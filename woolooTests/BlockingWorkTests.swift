import XCTest
@testable import wooloo

/// The tests wait from their own thread with timeouts, so a regression fails instead of hanging.
final class BlockingWorkTests: XCTestCase {
    func testRunningWorkNeverExceedsTheLimit() {
        let count = BlockingWork.limit * 3
        let running = Locked(0)
        let most = Locked(0)
        let runs = DispatchGroup()
        for _ in 0..<count {
            runs.enter()
            Task.detached {
                try? await BlockingWork.run { () throws in
                    let now = running.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    most.withLock { $0 = max($0, now) }
                    Thread.sleep(forTimeInterval: 0.05)
                    running.withLock { $0 -= 1 }
                }
                runs.leave()
            }
        }
        XCTAssertEqual(runs.wait(timeout: .now() + 30), .success, "Every call finished")
        XCTAssertLessThanOrEqual(most.value, BlockingWork.limit)
        XCTAssertGreaterThan(most.value, 1, "Calls still run concurrently")
    }

    /// Calls waiting for a slot are suspended, not blocking Swift's cooperative threads.
    func testWaitingForASlotLeavesCooperativeThreadsFree() {
        let gate = SlotGate(holding: BlockingWork.limit)
        defer { gate.open() }
        XCTAssertTrue(waitUntil(10) { gate.started.value == BlockingWork.limit }, "Every slot is held")
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 3
        let ran = Locked(0)
        let finished = DispatchGroup()
        for _ in 0..<waiters {
            finished.enter()
            Task.detached {
                try? await BlockingWork.run { () throws in ran.withLock { $0 += 1 } }
                finished.leave()
            }
        }
        XCTAssertTrue(waitUntil(10) { BlockingWork.slots.waiting >= waiters }, "The calls wait for a slot")
        let progressed = DispatchSemaphore(value: 0)
        Task.detached {
            await Task.yield()
            progressed.signal()
        }
        XCTAssertEqual(progressed.wait(timeout: .now() + 10), .success, "An unrelated task ran while calls waited")
        XCTAssertEqual(ran.value, 0, "No call ran while the slots were held")
        gate.open()
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success, "The waiting calls ran once slots came free")
        XCTAssertEqual(ran.value, waiters)
    }

    func testCancelledTaskDoesNotStartWork() {
        let ran = Locked(false)
        let threw = Locked(false)
        let failed = Locked(false)
        let returnedNil = Locked(false)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await BlockingWork.run { () throws in ran.value = true }
            } catch is CancellationError {
                threw.value = true
            } catch {}
            let result = await BlockingWork.run { () -> Result<Int, any Error> in
                ran.value = true
                return .success(1)
            }
            if case .failure(let error) = result, error is CancellationError { failed.value = true }
            let optional = await BlockingWork.run { () -> Int? in
                ran.value = true
                return 1
            }
            returnedNil.value = optional == nil
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertFalse(ran.value, "No work started")
        XCTAssertTrue(threw.value, "The throwing variant throws CancellationError")
        XCTAssertTrue(failed.value, "A Result comes back as a CancellationError failure")
        XCTAssertTrue(returnedNil.value, "An optional comes back nil")
    }

    /// A call cancelled while it waits for a slot stops waiting, never runs, and does not take a
    /// slot from the calls after it.
    func testCancellingAWaitingCallStopsIt() {
        let gate = SlotGate(holding: BlockingWork.limit)
        defer { gate.open() }
        XCTAssertTrue(waitUntil(10) { gate.started.value == BlockingWork.limit }, "Every slot is held")
        let ran = Locked(false)
        let cancelled = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                try await BlockingWork.run { () throws in ran.value = true }
            } catch is CancellationError {
                cancelled.signal()
            } catch {}
        }
        XCTAssertTrue(waitUntil(10) { BlockingWork.slots.waiting >= 1 }, "The call waits for a slot")
        task.cancel()
        XCTAssertEqual(cancelled.wait(timeout: .now() + 10), .success, "The call stopped waiting")
        gate.open()
        XCTAssertEqual(gate.finished.wait(timeout: .now() + 30), .success)
        let later = DispatchSemaphore(value: 0)
        Task.detached {
            try? await BlockingWork.run { () throws in }
            later.signal()
        }
        XCTAssertEqual(later.wait(timeout: .now() + 10), .success, "Slots came back")
        XCTAssertFalse(ran.value, "The cancelled call never ran")
    }

    /// Long-lived work, such as Herdr's surface stream, runs while every slot is held, at the
    /// quality of service it asks for.
    func testUnlimitedWorkIsNotLimited() {
        let gate = SlotGate(holding: BlockingWork.limit)
        defer { gate.open() }
        XCTAssertTrue(waitUntil(10) { gate.started.value == BlockingWork.limit }, "Every slot is held")
        let quality = Locked<QualityOfService?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await BlockingWork.run(qualityOfService: .userInteractive, limited: false) { () throws in
                quality.value = Thread.current.qualityOfService
            }
            try? await BlockingWork.run(priority: .utility, limited: false) { () throws in }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "Unlimited work ran while the slots were held")
        XCTAssertEqual(quality.value, .userInteractive)
    }

    func testPriorityDefaultsToTheCallersPriority() {
        let quality = Locked<QualityOfService?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            try? await BlockingWork.run { () throws in quality.value = Thread.current.qualityOfService }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(quality.value, .utility)
    }

    /// A worker runs its calls in order on its own queue, at the quality of service each asks for,
    /// and they still take a slot.
    func testWorkerRunsCallsInOrderOnItsQueue() {
        let worker = BlockingWorker(label: "dev.wooloo.test-worker")
        let order = Locked<[Int]>([])
        let labels = Locked<Set<String>>([])
        let quality = Locked<QualityOfService?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            for index in 0..<20 {
                try? await BlockingWork.run(on: worker) { () throws in
                    order.withLock { $0.append(index) }
                    labels.withLock { _ = $0.insert(String(cString: __dispatch_queue_get_label(nil))) }
                }
            }
            try? await BlockingWork.run(qualityOfService: .userInitiated, on: worker) { () throws in
                quality.value = Thread.current.qualityOfService
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(order.value, Array(0..<20))
        XCTAssertEqual(labels.value, ["dev.wooloo.test-worker"])
        XCTAssertEqual(quality.value, .userInitiated)

        let gate = SlotGate(holding: BlockingWork.limit)
        defer { gate.open() }
        XCTAssertTrue(waitUntil(10) { gate.started.value == BlockingWork.limit }, "Every slot is held")
        let ran = Locked(false)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            try? await BlockingWork.run(on: worker) { () throws in ran.value = true }
            finished.signal()
        }
        XCTAssertTrue(waitUntil(10) { BlockingWork.slots.waiting >= 1 }, "The worker's call waits for a slot")
        XCTAssertFalse(ran.value)
        gate.open()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(ran.value)
    }

    /// This Mac and each SSH machine keep to their own limit while all of them are busy at once.
    func testEachMachineKeepsToItsOwnLimit() {
        let machines: [BlockingWorkMachine] = [.local, .ssh("limits-a.test"), .ssh("limits-b.test")]
        let running = Locked<[BlockingWorkMachine: Int]>([:])
        let most = Locked<[BlockingWorkMachine: Int]>([:])
        let mostInAll = Locked(0)
        let runs = DispatchGroup()
        for machine in machines {
            for _ in 0..<BlockingWork.machineLimit * 3 {
                runs.enter()
                Task.detached {
                    try? await BlockingWork.run(reaching: machine) { () throws in
                        let (now, total) = running.withLock { value -> (Int, Int) in
                            value[machine, default: 0] += 1
                            return (value[machine, default: 0], value.values.reduce(0, +))
                        }
                        most.withLock { $0[machine] = max($0[machine, default: 0], now) }
                        mostInAll.withLock { $0 = max($0, total) }
                        Thread.sleep(forTimeInterval: 0.05)
                        running.withLock { $0[machine, default: 0] -= 1 }
                    }
                    runs.leave()
                }
            }
        }
        XCTAssertEqual(runs.wait(timeout: .now() + 30), .success, "Every call finished")
        let peaks = most.value
        XCTAssertLessThanOrEqual(peaks[.local, default: 0], BlockingWork.limit)
        for machine in machines.dropFirst() {
            XCTAssertLessThanOrEqual(peaks[machine, default: 0], BlockingWork.machineLimit, "\(machine)")
        }
        XCTAssertLessThan(BlockingWork.machineLimit, 10, "Below sshd's default MaxSessions")
        XCTAssertGreaterThan(mostInAll.value, BlockingWork.machineLimit,
                             "Machines run at the same time, beyond any one machine's limit")
    }

    /// A machine whose every slot is held makes only its own calls wait: work on this Mac and on
    /// another machine runs at once.
    func testASaturatedMachineDoesNotBlockOtherMachines() {
        let busy = BlockingWorkMachine.ssh("saturated.test")
        let gate = SlotGate(holding: BlockingWork.machineLimit, reaching: busy)
        defer { gate.open() }
        XCTAssertTrue(waitUntil(10) { gate.started.value == BlockingWork.machineLimit }, "Every slot of the machine is held")
        let queued = Locked(false)
        let queuedDone = DispatchSemaphore(value: 0)
        Task.detached {
            try? await BlockingWork.run(reaching: busy) { () throws in queued.value = true }
            queuedDone.signal()
        }
        XCTAssertTrue(waitUntil(10) { BlockingWork.slots(for: busy).waiting >= 1 }, "The machine's next call waits")

        let others = DispatchGroup()
        let ran = Locked(0)
        for _ in 0..<BlockingWork.limit * 2 {
            others.enter()
            Task.detached {
                try? await BlockingWork.run { () throws in ran.withLock { $0 += 1 } }
                try? await BlockingWork.run(reaching: .ssh("idle.test")) { () throws in ran.withLock { $0 += 1 } }
                others.leave()
            }
        }
        XCTAssertEqual(others.wait(timeout: .now() + 10), .success, "Local and other machines' work ran")
        XCTAssertEqual(ran.value, BlockingWork.limit * 4)
        XCTAssertEqual(BlockingWork.slots.waiting, 0)
        XCTAssertFalse(queued.value, "The saturated machine's call still waits")

        gate.open()
        XCTAssertEqual(queuedDone.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(queued.value)
    }

    /// Work knows whose slot it holds, so an SSH command started under this Mac's limit is caught.
    func testWorkKnowsTheMachineWhoseSlotItHolds() {
        let machine = HerdrMachineProfile(id: "box", label: "Box", target: "user@box.test", session: "default", enabled: true)
        let location = WorkspaceFileLocation(machine: machine, session: "default", workspaceID: "w",
                                             workspaceLabel: "w", root: "/srv")
        let seen = Locked<[BlockingWorkMachine?]>([])
        let held = Locked<[Bool]>([])
        let worker = BlockingWorker(label: "dev.wooloo.test-machine-worker")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let record: @Sendable () -> Void = {
                seen.withLock { $0.append(BlockingWork.currentMachine) }
                held.withLock { $0.append(BlockingWork.holdsSlot(of: .ssh("user@box.test"))) }
            }
            try? await WorkspaceFiles.blocking(at: location) { () throws in record() }
            try? await WorkspaceFiles.blocking(on: machine, worker: worker) { () throws in record() }
            try? await BlockingWork.run(on: worker) { () throws in record() }
            try? await BlockingWork.run { () throws in record() }
            try? await BlockingWork.run(priority: .utility, limited: false) { () throws in record() }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(seen.value, [.ssh("user@box.test"), .ssh("user@box.test"), .local, .local, nil])
        XCTAssertEqual(held.value, [true, true, false, false, true])
        XCTAssertEqual(BlockingWorkMachine(nil), .local)
        XCTAssertEqual(BlockingWorkMachine(machine), .ssh("user@box.test"))
    }

    /// Spellings of one SSH connection, which SSH shares through `ControlPath=%C`, share one
    /// limit; another user or port is another connection.
    func testSpellingsOfOneSSHConnectionShareALimit() {
        func machine(_ target: String) -> BlockingWorkMachine {
            BlockingWorkMachine(HerdrMachineProfile(id: target, label: target, target: target, session: "default", enabled: true))
        }
        XCTAssertEqual(machine("ssh://dev@box"), machine("dev@box"))
        XCTAssertEqual(machine("ssh://dev@Box:22"), machine("dev@box"))
        XCTAssertEqual(machine("ssh://box.test"), machine("box.test"))
        XCTAssertNotEqual(machine("ssh://dev@box:2222"), machine("dev@box"))
        XCTAssertNotEqual(machine("ssh://ops@box"), machine("dev@box"))
        XCTAssertTrue(BlockingWork.slots(for: machine("ssh://dev@box")) === BlockingWork.slots(for: machine("dev@box")))
        XCTAssertFalse(BlockingWork.slots(for: machine("ssh://dev@box:2222")) === BlockingWork.slots(for: machine("dev@box")))

        let endpoint = WorkspaceFiles.SSHEndpoint("ssh://dev@box:2222")
        XCTAssertEqual(endpoint.destination, "dev@box", "What ssh is given")
        XCTAssertEqual(endpoint.port, "2222")
        XCTAssertEqual(WorkspaceFiles.SSHEndpoint("dev@box").port, nil)
    }

    func testEachSSHMachineHasTheLimitOfThisMac() {
        XCTAssertEqual(BlockingWork.machineLimit, BlockingWork.limit)
        XCTAssertLessThan(BlockingWork.machineLimit, 10, "Below sshd's default MaxSessions")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}

/// A model's real load path, not `BlockingWork` alone: many Git bar loads of an SSH machine that
/// hangs. Waits spin the main run loop from the test's own thread with timeouts, so the main
/// actor's tasks run and a regression fails instead of hanging.
@MainActor
final class BlockingWorkLoadTests: XCTestCase {
    func testSlowGitBarLoadsLeaveCooperativeThreadsTheMainActorAndOtherMachinesFree() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer {
            try? FileManager.default.createDirectory(atPath: sandbox.path("gate"), withIntermediateDirectories: true)
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        try sandbox.repository("repo")
        // Holds every command for slow.test until the gate exists, for at most 12 s, below the
        // 15 s timeout of a load, so a regression that blocks the main thread still ends. Other
        // machines' commands run at once.
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            for command; do :; done
            case " $* " in
            *" slow.test "*)
                echo start >> '\(sandbox.path("started"))'
                i=0
                while [ ! -e '\(sandbox.path("gate"))' ] && [ $i -lt 240 ]; do sleep 0.05; i=$((i + 1)); done
                ;;
            esac
            cd '\(sandbox.base)'
            exec /bin/sh -c "$command"
            """], in: ".")
        try sandbox.sh("chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
        let started = { ((try? String(contentsOfFile: sandbox.path("started"), encoding: .utf8)) ?? "")
            .split(separator: "\n").count }

        let machine = HerdrMachineProfile(id: "slow", label: "Slow", target: "slow.test", session: "default", enabled: true)
        let slots = BlockingWork.slots(for: .ssh("slow.test"))
        let limit = BlockingWork.machineLimit
        // More loads than cooperative threads, besides the ones that get a slot.
        let count = limit + ProcessInfo.processInfo.activeProcessorCount * 2
        let models = (0..<count).map { _ in WorkspaceGitBarModel() }
        let loaded = expectation(description: "Every load finished")
        loaded.expectedFulfillmentCount = count
        for (index, model) in models.enumerated() {
            // Separate Spaces, so no load shares another's result.
            let location = WorkspaceFileLocation(machine: machine, session: "default", workspaceID: "space-\(index)",
                                                 workspaceLabel: "repo", root: sandbox.path("repo"))
            Task {
                await model.load(location)
                loaded.fulfill()
            }
        }
        XCTAssertTrue(spin(10) { started() == limit && slots.waiting == count - limit },
                      "Loads hold every slot of the machine and the rest wait: \(started()) started, \(slots.waiting) waiting")

        let pool = expectation(description: "An unrelated task ran on the cooperative threads")
        Task.detached {
            await Task.yield()
            pool.fulfill()
        }
        let mainActor = expectation(description: "The main actor ran other work")
        Task { mainActor.fulfill() }
        wait(for: [pool, mainActor], timeout: 10)

        // The slow machine holds only its own slots: a local Space and another SSH machine load.
        let fast = HerdrMachineProfile(id: "fast", label: "Fast", target: "fast.test", session: "default", enabled: true)
        let others = [sandbox.location("repo"),
                      WorkspaceFileLocation(machine: fast, session: "default", workspaceID: "fast",
                                            workspaceLabel: "repo", root: sandbox.path("repo"))]
        let otherModels = others.map { _ in WorkspaceGitBarModel() }
        let otherLoaded = expectation(description: "Loads of this Mac and another machine finished")
        otherLoaded.expectedFulfillmentCount = others.count
        for (location, model) in zip(others, otherModels) {
            Task {
                await model.load(location)
                otherLoaded.fulfill()
            }
        }
        wait(for: [otherLoaded], timeout: 10)
        XCTAssertEqual(otherModels.compactMap { $0.status?.branch }, ["main", "main"])
        XCTAssertEqual(started(), limit, "No more than the machine's limit ran at once")
        XCTAssertEqual(slots.waiting, count - limit, "The slow machine's loads still wait")

        try FileManager.default.createDirectory(atPath: sandbox.path("gate"), withIntermediateDirectories: true)
        wait(for: [loaded], timeout: 60)
        XCTAssertEqual(started(), count)
        XCTAssertEqual(models.compactMap { $0.status?.branch }, Array(repeating: "main", count: count))
    }


    private func spin(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }
}

/// Holds slots of `BlockingWork` with calls that block until `open()`.
private final class SlotGate: @unchecked Sendable {
    let started = Locked(0)
    let finished = DispatchGroup()
    private let semaphore = DispatchSemaphore(value: 0)
    private let opened = Locked(false)
    private let count: Int

    init(holding count: Int, reaching machine: BlockingWorkMachine = .local) {
        self.count = count
        for _ in 0..<count {
            finished.enter()
            Task.detached { [started, semaphore, finished] in
                try? await BlockingWork.run(priority: .utility, reaching: machine) { () throws in
                    started.withLock { $0 += 1 }
                    semaphore.wait()
                }
                finished.leave()
            }
        }
    }

    func open() {
        let first = opened.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        guard first else { return }
        for _ in 0..<count { semaphore.signal() }
    }
}

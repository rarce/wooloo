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
    func testSlowGitBarLoadsLeaveCooperativeThreadsAndTheMainActorFree() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer {
            try? FileManager.default.createDirectory(atPath: sandbox.path("gate"), withIntermediateDirectories: true)
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        try sandbox.repository("repo")
        // Holds every command until the gate exists, for at most 12 s, below the 15 s timeout of
        // a load, so a regression that blocks the main thread still ends.
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            echo start >> '\(sandbox.path("started"))'
            i=0
            while [ ! -e '\(sandbox.path("gate"))' ] && [ $i -lt 240 ]; do sleep 0.05; i=$((i + 1)); done
            for command; do :; done
            cd '\(sandbox.base)'
            exec /bin/sh -c "$command"
            """], in: ".")
        try sandbox.sh("chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
        let started = { ((try? String(contentsOfFile: sandbox.path("started"), encoding: .utf8)) ?? "")
            .split(separator: "\n").count }

        let machine = HerdrMachineProfile(id: "slow", label: "Slow", target: "slow.test", session: "default", enabled: true)
        // More loads than cooperative threads, besides the ones that get a slot.
        let count = BlockingWork.limit + ProcessInfo.processInfo.activeProcessorCount * 2
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
        XCTAssertTrue(spin(10) { started() == BlockingWork.limit && BlockingWork.slots.waiting == count - BlockingWork.limit },
                      "Loads hold every slot and the rest wait: \(started()) started, \(BlockingWork.slots.waiting) waiting")

        let pool = expectation(description: "An unrelated task ran on the cooperative threads")
        Task.detached {
            await Task.yield()
            pool.fulfill()
        }
        let mainActor = expectation(description: "The main actor ran other work")
        Task { mainActor.fulfill() }
        wait(for: [pool, mainActor], timeout: 10)
        XCTAssertEqual(started(), BlockingWork.limit, "No more than the limit ran at once")

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

    init(holding count: Int) {
        self.count = count
        for _ in 0..<count {
            finished.enter()
            Task.detached { [started, semaphore, finished] in
                try? await BlockingWork.run(priority: .utility) { () throws in
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

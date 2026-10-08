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

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
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

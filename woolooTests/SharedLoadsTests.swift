import XCTest
@testable import wooloo

/// `SharedLoads` lets the Git bar and the repository panel share one repository load. These
/// tests check that sharing never returns a result older than a change the app knows about.
final class SharedLoadsTests: XCTestCase {
    func testForgettingOneLocationPreservesOtherLocationsAndRejectsItsOldStores() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        _ = try loads.value(for: "a") { 1 }
        _ = try loads.value(for: "b") { 2 }
        let token = loads.generation(for: "a")
        loads.forget("a")
        loads.store(9, for: "a", keyGeneration: token)
        XCTAssertNil(loads.recent(for: "a"))
        XCTAssertEqual(try loads.value(for: "b") { 99 }, 2)
        XCTAssertEqual(try loads.value(for: "a") { 3 }, 3)
    }

    func testForgettingOneLocationDuringItsLoadDoesNotCacheTheOldResult() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        XCTAssertEqual(try loads.value(for: "a") { loads.forget("a"); return 1 }, 1)
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 2)
    }

    func testReusesRecentResult() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        var calls = 0
        XCTAssertEqual(try loads.value(for: "a") { calls += 1; return calls }, 1)
        XCTAssertEqual(try loads.value(for: "a") { calls += 1; return calls }, 1)
        XCTAssertEqual(try loads.value(for: "b") { calls += 1; return calls }, 2)
    }

    func testForgetLoadsAgain() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        _ = try loads.value(for: "a") { 1 }
        loads.forget()
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 2)
    }

    func testExpiredResultLoadsAgain() throws {
        let loads = SharedLoads<Int>(maxAge: 0)
        _ = try loads.value(for: "a") { 1 }
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 2)
    }

    func testFailureIsNotKept() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        XCTAssertThrowsError(try loads.value(for: "a") { throw CocoaError(.fileNoSuchFile) })
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 2)
    }

    /// A value found by other work is kept like a load's result, unless a change came in between.
    func testStoredValueIsKeptOnlyWithoutAnInterveningForget() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        XCTAssertNil(loads.recent(for: "a"))
        loads.store(1, for: "a", generation: loads.generation)
        XCTAssertEqual(loads.recent(for: "a"), 1)
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 1)

        let generation = loads.generation
        loads.forget()
        XCTAssertNil(loads.recent(for: "a"))
        loads.store(3, for: "a", generation: generation)
        XCTAssertNil(loads.recent(for: "a"), "The value may predate the change")
    }

    /// A load that started before a change may have read the old state. Its caller gets it,
    /// but a later caller must load again.
    func testLoadOvertakenByForgetIsNotKept() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        XCTAssertEqual(try loads.value(for: "a") { loads.forget(); return 1 }, 1)
        XCTAssertEqual(try loads.value(for: "a") { 2 }, 2)
    }

    /// A caller that needs results read after it asked joins a running load but never reuses a finished one.
    func testCallerNotReusingFinishedResultsOnlyJoinsARunningLoad() throws {
        let loads = SharedLoads<Int>(maxAge: 60)
        _ = try loads.value(for: "a") { 1 }
        XCTAssertEqual(try loads.value(for: "a", reusingFinished: false) { 2 }, 2)
        XCTAssertEqual(try loads.value(for: "a") { 3 }, 2, "Its result is kept for others")

        loads.forget()
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            _ = try? loads.value(for: "a") { started.signal(); Thread.sleep(forTimeInterval: 0.2); return 4 }
        }
        started.wait()
        XCTAssertEqual(try loads.value(for: "a", reusingFinished: false) { 5 }, 4)
        group.wait()
    }

    /// Callers that ask while a load runs wait for it instead of starting their own.
    func testConcurrentCallersShareOneLoad() {
        let loads = SharedLoads<Int>(maxAge: 60)
        let lock = NSLock()
        var calls = 0
        var results = [Int](repeating: 0, count: 8)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let value = try? loads.value(for: "a") {
                lock.lock(); calls += 1; lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                return 7
            }
            lock.lock(); results[index] = value ?? -1; lock.unlock()
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(results, [Int](repeating: 7, count: 8))
    }
}

import XCTest
@testable import wooloo

final class HangWatchdogTests: XCTestCase {
    func testAMainThreadThatAnswersIsPingedEveryIntervalAndNeverCaptured() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 0.5, answeredAt: 0.1, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 1, answeredAt: 0.1, interval: 1), .ping)
        // In the background, less often.
        XCTAssertEqual(stall.step(at: 3, answeredAt: 1.1, interval: 5), .wait)
        XCTAssertEqual(stall.step(at: 6, answeredAt: 1.1, interval: 5), .ping)
    }

    func testAStuckMainThreadIsCapturedOnceThenReportedWhenItAnswered() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 2.5, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 20, answeredAt: nil, interval: 1), .wait)
        // The time the main thread answered, not when the watchdog looked after sampling.
        XCTAssertEqual(stall.step(at: 21, answeredAt: 3.2, interval: 1), .recovered(after: 3.2))
    }

    func testStallsSoonAfterACaptureAreNotSampled() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 4, answeredAt: 3.5, interval: 1), .recovered(after: 3.5))
        XCTAssertEqual(stall.step(at: 7, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 8, answeredAt: 7.5, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 70, answeredAt: nil, interval: 1), .capture)
    }

    func testAStallThatBeganDuringTheCooldownIsCapturedWhenItEnds() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 4, answeredAt: 3.5, interval: 1), .recovered(after: 3.5))
        // Stuck for good from 30 on.
        XCTAssertEqual(stall.step(at: 33, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 62.5, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 63, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 120, answeredAt: nil, interval: 1), .wait)
    }

    func testReportNamesAreInUTC() {
        XCTAssertEqual(HangWatchdog.reportName(for: Date(timeIntervalSince1970: 0)), "hang-1970-01-01-000000.txt")
    }

    func testPruningKeepsTheNewestReportsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wooloo-hangs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (1...5).map { HangWatchdog.reportName(for: Date(timeIntervalSince1970: TimeInterval($0) * 3600)) }
        for name in names + ["notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }
        HangWatchdog.prune(directory, keeping: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, (names.suffix(2) + ["notes.txt"]).sorted())
    }
}

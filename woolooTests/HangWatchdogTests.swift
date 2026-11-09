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

    func testAStuckMainThreadIsCapturedThenReportedWhenItAnswered() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 2.5, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 20, answeredAt: nil, interval: 1), .wait)
        // The time the main thread answered, not when the watchdog looked after sampling.
        XCTAssertEqual(stall.step(at: 21, answeredAt: 3.2, interval: 1), .recovered(after: 3.2))
    }

    func testAContinuousStallGetsThreeSpacedCapturesAndKeepsItsOriginalRecoveryTime() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 32.9, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 33, answeredAt: nil, interval: 1), .recapture)
        XCTAssertEqual(stall.step(at: 62.9, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 63, answeredAt: nil, interval: 1), .recapture)
        XCTAssertEqual(stall.step(at: 300, answeredAt: nil, interval: 1), .wait)
        XCTAssertEqual(stall.step(at: 301, answeredAt: 300.5, interval: 1), .recovered(after: 300.5))
        XCTAssertEqual(stall.step(at: 304, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 334, answeredAt: nil, interval: 1), .recapture)
    }

    func testRecoveryBeforeARepeatDoesNotCaptureAgain() {
        var stall = HangWatchdog.Stall(threshold: 3, cooldown: 60)
        XCTAssertEqual(stall.step(at: 0, answeredAt: nil, interval: 1), .ping)
        XCTAssertEqual(stall.step(at: 3, answeredAt: nil, interval: 1), .capture)
        XCTAssertEqual(stall.step(at: 33, answeredAt: 32.9, interval: 1), .recovered(after: 32.9))
        XCTAssertEqual(stall.step(at: 36, answeredAt: nil, interval: 1), .wait)
    }

    func testEventHistoryRetainsOnlyRecentBoundedSingleLineEntries() {
        var history = HangWatchdog.History()
        for index in 0...HangWatchdog.History.capacity {
            history.record("event-\(index)\n" + String(repeating: "x", count: 600), at: Double(index))
        }
        XCTAssertEqual(history.entries.count, HangWatchdog.History.capacity)
        XCTAssertEqual(history.entries.first?.uptime, 1)
        XCTAssertEqual(history.entries.last?.uptime, 128)
        XCTAssertTrue(history.entries.allSatisfy { $0.message.count <= 512 && !$0.message.contains("\n") })
    }

    func testScrollBurstsAreCoalescedWithoutDroppingAnInterveningAlert() {
        var history = HangWatchdog.History()
        history.record("scroll began", at: 0, coalescing: "wheel")
        history.record("scroll update", at: 0.1, coalescing: "wheel")
        history.record("scroll update", at: 0.25, coalescing: "wheel")
        history.record("alert", at: 0.26)
        history.record("scroll after alert", at: 0.27, coalescing: "wheel")
        XCTAssertEqual(history.entries.map(\.message), ["scroll began", "scroll update", "alert", "scroll after alert"])
    }

    func testMountedContextSurvivesHistoryRolloverAndCanBeRemoved() {
        let watchdog = HangWatchdog()
        watchdog.setContext("path=review.md", for: "preview")
        for _ in 0..<200 { watchdog.record("scroll") }
        XCTAssertTrue(watchdog.diagnosticContext().contains("path=review.md"))
        watchdog.setContext(nil, for: "preview")
        XCTAssertFalse(watchdog.diagnosticContext().contains("path=review.md"))
    }

    func testMemoryReadingIncludesTheProcessesPhysicalFootprint() {
        let reading = HangWatchdog.memoryReading()
        XCTAssertTrue(reading.contains("footprint_bytes="), reading)
        XCTAssertFalse(reading.contains("footprint_bytes=0 "), reading)
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
        XCTAssertEqual(stall.step(at: 120, answeredAt: nil, interval: 1), .recapture)
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
        let abandonedSample = directory.appending(path: names[0]).appendingPathExtension("sample")
        try Data().write(to: abandonedSample)
        HangWatchdog.prune(directory, keeping: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, (names.suffix(2) + ["notes.txt"]).sorted())
    }
}

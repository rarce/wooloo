import XCTest
@testable import wooloo

final class HangWatchdogTests: XCTestCase {
    func testAMainThreadThatAnswersIsPingedAgainAndNeverCaptured() {
        var stall = HangWatchdog.Stall(threshold: 3)
        XCTAssertEqual(stall.step(at: 0, answered: false), .ping)
        for second in 1...10 {
            XCTAssertEqual(stall.step(at: TimeInterval(second), answered: true), .ping)
        }
    }

    func testAStuckMainThreadIsCapturedOnceThenReportedWhenItAnswers() {
        var stall = HangWatchdog.Stall(threshold: 3)
        XCTAssertEqual(stall.step(at: 0, answered: false), .ping)
        XCTAssertEqual(stall.step(at: 2.5, answered: false), .wait)
        XCTAssertEqual(stall.step(at: 3, answered: false), .capture)
        XCTAssertEqual(stall.step(at: 20, answered: false), .wait)
        XCTAssertEqual(stall.step(at: 21, answered: true), .recovered(after: 21))
        // A later stall is a new one.
        XCTAssertEqual(stall.step(at: 21.5, answered: false), .wait)
        XCTAssertEqual(stall.step(at: 24, answered: false), .capture)
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

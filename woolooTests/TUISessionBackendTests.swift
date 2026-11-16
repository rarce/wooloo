import XCTest
@testable import wooloo

/// How the Herdr TUI backend reads answers that report a refusal instead of an error.
final class TUISessionBackendTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testAMoveHerdrDidNotMakeIsAnErrorWithItsReason() throws {
        XCTAssertNoThrow(try TUISessionBackend.requireChange(
            json(["result": ["move_result": ["changed": true]]]), in: "move_result", doing: "move the pane"))
        XCTAssertThrowsError(try TUISessionBackend.requireChange(
            json(["result": ["move_result": ["changed": false, "reason": "target_zoomed"]]]),
            in: "move_result", doing: "move the pane")) { error in
            XCTAssertEqual(error.localizedDescription, "Herdr could not move the pane: target zoomed")
        }
        XCTAssertThrowsError(try TUISessionBackend.requireChange(
            json(["result": ["swap": ["changed": false]]]), in: "swap", doing: "place the pane on that side")) { error in
            XCTAssertEqual(error.localizedDescription, "Herdr could not place the pane on that side")
        }
        XCTAssertThrowsError(try TUISessionBackend.requireChange(json(["result": [:]]), in: "swap", doing: "swap")) { error in
            XCTAssertEqual(error.localizedDescription, "Unexpected response from Herdr")
        }
    }

    func testAReloadMustBeApplied() throws {
        XCTAssertNoThrow(try TUISessionBackend.requireApplied(json(["result": ["status": "applied"]])))
        XCTAssertThrowsError(try TUISessionBackend.requireApplied(
            json(["result": ["status": "rejected", "diagnostics": ["bad key", "bad value"]]]))) { error in
            XCTAssertEqual(error.localizedDescription, "Herdr reload: rejected. bad key\nbad value")
        }
        XCTAssertThrowsError(try TUISessionBackend.requireApplied(json(["result": [:]]))) { error in
            XCTAssertEqual(error.localizedDescription, "Unexpected response from Herdr reload")
        }
    }

    func testWorktreesFallBackToAPlainSpaceOnlyForKnownRefusals() {
        XCTAssertEqual(TUISessionBackend.worktreeFallbackCodes,
                       ["linked_worktree_source", "not_git_worktree", "invalid_request"])
    }

    func testMoveErrorsShowTheirMessage() {
        XCTAssertEqual(SessionMoveError(message: "The source tab disappeared.").localizedDescription,
                       "The source tab disappeared.")
    }
}

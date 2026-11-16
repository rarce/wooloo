import XCTest
@testable import wooloo

/// Each session command is sent to the Herdr TUI as the exact request `HerdrStore` sent before
/// commands existed, and only moving focus or splitting follows the server's focus.
final class SessionCommandTests: XCTestCase {
    private func encoded(_ command: SessionCommand) throws -> String {
        let request = command.herdrRequest
        let data = try JSONSerialization.data(withJSONObject: ["method": request.method, "params": request.params],
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testHerdrRequests() throws {
        let expected: [(SessionCommand, String)] = [
            (.focusPane(paneID: "w1:p1", direction: "left"),
             #"{"method":"pane.focus_direction","params":{"direction":"left","pane_id":"w1:p1"}}"#),
            (.splitPane(spaceID: "w1", paneID: "w1:p1", direction: "right"),
             #"{"method":"pane.split","params":{"direction":"right","focus":true,"target_pane_id":"w1:p1","workspace_id":"w1"}}"#),
            (.zoomPane(paneID: "w1:p2"),
             #"{"method":"pane.zoom","params":{"pane_id":"w1:p2"}}"#),
            (.renameSpace(spaceID: "w1", label: "api"),
             #"{"method":"workspace.rename","params":{"label":"api","workspace_id":"w1"}}"#),
            (.closeSpace(spaceID: "w2"),
             #"{"method":"workspace.close","params":{"workspace_id":"w2"}}"#),
            (.renameAgent(paneID: "w1:p1", name: "reviewer"),
             #"{"method":"agent.rename","params":{"name":"reviewer","target":"w1:p1"}}"#),
            (.renameAgent(paneID: "w1:p1", name: nil),
             #"{"method":"agent.rename","params":{"name":null,"target":"w1:p1"}}"#),
            (.renameTab(tabID: "w1:t2", label: "logs"),
             #"{"method":"tab.rename","params":{"label":"logs","tab_id":"w1:t2"}}"#),
            (.closeTab(tabID: "w1:t2"),
             #"{"method":"tab.close","params":{"tab_id":"w1:t2"}}"#),
            (.closePane(paneID: "w1:p3"),
             #"{"method":"pane.close","params":{"pane_id":"w1:p3"}}"#),
            (.moveTab(tabID: "w1:t1", insertIndex: 3),
             #"{"method":"tab.move","params":{"insert_index":3,"tab_id":"w1:t1"}}"#),
            (.reloadConfig,
             #"{"method":"server.reload_config","params":{}}"#),
        ]
        for (command, json) in expected {
            XCTAssertEqual(try encoded(command), json, "\(command)")
        }
    }

    func testOnlyFocusMovesAndSplitsFollowTheServer() {
        XCTAssertTrue(SessionCommand.focusPane(paneID: "p", direction: "up").followsServerFocus)
        XCTAssertTrue(SessionCommand.splitPane(spaceID: "w", paneID: "p", direction: "down").followsServerFocus)
        for command: SessionCommand in [.zoomPane(paneID: "p"), .renameSpace(spaceID: "w", label: "l"),
                                        .closeSpace(spaceID: "w"), .renameAgent(paneID: "p", name: nil),
                                        .renameTab(tabID: "t", label: "l"), .closeTab(tabID: "t"),
                                        .closePane(paneID: "p"), .moveTab(tabID: "t", insertIndex: 0),
                                        .reloadConfig] {
            XCTAssertFalse(command.followsServerFocus, "\(command)")
        }
    }
}

import XCTest
@testable import wooloo

/// The Herdr TUI snapshot mapped into the backend-neutral session model, and the neutral
/// move rules checked against the snapshot's own (the ones `HerdrStore` uses today).
final class WoolooSessionTests: XCTestCase {
    private let backend = BackendID.tui(contextID: "agents")

    /// Two Spaces: w1 with a one-pane tab and a zoomed two-pane tab, w2 with one tab.
    private let snapshotJSON = """
    {
      "workspaces": [
        {"workspace_id": "w1", "label": "repo", "agent_status": "working", "active_tab_id": "w1:t1",
         "worktree": {"checkout_path": "/src/repo-feature"}},
        {"workspace_id": "w2", "label": "docs", "agent_status": null, "active_tab_id": "w2:t1"}
      ],
      "tabs": [
        {"tab_id": "w1:t1", "workspace_id": "w1", "label": "one", "agent_status": "blocked"},
        {"tab_id": "w1:t2", "workspace_id": "w1", "label": "two", "agent_status": "idle"},
        {"tab_id": "w2:t1", "workspace_id": "w2", "label": "docs", "agent_status": null}
      ],
      "panes": [
        {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "cwd": "/src/repo", "agent_status": "blocked"},
        {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2", "cwd": "/src/repo", "agent_status": "idle"},
        {"pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t2", "cwd": null, "agent_status": "paused"},
        {"pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1", "cwd": "/src/docs"}
      ],
      "agents": [
        {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "claude",
         "display_agent": "Claude Code", "title": "fixing tests", "agent_status": "blocked",
         "state_labels": [["blocked", "needs input"]], "tokens": {"summary": "waiting for approval"},
         "state_change_seq": 7}
      ],
      "layouts": [
        {"tab_id": "w1:t1", "area": {"x": 0, "y": 0, "width": 120, "height": 40},
         "panes": [{"pane_id": "w1:p1", "rect": {"x": 0, "y": 0, "width": 120, "height": 40}}]},
        {"tab_id": "w1:t2", "area": {"x": 0, "y": 0, "width": 120, "height": 40}, "zoomed": true,
         "panes": [{"pane_id": "w1:p2", "rect": {"x": 0, "y": 0, "width": 60, "height": 40}},
                   {"pane_id": "w1:p3", "rect": {"x": 61, "y": 0, "width": 59, "height": 40}}]},
        {"tab_id": "w2:t1", "area": {"x": 0, "y": 0, "width": 120, "height": 40},
         "panes": [{"pane_id": "w2:p1", "rect": {"x": 0, "y": 0, "width": 120, "height": 40}}]}
      ],
      "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1"
    }
    """

    private func snapshot() throws -> HerdrSnapshot {
        try JSONDecoder().decode(HerdrSnapshot.self, from: Data(snapshotJSON.utf8))
    }

    func testStructureMapsOneToOne() throws {
        let session = try snapshot().session(backend: backend)
        XCTAssertEqual(session.backend, backend)
        XCTAssertEqual(session.capabilities, .herdrTUI)
        XCTAssertEqual(session.spaces.map(\.id), ["w1", "w2"])
        XCTAssertEqual(session.spaces[0].worktreePath, "/src/repo-feature")
        XCTAssertEqual(session.spaces[0].state, .working)
        XCTAssertNil(session.spaces[1].state)
        XCTAssertEqual(session.spaces[1].activeTabID, "w2:t1")
        XCTAssertEqual(session.tabs(in: "w1").map(\.id), ["w1:t1", "w1:t2"])
        XCTAssertEqual(session.panes(in: "w1:t2").map(\.id), ["w1:p2", "w1:p3"])
        XCTAssertEqual(session.panes[2].state, .other("paused"))
        XCTAssertNil(session.panes[3].state)
        XCTAssertEqual(session.layout(of: "w1:t2")?.zoomed, true)
        XCTAssertEqual(session.layout(of: "w1:t1")?.zoomed, false)
        XCTAssertEqual(session.layout(of: "w1:t2")?.panes.last?.rect, WoolooRect(x: 61, y: 0, width: 59, height: 40))
        XCTAssertEqual(session.focusedSpaceID, "w1")
        XCTAssertEqual(session.focusedTabID, "w1:t1")
        XCTAssertEqual(session.focusedPaneID, "w1:p1")
    }

    func testAgentKeepsWhatTheUIShows() throws {
        let source = try snapshot()
        let agent = try XCTUnwrap(source.session(backend: backend).agents.first)
        let tui = source.agents[0]
        XCTAssertEqual(agent.name, tui.displayName)
        XCTAssertEqual(agent.detail, tui.detail)
        XCTAssertEqual(agent.statusLabel, tui.displayStatus)
        XCTAssertEqual(agent.statusLabel, "needs input")
        XCTAssertEqual(agent.kind, "claude")
        XCTAssertEqual(agent.state, .blocked)
        XCTAssertTrue(agent.state.needsAttention)
        XCTAssertEqual(agent.progress, 7)
    }

    func testAgentStateVocabulary() {
        XCTAssertEqual(AgentState("working"), .working)
        XCTAssertEqual(AgentState("blocked"), .blocked)
        XCTAssertEqual(AgentState("error"), .error)
        XCTAssertEqual(AgentState("done"), .done)
        XCTAssertEqual(AgentState("idle"), .idle)
        XCTAssertEqual(AgentState("unknown"), .unknown)
        XCTAssertEqual(AgentState(nil), .unknown)
        XCTAssertEqual(AgentState("thinking"), .other("thinking"))
        XCTAssertTrue(AgentState.error.needsAttention)
        XCTAssertFalse(AgentState.done.needsAttention)
    }

    func testTUIBackendKeysKeepTheirFormat() throws {
        XCTAssertEqual(backend.persistentKey, "agents")
        XCTAssertEqual(try snapshot().session(backend: backend).spaceKey("w1"), "agents|w1")
        let remote = BackendID.tui(contextID: "ssh:box-1|agents|target:af5b478ea0f82ad4e0d63d3cf518cbb6")
        XCTAssertEqual(remote.persistentKey, remote.context)
        let core = BackendID.core(coreID: "0cb444fcc416473805fbe432ac9aaa8c", session: "default")
        XCTAssertEqual(core.persistentKey, "core:0cb444fcc416473805fbe432ac9aaa8c|default")
        XCTAssertNotEqual(core, BackendID.tui(contextID: core.context))
    }

    func testMoveRulesMatchTheSnapshotRules() throws {
        let source = try snapshot()
        let session = source.session(backend: backend)
        let tabIDs = source.tabs.map(\.tabID) + ["missing"]
        for from in tabIDs {
            for into in tabIDs + [nil] as [String?] {
                XCTAssertEqual(session.paneToSplit(fromTab: from, into: into),
                               source.paneToSplit(fromTab: from, into: into), "paneToSplit \(from) → \(into ?? "nil")")
            }
            for space in ["w1", "w2", "missing", nil] as [String?] {
                XCTAssertEqual(session.tabSpaceMoveRefusal(from, to: space),
                               source.tabSpaceMoveRefusal(from, to: space), "tabSpaceMoveRefusal \(from) → \(space ?? "nil")")
            }
        }
        for space in ["w1", "w2", "missing"] {
            for anchor in ["w1", "w2", "missing"] {
                for after in [false, true] {
                    XCTAssertEqual(session.spaceMoveIndex(space, beside: anchor, after: after),
                                   source.workspaceMoveIndex(space, beside: anchor, after: after))
                }
            }
        }
    }

    func testCapabilitiesDriveTheMoveRules() throws {
        var open = BackendCapabilities.herdrTUI
        open.zoomedTabsRefuseMoves = false
        open.onlySinglePaneTabsMove = false
        let session = try snapshot().session(backend: backend, capabilities: open)
        XCTAssertEqual(session.paneToSplit(fromTab: "w1:t2", into: "w1:t1"), "w1:p2")
        XCTAssertEqual(session.paneToSplit(fromTab: "w1:t1", into: "w1:t2"), "w1:p1")
        XCTAssertNil(session.tabSpaceMoveRefusal("w1:t2", to: "w2"))
        open.movesTabsBetweenSpaces = false
        XCTAssertEqual(try snapshot().session(backend: backend, capabilities: open).tabSpaceMoveRefusal("w1:t1", to: "w2"),
                       "This server cannot move tabs between Spaces.")
    }
}

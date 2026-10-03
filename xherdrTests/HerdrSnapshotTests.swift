import XCTest
@testable import xherdr

/// Decoding of Herdr's `session.snapshot`, trimmed from Herdr 0.9.1 output. Unknown fields,
/// such as `number` and `scroll`, must be ignored so newer servers keep working.
final class HerdrSnapshotTests: XCTestCase {
    private let json = """
    {"agents":[
      {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","agent":"claude","display_agent":"Claude",
       "agent_status":"blocked","state_labels":{"blocked":"Needs input"},"tokens":{"summary":"Fix the tests"},
       "title":"Claude","terminal_title_stripped":"claude ~/project"},
      {"pane_id":"w2:p1","workspace_id":"w2","agent_status":"working","title":"make test"},
      {"pane_id":"w2:p3"}
    ],
    "focused_pane_id":"w2:p2","focused_tab_id":"w2:t1","focused_workspace_id":"w2",
    "layouts":[{"area":{"height":40,"width":120,"x":0,"y":0},"focused_pane_id":"w1:p2",
      "panes":[{"focused":true,"pane_id":"w1:p2","rect":{"height":40,"width":120,"x":0,"y":0}}],
      "splits":[],"tab_id":"w1:t1","workspace_id":"w1","zoomed":false}],
    "panes":[
      {"agent_status":"blocked","cwd":"/tmp/project","focused":false,"pane_id":"w1:p2","revision":0,
       "scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":38},"tab_id":"w1:t1","workspace_id":"w1"},
      {"cwd":"/tmp/other","pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"},
      {"cwd":"/tmp/other/focused","pane_id":"w2:p2","tab_id":"w2:t1","workspace_id":"w2"},
      {"cwd":"relative/path","pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3"}
    ],
    "protocol":22,
    "tabs":[{"agent_status":"unknown","focused":false,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"}],
    "version":"0.9.1",
    "workspaces":[
      {"active_tab_id":"w1:t1","agent_status":"blocked","label":"project","number":1,"workspace_id":"w1",
       "worktree":{"checkout_path":"/tmp/project-worktree"}},
      {"label":"other","workspace_id":"w2"},
      {"label":"relative","workspace_id":"w3"}
    ]}
    """

    private func snapshot() throws -> HerdrSnapshot {
        try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    func testDecodesServerSnapshot() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.id), ["w1", "w2", "w3"])
        XCTAssertEqual(snapshot.workspaces[0].worktree?.checkoutPath, "/tmp/project-worktree")
        XCTAssertEqual(snapshot.focusedPaneID, "w2:p2")
        XCTAssertEqual(snapshot.layouts[0].panes[0].rect, HerdrRect(x: 0, y: 0, width: 120, height: 40))
        XCTAssertEqual(snapshot.tabs.first?.label, "1")
    }

    func testAgentRowsPreferLabelsAndSummaries() throws {
        let agents = try snapshot().agents
        XCTAssertEqual(agents[0].displayName, "Claude")
        XCTAssertEqual(agents[0].displayStatus, "Needs input")
        XCTAssertEqual(agents[0].detail, "Fix the tests")

        // Without a name, the title names the agent and is not repeated as detail.
        XCTAssertEqual(agents[1].displayName, "make test")
        XCTAssertEqual(agents[1].displayStatus, "working")
        XCTAssertNil(agents[1].detail)

        XCTAssertEqual(agents[2].displayName, "w2:p3")
        XCTAssertEqual(agents[2].displayStatus, "unknown")
    }

    /// Herdr's dots: finished agents keep a dot until seen (`done`), then show a ring (`idle`).
    func testAgentStatusMarksFollowHerdrDots() {
        for status in ["working", "blocked", "done"] {
            XCTAssertEqual(XherdrTheme.agentStatusMark(status), .dot, status)
        }
        XCTAssertEqual(XherdrTheme.agentStatusMark("idle"), .ring)
        XCTAssertEqual(XherdrTheme.agentStatusMark("unknown"), .faint)
        XCTAssertEqual(XherdrTheme.agentStatusMark(nil), .faint)
    }

    /// The Space's files come from its worktree, else the focused pane's directory, else any pane's.
    func testFileLocationFollowsWorktreeThenFocusedPane() throws {
        let snapshot = try snapshot()
        func root(_ id: String) -> String? {
            WorkspaceFiles.location(snapshot: snapshot, workspaceID: id, session: "test", machine: nil)?.root
        }
        XCTAssertEqual(root("w1"), "/tmp/project-worktree")
        XCTAssertEqual(root("w2"), "/tmp/other/focused")
        XCTAssertNil(root("w3"), "A relative directory cannot be a Space root")
        XCTAssertNil(root("missing"))
    }

    func testLocationPaths() {
        let location = WorkspaceFileLocation(machine: nil, session: "s", workspaceID: "w1", workspaceLabel: "p", root: "/tmp/p")
        XCTAssertEqual(location.absolutePath(""), "/tmp/p")
        XCTAssertEqual(location.absolutePath("a/b.txt"), "/tmp/p/a/b.txt")
        XCTAssertTrue(location.isLocal)
        XCTAssertEqual(location.machineLabel, "Local")
    }
}

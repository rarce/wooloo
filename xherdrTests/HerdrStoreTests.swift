import XCTest
@testable import xherdr

/// `HerdrStore` against a fake Herdr server in a temporary session directory. The endpoint
/// socket is absent, so input goes through the JSON fallback.
@MainActor
final class HerdrStoreTests: XCTestCase {
    /// The server's state; the responder reads and changes it on the server's threads.
    private final class State {
        let lock = NSLock()
        var workspaces: [[String: Any]] = [["workspace_id": "w1", "label": "project", "active_tab_id": "w1:t1"]]
        var tabs: [[String: Any]] = [["tab_id": "w1:t1", "workspace_id": "w1", "label": "1"],
                                     ["tab_id": "w1:t2", "workspace_id": "w1", "label": "2"]]
        var panes: [[String: Any]] = [["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1"],
                                      ["pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t1"],
                                      ["pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t2"]]
        var focus = ("w1", "w1:t1", "w1:p1")

        func snapshot() -> [String: Any] {
            ["result": ["snapshot": [
                "workspaces": workspaces, "tabs": tabs, "panes": panes, "agents": [], "layouts": [],
                "focused_workspace_id": focus.0, "focused_tab_id": focus.1, "focused_pane_id": focus.2
            ] as [String: Any]]]
        }
    }

    private let state = State()
    private var root: URL!
    private var savedRoot: URL!
    private var server: FakeHerdrServer!
    private var store: HerdrStore!

    override func setUp() async throws {
        // Short, so socket paths stay under the 104-byte limit.
        root = URL(fileURLWithPath: "/private/tmp/xherdr-tests/\(UUID().uuidString.prefix(8))")
        savedRoot = HerdrStore.sessionRoot
        HerdrStore.sessionRoot = root
        store = HerdrStore()
        server = try FakeHerdrServer(path: store.socketPath) { [state] method, params in
            state.lock.lock()
            defer { state.lock.unlock() }
            switch method {
            case "session.snapshot": return state.snapshot()
            case "pane.read": return ["result": ["read": ["text": "text of \(params["pane_id"] ?? "")"]]]
            case "workspace.create":
                state.workspaces.append(["workspace_id": "w2", "label": "new", "active_tab_id": "w2:t1"])
                state.tabs.append(["tab_id": "w2:t1", "workspace_id": "w2", "label": "1"])
                state.panes.append(["pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1"])
                return ["result": ["workspace": ["workspace_id": "w2"]]]
            case "pane.split":
                state.panes.append(["pane_id": "w1:p9", "workspace_id": "w1", "tab_id": "w1:t1"])
                state.focus = ("w1", "w1:t1", "w1:p9")
                return ["result": [:]]
            case "pane.send_input": return ["result": [:]]
            default: return ["error": ["message": "\(method) is not allowed here"]]
            }
        }
    }

    override func tearDown() async throws {
        store.stop()
        server.stop()
        HerdrStore.sessionRoot = savedRoot
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
    }

    private func connect() async {
        store.start()
        await waitUntil("connected") { store.isConnected }
    }

    func testConnectingSelectsTheServersFocus() async {
        await connect()
        XCTAssertEqual(store.selectedWorkspaceID, "w1")
        XCTAssertEqual(store.selectedTabID, "w1:t1")
        XCTAssertEqual(store.selectedPaneID, "w1:p1")
        // Without a live surface, the selected tab's panes are read as text.
        await waitUntil("pane text") { store.paneText["w1:p2"] == "text of w1:p2" }
    }

    func testEventsRefreshTheSnapshot() async {
        await connect()
        state.lock.lock()
        state.workspaces[0]["label"] = "renamed"
        state.lock.unlock()
        server.emit(["event": "workspace.renamed"])
        await waitUntil("renamed") { store.snapshot?.workspaces.first?.label == "renamed" }
    }

    func testTabsRememberTheirLastPane() async {
        await connect()
        store.select(paneID: "w1:p2")
        store.select(tabID: "w1:t2")
        XCTAssertEqual(store.selectedPaneID, "w1:p3")
        store.select(tabID: "w1:t1")
        XCTAssertEqual(store.selectedPaneID, "w1:p2")
        store.select(paneID: "w1:p3")
        XCTAssertEqual(store.selectedPaneID, "w1:p2", "A pane of another tab cannot be selected")
    }

    func testNewSpaceStartsFromTheSelectedOneAndIsSelected() async {
        await connect()
        store.createWorkspace()
        await waitUntil("new space selected") { store.selectedWorkspaceID == "w2" }
        XCTAssertEqual(store.selectedTabID, "w2:t1")
        XCTAssertEqual(store.selectedPaneID, "w2:p1")
        let request = server.requests.first { $0.method == "workspace.create" }
        XCTAssertEqual(request?.params["source_workspace_id"] as? String, "w1")
        XCTAssertEqual(request?.params["focus"] as? Bool, true)
    }

    func testSplitFollowsTheServersFocus() async {
        await connect()
        store.splitPane("right")
        await waitUntil("new pane selected") { store.selectedPaneID == "w1:p9" }
        let request = server.requests.first { $0.method == "pane.split" }
        XCTAssertEqual(request?.params["target_pane_id"] as? String, "w1:p1")
        XCTAssertEqual(request?.params["direction"] as? String, "right")
    }

    func testFailedActionsReportTheServersMessage() async {
        await connect()
        store.renameWorkspace("w1", to: "x")
        await waitUntil("action error") { store.actionError == "workspace.rename is not allowed here" }
        store.clearActionError()
        XCTAssertNil(store.actionError)
    }

    /// Without the endpoint, text and keys go through `pane.send_input` in order; mouse
    /// events have no JSON form and are dropped.
    func testInputFallsBackToJSON() async {
        await connect()
        store.sendText("ls", to: "w1:p1")
        store.sendMouse(HerdrMouseEvent(kind: .down(0), column: 0, row: 0, modifiers: 0, lines: 0), to: "w1:p1")
        store.sendKey("enter", to: "w1:p1")
        store.sendPaste("pasted", to: "w1:p2")
        await waitUntil("three inputs") { server.requests.filter { $0.method == "pane.send_input" }.count == 3 }
        let inputs = server.requests.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(inputs.map { $0.params["text"] as? String }, ["ls", nil, "pasted"])
        XCTAssertEqual(inputs.map { $0.params["keys"] as? [String] }, [nil, ["enter"], nil])
        XCTAssertEqual(inputs.map { $0.params["pane_id"] as? String }, ["w1:p1", "w1:p1", "w1:p2"])
        XCTAssertNil(store.inputError)
    }

    func testSessionNamesAreValidated() {
        store.connect(to: "../etc")
        XCTAssertEqual(store.sessionSelectionError, "Use letters, numbers, hyphens, or underscores")
        store.connect(to: " ")
        XCTAssertNotNil(store.sessionSelectionError)
    }

    func testAvailableSessionsListOnlyThoseWithASocket() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/empty"), withIntermediateDirectories: true)
        let named = (store.socketPath as NSString).deletingLastPathComponent.components(separatedBy: "/sessions/").last
        let sessions = HerdrStore.availableSessions()
        XCTAssertEqual(sessions.first, HerdrStore.defaultSessionName)
        XCTAssertFalse(sessions.contains("empty"))
        if let named, store.sessionName != HerdrStore.defaultSessionName { XCTAssertTrue(sessions.contains(named)) }
    }
}

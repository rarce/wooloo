import Combine
import XCTest
@testable import wooloo

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
        var layouts: [[String: Any]] = []
        var reload: [String: Any] = ["status": "applied"]
        var zoomedTabs: Set<String> = []
        /// When set, `pane.send_input` waits for it before answering, keeping the request in flight.
        var inputGate: DispatchSemaphore?
        var createGate: DispatchSemaphore?

        /// Changes the state from a test, which may be async.
        func update(_ change: (State) -> Void) {
            lock.withLock { change(self) }
        }

        func snapshot() -> [String: Any] {
            ["result": ["snapshot": [
                "workspaces": workspaces, "tabs": tabs, "panes": panes, "agents": [], "layouts": layouts,
                "focused_workspace_id": focus.0, "focused_tab_id": focus.1, "focused_pane_id": focus.2
            ] as [String: Any]]]
        }
    }

    private let state = State()
    private var root: URL!
    private var savedRoot: URL!
    private var savedLastSession: String?
    private var server: FakeHerdrServer!
    private var store: HerdrStore!

    override func setUp() async throws {
        // Short, so socket paths stay under the 104-byte limit.
        root = URL(fileURLWithPath: "/private/tmp/wooloo-tests/\(UUID().uuidString.prefix(8))")
        savedLastSession = UserDefaults.standard.string(forKey: "HerdrLastSession")
        UserDefaults.standard.set(HerdrStore.defaultSessionName, forKey: "HerdrLastSession")
        savedRoot = HerdrStore.sessionRoot
        HerdrStore.sessionRoot = root
        store = HerdrStore()
        server = try FakeHerdrServer(path: store.socketPath) { [state] method, params in
            if method == "pane.send_input", let gate = state.lock.withLock({ state.inputGate }) { gate.wait() }
            if method == "workspace.create", let gate = state.lock.withLock({ state.createGate }) { gate.wait() }
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
            case "worktree.open":
                // As Herdr 0.9.3 does: worktrees open from the repository's main checkout.
                if params["path"] as? String == "/r/gone" {
                    return ["error": ["code": "worktree_not_found", "message": "worktree path not found"]]
                }
                guard params["cwd"] as? String == "/r" else {
                    return ["error": ["code": "linked_worktree_source",
                                      "message": "New and open worktree actions start from the repo parent workspace."]]
                }
                state.workspaces.append(["workspace_id": "w3", "label": "feature", "active_tab_id": "w3:t1",
                                         "worktree": ["checkout_path": params["path"] ?? ""]])
                state.tabs.append(["tab_id": "w3:t1", "workspace_id": "w3", "label": "1"])
                state.panes.append(["pane_id": "w3:p1", "workspace_id": "w3", "tab_id": "w3:t1"])
                return ["result": ["already_open": false, "workspace": ["workspace_id": "w3"]]]
            case "pane.split":
                state.panes.append(["pane_id": "w1:p9", "workspace_id": "w1", "tab_id": "w1:t1"])
                state.focus = ("w1", "w1:t1", "w1:p9")
                return ["result": [:]]
            case "pane.send_input":
                if params["text"] as? String == "bad" { return ["error": ["message": "input rejected"]] }
                return ["result": [:]]
            case "pane.zoom", "workspace.close", "agent.rename": return ["result": [:]]
            case "tab.create":
                state.tabs.append(["tab_id": "w1:t3", "workspace_id": "w1", "label": "3"])
                state.panes.append(["pane_id": "w1:p4", "workspace_id": "w1", "tab_id": "w1:t3"])
                return ["result": ["tab": ["tab_id": "w1:t3"]]]
            case "pane.focus_direction":
                state.focus = ("w1", "w1:t1", "w1:p2")
                return ["result": [:]]
            case "server.reload_config": return ["result": state.reload]
            case "tab.move":
                // As Herdr 0.9.1 does: `insert_index` is a gap in the Space's current order.
                guard let id = params["tab_id"] as? String, let gap = params["insert_index"] as? Int,
                      let from = state.tabs.firstIndex(where: { $0["tab_id"] as? String == id }),
                      (0...state.tabs.count).contains(gap) else {
                    return ["error": ["message": "insert_index is out of bounds"]]
                }
                let tab = state.tabs.remove(at: from)
                state.tabs.insert(tab, at: gap > from ? gap - 1 : gap)
                return ["result": [:]]
            case "pane.move":
                // As Herdr 0.9.1 does: a pane moved into a zoomed tab is refused with `changed: false`;
                // otherwise it joins the tab, takes the focus, and its emptied tab closes.
                guard let id = params["pane_id"] as? String,
                      let destination = params["destination"] as? [String: Any],
                      let index = state.panes.firstIndex(where: { $0["pane_id"] as? String == id }),
                      let source = state.panes[index]["tab_id"] as? String else {
                    return ["error": ["message": "pane not found"]]
                }
                let tabID: String
                if destination["type"] as? String == "new_tab" {
                    tabID = "w1:t-new"
                    state.tabs.append(["tab_id": tabID, "workspace_id": "w1", "label": "detached"])
                } else if let id = destination["tab_id"] as? String {
                    tabID = id
                } else { return ["error": ["message": "missing destination"]] }
                if source == tabID {
                    return ["result": ["move_result": ["changed": false, "reason": "same_tab"]]]
                }
                if state.zoomedTabs.contains(tabID) {
                    return ["result": ["move_result": ["changed": false, "reason": "zoomed_tab"]]]
                }
                state.panes[index]["tab_id"] = tabID
                var closed: Any = NSNull()
                if !state.panes.contains(where: { $0["tab_id"] as? String == source }) {
                    state.tabs.removeAll { $0["tab_id"] as? String == source }
                    closed = source
                }
                state.focus = ("w1", tabID, id)
                return ["result": ["move_result": ["changed": true, "closed_tab_id": closed, "focused_pane_id": id]]]
            case "pane.swap":
                let found = [params["source_pane_id"], params["target_pane_id"]].allSatisfy { id in
                    state.panes.contains { $0["pane_id"] as? String == id as? String }
                }
                return ["result": ["swap": found ? ["changed": true] : ["changed": false, "reason": "not_found"]]]
            default: return ["error": ["message": "\(method) is not allowed here"]]
            }
        }
    }

    override func tearDown() async throws {
        store.stop()
        server.stop()
        HerdrStore.sessionRoot = savedRoot
        UserDefaults.standard.set(savedLastSession, forKey: "HerdrLastSession")
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
        state.update { $0.workspaces[0]["label"] = "renamed" }
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

    /// A worktree opens through Herdr in its own Space, which a second open only focuses.
    func testOpeningAWorktreeFocusesItsSpace() async {
        await connect()
        store.openWorktree("/r/feature", repository: "/r")
        await waitUntil("worktree space selected") { store.selectedWorkspaceID == "w3" }
        let request = server.requests.first { $0.method == "worktree.open" }
        XCTAssertEqual(request?.params["cwd"] as? String, "/r")
        XCTAssertEqual(request?.params["path"] as? String, "/r/feature")
        XCTAssertEqual(request?.params["focus"] as? Bool, true)

        store.select(workspaceID: "w1")
        store.openWorktree("/r/feature", repository: "/r")
        XCTAssertEqual(store.selectedWorkspaceID, "w3", "The open Space is selected at once")
        XCTAssertEqual(server.requests.filter { $0.method == "worktree.open" }.count, 1)
        XCTAssertTrue(server.requests.filter { $0.method == "workspace.create" }.isEmpty)
    }

    /// When Herdr will not open the worktree, such as in a bare repository, a plain Space opens there.
    func testOpeningAWorktreeFallsBackToAPlainSpace() async {
        await connect()
        store.openWorktree("/elsewhere/feature", repository: "/elsewhere")
        await waitUntil("new space selected") { store.selectedWorkspaceID == "w2" }
        let request = server.requests.first { $0.method == "workspace.create" }
        XCTAssertEqual(request?.params["cwd"] as? String, "/elsewhere/feature")
        XCTAssertEqual(request?.params["label"] as? String, "feature")
        XCTAssertNil(request?.params["source_workspace_id"])
        XCTAssertNil(store.actionError)
    }

    /// Other failures are reported rather than opening a second Space for the checkout.
    func testOpeningAWorktreeReportsOtherFailures() async {
        await connect()
        store.openWorktree("/r/gone", repository: "/r")
        await waitUntil("error reported") { store.actionError != nil }
        XCTAssertEqual(store.actionError, "worktree path not found")
        XCTAssertEqual(store.selectedWorkspaceID, "w1")
        XCTAssertTrue(server.requests.filter { $0.method == "workspace.create" }.isEmpty)
    }

    /// A pane that changed into a checkout does not make its Space that checkout's Space: Herdr decides.
    func testOpeningAWorktreeAsksHerdrWhenOnlyAPaneIsThere() async {
        state.update { $0.panes[0]["cwd"] = "/r/feature" }
        await connect()
        store.openWorktree("/r/feature", repository: "/r")
        await waitUntil("worktree space selected") { store.selectedWorkspaceID == "w3" }
        XCTAssertEqual(server.requests.filter { $0.method == "worktree.open" }.count, 1)
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

    func testNewTabIsCreatedInTheSelectedSpaceAndSelected() async {
        await connect()
        store.createTab(cwd: "/private/tmp")
        await waitUntil("new tab selected") { store.selectedTabID == "w1:t3" }
        XCTAssertEqual(store.selectedPaneID, "w1:p4")
        let request = server.requests.first { $0.method == "tab.create" }
        XCTAssertEqual(request?.params["workspace_id"] as? String, "w1")
        XCTAssertEqual(request?.params["cwd"] as? String, "/private/tmp")
    }

    /// The tab moves at once, `tab.move` gets the gap it goes into, and Herdr's order follows.
    func testMovingATabSendsTheGapAndShowsTheNewOrderAtOnce() async {
        await connect()
        state.update { $0.tabs.append(["tab_id": "w1:t3", "workspace_id": "w1", "label": "3"]) }
        server.emit(["event": "tab.created"])
        await waitUntil("third tab") { store.selectedTabs.count == 3 }

        store.moveTab("w1:t1", to: 3)
        XCTAssertEqual(store.selectedTabs.map(\.tabID), ["w1:t2", "w1:t3", "w1:t1"], "Shown before Herdr answers")
        await waitUntil("move requested") { server.requests.contains { $0.method == "tab.move" } }
        let request = server.requests.first { $0.method == "tab.move" }
        XCTAssertEqual(request?.params["tab_id"] as? String, "w1:t1")
        XCTAssertEqual(request?.params["insert_index"] as? Int, 3)
        XCTAssertEqual(request?.params.count, 2)

        await waitUntil("Herdr's order") { store.snapshot?.tabs.map(\.tabID) == ["w1:t2", "w1:t3", "w1:t1"] }
        store.moveTab("w1:t3", to: 1)
        XCTAssertEqual(store.selectedTabs.map(\.tabID), ["w1:t2", "w1:t3", "w1:t1"], "A move in place does nothing")
        XCTAssertEqual(server.requests.filter { $0.method == "tab.move" }.count, 1, "A move in place is not sent")

        store.moveTab("w1:t1", to: 0)
        await waitUntil("moved first") { state.lock.withLock { state.tabs.first?["tab_id"] as? String } == "w1:t1" }
        await waitUntil("snapshot read") { store.selectedTabs.map(\.tabID) == ["w1:t1", "w1:t2", "w1:t3"] }
        XCTAssertEqual(store.selectedTabID, "w1:t1", "The selection stays on its tab")
        XCTAssertNil(store.actionError)
    }

    /// A tab dropped on the right of a pane is one `pane.move` into the selected tab; Herdr
    /// closes the emptied tab and the selected tab stays, with the moved pane selected.
    func testDroppingATabOnAPaneMovesItsPaneNextToIt() async {
        await connect()
        XCTAssertTrue(store.canSplit(tabID: "w1:t2"))
        XCTAssertFalse(store.canSplit(tabID: "w1:t1"), "Not the selected tab")
        XCTAssertTrue(store.splitTab("w1:t2", nextTo: "w1:p2", edge: .right))
        await waitUntil("pane moved") { store.selectedPanes.map(\.paneID) == ["w1:p1", "w1:p2", "w1:p3"] }
        await waitUntil("moved pane selected") { store.selectedPaneID == "w1:p3" }
        XCTAssertEqual(store.selectedTabID, "w1:t1")
        XCTAssertEqual(store.selectedTabs.map(\.tabID), ["w1:t1"], "Herdr closed the emptied tab")
        let moves = server.requests.filter { $0.method == "pane.move" }
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.params["pane_id"] as? String, "w1:p3")
        XCTAssertEqual(moves.first?.params["focus"] as? Bool, true)
        let destination = moves.first?.params["destination"] as? [String: Any]
        XCTAssertEqual(destination?["type"] as? String, "tab")
        XCTAssertEqual(destination?["tab_id"] as? String, "w1:t1")
        XCTAssertEqual(destination?["split"] as? String, "right")
        XCTAssertEqual(destination?["target_pane_id"] as? String, "w1:p2")
        XCTAssertFalse(server.requests.contains { $0.method == "pane.swap" || $0.method == "tab.close" })
        XCTAssertNil(store.actionError)
    }

    /// Herdr splits only right and down, so a drop on the top splits down, then swaps the pair.
    func testDroppingATabOnTheTopSplitsDownAndSwaps() async {
        await connect()
        XCTAssertTrue(store.splitTab("w1:t2", nextTo: "w1:p1", edge: .top))
        await waitUntil("swap requested") { server.requests.contains { $0.method == "pane.swap" } }
        await waitUntil("moved pane selected") { store.selectedPaneID == "w1:p3" }
        let methods = server.requests.map(\.method).filter { $0.hasPrefix("pane.") }
        XCTAssertEqual(methods, ["pane.move", "pane.swap"])
        let move = server.requests.first { $0.method == "pane.move" }
        XCTAssertEqual((move?.params["destination"] as? [String: Any])?["split"] as? String, "down")
        let swap = server.requests.first { $0.method == "pane.swap" }
        XCTAssertEqual(swap?.params["source_pane_id"] as? String, "w1:p3")
        XCTAssertEqual(swap?.params["target_pane_id"] as? String, "w1:p1")
        XCTAssertEqual(swap?.params.count, 2)
        XCTAssertNil(store.actionError)
    }

    func testMovingWithinLayoutDetachesThenReinsertsAndSwaps() async {
        await connect()
        XCTAssertTrue(store.movePane("w1:p1", nextTo: "w1:p2", edge: .left))
        await waitUntil("swap completed") { server.requests.contains { $0.method == "pane.swap" } }
        await waitUntil("selected moved pane") { store.selectedPaneID == "w1:p1" && store.snapshot?.tabs.count == 2 }
        let moves = server.requests.filter { $0.method == "pane.move" }
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual((moves.first?.params["destination"] as? [String: Any])?["type"] as? String, "new_tab")
        XCTAssertEqual((moves.last?.params["destination"] as? [String: Any])?["target_pane_id"] as? String, "w1:p2")
        XCTAssertEqual(store.selectedTabID, "w1:t1")
        XCTAssertNil(store.actionError)
    }

    func testDetachingPaneSelectsItsOwnTabAndKeepsOtherPanes() async {
        await connect()
        XCTAssertTrue(store.detachPane("w1:p2"))
        await waitUntil("detached tab selected") { store.selectedTabID == "w1:t-new" }
        XCTAssertEqual(store.selectedPaneID, "w1:p2")
        XCTAssertEqual(store.snapshot?.panes.first { $0.paneID == "w1:p1" }?.tabID, "w1:t1")
        XCTAssertFalse(store.detachPane("w1:p2"), "Already has its own tab")
        XCTAssertNil(store.actionError)
    }

    func testFailedReinsertionKeepsDetachedTerminalReachable() async {
        await connect()
        // Simulate the destination becoming zoomed after the client's last snapshot.
        state.update { $0.zoomedTabs = ["w1:t1"] }
        XCTAssertTrue(store.movePane("w1:p1", nextTo: "w1:p2", edge: .top))
        await waitUntil("reinsertion refused") { store.actionError == "Herdr could not move the pane: zoomed tab" }
        XCTAssertEqual(store.selectedTabID, "w1:t-new")
        XCTAssertEqual(store.selectedPaneID, "w1:p1")
        XCTAssertEqual(store.snapshot?.panes.count, 3, "No terminal is lost after a partial move")
        XCTAssertFalse(server.requests.contains { $0.method == "pane.swap" })
    }

    func testRepositionRejectsSelfMissingAndZoomedTargets() async {
        await connect()
        XCTAssertFalse(store.movePane("w1:p1", nextTo: "w1:p1", edge: .right))
        XCTAssertFalse(store.movePane("missing", nextTo: "w1:p1", edge: .right))
        state.update { $0.layouts = [["tab_id": "w1:t1", "zoomed": true, "panes": [],
                                      "area": ["x": 0, "y": 0, "width": 80, "height": 24]]] }
        server.emit(["event": "layout.updated"])
        await waitUntil("zoom snapshot") { store.snapshot?.layouts.first?.zoomed == true }
        XCTAssertFalse(store.movePane("w1:p1", nextTo: "w1:p2", edge: .bottom))
        XCTAssertFalse(server.requests.contains { $0.method == "pane.move" })
    }

    func testDropsThatCannotMoveSendNothing() async {
        await connect()
        state.update { $0.panes.append(["pane_id": "w1:p4", "workspace_id": "w1", "tab_id": "w1:t2"]) }
        server.emit(["event": "pane.created"])
        await waitUntil("second pane") { store.snapshot?.panes.count == 4 }
        XCTAssertFalse(store.canSplit(tabID: "w1:t2"), "Only single-pane tabs move")
        XCTAssertFalse(store.splitTab("w1:t2", nextTo: "w1:p1", edge: .right))
        XCTAssertFalse(store.splitTab("w1:t1", nextTo: "w1:p1", edge: .right), "Not onto itself")
        XCTAssertFalse(store.splitTab("w1:t9", nextTo: "w1:p1", edge: .right))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(server.requests.contains { $0.method == "pane.move" })
    }

    /// A move Herdr refuses, such as into a zoomed tab, reports why and sends no swap.
    func testRefusedMovesReportHerdrsReason() async {
        await connect()
        state.update { $0.zoomedTabs = ["w1:t1"] }
        XCTAssertTrue(store.splitTab("w1:t2", nextTo: "w1:p1", edge: .left))
        await waitUntil("error") { store.actionError == "Herdr could not move the pane: zoomed tab" }
        XCTAssertFalse(server.requests.contains { $0.method == "pane.swap" })
        XCTAssertEqual(store.selectedTabID, "w1:t1")
    }

    func testMovingTabsKeepsOtherSpacesInPlace() throws {
        let json = """
        {"workspaces": [], "panes": [], "agents": [], "layouts": [], "tabs": [
          {"tab_id": "w1:t1", "workspace_id": "w1", "label": "a"}, {"tab_id": "w2:t1", "workspace_id": "w2", "label": "x"},
          {"tab_id": "w1:t2", "workspace_id": "w1", "label": "b"}, {"tab_id": "w1:t3", "workspace_id": "w1", "label": "c"}]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.movingTab("w1:t3", to: 0)?.tabs.map(\.tabID), ["w1:t3", "w2:t1", "w1:t1", "w1:t2"])
        XCTAssertEqual(snapshot.movingTab("w1:t1", to: 2)?.tabs.map(\.tabID), ["w1:t2", "w2:t1", "w1:t1", "w1:t3"])
        XCTAssertNil(snapshot.movingTab("w1:t1", to: 1), "Moving into its own gap")
        XCTAssertNil(snapshot.movingTab("w1:t1", to: 4), "Past the last gap")
        XCTAssertNil(snapshot.movingTab("missing", to: 0))
    }

    func testFocusMovesFollowTheServer() async {
        await connect()
        store.focusPane("right")
        await waitUntil("focused pane") { store.selectedPaneID == "w1:p2" }
        let request = server.requests.first { $0.method == "pane.focus_direction" }
        XCTAssertEqual(request?.params["pane_id"] as? String, "w1:p1")
        XCTAssertEqual(request?.params["direction"] as? String, "right")
    }

    /// A reload that Herdr does not apply reports its status and diagnostics.
    func testConfigReloadReportsRejections() async {
        await connect()
        store.reloadConfig()
        await waitUntil("reload requested") { server.requests.contains { $0.method == "server.reload_config" } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(store.actionError)

        state.update { $0.reload = ["status": "rejected", "diagnostics": ["unknown key `foo`", "line 3"]] }
        store.reloadConfig()
        await waitUntil("reload error") { store.actionError == "Herdr reload: rejected. unknown key `foo`\nline 3" }
    }

    /// Switching session resets the selection, remembers the name and connects to the new socket.
    func testConnectingToAnotherSessionStartsOver() async throws {
        let key = "HerdrLastSession"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        await connect()
        let other = try FakeHerdrServer(path: root.appendingPathComponent("sessions/other/herdr.sock").path) { [state] method, _ in
            state.lock.lock()
            defer { state.lock.unlock() }
            return method == "session.snapshot" ? state.snapshot() : ["result": [:]]
        }
        defer { other.stop() }
        store.connect(to: " other ")
        XCTAssertEqual(store.sessionName, "other")
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.selectedPaneID)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "other")
        await waitUntil("connected to other") { store.isConnected }
        XCTAssertTrue(other.requests.contains { $0.method == "session.snapshot" })
    }

    /// Clicks, split drags and Herdr events that change nothing must not publish: any write to a
    /// published property, even of the same value, makes SwiftUI update the whole window.
    func testRepeatedEventsThatChangeNothingDoNotPublish() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        // The surface shows one of the tab's two panes, so the other is still read as text once a second.
        await waitUntil("pane text") { store.paneText.count == 2 }
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        for _ in 0..<20 {
            store.select(paneID: "w1:p1")
            store.setSplitRatio(path: [true], ratio: 0.4)
            store.sendMouse(HerdrMouseEvent(kind: .scrollUp, column: 1, row: 1, modifiers: 0, lines: 1), to: "w1:p1")
        }
        let snapshots = server.requests.filter { $0.method == "session.snapshot" }.count
        for _ in 0..<5 { server.emit(["event": "pane.updated"]) }
        await waitUntil("snapshots read") { server.requests.filter { $0.method == "session.snapshot" }.count >= snapshots + 5 }
        // The pane text poll runs once a second; let it and the snapshots reach the main thread.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(published, 0)
        XCTAssertTrue(Self.requests(in: endpoint).contains { $0.method == "layout.set_split_ratio" })
        XCTAssertNil(store.surfaceError)

        state.update { $0.workspaces[0]["label"] = "renamed" }
        server.emit(["event": "workspace.renamed"])
        await waitUntil("renamed") { store.snapshot?.workspaces.first?.label == "renamed" }
        XCTAssertGreaterThan(published, 0, "A changed snapshot is still published")
    }

    /// Herdr answers every pane.focus with a complete surface, so clicks in the pane it already
    /// focuses send none; a click in another pane still focuses that one.
    func testClicksInTheFocusedPaneDoNotFocusItAgain() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        let focuses = { Self.requests(in: endpoint).filter { $0.method == "pane.focus" }.compactMap { $0.params["pane_id"] as? String } }
        let before = focuses()
        for _ in 0..<10 { store.select(paneID: "w1:p1") }
        store.select(paneID: "w1:p2")
        await waitUntil("other pane focused") { focuses().count > before.count }
        XCTAssertEqual(Array(focuses().dropFirst(before.count)), ["w1:p2"])
        XCTAssertEqual(store.selectedPaneID, "w1:p2")
    }

    /// A pane.focus emits no event that refreshes the snapshot, so its focus still names the
    /// first pane after a click in the second; a click back in the first must still focus it.
    func testClickingBackInThePreviousPaneFocusesItAgain() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surface?.focusedPaneID == "w1:p1" }
        let focuses = { Self.requests(in: endpoint).filter { $0.method == "pane.focus" }.compactMap { $0.params["pane_id"] as? String } }
        let before = focuses().count
        store.select(paneID: "w1:p2")
        await waitUntil("second pane focused") { focuses().count == before + 1 }
        // Herdr answers with a surface that focuses the second pane; the snapshot is unchanged.
        var focusedSecond = SurfaceModel(width: 4, height: 2)
        focusedSecond.paneID = "w1:p2"
        focusedSecond.revision = 2
        endpoint.send(focusedSecond.surfaceFrame())
        await waitUntil("surface focuses the second pane") { store.surface?.focusedPaneID == "w1:p2" }
        XCTAssertEqual(store.snapshot?.focusedPaneID, "w1:p1")

        store.select(paneID: "w1:p1")
        await waitUntil("first pane focused again") { focuses().count == before + 2 }
        XCTAssertEqual(Array(focuses().dropFirst(before)), ["w1:p2", "w1:p1"])
        XCTAssertEqual(store.selectedPaneID, "w1:p1")
    }

    /// Until Herdr's surface answers a pane.focus, the last surface still names the pane left
    /// behind; a click back there before the answer still focuses it, and repeated clicks don't.
    func testClicksBeforeHerdrAnswersAFocusFollowTheLastRequest() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surface?.focusedPaneID == "w1:p1" }
        let focuses = { Self.requests(in: endpoint).filter { $0.method == "pane.focus" }.compactMap { $0.params["pane_id"] as? String } }
        let before = focuses().count
        for pane in ["w1:p2", "w1:p1", "w1:p1", "w1:p2"] { store.select(paneID: pane) }
        await waitUntil("focuses sent") { focuses().count >= before + 3 }
        XCTAssertEqual(Array(focuses().dropFirst(before)), ["w1:p2", "w1:p1", "w1:p2"])

        // Once a surface shows the pane focused, it decides again.
        var focusedSecond = SurfaceModel(width: 4, height: 2)
        focusedSecond.paneID = "w1:p2"
        focusedSecond.revision = 2
        endpoint.send(focusedSecond.surfaceFrame())
        await waitUntil("surface focuses the second pane") { store.surface?.focusedPaneID == "w1:p2" }
        store.select(paneID: "w1:p2")
        store.select(paneID: "w1:p1")
        await waitUntil("first pane focused") { focuses().count >= before + 4 }
        XCTAssertEqual(Array(focuses().dropFirst(before)), ["w1:p2", "w1:p1", "w1:p2", "w1:p1"])
    }

    /// A tab switch keeps the terminal view on the previous tab's surface until Herdr sends the
    /// new tab's, instead of falling back to the pane text and building a new view for it; if
    /// none comes, the window falls back after a grace period.
    func testTabSwitchKeepsTheLiveSurfaceUntilTheNewTabsArrives() async throws {
        state.update { $0.panes.removeAll { $0["pane_id"] as? String == "w1:p2" } }
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        let grace = HerdrStore.surfaceSwitchGrace
        defer { HerdrStore.surfaceSwitchGrace = grace }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        XCTAssertTrue(store.showsLiveSurface)

        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        store.select(tabID: "w1:t2")
        XCTAssertTrue(store.showsLiveSurface, "the previous tab's surface stays until the new one arrives")
        XCTAssertEqual(store.selectedTabID, "w1:t2", "the store selects the tab at once")
        XCTAssertEqual(published, 0, "the window learns of the switch once the new tab's surface is drawn")
        var other = SurfaceModel(width: 4, height: 2)
        other.paneID = "w1:p3"
        other.revision = 2
        endpoint.send(other.surfaceFrame())
        await waitUntil("new tab shown") { store.surfaceLayout?.paneIDs == ["w1:p3"] }
        XCTAssertTrue(store.showsLiveSurface)
        await waitUntil("selection published") { published == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published, 1, "one publish for the whole switch: the selection, after its surface")

        // Without a surface, the selection is published after its wait and the fallback after
        // the grace period, far apart so the order holds on a loaded machine.
        let wait = HerdrStore.selectionPublishWait
        defer { HerdrStore.selectionPublishWait = wait }
        HerdrStore.selectionPublishWait = .milliseconds(10)
        HerdrStore.surfaceSwitchGrace = .milliseconds(400)
        store.select(tabID: "w1:t1")
        XCTAssertTrue(store.showsLiveSurface)
        let selected = published
        await waitUntil("selection published without a surface") { published == selected + 1 }
        XCTAssertTrue(store.showsLiveSurface, "the previous surface stays through the grace period")
        await waitUntil("fell back to the pane text") { !store.showsLiveSurface }
        XCTAssertEqual(published, selected + 2, "the fallback is published")
    }

    /// Keys typed while the window still shows the previous tab go to the tab switched to.
    func testInputDuringATabSwitchGoesToTheNewPane() async throws {
        store.requiresSurfaceForInput = true
        state.update { $0.panes.removeAll { $0["pane_id"] as? String == "w1:p2" } }
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        store.select(paneID: "w1:p1")
        store.select(tabID: "w1:t2")
        store.sendText("x", to: "w1:p1")
        // A mouse event belongs to the pane under the pointer, whose surface is still shown.
        let release = HerdrMouseEvent(kind: .up(0), column: 1, row: 1, modifiers: 0, lines: 1)
        store.sendMouse(release, to: "w1:p1")
        await waitUntil("input sent") { endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .mouse(release))!) }
        XCTAssertTrue(endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p3", event: .text("x"))!))
        XCTAssertFalse(endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("x"))!))
        XCTAssertFalse(endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p3", event: .mouse(release))!))
    }

    /// Another change to the selection while a tab switch waits, such as a click on a pane's
    /// header, is published at once, together with the switch.
    func testOtherSelectionChangesDuringATabSwitchPublishAtOnce() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        store.select(tabID: "w1:t2")
        XCTAssertEqual(published, 0)
        store.selectedPaneID = "w1:p3"
        XCTAssertEqual(published, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published, 1, "the switch's own publish is not sent again")
        store.select(paneID: "w1:p3")
        XCTAssertEqual(published, 1, "selecting the same pane again publishes nothing")
    }

    /// Mouse events are input too, but a surface after a wheel event is not their answer:
    /// with mouse reporting and streaming output, every surface would be drawn at once.
    func testMouseInputDoesNotMarkTheNextSurfaceAsAnAnswer() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        var urgent: [Bool] = []
        let owner = NSObject()
        store.surfaceFeed.observe(owner) { _, answers in urgent.append(answers) }
        let wheel = HerdrMouseEvent(kind: .scrollDown, column: 1, row: 1, modifiers: 0, lines: 1)
        store.sendMouse(wheel, to: "w1:p1")
        await waitUntil("wheel sent") { endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .mouse(wheel))!) }
        var next = SurfaceModel(width: 4, height: 2)
        next.revision = 2
        endpoint.send(next.patchFrame(baseRevision: 1, rows: [0]))
        await waitUntil("surface") { !urgent.isEmpty }
        XCTAssertEqual(urgent, [false])
        store.sendText("a", to: "w1:p1")
        await waitUntil("text sent") { endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("a"))!) }
        next.revision = 3
        endpoint.send(next.patchFrame(baseRevision: 2, rows: [0]))
        await waitUntil("echo") { urgent.count == 2 }
        XCTAssertEqual(urgent, [false, true])
    }

    /// A split drag changes only the snapshot's layouts, which the window reads only for panes
    /// the live surface does not show: then they are kept without publishing.
    func testLayoutOnlyChangesUnderTheLiveSurfaceDoNotPublish() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        func layout(width: Int) -> [[String: Any]] {
            [["tab_id": "w1:t1", "area": ["x": 0, "y": 0, "width": 80, "height": 24],
              "panes": [["pane_id": "w1:p1", "rect": ["x": 0, "y": 0, "width": width, "height": 24]]]]]
        }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        // The tab has a pane the surface does not show yet: its layout is still published.
        state.update { $0.layouts = layout(width: 40) }
        server.emit(["event": "layout.changed"])
        await waitUntil("layout published") { store.snapshot?.layouts.first?.panes.first?.rect.width == 40 }

        state.update { $0.panes.removeAll { $0["pane_id"] as? String == "w1:p2" } }
        server.emit(["event": "pane.closed"])
        await waitUntil("pane closed") { store.selectedPanes.map(\.paneID) == ["w1:p1"] }
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        for width in [50, 60, 70] {
            state.update { $0.layouts = layout(width: width) }
            server.emit(["event": "layout.changed"])
            await waitUntil("layout \(width) kept") { store.snapshot?.layouts.first?.panes.first?.rect.width == width }
        }
        XCTAssertEqual(published, 0)

        state.update { $0.workspaces[0]["label"] = "renamed" }
        server.emit(["event": "workspace.renamed"])
        await waitUntil("renamed") { store.snapshot?.workspaces.first?.label == "renamed" }
        XCTAssertEqual(published, 1, "Other changes still publish")
    }

    func testSplitResizeNeedsTheEndpoint() async {
        await connect()
        store.setSplitRatio(path: [true], ratio: 0.5)
        XCTAssertEqual(store.surfaceError, "Herdr split resize is unavailable")
    }

    /// With the binary endpoint, the store shows its surfaces and sends input, focus, resize
    /// and split ratios through it instead of JSON requests.
    func testEndpointCarriesSurfacesAndClientMessages() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        XCTAssertEqual(store.surface?.width, 4)

        store.sendText("ls", to: "w1:p1")
        await waitUntil("input sent") { endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("ls"))!) }
        store.resizeSurface(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        store.resizeSurface(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        store.resizeSurface(cols: 2000, rows: 30, cellWidth: 8, cellHeight: 16)
        store.select(tabID: "w1:t2")
        store.setSplitRatio(path: [false, true], ratio: 0.25)
        await waitUntil("split ratio sent") { Self.requests(in: endpoint).contains { $0.method == "layout.set_split_ratio" } }

        XCTAssertEqual(endpoint.received.filter { $0.first == 12 }.map(Array.init), [[12, 8, 16, 100, 30, 0]],
                       "Repeated and invalid sizes are not sent")
        let requests = Self.requests(in: endpoint)
        XCTAssertTrue(requests.contains { $0.method == "tab.focus" && $0.params["tab_id"] as? String == "w1:t2" })
        XCTAssertTrue(requests.contains { $0.method == "pane.focus" && $0.params["pane_id"] as? String == "w1:p3" })
        let ratio = try XCTUnwrap(requests.first { $0.method == "layout.set_split_ratio" })
        XCTAssertEqual(ratio.params["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(ratio.params["path"] as? [Bool], [false, true])
        XCTAssertEqual(ratio.params["ratio"] as? Double, 0.25)
        XCTAssertNil(store.surfaceError)
        XCTAssertFalse(server.requests.contains { $0.method == "pane.send_input" }, "Input skipped the JSON fallback")
    }

    func testZoomTargetsTheSelectedPane() async {
        store.zoomPane()
        await connect()
        XCTAssertFalse(server.requests.contains { $0.method == "pane.zoom" }, "Nothing is zoomed without a selected pane")
        store.select(paneID: "w1:p2")
        store.zoomPane()
        await waitUntil("zoom requested") { server.requests.contains { $0.method == "pane.zoom" } }
        let requests = server.requests.filter { $0.method == "pane.zoom" }
        XCTAssertEqual(requests.map { $0.params["pane_id"] as? String }, ["w1:p2"])
        XCTAssertEqual(requests.first?.params.count, 1)
        XCTAssertNil(store.actionError)
    }

    func testClosingASpaceSendsItsID() async {
        await connect()
        store.closeWorkspace("w1")
        await waitUntil("close requested") { server.requests.contains { $0.method == "workspace.close" } }
        let request = server.requests.first { $0.method == "workspace.close" }
        XCTAssertEqual(request?.params["workspace_id"] as? String, "w1")
        XCTAssertEqual(request?.params.count, 1)
        XCTAssertNil(store.actionError)
    }

    /// A name renames the pane's agent; nil sends a JSON null, which restores the detected name.
    func testRenamingAnAgentSendsTheNameOrNull() async {
        await connect()
        store.renameAgent("w1:p2", to: "reviewer")
        await waitUntil("rename requested") { server.requests.contains { $0.method == "agent.rename" } }
        store.renameAgent("w1:p2", to: nil)
        await waitUntil("reset requested") { server.requests.filter { $0.method == "agent.rename" }.count == 2 }
        let requests = server.requests.filter { $0.method == "agent.rename" }
        XCTAssertEqual(requests.map { $0.params["target"] as? String }, ["w1:p2", "w1:p2"])
        XCTAssertEqual(requests[0].params["name"] as? String, "reviewer")
        XCTAssertTrue(requests[1].params["name"] is NSNull, "A nil name is sent as null, not omitted")
        XCTAssertNil(store.actionError)
    }

    /// Input sent while a JSON request is in flight waits in the queue and follows in order;
    /// once the queue drains, later input starts a new send.
    func testInputQueuedWhileSendingFollowsInOrder() async {
        await connect()
        let gate = DispatchSemaphore(value: 0)
        state.update { $0.inputGate = gate }
        store.sendText("first", to: "w1:p1")
        await waitUntil("first input in flight") { server.requests.contains { $0.method == "pane.send_input" } }
        store.sendKey("enter", to: "w1:p1")
        store.sendPaste("third", to: "w1:p2")
        store.sendText("", to: "w1:p1")
        store.sendPaste("", to: "w1:p1")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(server.requests.filter { $0.method == "pane.send_input" }.count, 1, "Queued input waits for the request")
        state.update { $0.inputGate = nil }
        gate.signal()
        await waitUntil("queued inputs sent") { server.requests.filter { $0.method == "pane.send_input" }.count == 3 }

        store.sendText("later", to: "w1:p1")
        await waitUntil("later input sent") { server.requests.filter { $0.method == "pane.send_input" }.count == 4 }
        let inputs = server.requests.filter { $0.method == "pane.send_input" }
        XCTAssertEqual(inputs.map { $0.params["text"] as? String }, ["first", nil, "third", "later"])
        XCTAssertEqual(inputs.map { $0.params["keys"] as? [String] }, [nil, ["enter"], nil, nil])
        XCTAssertEqual(inputs.map { $0.params["pane_id"] as? String }, ["w1:p1", "w1:p1", "w1:p2", "w1:p1"])
        await waitUntil("last reply handled") { store.inputError == nil }
    }

    /// A rejected JSON input reports Herdr's message; the next accepted one clears it.
    func testRejectedJSONInputReportsTheErrorUntilInputSucceeds() async {
        await connect()
        store.sendText("bad", to: "w1:p1")
        await waitUntil("input error") { store.inputError == "input rejected" }
        store.sendText("good", to: "w1:p1")
        await waitUntil("input error cleared") { store.inputError == nil }
        XCTAssertEqual(server.requests.filter { $0.method == "pane.send_input" }.map { $0.params["text"] as? String },
                       ["bad", "good"])
    }

    /// Input the endpoint cannot encode reports a failure; the next input sent through it clears it.
    func testEndpointInputFailureIsReportedUntilInputSucceeds() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surfaceLayout?.paneIDs == ["w1:p1"] }
        store.sendKey("ctrl+", to: "w1:p1")
        await waitUntil("input error") { store.inputError == "Herdr endpoint input failed; reconnecting" }
        store.sendText("ls", to: "w1:p1")
        await waitUntil("input error cleared") { store.inputError == nil }
        XCTAssertTrue(endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("ls"))!))
        XCTAssertFalse(server.requests.contains { $0.method == "pane.send_input" }, "Input skipped the JSON fallback")
    }

    /// When the endpoint becomes ready while no tab is selected, the store focuses the selected space.
    func testEndpointFocusesTheSpaceWhenNoTabIsSelected() async throws {
        state.update {
            $0.workspaces = [["workspace_id": "w1", "label": "project"]]
            $0.tabs = []
            $0.panes = []
        }
        await connect()
        XCTAssertEqual(store.selectedWorkspaceID, "w1")
        XCTAssertNil(store.selectedTabID)
        // The endpoint appears after the snapshot, so the store's next attempt finds the selection in place.
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath, afterHello: [])
        defer { endpoint.stop() }
        for _ in 0..<500 where !Self.requests(in: endpoint).contains(where: { $0.method == "workspace.focus" }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = Self.requests(in: endpoint)
        let focus = try XCTUnwrap(requests.first { $0.method == "workspace.focus" })
        XCTAssertEqual(focus.params["workspace_id"] as? String, "w1")
        XCTAssertFalse(requests.contains { $0.method == "tab.focus" || $0.method == "pane.focus" })
    }

    func testEventLossEOFResubscribesBeforeTakingAnAuthoritativeSnapshot() async {
        await connect()
        XCTAssertEqual(store.snapshot?.workspaces.first?.label, "project")
        state.update { $0.workspaces[0]["label"] = "changed during the gap" }
        server.loseEvents()
        // No workspace event announces this change: only the post-ack snapshot can recover it.
        await waitUntil("resubscribed and caught up") {
            store.snapshot?.workspaces.first?.label == "changed during the gap" && store.errorMessage == nil
        }
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 2)
        let methods = server.requests.map(\.method)
        let secondSubscription = methods.lastIndex(of: "events.subscribe")!
        XCTAssertTrue(methods.dropFirst(secondSubscription + 1).contains("session.snapshot"))
        XCTAssertTrue(store.isConnected)
    }

    func testStalledSurfaceClearsProjectionFallsBackAndRestoresLatestFocusAndSize() async throws {
        store = HerdrStore(endpointTimeouts: HerdrEndpointTimeouts(frame: .milliseconds(400)))
        var snapshot = AgentViewFixture.snapshot([AgentViewFixture.agent("w1:p1")])
        snapshot["workspaces"] = [["workspace_id": "w1", "git_ahead_behind": [2, 1]]]
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               welcome: ["capabilities": ["agent_view_projection"]], afterHello: [
            FakeSurfaceEndpoint.control("shell.snapshot.v1", String(decoding: try AgentViewFixture.data(snapshot), as: UTF8.self)),
            SurfaceModel(width: 4, height: 2).surfaceFrame()
        ])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface and projection") { store.surface != nil && store.agentViewState != nil }
        XCTAssertEqual(store.workspaceGitStatuses["w1"]?.ahead, 2)
        store.select(tabID: "w1:t2")
        store.resizeSurface(cols: 100, rows: 30, cellWidth: 9, cellHeight: 18)
        endpoint.sendPartialHeader()
        await waitUntil("stale state cleared") {
            store.surface == nil && store.agentViewState == nil && store.workspaceGitStatuses.isEmpty
                && store.surfaceError != nil
        }
        await waitUntil("text fallback resumed") { store.paneText["w1:p3"] != nil }
        endpoint.stop()
        var next = SurfaceModel(width: 100, height: 30)
        next.paneID = "w1:p3"
        let replacement = try FakeSurfaceEndpoint(path: store.clientSocketPath, afterHello: [next.surfaceFrame()])
        defer { replacement.stop() }
        await waitUntil("fresh surface") { store.surface?.paneIDs == ["w1:p3"] && store.surfaceError == nil }
        await waitUntil("selection restored") { Self.requests(in: replacement).contains { $0.method == "pane.focus" } }
        XCTAssertEqual(store.selectedTabID, "w1:t2")
        XCTAssertEqual(store.selectedPaneID, "w1:p3")
        let requests = Self.requests(in: replacement)
        XCTAssertTrue(requests.contains { $0.method == "tab.focus" && $0.params["tab_id"] as? String == "w1:t2" })
        XCTAssertTrue(requests.contains { $0.method == "pane.focus" && $0.params["pane_id"] as? String == "w1:p3" })
        var hello = SurfaceReaderProbe(try XCTUnwrap(replacement.received.first))
        _ = hello.number(); _ = hello.string()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.string().utf8)) as? [String: Any])
        XCTAssertEqual(json["surface_size"] as? [String: Int], ["cols": 100, "rows": 30])
        XCTAssertEqual(json["cell_width_px"] as? Int, 9)
        XCTAssertEqual(json["cell_height_px"] as? Int, 18)
    }

    func testResizeDuringStartupIsSentAfterTheFirstSnapshot() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath, afterHello: [], sendsSnapshot: false)
        defer { endpoint.stop() }
        await connect()
        await waitUntil("hello received") { !endpoint.received.isEmpty }
        store.resizeSurface(cols: 111, rows: 33, cellWidth: 9, cellHeight: 18)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(endpoint.received.contains { $0.first == 12 }, "Resize waits for a ready endpoint")
        endpoint.send(FakeSurfaceEndpoint.control("shell.snapshot.v1", #"{"boot_id":"boot-test"}"#))
        await waitUntil("latest viewport sent") { endpoint.received.contains { $0.first == 12 } }
        XCTAssertEqual(endpoint.received.filter { $0.first == 12 }.map(Array.init), [[12, 9, 18, 111, 33, 0]])
    }

    func testWelcomeStallUsesRetryLoopWithoutRestartingTheStore() async throws {
        store = HerdrStore(endpointTimeouts: HerdrEndpointTimeouts(handshake: .milliseconds(300)))
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath, afterHello: [],
                                               sendsWelcome: false, sendsSnapshot: false)
        defer { endpoint.stop() }
        await connect()
        await waitUntil("handshake timeout") { store.surfaceError?.contains("handshake") == true }
        endpoint.stop()
        let replacement = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                                  afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()])
        defer { replacement.stop() }
        await waitUntil("retry recovered") { store.surface != nil && store.surfaceError == nil }
        XCTAssertEqual(store.selectedWorkspaceID, "w1")
    }

    func testSessionSwitchInterruptsStalledWriterAndRejectsOldCallbacks() async throws {
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               welcome: ["capabilities": ["agent_view_projection"]],
                                               afterHello: [SurfaceModel(width: 4, height: 2).surfaceFrame()], readsClient: false)
        defer { endpoint.stop() }
        await connect()
        await waitUntil("surface shown") { store.surface != nil }
        store.sendPaste(String(repeating: "x", count: 8 * 1024 * 1024), to: "w1:p1")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let previousSession = store.sessionName
        defer { UserDefaults.standard.set(previousSession, forKey: "HerdrLastSession") }
        let nextSession = "recovery-" + UUID().uuidString.prefix(8)
        let nextPath = root.appendingPathComponent("sessions/\(nextSession)/herdr.sock").path
        let nextServer = try FakeHerdrServer(path: nextPath) { method, _ in
            method == "session.snapshot" ? fakeSnapshot(label: "new session", paneIDs: ["w1:p9"]) : ["result": [:]]
        }
        defer { nextServer.stop() }
        let nextEndpoint = try FakeSurfaceEndpoint(path: root.appendingPathComponent("sessions/\(nextSession)/herdr-client.sock").path,
                                                   afterHello: [])
        defer { nextEndpoint.stop() }
        let before = ContinuousClock.now
        store.connect(to: nextSession)
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        await waitUntil("new session") { store.snapshot?.workspaces.first?.label == "new session" }
        // The old peer is still alive; any buffered old-generation state must stay excluded.
        endpoint.send(SurfaceModel(width: 4, height: 2).surfaceFrame())
        endpoint.send(FakeSurfaceEndpoint.control("shell.snapshot.v1", String(decoding: try AgentViewFixture.data(AgentViewFixture.snapshot([])), as: UTF8.self)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.surface)
        XCTAssertNil(store.agentViewState)
        XCTAssertTrue(store.workspaceGitStatuses.isEmpty)
        XCTAssertEqual(store.selectedPaneID, "w1:p9")
    }

    /// An event line over the size limit drops the subscription with an error, and the store reconnects.
    func testOversizedEventReconnects() async {
        await connect()
        server.emit(["event": String(repeating: "x", count: 1_000_001)])
        await waitUntil("size error") { store.errorMessage == "Herdr event exceeded size limit" }
        for _ in 0..<500 where !store.isConnected { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.isConnected, "reconnected")
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 2)
    }

    func testEndpointViewsUpdateIndependentlyOfLifecycleEventsAndClearOnDisconnect() async throws {
        let agents = [AgentViewFixture.agent("w1:p1"),
                      AgentViewFixture.agent("w2:p1", workspace: "w2", tab: "w2:t1", status: "blocked")]
        func control(_ kind: String, _ value: Any) throws -> Data {
            FakeSurfaceEndpoint.control(kind, String(decoding: try AgentViewFixture.data(value), as: UTF8.self))
        }
        let view = AgentViewFixture.view(filter: ["op": "eq", "field": "status", "value": "blocked"])
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
                                               welcome: ["capabilities": ["agent_view_projection"]], afterHello: [
            control("endpoint.agent-view.v1", ["boot_id": "boot-test", "revision": 1, "view": view]),
            control("shell.snapshot.v1", AgentViewFixture.snapshot(agents)),
            SurfaceModel(width: 4, height: 2).surfaceFrame()
        ])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("agent view") { store.agentViewState?.view != nil }
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: false).map(\.paneID), ["w2:p1"])
        XCTAssertTrue(store.visibleAgents(inSelectedSpaceOnly: true).isEmpty)
        XCTAssertEqual(store.selectedPaneID, "w1:p1")
        // An unsupported replacement falls back to the unfiltered list; terminal decoding continues.
        endpoint.send(try control("endpoint.agent-view.v1", ["boot_id": "boot-test", "revision": 2,
                                                            "view": AgentViewFixture.view(filter: ["op": "future"])]))
        endpoint.send(try control("shell.snapshot.v1", AgentViewFixture.snapshot(agents, revision: 2)))
        await waitUntil("unsupported query") { store.agentViewState?.unavailable == true }
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: false).count, 2)
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: true).map(\.paneID), ["w1:p1"])
        XCTAssertNil(store.surfaceError)
        endpoint.send(try control("endpoint.agent-view.v1", ["boot_id": "boot-test", "revision": 3, "view": NSNull()]))
        endpoint.send(try control("shell.snapshot.v1", AgentViewFixture.snapshot(agents, revision: 3, label: nil)))
        await waitUntil("view cleared") { store.agentViewState == nil }
        endpoint.send(try control("endpoint.agent-view.v1", ["boot_id": "boot-test", "revision": 4, "view": view]))
        endpoint.send(try control("shell.snapshot.v1", AgentViewFixture.snapshot(agents, revision: 4)))
        await waitUntil("view reapplied") { store.agentViewState?.view != nil }
        endpoint.stop()
        await waitUntil("view discarded after disconnect") { store.agentViewState == nil }
    }

    func testPopupInputNeverFallsBackToPaneAndRejectsReplacedTargets() async throws {
        func frame(_ id: String?, revision: UInt64) -> Data {
            var model = SurfaceModel(width: 30, height: 12)
            model.revision = revision
            let popup = id.map { id in
                HerdrPopup(terminalID: id, title: "Fixture", width: nil, height: nil, cols: 9, rows: 4,
                           cells: Array(repeating: SurfaceModel.blank, count: 36), cursor: nil, hyperlinks: [],
                           mouseReporting: true, pixelMouse: false, pixelWidth: 0, pixelHeight: 0)
            }
            return model.surfaceFrame { writer in
                writer.number(0); writer.popup(popup)
                writer.number(0); writer.number(0); writer.number(0)
            }
        }
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath, afterHello: [frame("popup-a", revision: 1)])
        defer { endpoint.stop() }
        await connect()
        await waitUntil("popup") { store.surface?.popup?.terminalID == "popup-a" }
        store.sendText("must not reach pane", to: "w1:p1")
        store.sendPopupInput(.text("first"), terminalID: "popup-a", bootID: "boot-test")
        store.sendPopupInput(.text("wrong boot"), terminalID: "popup-a", bootID: "old-boot")
        await waitUntil("popup input") { endpoint.received.filter { $0.first == 14 }.count == 1 }
        XCTAssertFalse(endpoint.received.contains { $0.first == 13 })
        store.closePopup(terminalID: "popup-a", bootID: "boot-test")
        await waitUntil("popup close") { Self.requests(in: endpoint).contains { $0.method == "popup.close" } }
        endpoint.send(frame("popup-b", revision: 2))
        await waitUntil("replacement popup") { store.surface?.popup?.terminalID == "popup-b" }
        store.sendPopupInput(.key("esc"), terminalID: "popup-a", bootID: "boot-test")
        store.sendPopupInput(.key("esc"), terminalID: "popup-b", bootID: "boot-test")
        await waitUntil("replacement input") { endpoint.received.filter { $0.first == 14 }.count == 2 }
        endpoint.stop()
        await waitUntil("popup disconnected") { store.surface == nil }
        store.sendText("no fallback", to: "w1:p1")
        store.sendPopupInput(.text("no fallback"), terminalID: "popup-b", bootID: "boot-test")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(server.requests.contains { $0.method == "pane.send_input" })
    }


    /// Model SSH's duplex stdio without touching saved hosts or requiring a local sshd.
    /// The real bridge owns its UNIX listeners, Process, cancellation and both protocols.
    private func fakeSSH(api: String, client: String, connectionDelay: TimeInterval = 0) throws -> String {
        let binaryDirectory = root.appendingPathComponent("remote-bin")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let path = binaryDirectory.appendingPathComponent("herdr").path
        let script = """
        #!/usr/bin/python3
        import os, sys, socket, select, time
        assert sys.argv[1:3] == ['--session', 'agents'], sys.argv
        if '--check' in sys.argv:
            print('herdr-api-bridge-v1')
            sys.exit(0)
        time.sleep(\(connectionDelay))
        command = sys.argv[3]
        path = \(String(reflecting: api)) if 'remote-api-bridge' in command else \(String(reflecting: client))
        sock = socket.socket(socket.AF_UNIX)
        try:
            sock.connect(path)
            while True:
                ready, _, _ = select.select([0, sock], [], [])
                for source in ready:
                    data = os.read(0, 65536) if source == 0 else sock.recv(65536)
                    if not data: sys.exit(0)
                    if source == 0: sock.sendall(data)
                    else:
                        while data:
                            count = os.write(1, data)
                            data = data[count:]
        except (OSError, BrokenPipeError):
            sys.exit(1)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let sshPath = root.appendingPathComponent("ssh.py").path
        let ssh = """
        #!/usr/bin/python3
        import os, sys
        os.environ['PATH'] = \(String(reflecting: binaryDirectory.path)) + ':/usr/bin:/bin'
        os.execl('/bin/sh', 'sh', '-c', sys.argv[-1])
        """
        try ssh.write(toFile: sshPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshPath)
        return sshPath
    }

    /// Unlike a local connection, remote startup opens three sequential SSH channels before
    /// publishing its authoritative snapshot. Fail at this prerequisite instead of cascading into
    /// unrelated routing assertions; the request log distinguishes progress from a broken bridge.
    private func waitForRemoteSpace(_ label: String, server: FakeHerdrServer,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !store.isConnected || store.snapshot?.workspaces.first?.label != label {
            guard ContinuousClock.now < deadline else {
                XCTFail("Remote bootstrap timed out: expected \(label), "
                        + "snapshot=\(store.snapshot?.workspaces.first?.label ?? "nil"), "
                        + "error=\(store.errorMessage ?? "nil"), "
                        + "surfaceError=\(store.surfaceError ?? "nil"), "
                        + "API requests=\(server.requests.map(\.method))", file: file, line: line)
                throw CocoaError(.userCancelled)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testHostSwitchRoutesSpacesTerminalAndActionsToTheSameRemoteServer() async throws {
        let originalSSH = WorkspaceFiles.sshExecutable
        let localSession = store.sessionName
        defer { WorkspaceFiles.sshExecutable = originalSSH }
        let remote = try FakeHerdrServer(path: root.appendingPathComponent("remote/api").path) { [state] method, _ in
            if method == "session.snapshot" {
                var snapshot = state.snapshot()
                var result = snapshot["result"] as! [String: Any]
                var value = result["snapshot"] as! [String: Any]
                value["workspaces"] = [["workspace_id": "w1", "label": "remote project", "active_tab_id": "w1:t1"]]
                result["snapshot"] = value
                snapshot["result"] = result
                return snapshot
            }
            if method == "tab.create" { return ["result": ["tab": ["tab_id": "w1:t2"]]] }
            return ["result": [:]]
        }
        defer { remote.stop() }
        let client = root.appendingPathComponent("remote/client").path
        let remoteAgents = [AgentViewFixture.agent("w1:p1", status: "blocked")]
        let remoteSurface = try FakeSurfaceEndpoint(path: client,
            welcome: ["capabilities": ["agent_view_projection"]], afterHello: [FakeSurfaceEndpoint.control("shell.snapshot.v1",
                String(decoding: try AgentViewFixture.data(AgentViewFixture.snapshot(remoteAgents)), as: UTF8.self)),
                SurfaceModel(width: 7, height: 2).surfaceFrame()])
        defer { remoteSurface.stop() }
        // Startup needs three sequential API channels (snapshot, subscription, authoritative
        // snapshot). A 1.1 s delay per channel exposes the old single-local-request wait budget.
        WorkspaceFiles.sshExecutable = try fakeSSH(api: remote.path, client: client, connectionDelay: 1.1)
        await connect()
        XCTAssertEqual(store.snapshot?.workspaces.first?.label, "project")
        let localContext = store.contextID
        let machine = HerdrMachineProfile(id: "remote-a", label: "Remote A", target: "test-host", session: "agents", enabled: true)
        store.connect(to: machine)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.surface)
        XCTAssertNotEqual(store.contextID, localContext)
        XCTAssertFalse(store.socketPath.hasPrefix(HerdrStore.sessionRoot.path))
        try await waitForRemoteSpace("remote project", server: remote)
        await waitUntil("remote terminal attached") { store.surface?.width == 7 }
        await waitUntil("remote agents attached") { store.agentViewState?.agents.count == 1 }
        server.emit(["event": "workspace.created"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.snapshot?.workspaces.first?.label, "remote project")
        let localInputs = server.requests.filter { $0.method == "pane.send_input" }.count
        store.sendText("remote input", to: "w1:p1")
        await waitUntil("remote binary input") { remoteSurface.received.contains { $0.first == 13 } }
        XCTAssertEqual(server.requests.filter { $0.method == "pane.send_input" }.count, localInputs)
        store.createTab(cwd: "/remote/project")
        await waitUntil("remote tab command") {
            Self.requests(in: remoteSurface).contains { $0.method == "tab.create" }
                || remote.requests.contains { $0.method == "tab.create" }
        }
        XCTAssertFalse(server.requests.contains { $0.method == "tab.create" })
        await waitUntil("remote tab created") { store.selectedTabID == "w1:t2" }
        XCTAssertNil(store.actionError)
        let oldSocket = store.socketPath
        store.connect(to: localSession)
        XCTAssertNil(store.machine)
        XCTAssertEqual(store.contextID, localContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSocket))
        await waitUntil("local Space restored") { store.snapshot?.workspaces.first?.label == "project" }
        XCTAssertNil(store.surface)
    }

    func testUnreachableRemoteNeverReusesLocalSnapshotOrSocket() async throws {
        await connect()
        let localSocket = store.socketPath
        let originalSSH = WorkspaceFiles.sshExecutable
        WorkspaceFiles.sshExecutable = "/usr/bin/false"
        defer { WorkspaceFiles.sshExecutable = originalSSH }
        store.connect(to: HerdrMachineProfile(id: "missing", label: "Missing", target: "absent", session: "agents", enabled: true))
        await waitUntil("remote error") { store.errorMessage != nil }
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.selectedWorkspaceID)
        XCTAssertNotEqual(store.socketPath, localSocket)
        XCTAssertEqual(store.machine?.id, "missing")
        XCTAssertTrue(store.errorMessage?.contains("Missing") == true)
    }

    func testAbandonedRemoteConnectionCannotReplaceTheLocalContext() async throws {
        let localSession = store.sessionName
        let originalSSH = WorkspaceFiles.sshExecutable
        WorkspaceFiles.sshExecutable = "/usr/bin/false"
        defer { WorkspaceFiles.sshExecutable = originalSSH }
        await connect()
        store.connect(to: HerdrMachineProfile(id: "abandoned", label: "Abandoned", target: "absent", session: "agents", enabled: true))
        let remoteSocket = store.socketPath
        store.connect(to: localSession)
        await waitUntil("local reconnect") { store.isConnected }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.machine)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.surface)
        XCTAssertEqual(store.snapshot?.workspaces.first?.label, "project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteSocket))
    }

    func testPassiveDestinationSubscribesWithoutTerminalOrPanePolling() async throws {
        state.update { $0.panes.removeAll { $0["pane_id"] as? String == "w1:p2" } }
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
            afterHello: [SurfaceModel(width: 80, height: 24).surfaceFrame()])
        defer { endpoint.stop() }
        store.requiresSurfaceForInput = true
        store.setPresentationActive(false)
        await connect()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(endpoint.received.isEmpty, "A background destination must not open the endpoint")
        XCTAssertFalse(server.requests.contains { $0.method == "pane.read" })
        store.sendText("must not send", to: "w1:p1")
        XCTAssertFalse(server.requests.contains { $0.method == "pane.send_input" })
        store.setPresentationActive(true)
        await waitUntil("fresh active surface") { store.inputReady }
        store.select(tabID: "w1:t2")
        store.select(paneID: "w1:p3")
        store.setPresentationActive(false)
        XCTAssertNil(store.surface)
        XCTAssertFalse(store.inputReady)
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.selectedTabID, "w1:t2")
        state.update { $0.workspaces[0]["label"] = "background update" }
        server.emit(["event": "workspace.renamed"])
        await waitUntil("background metadata continues") { store.snapshot?.workspaces.first?.label == "background update" }
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 1)
    }

    func testMetadataPoolSharesOneSubscriptionAndKeepsWindowSelectionsIndependent() async throws {
        let notifier = HerdrNotifier()
        let pool = HerdrMetadataPool(notifier: notifier)
        let first = HerdrDestinations(store: store, notifier: notifier, pool: pool)
        let second = HerdrDestinations(notifier: notifier, pool: pool)
        first.start()
        second.start()
        defer { first.stop(); second.stop(); notifier.reset() }
        await waitUntil("both windows connected") { first.active.isConnected && second.active.isConnected }
        XCTAssertTrue(first.active.metadataSource === second.active.metadataSource)
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 1)
        first.active.select(tabID: "w1:t2")
        XCTAssertEqual(second.active.selectedTabID, "w1:t1")
        first.stop()
        state.update { $0.workspaces[0]["label"] = "still connected" }
        server.emit(["event": "workspace.renamed"])
        await waitUntil("remaining window keeps metadata") { second.active.snapshot?.workspaces.first?.label == "still connected" }
    }

    func testDestinationNavigationReturnsToRememberedTabWithoutReconnectingMetadata() async throws {
        let otherPath = root.appendingPathComponent("sessions/other/herdr.sock").path
        let other = try FakeHerdrServer(path: otherPath) { [state] method, _ in
            method == "session.snapshot" ? state.snapshot() : ["result": [:]]
        }
        defer { other.stop() }
        let notifier = HerdrNotifier()
        let destinations = HerdrDestinations(store: store, notifier: notifier)
        destinations.start()
        defer { destinations.stop(); notifier.reset() }
        await waitUntil("first destination connected") { store.isConnected }
        store.select(tabID: "w1:t2")
        let firstGeneration = store.generation
        destinations.localSession("other")
        let second = destinations.active
        await waitUntil("second destination connected") { second.isConnected }
        destinations.goBack()
        XCTAssertTrue(destinations.active === store)
        XCTAssertEqual(store.selectedTabID, "w1:t2")
        XCTAssertEqual(store.generation, firstGeneration)
        XCTAssertFalse(second.presentationActive)
        XCTAssertTrue(second.isConnected)
        destinations.goBack()
        XCTAssertTrue(destinations.active === second)
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 1)
    }

    func testSlowSpaceCreationDoesNotStealALaterSelectionOnTheSameDestination() async throws {
        state.update {
            $0.workspaces.append(["workspace_id": "w9", "label": "chosen", "active_tab_id": "w9:t1"])
            $0.tabs.append(["tab_id": "w9:t1", "workspace_id": "w9", "label": "1"])
            $0.panes.append(["pane_id": "w9:p1", "workspace_id": "w9", "tab_id": "w9:t1"])
        }
        let notifier = HerdrNotifier()
        let destinations = HerdrDestinations(store: store, notifier: notifier)
        destinations.start()
        defer { destinations.stop(); notifier.reset() }
        await waitUntil("connected") { store.isConnected }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        state.update { $0.createGate = gate }
        destinations.createSpace(on: store)
        await waitUntil("creation started") { server.requests.contains { $0.method == "workspace.create" } }
        destinations.select(store, workspaceID: "w9")
        gate.signal()
        await waitUntil("created without navigating") { store.snapshot?.workspaces.contains { $0.workspaceID == "w2" } == true }
        XCTAssertEqual(store.selectedWorkspaceID, "w9")
        destinations.goBack()
        XCTAssertEqual(store.selectedWorkspaceID, "w1")
    }

    func testLateCatalogResultCannotOpenConnectionsAfterWindowCloses() async {
        let notifier = HerdrNotifier()
        let destinations = HerdrDestinations(store: store, notifier: notifier)
        destinations.start()
        destinations.stop()
        destinations.refresh([HerdrMachineProfile(id: "late", label: "Late", target: "absent", session: "agents", enabled: true)])
        XCTAssertEqual(destinations.stores.count, 1)
        XCTAssertNil(store.metadataSource)
        destinations.localSession("late")
        XCTAssertEqual(destinations.stores.count, 1)
    }

    func testChangingSSHTargetChangesRoutingAndDocumentIdentity() {
        let originalSSH = WorkspaceFiles.sshExecutable
        WorkspaceFiles.sshExecutable = "/usr/bin/false"
        defer { WorkspaceFiles.sshExecutable = originalSSH }
        store.setPresentationActive(false)
        store.connect(to: HerdrMachineProfile(id: "same-profile", label: "Devbox", target: "host-one", session: "agents", enabled: true))
        let old = store.contextID
        let action = HerdrActionConnection(store)
        store.updateProfile(HerdrMachineProfile(id: "same-profile", label: "Devbox", target: "host-two", session: "agents", enabled: true))
        XCTAssertNotEqual(store.contextID, old)
        XCTAssertNil(action.validStore)
    }

    func testQueuedMutationIsCancelledBeforeDispatchAfterConnectionChanges() async {
        await connect()
        for _ in 0..<BlockingWork.limit { try? await BlockingWork.slots.acquire() }
        store.closeWorkspace("w1")
        await Task.yield()
        store.stop()
        store.start()
        for _ in 0..<BlockingWork.limit { BlockingWork.slots.release() }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(server.requests.contains { $0.method == "workspace.close" })
    }

    func testSaturatedRemoteDoesNotBlockLocalMutations() async throws {
        await connect()
        let originalSSH = WorkspaceFiles.sshExecutable
        let remoteServer = try FakeHerdrServer { [state] method, _ in
            method == "session.snapshot" ? state.snapshot() : ["result": [:]]
        }
        let remote = HerdrStore()
        remote.setPresentationActive(false)
        defer { remote.stop(); remoteServer.stop(); WorkspaceFiles.sshExecutable = originalSSH }
        WorkspaceFiles.sshExecutable = try fakeSSH(api: remoteServer.path, client: "/private/tmp/no-client")
        let machine = HerdrMachineProfile(id: "budget-test", label: "Budget", target: "budget-test", session: "agents", enabled: true)
        remote.connect(to: machine)
        await waitUntil("remote metadata connected") { remote.isConnected }
        let slots = BlockingWork.slots(for: BlockingWorkMachine(machine))
        for _ in 0..<BlockingWork.machineLimit { try await slots.acquire() }
        remote.closeWorkspace("w1")
        store.closeWorkspace("w1")
        await waitUntil("local mutation does not wait for remote capacity") { server.requests.contains { $0.method == "workspace.close" } }
        XCTAssertFalse(remoteServer.requests.contains { $0.method == "workspace.close" })
        for _ in 0..<BlockingWork.machineLimit { slots.release() }
        await waitUntil("remote mutation follows after its own capacity frees") { remoteServer.requests.contains { $0.method == "workspace.close" } }
    }

    func testInvalidatingQueuedInputDoesNotLeaveACompletedTaskBlockingNewKeys() async throws {
        state.update { $0.panes.removeAll { $0["pane_id"] as? String == "w1:p2" } }
        let endpoint = try FakeSurfaceEndpoint(path: store.clientSocketPath,
            afterHello: [SurfaceModel(width: 80, height: 24).surfaceFrame()])
        defer { endpoint.stop() }
        store.requiresSurfaceForInput = true
        await connect()
        await waitUntil("terminal ready") { store.inputReady }
        store.sendText("old epoch", to: "w1:p1")
        store.invalidatePendingActions()
        store.sendText("new epoch", to: "w1:p1")
        await waitUntil("new input task sends") {
            endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("new epoch"))!)
        }
        XCTAssertFalse(endpoint.received.contains(SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("old epoch"))!))
    }

    func testSameDestinationSelectionDoesNotRestartConnection() async {
        await connect()
        let generation = store.generation
        store.connect(to: store.sessionName)
        XCTAssertEqual(store.generation, generation)
        XCTAssertTrue(store.isConnected)
    }

    func testStrictInputWaitsForSurfaceAndDoesNotUseJSONFallback() async {
        store.requiresSurfaceForInput = true
        await connect()
        store.sendText("not yet", to: "w1:p1")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(store.inputReady)
        XCTAssertFalse(server.requests.contains { $0.method == "pane.send_input" })
    }

    func testBridgePreservesSSHPortAndQuotesSession() throws {
        let machine = HerdrMachineProfile(id: "a", label: "A", target: "ssh://user@example.test:2222", session: "agents", enabled: true)
        let arguments = HerdrRemoteBridge.arguments(machine, command: "remote-api-bridge")
        XCTAssertEqual(arguments.suffix(2).first, "user@example.test")
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.last?.contains("remote-api-bridge") == true)
        XCTAssertThrowsError(try HerdrRemoteBridge(machine: HerdrMachineProfile(id: "b", label: "B", target: "-oBad", session: "agents", enabled: true)))
        XCTAssertThrowsError(try HerdrRemoteBridge(machine: HerdrMachineProfile(id: "b", label: "B", target: "host", session: "bad;session", enabled: true)))
    }

    /// The JSON requests (tag 15) the store sent through the endpoint.
    private static func requests(in endpoint: FakeSurfaceEndpoint) -> [(method: String, params: [String: Any])] {
        endpoint.received.filter { $0.first == 15 }.compactMap { frame in
            var probe = SurfaceReaderProbe(frame)
            _ = probe.number()
            _ = probe.string() // boot ID
            guard let json = try? JSONSerialization.jsonObject(with: Data(probe.string().utf8)) as? [String: Any],
                  let method = json["method"] as? String else { return nil }
            return (method, json["params"] as? [String: Any] ?? [:])
        }
    }
}

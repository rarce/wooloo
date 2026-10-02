import Combine
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
        var layouts: [[String: Any]] = []
        var reload: [String: Any] = ["status": "applied"]
        /// When set, `pane.send_input` waits for it before answering, keeping the request in flight.
        var inputGate: DispatchSemaphore?

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
    private var server: FakeHerdrServer!
    private var store: HerdrStore!

    override func setUp() async throws {
        // Short, so socket paths stay under the 104-byte limit.
        root = URL(fileURLWithPath: "/private/tmp/xherdr-tests/\(UUID().uuidString.prefix(8))")
        savedRoot = HerdrStore.sessionRoot
        HerdrStore.sessionRoot = root
        store = HerdrStore()
        server = try FakeHerdrServer(path: store.socketPath) { [state] method, params in
            if method == "pane.send_input", let gate = state.lock.withLock({ state.inputGate }) { gate.wait() }
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

    /// An event line over the size limit drops the subscription with an error, and the store reconnects.
    func testOversizedEventReconnects() async {
        await connect()
        server.emit(["event": String(repeating: "x", count: 1_000_001)])
        await waitUntil("size error") { store.errorMessage == "Herdr event exceeded size limit" }
        for _ in 0..<500 where !store.isConnected { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.isConnected, "reconnected")
        XCTAssertEqual(server.requests.filter { $0.method == "events.subscribe" }.count, 2)
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

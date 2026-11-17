import WoolooTerminalEngine
import XCTest
@testable import wooloo

/// `HerdrStore` connected to herdr-core (Phases 3 to 5): state, commands, live terminals and
/// their arrangement go through `CoreSessionBackend`, against an in-memory `FakeCore`.
@MainActor
final class HerdrStoreCoreTests: XCTestCase {
    private var core: FakeCore!
    private var store: HerdrStore!
    private var savedFactory: ((String, HerdrMachineProfile?) throws -> CoreSessionBackend)!

    override func setUp() async throws {
        core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", argv: ["/bin/zsh"], cols: 100, rows: 30, cwd: "/src/app")]
        core.screens["t1"] = "$ make\nok\n"
        savedFactory = HerdrStore.makeCoreBackend
        HerdrStore.makeCoreBackend = { [core] session, _ in
            CoreSessionBackend(target: .local(hc: "/fake/hc", session: session), makeTransport: { _ in core!.connect() })
        }
        store = HerdrStore()
    }

    override func tearDown() async throws {
        store.stop()
        HerdrStore.makeCoreBackend = savedFactory
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
    }

    func testACoreConnectionShowsItsTerminalsAsTabs() async throws {
        store.connect(toCore: "wooloo-ui-test")
        await waitUntil("connected") { store.isConnected }
        XCTAssertEqual(store.backendKind, .core)
        XCTAssertEqual(store.contextID, "core:wooloo-ui-test")
        XCTAssertEqual(store.session?.backend.kind, .core)
        XCTAssertEqual(store.session?.spaces.map(\.id), [CoreStructure.unfiledID], "A terminal no tab holds is Unfiled")
        XCTAssertEqual(store.session?.tabs.map(\.id), ["tab-t1"])
        XCTAssertNotNil(store.presentationProvider, "herdr-core terminals are emulated in wooloo")
        XCTAssertEqual(HerdrWindowConnection(store).id, "core:wooloo-ui-test")
        XCTAssertEqual(HerdrWindowConnection(store).backendKind, .core)
    }

    func testNewTabsAreNewTerminalsAndChangesArrive() async throws {
        store.connect(toCore: "wooloo-ui-test")
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID)
        store.createTab(cwd: "/src")
        await waitUntil("new tab") { store.session?.tabs.count == 2 }
        XCTAssertEqual(core.callsTo("terminal.run").first?.params["cwd"] as? String, "/src")
        let created = try XCTUnwrap(store.session?.tabs.last?.id)
        XCTAssertEqual(store.selectedTabID, created)
        core.update { $0.terminals.removeAll { $0.address == "t1" } }
        // The watcher and the live presentation each subscribe; a real core tells every subscriber.
        for server in core.connections where server.eventsChannel != nil { server.emit(type: "removed", terminal: "t1") }
        await waitUntil("removed tab") { store.session?.tabs.map(\.id) == [created] }
    }

    func testUnsupportedActionsReportAnError() async throws {
        store.connect(toCore: "wooloo-ui-test")
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        store.reloadConfig()
        await waitUntil("error") { store.actionError != nil }
        XCTAssertEqual(store.actionError, CoreProtocolError.unsupported("reload the configuration").localizedDescription)
    }

    private func attachedServer() -> (FakeCoreServer, UInt32)? {
        for server in core.connections { if let channel = core.lock.withLock({ server.attachChannels.last }) { return (server, channel) } }
        return nil
    }

    func testTheLiveTerminalShowsItsOutputAndTakesTyping() async throws {
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let attach = try XCTUnwrap(core.callsTo("terminal.attach").last)
        XCTAssertEqual(attach.params["terminal"] as? String, "t1")
        XCTAssertNotNil(attach.params["display"], "The window's colours answer the program's colour queries")
        XCTAssertEqual(attach.params["history"] as? Int, CoreTerminalPresentation.attachHistory, "Scrollback comes with the attach")
        let (server, channel) = try XCTUnwrap(attachedServer())
        server.send(Data("hello \u{1b}[1mworld\u{1b}[0m".utf8), on: channel)
        await waitUntil("surface") {
            store.surface?.paneIDs == ["t1"] && store.surface.map { $0.cells.row(0).prefix(11).map(\.symbol).joined() } == "hello world"
        }
        let bold = try XCTUnwrap(store.surface?.cells[6, 0])
        XCTAssertEqual(bold.modifier & 1, 1)
        await waitUntil("input ready") { store.inputReady }
        store.sendKey("ctrl+c", to: "t1")
        store.sendText("ls", to: "t1")
        await waitUntil("typed") {
            server.recordedFrames().filter { $0.channel == channel && $0.kind == .data }.map(\.payload) == [Data([3]), Data("ls".utf8)]
        }
        XCTAssertTrue(server.recordedFrames().contains { $0.channel == channel && $0.kind == .facts })
        XCTAssertTrue(core.callsTo("terminal.keys").isEmpty, "Keys go to the attached stream, encoded in wooloo")
        // A program that asks for the mouse gets clicks, encoded for its mode.
        XCTAssertEqual(store.surface?.mouseReportingPaneIDs, [])
        server.send(Data("\u{1b}[?1000h".utf8), on: channel)
        await waitUntil("mouse reporting") { store.surface?.mouseReportingPaneIDs == ["t1"] }
        store.sendMouse(HerdrMouseEvent(kind: .down(0), column: 2, row: 1, modifiers: 0, lines: 1), to: "t1")
        await waitUntil("clicked") {
            server.recordedFrames().contains { $0.channel == channel && $0.kind == .data
                && $0.payload == Data([0x1b, 0x5b, 0x4d, 32, 35, 34]) }
        }
    }

    func testASplitTabIsComposedFromItsTerminals() async throws {
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("first pane") { store.surface?.paneIDs == ["t1"] }
        store.splitPane("right")
        await waitUntil("both panes") { store.surface?.paneIDs == ["t1", "t2"] }
        XCTAssertEqual(store.selectedPaneID, "t2", "The window follows the new pane")
        let surface = try XCTUnwrap(store.surface)
        let left = try XCTUnwrap(surface.paneRects["t1"]), right = try XCTUnwrap(surface.paneRects["t2"])
        XCTAssertEqual(left.x + left.width + 1, right.x, "One column of border between them")
        let split = try XCTUnwrap(surface.splits.first)
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.pos, left.width)
        XCTAssertEqual(surface.cells[split.pos, 0].symbol, "│")
        XCTAssertEqual(core.lock.withLock { () -> Int in
            core.connections.reduce(0) { $0 + $1.attachChannels.count }
        }, 2)
        // Output of the second terminal lands in its half.
        let attaches = core.callsTo("terminal.attach").map { $0.params["terminal"] as? String }
        let index = try XCTUnwrap(attaches.lastIndex(of: "t2"))
        let (server, _) = try XCTUnwrap(attachedServer())
        let channel = core.lock.withLock { server.attachChannels[index] }
        server.send(Data("right side".utf8), on: channel)
        await waitUntil("right output") {
            store.surface.map { s in (0..<10).map { s.cells[right.x + $0, 0].symbol }.joined() } == "right side"
        }
        // Zoom is this window's own: the selected pane fills the tab, the other is detached.
        store.zoomPane()
        await waitUntil("zoomed") { store.surface?.paneRects["t2"]?.width == surface.width }
        XCTAssertEqual(store.surface?.paneRects["t1"]?.width, 0)
        XCTAssertEqual(store.surface?.paneIDs, ["t1", "t2"], "The surface still names every pane of the tab")
        XCTAssertEqual(store.surface?.splits, [])
        XCTAssertEqual(store.session?.layout(of: "tab-t1")?.zoomed, true)
        XCTAssertFalse(core.lock.withLock { () -> Bool in
            let document = core.documents[CoreStructure.documentName]?.value
            return (try? JSONSerialization.data(withJSONObject: document ?? [:])).map { String(decoding: $0, as: UTF8.self) }?
                .contains("zoom") ?? false
        }, "Zoom is not written to the shared document")
        store.zoomPane()
        await waitUntil("unzoomed") { store.surface?.paneRects["t1"]?.width == left.width }
        // A dragged split moves at once and is written to the document once it rests.
        store.setSplitRatio(path: [], ratio: 0.25)
        await waitUntil("moved split") { (store.surface?.paneRects["t1"]?.width ?? 0) < left.width }
        await waitUntil("written ratio") {
            self.core.lock.withLock {
                CoreStructure.decode(self.core.documents[CoreStructure.documentName]?.value ?? nil)?
                    .spaces.first?.tabs.first?.root
            } == .split(.right, ratio: 0.25, first: .terminal("t1"), second: .terminal("t2"))
        }
    }

    func testFindInTerminalHighlightsTheMatch() async throws {
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let (server, channel) = try XCTUnwrap(attachedServer())
        server.send(Data("alpha\r\nbeta\r\n".utf8), on: channel)
        await waitUntil("output") { store.surface.map { $0.cells.row(1).prefix(4).map(\.symbol).joined() } == "beta" }
        XCTAssertTrue(store.findsInTerminal)
        let result = await store.findInTerminal("beta", older: true)
        XCTAssertEqual(result, TerminalFindResult(index: 1, total: 1))
        await waitUntil("highlight") { (store.surface?.cells[0, 1].modifier ?? 0) & 64 != 0 }
        XCTAssertEqual((store.surface?.cells[4, 1].modifier ?? 64) & 64, 0, "Only the match")
        let missing = await store.findInTerminal("gamma", older: true)
        XCTAssertNil(missing)
        await waitUntil("no highlight") { (store.surface?.cells[0, 1].modifier ?? 64) & 64 == 0 }
        store.endTerminalFind()
    }

    func testAnInactiveWindowWatchesUntilItIsActive() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let watching = try XCTUnwrap(core.callsTo("terminal.attach").last)
        XCTAssertEqual(watching.params["observe"] as? Bool, true, "A window behind others only watches")
        XCTAssertEqual(watching.params["resize_notifications"] as? Bool, true)
        let (server, channel) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        server.send(Data("watched".utf8), on: channel)
        let firstRow = { store.surface.map { $0.cells.row(0).prefix(7).map(\.symbol).joined() } }
        await waitUntil("output, row 0 is \(String(describing: firstRow()))") { firstRow() == "watched" }
        server.sendResize(cols: 30, rows: 8, on: channel)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(server.recordedFrames().contains { $0.channel == channel && $0.kind == .resize },
                       "An observer never sizes the terminal")
        store.updateTerminalHost(theme: theme, focused: true)
        await waitUntil("active again") {
            core.callsTo("terminal.attach").count == 2 && core.callsTo("terminal.attach").last?.params["observe"] == nil
        }
        await waitUntil("old stream closed") {
            server.recordedFrames().contains { $0.channel == channel && $0.kind == .close }
        }
    }

    func testShowingADoneTurnMarksItSeenOnlyInFrontOfSomeone() async throws {
        core.terminals = [CoreTerminal(address: "t1", argv: ["claude"], cols: 100, rows: 30, cwd: "/src/app",
                                       status: CoreStatus(state: "done", app: "claude", msg: nil, title: nil), turn: 4)]
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("drawn") { store.surface?.paneIDs == ["t1"] }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(core.callsTo("terminal.label").isEmpty, "Not seen while the window's terminal is not focused")
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        await waitUntil("seen") {
            core.callsTo("terminal.label").contains { ($0.params["labels"] as? [String: String]) == ["herdr.seen": "4"] }
        }
    }

    func testPinnedAgentsListFirstAndAnUnreadTurnStaysUnread() async throws {
        let idle = CoreStatus(state: "idle", app: "claude", msg: nil, title: nil)
        core.terminals = [CoreTerminal(address: "t1", argv: ["claude"], cols: 100, rows: 30, cwd: "/src/app",
                                       labels: ["herdr.seen": "3"], status: idle, turn: 3),
                          CoreTerminal(address: "t2", argv: ["codex"], cols: 100, rows: 30, cwd: "/src/app",
                                       status: idle, turn: 0)]
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        await waitUntil("connected") { store.isConnected }
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: false).map(\.paneID), ["t1", "t2"])
        store.setAgentPinned("t2", true)
        await waitUntil("pinned first") { store.visibleAgents(inSelectedSpaceOnly: false).map(\.paneID) == ["t2", "t1"] }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("drawn") { store.surface?.paneIDs == ["t1"] }
        store.markAgentUnread("t1")
        await waitUntil("unread") { store.session?.agents.first { $0.paneID == "t1" }?.state == .done }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(core.callsTo("terminal.label").contains { ($0.params["labels"] as? [String: String]) == ["herdr.seen": "3"] },
                       "The pane on screen is not marked seen again at once")
    }

    func testCellsUseHerdrsSurfaceEncoding() {
        let cell = CoreTerminalPresentation.cell(TerminalCell(text: "界", foreground: TerminalRGB(255, 128, 0),
                                                               background: nil, style: [.bold, .underline, .inverse],
                                                               width: .wide))
        XCTAssertEqual(cell.symbol, "界")
        XCTAssertEqual(cell.foreground, 0x02FF_8000)
        XCTAssertEqual(cell.background, 0)
        XCTAssertEqual(cell.modifier, 1 | 8 | 64)
        XCTAssertFalse(cell.skip)
        XCTAssertTrue(CoreTerminalPresentation.cell(TerminalCell(width: .spacer)).skip)
        XCTAssertEqual(CoreTerminalPresentation.cell(TerminalCell()).symbol, " ")
        XCTAssertEqual(CoreTerminalPresentation.row([TerminalCell(text: "a")], width: 3).map(\.symbol), ["a", " ", " "])
    }

    func testAMissingCoreIsReportedWithoutStartingAnything() async throws {
        HerdrStore.makeCoreBackend = { _, _ in throw WorkspaceFileError.message("herdr-core (hc) is not installed on this Mac.") }
        store.connect(toCore: "wooloo-ui-test")
        XCTAssertEqual(store.errorMessage, "herdr-core (hc) is not installed on this Mac.")
        XCTAssertFalse(store.isConnected)
    }

    func testTUIConnectionsKeepTheirKeysAndProvider() {
        store.connect(to: "agents", remember: false, startImmediately: false)
        XCTAssertEqual(store.backendKind, .tui)
        XCTAssertEqual(store.contextID, "agents")
        XCTAssertNotNil(store.presentationProvider)
    }
}

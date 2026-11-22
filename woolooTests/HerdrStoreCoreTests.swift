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

    /// The first tab is chosen by the store when the state arrives, not by the user: the
    /// presentation still has to be told, or the pane stays on text with input withheld.
    func testInitialAttachWaitsForTheWindowsFirstFocusReport() async throws {
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("tab chosen") { store.selectedTabID == "tab-t1" }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(core.callsTo("terminal.attach").isEmpty)
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        await waitUntil("active attach") { attachedServer() != nil }
        XCTAssertEqual(core.callsTo("terminal.attach").count, 1)
        XCTAssertNil(core.callsTo("terminal.attach").first?.params["observe"])
    }

    func testTheTabChosenOnConnectGoesLive() async throws {
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("a tab chosen") { store.selectedTabID == "tab-t1" }
        await waitUntil("attached") { attachedServer() != nil }
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        await waitUntil("input ready") { store.inputReady }
        XCTAssertTrue(store.findsInTerminal)
    }

    /// Keys can reach a watching pane before the window's activation does: they are kept and
    /// sent once the pane attaches actively, which the typing itself starts.
    func testKeysBeforeTheActivationAreNotLost() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("watching") { core.callsTo("terminal.attach").last?.params["observe"] as? Bool == true }
        let (_, watching) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        store.sendText("echo hi", to: "t1")
        await waitUntil("typed into the active stream") {
            self.core.connections.contains { server in
                server.recordedFrames().contains {
                    $0.channel != watching && $0.kind == .data && $0.payload == Data("echo hi".utf8)
                }
            }
        }
        XCTAssertNil(core.callsTo("terminal.attach").last?.params["observe"])
    }

    /// Only the window in use sizes the terminal. A window resized in the background may be the
    /// only viewer, so it keeps sizing it until Core reports another viewer's size; then it
    /// watches. A window coming back to the front sends its size again.
    func testABackgroundWindowDoesNotSizeTheTerminal() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let (server, active) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        let resizes = { server.recordedFrames().filter { $0.channel == active && $0.kind == .resize }.count }
        let before = resizes()

        store.updateTerminalHost(theme: theme, focused: false)
        store.resizeSurface(cols: 50, rows: 12, cellWidth: 8, cellHeight: 16)
        await waitUntil("sized while it may be the only viewer") { resizes() > before }
        XCTAssertEqual(core.callsTo("terminal.attach").count, 1)
        // A late report of a size this window sent is its own.
        server.emit(type: "size", terminal: "t1", data: ["cols": 50, "rows": 12])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(core.callsTo("terminal.attach").count, 1)

        server.emit(type: "size", terminal: "t1", data: ["cols": 90, "rows": 20])
        await waitUntil("watching") { core.callsTo("terminal.attach").last?.params["observe"] as? Bool == true }
        await waitUntil("active stream closed") {
            server.recordedFrames().contains { $0.channel == active && $0.kind == .close }
        }
        let sized = resizes()
        store.resizeSurface(cols: 48, rows: 12, cellWidth: 8, cellHeight: 16)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(resizes(), sized, "Watching, a window in the background never sends its size")
        store.resizeSurface(cols: 50, rows: 12, cellWidth: 8, cellHeight: 16)

        store.updateTerminalHost(theme: theme, focused: true)
        await waitUntil("active again") {
            core.callsTo("terminal.attach").last?.params["observe"] == nil && core.callsTo("terminal.attach").count == 3
        }
        let last = try XCTUnwrap(core.callsTo("terminal.attach").last)
        XCTAssertEqual(last.params["cols"] as? Int, 50)
        XCTAssertEqual(last.params["rows"] as? Int, 12)

        // Back in front without a resize: the stream stays, and sends its size again in case
        // another window took the terminal meanwhile.
        let current = try XCTUnwrap(core.lock.withLock { server.attachChannels.last })
        store.updateTerminalHost(theme: theme, focused: false)
        store.updateTerminalHost(theme: theme, focused: true)
        await waitUntil("size sent again") {
            server.recordedFrames().contains { $0.channel == current && $0.kind == .resize }
        }
        XCTAssertEqual(core.callsTo("terminal.attach").count, 3, "Switching windows does not attach again")
    }

    /// A background window's active stream hears of no other size: when Core reports that
    /// another viewer resized the terminal, it watches instead, following Core's size.
    func testABackgroundWindowWatchesOnceAnotherViewerResizes() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let (server, active) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        let attach = try XCTUnwrap(core.callsTo("terminal.attach").last)
        let cols = try XCTUnwrap(attach.params["cols"] as? Int), rows = try XCTUnwrap(attach.params["rows"] as? Int)
        let resizes = { server.recordedFrames().filter { $0.kind == .resize }.count }
        let before = resizes()

        store.updateTerminalHost(theme: theme, focused: false)
        // Its own size coming back changes nothing.
        server.emit(type: "size", terminal: "t1", data: ["cols": cols, "rows": rows])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(core.callsTo("terminal.attach").count, 1)

        server.emit(type: "size", terminal: "t1", data: ["cols": cols + 7, "rows": rows - 3])
        await waitUntil("watching") { core.callsTo("terminal.attach").last?.params["observe"] as? Bool == true }
        await waitUntil("active stream closed") {
            server.recordedFrames().contains { $0.channel == active && $0.kind == .close }
        }
        XCTAssertEqual(resizes(), before, "A window in the background never sends its size")
    }

    func testRefusedActivationWaitsBeforeRetrying() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("watching") { attachedServer() != nil }
        core.update { $0.overrides["terminal.attach"] = { _ in nil } }
        store.updateTerminalHost(theme: theme, focused: true)
        await waitUntil("first refusal") { core.callsTo("terminal.attach").count >= 2 }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(core.callsTo("terminal.attach").count, 2)
        core.update { $0.overrides["terminal.attach"] = nil }
        await waitUntil("retry succeeds") { core.callsTo("terminal.attach").count >= 3 }
    }

    func testReleaseOfASwallowedPressStaysLocalAfterPromotion() async throws {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("watching") { attachedServer() != nil && store.surface != nil }
        let (server, watching) = try XCTUnwrap(attachedServer())
        server.send(Data((1...90).map { "line \($0)" }.joined(separator: "\r\n").utf8), on: watching)
        await waitUntil("output drawn") { store.surface?.cells.row(0).first?.symbol == "l" }
        let stream = try XCTUnwrap(store.surfaceStream)
        XCTAssertTrue(stream.sendInput(.mouse(.init(kind: .scrollUp, column: 0, row: 0, modifiers: 0, lines: 10)), to: "t1"))
        server.send(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8), on: watching)
        await waitUntil("mouse reporting") { store.surface?.mouseReportingPaneIDs.contains("t1") == true }
        XCTAssertTrue(stream.sendInput(.mouse(.init(kind: .down(0), column: 2, row: 1, modifiers: 0, lines: 1)), to: "t1"))
        store.updateTerminalHost(theme: theme, focused: true)
        await waitUntil("promoted") { server.recordedFrames().contains { $0.channel == watching && $0.kind == .close } }
        store.sendMouse(.init(kind: .up(0), column: 2, row: 1, modifiers: 0, lines: 1), to: "t1")
        store.sendText("after", to: "t1")
        await waitUntil("input flushed") { server.recordedFrames().contains { $0.payload == Data("after".utf8) } }
        XCTAssertFalse(server.recordedFrames().contains { $0.payload == Data("\u{1b}[<0;3;2m".utf8) })
    }

    /// A click into a watching pane can come before the window's activation, like keys: it is
    /// kept and sent once the pane attaches actively.
    func testAClickBeforeTheActivationIsNotLost() async throws {
        core.terminals = [CoreTerminal(address: "t1", argv: ["/bin/zsh"], cols: 8, rows: 8, cwd: "/src/app")]
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("watching") { core.callsTo("terminal.attach").last?.params["observe"] as? Bool == true }
        let (server, watching) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        // The program reports clicks (SGR), as vim with `mouse=a` does.
        server.send(Data("\u{1b}[?1000h\u{1b}[?1006hvim".utf8), on: watching)
        await waitUntil("reporting") { store.surface.map { $0.cells.row(0).prefix(3).map(\.symbol).joined() } == "vim" }
        let press = Data("\u{1b}[<0;21;2M".utf8)
        store.sendMouse(HerdrMouseEvent(kind: .down(0), column: 20, row: 1, modifiers: 0, lines: 0), to: "t1")
        await waitUntil("the click reaches the active stream") {
            self.core.connections.contains { server in
                server.recordedFrames().contains { $0.channel != watching && $0.kind == .data && $0.payload == press }
            }
        }
        XCTAssertNil(core.callsTo("terminal.attach").last?.params["observe"])
    }

    /// A core that sends observers no RESIZE frames: the observer follows `size` events.
    func testAnObserverFollowsSizeEventsWithoutResizeFrames() async throws {
        core.features.removeAll { $0 == "resize_notifications" }
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: theme, focused: false)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("watching") { core.callsTo("terminal.attach").last?.params["observe"] as? Bool == true }
        XCTAssertNil(core.callsTo("terminal.attach").last?.params["resize_notifications"], "Not offered, not asked for")
        XCTAssertNil(core.callsTo("terminal.attach").last?.params["display"], "Only the active viewer sets colours and cell size")
        let (server, channel) = try XCTUnwrap(attachedServer())
        await waitUntil("surface") { store.surface?.paneIDs == ["t1"] }
        server.emit(type: "size", terminal: "t1", data: ["cols": 30, "rows": 8])
        try await Task.sleep(nanoseconds: 300_000_000)
        server.send(Data((String(repeating: "x", count: 40) + "|").utf8), on: channel)
        let wrapped = { self.store.surface.map { $0.cells.row(1).prefix(11).map(\.symbol).joined() } }
        await waitUntil("wrapped at Core's 30 columns") { wrapped() == "xxxxxxxxxx|" }
        // The same size again changes nothing: the screen stays, though the program draws nothing.
        server.emit(type: "size", terminal: "t1", data: ["cols": 30, "rows": 8])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(wrapped(), "xxxxxxxxxx|")
        // Any size a peer sets is capped, and a cursor past the pane is not drawn on a neighbour.
        server.emit(type: "size", terminal: "t1", data: ["cols": 65535, "rows": 65535])
        try await Task.sleep(nanoseconds: 300_000_000)
        server.send(Data("\u{1b}[2;900Hz".utf8), on: channel)
        XCTAssertNotNil(store.surface?.cursor, "Shown while inside the pane")
        await waitUntil("cursor past the pane hidden") { self.store.surface != nil && self.store.surface?.cursor == nil }
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
        // Mode 1000 reports no motion: a drag sends nothing, and that is not a failure.
        store.sendMouse(HerdrMouseEvent(kind: .drag(0), column: 3, row: 1, modifiers: 0, lines: 1), to: "t1")
        store.sendText("z", to: "t1")
        await waitUntil("typed after the drag") {
            server.recordedFrames().contains { $0.channel == channel && $0.kind == .data && $0.payload == Data("z".utf8) }
        }
        XCTAssertNil(store.inputError, "A drag the program does not report is not an input failure")
    }

    /// A click while older lines show only returns to the live screen: neither its press nor
    /// its drags and release reach a program that takes the mouse.
    func testAClickThatReturnsToTheLiveScreenIsNotReported() async throws {
        store.requiresSurfaceForInput = true
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("attached") { attachedServer() != nil }
        let (server, channel) = try XCTUnwrap(attachedServer())
        server.send(Data(((1...200).map { "line \($0)" }.joined(separator: "\r\n")).utf8), on: channel)
        await waitUntil("output") { store.surface.map { $0.cells.row(0).prefix(4).map(\.symbol).joined() } == "line" }
        await waitUntil("input ready") { store.inputReady }
        store.sendMouse(HerdrMouseEvent(kind: .scrollUp, column: 2, row: 1, modifiers: 0, lines: 5), to: "t1")
        try await Task.sleep(nanoseconds: 200_000_000)
        server.send(Data("\u{1b}[?1002h\u{1b}[?1006h".utf8), on: channel)
        await waitUntil("mouse reporting") { store.surface?.mouseReportingPaneIDs == ["t1"] }
        let reports = { server.recordedFrames().filter { $0.channel == channel && $0.kind == .data }.map(\.payload) }
        for kind: HerdrMouseEvent.Kind in [.down(0), .drag(0), .up(0)] {
            store.sendMouse(HerdrMouseEvent(kind: kind, column: 2, row: 1, modifiers: 0, lines: 1), to: "t1")
        }
        store.sendMouse(HerdrMouseEvent(kind: .down(0), column: 3, row: 1, modifiers: 0, lines: 1), to: "t1")
        await waitUntil("the next click is reported") { reports().contains(Data("\u{1b}[<0;4;2M".utf8)) }
        XCTAssertEqual(reports().map { String(decoding: $0, as: UTF8.self) }, ["\u{1b}[<0;4;2M"],
                       "Only the click on the live screen")
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

    /// When the shown tab goes away, the window moves to another tab and its remembered pane:
    /// that pane, which takes the typing, also shows the cursor.
    func testTheTabShownAfterAClosedOneFocusesTheRememberedPane() async throws {
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("first pane") { store.surface?.paneIDs == ["t1"] }
        store.splitPane("right")
        await waitUntil("both panes") { store.surface?.paneIDs == ["t1", "t2"] && store.surface?.focusedPaneID == "t2" }
        store.createTab(cwd: "/src")
        await waitUntil("new tab") { store.session?.tabs.count == 2 && store.selectedTabID != "tab-t1" }
        let created = try XCTUnwrap(store.selectedTabID)
        let shell = try XCTUnwrap(store.snapshot?.panes.first { $0.tabID == created }?.paneID)
        await waitUntil("new tab shown") { store.surface?.paneIDs == [shell] }
        core.update { $0.terminals.removeAll { $0.address == shell } }
        for server in core.connections where server.eventsChannel != nil { server.emit(type: "removed", terminal: shell) }
        await waitUntil("back on the split tab") { store.selectedTabID == "tab-t1" }
        if store.selectedTabID != "tab-t1" {
            XCTFail("selected \(String(describing: store.selectedTabID)), tabs \(String(describing: store.snapshot?.tabs.map(\.tabID))), "
                + "panes \(String(describing: store.snapshot?.panes.map(\.paneID))), removed \(shell)")
        }
        await waitUntil("split tab shown, now \(String(describing: store.surface?.paneIDs))") { store.surface?.paneIDs == ["t1", "t2"] }
        XCTAssertEqual(store.selectedPaneID, "t2")
        await waitUntil("cursor in the remembered pane") { store.surface?.focusedPaneID == "t2" }
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
        // Closing the bar while a find is still queued: that find, if it begins afterwards,
        // leaves no highlight.
        let queued = Task { await store.findInTerminal("beta", older: true) }
        await Task.yield()
        store.endTerminalFind()
        let late = await queued.value
        XCTAssertNil(late)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual((store.surface?.cells[0, 1].modifier ?? 64) & 64, 0)
    }

    /// A find in one pane ends the search in the others, which would go on following output.
    func testAFindInAnotherPaneEndsTheFirstPanesSearch() async throws {
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: true)
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreStructure.unfiledID, tabID: "tab-t1", paneID: "t1")
        await waitUntil("first pane") { store.surface?.paneIDs == ["t1"] }
        _ = await store.findInTerminal("prompt", older: true)
        let presentation = try XCTUnwrap(store.surfaceStream as? CoreTerminalPresentation)
        XCTAssertTrue(presentation.isSearching(in: "t1"))
        store.splitPane("right")
        await waitUntil("second pane focused") { store.surface?.paneIDs == ["t1", "t2"] && store.selectedPaneID == "t2" }
        _ = await store.findInTerminal("prompt", older: true)
        XCTAssertTrue(presentation.isSearching(in: "t2"))
        XCTAssertFalse(presentation.isSearching(in: "t1"))
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
        let firstRow = { self.store.surface.map { $0.cells.row(0).prefix(7).map(\.symbol).joined() } }
        // Data sent before the presentation routes its channel would be lost, so the surface comes first.
        for _ in 0..<500 where firstRow() != "watched" { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(firstRow(), "watched")
        server.sendResize(cols: 30, rows: 8, on: channel)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(server.recordedFrames().contains { $0.channel == channel && $0.kind == .resize },
                       "An observer never sizes the terminal")
        store.updateTerminalHost(theme: theme, focused: true)
        // Typed at once, before the active attach replaces the observer: held, then sent on it.
        store.sendText("now", to: "t1")
        await waitUntil("typed into the active stream") {
            self.core.connections.contains { server in
                server.recordedFrames().contains { $0.channel != channel && $0.kind == .data && $0.payload == Data("now".utf8) }
            }
        }
        XCTAssertNil(store.inputError)
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
        store.updateTerminalHost(theme: WoolooTheme.named(WoolooTheme.fallbackID)!, focused: false)
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

import XCTest
@testable import wooloo

/// `HerdrStore` connected to herdr-core (Phase 3): state, commands, text panes and fallback
/// input go through `CoreSessionBackend`, against an in-memory `FakeCore`.
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
        XCTAssertEqual(store.session?.spaces.map(\.id), [CoreSessionBackend.spaceID])
        XCTAssertEqual(store.session?.tabs.map(\.id), ["t1"])
        XCTAssertNil(store.presentationProvider)
        XCTAssertEqual(HerdrWindowConnection(store).id, "core:wooloo-ui-test")
        XCTAssertEqual(HerdrWindowConnection(store).backendKind, .core)
    }

    func testNewTabsAreNewTerminalsAndChangesArrive() async throws {
        store.connect(toCore: "wooloo-ui-test")
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreSessionBackend.spaceID)
        store.createTab(cwd: "/src")
        await waitUntil("new tab") { store.session?.tabs.map(\.id) == ["t1", "t2"] }
        XCTAssertEqual(core.callsTo("terminal.run").first?.params["cwd"] as? String, "/src")
        XCTAssertEqual(store.selectedTabID, "t2")
        core.update { $0.terminals.removeAll { $0.address == "t1" } }
        core.connections.first { $0.eventsChannel != nil }?.emit(type: "removed", terminal: "t1")
        await waitUntil("removed tab") { store.session?.tabs.map(\.id) == ["t2"] }
    }

    func testUnsupportedActionsReportAnError() async throws {
        store.connect(toCore: "wooloo-ui-test")
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreSessionBackend.spaceID, tabID: "t1", paneID: "t1")
        store.splitPane("right")
        await waitUntil("error") { store.actionError != nil }
        XCTAssertEqual(store.actionError, CoreProtocolError.unsupported("split panes").localizedDescription)
    }

    func testPanesShowTheirTextAndTakeFallbackInput() async throws {
        store.requiresSurfaceForInput = true
        store.connect(toCore: "wooloo-ui-test")
        store.setPresentationActive(true)
        await waitUntil("connected") { store.isConnected }
        store.select(workspaceID: CoreSessionBackend.spaceID, tabID: "t1", paneID: "t1")
        await waitUntil("pane text") { store.paneText["t1"] == "$ make\nok\n" }
        XCTAssertTrue(store.inputReady, "Without a live surface, input goes through the fallback")
        store.sendKey("ctrl+c", to: "t1")
        await waitUntil("keys") { !core.callsTo("terminal.keys").isEmpty }
        XCTAssertEqual(core.callsTo("terminal.keys").first?.params["keys"] as? [String], ["ctrl+c"])
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

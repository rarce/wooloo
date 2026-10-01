import SwiftUI
import XCTest
@testable import xherdr

/// The command catalog shared by the menu bar and the palette, the palette's ordering and
/// matching, and running a command from it.
@MainActor
final class CommandPaletteTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "CommandPaletteTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let everything = XherdrCommandAvailability(isConnected: true, hasSpace: true, tabCount: 3,
                                                       hasPane: true, hasFiles: true)

    // MARK: Catalog

    func testEveryCommandIsAKnownActionAndUnique() {
        let actions = XherdrCommandItem.all.map(\.action)
        XCTAssertEqual(Set(actions).count, actions.count)
        for action in actions {
            XCTAssertNotNil(HerdrCommand(action: action), "\(action) must dispatch to a command")
        }
        let shortcuts = XherdrCommandItem.all.compactMap(\.shortcutLabel)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count, "No two commands share a menu shortcut")
    }

    func testShortcutLabelsUseMacNotation() {
        XCTAssertEqual(XherdrCommandItem.named("project_search")?.shortcutLabel, "⇧⌘F")
        XCTAssertEqual(XherdrCommandItem.named("zoom")?.shortcutLabel, "⇧⌘↩")
        XCTAssertEqual(XherdrCommandItem.named("focus_pane_left")?.shortcutLabel, "⌥⌘←")
        XCTAssertEqual(XherdrCommandItem.named("toggle_sidebar")?.shortcutLabel, "⌃⌘S")
        XCTAssertNil(XherdrCommandItem.named("close_pane")?.shortcutLabel)
    }

    func testAvailabilityFollowsTheWindowState() {
        let offline = XherdrCommandAvailability()
        let available = Set(XherdrCommandItem.all.filter { $0.isAvailable(offline) }.map(\.action))
        XCTAssertTrue(available.isSuperset(of: ["settings", "help", "command_palette", "project_search"]))
        XCTAssertFalse(available.contains("new_tab"))
        XCTAssertFalse(available.contains("quick_open"), "Go to File needs the explorer's location")
        var oneTab = everything
        oneTab.tabCount = 1
        XCTAssertTrue(XherdrCommandItem.named("rename_tab")!.isAvailable(oneTab))
        XCTAssertFalse(XherdrCommandItem.named("next_tab")!.isAvailable(oneTab), "Cycling needs two tabs")
        XCTAssertFalse(XherdrCommandItem.named("close_tab")!.isAvailable(oneTab), "The last tab is not closed")
    }

    // MARK: Model

    private func presented(_ availability: XherdrCommandAvailability? = nil,
                           bindings: [String: String] = [:]) -> CommandPaletteModel {
        let model = CommandPaletteModel(defaults: defaults)
        let items = XherdrCommandItem.all.filter { $0.isAvailable(availability ?? everything) }
        model.present(items, bindings: bindings)
        return model
    }

    func testEmptyQueryListsRecentThenAlphabetical() {
        let model = CommandPaletteModel(defaults: defaults)
        model.record("zoom")
        model.record("new_tab")
        model.present(XherdrCommandItem.all, bindings: ["new_tab": "⌃B C"])
        let labels = model.results.map(\.item.label)
        XCTAssertEqual(Array(labels.prefix(2)), ["Space: New Tab", "Pane: Zoom Pane"])
        XCTAssertEqual(Array(labels.dropFirst(2)), labels.dropFirst(2).sorted())
        XCTAssertFalse(labels.contains("View: Command Palette…"), "The palette does not list itself")
        XCTAssertEqual(model.results.first?.binding, "⌃B C")
        XCTAssertTrue(model.results[0].isRecent)
    }

    func testQueryMatchesLabelsAndRecentFirst() {
        let model = presented()
        model.query = "split"
        XCTAssertEqual(Set(model.results.map(\.item.action)), ["split_vertical", "split_horizontal"])
        model.query = "pane split down"
        XCTAssertEqual(model.results.first?.item.action, "split_horizontal")
        XCTAssertEqual(model.results.first.map { Set($0.positions).isSuperset(of: [0, 1, 2, 3]) }, true)
        model.record("split_vertical")
        model.dismiss()
        let again = presented()
        again.query = "split"
        XCTAssertEqual(again.results.first?.item.action, "split_vertical", "Recently run commands come first")
        again.query = "zzz"
        XCTAssertTrue(again.results.isEmpty)
    }

    func testRecentListIsBounded() {
        let model = CommandPaletteModel(defaults: defaults)
        for index in 0..<30 { model.record("action\(index)") }
        model.record("action5")
        XCTAssertEqual(model.recentActions.count, CommandPaletteModel.maximumRecent)
        XCTAssertEqual(model.recentActions.first, "action5")
    }

    func testUnavailableCommandsAreNotListed() {
        let model = presented(XherdrCommandAvailability())
        model.query = "split"
        XCTAssertTrue(model.results.isEmpty)
    }

    // MARK: Running

    func testCommandRunsTheSelectionAndClosesGoToFile() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let repo = try sandbox.repository("repo")
        let window = ContentWindowModel(defaults: defaults)
        let commands = ContentCommands(window: window, herdr: HerdrStore(), documents: WorkspaceDocumentStore(),
                                       search: WorkspaceSearchModel(), explorerLocation: repo)
        commands.perform(.quickOpen)
        XCTAssertTrue(window.quickOpen.isPresented)
        commands.perform(.commandPalette)
        XCTAssertTrue(window.commandPalette.isPresented)
        XCTAssertFalse(window.quickOpen.isPresented, "Only one picker is open at a time")
        XCTAssertFalse(window.commandPalette.results.contains { $0.item.action == "new_tab" },
                       "Disconnected, Herdr commands are not offered")
        window.commandPalette.query = "toggle"
        XCTAssertEqual(window.commandPalette.results.count, 2)
        commands.perform(.commandPalette)
        XCTAssertEqual(window.commandPalette.selection, 1, "⇧⌘P again selects the next command")
        window.commandPalette.query = "toggle sidebar"
        XCTAssertEqual(window.commandPalette.selectedMatch?.item.action, "toggle_sidebar")
        commands.runCommandPaletteSelection()
        XCTAssertFalse(window.commandPalette.isPresented)
        XCTAssertFalse(window.showsSidebar)
        XCTAssertEqual(window.commandPalette.recentActions.first, "toggle_sidebar")
    }
}


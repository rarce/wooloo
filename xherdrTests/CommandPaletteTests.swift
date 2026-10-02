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
        // Editor and explorer commands act where the keyboard is, so each group is checked alone.
        for group in [nil, "Editor", "Explorer"] {
            let shortcuts = XherdrCommandItem.all
                .filter { group == nil ? !["Editor", "Explorer"].contains($0.category) : $0.category == group }
                .compactMap(\.shortcutLabel)
            XCTAssertEqual(Set(shortcuts).count, shortcuts.count, "No two \(group ?? "menu") commands share a shortcut")
        }
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
        XCTAssertFalse(available.contains("new_untitled_file"), "An untitled file needs a location to save in")
        XCTAssertTrue(XherdrCommandItem.named("new_untitled_file")!.isAvailable(everything))
        XCTAssertEqual(XherdrCommandItem.named("new_untitled_file")?.shortcutLabel, "⌃⌘N")
        var oneTab = everything
        oneTab.tabCount = 1
        XCTAssertTrue(XherdrCommandItem.named("rename_tab")!.isAvailable(oneTab))
        XCTAssertFalse(XherdrCommandItem.named("next_tab")!.isAvailable(oneTab), "Cycling needs two tabs")
        XCTAssertFalse(XherdrCommandItem.named("close_tab")!.isAvailable(oneTab), "The last tab is not closed")
    }

    func testEditorCommandsNeedAnOpenFileAndCursorsItsSource() {
        var preview = everything
        preview.hasFileDocument = true
        let save = XherdrCommandItem.named("editor_save")!
        let cursor = XherdrCommandItem.named("editor_add_cursor_below")!
        XCTAssertFalse(save.isAvailable(everything), "No file is open")
        XCTAssertTrue(save.isAvailable(preview))
        XCTAssertFalse(cursor.isAvailable(preview), "A Markdown preview takes no cursors")
        preview.showsSource = true
        XCTAssertTrue(cursor.isAvailable(preview))
        XCTAssertEqual(HerdrCommand(action: "editor_find"), .editor(.find))
        XCTAssertEqual(cursor.label, "Editor: Add Cursor Below")
        XCTAssertEqual(cursor.shortcutLabel, "⌥⌘↓")
    }

    func testExplorerCommandsFollowTheFocusedTree() {
        XCTAssertEqual(HerdrCommand(action: "explorer_rename"), .explorer(.rename))
        XCTAssertNil(ExplorerFileCommand(paletteAction: "explorer_selectNext"), "Moving through rows stays on the keys")
        let rename = XherdrCommandItem.named("explorer_rename")!
        XCTAssertEqual(rename.label, "Explorer: Rename…")
        XCTAssertEqual(rename.shortcutLabel, "↩")
        XCTAssertFalse(rename.isAvailable(everything))
        var focused = everything
        focused.explorerActions = ["explorer_rename"]
        XCTAssertTrue(rename.isAvailable(focused))
        XCTAssertFalse(XherdrCommandItem.named("explorer_trash")!.isAvailable(focused))
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

    func testExplorerCommandsReachTheTreeWhileItHadFocus() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let repo = try sandbox.repository("repo")
        let window = ContentWindowModel(defaults: defaults)
        let commands = ContentCommands(window: window, herdr: HerdrStore(), documents: WorkspaceDocumentStore(),
                                       search: WorkspaceSearchModel(), explorerLocation: repo)
        var focused = false
        var received: [ExplorerFileCommand] = []
        window.explorer.register(UUID(), available: { focused && [.newFile, .copyPath].contains($0) }) {
            received.append($0)
        }
        commands.perform(.commandPalette)
        XCTAssertFalse(window.commandPalette.results.contains { $0.item.category == "Explorer" }, "The tree lacks focus")
        window.commandPalette.dismiss()

        focused = true
        commands.perform(.commandPalette)
        XCTAssertEqual(Set(window.commandPalette.results.filter { $0.item.category == "Explorer" }.map(\.item.action)),
                       ["explorer_new_file", "explorer_copy_path"])
        window.commandPalette.query = "explorer new file"
        // Focus moves to the palette's field and back before the command runs.
        focused = false
        commands.runCommandPaletteSelection()
        XCTAssertEqual(received, [.newFile], "The command runs although the tree has not taken focus back yet")
    }

    func testEditorCommandsReachTheShownDocument() async throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let repo = try sandbox.repository("repo", files: ["a.txt": "one\n", "b.md": "# b\n"])
        let window = ContentWindowModel(defaults: defaults)
        let documents = WorkspaceDocumentStore()
        let commands = ContentCommands(window: window, herdr: HerdrStore(), documents: documents,
                                       search: WorkspaceSearchModel(), explorerLocation: repo)
        var received: [EditorCommand] = []
        let view = UUID()
        window.editor.register(view) { received.append($0) }

        commands.perform(.commandPalette)
        XCTAssertFalse(window.commandPalette.results.contains { $0.item.category == "Editor" }, "No file is open")
        window.commandPalette.dismiss()

        documents.open(.file, path: "a.txt", at: repo)
        for _ in 0..<300 where documents.documents.first?.isLoading != false { try await Task.sleep(nanoseconds: 10_000_000) }
        commands.perform(.commandPalette)
        window.commandPalette.query = "editor find"
        XCTAssertEqual(window.commandPalette.selectedMatch?.item.action, "editor_find")
        commands.runCommandPaletteSelection()
        XCTAssertEqual(received, [.find])

        documents.open(.file, path: "b.md", at: repo)
        for _ in 0..<300 where documents.document(documents.activeID!)?.isLoading != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        commands.perform(.commandPalette)
        let actions = Set(window.commandPalette.results.map(\.item.action))
        XCTAssertTrue(actions.contains("editor_find"), "A Markdown preview can be searched")
        XCTAssertFalse(actions.contains("editor_select_next"), "but takes no cursors")
        window.commandPalette.dismiss()

        window.editor.unregister(UUID())
        commands.perform(.editor(.save))
        XCTAssertEqual(received, [.find, .save], "Another view's unregistering leaves this one")
        window.editor.unregister(view)
        commands.perform(.editor(.save))
        XCTAssertEqual(received, [.find, .save])
    }

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


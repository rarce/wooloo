import Foundation

/// What the Rename alert renames.
enum HerdrRenameTarget: Equatable {
    case workspace(String)
    case tab(String)
    case agent(String)

    var title: String {
        switch self {
        case .workspace: return "Rename Space"
        case .tab: return "Rename Tab"
        case .agent: return "Rename Agent"
        }
    }
}

/// What the Close confirmation closes, with the label it shows.
enum HerdrCloseTarget: Equatable {
    case workspace(String, String)
    case tab(String, String)
    case pane(String)

    var title: String {
        switch self {
        case .workspace(_, let label): return "Close Space “\(label)”?"
        case .tab(_, let label): return "Close Tab “\(label)”?"
        case .pane(let id): return "Close Pane \(id)?"
        }
    }
}

extension HerdrStore {
    var selectedWorkspace: HerdrWorkspace? {
        snapshot?.workspaces.first { $0.workspaceID == selectedWorkspaceID }
    }

    /// The tabs of the selected Space, in Herdr's order.
    var selectedTabs: [HerdrTab] {
        snapshot?.tabs.filter { $0.workspaceID == selectedWorkspaceID } ?? []
    }

    /// The panes of the selected tab.
    var selectedPanes: [HerdrPane] {
        snapshot?.panes.filter { $0.tabID == selectedTabID } ?? []
    }
}

/// The main window's own state: sidebars, sheets, the Search tab and the rename or close
/// waiting for confirmation. `ContentView` renders it and `ContentCommands` changes it.
@MainActor
final class ContentWindowModel: ObservableObject {
    @Published var showsSidebar = true
    @Published var showsFilesSidebar = true
    @Published var showsSessionPicker = false
    @Published var showsSettings = false
    @Published var settingsShowShortcuts = false
    @Published var requestedSessionName = ""
    /// A document with unsaved edits the user asked to close.
    @Published var pendingCloseDocumentID: String?
    /// The untitled document the Save As sheet asks a path for.
    @Published var saveAsDocumentID: String?
    /// Bumped to reload the explorer and repository views.
    @Published var fileRefreshVersion = 0
    @Published var showsSearchTab = false
    @Published var renameTarget: HerdrRenameTarget?
    @Published var renameText = ""
    @Published var closeTarget: HerdrCloseTarget?
    /// Go to File; `QuickOpenOverlay` observes it.
    /// The command palette; `CommandPaletteOverlay` observes it.
    let commandPalette: CommandPaletteModel

    /// Tests keep the palette's recent commands out of the app's defaults.
    let quickOpen: QuickOpenModel
    /// The shown document's editor, for editor commands from the palette.
    let editor = EditorCommandTarget()
    /// The explorer's Files and Changes trees, for their file commands from the palette.
    let explorer = ExplorerCommandTarget()
    /// A tab dragged in the tab bar; only the tabs observe it, so hovering redraws only them.
    let tabDrag = TabDragModel()

    /// Tests keep the pickers' recent commands and options out of the app's defaults.
    init(defaults: UserDefaults = .standard) {
        quickOpen = QuickOpenModel(defaults: defaults)
        commandPalette = CommandPaletteModel(defaults: defaults)
    }
}

/// Effects of window commands beyond Herdr and the window, replaceable in tests.
struct ContentCommandEffects {
    /// Reads xherdr's shortcut map and themes again from Herdr's config.
    var reloadAppConfig: () -> Void = {}
    var forgetRecentFileResults: () -> Void = { WorkspaceFiles.forgetRecentResults() }
    var copy: (String) -> Void = { AppActions.copy($0) }
    var reveal: (String) -> Void = { AppActions.reveal($0) }
}

/// What shortcuts, menu items and the window's dialogs do to Herdr, the open documents, project
/// search and the window's state. Built by `ContentView` for each use.
@MainActor
struct ContentCommands {
    let window: ContentWindowModel
    let herdr: HerdrStore
    let documents: WorkspaceDocumentStore
    let search: WorkspaceSearchModel
    /// Where project search looks: the explorer's location.
    var explorerLocation: WorkspaceFileLocation?
    var effects = ContentCommandEffects()
    /// An action's Herdr key binding in Mac notation, shown in the command palette.
    var bindingLabel: (String) -> String? = { _ in nil }

    /// Which commands apply now, for the menu bar and the command palette.
    var availability: XherdrCommandAvailability {
        let document = documents.activeID.flatMap(documents.document)
        let hasFileDocument = document.map { $0.kind == .file && !$0.isLoading && ($0.version != nil || $0.isUntitled) } ?? false
        let showsSource = document.map {
            !MarkdownDisplayMode.supports($0.path) || $0.markdownMode != .preview
        } ?? false
        return XherdrCommandAvailability(isConnected: herdr.isConnected, hasSpace: herdr.selectedWorkspace != nil,
                                         tabCount: herdr.selectedTabs.count, hasPane: herdr.selectedPaneID != nil && herdr.surfaceLayout?.popupTerminalID == nil,
                                         hasFiles: explorerLocation != nil, hasFileDocument: hasFileDocument,
                                         showsSource: showsSource,
                                         explorerActions: Set(ExplorerFileCommand.paletteCommands
                                             .filter(window.explorer.isAvailable).map(\.paletteAction)))
    }

    func perform(_ action: String) {
        guard let command = HerdrCommand(action: action) else { return }
        perform(command)
    }

    func perform(_ command: HerdrCommand) {
        if herdr.surfaceLayout?.popupTerminalID != nil {
            switch command {
            case .focusPane, .splitPane, .zoom, .closePane: return
            default: break
            }
        }
        let tabs = herdr.selectedTabs
        switch command {
        case .help:
            window.settingsShowShortcuts = true
            window.showsSettings = true
        case .settings:
            window.settingsShowShortcuts = false
            window.showsSettings = true
        case .newWorkspace:
            documents.activeID = nil
            herdr.createWorkspace()
        case .newTab:
            documents.activeID = nil
            herdr.createTab()
        case .newUntitledFile: newUntitledFile()
        case .cycleTab(let delta):
            guard let tabID = HerdrCommand.tab(delta, from: herdr.selectedTabID, in: tabs.map(\.tabID)) else { return }
            herdr.select(tabID: tabID)
            documents.activeID = nil
        case .switchTab(let number):
            guard tabs.indices.contains(number - 1) else { return }
            herdr.select(tabID: tabs[number - 1].tabID)
            documents.activeID = nil
        case .toggleSidebar: window.showsSidebar.toggle()
        case .focusPane(let direction): herdr.focusPane(direction)
        case .splitPane(let direction): herdr.splitPane(direction)
        case .zoom: herdr.zoomPane()
        case .reloadConfig:
            effects.reloadAppConfig()
            herdr.reloadConfig()
        case .toggleFilesSidebar: window.showsFilesSidebar.toggle()
        case .refreshFiles:
            effects.forgetRecentFileResults()
            window.fileRefreshVersion += 1
        case .switchSession:
            window.showsSidebar = true
            window.requestedSessionName = herdr.sessionName
            window.showsSessionPicker = true
        case .renameWorkspace:
            guard let workspace = herdr.selectedWorkspace else { return }
            window.renameText = workspace.label
            window.renameTarget = .workspace(workspace.workspaceID)
        case .closeWorkspace:
            guard let workspace = herdr.selectedWorkspace else { return }
            window.closeTarget = .workspace(workspace.workspaceID, workspace.label)
        case .renameTab:
            guard let tab = tabs.first(where: { $0.tabID == herdr.selectedTabID }) else { return }
            window.renameText = tab.label
            window.renameTarget = .tab(tab.tabID)
        case .closeTab:
            guard tabs.count > 1, let tab = tabs.first(where: { $0.tabID == herdr.selectedTabID }) else { return }
            window.closeTarget = .tab(tab.tabID, tab.label)
        case .closeCurrentTab:
            if documents.activeID == WorkspaceSearchModel.tabID {
                closeSearch()
            } else if let activeID = documents.activeID {
                closeDocument(activeID)
            } else {
                perform(.closeTab)
            }
        case .closePane:
            guard let paneID = herdr.selectedPaneID else { return }
            window.closeTarget = .pane(paneID)
        case .projectSearch(let replace): openSearch(replace: replace)
        case .quickOpen:
            if window.quickOpen.isPresented {
                window.quickOpen.move(1)
            } else if let explorerLocation {
                window.commandPalette.dismiss()
                let current = documents.activeID.flatMap(documents.document)
                window.quickOpen.present(at: explorerLocation, recents: documents.recentPaths(at: explorerLocation),
                                         current: current?.location == explorerLocation ? current?.path : nil)
            }
        case .editor(let command):
            guard availability.hasFileDocument else { return }
            window.editor.perform(command)
        // Listed only while the tree had focus; the explorer checks its selection again.
        case .explorer(let command):
            window.explorer.perform(command)
        case .commandPalette:
            if window.commandPalette.isPresented {
                window.commandPalette.move(1)
            } else {
                window.quickOpen.dismiss()
                let availability = availability
                let items = XherdrCommandItem.all.filter { $0.isAvailable(availability) }
                let bindings = Dictionary(items.compactMap { item in bindingLabel(item.action).map { (item.action, $0) } },
                                          uniquingKeysWith: { first, _ in first })
                window.commandPalette.present(items, bindings: bindings)
            }
        case .copyPaneDirectory, .revealPaneDirectory:
            guard let cwd = herdr.selectedPanes.first(where: { $0.paneID == herdr.selectedPaneID })?.cwd else { return }
            if command == .copyPaneDirectory { effects.copy(cwd) } else { effects.reveal(cwd) }
        }
    }

    /// Runs the command palette's selected command where the keyboard was before it opened.
    func runCommandPaletteSelection() {
        let palette = window.commandPalette
        guard let item = palette.selectedMatch?.item else { return }
        palette.dismiss()
        palette.record(item.action)
        perform(item.action)
    }

    /// Opens Go to File's selected file, at the line and column typed after its name, or creates
    /// the typed file and opens it; the returned task does the creating.
    @discardableResult
    func openQuickOpenSelection() -> Task<Void, Never>? {
        let quickOpen = window.quickOpen
        guard let location = quickOpen.location else { return nil }
        let query = QuickOpenQuery(quickOpen.query)
        let reveal = query.line.map { line in
            WorkspaceDocumentReveal(line: line, range: query.column.map { NSRange(location: max($0 - 1, 0), length: 0) })
        }
        if let path = quickOpen.selectedCreatePath {
            return Task { [documents, window] in
                let created = await Task.detached(priority: .userInitiated) {
                    Result { try WorkspaceFiles.createFile(path, at: location) }
                }.value
                switch created {
                case .success:
                    quickOpen.dismiss(restoringFocus: false)
                    documents.open(.file, path: path, at: location, focus: true)
                    window.fileRefreshVersion += 1
                case .failure(let failure):
                    quickOpen.fail(failure.localizedDescription)
                }
            }
        }
        guard let match = quickOpen.selectedMatch else { return nil }
        quickOpen.dismiss(restoringFocus: false)
        documents.open(.file, path: match.path, at: location, reveal: reveal, focus: true)
        return nil
    }

    /// Shows the Search tab on the explorer's location and focuses its field. The first time
    /// it is shown, search learns which files have unsaved edits and reloads the documents a
    /// replace writes.
    func openSearch(replace: Bool) {
        if !window.showsSearchTab {
            search.hasUnsavedEdits = { [documents] location, path in
                documents.hasUnsavedEdits(at: location, path: path)
            }
            search.didModifyFiles = { [documents, window] location, paths in
                documents.reloadUnedited(paths, at: location)
                window.fileRefreshVersion += 1
            }
        }
        window.showsSearchTab = true
        if replace { search.showsReplace = true }
        search.setLocation(explorerLocation)
        documents.activeID = WorkspaceSearchModel.tabID
        search.requestFocus()
    }

    func closeSearch() {
        window.showsSearchTab = false
        if documents.activeID == WorkspaceSearchModel.tabID { documents.activeID = nil }
    }

    /// Opens an empty "Untitled-N" tab at the explorer's location, where saving it starts.
    func newUntitledFile() {
        guard let explorerLocation else { return }
        documents.newUntitled(at: explorerLocation)
    }

    /// Saves a document; an untitled one first asks where, with the Save As sheet.
    func saveDocument(_ id: String) {
        guard let document = documents.document(id) else { return }
        if document.isUntitled {
            window.saveAsDocumentID = id
        } else {
            documents.save(id) { [window] in window.fileRefreshVersion += 1 }
        }
    }

    /// Saves the Save As sheet's untitled document at the path typed, relative to the Space
    /// root, then refreshes the explorer. Returns the error to show in the sheet, or nil once saved.
    func saveUntitled(as path: String) async -> String? {
        guard let id = window.saveAsDocumentID else { return nil }
        if let error = await documents.saveUntitled(id, as: path) { return error }
        window.saveAsDocumentID = nil
        window.fileRefreshVersion += 1
        return nil
    }

    /// Closes a document, or asks first when it has unsaved edits.
    func closeDocument(_ id: String, force: Bool = false) {
        if !documents.close(id, force: force) { window.pendingCloseDocumentID = id }
    }

    /// Applies the Rename alert's text. An empty name resets an agent to its detected name and
    /// leaves Spaces and tabs unchanged.
    func commitRename() {
        let label = window.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { window.renameTarget = nil }
        guard let target = window.renameTarget else { return }
        if case .agent(let id) = target {
            herdr.renameAgent(id, to: label.isEmpty ? nil : label)
            return
        }
        guard !label.isEmpty else { return }
        switch target {
        case .workspace(let id): herdr.renameWorkspace(id, to: label)
        case .tab(let id): herdr.renameTab(id, to: label)
        case .agent: break
        }
    }

    func commitClose() {
        defer { window.closeTarget = nil }
        switch window.closeTarget {
        case .workspace(let id, _):
            documents.activeID = nil
            herdr.closeWorkspace(id)
        case .tab(let id, _): herdr.closeTab(id)
        case .pane(let id): herdr.closePane(id)
        case nil: break
        }
    }
}

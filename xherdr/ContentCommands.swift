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
    /// Bumped to reload the explorer and repository views.
    @Published var fileRefreshVersion = 0
    @Published var showsSearchTab = false
    @Published var renameTarget: HerdrRenameTarget?
    @Published var renameText = ""
    @Published var closeTarget: HerdrCloseTarget?
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

    func perform(_ action: String) {
        guard let command = HerdrCommand(action: action) else { return }
        perform(command)
    }

    func perform(_ command: HerdrCommand) {
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
        case .copyPaneDirectory, .revealPaneDirectory:
            guard let cwd = herdr.selectedPanes.first(where: { $0.paneID == herdr.selectedPaneID })?.cwd else { return }
            if command == .copyPaneDirectory { effects.copy(cwd) } else { effects.reveal(cwd) }
        }
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

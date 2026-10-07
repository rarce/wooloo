import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.xherdrTypography) private var typography
    @ObservedObject private var runtime = HerdrRuntimeModel.shared
    private var managesRuntime = true
    @StateObject private var herdr = HerdrStore()
    @StateObject private var window = ContentWindowModel()
    @State private var shortcutMap = HerdrShortcutMap.load()
    @State private var shortcutPrefixActive = false
    @State private var availableSessions: [String] = []
    @State private var machines: [HerdrMachineProfile] = []
    /// The SSH machine whose files and repository the explorer shows; nil is this Mac.
    @State private var explorerMachine: HerdrMachineProfile?
    @StateObject private var documentStore = WorkspaceDocumentStore()
    private var documents: [WorkspaceDocument] { documentStore.visibleDocuments }
    private var activeDocumentID: String? {
        get { documentStore.activeID }
        nonmutating set { documentStore.activeID = newValue }
    }
    /// The focused editor tab's file or changes, for the explorer to select.
    private var activeFile: WorkspaceActiveFile? {
        guard let id = commands.focusedDocumentID, let document = documentStore.document(id),
              document.kind != .commit, !document.isUntitled else { return nil }
        return WorkspaceActiveFile(location: document.location, path: document.path)
    }
    @StateObject private var search = WorkspaceSearchModel()
    @State private var explorerLocation: WorkspaceFileLocation?
    @AppStorage("SidebarWidth") private var sidebarWidth = 206.0
    @AppStorage("FilesSidebarWidth") private var filesSidebarWidth = 244.0
    @AppStorage("AgentsInSelectedSpaceOnly") private var agentsInSelectedSpaceOnly = false
    @State private var followsHerdrAgentView = true
    @State private var popupDocument: (session: String, space: String?, tab: String?, document: String)?

    @StateObject private var themes = ThemeStore()
    @StateObject private var notifier = HerdrNotifier()
    @AppStorage(XherdrTypography.baseKey) private var interfaceTextSize = XherdrTypography.defaultBase
    @AppStorage(XherdrTypography.codeKey) private var codeTextSize = XherdrTypography.defaultCode
    private var textScale: XherdrTypography {
        XherdrTypography(base: interfaceTextSize.clamped(to: XherdrTypography.baseRange),
                         code: codeTextSize.clamped(to: XherdrTypography.codeRange))
    }
    private var theme: XherdrTheme { themes.theme }
    private var sidebarBackground: Color { theme.sidebarBackground }
    private var barBackground: Color { theme.barBackground }

    private var selectedWorkspace: HerdrWorkspace? { herdr.selectedWorkspace }
    private var selectedTabs: [HerdrTab] { herdr.selectedTabs }
    private var selectedPanes: [HerdrPane] { herdr.selectedPanes }

    init() {}

    private func presentPopup(_ terminalID: String?) {
        if terminalID != nil {
            if let activeDocumentID {
                popupDocument = (herdr.sessionName, herdr.selectedWorkspaceID, herdr.selectedTabID, activeDocumentID)
                self.activeDocumentID = nil
            }
            window.quickOpen.dismiss()
            window.commandPalette.dismiss()
        } else if let previous = popupDocument {
            popupDocument = nil
            guard activeDocumentID == nil, herdr.sessionName == previous.session,
                  herdr.selectedWorkspaceID == previous.space, herdr.selectedTabID == previous.tab,
                  documentStore.document(previous.document) != nil || previous.document == WorkspaceSearchModel.tabID else { return }
            activeDocumentID = previous.document
        }
    }

    /// Tests pass a store for a fake Herdr session and documents opened beforehand.
    init(herdr: HerdrStore, documents: WorkspaceDocumentStore? = nil) {
        _herdr = StateObject(wrappedValue: herdr)
        managesRuntime = false
        if let documents { _documentStore = StateObject(wrappedValue: documents) }
    }

    private var windowContent: some View {
        GeometryReader { geometry in
            if managesRuntime && runtime.showsSetup {
                HerdrSetupView(runtime: runtime)
            } else {
                content(totalWidth: geometry.size.width)
            }
        }
        .frame(minWidth: 850, minHeight: managesRuntime && runtime.showsSetup ? 580 : 380)
        .preferredColorScheme(theme.colorScheme)
        .environment(\.xherdrTheme, theme)
        .environment(\.xherdrTypography, textScale)
        .tint(theme.accent)
        .task {
            if managesRuntime {
                guard await runtime.prepare(session: herdr.sessionName) else { return }
            }
            herdr.start()
        }
        .onChange(of: runtime.showsSetup) { _, showsSetup in
            guard managesRuntime else { return }
            if showsSetup {
                herdr.stop()
            } else {
                herdr.connect(to: runtime.connectedSession ?? herdr.sessionName)
                shortcutMap = HerdrShortcutMap.load()
            }
        }
        .focusedSceneValue(\.xherdrCommands, XherdrCommandContext(
            availability: commands.availability,
            showsSidebar: window.showsSidebar,
            showsFilesSidebar: window.showsFilesSidebar,
            perform: handleShortcut
        ))
        .onDisappear {
            herdr.stop()
            Task {
                do { try await documentStore.flushPersistence() }
                catch { documentStore.persistenceError = error.localizedDescription }
            }
        }
        .overlay { pickers }
        .overlay { HerdrToastStack(notifier: notifier) }
        .overlay { InactiveWindowOverlay(background: theme.contentBackground) }
        .background { WorkspaceSessionWindowGuard(store: documentStore).frame(width: 0, height: 0) }
    }

    var body: some View {
        followingPanels(windowContent)
        .onAppear {
            notifier.onOpenPane = { focusPane($0) }
            notifier.reloadSettings()
        }
        .onReceive(herdr.snapshotPublisher) { snapshot in
            notifier.process(snapshot, selectedPaneID: herdr.selectedPaneID)
        }
        .onChange(of: herdr.selectedPaneID) { _, paneID in notifier.acknowledge(paneID: paneID) }
        .onChange(of: herdr.surfaceLayout?.popupTerminalID) { _, terminalID in presentPopup(terminalID) }
        .onChange(of: herdr.sessionName) { _, _ in
            notifier.reset()
            followsHerdrAgentView = true
        }
        // Documents belong to the Space they were opened in.
        .onChange(of: herdr.selectedWorkspaceID.map { "\(herdr.sessionName)|\($0)" }, initial: true) { _, space in
            documentStore.showSpace(space)
            window.focusedPanel = .main
        }
        // Editing a preview keeps it open, so later previews never replace unsaved work.
        .onChange(of: documents.contains { $0.isPreview && $0.isDirty }) { _, edited in
            if edited { documentStore.keepEditedPreviewsOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.acknowledge(paneID: herdr.selectedPaneID)
        }
        .sheet(isPresented: $window.showsSettings) {
            HerdrSettingsView(socketPath: herdr.socketPath, sessionName: herdr.sessionName,
                              showShortcuts: window.settingsShowShortcuts,
                              showRemoteAccess: window.settingsShowRemoteAccess) {
                shortcutMap = HerdrShortcutMap.load()
                herdr.reloadAgentViewSettings()
                themes.reload()
                notifier.reloadSettings()
                notifier.refreshDockBadge()
            }
            .environment(\.xherdrTheme, theme)
            .environment(\.xherdrTypography, textScale)
        }
        .alert("Herdr action failed", isPresented: Binding(
            get: { herdr.actionError != nil },
            set: { if !$0 { herdr.clearActionError() } }
        )) {
            Button("OK", role: .cancel) { herdr.clearActionError() }
        } message: {
            Text(herdr.actionError ?? "")
        }
        .alert("Editor session recovery", isPresented: Binding(
            get: { documentStore.persistenceError != nil },
            set: { if !$0 { documentStore.persistenceError = nil } }
        )) {
            Button("OK", role: .cancel) { documentStore.persistenceError = nil }
        } message: {
            Text(documentStore.persistenceError ?? "")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(
            get: { window.pendingCloseDocumentID != nil },
            set: { if !$0 { window.pendingCloseDocumentID = nil } }
        )) {
            Button("Discard and close", role: .destructive) {
                if let id = window.pendingCloseDocumentID { closeDocument(id, force: true) }
                window.pendingCloseDocumentID = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { window.saveAsDocumentID != nil }, set: { if !$0 { window.saveAsDocumentID = nil } }
        )) {
            if let id = window.saveAsDocumentID, let document = documentStore.document(id) {
                UntitledSaveSheet(title: document.title, location: document.location,
                                  save: { await commands.saveUntitled(as: $0) },
                                  cancel: { window.saveAsDocumentID = nil })
                    .environment(\.xherdrTheme, theme)
                    .environment(\.xherdrTypography, textScale)
            }
        }
        .alert(window.renameTarget?.title ?? "Rename", isPresented: Binding(
            get: { window.renameTarget != nil }, set: { if !$0 { window.renameTarget = nil } }
        )) {
            TextField("Name", text: $window.renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { window.renameTarget = nil }
        }
        .confirmationDialog(window.closeTarget?.title ?? "Close?", isPresented: Binding(
            get: { window.closeTarget != nil }, set: { if !$0 { window.closeTarget = nil } }
        )) {
            Button("Close", role: .destructive) { commitClose() }
        } message: {
            Text("Processes running in its terminals will be terminated.")
        }
    }

    /// Go to File and the command palette, over the whole window.
    private var pickers: some View {
        ZStack {
            QuickOpenOverlay(model: window.quickOpen) { commands.openQuickOpenSelection() }
            CommandPaletteOverlay(model: window.commandPalette) { commands.runCommandPaletteSelection() }
        }
        .environment(\.xherdrTheme, theme)
        .environment(\.xherdrTypography, textScale)
    }

    private func content(totalWidth: CGFloat) -> some View {
        // Keep the terminal area usable however wide the sidebars are dragged.
        let mainMinimum = 360.0
        let left = window.showsSidebar ? sidebarWidth : 0
        let right = window.showsFilesSidebar ? filesSidebarWidth : 0
        return HStack(spacing: 0) {
            if window.showsSidebar {
                sidebar.frame(width: sidebarWidth)
                SidebarResizeHandle(width: $sidebarWidth, defaultWidth: 206, edge: .leading,
                                    range: 160...max(160, min(420, totalWidth - right - mainMinimum)))
            }
            mainArea
            if window.showsFilesSidebar {
                SidebarResizeHandle(width: $filesSidebarWidth, defaultWidth: 244, edge: .trailing,
                                    range: 200...max(200, min(560, totalWidth - left - mainMinimum)))
                WorkspaceBrowserView(localSnapshot: herdr.snapshot,
                                     localWorkspaceID: herdr.selectedWorkspaceID,
                                     localSession: herdr.sessionName,
                                     machine: explorerMachine,
                                     refreshVersion: window.fileRefreshVersion,
                                     onOpenFile: { location, path, preview in
                                         openDocument(.file, path: path, at: location, preview: preview)
                                     },
                                     onOpenDiff: { location, path, preview in
                                         openDocument(.change, path: path, at: location, preview: preview)
                                     },
                                     onNewTab: { cwd in
                                         activeDocumentID = nil
                                         herdr.createTab(cwd: cwd)
                                     },
                                     onNewSpace: { cwd, label in
                                         activeDocumentID = nil
                                         herdr.createWorkspace(cwd: cwd, label: label)
                                     },
                                     onLocationChange: { location in
                                         explorerLocation = location
                                         search.setLocation(location)
                                     },
                                     onFindInFolder: { location, path in
                                         search.setLocation(location)
                                         search.options.include = path.isEmpty ? "" : path + "/**"
                                         search.showsFilters = !path.isEmpty
                                         openSearch(replace: false)
                                     },
                                     onOpenWorktree: openWorktree,
                                     onOpenCommitFile: { location, commit, file in
                                         openDocument(.commit, path: file.path, at: location,
                                                      commit: commit.id, originalPath: file.originalPath)
                                     },
                                     activeFile: activeFile,
                                     onOpenScopedDiff: { location, path, scope in
                                         openDocument(.change, path: path, at: location, scope: scope)
                                     },
                                     commandTarget: window.explorer)
                    .frame(width: filesSidebarWidth)
            }
        }
    }

    @ViewBuilder
    private var globalActions: some View {
        Button("New Space", systemImage: "plus.square") { commands.perform(.newWorkspace) }
            .disabled(!herdr.isConnected)
        Button("New Tab", systemImage: "plus") { commands.perform(.newTab) }
            .disabled(!herdr.isConnected || herdr.selectedWorkspaceID == nil)
        Divider()
        Button(window.showsSidebar ? "Hide Sidebar" : "Show Sidebar",
               systemImage: "sidebar.left") { commands.perform(.toggleSidebar) }
        Button(window.showsFilesSidebar ? "Hide Files and Changes" : "Show Files and Changes",
               systemImage: "sidebar.right") { commands.perform(.toggleFilesSidebar) }
        Button("Refresh Files and Repository", systemImage: "arrow.clockwise") { commands.perform(.refreshFiles) }
        Button("Find in Project…", systemImage: "magnifyingglass") { openSearch(replace: false) }
        Button("Replace in Project…", systemImage: "text.magnifyingglass") { openSearch(replace: true) }
        Button("Go to File…", systemImage: "doc.text.magnifyingglass") { commands.perform(.quickOpen) }
            .disabled(explorerLocation == nil)
        Button("Command Palette…", systemImage: "command") { commands.perform(.commandPalette) }
        Divider()
        Button("Keyboard Shortcuts…", systemImage: "keyboard") { commands.perform(.help) }
        Button("Herdr Settings…", systemImage: "gearshape") { commands.perform(.settings) }
        Button("Reload Herdr Config", systemImage: "arrow.triangle.2.circlepath") { commands.perform(.reloadConfig) }
            .disabled(!herdr.isConnected)
        Button("Switch Session…", systemImage: "point.3.connected.trianglepath.dotted") {
            commands.perform(.switchSession)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 0) {
                            sectionTitle("SPACES", icon: "square.stack")
                            Spacer()
                            Button {
                                activeDocumentID = nil
                                herdr.createWorkspace()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: typography.secondary, weight: .semibold))
                                    .frame(width: 23, height: typography.metric(20))
                            }
                            .buttonStyle(.plain)
                            .help("New Space")
                            .disabled(!herdr.isConnected)
                        }
                        ForEach(herdr.snapshot?.workspaces ?? []) { workspace in
                            Button {
                                herdr.select(workspaceID: workspace.workspaceID)
                            } label: {
                                HStack(spacing: 7) {
                                    AgentStatusDot(status: workspace.agentStatus)
                                    Text(workspace.label)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    let marks = notifier.attentionCount(inWorkspace: workspace.workspaceID,
                                                                        snapshot: herdr.snapshot)
                                    HerdrAttentionBadge(requests: marks.requests, done: marks.done)
                                }
                                .font(.system(size: typography.emphasis, weight: .medium))
                                .sidebarRow(selected: workspace.workspaceID == herdr.selectedWorkspaceID)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { spaceActions(workspace) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 0) {
                            sectionTitle("AGENTS", icon: "sparkles")
                            Spacer()
                            if let state = herdr.agentViewState, let label = state.label {
                                Menu {
                                    if let source = state.view?.source { Text("View from \(source)") }
                                    if state.unavailable {
                                        Text("This Herdr view is unavailable. Showing all agents.")
                                    } else {
                                        Toggle("Follow Herdr View", isOn: $followsHerdrAgentView)
                                    }
                                } label: {
                                    Text(state.unavailable ? "Unavailable" : label)
                                        .font(.system(size: typography.caption))
                                        .foregroundStyle(state.unavailable || !followsHerdrAgentView ? .secondary : theme.accent)
                                        .lineLimit(1)
                                        .frame(maxWidth: 75)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(state.unavailable ? "Herdr's agent view could not be applied. The Space filter still applies."
                                      : "\(label) — \(state.view?.source ?? "Herdr"). \(followsHerdrAgentView ? "Following Herdr's view." : "Showing all agents in this window.")")
                                .accessibilityLabel("Herdr Agent View: \(label)")
                                .accessibilityIdentifier("herdr-agent-view")
                            }
                            Button {
                                agentsInSelectedSpaceOnly.toggle()
                            } label: {
                                Image(systemName: agentsInSelectedSpaceOnly
                                      ? "line.3.horizontal.decrease.circle.fill"
                                      : "line.3.horizontal.decrease.circle")
                                    .font(.system(size: typography.body, weight: .semibold))
                                    .foregroundStyle(agentsInSelectedSpaceOnly ? theme.accent : .secondary)
                                    .frame(width: 23, height: typography.metric(20))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agents-space-filter")
                            .help(agentsInSelectedSpaceOnly ? "Show Agents in All Spaces"
                                                            : "Show Agents in Selected Space Only")
                        }
                        let agents = herdr.visibleAgents(inSelectedSpaceOnly: agentsInSelectedSpaceOnly,
                                                         followHerdrView: followsHerdrAgentView)
                        if agents.isEmpty {
                            Text(followsHerdrAgentView && herdr.agentViewState?.view != nil
                                 ? (agentsInSelectedSpaceOnly ? "No agents match this view in this Space" : "No agents match this view")
                                 : (agentsInSelectedSpaceOnly ? "No agents in this Space" : "No agents"))
                                .font(.system(size: typography.body))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        ForEach(agents) { agent in
                            Button {
                                focusAgent(agent)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 7) {
                                        AgentStatusDot(status: agent.agentStatus)
                                        Text(agentLocation(agent))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(agent.displayStatus)
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: typography.secondary))
                                    .foregroundStyle(.secondary)
                                    HStack(spacing: 5) {
                                        Text(agent.displayName)
                                            .font(.system(size: typography.body, weight: .medium))
                                            .lineLimit(1)
                                        if let alert = notifier.attention[agent.paneID] {
                                            Label(alert.label, systemImage: alert.icon)
                                                .font(.system(size: typography.caption, weight: .semibold))
                                                .foregroundStyle(alert == .request ? theme.warning : theme.success)
                                                .padding(.horizontal, 5)
                                                .frame(height: 15)
                                                .background((alert == .request ? theme.warning : theme.success).opacity(0.16),
                                                            in: Capsule())
                                        }
                                    }
                                    .padding(.leading, 13)
                                    if let detail = agent.detail {
                                        Text(detail)
                                            .font(.system(size: typography.secondary))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .padding(.leading, 13)
                                    }
                                }
                                .sidebarRow(selected: agent.paneID == herdr.selectedPaneID,
                                            height: agent.detail == nil ? 44 : 59)
                            }
                            .buttonStyle(.plain)
                            .help(agentTooltip(agent))
                            .contextMenu {
                                Button("Focus Pane", systemImage: "scope") { focusAgent(agent) }
                                Button("Focus and Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                                    focusAgent(agent)
                                    herdr.zoomPane()
                                }
                                Divider()
                                Button("Rename Agent…", systemImage: "pencil") {
                                    window.renameText = agent.displayName
                                    window.renameTarget = .agent(agent.paneID)
                                }
                                Button("Copy Agent Name", systemImage: "doc.on.doc") {
                                    AppActions.copy(agent.displayName)
                                }
                                Divider()
                                Button("Close Pane…", systemImage: "xmark.square", role: .destructive) {
                                    window.closeTarget = .pane(agent.paneID)
                                }
                            }
                        }
                    }
                }
                .padding(7)
            }

            Divider()
            HostStatsSection(machine: explorerMachine,
                             directory: explorerLocation?.machine?.id == explorerMachine?.id
                                 ? explorerLocation?.root : nil)
                .padding(7)
            Divider()
            AgentQuotaSection(machine: explorerMachine)
                .padding(7)
            Divider()
            HStack(spacing: 0) {
                Button {
                    window.requestedSessionName = herdr.sessionName
                    window.showsSessionPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text(herdr.sessionName).lineLimit(1)
                        if let explorerMachine {
                            Image(systemName: "network").foregroundStyle(theme.accent)
                            Text(explorerMachine.label).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: typography.caption))
                    }
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
                    .frame(height: typography.metric(29))
                }
                .buttonStyle(.plain)
                RemoteAccessIndicator { commands.perform("remote_access") }
                Button {
                    window.settingsShowShortcuts = false
                    window.settingsShowRemoteAccess = false
                    window.showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: typography.body))
                        .foregroundStyle(.secondary)
                        .frame(width: 29, height: typography.metric(29))
                }
                .buttonStyle(.plain)
                .help("Herdr settings")
            }
            .popover(isPresented: $window.showsSessionPicker) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Connect to a Herdr session")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableSessions, id: \.self) { name in
                            Button {
                                window.requestedSessionName = name
                                connect()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: name == herdr.sessionName ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(name == herdr.sessionName ? theme.accent : Color.secondary)
                                    Text(name).font(.system(size: typography.emphasis, design: .monospaced))
                                    if name == HerdrStore.defaultSessionName {
                                        Text("primary").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: typography.metric(22))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Session name", text: $window.requestedSessionName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                    }
                    if let error = herdr.sessionSelectionError {
                        Text(error).font(.caption).foregroundStyle(theme.warning)
                    }
                    if managesRuntime {
                        Button("Set Up Herdr…") {
                            window.showsSessionPicker = false
                            runtime.showsSetup = true
                        }
                    }
                    Divider()
                    Text("Files and changes")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        machineRow(nil)
                        ForEach(machines) { machineRow($0) }
                    }
                }
                .padding(14)
                .frame(width: 305)
                .onAppear {
                    availableSessions = HerdrStore.availableSessions()
                    loadMachines()
                }
            }
        }
        .background(sidebarBackground)
    }

    private func machineRow(_ profile: HerdrMachineProfile?) -> some View {
        let selected = profile?.id == explorerMachine?.id
        return Button {
            explorerMachine = profile
            window.showsSessionPicker = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? theme.accent : Color.secondary)
                Image(systemName: profile == nil ? "desktopcomputer" : "network")
                    .foregroundStyle(.secondary)
                Text(profile?.label ?? "Local").font(.system(size: typography.emphasis))
                if let profile {
                    Text(profile.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: typography.metric(22))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadMachines() {
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.machines() } }.value
            guard case .success(let profiles) = result else { return }
            machines = profiles
            // A machine removed from Herdr's list falls back to this Mac.
            if let current = explorerMachine, !profiles.contains(where: { $0.id == current.id }) {
                explorerMachine = nil
            }
        }
    }

    private var mainArea: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
    }

    /// Under the panes, level with the sidebar's session bar: the sidebar toggles, the selected
    /// Space and the prefix and connection state.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Button { window.showsSidebar.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 22, height: typography.metric(29))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(window.showsSidebar ? "Hide sidebar" : "Show sidebar")
            Text(selectedWorkspace?.label ?? "Herdr")
                .lineLimit(1)
            if shortcutPrefixActive {
                Text("PREFIX")
                    .font(.system(size: typography.caption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
            Spacer()
            if !herdr.isConnected {
                Text("Disconnected")
                    .foregroundStyle(theme.warning)
            }
            Button { window.showsFilesSidebar.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 22, height: typography.metric(29))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(window.showsFilesSidebar ? "Hide Files and Changes" : "Show Files and Changes")
        }
        .font(.system(size: typography.secondary, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: typography.metric(29))
        .background(sidebarBackground)
        .contentShape(Rectangle())
        .contextMenu {
            if let selectedWorkspace {
                spaceActions(selectedWorkspace)
                Divider()
            }
            globalActions
        }
    }

    /// Keeps the split panels in step with the tabs: opening a tab that has a side panel focuses
    /// that panel, and closing a tab closes its panel.
    private func followingPanels(_ content: some View) -> some View {
        content
            .onChange(of: activeDocumentID) { old, new in commands.activeDocumentChanged(from: old, to: new) }
            .onChange(of: documentStore.documents.map(\.backupID)) { _, _ in commands.prunePanels() }
            .onChange(of: window.showsSearchTab) { _, _ in commands.prunePanels() }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if herdr.isConnected || !documents.isEmpty {
                tabBar
                    .frame(height: typography.metric(31))
                    .background(barBackground)
                Divider()

                PanelLayoutView(layout: commands.panelLayout, drop: panelDrop,
                                 setRatio: { path, ratio in setPanelRatio(ratio, at: path) }) { content in
                    if content == .main {
                        mainPanel
                    } else {
                        sidePanel(content)
                    }
                }
            } else {
                connectionState
            }
        }
    }

    /// The main panel: the selected terminal tab, or the active document or Search.
    @ViewBuilder
    private var mainPanel: some View {
        if activeDocumentID == WorkspaceSearchModel.tabID {
            searchView
        } else if let activeDocumentID,
           let index = documentStore.documents.firstIndex(where: { $0.id == activeDocumentID }) {
            documentView(at: index, focused: commands.focusedPanel == .main)
        } else if !herdr.isConnected {
            connectionState
        } else if herdr.showsLiveSurface {
            GeometryReader { geometry in
                TerminalPaneView(
                    text: "",
                    paneID: herdr.selectedPaneID ?? selectedPanes[0].paneID,
                    surfaceFeed: herdr.surfaceFeed,
                    onPresentSurface: { herdr.acknowledgeAgentSurface($0) },
                    sendPopupInput: { event, id, boot in herdr.sendPopupInput(event, terminalID: id, bootID: boot) },
                    closePopup: { id, boot in herdr.closePopup(terminalID: id, bootID: boot) },
                    shortcutMap: shortcutMap,
                    onShortcut: handleShortcut,
                    onPrefixChanged: { shortcutPrefixActive = $0 },
                    selectPane: { id in herdr.select(paneID: id) },
                    sendText: { text, id in herdr.sendText(text, to: id) },
                    sendPaste: { text, id in herdr.sendPaste(text, to: id) },
                    sendKey: { key, id in herdr.sendKey(key, to: id) },
                    sendMouse: { mouse, id in herdr.sendMouse(mouse, to: id) },
                    setSplitRatio: { path, ratio in herdr.setSplitRatio(path: path, ratio: ratio) },
                    tabDrop: terminalTabDrop
                )
                .onAppear { resizeSurface(to: geometry.size) }
                .onChange(of: geometry.size) { _, size in resizeSurface(to: size) }
            }
        } else if let layout = herdr.snapshot?.layouts.first(where: { $0.tabID == herdr.selectedTabID }),
           !layout.panes.isEmpty {
            GeometryReader { geometry in
                ForEach(layout.panes, id: \.paneID) { item in
                    if let pane = selectedPanes.first(where: { $0.paneID == item.paneID }) {
                        let width = geometry.size.width * CGFloat(item.rect.width) / CGFloat(max(layout.area.width, 1))
                        let height = geometry.size.height * CGFloat(item.rect.height) / CGFloat(max(layout.area.height, 1))
                        let x = geometry.size.width * CGFloat(item.rect.x - layout.area.x) / CGFloat(max(layout.area.width, 1)) + width / 2
                        let y = geometry.size.height * CGFloat(item.rect.y - layout.area.y) / CGFloat(max(layout.area.height, 1)) + height / 2
                        terminalPane(pane)
                            .frame(width: max(width - 2, 1), height: max(height - 2, 1))
                            .position(x: x, y: y)
                    }
                }
            }
        } else if let pane = selectedPanes.first {
            terminalPane(pane)
        } else {
            emptyState("This tab has no panes")
        }
    }

    private var searchView: some View {
        WorkspaceSearchView(model: search) { location, path, line, range in
            openDocument(.file, path: path, at: location,
                         reveal: WorkspaceDocumentReveal(line: line, range: range))
        }
    }

    private func documentView(at index: Int, focused: Bool) -> some View {
        let id = documentStore.documents[index].id
        return WorkspaceDocumentView(document: $documentStore.documents[index], onSave: {
            saveDocument(id)
        }, onReload: {
            documentStore.load(id)
        }, onOpenFile: { [location = documentStore.documents[index].location] path in
            openDocument(.file, path: path, at: location)
        }, commandTarget: window.editor, isFocused: focused)
        .id(id)
    }

    /// A panel beside the main one, showing one document or Search under a header that works
    /// like its tab: dragged, it moves the panel elsewhere.
    private func sidePanel(_ content: PanelContent) -> some View {
        VStack(spacing: 0) {
            panelHeader(content)
            Divider()
            switch content {
            case .search:
                searchView
            case .document(let backupID):
                if let index = documentStore.documents.firstIndex(where: { $0.backupID == backupID }) {
                    documentView(at: index, focused: commands.focusedPanel == content)
                }
            case .main:
                EmptyView()
            }
        }
        .background(theme.contentBackground)
    }

    private func panelHeader(_ content: PanelContent) -> some View {
        let id = commands.tabID(of: content)
        let document = id.flatMap(documentStore.document)
        let focused = commands.focusedPanel == content
        return HStack(spacing: 5) {
            Image(systemName: document?.icon ?? "magnifyingglass")
                .foregroundStyle(theme.accent)
            Text(document?.title ?? search.title).lineLimit(1)
                .foregroundStyle(focused ? .primary : .secondary)
            if document?.isDirty == true { Circle().fill(theme.warning).frame(width: 5, height: 5) }
            Spacer(minLength: 6)
            Button { if let id { commands.dropTab(id, on: .main, zone: .center) } } label: {
                Image(systemName: "rectangle.portrait.and.arrow.forward")
                    .frame(width: 22, height: typography.metric(25))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Main Panel")
            Button { commands.closePanel(content) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: typography.tiny))
                    .frame(width: 22, height: typography.metric(25))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Split (the tab stays open)")
        }
        .font(.system(size: typography.body))
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(height: typography.metric(27))
        .background(barBackground)
        .overlay(alignment: .top) {
            if focused { Rectangle().fill(theme.accent).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .help(document.map { $0.isUntitled ? "\($0.title) · not saved yet" : "\($0.location.machineLabel) · \($0.path)" }
              ?? "Project Search")
        .onDrag { window.tabDrag.begin(content == .search ? .search : .document, id: id ?? "") }
        .contextMenu {
            if let id {
                Button("Show in Main Panel", systemImage: "rectangle.portrait.and.arrow.forward") {
                    commands.dropTab(id, on: .main, zone: .center)
                }
            }
            Button("Close Split", systemImage: "rectangle.split.2x1.slash") { commands.closePanel(content) }
            Divider()
            if content == .search {
                Button("Close Search", systemImage: "xmark") { closeSearch() }
            } else if let id {
                Button("Close Tab", systemImage: "xmark") { closeDocument(id) }
            }
        }
    }

    /// Document and Search tabs dragged from the tab bar or a panel header onto the panels:
    /// the middle of a panel shows the tab there, a side splits the panel.
    private var panelDrop: PanelDropHandler {
        PanelDropHandler(
            dragged: { [drag = window.tabDrag] in drag.draggedPanelTab.flatMap(commands.panelContent(forTab:)) },
            accepts: { content, target, zone in
                PanelDrop.accepts(content, on: target, zone: zone, mainShows: commands.mainPanelContent)
            },
            drop: { [drag = window.tabDrag] target, zone in
                guard let id = drag.dropPanelTab() else { return false }
                return commands.dropTab(id, on: target, zone: zone)
            },
            focus: { commands.focusPanel($0) })
    }

    private func setPanelRatio(_ ratio: Double, at path: [Bool]) {
        let key = WorkspaceSessionPersistence.key(for: documentStore.space)
        guard let layout = window.panelLayouts[key] else { return }
        window.panelLayouts[key] = layout.settingRatio(ratio, at: path)
    }

    /// A tab's background: strong while its panel has focus, faint while it shows in another
    /// panel, none while hidden. Every tab type uses it.
    private func tabBackground(_ content: PanelContent?, inMain: Bool) -> Color {
        let focused = commands.focusedPanel
        let visible = inMain || content.map { $0 != .main && commands.panelLayout.contains($0) } == true
        guard visible else { return .clear }
        let hasFocus = inMain ? focused == .main : content == focused
        return Color.primary.opacity(hasFocus ? 0.09 : 0.045)
    }

    /// Terminal tabs, the Search tab and document tabs, then the new tab buttons. Double-clicking
    /// the empty space after them opens an untitled file; a middle click closes a tab; terminal
    /// and document tabs are dragged to reorder them within their group.
    private var tabBar: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(selectedTabs.enumerated()), id: \.element.id) { index, tab in
                        terminalTab(tab, index: index)
                    }
                    if !documents.isEmpty || window.showsSearchTab {
                        Divider().frame(height: typography.metric(17)).padding(.horizontal, 4)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .tabDropAtEnd(drag: window.tabDrag, [.terminal: terminalTabsEnd])
                    }
                    if window.showsSearchTab { searchTab }
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        documentTab(document, index: index)
                    }
                    Button {
                        commands.perform(.newTab)
                    } label: {
                        TabBarAddIcon(symbol: "terminal")
                            .frame(width: 26, height: typography.metric(25))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Terminal Tab")
                    .disabled(herdr.selectedWorkspaceID == nil)
                    Button {
                        commands.newUntitledFile()
                    } label: {
                        TabBarAddIcon(symbol: "doc")
                            .frame(width: 26, height: typography.metric(25))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Untitled File (double-click the empty tab bar)")
                    .disabled(explorerLocation == nil)
                    // The rest of the bar: double-clicking it opens an untitled file, and a tab
                    // dropped on it goes last in its group.
                    Color.clear
                        .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { commands.newUntitledFile() }
                        .tabDropAtEnd(drag: window.tabDrag, [
                            .terminal: terminalTabsEnd,
                            .document: TabDropEnd(lastIndex: documents.count - 1, onMove: { documentStore.move($0, to: $1) })
                        ])
                }
                .padding(.horizontal, 7)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .leading)
            }
        }
    }

    private var terminalTabsEnd: TabDropEnd {
        TabDropEnd(lastIndex: selectedTabs.count - 1, onMove: { herdr.moveTab($0, to: $1) })
    }

    private func terminalTab(_ tab: HerdrTab, index: Int) -> some View {
        Button {
            herdr.select(tabID: tab.tabID)
            activeDocumentID = nil
            commands.focusPanel(.main)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: typography.secondary))
                Text(tab.label).lineLimit(1)
                let marks = notifier.attentionCount(inTab: tab.tabID, snapshot: herdr.snapshot)
                HerdrAttentionBadge(requests: marks.requests, done: marks.done)
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 10)
            .frame(height: typography.metric(27))
            .background(tabBackground(nil, inMain: activeDocumentID == nil && herdr.selectedTabID == tab.tabID),
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onMiddleClick { closeTerminalTab(tab) }
        .contextMenu {
            Button("New Tab", systemImage: "plus") {
                activeDocumentID = nil
                herdr.createTab()
            }
            Button("Rename Tab…", systemImage: "pencil") {
                window.renameText = tab.label
                window.renameTarget = .tab(tab.tabID)
            }
            Divider()
            Button("Close Tab…", systemImage: "xmark", role: .destructive) { closeTerminalTab(tab) }
                .disabled(selectedTabs.count < 2)
        }
        .tabReorder(.terminal, id: tab.tabID, index: index, drag: window.tabDrag,
                    onMove: { herdr.moveTab($0, to: $1) })
    }

    /// A single-pane terminal tab dragged from the tab bar onto the selected tab's panes splits
    /// next to the pane under the pointer. Other drags, and tabs that cannot move, are ignored.
    private var terminalTabDrop: TerminalTabDropHandler {
        TerminalTabDropHandler(
            accepts: { [herdr, drag = window.tabDrag] in
                drag.draggedTerminalTab.map { herdr.canSplit(tabID: $0) } ?? false
            },
            drop: { [herdr, drag = window.tabDrag] paneID, edge in
                guard let tabID = drag.dropTerminalTab() else { return false }
                return herdr.splitTab(tabID, nextTo: paneID, edge: edge)
            })
    }

    /// Asks before closing a terminal tab; the last tab of a Space stays.
    private func closeTerminalTab(_ tab: HerdrTab) {
        guard selectedTabs.count >= 2 else { return }
        window.closeTarget = .tab(tab.tabID, tab.label)
    }

    private var searchTab: some View {
        HStack(spacing: 0) {
            Button { openSearch(replace: false) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
                    Text(search.title).lineLimit(1).frame(maxWidth: 160)
                }
                .font(.system(size: typography.body))
                .padding(.leading, 9)
                .frame(height: typography.metric(27))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { closeSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: typography.tiny))
                    .frame(width: 22, height: typography.metric(27))
            }
            .buttonStyle(.plain)
        }
        .background(tabBackground(.search, inMain: activeDocumentID == WorkspaceSearchModel.tabID),
                    in: RoundedRectangle(cornerRadius: 4))
        .help("Project Search")
        .onMiddleClick { closeSearch() }
        .onDrag { window.tabDrag.begin(.search, id: WorkspaceSearchModel.tabID) }
        .contextMenu {
            splitActions(WorkspaceSearchModel.tabID)
            Divider()
            Button("Close Search", systemImage: "xmark") { closeSearch() }
        }
    }

    private func documentTab(_ document: WorkspaceDocument, index: Int) -> some View {
        HStack(spacing: 0) {
            Button { commands.selectTab(document.id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: document.icon)
                        .foregroundStyle(theme.accent)
                    Text(document.title).lineLimit(1).italic(document.isPreview)
                    if document.isDirty { Circle().fill(theme.warning).frame(width: 5, height: 5) }
                }
                .font(.system(size: typography.body))
                .padding(.leading, 9)
                .frame(height: typography.metric(27))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { keepDocumentOpen(document.id) })
            Button { closeDocument(document.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: typography.tiny))
                    .frame(width: 22, height: typography.metric(27))
            }
            .buttonStyle(.plain)
        }
        .background(tabBackground(.document(document.backupID), inMain: activeDocumentID == document.id),
                    in: RoundedRectangle(cornerRadius: 4))
        .help(document.isUntitled ? "\(document.title) · not saved yet"
              : "\(document.location.machineLabel) · \(document.location.workspaceLabel) · \(document.path)")
        .onMiddleClick { closeDocument(document.id) }
        .contextMenu { documentActions(document) }
        .tabReorder(.document, id: document.id, index: index, drag: window.tabDrag,
                    onMove: { documentStore.move($0, to: $1) })
    }

    private func terminalPane(_ pane: HerdrPane) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                Text(pane.paneID).fontWeight(.medium)
                Spacer(minLength: 5)
                if let error = herdr.inputError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.warning)
                        .help(error)
                }
                Text(pane.cwd ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: typography.secondary, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: typography.metric(26))
            .background(barBackground)
            .contentShape(Rectangle())
            .onTapGesture { herdr.selectedPaneID = pane.paneID }
            .contextMenu {
                Button("Split Right", systemImage: "rectangle.split.2x1") {
                    herdr.selectedPaneID = pane.paneID
                    herdr.splitPane("right")
                }
                Button("Split Down", systemImage: "rectangle.split.1x2") {
                    herdr.selectedPaneID = pane.paneID
                    herdr.splitPane("down")
                }
                Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
                    herdr.selectedPaneID = pane.paneID
                    herdr.zoomPane()
                }
                if let cwd = pane.cwd {
                    Divider()
                    Button("Copy Working Directory", systemImage: "doc.on.doc") { AppActions.copy(cwd) }
                    Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(cwd) }
                }
                Divider()
                Button("Close Pane…", systemImage: "xmark.square", role: .destructive) {
                    window.closeTarget = .pane(pane.paneID)
                }
            }
            Divider()
            TerminalPaneView(
                text: herdr.paneText[pane.paneID] ?? "Reading pane…",
                paneID: pane.paneID,
                shortcutMap: shortcutMap,
                onShortcut: handleShortcut,
                onPrefixChanged: { shortcutPrefixActive = $0 },
                sendText: { text, id in herdr.sendText(text, to: id) },
                sendPaste: { text, id in herdr.sendPaste(text, to: id) },
                sendKey: { key, id in herdr.sendKey(key, to: id) },
                sendMouse: { mouse, id in herdr.sendMouse(mouse, to: id) },
                setSplitRatio: { path, ratio in herdr.setSplitRatio(path: path, ratio: ratio) },
                tabDrop: terminalTabDrop
            )
            .id(pane.paneID)
        }
        .background(theme.contentBackground)
        .overlay {
            Rectangle()
                .stroke(pane.paneID == herdr.selectedPaneID ? theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        }
    }

    private func connect() {
        let name = window.requestedSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime.clearServerStartError()
        Task {
            if managesRuntime {
                guard await runtime.prepare(session: name) else { return }
            }
            herdr.connect(to: name)
            if herdr.sessionSelectionError == nil { window.showsSessionPicker = false }
        }
        activeDocumentID = nil
    }

    private func openDocument(_ kind: WorkspaceDocumentKind, path: String, at location: WorkspaceFileLocation,
                              reveal: WorkspaceDocumentReveal? = nil,
                              commit: String? = nil, originalPath: String? = nil,
                              scope: WorkspaceDiffScope? = nil, preview: Bool = false) {
        documentStore.open(kind, path: path, at: location, reveal: reveal, commit: commit,
                           originalPath: originalPath, scope: scope, preview: preview)
    }

    private func keepDocumentOpen(_ id: String) {
        documentStore.keepOpen(id)
    }

    private func saveDocument(_ id: String) {
        commands.saveDocument(id)
    }

    private var commands: ContentCommands {
        ContentCommands(window: window, herdr: herdr, documents: documentStore, search: search,
                        explorerLocation: explorerLocation,
                        effects: ContentCommandEffects(reloadAppConfig: {
                            shortcutMap = HerdrShortcutMap.load()
                            themes.reload()
                        }),
                        bindingLabel: { [shortcutMap] in shortcutMap.displayLabel(for: $0) })
    }

    private func openSearch(replace: Bool) {
        commands.openSearch(replace: replace)
    }

    private func closeSearch() {
        commands.closeSearch()
    }

    private func closeDocument(_ id: String, force: Bool = false) {
        commands.closeDocument(id, force: force)
    }

    @ViewBuilder
    private func spaceActions(_ workspace: HerdrWorkspace) -> some View {
        let root = herdr.snapshot.flatMap {
            WorkspaceFiles.location(snapshot: $0, workspaceID: workspace.workspaceID,
                                    session: herdr.sessionName, machine: nil)?.root
        }
        Button("New Tab in Space", systemImage: "plus") {
            herdr.select(workspaceID: workspace.workspaceID)
            activeDocumentID = nil
            herdr.createTab()
        }
        Button("Rename Space…", systemImage: "pencil") {
            window.renameText = workspace.label
            window.renameTarget = .workspace(workspace.workspaceID)
        }
        if let root {
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(root) }
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(root) }
        }
        Divider()
        Button("Close Space…", systemImage: "xmark", role: .destructive) {
            window.closeTarget = .workspace(workspace.workspaceID, workspace.label)
        }
    }

    @ViewBuilder
    private func documentActions(_ document: WorkspaceDocument) -> some View {
        if document.isPreview {
            Button("Keep Open", systemImage: "pin") { keepDocumentOpen(document.id) }
            Divider()
        }
        if document.isUntitled {
            Button("Save As…", systemImage: "square.and.arrow.down") { saveDocument(document.id) }
        } else if document.kind == .file {
            Button("Save", systemImage: "square.and.arrow.down") { saveDocument(document.id) }
                .disabled(!document.isDirty)
            Button("Open Changes", systemImage: "arrow.left.arrow.right") {
                openDocument(.change, path: document.path, at: document.location)
            }
        } else {
            Button("Open File", systemImage: "doc.text") {
                openDocument(.file, path: document.path, at: document.location)
            }
        }
        Divider()
        splitActions(document.id)
        if !document.isUntitled {
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(document.location.absolutePath(document.path)) }
            Button("Copy Relative Path") { AppActions.copy(document.path) }
        }
        if document.location.isLocal && !document.isUntitled {
            Button("Reveal in Finder", systemImage: "folder") {
                AppActions.reveal(document.location.absolutePath(document.path))
            }
        }
        Divider()
        Button("Close", systemImage: "xmark") { closeDocument(document.id) }
        Button("Close Others") {
            for other in documents where other.id != document.id { closeDocument(other.id) }
        }
            .disabled(documents.count < 2)
        Button("Close All") {
            for other in documents { closeDocument(other.id) }
        }
    }

    /// Opening a document or Search tab in a panel of its own, beside the focused panel, or
    /// putting it back in the main panel.
    @ViewBuilder
    private func splitActions(_ id: String) -> some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") { commands.splitTab(id, edge: .right) }
        Button("Split Down", systemImage: "rectangle.split.1x2") { commands.splitTab(id, edge: .bottom) }
        if let content = commands.panelContent(forTab: id), commands.panelLayout.contains(content) {
            Button("Show in Main Panel", systemImage: "rectangle.portrait.and.arrow.forward") {
                commands.dropTab(id, on: .main, zone: .center)
            }
        }
    }

    /// Focuses the Space already open on a worktree, or opens a new one there.
    private func openWorktree(path: String, label: String) {
        activeDocumentID = nil
        let snapshot = herdr.snapshot
        let existing = snapshot?.workspaces.first { $0.worktree?.checkoutPath == path }?.workspaceID
            ?? snapshot?.panes.first { $0.cwd == path }?.workspaceID
        if let existing {
            herdr.select(workspaceID: existing)
        } else {
            herdr.createWorkspace(cwd: path, label: label)
        }
    }

    private func focusAgent(_ agent: HerdrAgent) {
        focusPane(agent.paneID)
    }

    private func focusPane(_ paneID: String) {
        guard let pane = herdr.snapshot?.panes.first(where: { $0.paneID == paneID }) else { return }
        herdr.select(workspaceID: pane.workspaceID, tabID: pane.tabID, paneID: pane.paneID)
        activeDocumentID = nil
        notifier.acknowledge(paneID: paneID)
    }

    private func commitRename() {
        commands.commitRename()
    }

    private func commitClose() {
        commands.commitClose()
    }

    private func handleShortcut(_ action: String) {
        commands.perform(action)
    }

    private func resizeSurface(to size: CGSize) {
        let cols = max(1, Int((size.width - 20) / TerminalPaneView.cellWidth))
        let rows = max(1, Int((size.height - 18) / TerminalPaneView.cellHeight))
        herdr.resizeSurface(cols: cols, rows: rows,
                            cellWidth: Int(TerminalPaneView.cellWidth.rounded()),
                            cellHeight: Int(TerminalPaneView.cellHeight.rounded()))
    }

    /// Shown until the session connects. A stopped server can be started from here.
    @ViewBuilder
    private var connectionState: some View {
        if managesRuntime && herdr.isServerStopped {
            VStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 24, weight: .light))
                Text("The \(herdr.sessionName) session is not running")
                    .font(.headline)
                Text("Start its Herdr server, or choose another session in the sidebar.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button {
                    let session = herdr.sessionName
                    Task { await runtime.startServer(session: session) }
                } label: {
                    if runtime.isStartingServer {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting Herdr…")
                        }
                    } else {
                        Text("Start Herdr")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runtime.isStartingServer)
                .padding(.top, 4)
                if let error = runtime.serverStartError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .textSelection(.enabled)
                }
                Text(herdr.socketPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState(herdr.errorMessage ?? "Connecting to \(herdr.sessionName) session…")
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 24, weight: .light))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text(herdr.socketPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Matches the EXPLORER and REPOSITORY headers of the files sidebar.
    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: typography.secondary, weight: .semibold))
                .tracking(0.7)
            Image(systemName: icon)
                .font(.system(size: typography.secondary))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func agentLocation(_ agent: HerdrAgent) -> String {
        let workspace = herdr.snapshot?.workspaces.first { $0.workspaceID == agent.workspaceID }?.label
            ?? agent.workspaceID ?? "Space"
        let tab = herdr.snapshot?.tabs.first { $0.tabID == agent.tabID }?.label
        return tab.map { "\(workspace) · \($0)" } ?? workspace
    }

    private func agentTooltip(_ agent: HerdrAgent) -> String {
        var lines = [agent.displayName, agentLocation(agent), agent.displayStatus]
        if let detail = agent.detail { lines.append(detail) }
        return lines.joined(separator: "\n")
    }
}

private extension View {
    func sidebarRow(selected: Bool, height: CGFloat = 27) -> some View {
        modifier(SidebarRowModifier(selected: selected, height: height))
    }
}

private struct SidebarRowModifier: ViewModifier {
    @Environment(\.xherdrTypography) private var typography
    let selected: Bool
    /// Height at 11 pt text; grows with the interface text size.
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(minHeight: typography.metric(height))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            // Plain buttons only hit-test drawn pixels; make the whole row clickable.
            .contentShape(Rectangle())
    }
}

/// Dim the whole window when another app or window is active, keeping live output readable.
/// Observe activity here so focus changes do not invalidate the terminal/editor hierarchy.
private struct InactiveWindowOverlay: View {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let background: Color

    var body: some View {
        background
            .opacity(activeState == .inactive ? 0.35 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: activeState)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum AppActions {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct SidebarResizeHandle: View {
    @Environment(\.xherdrTypography) private var typography
    @Binding var width: Double
    let defaultWidth: Double
    /// The side of the window the sidebar sits on; dragging away from it widens the sidebar.
    let edge: HorizontalEdge
    let range: ClosedRange<Double>

    @State private var dragStartWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                // An AppKit view, so the resize cursor wins over the hosting view's arrow and the
                // neighbouring text views' I-beam; SwiftUI's onHover with NSCursor.push loses to both.
                ResizeHandleArea(
                    onDrag: { translation in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        let delta = edge == .leading ? translation : -translation
                        width = min(max(start + delta, range.lowerBound), range.upperBound)
                    },
                    onDragEnd: { dragStartWidth = nil },
                    onReset: { width = defaultWidth }
                )
                .frame(width: 9)
            }
            .zIndex(1)
            .onChange(of: range) { _, range in
                width = min(max(width, range.lowerBound), range.upperBound)
            }
    }
}

/// A resize handle as an AppKit view, so its cursor wins over the hosting view's arrow and the
/// neighbouring text views' I-beam. `vertical` handles resize heights.
struct ResizeHandleArea: NSViewRepresentable {
    var vertical = false
    var tooltip = "Drag to resize · double-click to reset"
    let onDrag: (Double) -> Void
    let onDragEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.vertical = vertical
        view.toolTip = tooltip
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onReset = onReset
    }
}

final class ResizeHandleView: NSView {
    /// Resizes heights: dragging down is positive.
    var vertical = false {
        didSet { if vertical != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var onDrag: (Double) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onReset: () -> Void = {}
    private var dragStart: CGFloat?
    private var cursorTrackingArea: NSTrackingArea?
    private var cursor: NSCursor { vertical ? .resizeUpDown : .resizeLeftRight }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    /// Window coordinates grow upwards; heights grow as the pointer goes down.
    private func position(_ event: NSEvent) -> CGFloat {
        vertical ? -event.locationInWindow.y : event.locationInWindow.x
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onReset()
        } else {
            dragStart = position(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        // The pointer leaves the handle while the view catches up; keep the cursor until mouse up.
        cursor.set()
        onDrag(position(event) - dragStart)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnd()
    }
}

/// A Space's or agent's state as Herdr's sidebar draws it: a dot while working, blocked or
/// finished and unseen, a ring once seen. Herdr marks panes seen when their tab is focused,
/// which selecting a Space, tab or pane here does.
struct AgentStatusDot: View {
    let status: String?
    @Environment(\.xherdrTheme) private var theme

    var body: some View {
        let color = theme.agentStatus(status)
        Group {
            switch XherdrTheme.agentStatusMark(status) {
            case .dot: Circle().fill(color)
            case .ring: Circle().strokeBorder(color, lineWidth: 1.25)
            case .faint: Circle().fill(color).padding(1.5)
            }
        }
        .frame(width: 6, height: 6)
    }
}

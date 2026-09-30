import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.xherdrTypography) private var typography
    @StateObject private var herdr = HerdrStore()
    @State private var showsSidebar = true
    @State private var showsFilesSidebar = true
    @State private var showsSessionPicker = false
    @State private var showsSettings = false
    @State private var settingsShowShortcuts = false
    @State private var shortcutMap = HerdrShortcutMap.load()
    @State private var shortcutPrefixActive = false
    @State private var requestedSessionName = ""
    @State private var availableSessions: [String] = []
    @State private var machines: [HerdrMachineProfile] = []
    /// The SSH machine whose files and repository the explorer shows; nil is this Mac.
    @State private var explorerMachine: HerdrMachineProfile?
    @StateObject private var documentStore = WorkspaceDocumentStore()
    @State private var pendingCloseDocumentID: String?
    private var documents: [WorkspaceDocument] { documentStore.documents }
    private var activeDocumentID: String? {
        get { documentStore.activeID }
        nonmutating set { documentStore.activeID = newValue }
    }
    @State private var fileRefreshVersion = 0
    @StateObject private var search = WorkspaceSearchModel()
    @State private var showsSearchTab = false
    @State private var explorerLocation: WorkspaceFileLocation?
    @AppStorage("SidebarWidth") private var sidebarWidth = 206.0
    @AppStorage("FilesSidebarWidth") private var filesSidebarWidth = 244.0
    @AppStorage("AgentsInSelectedSpaceOnly") private var agentsInSelectedSpaceOnly = false
    @State private var renameTarget: HerdrRenameTarget?
    @State private var renameText = ""
    @State private var closeTarget: HerdrCloseTarget?

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

    private var selectedWorkspace: HerdrWorkspace? {
        herdr.snapshot?.workspaces.first { $0.workspaceID == herdr.selectedWorkspaceID }
    }

    private var selectedTabs: [HerdrTab] {
        herdr.snapshot?.tabs.filter { $0.workspaceID == herdr.selectedWorkspaceID } ?? []
    }

    private var selectedPanes: [HerdrPane] {
        herdr.snapshot?.panes.filter { $0.tabID == herdr.selectedTabID } ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            content(totalWidth: geometry.size.width)
        }
        .frame(minWidth: 850, minHeight: 380)
        .preferredColorScheme(theme.colorScheme)
        .environment(\.xherdrTheme, theme)
        .environment(\.xherdrTypography, textScale)
        .tint(theme.accent)
        .task { herdr.start() }
        .focusedSceneValue(\.xherdrCommands, XherdrCommandContext(
            isConnected: herdr.isConnected,
            hasSpace: selectedWorkspace != nil,
            tabCount: selectedTabs.count,
            hasPane: herdr.selectedPaneID != nil,
            showsSidebar: showsSidebar,
            showsFilesSidebar: showsFilesSidebar,
            perform: handleShortcut
        ))
        .onDisappear { herdr.stop() }
        .overlay { HerdrToastStack(notifier: notifier) }
        .onAppear {
            notifier.onOpenPane = { focusPane($0) }
            notifier.reloadSettings()
        }
        .onReceive(herdr.$snapshot) { snapshot in
            notifier.process(snapshot, selectedPaneID: herdr.selectedPaneID)
        }
        .onChange(of: herdr.selectedPaneID) { _, paneID in notifier.acknowledge(paneID: paneID) }
        .onChange(of: herdr.sessionName) { _, _ in notifier.reset() }
        // Editing a preview keeps it open, so later previews never replace unsaved work.
        .onChange(of: documents.contains { $0.isPreview && $0.isDirty }) { _, edited in
            if edited { documentStore.keepEditedPreviewsOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.acknowledge(paneID: herdr.selectedPaneID)
        }
        .sheet(isPresented: $showsSettings) {
            HerdrSettingsView(socketPath: herdr.socketPath, sessionName: herdr.sessionName,
                              showShortcuts: settingsShowShortcuts) {
                shortcutMap = HerdrShortcutMap.load()
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
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(
            get: { pendingCloseDocumentID != nil },
            set: { if !$0 { pendingCloseDocumentID = nil } }
        )) {
            Button("Discard and close", role: .destructive) {
                if let id = pendingCloseDocumentID { closeDocument(id, force: true) }
                pendingCloseDocumentID = nil
            }
        }
        .alert(renameTarget?.title ?? "Rename", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(closeTarget?.title ?? "Close?", isPresented: Binding(
            get: { closeTarget != nil }, set: { if !$0 { closeTarget = nil } }
        )) {
            Button("Close", role: .destructive) { commitClose() }
        } message: {
            Text("Processes running in its terminals will be terminated.")
        }
    }

    private func content(totalWidth: CGFloat) -> some View {
        // Keep the terminal area usable however wide the sidebars are dragged.
        let mainMinimum = 360.0
        let left = showsSidebar ? sidebarWidth : 0
        let right = showsFilesSidebar ? filesSidebarWidth : 0
        return HStack(spacing: 0) {
            if showsSidebar {
                sidebar.frame(width: sidebarWidth)
                SidebarResizeHandle(width: $sidebarWidth, defaultWidth: 206, edge: .leading,
                                    range: 160...max(160, min(420, totalWidth - right - mainMinimum)))
            }
            mainArea
            if showsFilesSidebar {
                SidebarResizeHandle(width: $filesSidebarWidth, defaultWidth: 244, edge: .trailing,
                                    range: 200...max(200, min(560, totalWidth - left - mainMinimum)))
                WorkspaceBrowserView(localSnapshot: herdr.snapshot,
                                     localWorkspaceID: herdr.selectedWorkspaceID,
                                     localSession: herdr.sessionName,
                                     machine: explorerMachine,
                                     refreshVersion: fileRefreshVersion,
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
                                     })
                    .frame(width: filesSidebarWidth)
            }
        }
    }

    @ViewBuilder
    private var globalActions: some View {
        Button("New Space", systemImage: "plus.square") {
            activeDocumentID = nil
            herdr.createWorkspace()
        }
            .disabled(!herdr.isConnected)
        Button("New Tab", systemImage: "plus") {
            activeDocumentID = nil
            herdr.createTab()
        }
            .disabled(!herdr.isConnected || herdr.selectedWorkspaceID == nil)
        Divider()
        Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar",
               systemImage: "sidebar.left") { showsSidebar.toggle() }
        Button(showsFilesSidebar ? "Hide Files and Changes" : "Show Files and Changes",
               systemImage: "sidebar.right") { showsFilesSidebar.toggle() }
        Button("Refresh Files and Repository", systemImage: "arrow.clockwise") {
            WorkspaceFiles.forgetRecentResults()
            fileRefreshVersion += 1
        }
        Button("Find in Project…", systemImage: "magnifyingglass") { openSearch(replace: false) }
        Button("Replace in Project…", systemImage: "text.magnifyingglass") { openSearch(replace: true) }
        Divider()
        Button("Keyboard Shortcuts…", systemImage: "keyboard") {
            settingsShowShortcuts = true
            showsSettings = true
        }
        Button("Herdr Settings…", systemImage: "gearshape") {
            settingsShowShortcuts = false
            showsSettings = true
        }
        Button("Reload Herdr Config", systemImage: "arrow.triangle.2.circlepath") {
            shortcutMap = HerdrShortcutMap.load()
            themes.reload()
            herdr.reloadConfig()
        }
            .disabled(!herdr.isConnected)
        Button("Switch Session…", systemImage: "point.3.connected.trianglepath.dotted") {
            showsSidebar = true
            requestedSessionName = herdr.sessionName
            showsSessionPicker = true
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(theme.accent)
                Text("herdr")
                    .font(.system(size: typography.emphasis, weight: .semibold, design: .monospaced))
                Spacer()
                Circle()
                    .fill(herdr.isConnected ? theme.success : theme.warning)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .frame(height: typography.metric(35))
            .contentShape(Rectangle())
            .contextMenu { globalActions }

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
                                activeDocumentID = nil
                            } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(statusColor(workspace.agentStatus))
                                        .frame(width: 6, height: 6)
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
                            .help(agentsInSelectedSpaceOnly ? "Show Agents in All Spaces"
                                                            : "Show Agents in Selected Space Only")
                        }
                        let agents = (herdr.snapshot?.agents ?? []).filter {
                            !agentsInSelectedSpaceOnly || $0.workspaceID == herdr.selectedWorkspaceID
                        }
                        if agents.isEmpty {
                            Text(agentsInSelectedSpaceOnly ? "No agents in this Space" : "No agents")
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
                                        Circle()
                                            .fill(statusColor(agent.agentStatus))
                                            .frame(width: 6, height: 6)
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
                                    renameText = agent.displayName
                                    renameTarget = .agent(agent.paneID)
                                }
                                Button("Copy Agent Name", systemImage: "doc.on.doc") {
                                    AppActions.copy(agent.displayName)
                                }
                                Divider()
                                Button("Close Pane…", systemImage: "xmark.square", role: .destructive) {
                                    closeTarget = .pane(agent.paneID)
                                }
                            }
                        }
                    }
                }
                .padding(7)
            }

            Divider()
            HStack(spacing: 0) {
                Button {
                    requestedSessionName = herdr.sessionName
                    showsSessionPicker = true
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
                Button {
                    settingsShowShortcuts = false
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: typography.body))
                        .foregroundStyle(.secondary)
                        .frame(width: 29, height: typography.metric(29))
                }
                .buttonStyle(.plain)
                .help("Herdr settings")
            }
            .popover(isPresented: $showsSessionPicker) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Connect to a Herdr session")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableSessions, id: \.self) { name in
                            Button {
                                requestedSessionName = name
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
                        TextField("Session name", text: $requestedSessionName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                    }
                    if let error = herdr.sessionSelectionError {
                        Text(error).font(.caption).foregroundStyle(theme.warning)
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
            showsSessionPicker = false
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
            HStack(spacing: 8) {
                Button {
                    showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help(showsSidebar ? "Hide sidebar" : "Show sidebar")
                Text(selectedWorkspace?.label ?? "Herdr")
                    .font(.system(size: typography.emphasis, weight: .semibold))
                    .lineLimit(1)
                if shortcutPrefixActive {
                    Text("PREFIX")
                        .font(.system(size: typography.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                Spacer()
                if !herdr.isConnected {
                    Text("Disconnected")
                        .font(.system(size: typography.secondary, design: .monospaced))
                        .foregroundStyle(theme.warning)
                }
                Button { showsFilesSidebar.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(showsFilesSidebar ? "Hide Files and Changes" : "Show Files and Changes")
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(35))
            .background(barBackground)
            .contextMenu {
                if let selectedWorkspace {
                    spaceActions(selectedWorkspace)
                    Divider()
                }
                globalActions
            }
            Divider()

            if herdr.isConnected || !documents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(selectedTabs) { tab in
                            Button {
                                herdr.select(tabID: tab.tabID)
                                activeDocumentID = nil
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
                                .background(
                                    activeDocumentID == nil && herdr.selectedTabID == tab.tabID
                                        ? Color.primary.opacity(0.09) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("New Tab", systemImage: "plus") {
                                    activeDocumentID = nil
                                    herdr.createTab()
                                }
                                Button("Rename Tab…", systemImage: "pencil") {
                                    renameText = tab.label
                                    renameTarget = .tab(tab.tabID)
                                }
                                Divider()
                                Button("Close Tab…", systemImage: "xmark", role: .destructive) {
                                    closeTarget = .tab(tab.tabID, tab.label)
                                }
                                .disabled(selectedTabs.count < 2)
                            }
                        }
                        if !documents.isEmpty || showsSearchTab { Divider().frame(height: typography.metric(17)).padding(.horizontal, 4) }
                        if showsSearchTab {
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
                            .background(activeDocumentID == WorkspaceSearchModel.tabID ? Color.primary.opacity(0.09) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .help("Project Search")
                        }
                        ForEach(documents) { document in
                            HStack(spacing: 0) {
                                Button { activeDocumentID = document.id } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: document.kind.icon)
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
                            .background(activeDocumentID == document.id ? Color.primary.opacity(0.09) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .help("\(document.location.machineLabel) · \(document.location.workspaceLabel) · \(document.path)")
                            .contextMenu { documentActions(document) }
                        }
                        Button {
                            activeDocumentID = nil
                            herdr.createTab()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: typography.secondary, weight: .semibold))
                                .frame(width: 26, height: typography.metric(25))
                        }
                        .buttonStyle(.plain)
                        .help("New Tab")
                        .disabled(herdr.selectedWorkspaceID == nil)
                    }
                    .padding(.horizontal, 7)
                }
                .frame(height: typography.metric(31))
                .background(barBackground)
                Divider()

                if activeDocumentID == WorkspaceSearchModel.tabID {
                    WorkspaceSearchView(model: search) { location, path, line, range in
                        openDocument(.file, path: path, at: location,
                                     reveal: WorkspaceDocumentReveal(line: line, range: range))
                    }
                } else if let activeDocumentID,
                   let index = documents.firstIndex(where: { $0.id == activeDocumentID }) {
                    WorkspaceDocumentView(document: $documentStore.documents[index], onSave: {
                        saveDocument(activeDocumentID)
                    }, onOpenFile: { [location = documents[index].location] path in
                        openDocument(.file, path: path, at: location)
                    })
                    .id(activeDocumentID)
                } else if !herdr.isConnected {
                    emptyState(herdr.errorMessage ?? "Connecting to \(herdr.sessionName) session…")
                } else if let surfaceLayout = herdr.surfaceLayout,
                   !selectedPanes.isEmpty,
                   Set(surfaceLayout.paneIDs) == Set(selectedPanes.map(\.paneID)) {
                    GeometryReader { geometry in
                        TerminalPaneView(
                            text: "",
                            paneID: herdr.selectedPaneID ?? selectedPanes[0].paneID,
                            surfaceFeed: herdr.surfaceFeed,
                            shortcutMap: shortcutMap,
                            onShortcut: handleShortcut,
                            onPrefixChanged: { shortcutPrefixActive = $0 },
                            selectPane: { id in herdr.select(paneID: id) },
                            sendText: { text, id in herdr.sendText(text, to: id) },
                            sendPaste: { text, id in herdr.sendPaste(text, to: id) },
                            sendKey: { key, id in herdr.sendKey(key, to: id) },
                            sendMouse: { mouse, id in herdr.sendMouse(mouse, to: id) },
                            setSplitRatio: { path, ratio in herdr.setSplitRatio(path: path, ratio: ratio) }
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
            } else {
                emptyState(herdr.errorMessage ?? "Connecting to \(herdr.sessionName) session…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    closeTarget = .pane(pane.paneID)
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
                setSplitRatio: { path, ratio in herdr.setSplitRatio(path: path, ratio: ratio) }
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
        herdr.connect(to: requestedSessionName)
        if herdr.sessionSelectionError == nil { showsSessionPicker = false }
        activeDocumentID = nil
    }

    private func openDocument(_ kind: WorkspaceDocumentKind, path: String, at location: WorkspaceFileLocation,
                              reveal: WorkspaceDocumentReveal? = nil,
                              commit: String? = nil, originalPath: String? = nil, preview: Bool = false) {
        documentStore.open(kind, path: path, at: location, reveal: reveal, commit: commit,
                           originalPath: originalPath, preview: preview)
    }

    private func keepDocumentOpen(_ id: String) {
        documentStore.keepOpen(id)
    }

    private func saveDocument(_ id: String) {
        documentStore.save(id) { fileRefreshVersion += 1 }
    }

    private func openSearch(replace: Bool) {
        if !showsSearchTab {
            search.hasUnsavedEdits = { [documentStore] location, path in
                documentStore.hasUnsavedEdits(at: location, path: path)
            }
            search.didModifyFiles = { [documentStore] location, paths in
                documentStore.reloadUnedited(paths, at: location)
                fileRefreshVersion += 1
            }
        }
        showsSearchTab = true
        if replace { search.showsReplace = true }
        search.setLocation(explorerLocation)
        activeDocumentID = WorkspaceSearchModel.tabID
        search.requestFocus()
    }

    private func closeSearch() {
        showsSearchTab = false
        if activeDocumentID == WorkspaceSearchModel.tabID { activeDocumentID = nil }
    }

    private func closeDocument(_ id: String, force: Bool = false) {
        if !documentStore.close(id, force: force) { pendingCloseDocumentID = id }
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
            renameText = workspace.label
            renameTarget = .workspace(workspace.workspaceID)
        }
        if let root {
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(root) }
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(root) }
        }
        Divider()
        Button("Close Space…", systemImage: "xmark", role: .destructive) {
            closeTarget = .workspace(workspace.workspaceID, workspace.label)
        }
    }

    @ViewBuilder
    private func documentActions(_ document: WorkspaceDocument) -> some View {
        if document.isPreview {
            Button("Keep Open", systemImage: "pin") { keepDocumentOpen(document.id) }
            Divider()
        }
        if document.kind == .file {
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
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(document.location.absolutePath(document.path)) }
        Button("Copy Relative Path") { AppActions.copy(document.path) }
        if document.location.isLocal {
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
        let label = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renameTarget = nil }
        guard let renameTarget else { return }
        if case .agent(let id) = renameTarget {
            herdr.renameAgent(id, to: label.isEmpty ? nil : label)
            return
        }
        guard !label.isEmpty else { return }
        switch renameTarget {
        case .workspace(let id): herdr.renameWorkspace(id, to: label)
        case .tab(let id): herdr.renameTab(id, to: label)
        case .agent: break
        }
    }

    private func commitClose() {
        defer { closeTarget = nil }
        switch closeTarget {
        case .workspace(let id, _):
            activeDocumentID = nil
            herdr.closeWorkspace(id)
        case .tab(let id, _): herdr.closeTab(id)
        case .pane(let id): herdr.closePane(id)
        case nil: break
        }
    }

    private func handleShortcut(_ action: String) {
        guard let command = HerdrCommand(action: action) else { return }
        switch command {
        case .help:
            settingsShowShortcuts = true
            showsSettings = true
        case .settings:
            settingsShowShortcuts = false
            showsSettings = true
        case .newWorkspace:
            activeDocumentID = nil
            herdr.createWorkspace()
        case .newTab:
            activeDocumentID = nil
            herdr.createTab()
        case .cycleTab(let delta):
            guard let tabID = HerdrCommand.tab(delta, from: herdr.selectedTabID, in: selectedTabs.map(\.tabID)) else { return }
            herdr.select(tabID: tabID)
            activeDocumentID = nil
        case .switchTab(let number):
            guard selectedTabs.indices.contains(number - 1) else { return }
            herdr.select(tabID: selectedTabs[number - 1].tabID)
            activeDocumentID = nil
        case .toggleSidebar: showsSidebar.toggle()
        case .focusPane(let direction): herdr.focusPane(direction)
        case .splitPane(let direction): herdr.splitPane(direction)
        case .zoom: herdr.zoomPane()
        case .reloadConfig:
            shortcutMap = HerdrShortcutMap.load()
            themes.reload()
            herdr.reloadConfig()
        case .toggleFilesSidebar: showsFilesSidebar.toggle()
        case .refreshFiles:
            WorkspaceFiles.forgetRecentResults()
            fileRefreshVersion += 1
        case .switchSession:
            showsSidebar = true
            requestedSessionName = herdr.sessionName
            showsSessionPicker = true
        case .renameWorkspace:
            guard let selectedWorkspace else { return }
            renameText = selectedWorkspace.label
            renameTarget = .workspace(selectedWorkspace.workspaceID)
        case .closeWorkspace:
            guard let selectedWorkspace else { return }
            closeTarget = .workspace(selectedWorkspace.workspaceID, selectedWorkspace.label)
        case .renameTab:
            guard let tab = selectedTabs.first(where: { $0.tabID == herdr.selectedTabID }) else { return }
            renameText = tab.label
            renameTarget = .tab(tab.tabID)
        case .closeTab:
            guard selectedTabs.count > 1,
                  let tab = selectedTabs.first(where: { $0.tabID == herdr.selectedTabID }) else { return }
            closeTarget = .tab(tab.tabID, tab.label)
        case .closeCurrentTab:
            if activeDocumentID == WorkspaceSearchModel.tabID {
                closeSearch()
            } else if let activeDocumentID {
                closeDocument(activeDocumentID)
            } else {
                handleShortcut("close_tab")
            }
        case .closePane:
            guard let paneID = herdr.selectedPaneID else { return }
            closeTarget = .pane(paneID)
        case .projectSearch(let replace): openSearch(replace: replace)
        case .copyPaneDirectory, .revealPaneDirectory:
            guard let cwd = selectedPanes.first(where: { $0.paneID == herdr.selectedPaneID })?.cwd else { return }
            if command == .copyPaneDirectory { AppActions.copy(cwd) } else { AppActions.reveal(cwd) }
        }
    }

    private func resizeSurface(to size: CGSize) {
        let cols = max(1, Int((size.width - 20) / TerminalPaneView.cellWidth))
        let rows = max(1, Int((size.height - 18) / TerminalPaneView.cellHeight))
        herdr.resizeSurface(cols: cols, rows: rows,
                            cellWidth: Int(TerminalPaneView.cellWidth.rounded()),
                            cellHeight: Int(TerminalPaneView.cellHeight.rounded()))
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

    private func statusColor(_ status: String?) -> Color {
        theme.agentStatus(status)
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

private enum HerdrRenameTarget {
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

private enum HerdrCloseTarget {
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
    @State private var isHovering = false

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHovering else { return }
                        isHovering = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                let delta = edge == .leading ? value.translation.width : -value.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .onTapGesture(count: 2) { width = defaultWidth }
                    .help("Drag to resize · double-click to reset")
            }
            .zIndex(1)
            .onChange(of: range) { _, range in
                width = min(max(width, range.lowerBound), range.upperBound)
            }
            .onDisappear { if isHovering { NSCursor.pop() } }
    }
}

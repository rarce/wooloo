import SwiftUI

struct ContentView: View {
    @StateObject private var herdr = HerdrStore()
    @State private var showsSidebar = true
    @State private var showsSessionPicker = false
    @State private var showsSettings = false
    @State private var settingsShowShortcuts = false
    @State private var shortcutMap = HerdrShortcutMap.load()
    @State private var shortcutPrefixActive = false
    @State private var requestedSessionName = "xherdr-ui-test"

    private let sidebarBackground = Color(red: 0.105, green: 0.115, blue: 0.13)
    private let barBackground = Color(red: 0.13, green: 0.14, blue: 0.155)

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
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar.frame(width: 206)
                Divider()
            }
            mainArea
        }
        .frame(minWidth: 640, minHeight: 380)
        .preferredColorScheme(.dark)
        .task { herdr.start() }
        .onDisappear { herdr.stop() }
        .sheet(isPresented: $showsSettings) {
            HerdrSettingsView(socketPath: herdr.socketPath, sessionName: herdr.sessionName,
                              showShortcuts: settingsShowShortcuts) {
                shortcutMap = HerdrShortcutMap.load()
            }
        }
        .alert("Herdr action failed", isPresented: Binding(
            get: { herdr.actionError != nil },
            set: { if !$0 { herdr.clearActionError() } }
        )) {
            Button("OK", role: .cancel) { herdr.clearActionError() }
        } message: {
            Text(herdr.actionError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.cyan)
                Text("herdr")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Circle()
                    .fill(herdr.isConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .frame(height: 35)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 0) {
                            sectionTitle("SPACES")
                            Spacer()
                            Button { herdr.createWorkspace() } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 23, height: 20)
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
                                    Circle()
                                        .fill(statusColor(workspace.agentStatus))
                                        .frame(width: 6, height: 6)
                                    Text(workspace.label)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .sidebarRow(selected: workspace.workspaceID == herdr.selectedWorkspaceID)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        sectionTitle("AGENTS")
                        let agents = herdr.snapshot?.agents ?? []
                        if agents.isEmpty {
                            Text("No agents")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        ForEach(agents) { agent in
                            Button {
                                if let pane = herdr.snapshot?.panes.first(where: { $0.paneID == agent.paneID }) {
                                    herdr.select(workspaceID: pane.workspaceID, tabID: pane.tabID, paneID: pane.paneID)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(statusColor(agent.agentStatus))
                                        .frame(width: 6, height: 6)
                                    Text(agent.displayName).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(agent.agentStatus ?? "")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 11))
                                .sidebarRow(selected: agent.paneID == herdr.selectedPaneID)
                            }
                            .buttonStyle(.plain)
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
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
                    .frame(height: 29)
                }
                .buttonStyle(.plain)
                Button {
                    settingsShowShortcuts = false
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 29, height: 29)
                }
                .buttonStyle(.plain)
                .help("Herdr settings")
            }
            .popover(isPresented: $showsSessionPicker) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Connect to a named session")
                        .font(.subheadline.weight(.semibold))
                    HStack {
                        TextField("Session name", text: $requestedSessionName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                    }
                    if let error = herdr.sessionSelectionError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .frame(width: 305)
            }
        }
        .background(sidebarBackground)
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
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if shortcutPrefixActive {
                    Text("PREFIX")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Menu {
                    Button("New Space", systemImage: "plus.square") { herdr.createWorkspace() }
                        .disabled(!herdr.isConnected)
                    Button("New Tab", systemImage: "plus") { herdr.createTab() }
                        .disabled(!herdr.isConnected || herdr.selectedWorkspaceID == nil)
                    Divider()
                    Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar",
                           systemImage: "sidebar.left") { showsSidebar.toggle() }
                    Button("Keyboard Shortcuts…", systemImage: "keyboard") {
                        settingsShowShortcuts = true
                        showsSettings = true
                    }
                    Button("Herdr Settings…", systemImage: "gearshape") {
                        settingsShowShortcuts = false
                        showsSettings = true
                    }
                    Button("Switch Session…", systemImage: "point.3.connected.trianglepath.dotted") {
                        showsSidebar = true
                        requestedSessionName = herdr.sessionName
                        showsSessionPicker = true
                    }
                } label: {
                    Label("Menu", systemImage: "ellipsis.circle")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Herdr menu")
                Text(herdr.surface == nil ? "TEXT" : "LIVE")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(herdr.surface == nil ? Color.secondary : Color.cyan)
                    .help(herdr.surfaceError ?? (herdr.surface == nil ? "Text snapshot" : "Live Herdr surface"))
                if !herdr.isConnected {
                    Text("Disconnected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 35)
            .background(barBackground)
            Divider()

            if herdr.isConnected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(selectedTabs) { tab in
                            Button {
                                herdr.select(tabID: tab.tabID)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 10))
                                    Text(tab.label).lineLimit(1)
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 10)
                                .frame(height: 27)
                                .background(
                                    herdr.selectedTabID == tab.tabID ? Color.white.opacity(0.09) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Button { herdr.createTab() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 26, height: 25)
                        }
                        .buttonStyle(.plain)
                        .help("New Tab")
                        .disabled(herdr.selectedWorkspaceID == nil)
                    }
                    .padding(.horizontal, 7)
                }
                .frame(height: 31)
                .background(barBackground)
                Divider()

                if let surface = herdr.surface,
                   !selectedPanes.isEmpty,
                   Set(surface.paneIDs) == Set(selectedPanes.map(\.paneID)) {
                    GeometryReader { geometry in
                        TerminalPaneView(
                            text: "",
                            paneID: herdr.selectedPaneID ?? selectedPanes[0].paneID,
                            surface: surface,
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
                emptyState(herdr.errorMessage ?? "Connecting to test session…")
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
                        .foregroundStyle(.orange)
                        .help(error)
                }
                Text(pane.cwd ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(barBackground)
            .contentShape(Rectangle())
            .onTapGesture { herdr.selectedPaneID = pane.paneID }
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
        .background(Color(red: 0.075, green: 0.082, blue: 0.091))
        .overlay {
            Rectangle()
                .stroke(pane.paneID == herdr.selectedPaneID ? Color.cyan.opacity(0.45) : Color.clear, lineWidth: 1)
        }
    }

    private func connect() {
        herdr.connect(to: requestedSessionName)
        if herdr.sessionSelectionError == nil { showsSessionPicker = false }
    }

    private func handleShortcut(_ action: String) {
        switch action {
        case "help":
            settingsShowShortcuts = true
            showsSettings = true
        case "settings":
            settingsShowShortcuts = false
            showsSettings = true
        case "new_workspace": herdr.createWorkspace()
        case "new_tab": herdr.createTab()
        case "previous_tab", "next_tab":
            guard let index = selectedTabs.firstIndex(where: { $0.tabID == herdr.selectedTabID }),
                  !selectedTabs.isEmpty else { return }
            let delta = action == "next_tab" ? 1 : -1
            let next = (index + delta + selectedTabs.count) % selectedTabs.count
            herdr.select(tabID: selectedTabs[next].tabID)
        case "toggle_sidebar": showsSidebar.toggle()
        case "focus_pane_left": herdr.focusPane("left")
        case "focus_pane_down": herdr.focusPane("down")
        case "focus_pane_up": herdr.focusPane("up")
        case "focus_pane_right": herdr.focusPane("right")
        case "split_vertical": herdr.splitPane("right")
        case "split_horizontal": herdr.splitPane("down")
        case "zoom": herdr.zoomPane()
        case "reload_config":
            shortcutMap = HerdrShortcutMap.load()
            herdr.reloadConfig()
        default:
            if action.hasPrefix("switch_tab_"),
               let number = Int(action.dropFirst("switch_tab_".count)),
               selectedTabs.indices.contains(number - 1) {
                herdr.select(tabID: selectedTabs[number - 1].tabID)
            }
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "working": return .orange
        case "blocked": return .pink
        case "done": return .cyan
        case "idle": return .green
        default: return .gray
        }
    }
}

private extension View {
    func sidebarRow(selected: Bool) -> some View {
        padding(.horizontal, 8)
            .frame(height: 27)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.white.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}

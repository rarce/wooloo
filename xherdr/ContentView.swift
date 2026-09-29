import SwiftUI

struct ContentView: View {
    @StateObject private var herdr = HerdrStore()
    @State private var showsSidebar = true
    @State private var inputByPane: [String: String] = [:]
    @State private var requestedSessionName = "xherdr-ui-test"

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
                sidebar.frame(width: 260)
                Divider()
            }
            mainArea
        }
        .frame(minWidth: 760, minHeight: 500)
        .preferredColorScheme(.dark)
        .task { herdr.start() }
        .onDisappear { herdr.stop() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("HERDR")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                Spacer()
                Circle()
                    .fill(herdr.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .help(herdr.isConnected ? "Connected to test session" : "Waiting for test session")
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("SPACES")
                        ForEach(herdr.snapshot?.workspaces ?? []) { workspace in
                            Button {
                                herdr.select(workspaceID: workspace.workspaceID)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(statusColor(workspace.agentStatus))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(workspace.label).font(.subheadline.weight(.medium))
                                        Text(workspace.workspaceID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .sidebarRow(selected: workspace.workspaceID == herdr.selectedWorkspaceID)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("AGENTS")
                        let agents = herdr.snapshot?.agents ?? []
                        if agents.isEmpty {
                            Text("No agents detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                        }
                        ForEach(agents) { agent in
                            Button {
                                if let pane = herdr.snapshot?.panes.first(where: { $0.paneID == agent.paneID }) {
                                    herdr.select(workspaceID: pane.workspaceID, tabID: pane.tabID, paneID: pane.paneID)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(statusColor(agent.agentStatus))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.displayName).font(.subheadline.weight(.medium))
                                        Text(agent.agentStatus ?? "unknown")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .sidebarRow(selected: agent.paneID == herdr.selectedPaneID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }

            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(herdr.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("\(herdr.isConnected ? "Connected" : "Disconnected") · \(herdr.sessionName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help(showsSidebar ? "Hide sidebar" : "Show sidebar")
                Text(selectedWorkspace?.label ?? "Herdr")
                    .font(.headline)
                Spacer()
                TextField("Named session", text: $requestedSessionName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 145)
                    .onSubmit { herdr.connect(to: requestedSessionName) }
                    .help("Named sessions only; default is excluded")
                Button("Connect") { herdr.connect(to: requestedSessionName) }
                    .buttonStyle(.borderless)
                if let sessionSelectionError = herdr.sessionSelectionError {
                    Text(sessionSelectionError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Divider()

            if herdr.isConnected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(selectedTabs) { tab in
                            Button {
                                herdr.select(tabID: tab.tabID)
                            } label: {
                                Label(tab.label, systemImage: "terminal")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        herdr.selectedTabID == tab.tabID ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 44)
                Divider()

                if let layout = herdr.snapshot?.layouts.first(where: { $0.tabID == herdr.selectedTabID }),
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(pane.paneID).fontWeight(.semibold)
                Spacer()
                Text(pane.cwd ?? "")
                    .lineLimit(1)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider()
            ScrollView {
                Text(herdr.paneText[pane.paneID] ?? "Reading pane…")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Text("›")
                    .foregroundStyle(.secondary)
                TextField("Send a line to this pane", text: Binding(
                    get: { inputByPane[pane.paneID] ?? "" },
                    set: { inputByPane[pane.paneID] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { sendInput(to: pane.paneID) }
                Button("Send") { sendInput(to: pane.paneID) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            if let inputError = herdr.inputError {
                Text(inputError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            HStack {
                Text("LIVE SNAPSHOT · line input")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(pane.agentStatus ?? "unknown")
                    .font(.caption.monospaced())
                    .foregroundStyle(statusColor(pane.agentStatus))
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(pane.paneID == herdr.selectedPaneID ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { herdr.selectedPaneID = pane.paneID }
    }

    private func sendInput(to paneID: String) {
        let text = inputByPane[paneID] ?? ""
        guard !text.isEmpty else { return }
        Task {
            if await herdr.sendLine(text, to: paneID) {
                inputByPane[paneID] = ""
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 30, weight: .light))
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
            .padding(.horizontal, 9)
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
        padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

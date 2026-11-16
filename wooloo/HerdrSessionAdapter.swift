import Foundation

// Maps the Herdr TUI snapshot into the backend-neutral session model. The TUI types stay as
// they are while readers move to `WoolooSession`; parity with the snapshot's own rules is
// checked by WoolooSessionTests.

extension HerdrSnapshot {
    func session(backend: BackendID, capabilities: BackendCapabilities = .herdrTUI) -> WoolooSession {
        WoolooSession(
            backend: backend,
            capabilities: capabilities,
            spaces: workspaces.map {
                WoolooSpace(id: $0.workspaceID, label: $0.label, state: $0.agentStatus.map { AgentState($0) },
                            activeTabID: $0.activeTabID, worktreePath: $0.worktree?.checkoutPath)
            },
            tabs: tabs.map {
                WoolooTab(id: $0.tabID, spaceID: $0.workspaceID, label: $0.label,
                          state: $0.agentStatus.map { AgentState($0) })
            },
            panes: panes.map {
                WoolooPane(id: $0.paneID, spaceID: $0.workspaceID, tabID: $0.tabID, cwd: $0.cwd,
                           state: $0.agentStatus.map { AgentState($0) })
            },
            agents: agents.map(\.woolooAgent),
            layouts: layouts.map { layout in
                WoolooTabLayout(tabID: layout.tabID, area: WoolooRect(layout.area),
                                panes: layout.panes.map { .init(paneID: $0.paneID, rect: WoolooRect($0.rect)) },
                                zoomed: layout.zoomed == true)
            },
            focusedSpaceID: focusedWorkspaceID,
            focusedTabID: focusedTabID,
            focusedPaneID: focusedPaneID)
    }
}

extension HerdrAgent {
    /// This agent as the neutral model shows it. Herdr's agent views list `HerdrAgent`s too.
    var woolooAgent: WoolooAgent {
        WoolooAgent(paneID: paneID, spaceID: workspaceID, tabID: tabID, kind: agent, name: displayName,
                    detail: detail, state: AgentState(agentStatus), statusLabel: displayStatus,
                    progress: stateChangeSeq)
    }
}

extension WoolooRect {
    init(_ rect: HerdrRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

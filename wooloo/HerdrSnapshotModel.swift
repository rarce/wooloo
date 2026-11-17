import Foundation

// Herdr TUI snapshot types, decoded from `session.snapshot` and the event stream.
// They stay Foundation-only so the backend-neutral model and its tests build anywhere.

struct HerdrSnapshot: Decodable, Equatable {
    let workspaces: [HerdrWorkspace]
    let tabs: [HerdrTab]
    let panes: [HerdrPane]
    let agents: [HerdrAgent]
    let layouts: [HerdrLayout]
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaces, tabs, panes, agents, layouts
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }
}

extension HerdrSnapshot {
    /// This snapshot with a tab moved to `insertIndex`, a gap in its Space's tab order as
    /// `tab.move` takes it; nil when the tab is unknown, the gap is out of range, or the tab
    /// would stay where it is.
    func movingTab(_ tabID: String, to insertIndex: Int) -> HerdrSnapshot? {
        guard let tab = tabs.first(where: { $0.tabID == tabID }) else { return nil }
        var spaceTabs = tabs.filter { $0.workspaceID == tab.workspaceID }
        guard let from = spaceTabs.firstIndex(of: tab), (0...spaceTabs.count).contains(insertIndex),
              insertIndex != from, insertIndex != from + 1 else { return nil }
        spaceTabs.remove(at: from)
        spaceTabs.insert(tab, at: insertIndex > from ? insertIndex - 1 : insertIndex)
        var next = spaceTabs.makeIterator()
        return HerdrSnapshot(workspaces: workspaces,
                             tabs: tabs.map { $0.workspaceID == tab.workspaceID ? next.next()! : $0 },
                             panes: panes, agents: agents, layouts: layouts, focusedWorkspaceID: focusedWorkspaceID,
                             focusedTabID: focusedTabID, focusedPaneID: focusedPaneID)
    }
}

extension HerdrSnapshot {
    /// The pane a terminal tab dropped on `targetTabID`'s panes moves there: the tab's only
    /// pane. Nil for the target tab itself, a tab with several panes (`pane.move` moves one
    /// pane, so the rest would stay behind), an unknown tab, or a zoomed target, which Herdr
    /// refuses.
    func paneToSplit(fromTab tabID: String, into targetTabID: String?) -> String? {
        guard let targetTabID, tabID != targetTabID,
              tabs.contains(where: { $0.tabID == tabID }), tabs.contains(where: { $0.tabID == targetTabID }),
              layouts.first(where: { $0.tabID == targetTabID })?.zoomed != true else { return nil }
        let moving = panes.filter { $0.tabID == tabID }
        return moving.count == 1 ? moving[0].paneID : nil
    }
}

extension HerdrSnapshot {
    func workspaceMoveIndex(_ workspaceID: String, beside anchorID: String, after: Bool) -> Int? {
        guard let from = workspaces.firstIndex(where: { $0.workspaceID == workspaceID }),
              let anchor = workspaces.firstIndex(where: { $0.workspaceID == anchorID }) else { return nil }
        let gap = anchor + (after ? 1 : 0)
        return gap == from || gap == from + 1 ? nil : gap
    }

    func tabSpaceMoveRefusal(_ tabID: String, to workspaceID: String?) -> String? {
        guard let tab = tabs.first(where: { $0.tabID == tabID }) else { return "The source tab disappeared." }
        guard panes.filter({ $0.tabID == tabID }).count == 1 else { return "Only terminal tabs with one pane can move between Spaces." }
        guard layouts.first(where: { $0.tabID == tabID })?.zoomed != true else { return "Unzoom the terminal tab before moving it." }
        if let workspaceID {
            guard workspaceID != tab.workspaceID else { return "Drop on a different Space." }
            guard workspaces.contains(where: { $0.workspaceID == workspaceID }) else { return "The destination Space disappeared." }
        }
        return nil
    }
}

struct HerdrWorkspace: Decodable, Equatable, Identifiable {
    let workspaceID: String
    let label: String
    let agentStatus: String?
    let activeTabID: String?
    let worktree: HerdrWorktree?

    var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label, worktree
        case agentStatus = "agent_status"
        case activeTabID = "active_tab_id"
    }
}

struct HerdrWorktree: Decodable, Equatable {
    let checkoutPath: String

    enum CodingKeys: String, CodingKey {
        case checkoutPath = "checkout_path"
    }
}

struct HerdrTab: Decodable, Equatable, Identifiable {
    let tabID: String
    let workspaceID: String
    let label: String
    let agentStatus: String?

    var id: String { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label
        case agentStatus = "agent_status"
    }
}

struct HerdrPane: Decodable, Equatable, Identifiable {
    let paneID: String
    let workspaceID: String
    let tabID: String
    let cwd: String?
    let agentStatus: String?

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case cwd
        case agentStatus = "agent_status"
    }
}

struct HerdrAgent: Decodable, Equatable, Identifiable, Sendable {
    let paneID: String
    let workspaceID: String?
    let tabID: String?
    let agent: String?
    let name: String?
    let title: String?
    let terminalTitleStripped: String?
    let displayAgent: String?
    var agentStatus: String?
    let stateLabels: [String: String]?
    let tokens: [String: String]?
    var stateChangeSeq: UInt64 = 0
    /// Pinned through herdr-core's `herdr.pinned` label; the TUI has no pins.
    var pinned = false

    var id: String { paneID }
    var displayName: String { displayAgent ?? name ?? agent ?? title ?? paneID }
    var displayStatus: String {
        let status = agentStatus ?? "unknown"
        return stateLabels?[status] ?? status
    }
    var detail: String? {
        for value in [tokens?["summary"], title, terminalTitleStripped] {
            if let value, !value.isEmpty, value != displayName { return value }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent, name, title, tokens
        case terminalTitleStripped = "terminal_title_stripped"
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
        case stateLabels = "state_labels"
        case stateChangeSeq = "state_change_seq"
    }
}

extension HerdrAgent {
    /// The JSON API uses dictionaries, while shell.snapshot.v1 uses arrays of string pairs.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try values.decode(String.self, forKey: .paneID)
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
        tabID = try values.decodeIfPresent(String.self, forKey: .tabID)
        agent = try values.decodeIfPresent(String.self, forKey: .agent)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        terminalTitleStripped = try values.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        displayAgent = try values.decodeIfPresent(String.self, forKey: .displayAgent)
        agentStatus = try values.decodeIfPresent(String.self, forKey: .agentStatus)
        stateLabels = try values.decodeIfPresent(AgentMetadata.self, forKey: .stateLabels)?.values
        tokens = try values.decodeIfPresent(AgentMetadata.self, forKey: .tokens)?.values
        stateChangeSeq = try values.decodeIfPresent(UInt64.self, forKey: .stateChangeSeq) ?? 0
    }

    private struct AgentMetadata: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dictionary = try? container.decode([String: String].self) { values = dictionary; return }
            let pairs = try container.decode([[String]].self)
            guard pairs.allSatisfy({ $0.count == 2 }) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected metadata string pairs")
            }
            values = Dictionary(pairs.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

struct HerdrLayout: Decodable, Equatable {
    let tabID: String
    let area: HerdrRect
    let panes: [HerdrLayoutPane]
    /// Whether one pane fills the tab; Herdr refuses to move panes into a zoomed tab.
    var zoomed: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case area, panes, zoomed
    }
}

struct HerdrLayoutPane: Decodable, Equatable {
    let paneID: String
    let rect: HerdrRect

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case rect
    }
}

struct HerdrRect: Decodable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

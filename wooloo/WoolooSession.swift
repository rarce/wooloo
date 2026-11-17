import Foundation

// The backend-neutral session model: what the UI shows of one connected session, whichever
// server it comes from (docs/proposals/herdr-core-backend.md, "Backend-neutral session model").
// The Herdr TUI fills it from its snapshot (`HerdrSnapshot.session(backend:)`); herdr-core will
// fill it from its terminals and wooloo's structure document. Ids inside one session are the
// backend's raw ids; `BackendID` scopes them, since a Core terminal id is unique only per core.

enum BackendKind: String, Codable, Hashable, Sendable {
    case tui
    case core
}

/// Which backend connection a session belongs to.
struct BackendID: Codable, Hashable, Sendable {
    let kind: BackendKind
    /// For the TUI, today's context ID (the session name, or the SSH context with its target
    /// hash). For Core, the core's identity and session.
    let context: String

    static func tui(contextID: String) -> BackendID { BackendID(kind: .tui, context: contextID) }
    static func core(coreID: String, session: String) -> BackendID {
        BackendID(kind: .core, context: "\(coreID)|\(session)")
    }

    /// The prefix of every persisted key that belongs to this backend. TUI keys keep exactly
    /// the format they had before the backend split (pinned by PersistedKeyGoldenTests).
    var persistentKey: String {
        switch kind {
        case .tui: return context
        case .core: return "core:\(context)"
        }
    }
}

/// An agent's or terminal's state, in the vocabulary both backends map to.
enum AgentState: Hashable, Sendable {
    case working
    case blocked
    case error
    case done
    case idle
    case unknown
    /// A state this build does not know, kept so it can still be shown.
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "working": self = .working
        case "blocked": self = .blocked
        case "error": self = .error
        case "done": self = .done
        case "idle": self = .idle
        case nil, "unknown": self = .unknown
        case let value?: self = .other(value)
        }
    }

    /// Whether a person is needed: the states that raise an attention alert.
    var needsAttention: Bool { self == .blocked || self == .error }
}

/// What a backend supports, read by command availability instead of hard-coded TUI rules.
struct BackendCapabilities: Hashable, Sendable {
    /// A zoomed tab refuses panes moved into it.
    var zoomedTabsRefuseMoves: Bool
    /// Only a tab with a single pane can move to another tab or Space.
    var onlySinglePaneTabsMove: Bool
    /// Tabs can move between Spaces.
    var movesTabsBetweenSpaces: Bool
    /// The backend opens Git worktrees as Spaces itself.
    var opensWorktrees: Bool
    /// The backend shows agent views and popups drawn by the server.
    var serverAgentViews: Bool
    /// The backend reloads its configuration on request.
    var reloadsConfig: Bool
    /// Terminal history lives in the server, which scrolls it on wheel events.
    var serverScrollback: Bool

    static let herdrTUI = BackendCapabilities(
        zoomedTabsRefuseMoves: true, onlySinglePaneTabsMove: true, movesTabsBetweenSpaces: true,
        opensWorktrees: true, serverAgentViews: true, reloadsConfig: true, serverScrollback: true)
}

struct WoolooRect: Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct WoolooSpace: Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let state: AgentState?
    let activeTabID: String?
    /// The Git checkout the Space was opened on, when it is a worktree Space.
    let worktreePath: String?
}

struct WoolooTab: Hashable, Identifiable, Sendable {
    let id: String
    let spaceID: String
    let label: String
    let state: AgentState?
}

struct WoolooPane: Hashable, Identifiable, Sendable {
    let id: String
    let spaceID: String
    let tabID: String
    let cwd: String?
    let state: AgentState?
}

struct WoolooAgent: Hashable, Identifiable, Sendable {
    let paneID: String
    let spaceID: String?
    let tabID: String?
    /// The agent program, such as `claude` or `codex`, when the backend knows it.
    let kind: String?
    let name: String
    let detail: String?
    let state: AgentState
    /// The state as the backend labels it for display.
    let statusLabel: String
    /// Increases each time the agent's state changes (TUI `state_change_seq`, Core `turn`).
    let progress: UInt64
    /// Pinned by a person in any client (herdr-core's `herdr.pinned`); pinned agents list first.
    var pinned = false

    var id: String { paneID }
}

struct WoolooTabLayout: Hashable, Sendable {
    struct Pane: Hashable, Sendable {
        let paneID: String
        let rect: WoolooRect
    }

    let tabID: String
    let area: WoolooRect
    let panes: [Pane]
    let zoomed: Bool
}

struct WoolooSession: Hashable, Sendable {
    let backend: BackendID
    let capabilities: BackendCapabilities
    let spaces: [WoolooSpace]
    let tabs: [WoolooTab]
    let panes: [WoolooPane]
    let agents: [WoolooAgent]
    let layouts: [WoolooTabLayout]
    let focusedSpaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?

    func tabs(in spaceID: String) -> [WoolooTab] { tabs.filter { $0.spaceID == spaceID } }
    func panes(in tabID: String) -> [WoolooPane] { panes.filter { $0.tabID == tabID } }
    func layout(of tabID: String) -> WoolooTabLayout? { layouts.first { $0.tabID == tabID } }

    /// The key a Space's documents, panel layouts and window membership are saved under.
    func spaceKey(_ spaceID: String) -> String { "\(backend.persistentKey)|\(spaceID)" }
}

extension WoolooSession {
    private func refusesMovesInto(_ tabID: String) -> Bool {
        capabilities.zoomedTabsRefuseMoves && layout(of: tabID)?.zoomed == true
    }

    /// The pane a terminal tab dropped on `targetTabID`'s panes moves there; nil when the
    /// backend would refuse the move (see `HerdrSnapshot.paneToSplit`).
    func paneToSplit(fromTab tabID: String, into targetTabID: String?) -> String? {
        guard let targetTabID, tabID != targetTabID,
              tabs.contains(where: { $0.id == tabID }), tabs.contains(where: { $0.id == targetTabID }),
              !refusesMovesInto(targetTabID) else { return nil }
        let moving = panes(in: tabID)
        if capabilities.onlySinglePaneTabsMove { return moving.count == 1 ? moving[0].id : nil }
        return moving.first?.id
    }

    /// The gap to pass when moving a Space beside another; nil when it would stay in place.
    func spaceMoveIndex(_ spaceID: String, beside anchorID: String, after: Bool) -> Int? {
        guard let from = spaces.firstIndex(where: { $0.id == spaceID }),
              let anchor = spaces.firstIndex(where: { $0.id == anchorID }) else { return nil }
        let gap = anchor + (after ? 1 : 0)
        return gap == from || gap == from + 1 ? nil : gap
    }

    /// Why a tab cannot move to `spaceID` (or to a new Space when nil); nil when it can.
    func tabSpaceMoveRefusal(_ tabID: String, to spaceID: String?) -> String? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return "The source tab disappeared." }
        guard capabilities.movesTabsBetweenSpaces else { return "This server cannot move tabs between Spaces." }
        if capabilities.onlySinglePaneTabsMove, panes(in: tabID).count != 1 {
            return "Only terminal tabs with one pane can move between Spaces."
        }
        if refusesMovesInto(tabID) { return "Unzoom the terminal tab before moving it." }
        if let spaceID {
            guard spaceID != tab.spaceID else { return "Drop on a different Space." }
            guard spaces.contains(where: { $0.id == spaceID }) else { return "The destination Space disappeared." }
        }
        return nil
    }
}

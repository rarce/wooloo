import Foundation

// Phase 2 of docs/proposals/herdr-core-backend.md: what the UI asks of a backend, independent
// of how a server is reached. `HerdrStore` keeps the generic flow (connection checks, action
// epochs, refreshing and following focus); a backend only carries out the command.

/// A structural change the UI asks of the connected session.
enum SessionCommand: Hashable, Sendable {
    case focusPane(paneID: String, direction: String)
    case splitPane(spaceID: String, paneID: String, direction: String)
    case zoomPane(paneID: String)
    case renameSpace(spaceID: String, label: String)
    case closeSpace(spaceID: String)
    /// A nil name restores the name the backend gives the agent itself.
    case renameAgent(paneID: String, name: String?)
    case renameTab(tabID: String, label: String)
    case closeTab(tabID: String)
    case closePane(paneID: String)
    /// Moves a tab within its Space to a gap in the Space's tab order (0 is before the first).
    case moveTab(tabID: String, insertIndex: Int)
    /// Asks the server to apply its configuration file again.
    case reloadConfig

    /// Whether the window then follows the focus the server reports, as after moving focus or
    /// splitting; otherwise it keeps its own selection where it still exists.
    var followsServerFocus: Bool {
        switch self {
        case .focusPane, .splitPane: return true
        default: return false
        }
    }
}

/// Carries out session commands for one connection.
protocol SessionBackend: Sendable {
    var kind: BackendKind { get }
    /// Performs `command`, blocking until the server has applied it. Call it inside
    /// `BlockingWork`, like every other blocking request.
    func perform(_ command: SessionCommand) throws
}

extension SessionCommand {
    /// The Herdr TUI socket request for this command, as `herdr api schema --json` names it.
    var herdrRequest: (method: String, params: [String: Any]) {
        switch self {
        case let .focusPane(paneID, direction):
            return ("pane.focus_direction", ["pane_id": paneID, "direction": direction])
        case let .splitPane(spaceID, paneID, direction):
            return ("pane.split", ["workspace_id": spaceID, "target_pane_id": paneID,
                                   "direction": direction, "focus": true])
        case let .zoomPane(paneID):
            return ("pane.zoom", ["pane_id": paneID])
        case let .renameSpace(spaceID, label):
            return ("workspace.rename", ["workspace_id": spaceID, "label": label])
        case let .closeSpace(spaceID):
            return ("workspace.close", ["workspace_id": spaceID])
        case let .renameAgent(paneID, name):
            return ("agent.rename", ["target": paneID, "name": name ?? NSNull()])
        case let .renameTab(tabID, label):
            return ("tab.rename", ["tab_id": tabID, "label": label])
        case let .closeTab(tabID):
            return ("tab.close", ["tab_id": tabID])
        case let .closePane(paneID):
            return ("pane.close", ["pane_id": paneID])
        case let .moveTab(tabID, insertIndex):
            return ("tab.move", ["tab_id": tabID, "insert_index": insertIndex])
        case .reloadConfig:
            return ("server.reload_config", [:])
        }
    }
}

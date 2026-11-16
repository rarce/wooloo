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

/// Something the UI opens in the connected session; the backend answers with its new ID.
enum SessionCreation: Hashable, Sendable {
    /// A Space in `cwd`, or beside `sourceSpaceID` (in its folder) when `cwd` is nil.
    case space(sourceSpaceID: String?, cwd: String?, label: String?)
    /// The Space of a Git worktree checkout: the one already open there, or a new one.
    /// `repository` is the main checkout; without one, a plain Space opens in the checkout.
    case worktreeSpace(checkout: String, repository: String?)
    case tab(spaceID: String, cwd: String?)
}

/// Where a pane moves.
enum PaneDestination: Hashable, Sendable {
    /// Into a new tab of its Space.
    case newTab
    /// Beside `targetPaneID` in tab `tabID`, splitting it `split` ("right" or "down"). With
    /// `swapAfter`, the two panes then trade places, which puts the pane left of or above the
    /// target. `detachFirst` takes the pane out of its tab first, for moves within one tab.
    case beside(targetPaneID: String, tabID: String, split: String, swapAfter: Bool, detachFirst: Bool)
}

/// Carries out session commands for one connection. Every method blocks until the server has
/// answered: call them inside `BlockingWork`, like every other blocking request. `checkpoint`
/// throws once the caller no longer wants the result, so a long operation stops between steps.
protocol SessionBackend: Sendable {
    var kind: BackendKind { get }
    func perform(_ command: SessionCommand) throws
    /// Opens `item` and returns its ID: a Space's for Spaces and worktrees, a tab's for tabs.
    func create(_ item: SessionCreation) throws -> String
    /// Moves a Space beside another, against the server's latest order; does nothing when it
    /// would stay where it is.
    func moveSpace(_ spaceID: String, beside anchorID: String, after: Bool,
                   checkpoint: @Sendable () throws -> Void) throws
    /// Moves a single-pane tab to another Space, or to a new Space when `spaceID` is nil, and
    /// returns its pane where it landed. `lastTabWasChecked` says whether the caller cleared
    /// closing the source Space; without it, a tab that became the last one is refused.
    func moveTab(_ tabID: String, toSpace spaceID: String?, lastTabWasChecked: Bool,
                 checkpoint: @Sendable () throws -> Void) throws -> WoolooPane
    func movePane(_ paneID: String, to destination: PaneDestination,
                  checkpoint: @Sendable () throws -> Void) throws
}

/// A refusal to show as it is, such as a Space move the server's latest state no longer allows.
struct SessionMoveError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
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

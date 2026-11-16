import Foundation

/// The Herdr TUI server reached through its JSON socket, `herdr.sock` (or the local socket of
/// `HerdrRemoteBridge` for an SSH session). Every method blocks; `HerdrStore` calls them inside
/// `BlockingWork.run`.
struct TUISessionBackend: SessionBackend {
    let socketPath: String

    var kind: BackendKind { .tui }

    /// The Herdr refusals after which a worktree opens in a plain Space: the source is not a main
    /// checkout or not in Git (a bare repository), or the server predates `worktree.open`.
    static let worktreeFallbackCodes: Set<String> = ["linked_worktree_source", "not_git_worktree", "invalid_request"]

    func perform(_ command: SessionCommand) throws {
        let request = command.herdrRequest
        let data = try HerdrSocket.request(path: socketPath, method: request.method, params: request.params)
        if command == .reloadConfig { try Self.requireApplied(data) }
    }

    func create(_ item: SessionCreation) throws -> String {
        switch item {
        case let .space(sourceSpaceID, cwd, label):
            return try HerdrSocket.createWorkspace(path: socketPath, sourceWorkspaceID: sourceSpaceID,
                                                   cwd: cwd, label: label)
        case let .worktreeSpace(checkout, repository):
            if let repository {
                do {
                    return try HerdrSocket.openWorktree(path: socketPath, checkout: checkout, repository: repository)
                } catch HerdrSocketError.refused(let code, _) where Self.worktreeFallbackCodes.contains(code) {}
            }
            return try HerdrSocket.createWorkspace(path: socketPath, sourceWorkspaceID: nil, cwd: checkout,
                                                   label: (checkout as NSString).lastPathComponent)
        case let .tab(spaceID, cwd):
            return try HerdrSocket.createTab(path: socketPath, workspaceID: spaceID, cwd: cwd)
        }
    }

    func moveSpace(_ spaceID: String, beside anchorID: String, after: Bool,
                   checkpoint: @Sendable () throws -> Void) throws {
        let fresh = try HerdrSocket.snapshot(path: socketPath)
        guard let gap = fresh.workspaceMoveIndex(spaceID, beside: anchorID, after: after) else { return }
        try checkpoint()
        _ = try HerdrSocket.request(path: socketPath, method: "workspace.move",
                                    params: ["workspace_id": spaceID, "insert_index": gap])
    }

    /// Herdr moves a pane, not a whole tab, so a single-pane tab moves as its pane.
    func moveTab(_ tabID: String, toSpace spaceID: String?, lastTabWasChecked: Bool,
                 checkpoint: @Sendable () throws -> Void) throws -> WoolooPane {
        let fresh = try HerdrSocket.snapshot(path: socketPath)
        if let reason = fresh.tabSpaceMoveRefusal(tabID, to: spaceID) { throw SessionMoveError(message: reason) }
        guard let currentTab = fresh.tabs.first(where: { $0.tabID == tabID }),
              let pane = fresh.panes.first(where: { $0.tabID == tabID }) else {
            throw SessionMoveError(message: "The source tab disappeared.")
        }
        // The caller checked documents before this ran. If another client removes a sibling
        // tab after that check, fail closed rather than close the Space.
        if fresh.tabs.filter({ $0.workspaceID == currentTab.workspaceID }).count == 1, !lastTabWasChecked {
            throw SessionMoveError(message: "The source Space changed. Try the drag again.")
        }
        let destination: [String: Any] = spaceID.map {
            ["type": "new_tab", "workspace_id": $0, "label": currentTab.label]
        } ?? ["type": "new_workspace", "label": currentTab.label, "tab_label": currentTab.label]
        try checkpoint()
        let response = try HerdrSocket.request(path: socketPath, method: "pane.move",
            params: ["pane_id": pane.paneID, "destination": destination, "focus": false])
        try Self.requireChange(response, in: "move_result", doing: "move the terminal tab")
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let move = result["move_result"] as? [String: Any], let moved = move["pane"] else {
            throw SessionMoveError(message: "Herdr did not return the moved pane. Refresh before trying again.")
        }
        let landed = try JSONDecoder().decode(HerdrPane.self, from: JSONSerialization.data(withJSONObject: moved))
        return WoolooPane(id: landed.paneID, spaceID: landed.workspaceID, tabID: landed.tabID, cwd: landed.cwd,
                          state: landed.agentStatus.map { AgentState($0) })
    }

    /// Herdr refuses same-tab moves, so `detachFirst` moves the pane to a new tab before
    /// inserting it beside the target.
    func movePane(_ paneID: String, to destination: PaneDestination,
                  checkpoint: @Sendable () throws -> Void) throws {
        try checkpoint()
        switch destination {
        case .newTab:
            let moved = try HerdrSocket.request(path: socketPath, method: "pane.move", params: [
                "pane_id": paneID, "destination": ["type": "new_tab"], "focus": true
            ])
            try Self.requireChange(moved, in: "move_result", doing: "move the pane")
        case let .beside(targetPaneID, tabID, split, swapAfter, detachFirst):
            if detachFirst {
                let detached = try HerdrSocket.request(path: socketPath, method: "pane.move", params: [
                    "pane_id": paneID, "destination": ["type": "new_tab"], "focus": false
                ])
                try Self.requireChange(detached, in: "move_result", doing: "detach the pane")
            }
            let moved = try HerdrSocket.request(path: socketPath, method: "pane.move", params: [
                "pane_id": paneID,
                "destination": ["type": "tab", "tab_id": tabID, "split": split, "target_pane_id": targetPaneID],
                "focus": true
            ])
            try Self.requireChange(moved, in: "move_result", doing: "move the pane")
            guard swapAfter else { return }
            let swapped = try HerdrSocket.request(path: socketPath, method: "pane.swap", params: [
                "source_pane_id": paneID, "target_pane_id": targetPaneID
            ])
            try Self.requireChange(swapped, in: "swap", doing: "place the pane on that side")
        }
    }

    /// Herdr answers a move or swap it did not make with `changed: false` and a reason, not an error.
    static func requireChange(_ response: Data, in key: String, doing action: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = (root["result"] as? [String: Any])?[key] as? [String: Any] else {
            throw HerdrSocketError.message("Unexpected response from Herdr")
        }
        guard result["changed"] as? Bool != true else { return }
        let reason = (result["reason"] as? String)?.replacingOccurrences(of: "_", with: " ")
        throw HerdrSocketError.message("Herdr could not \(action)" + (reason.map { ": \($0)" } ?? ""))
    }

    /// Herdr answers a reload with its status and diagnostics rather than an error.
    static func requireApplied(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["result"] as? [String: Any],
              let status = response["status"] as? String else {
            throw HerdrConfigError.validation("Unexpected response from Herdr reload")
        }
        if status != "applied" {
            let details = (response["diagnostics"] as? [String] ?? []).joined(separator: "\n")
            throw HerdrConfigError.validation("Herdr reload: \(status). \(details)")
        }
    }
}

import Foundation

/// What choosing a row of the branch picker does.
enum WorkspaceBranchChoice: Equatable {
    /// Switch to the branch: a local one, or a remote one through a new local branch that tracks
    /// it. A branch checked out in another worktree carries that worktree's path, which opens instead.
    case branch(WorkspaceBranch, worktreePath: String?)
    /// Create a branch with the typed name at HEAD and switch to it.
    case create(String)
}

struct WorkspaceBranchPickerRow: Equatable, Identifiable {
    let choice: WorkspaceBranchChoice
    let title: String
    /// UTF-8 offsets in `title` of the characters the query matched.
    let positions: [Int]

    var id: String {
        switch choice {
        case .branch(let branch, _): return branch.id
        case .create(let name): return "create:" + name
        }
    }
}

/// The branch picker's rows: the branches matching what was typed, then a row to create a branch
/// with that name when none has it.
enum WorkspaceBranchPicker {
    /// Without a query: the current branch, the other local branches, then remote branches.
    /// Remote branches that a local branch already tracks are left out, since choosing them would
    /// only switch to that local branch.
    static func rows(query: String, branches: [WorkspaceBranch], worktrees: [WorkspaceWorktree],
                     root: String) -> [WorkspaceBranchPickerRow] {
        let tracked = Set(branches.filter { !$0.isRemote }.map(\.upstream).filter { !$0.isEmpty })
        let shown = branches.filter { !$0.isRemote && $0.isCurrent }
            + branches.filter { !$0.isRemote && !$0.isCurrent }
            + branches.filter { $0.isRemote && !tracked.contains($0.name) }
        // A branch checked out elsewhere cannot be switched to here; its worktree opens instead.
        var elsewhere: [String: String] = [:]
        for tree in worktrees where tree.path != root && !tree.isBare {
            if let branch = tree.branch { elsewhere[branch] = tree.path }
        }
        func row(_ branch: WorkspaceBranch, _ positions: [Int]) -> WorkspaceBranchPickerRow {
            let path = branch.isRemote || branch.isCurrent ? nil : elsewhere[branch.name]
            return WorkspaceBranchPickerRow(choice: .branch(branch, worktreePath: path), title: branch.name,
                                            positions: positions)
        }

        let parsed = QuickOpenQuery(query)
        var rows: [WorkspaceBranchPickerRow]
        if parsed.terms.isEmpty {
            rows = shown.map { row($0, []) }
        } else {
            let byName = Dictionary(shown.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let matches = QuickOpenMatcher.match(parsed, in: QuickOpenIndex(shown.map(\.name)), recents: [],
                                                 limit: shown.count) ?? []
            rows = matches.compactMap { match in byName[match.path].map { row($0, match.positions) } }
        }
        let name = query.trimmingCharacters(in: .whitespaces)
        if isPlausibleBranchName(name), !branches.contains(where: { !$0.isRemote && $0.name == name }) {
            rows.append(WorkspaceBranchPickerRow(choice: .create(name), title: name, positions: []))
        }
        return rows
    }

    /// Whether `name` could name a new branch. Git checks the full rules when creating it; this
    /// only keeps the picker from offering names Git always refuses.
    static func isPlausibleBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), name != "@",
              !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\").union(.whitespacesAndNewlines).union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

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

/// The branch picker's rows: the branches matching what was typed, and a row to create a branch
/// with that name when no branch has it.
enum WorkspaceBranchPicker {
    /// Without a query: the current branch, the other local branches, then remote branches.
    /// Remote branches are left out when a local branch tracks them or has their name, since
    /// choosing them could only fail or switch to that local branch. `otherWorktrees` are the
    /// usable worktrees besides this one; a branch checked out in one of them opens it instead.
    static func rows(query: String, branches: [WorkspaceBranch],
                     otherWorktrees: [WorkspaceWorktree]) -> [WorkspaceBranchPickerRow] {
        let locals = branches.filter { !$0.isRemote }
        let tracked = Set(locals.map(\.upstream).filter { !$0.isEmpty })
        let localNames = Set(locals.map(\.name))
        let shown = locals.filter(\.isCurrent) + locals.filter { !$0.isCurrent }
            + branches.filter { $0.isRemote && !tracked.contains($0.name) && !localNames.contains(localName(of: $0)) }
        var elsewhere: [String: String] = [:]
        for tree in otherWorktrees {
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
        // Git refuses a name that differs from an existing branch only in case on a case-insensitive
        // disk, or creates a second branch other machines cannot check out.
        guard isPlausibleBranchName(name),
              !locals.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return rows }
        let create = WorkspaceBranchPickerRow(choice: .create(name), title: name, positions: [])
        // A loose fuzzy match should not take ↩ from a new name: the Create row comes first unless a
        // branch contains what was typed as it was typed.
        let contained = rows.contains { $0.title.range(of: name, options: .caseInsensitive) != nil }
        return contained ? rows + [create] : [create] + rows
    }

    /// The local branch `git switch --track` makes for a remote branch: its name without the remote.
    static func localName(of remote: WorkspaceBranch) -> String {
        guard let slash = remote.name.firstIndex(of: "/") else { return remote.name }
        return String(remote.name[remote.name.index(after: slash)...])
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

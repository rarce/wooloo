import Foundation

/// What choosing a row of the branch picker does.
enum WorkspaceBranchChoice: Equatable {
    /// Switch to the branch: a local one, or a remote one through a new local branch that tracks
    /// it. A branch checked out in another worktree carries that worktree: Git will not switch to
    /// it here, so that worktree opens instead, unless its folder is gone.
    case branch(WorkspaceBranch, worktree: WorkspaceWorktree?)
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
/// with that name when no branch has it. Built once per list of branches; each query only matches.
struct WorkspaceBranchPicker {
    /// The branches listed, in order: the current one, the other local ones, then remote ones.
    let shown: [WorkspaceBranch]
    private let index: QuickOpenIndex
    private let elsewhere: [String: WorkspaceWorktree]
    private let branches: [WorkspaceBranch]
    private let remotes: [String]

    /// `otherWorktrees` are the worktrees besides this one, including those whose folder was
    /// deleted, which still hold their branch. `remotes` are the repository's remote names.
    init(branches: [WorkspaceBranch], otherWorktrees: [WorkspaceWorktree], remotes: [String]) {
        let locals = branches.filter { !$0.isRemote }
        shown = locals.filter(\.isCurrent) + locals.filter { !$0.isCurrent }
            + branches.filter { $0.isRemote && Self.canCheckOut($0, among: branches, remotes: remotes) }
        index = QuickOpenIndex(shown.map(\.name))
        var elsewhere: [String: WorkspaceWorktree] = [:]
        for tree in otherWorktrees where !tree.isBare {
            if let branch = tree.branch { elsewhere[branch] = tree }
        }
        self.elsewhere = elsewhere
        self.branches = branches
        self.remotes = remotes
    }

    func rows(query: String) -> [WorkspaceBranchPickerRow] {
        func row(_ branch: WorkspaceBranch, _ positions: [Int]) -> WorkspaceBranchPickerRow {
            let tree = branch.isRemote || branch.isCurrent ? nil : elsewhere[branch.name]
            return WorkspaceBranchPickerRow(choice: .branch(branch, worktree: tree), title: branch.name,
                                            positions: positions)
        }
        let parsed = QuickOpenQuery(query)
        var rows: [WorkspaceBranchPickerRow]
        if parsed.terms.isEmpty {
            rows = shown.map { row($0, []) }
        } else {
            // A local branch can share its name with a remote one; each match takes the next branch
            // of its name, so both stay listed.
            var byName = Dictionary(grouping: shown, by: \.name)
            let matches = QuickOpenMatcher.match(parsed, in: index, recents: [], limit: shown.count) ?? []
            rows = matches.compactMap { match in
                guard let branch = byName[match.path]?.first else { return nil }
                byName[match.path]?.removeFirst()
                return row(branch, match.positions)
            }
        }
        let name = query.trimmingCharacters(in: .whitespaces)
        guard WorkspaceFiles.isValidNewBranchName(name), !clashes(name) else { return rows }
        let create = WorkspaceBranchPickerRow(choice: .create(name), title: name, positions: [])
        // A loose fuzzy match should not take ↩ from a new name: the Create row comes first unless a
        // branch contains what was typed as it was typed.
        let contained = rows.contains { $0.title.range(of: name, options: .caseInsensitive) != nil }
        return contained ? rows + [create] : [create] + rows
    }

    /// Whether a new branch `name` would clash: with a branch differing only in case, which Git
    /// refuses or duplicates on a case-insensitive disk, or with a remote's branches, which it
    /// would make ambiguous.
    private func clashes(_ name: String) -> Bool {
        if branches.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return true }
        let first = name.split(separator: "/").first.map(String.init) ?? name
        return remotes.contains(first)
    }

    /// Whether `git switch --track` can check out a remote branch: no local branch tracks it or
    /// already has the name it would get.
    static func canCheckOut(_ remote: WorkspaceBranch, among branches: [WorkspaceBranch], remotes: [String]) -> Bool {
        guard remote.isRemote else { return false }
        let locals = branches.filter { !$0.isRemote }
        let name = localName(of: remote, remotes: remotes)
        return !locals.contains { $0.upstream == remote.name || $0.name == name }
    }

    /// The local branch `git switch --track` makes for a remote branch: its name without the
    /// remote's. Remote names may contain slashes, so the longest known remote that prefixes it
    /// wins; without remotes, the first path component is taken as the remote.
    static func localName(of remote: WorkspaceBranch, remotes: [String]) -> String {
        if let known = remotes.filter({ remote.name.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return String(remote.name.dropFirst(known.count + 1))
        }
        guard let slash = remote.name.firstIndex(of: "/") else { return remote.name }
        return String(remote.name[remote.name.index(after: slash)...])
    }
}

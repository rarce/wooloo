import SwiftUI

/// Sticky footer under Files and Changes: worktree and branch pickers plus a Git sync split button.
/// In Changes, a commit message editor sits above the status row.
struct WorkspaceGitBar: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let location: WorkspaceFileLocation
    let reloadToken: Int
    /// Working tree changes; non-nil shows the commit editor.
    let changes: [WorkspaceFileChange]?
    let onChange: () -> Void
    let onOpenWorktree: ((String, String) -> Void)?
    let onError: (String) -> Void

    /// Injectable so tests can wait for its load.
    @StateObject var model = WorkspaceGitBarModel()
    @State private var confirmsForcePush = false
    @State private var showsBranchPicker = false
    @State private var expandsEditor = false

    private var identity: String { "\(location.identity)|\(reloadToken)" }
    private var running: String? { model.running }

    var body: some View {
        VStack(spacing: 0) {
            if let changes {
                commitEditor(changes)
                Divider()
            }
            statusRow
        }
        .background(theme.sidebarBackground)
        .task(id: identity) { await model.load(location) }
        .confirmationDialog("Force push this branch?", isPresented: $confirmsForcePush) {
            Button("Force Push", role: .destructive) { perform(.forcePush) }
        } message: {
            Text("Remote commits not present locally will be overwritten, unless someone pushed since your last fetch.")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 4) {
            if let status = model.status {
                worktreeMenu
                branchPicker(status)
                Spacer(minLength: 6)
                syncButton(status)
            } else {
                Spacer()
            }
        }
        .font(.system(size: typography.body))
        .padding(.horizontal, 9)
        .frame(height: typography.metric(32))
    }

    // MARK: Commit

    private func commitEditor(_ changes: [WorkspaceFileChange]) -> some View {
        let plan = WorkspaceCommitPlan(changes: changes)
        let mode = plan.defaultMode
        let font = Font.system(size: typography.code, design: .monospaced)
        let available = { (mode: WorkspaceCommitMode) in plan.isAvailable(mode, typed: model.message) }
        return VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(font)
                    .scrollContentBackground(.hidden)
                    .padding(.trailing, 18)
                if model.message.isEmpty {
                    Text(plan.suggestion ?? "Commit message")
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    expandsEditor.toggle()
                } label: {
                    Image(systemName: expandsEditor ? "arrow.down.right.and.arrow.up.left"
                                                    : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: typography.metric(18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expandsEditor ? "Shrink message editor" : "Expand message editor")
            }
            .frame(height: expandsEditor ? 220 : 84)

            splitButton(title: running ?? mode.title, icon: nil, enabled: available(mode),
                        help: "Commit (⌘↩)", action: { model.commit(mode, plan: plan, finished: finished) }) {
                ForEach([WorkspaceCommitMode.staged, .tracked, .all], id: \.title) { item in
                    Button(item.title) { model.commit(item, plan: plan, finished: finished) }
                        .disabled(!available(item))
                }
                Divider()
                Button("Amend Last Commit") { model.commit(.amend, plan: plan, finished: finished) }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    /// Reports an operation's failure, then lets the explorer refresh.
    private func finished(_ error: String?) {
        if let error { onError(error) }
        onChange()
    }

    // MARK: Pickers

    @ViewBuilder
    private var worktreeMenu: some View {
        let others = model.otherWorktrees
        if !others.isEmpty {
            Menu {
                Section("Worktrees") {
                    if let currentWorktree = model.currentWorktree {
                        Button {} label: { Label(worktreeName(currentWorktree), systemImage: "checkmark") }
                            .disabled(true)
                    }
                    ForEach(others) { tree in
                        Button(worktreeName(tree)) {
                            onOpenWorktree?(tree.path, tree.branch ?? (tree.path as NSString).lastPathComponent)
                        }
                        .disabled(onOpenWorktree == nil)
                    }
                }
            } label: {
                pickerLabel(model.currentWorktree.map(worktreeName) ?? (location.root as NSString).lastPathComponent,
                            icon: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("Switch worktree")
            Text("/").foregroundStyle(.tertiary)
        }
    }

    private func branchPicker(_ status: WorkspaceBranchStatus) -> some View {
        let name = status.branch ?? status.shortHead
        return Button {
            showsBranchPicker.toggle()
        } label: {
            // The padding a borderless menu gives the worktree picker beside it.
            pickerLabel(name, icon: "arrow.triangle.branch")
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(running != nil)
        .help(status.upstream.map { "Switch branch (tracking \($0))" } ?? "Switch branch")
        .contextMenu {
            Button("Copy Branch Name", systemImage: "doc.on.doc") { AppActions.copy(name) }
        }
        .popover(isPresented: $showsBranchPicker, arrowEdge: .top) {
            WorkspaceBranchPickerPanel(branches: model.repository?.branches ?? [],
                                       otherWorktrees: model.otherWorktrees,
                                       current: name, opensWorktrees: onOpenWorktree != nil,
                                       onChoose: choose, onCancel: { showsBranchPicker = false })
        }
    }

    private func choose(_ choice: WorkspaceBranchChoice) {
        showsBranchPicker = false
        switch choice {
        case .branch(let branch, worktreePath: let path?):
            onOpenWorktree?(path, branch.name)
        case .branch(let branch, worktreePath: nil):
            if !branch.isCurrent { model.switchBranch(branch, finished: finished) }
        case .create(let name):
            model.createBranch(name, finished: finished)
        }
    }

    private func pickerLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func worktreeName(_ tree: WorkspaceWorktree) -> String {
        (tree.path as NSString).lastPathComponent
    }

    // MARK: Sync

    private func perform(_ action: WorkspaceGitSync) {
        model.perform(action, finished: finished)
    }

    private func syncButton(_ status: WorkspaceBranchStatus) -> some View {
        let plan = WorkspaceSyncPlan(status: status)
        let action = plan.primaryAction
        let tracks = plan.tracksUpstream
        return splitButton(title: running ?? plan.primaryTitle, icon: action.icon,
                           enabled: plan.hasRemote, help: plan.primaryHelp,
                           action: { perform(action) }) {
            Button(WorkspaceGitSync.fetch.title, systemImage: WorkspaceGitSync.fetch.icon) { perform(.fetch) }
            Divider()
            Button(WorkspaceGitSync.pull.title, systemImage: WorkspaceGitSync.pull.icon) { perform(.pull) }
                .disabled(!tracks)
            Button(WorkspaceGitSync.pullRebase.title) { perform(.pullRebase) }
                .disabled(!tracks)
            Divider()
            if case .publish = action {
                Button(action.title, systemImage: action.icon) { perform(action) }
            } else {
                Button(WorkspaceGitSync.push.title, systemImage: WorkspaceGitSync.push.icon) { perform(.push) }
                    .disabled(!tracks)
            }
            Button("Force Push…") { confirmsForcePush = true }
                .disabled(!tracks)
        }
    }

    /// A primary action with a chevron menu of related actions, drawn as one bordered control.
    private func splitButton<MenuContent: View>(title: String, icon: String?, enabled: Bool, help: String,
                                                action: @escaping () -> Void,
                                                @ViewBuilder menu: () -> MenuContent) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if running != nil {
                        ProgressView().controlSize(.mini)
                    } else if let icon {
                        Image(systemName: icon).font(.system(size: typography.caption, weight: .semibold))
                    }
                    Text(title).lineLimit(1)
                }
                .font(.system(size: typography.secondary))
                .padding(.horizontal, 6)
                .frame(height: typography.metric(19))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: typography.metric(19))

            Menu(content: menu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: typography.tiny, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20, height: typography.metric(19))
            .contentShape(Rectangle())
            .help("More actions")
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.14)))
        .fixedSize()
        .disabled(running != nil)
    }
}

/// What the commit button offers for a set of working tree changes.
struct WorkspaceCommitPlan {
    let changes: [WorkspaceFileChange]
    let staged: [WorkspaceFileChange]
    let tracked: [WorkspaceFileChange]

    init(changes: [WorkspaceFileChange]) {
        self.changes = changes
        staged = changes.filter { $0.indexStatus != " " && $0.indexStatus != "?" }
        tracked = changes.filter { $0.kind != .untracked }
    }

    /// Staged changes when there are any, otherwise every tracked change.
    var defaultMode: WorkspaceCommitMode { staged.isEmpty ? .tracked : .staged }

    /// Zed-style default message when exactly one file changed.
    var suggestion: String? {
        let committed = staged.isEmpty ? tracked : staged
        guard committed.count == 1, let change = committed.first else { return nil }
        let name = (change.path as NSString).lastPathComponent
        switch change.kind {
        case .added, .untracked: return "Create \(name)"
        case .deleted: return "Delete \(name)"
        default: return "Update \(name)"
        }
    }

    func isAvailable(_ mode: WorkspaceCommitMode, typed: String) -> Bool {
        let hasMessage = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || suggestion != nil
        switch mode {
        case .staged: return !staged.isEmpty && hasMessage
        case .tracked: return !tracked.isEmpty && hasMessage
        case .all: return !changes.isEmpty && hasMessage
        case .amend: return true
        }
    }

    /// The typed message, or the suggestion when nothing was typed. An amend with no message
    /// keeps the last commit's.
    func message(for mode: WorkspaceCommitMode, typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty && mode != .amend ? (suggestion ?? "") : trimmed
    }
}

/// The sync button's main action for a branch: publish, pull, push, or fetch.
struct WorkspaceSyncPlan {
    let status: WorkspaceBranchStatus

    var hasRemote: Bool { !status.remotes.isEmpty }
    var tracksUpstream: Bool { status.upstream != nil }

    var primaryAction: WorkspaceGitSync {
        if status.upstream == nil, let branch = status.branch,
           let remote = status.remotes.first(where: { $0 == "origin" }) ?? status.remotes.first {
            return .publish(remote: remote, branch: branch)
        }
        if status.behind > 0 { return .pull }
        if status.ahead > 0 { return .push }
        return .fetch
    }

    /// The action's icon already shows the direction, so the title carries only the commit count.
    var primaryTitle: String {
        switch primaryAction {
        case .pull: return "Pull \(status.behind)"
        case .push: return "Push \(status.ahead)"
        case let action: return action.title
        }
    }

    var primaryHelp: String {
        guard hasRemote else { return "This repository has no remotes" }
        let commits: (Int) -> String = { $0 == 1 ? "1 commit" : "\($0) commits" }
        switch primaryAction {
        case .pull:
            let pull = "Pull \(commits(status.behind))"
            return status.ahead > 0 ? pull + "; \(commits(status.ahead)) to push afterwards" : pull
        case .push: return "Push \(commits(status.ahead))"
        case let action: return action.title
        }
    }
}

/// The Git bar's branch status and repository, and the one Git operation it may run at a time.
@MainActor
final class WorkspaceGitBarModel: ObservableObject {
    @Published private(set) var status: WorkspaceBranchStatus?
    @Published private(set) var repository: WorkspaceRepositoryListing?
    /// The running operation's label, such as "Committing…".
    @Published private(set) var running: String?
    @Published var message = ""
    private var location: WorkspaceFileLocation?
    private var loadGeneration = 0

    var currentWorktree: WorkspaceWorktree? {
        repository?.worktrees.first { $0.path == repository?.root }
    }

    /// The worktrees besides this one that can be opened: not bare, and not deleted without pruning.
    var otherWorktrees: [WorkspaceWorktree] {
        (repository?.worktrees ?? []).filter { $0.path != repository?.root && !$0.isBare && !$0.isPrunable }
    }

    var localBranches: [WorkspaceBranch] {
        (repository?.branches ?? []).filter { !$0.isRemote }
    }

    func load(_ location: WorkspaceFileLocation) async {
        loadGeneration += 1
        let generation = loadGeneration
        self.location = location
        let start = TerminalPipelineMetrics.now()
        defer { TerminalPipelineMetrics.spanShown("git-bar", start: start, detail: location.isLocal ? "local" : "ssh") }
        let result = await Task.detached(priority: .utility) {
            Result { try WorkspaceFiles.gitBar(at: location) }
        }.value
        guard !Task.isCancelled, loadGeneration == generation, location.identity == self.location?.identity else { return }
        switch result {
        case .success(let (status, repository)):
            self.status = status
            self.repository = repository
        case .failure:
            status = nil
            repository = nil
        }
    }

    /// Commits with the typed message or the plan's suggestion, and clears the message on success.
    func commit(_ mode: WorkspaceCommitMode, plan: WorkspaceCommitPlan, finished: @escaping (String?) -> Void) {
        let text = plan.message(for: mode, typed: message)
        run("Committing…", onSuccess: { [weak self] in self?.message = "" }, finished: finished) {
            try WorkspaceFiles.commit(message: text, mode: mode, at: $0)
        }
    }

    func perform(_ action: WorkspaceGitSync, finished: @escaping (String?) -> Void) {
        run(action.title + "…", finished: finished) { try WorkspaceFiles.sync(action, at: $0) }
    }

    func switchBranch(_ branch: WorkspaceBranch, finished: @escaping (String?) -> Void) {
        run("Switching…", finished: finished) { try WorkspaceFiles.switchBranch(branch, at: $0) }
    }

    func createBranch(_ name: String, finished: @escaping (String?) -> Void) {
        run("Creating Branch…", finished: finished) { try WorkspaceFiles.createBranch(name, at: $0) }
    }

    /// Runs one operation off the main thread, reports its error (nil on success), and reloads.
    private func run(_ label: String, onSuccess: @escaping () -> Void = {}, finished: @escaping (String?) -> Void,
                     _ operation: @escaping @Sendable (WorkspaceFileLocation) throws -> Void) {
        guard running == nil, let location else { return }
        running = label
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation(location) } }.value
            running = nil
            switch result {
            case .success:
                onSuccess()
                finished(nil)
            case .failure(let failure):
                finished(failure.localizedDescription)
            }
            // A bar that moved to another location meanwhile loads that one itself.
            if self.location?.identity == location.identity { await load(location) }
        }
    }
}

/// The branch picker: type to filter the branches, ↑ and ↓ to move, ↩ to switch, or type a new
/// name to create a branch.
struct WorkspaceBranchPickerPanel: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let branches: [WorkspaceBranch]
    let otherWorktrees: [WorkspaceWorktree]
    let current: String
    /// Whether a branch checked out in another worktree can open it.
    let opensWorktrees: Bool
    let onChoose: (WorkspaceBranchChoice) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var selection = 0
    /// Matched again only when the query or the branches change, not on every move of the selection.
    @State private var rows: [WorkspaceBranchPickerRow] = []

    private var rowHeight: CGFloat { typography.metric(26) }

    private func refresh() {
        rows = WorkspaceBranchPicker.rows(query: query, branches: branches, otherWorktrees: otherWorktrees)
        selection = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: typography.body))
                    .foregroundStyle(theme.accent)
                PickerField(text: $query, placeholder: "Switch branch or type a new name",
                            font: .systemFont(ofSize: typography.body),
                            onMove: { move($0, in: rows) }, onSubmit: { submit(rows) }, onCancel: onCancel)
            }
            .padding(.horizontal, 10)
            .frame(height: typography.metric(32))
            Divider()
            if rows.isEmpty {
                Text(query.isEmpty ? "No branches" : "No matching branches")
                    .font(.system(size: typography.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            } else {
                list(rows)
            }
        }
        .frame(width: 340)
        .onAppear(perform: refresh)
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: branches) { _, _ in refresh() }
        .onChange(of: otherWorktrees) { _, _ in refresh() }
    }

    private func list(_ rows: [WorkspaceBranchPickerRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                submit(rows)
                            }
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(rows.count) * rowHeight + 8, 320))
            .onChange(of: selection) { _, index in
                if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
            }
        }
    }

    private func rowView(_ row: WorkspaceBranchPickerRow, selected: Bool) -> some View {
        let detail = detail(row)
        return HStack(spacing: 7) {
            Image(systemName: icon(row))
                .font(.system(size: typography.secondary))
                .foregroundStyle(isCurrent(row) ? theme.accent : Color.secondary)
                .frame(width: 14)
            if case .create = row.choice {
                Text("Create branch “\(row.title)”")
                    .font(.system(size: typography.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(PickerHighlight.text(row.title, from: 0, row.positions, color: theme.accent, size: typography.body))
                    .font(.system(size: typography.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .opacity(isAvailable(row) ? 1 : 0.5)
        .help(help(row))
    }

    private func isCurrent(_ row: WorkspaceBranchPickerRow) -> Bool {
        if case .branch(let branch, _) = row.choice { return branch.isCurrent }
        return false
    }

    private func isAvailable(_ row: WorkspaceBranchPickerRow) -> Bool {
        if case .branch(_, worktreePath: _?) = row.choice { return opensWorktrees }
        return true
    }

    private func icon(_ row: WorkspaceBranchPickerRow) -> String {
        switch row.choice {
        case .create: return "plus"
        case .branch(let branch, let path):
            if branch.isCurrent { return "checkmark" }
            if path != nil { return "folder" }
            return branch.isRemote ? "cloud" : "arrow.triangle.branch"
        }
    }

    private func detail(_ row: WorkspaceBranchPickerRow) -> String? {
        switch row.choice {
        case .create: return "from \(current)"
        case .branch(let branch, let path):
            if branch.isCurrent { return "current" }
            if let path { return (path as NSString).lastPathComponent }
            return branch.isRemote ? "remote" : nil
        }
    }

    private func help(_ row: WorkspaceBranchPickerRow) -> String {
        switch row.choice {
        case .create(let name): return "Create \(name) from \(current) and switch to it, keeping uncommitted changes"
        case .branch(let branch, let path):
            if branch.isCurrent { return "The current branch" }
            if let path {
                return opensWorktrees ? "Checked out in \(path); choose it to open that worktree"
                                      : "Checked out in \(path), so Git cannot switch to it here"
            }
            if branch.isRemote { return "Create a local branch tracking \(branch.name) and switch to it" }
            return "Switch to \(branch.name)"
        }
    }

    private func move(_ delta: Int, in rows: [WorkspaceBranchPickerRow]) {
        guard !rows.isEmpty else { return }
        selection = ((selection + delta) % rows.count + rows.count) % rows.count
    }

    private func submit(_ rows: [WorkspaceBranchPickerRow]) {
        guard rows.indices.contains(selection), isAvailable(rows[selection]) else { return }
        onChoose(rows[selection].choice)
    }
}

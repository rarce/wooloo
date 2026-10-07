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
                branchMenu(status)
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

    private func branchMenu(_ status: WorkspaceBranchStatus) -> some View {
        Menu {
            Section("Branches") {
                ForEach(model.localBranches) { branch in
                    Button {
                        model.switchBranch(branch, finished: finished)
                    } label: {
                        if branch.isCurrent { Label(branch.name, systemImage: "checkmark") } else { Text(branch.name) }
                    }
                    .disabled(branch.isCurrent)
                }
            }
            Divider()
            Button("Copy Branch Name", systemImage: "doc.on.doc") {
                AppActions.copy(status.branch ?? status.shortHead)
            }
        } label: {
            pickerLabel(status.branch ?? status.shortHead, icon: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(running != nil)
        .help(status.upstream.map { "Tracking \($0)" } ?? "Switch branch")
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

    var otherWorktrees: [WorkspaceWorktree] {
        (repository?.worktrees ?? []).filter { $0.path != repository?.root && !$0.isBare }
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

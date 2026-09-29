import SwiftUI

/// Sticky footer under Files and Changes: worktree and branch pickers plus a Git sync split button.
/// In Changes, a commit message editor sits above the status row.
struct WorkspaceGitBar: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    let location: WorkspaceFileLocation
    let reloadToken: Int
    /// Working tree changes; non-nil shows the commit editor.
    let changes: [WorkspaceFileChange]?
    let onChange: () -> Void
    let onOpenWorktree: ((String, String) -> Void)?
    let onError: (String) -> Void

    @State private var status: WorkspaceBranchStatus?
    @State private var repository: WorkspaceRepositoryListing?
    @State private var running: String?
    @State private var confirmsForcePush = false
    @State private var message = ""
    @State private var expandsEditor = false

    private var identity: String { "\(location.identity)|\(reloadToken)" }

    var body: some View {
        VStack(spacing: 0) {
            if let changes {
                commitEditor(changes)
                Divider()
            }
            statusRow
        }
        .background(theme.sidebarBackground)
        .task(id: identity) { await load() }
        .confirmationDialog("Force push this branch?", isPresented: $confirmsForcePush) {
            Button("Force Push", role: .destructive) { perform(.forcePush) }
        } message: {
            Text("Remote commits not present locally will be overwritten, unless someone pushed since your last fetch.")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 4) {
            if let status {
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
        let staged = changes.filter { $0.indexStatus != " " && $0.indexStatus != "?" }
        let tracked = changes.filter { $0.kind != .untracked }
        let mode: WorkspaceCommitMode = staged.isEmpty ? .tracked : .staged
        let suggestion = suggestedMessage(staged.isEmpty ? tracked : staged)
        let font = Font.system(size: typography.code, design: .monospaced)
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || suggestion != nil
        let available: (WorkspaceCommitMode) -> Bool = { mode in
            switch mode {
            case .staged: return !staged.isEmpty && hasMessage
            case .tracked: return !tracked.isEmpty && hasMessage
            case .all: return !changes.isEmpty && hasMessage
            case .amend: return true
            }
        }
        return VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(font)
                    .scrollContentBackground(.hidden)
                    .padding(.trailing, 18)
                if message.isEmpty {
                    Text(suggestion ?? "Commit message")
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
                        help: "Commit (⌘↩)", action: { commit(mode, suggestion: suggestion) }) {
                ForEach([WorkspaceCommitMode.staged, .tracked, .all], id: \.title) { item in
                    Button(item.title) { commit(item, suggestion: suggestion) }
                        .disabled(!available(item))
                }
                Divider()
                Button("Amend Last Commit") { commit(.amend, suggestion: nil) }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    /// Zed-style default message when exactly one file changed.
    private func suggestedMessage(_ changes: [WorkspaceFileChange]) -> String? {
        guard changes.count == 1, let change = changes.first else { return nil }
        let name = (change.path as NSString).lastPathComponent
        switch change.kind {
        case .added, .untracked: return "Create \(name)"
        case .deleted: return "Delete \(name)"
        default: return "Update \(name)"
        }
    }

    private func commit(_ mode: WorkspaceCommitMode, suggestion: String?) {
        let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty && mode != .amend ? (suggestion ?? "") : typed
        run("Committing…", onSuccess: { message = "" }) {
            try WorkspaceFiles.commit(message: text, mode: mode, at: $0)
        }
    }

    // MARK: Pickers

    private var currentWorktree: WorkspaceWorktree? {
        repository?.worktrees.first { $0.path == repository?.root }
    }

    @ViewBuilder
    private var worktreeMenu: some View {
        let others = (repository?.worktrees ?? []).filter { $0.path != repository?.root && !$0.isBare }
        if !others.isEmpty {
            Menu {
                Section("Worktrees") {
                    if let currentWorktree {
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
                pickerLabel(currentWorktree.map(worktreeName) ?? (location.root as NSString).lastPathComponent,
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
        let locals = (repository?.branches ?? []).filter { !$0.isRemote }
        return Menu {
            Section("Branches") {
                ForEach(locals) { branch in
                    Button {
                        switchBranch(branch)
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

    private func primaryAction(_ status: WorkspaceBranchStatus) -> WorkspaceGitSync {
        if status.upstream == nil, let branch = status.branch,
           let remote = status.remotes.first(where: { $0 == "origin" }) ?? status.remotes.first {
            return .publish(remote: remote, branch: branch)
        }
        if status.behind > 0 { return .pull }
        if status.ahead > 0 { return .push }
        return .fetch
    }

    private func primaryTitle(_ action: WorkspaceGitSync, _ status: WorkspaceBranchStatus) -> String {
        switch action {
        case .pull: return status.ahead > 0 ? "Pull ↓\(status.behind) ↑\(status.ahead)" : "Pull ↓\(status.behind)"
        case .push: return "Push ↑\(status.ahead)"
        default: return action.title
        }
    }

    private func syncButton(_ status: WorkspaceBranchStatus) -> some View {
        let action = primaryAction(status)
        let hasRemote = !status.remotes.isEmpty
        let tracks = status.upstream != nil
        return splitButton(title: running ?? primaryTitle(action, status), icon: action.icon,
                           enabled: hasRemote,
                           help: hasRemote ? action.title : "This repository has no remotes",
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
                        Image(systemName: icon).font(.system(size: typography.secondary))
                    }
                    Text(title).lineLimit(1)
                }
                .font(.system(size: typography.body))
                .padding(.horizontal, 7)
                .frame(height: typography.metric(21))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: typography.metric(21))

            Menu(content: menu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: typography.tiny, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22, height: typography.metric(21))
            .contentShape(Rectangle())
            .help("More actions")
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.14)))
        .fixedSize()
        .disabled(running != nil)
    }

    // MARK: Operations

    private func load() async {
        let location = location
        let result = await Task.detached(priority: .utility) {
            Result { (try WorkspaceFiles.branchStatus(at: location), try? WorkspaceFiles.repository(at: location)) }
        }.value
        guard location.identity == self.location.identity else { return }
        switch result {
        case .success(let (status, repository)):
            self.status = status
            self.repository = repository
        case .failure:
            status = nil
            repository = nil
        }
    }

    private func perform(_ action: WorkspaceGitSync) {
        run(action.title + "…") { try WorkspaceFiles.sync(action, at: $0) }
    }

    private func switchBranch(_ branch: WorkspaceBranch) {
        run("Switching…") { try WorkspaceFiles.switchBranch(branch, at: $0) }
    }

    private func run(_ label: String, onSuccess: @escaping () -> Void = {},
                     _ operation: @escaping @Sendable (WorkspaceFileLocation) throws -> Void) {
        guard running == nil else { return }
        let location = location
        running = label
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation(location) } }.value
            running = nil
            switch result {
            case .success: onSuccess()
            case .failure(let failure): onError(failure.localizedDescription)
            }
            onChange()
            await load()
        }
    }
}

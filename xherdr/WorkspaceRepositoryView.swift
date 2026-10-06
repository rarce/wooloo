import SwiftUI

struct WorkspaceRepositoryView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    let location: WorkspaceFileLocation?
    let refreshVersion: Int
    @Binding var isCollapsed: Bool
    let onChange: () -> Void
    let onNewSpace: ((String, String) -> Void)?
    let onOpenCommitFile: (WorkspaceFileLocation, WorkspaceCommit, WorkspaceCommitFile) -> Void
    /// A Space-relative file whose history the History tab shows instead of the branch's.
    @Binding var historyPath: String?

    /// The model, tab and commit shown first are not private so snapshot tests can set them.
    @StateObject var model = WorkspaceRepositoryModel()
    @State var selectedTab = 0
    @State var selectedCommit: WorkspaceCommit? = nil
    @State private var addRequest: AddWorktreeRequest?
    @State private var removing: WorkspaceWorktree?
    @State private var selectedCommitFile: String?

    private var listing: WorkspaceRepositoryListing? { model.listing }
    private var error: String? { model.error }
    private var isLoading: Bool { model.isLoading }
    private var commitFiles: [WorkspaceCommitFile]? { model.commitFiles }
    private var commitFilesError: String? { model.commitFilesError }

    private var identity: String {
        "\(location?.identity ?? "none")|\(refreshVersion)|\(model.reloadVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { isCollapsed.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: typography.tiny, weight: .semibold))
                            .frame(width: 9)
                        Text("REPOSITORY")
                            .font(.system(size: typography.secondary, weight: .semibold))
                            .tracking(0.7)
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: typography.secondary))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show repository" : "Hide repository")
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: typography.secondary))
                }
                .buttonStyle(.plain)
                .help("Refresh repository")
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(34))
            .contentShape(Rectangle())
            .contextMenu {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                if let listing {
                    Button("Add Worktree…", systemImage: "plus") { prepareAdd(listing) }
                        .disabled(listing.branches.isEmpty)
                }
                if let location {
                    Divider()
                    Button("Copy Repository Path", systemImage: "doc.on.doc") { AppActions.copy(location.root) }
                    if location.isLocal {
                        Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.root) }
                    }
                }
            }
            if !isCollapsed {
                Divider()
                HStack(spacing: 0) {
                    tab("History", icon: "clock.arrow.circlepath", index: 0)
                    tab("Branches", icon: "point.3.connected.trianglepath.dotted", index: 1)
                }
                .padding(.horizontal, 3)
                Divider()

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    hint(error).foregroundStyle(theme.warning)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let listing {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if selectedTab == 0 {
                                if let selectedCommit { commitDetail(selectedCommit) }
                                else if let historyPath { fileHistory(historyPath) }
                                else { history(listing) }
                            }
                            else { branches(listing) }
                        }
                        .padding(.vertical, 4)
                    }
                    .id("\(selectedTab)|\(selectedCommit?.id ?? "")")
                } else {
                    hint("Select a Space to browse its repository")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(theme.sidebarBackground)
        // A collapsed repository loads when it is opened again.
        .task(id: "\(identity)|\(isCollapsed)") { if !isCollapsed { await model.load(location) } }
        .task(id: "\(location?.identity ?? "")|\(selectedCommit?.id ?? "")") {
            await model.loadCommitFiles(selectedCommit?.id, at: location)
        }
        .task(id: "\(identity)|\(historyPath ?? "")") { await model.loadFileHistory(historyPath, at: location) }
        .onChange(of: location?.identity) { _, _ in
            selectedCommit = nil
            historyPath = nil
        }
        .onChange(of: historyPath) { _, path in
            guard path != nil else { return }
            selectedCommit = nil
            selectedTab = 0
            isCollapsed = false
        }
        .sheet(item: $addRequest) { request in
            AddWorktreeSheet(request: request) { branch, path, newBranch in
                if let location { model.addWorktree(at: location, branch: branch, path: path, newBranch: newBranch) }
            }
        }
        .confirmationDialog("Remove worktree?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            if let removing {
                Button("Remove \((removing.path as NSString).lastPathComponent)", role: .destructive) {
                    self.removing = nil
                    if let location { model.removeWorktree(removing, at: location) }
                }
            }
        } message: {
            Text("Git will remove this worktree only if it has no uncommitted changes.")
        }
        .alert("Repository operation failed", isPresented: Binding(
            get: { model.operationError != nil }, set: { if !$0 { model.clearOperationError() } }
        )) {
            Button("OK") { model.clearOperationError() }
        } message: {
            Text(model.operationError ?? "")
        }
    }

    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            Label(title, systemImage: icon)
                .font(.system(size: typography.secondary, weight: selectedTab == index ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: typography.metric(25))
                .background(selectedTab == index ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                // Keep the spacing inside the hit area so the whole strip is clickable.
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: typography.body)).foregroundStyle(.secondary).padding(10)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: typography.caption, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 11)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    private func history(_ listing: WorkspaceRepositoryListing) -> some View {
        commitList(listing.commits)
    }

    /// The commits that changed one file, under a header that goes back to the whole history.
    private func fileHistory(_ path: String) -> some View {
        Group {
            HStack(spacing: 5) {
                Image(systemName: "doc.text").font(.system(size: typography.caption))
                Text((path as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { historyPath = nil } label: {
                    Image(systemName: "xmark").font(.system(size: typography.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Show the whole history")
            }
            .font(.system(size: typography.secondary))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: typography.metric(22))
            .help("History of \(path)")
            if let error = model.fileHistoryError {
                hint(error).foregroundStyle(theme.warning)
            } else if let commits = model.fileHistory {
                commitList(commits)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            }
        }
    }

    private func commitList(_ commits: [WorkspaceCommit]) -> some View {
        Group {
            if commits.isEmpty { hint("No commits") }
            ForEach(commits) { commit in
                Button {
                    selectedCommitFile = nil
                    selectedCommit = commit
                } label: {
                    commitSummary(commit)
                }
                .buttonStyle(.plain)
                .help(commit.id)
                .contextMenu { commitActions(commit) }
            }
        }
    }

    private func commitSummary(_ commit: WorkspaceCommit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .font(.system(size: typography.body))
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(commit.shortHash).foregroundStyle(theme.accent)
                Text("·")
                Text(commit.author).lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.relativeDate)
                    .lineLimit(1)
                    .help(commit.absoluteDate)
            }
            .font(.system(size: typography.caption))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func commitActions(_ commit: WorkspaceCommit) -> some View {
        Button("Copy Commit Hash", systemImage: "number") { AppActions.copy(commit.id) }
        Button("Copy Short Hash") { AppActions.copy(commit.shortHash) }
        Button("Copy Subject", systemImage: "text.quote") { AppActions.copy(commit.subject) }
    }

    private func commitDetail(_ commit: WorkspaceCommit) -> some View {
        Group {
            Button {
                selectedCommit = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: typography.caption, weight: .semibold))
                    Text(historyPath.map { "History of \(($0 as NSString).lastPathComponent)" } ?? "History")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .frame(height: typography.metric(22))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to history")

            commitSummary(commit)
                .help(commit.id)
                .contextMenu { commitActions(commit) }
            Divider().padding(.vertical, 2)

            if let commitFilesError {
                hint(commitFilesError).foregroundStyle(theme.warning)
            } else if let commitFiles {
                let added = commitFiles.compactMap(\.additions).reduce(0, +)
                let removed = commitFiles.compactMap(\.deletions).reduce(0, +)
                HStack(spacing: 6) {
                    Text(commitFiles.count == 1 ? "1 file" : "\(commitFiles.count) files")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    lineCounts(added, removed)
                }
                .font(.system(size: typography.secondary))
                .padding(.horizontal, 11)
                .frame(height: typography.metric(20))
                if commitFiles.isEmpty { hint("No file changes") }
                ForEach(commitFiles) { file in commitFileRow(file, commit: commit) }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            }
        }
    }

    private func commitFileRow(_ file: WorkspaceCommitFile, commit: WorkspaceCommit) -> some View {
        let kind = commitFileKind(file.status)
        let name = (file.path as NSString).lastPathComponent
        let directory = (file.path as NSString).deletingLastPathComponent
        return Button {
            guard let location else { return }
            selectedCommitFile = file.path
            onOpenCommitFile(location, commit, file)
        } label: {
            HStack(spacing: 6) {
                Text(String(file.status))
                    .font(.system(size: typography.caption, weight: .semibold))
                    .foregroundStyle(theme.vcs(kind))
                    .frame(width: 11)
                Text(name)
                    .foregroundStyle(theme.vcs(kind))
                    .strikethrough(kind == .deleted)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let additions = file.additions, let deletions = file.deletions {
                    lineCounts(additions, deletions)
                } else {
                    Text("binary").font(.system(size: typography.caption)).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 11)
            .frame(height: typography.metric(23))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedCommitFile == file.path ? Color.primary.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(file.path) }
        }
    }

    private func lineCounts(_ additions: Int, _ deletions: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(theme.diffAdded)
            Text("−\(deletions)").foregroundStyle(theme.diffRemoved)
        }
        .font(.system(size: typography.secondary, design: .monospaced))
    }

    private func commitFileKind(_ status: Character) -> WorkspaceFileChange.Kind {
        switch status {
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        default: return .modified
        }
    }

    private func branches(_ listing: WorkspaceRepositoryListing) -> some View {
        Group {
            heading("Local")
            let local = listing.branches.filter { !$0.isRemote }
            if local.isEmpty { hint("No local branches") }
            ForEach(local) { branch in branchRow(branch, listing: listing) }

            heading("Remote")
            let remote = listing.branches.filter(\.isRemote)
            if remote.isEmpty { hint("No remote branches") }
            ForEach(remote) { branch in branchRow(branch, listing: listing) }

            HStack {
                heading("Worktrees")
                Spacer()
                Button { prepareAdd(listing) } label: {
                    Image(systemName: "plus").font(.system(size: typography.body))
                }
                .buttonStyle(.plain)
                .help("Add worktree")
                .padding(.trailing, 11)
                .disabled(listing.branches.isEmpty)
            }
            ForEach(listing.worktrees) { tree in
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.branch ?? "Detached HEAD")
                            .font(.system(size: typography.body))
                            .lineLimit(1)
                        Text(tree.path)
                            .font(.system(size: typography.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if tree.path != listing.root && !tree.isBare && !tree.isLocked && !tree.isPrunable {
                        Button { removing = tree } label: {
                            Image(systemName: "minus.circle").font(.system(size: typography.body))
                        }
                        .buttonStyle(.plain)
                        .help("Remove worktree")
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: typography.metric(35))
                .contentShape(Rectangle())
                .help(tree.path)
                .contextMenu {
                    if let onNewSpace, tree.path != location?.root, !tree.isBare {
                        Button("Open as Space", systemImage: "square.stack") {
                            onNewSpace(tree.path, tree.branch ?? (tree.path as NSString).lastPathComponent)
                        }
                        Divider()
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(tree.path) }
                    if let branch = tree.branch {
                        Button("Copy Branch Name") { AppActions.copy(branch) }
                    }
                    if location?.isLocal == true {
                        Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(tree.path) }
                    }
                    if tree.path != listing.root && !tree.isBare && !tree.isLocked && !tree.isPrunable {
                        Divider()
                        Button("Remove Worktree…", systemImage: "minus.circle", role: .destructive) {
                            removing = tree
                        }
                    }
                }
            }
        }
    }

    private func branchRow(_ branch: WorkspaceBranch, listing: WorkspaceRepositoryListing) -> some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.system(size: typography.secondary))
                .foregroundStyle(branch.isCurrent ? theme.accent : Color.secondary)
                .frame(width: 15)
            Text(branch.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: typography.body))
        .padding(.horizontal, 11)
        .frame(height: typography.metric(23))
        .contentShape(Rectangle())
        .help(branch.upstream.isEmpty ? branch.id : "Tracks \(branch.upstream)")
        .contextMenu {
            if !branch.isRemote && !branch.isCurrent {
                Button("Switch to Branch", systemImage: "arrow.triangle.swap") {
                    if let location { model.switchBranch(branch, at: location, onSwitched: onChange) }
                }
            }
            Button("Add Worktree from Branch…", systemImage: "plus") { prepareAdd(listing, from: branch) }
            Divider()
            Button("Copy Branch Name", systemImage: "doc.on.doc") { AppActions.copy(branch.name) }
            if !branch.upstream.isEmpty {
                Button("Copy Upstream Name") { AppActions.copy(branch.upstream) }
            }
        }
    }

    private func prepareAdd(_ listing: WorkspaceRepositoryListing, from preferred: WorkspaceBranch? = nil) {
        addRequest = AddWorktreeRequest.suggested(for: listing, from: preferred)
    }

    /// An explicit refresh reads the repository again, even if it was just loaded.
    private func reload() {
        WorkspaceFiles.forgetRecentResults()
        model.reload()
    }
}

/// The repository panel's listing, a selected commit's files, and worktree and branch operations.
@MainActor
final class WorkspaceRepositoryModel: ObservableObject {
    @Published private(set) var listing: WorkspaceRepositoryListing?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    /// Bumped after an operation changes the repository, so the panel loads it again.
    @Published private(set) var reloadVersion = 0
    @Published private(set) var operationError: String?
    @Published private(set) var commitFiles: [WorkspaceCommitFile]?
    @Published private(set) var commitFilesError: String?
    /// Commits of the file whose history is shown; nil while it loads or when none is.
    @Published private(set) var fileHistory: [WorkspaceCommit]?
    @Published private(set) var fileHistoryError: String?
    private var fileHistoryKey: String?
    private var location: WorkspaceFileLocation?
    private var loadGeneration = 0
    /// The commit whose files are wanted, with its location.
    private var commitKey: String?

    func reload() { reloadVersion += 1 }

    func clearOperationError() { operationError = nil }

    /// Loads the repository of `location`; reloading the one already shown keeps it on screen.
    func load(_ location: WorkspaceFileLocation?) async {
        loadGeneration += 1
        let generation = loadGeneration
        let isReload = listing != nil && self.location?.identity == location?.identity
        self.location = location
        guard let location else { listing = nil; error = nil; return }
        isLoading = !isReload
        error = nil
        let start = TerminalPipelineMetrics.now()
        let result = await Task.detached { Result { try WorkspaceFiles.repository(at: location) } }.value
        guard !Task.isCancelled, loadGeneration == generation, self.location?.identity == location.identity else { return }
        switch result {
        case .success(let value): listing = value
        case .failure(let failure): error = failure.localizedDescription
        }
        isLoading = false
        TerminalPipelineMetrics.spanShown("repository", start: start, detail: location.isLocal ? "local" : "ssh")
    }

    /// Loads the files of the selected commit; nil clears them.
    func loadCommitFiles(_ hash: String?, at location: WorkspaceFileLocation?) async {
        commitKey = hash.map { "\(location?.identity ?? "")|\($0)" }
        commitFiles = nil
        commitFilesError = nil
        guard let location, let hash, let key = commitKey else { return }
        let start = TerminalPipelineMetrics.now()
        defer { TerminalPipelineMetrics.spanShown("commit-files", start: start, detail: location.isLocal ? "local" : "ssh") }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try WorkspaceFiles.commitFiles(hash, at: location) }
        }.value
        guard commitKey == key else { return }
        switch result {
        case .success(let files): commitFiles = files
        case .failure(let failure): commitFilesError = failure.localizedDescription
        }
    }

    /// Loads the commits that changed `path`; nil clears them.
    func loadFileHistory(_ path: String?, at location: WorkspaceFileLocation?) async {
        let key = path.map { "\(location?.identity ?? "")|\($0)" }
        // A reload of the file shown keeps its commits on screen.
        if key != fileHistoryKey { fileHistory = nil }
        fileHistoryKey = key
        fileHistoryError = nil
        guard let location, let path, let key else { fileHistory = nil; return }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try WorkspaceFiles.fileHistory(path, at: location) }
        }.value
        guard fileHistoryKey == key else { return }
        switch result {
        case .success(let commits): fileHistory = commits
        case .failure(let failure): fileHistoryError = failure.localizedDescription
        }
    }

    func addWorktree(at location: WorkspaceFileLocation, branch: WorkspaceBranch, path: String, newBranch: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            try WorkspaceFiles.addWorktree(at: location, path: path, branch: branch, newBranch: name.isEmpty ? nil : name)
        }
    }

    func switchBranch(_ branch: WorkspaceBranch, at location: WorkspaceFileLocation, onSwitched: @escaping () -> Void) {
        run(onSuccess: onSwitched) { try WorkspaceFiles.switchBranch(branch, at: location) }
    }

    /// Git refuses to remove a worktree with uncommitted changes; that refusal is reported.
    func removeWorktree(_ tree: WorkspaceWorktree, at location: WorkspaceFileLocation) {
        run { try WorkspaceFiles.removeWorktree(at: location, path: tree.path) }
    }

    private func run(onSuccess: @escaping () -> Void = {}, _ operation: @escaping @Sendable () throws -> Void) {
        Task {
            let result = await Task.detached { Result { try operation() } }.value
            switch result {
            case .success:
                reloadVersion += 1
                onSuccess()
            case .failure(let failure): operationError = failure.localizedDescription
            }
        }
    }
}

struct AddWorktreeRequest: Identifiable {
    let id = UUID()
    let branches: [WorkspaceBranch]
    let branchID: String
    let path: String
    let newBranch: String

    /// Starts from `preferred`, or the first local branch not checked out. A branch that is
    /// already checked out or remote needs a new local branch, named after it. The worktree
    /// goes beside the repository, named after the repository and the branch.
    static func suggested(for listing: WorkspaceRepositoryListing, from preferred: WorkspaceBranch? = nil) -> AddWorktreeRequest? {
        guard let branch = preferred ?? listing.branches.first(where: { !$0.isRemote && !$0.isCurrent })
            ?? listing.branches.first else { return nil }
        let newBranch = (branch.isCurrent || branch.isRemote)
            ? branch.name.split(separator: "/").last.map(String.init).map { $0 + "-worktree" } ?? "worktree"
            : ""
        let parent = (listing.root as NSString).deletingLastPathComponent
        let name = (listing.root as NSString).lastPathComponent
        let path = parent + "/" + name + "-" + branch.name.replacingOccurrences(of: "/", with: "-")
        return AddWorktreeRequest(branches: listing.branches, branchID: branch.id, path: path, newBranch: newBranch)
    }
}

private struct AddWorktreeSheet: View {
    @Environment(\.xherdrTypography) private var typography
    let request: AddWorktreeRequest
    let onAdd: (WorkspaceBranch, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var branchID: String
    @State private var path: String
    @State private var newBranch: String

    init(request: AddWorktreeRequest, onAdd: @escaping (WorkspaceBranch, String, String) -> Void) {
        self.request = request
        self.onAdd = onAdd
        _branchID = State(initialValue: request.branchID)
        _path = State(initialValue: request.path)
        _newBranch = State(initialValue: request.newBranch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Worktree").font(.headline)
            Picker("Start from", selection: $branchID) {
                ForEach(request.branches) { branch in
                    Text(branch.isRemote ? "Remote · \(branch.name)" : "Local · \(branch.name)")
                        .tag(branch.id)
                }
            }
            TextField("Absolute path", text: $path)
            TextField("New local branch (optional)", text: $newBranch)
            Text("A remote branch needs a new local branch name. Git refuses to add a branch that is already checked out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let branch = request.branches.first(where: { $0.id == branchID }) else { return }
                    onAdd(branch, path, newBranch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || branchID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

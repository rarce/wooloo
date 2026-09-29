import SwiftUI

struct WorkspaceRepositoryView: View {
    @Environment(\.xherdrTheme) private var theme
    let location: WorkspaceFileLocation?
    let refreshVersion: Int
    let onChange: () -> Void
    let onNewSpace: ((String, String) -> Void)?
    let onOpenCommitFile: (WorkspaceFileLocation, WorkspaceCommit, WorkspaceCommitFile) -> Void

    @State private var listing: WorkspaceRepositoryListing?
    @State private var error: String?
    @State private var isLoading = false
    @State private var selectedTab = 0
    @State private var reloadVersion = 0
    @State private var addRequest: AddWorktreeRequest?
    @State private var removing: WorkspaceWorktree?
    @State private var operationError: String?
    @State private var selectedCommit: WorkspaceCommit?
    @State private var commitFiles: [WorkspaceCommitFile]?
    @State private var commitFilesError: String?
    @State private var selectedCommitFile: String?

    private var identity: String {
        "\(location?.identity ?? "none")|\(refreshVersion)|\(reloadVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("REPOSITORY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { reloadVersion += 1 } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Refresh repository")
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Refresh", systemImage: "arrow.clockwise") { reloadVersion += 1 }
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
                            if let selectedCommit { commitDetail(selectedCommit) } else { history(listing) }
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
        .background(theme.sidebarBackground)
        .task(id: identity) { load() }
        .task(id: "\(location?.identity ?? "")|\(selectedCommit?.id ?? "")") { await loadCommitFiles() }
        .onChange(of: location?.identity) { _, _ in selectedCommit = nil }
        .sheet(item: $addRequest) { request in
            AddWorktreeSheet(request: request) { branch, path, newBranch in
                add(branch: branch, path: path, newBranch: newBranch)
            }
        }
        .confirmationDialog("Remove worktree?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            if let removing {
                Button("Remove \((removing.path as NSString).lastPathComponent)", role: .destructive) {
                    remove(removing)
                }
            }
        } message: {
            Text("Git will remove this worktree only if it has no uncommitted changes.")
        }
        .alert("Repository operation failed", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
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
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 11)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    private func history(_ listing: WorkspaceRepositoryListing) -> some View {
        Group {
            if listing.commits.isEmpty { hint("No commits") }
            ForEach(listing.commits) { commit in
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
                .font(.system(size: 11))
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(commit.shortHash).foregroundStyle(theme.accent)
                Text("·")
                Text(commit.author).lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.date)
            }
            .font(.system(size: 9))
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
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text("History")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .frame(height: 22)
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
                .font(.system(size: 10))
                .padding(.horizontal, 11)
                .frame(height: 20)
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.vcs(kind))
                    .frame(width: 11)
                Text(name)
                    .foregroundStyle(theme.vcs(kind))
                    .strikethrough(kind == .deleted)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let additions = file.additions, let deletions = file.deletions {
                    lineCounts(additions, deletions)
                } else {
                    Text("binary").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 11)
            .frame(height: 23)
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
        .font(.system(size: 10, design: .monospaced))
    }

    private func commitFileKind(_ status: Character) -> WorkspaceFileChange.Kind {
        switch status {
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        default: return .modified
        }
    }

    private func loadCommitFiles() async {
        commitFiles = nil
        commitFilesError = nil
        guard let location, let hash = selectedCommit?.id else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try WorkspaceFiles.commitFiles(hash, at: location) }
        }.value
        guard selectedCommit?.id == hash, self.location?.identity == location.identity else { return }
        switch result {
        case .success(let files): commitFiles = files
        case .failure(let failure): commitFilesError = failure.localizedDescription
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
                    Image(systemName: "plus").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Add worktree")
                .padding(.trailing, 11)
                .disabled(listing.branches.isEmpty)
            }
            ForEach(listing.worktrees) { tree in
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.branch ?? "Detached HEAD")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(tree.path)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if tree.path != listing.root && !tree.isBare && !tree.isLocked && !tree.isPrunable {
                        Button { removing = tree } label: {
                            Image(systemName: "minus.circle").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("Remove worktree")
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 35)
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
                .font(.system(size: 10))
                .foregroundStyle(branch.isCurrent ? theme.accent : Color.secondary)
                .frame(width: 15)
            Text(branch.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 11)
        .frame(height: 23)
        .contentShape(Rectangle())
        .help(branch.upstream.isEmpty ? branch.id : "Tracks \(branch.upstream)")
        .contextMenu {
            if !branch.isRemote && !branch.isCurrent {
                Button("Switch to Branch", systemImage: "arrow.triangle.swap") { switchTo(branch) }
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
        guard let branch = preferred ?? listing.branches.first(where: { !$0.isRemote && !$0.isCurrent })
            ?? listing.branches.first else { return }
        let newBranch = (branch.isCurrent || branch.isRemote)
            ? branch.name.split(separator: "/").last.map(String.init).map { $0 + "-worktree" } ?? "worktree"
            : ""
        let parent = (listing.root as NSString).deletingLastPathComponent
        let name = (listing.root as NSString).lastPathComponent
        let path = parent + "/" + name + "-" + branch.name.replacingOccurrences(of: "/", with: "-")
        addRequest = AddWorktreeRequest(branches: listing.branches, branchID: branch.id,
                                        path: path, newBranch: newBranch)
    }

    private func load() {
        guard let location else { listing = nil; error = nil; return }
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.repository(at: location) } }.value
            guard self.location?.identity == location.identity else { return }
            switch result {
            case .success(let value): listing = value
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
        }
    }

    private func add(branch: WorkspaceBranch, path: String, newBranch: String) {
        guard let location else { return }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await Task.detached {
                Result { try WorkspaceFiles.addWorktree(at: location, path: path, branch: branch,
                                                        newBranch: name.isEmpty ? nil : name) }
            }.value
            switch result {
            case .success: reloadVersion += 1
            case .failure(let failure): operationError = failure.localizedDescription
            }
        }
    }

    private func switchTo(_ branch: WorkspaceBranch) {
        guard let location else { return }
        Task {
            let result = await Task.detached {
                Result { try WorkspaceFiles.switchBranch(branch, at: location) }
            }.value
            switch result {
            case .success:
                reloadVersion += 1
                onChange()
            case .failure(let failure): operationError = failure.localizedDescription
            }
        }
    }

    private func remove(_ tree: WorkspaceWorktree) {
        guard let location else { return }
        removing = nil
        Task {
            let result = await Task.detached {
                Result { try WorkspaceFiles.removeWorktree(at: location, path: tree.path) }
            }.value
            switch result {
            case .success: reloadVersion += 1
            case .failure(let failure): operationError = failure.localizedDescription
            }
        }
    }
}

private struct AddWorktreeRequest: Identifiable {
    let id = UUID()
    let branches: [WorkspaceBranch]
    let branchID: String
    let path: String
    let newBranch: String
}

private struct AddWorktreeSheet: View {
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

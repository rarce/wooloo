import SwiftUI

struct WorkspaceBrowserView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    let localSnapshot: HerdrSnapshot?
    let localWorkspaceID: String?
    let localSession: String
    /// The SSH machine chosen in the session picker; nil browses this Mac.
    let machine: HerdrMachineProfile?
    let refreshVersion: Int
    let onOpenFile: (WorkspaceFileLocation, String) -> Void
    let onOpenDiff: (WorkspaceFileLocation, String) -> Void
    let onNewTab: (String) -> Void
    let onNewSpace: (String, String) -> Void
    let onLocationChange: (WorkspaceFileLocation?) -> Void
    let onFindInFolder: (WorkspaceFileLocation, String) -> Void
    let onOpenWorktree: (String, String) -> Void
    let onOpenCommitFile: (WorkspaceFileLocation, WorkspaceCommit, WorkspaceCommitFile) -> Void

    @State private var remoteSnapshot: HerdrSnapshot?
    @State private var remoteWorkspaceID: String?
    @State private var listing: WorkspaceFileListing?
    @State private var error: String?
    @State private var isLoading = false
    @State private var showsChanges = false
    @State private var modifiedOnly = false
    @State private var expandedDirectories: Set<String> = []
    @State private var collapsedRoots: Set<String> = []
    @State private var selectedItem: String?
    @State private var operationError: String?
    @State private var clipboard: WorkspaceFileClipboard?
    @State private var renamePrompt: WorkspaceRenamePrompt?
    /// A file or folder being named in place in the tree, before it is created.
    @State private var draft: WorkspaceFileDraft?
    @State private var draftName = ""
    @FocusState private var draftFocused: Bool
    @State private var nameInput = ""
    @State private var pendingDelete: WorkspaceFileTarget?
    /// Folders created in the explorer, by location, shown while they hold no listed file.
    @State private var createdDirectories: [String: Set<String>] = [:]
    /// Bumped on every listing load so the Git bar refreshes with the explorer.
    @State private var listingVersion = 0
    /// Bumped by Git bar operations so the repository panel refreshes too.
    @State private var gitVersion = 0
    @AppStorage("RepositoryCollapsed") private var repositoryCollapsed = false

    private var isFilteredFiles: Bool { !showsChanges && modifiedOnly }

    private var snapshot: HerdrSnapshot? {
        machine == nil ? localSnapshot : remoteSnapshot
    }

    private var workspaceID: String? {
        machine == nil ? localWorkspaceID : remoteWorkspaceID
    }

    private var location: WorkspaceFileLocation? {
        guard let snapshot, let workspaceID else { return nil }
        return WorkspaceFiles.location(snapshot: snapshot, workspaceID: workspaceID,
                                       session: machine?.session ?? localSession, machine: machine)
    }

    private var listingIdentity: String {
        (location?.identity ?? "none|\(machine?.id ?? "local")|\(workspaceID ?? "")") + "|\(refreshVersion)"
    }

    var body: some View {
        Group {
            // A collapsed repository keeps only its header, so the explorer takes the rest without a divider to drag.
            if repositoryCollapsed {
                VStack(spacing: 0) {
                    explorer.frame(maxHeight: .infinity)
                    Divider()
                    repository
                }
            } else {
                VSplitView {
                    explorer
                        .frame(minHeight: 190)
                    repository
                        .frame(minHeight: 160)
                }
            }
        }
        .background(theme.sidebarBackground)
        .task(id: machine) { machineChanged() }
        .task(id: listingIdentity) { loadListing() }
        .task(id: location?.identity) { onLocationChange(location) }
        .alert("Operation failed", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    private var repository: some View {
        WorkspaceRepositoryView(location: location, refreshVersion: refreshVersion + gitVersion,
                                isCollapsed: $repositoryCollapsed,
                                onChange: { loadListing() },
                                onNewSpace: location?.isLocal == true ? onNewSpace : nil,
                                onOpenCommitFile: onOpenCommitFile)
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPLORER")
                    .font(.system(size: typography.secondary, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                machineIcon
                Spacer()
                if !showsChanges {
                    // A plain button, because a borderless Menu ignores its label's color and weight.
                    Button { modifiedOnly.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: modifiedOnly ? "line.3.horizontal.decrease.circle.fill"
                                                           : "line.3.horizontal.decrease.circle")
                            if modifiedOnly { Text("Modified") }
                        }
                        .font(.system(size: typography.secondary, weight: modifiedOnly ? .semibold : .regular))
                        .foregroundStyle(modifiedOnly ? theme.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(modifiedOnly ? "Showing modified files; click to show all" : "Show modified files only")
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: typography.secondary))
                }
                .buttonStyle(.plain)
                .help("Refresh files and changes")
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(35))
            Divider()

            if let snapshot, machine != nil {
                Menu {
                    ForEach(snapshot.workspaces) { workspace in
                        Button(workspace.label) { remoteWorkspaceID = workspace.workspaceID }
                    }
                } label: {
                    Label(snapshot.workspaces.first(where: { $0.workspaceID == remoteWorkspaceID })?.label ?? "Choose Space",
                          systemImage: "square.stack")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 9)
                .frame(height: typography.metric(26))
            }

            HStack(spacing: 0) {
                segment("Files", icon: "doc.text", selected: !showsChanges) { showsChanges = false }
                segment("Changes", icon: "arrow.left.arrow.right", selected: showsChanges) { showsChanges = true }
            }
            .padding(.horizontal, 3)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: typography.body))
                    .foregroundStyle(theme.warning)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let listing, let location {
                let changedPaths = Set(listing.changes.map(\.path))
                let paths = showsChanges ? listing.changes.map(\.path)
                    : (modifiedOnly ? listing.files.filter { changedPaths.contains($0) } : listing.files)
                let changesByPath = Dictionary(listing.changes.map { ($0.path, $0) },
                                               uniquingKeysWith: { first, _ in first })
                let directoryKinds = directoryKinds(listing.changes)
                let stageStates = showsChanges ? stageStates(listing.changes) : [:]
                let rows = WorkspaceTreeNode.visibleRows(
                    paths: paths,
                    directories: showsChanges || modifiedOnly ? [] : createdDirectories[location.identity] ?? [],
                    expanded: expandedDirectories,
                    identity: treeIdentity(location)
                )
                let draftFolder = !showsChanges && draft?.location.identity == location.identity ? draft?.folder : nil
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            treeRoot(location, stageState: listing.hasGit ? stageStates[""] : nil)
                            if !collapsedRoots.contains(treeIdentity(location)) {
                                if draftFolder == "" { draftRow(depth: 1) }
                                if (showsChanges || isFilteredFiles) && !listing.hasGit {
                                    hint("No Git repository in this Space")
                                } else if paths.isEmpty {
                                    hint(showsChanges ? "No changes" : (modifiedOnly ? "No modified files" : "No files"))
                                }
                                if !showsChanges && listing.totalFiles > listing.files.count {
                                    hint("Showing \(listing.files.count) of \(listing.totalFiles) files; tracked files come first")
                                }
                                ForEach(rows) { row in
                                    treeRow(row, location: location,
                                            change: changesByPath[row.node.path],
                                            directoryKind: directoryKinds[row.node.path],
                                            stageState: listing.hasGit ? stageStates[row.node.path] : nil,
                                            hasGit: listing.hasGit)
                                    if row.node.isDirectory, draftFolder == row.node.path { draftRow(depth: row.depth + 1) }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                        // The space under the last row opens the Space's menu too.
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .contextMenu { rootMenu(location) }
                        }
                    }
                }
                .id(treeIdentity(location))
            } else {
                hint("Select a Space to browse")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let location, listing?.hasGit == true {
                Divider()
                WorkspaceGitBar(location: location, reloadToken: listingVersion,
                                changes: showsChanges ? listing?.changes ?? [] : nil,
                                onChange: {
                                    gitVersion += 1
                                    loadListing(quietly: true)
                                },
                                onOpenWorktree: location.isLocal ? onOpenWorktree : nil,
                                onError: { operationError = $0 })
            }
        }
        .background(theme.sidebarBackground)
        .alert(renamePrompt?.title ?? "", isPresented: Binding(
            get: { renamePrompt != nil }, set: { if !$0 { renamePrompt = nil } }
        ), presenting: renamePrompt) { prompt in
            TextField("Name", text: $nameInput)
            Button("Rename") { submitRename(prompt) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .confirmationDialog(pendingDelete.map { "Delete “\(($0.path as NSString).lastPathComponent)”?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { target in
            Button("Delete", role: .destructive) { delete(target) }
        } message: { target in
            Text(target.isDirectory ? "The folder and everything in it are deleted permanently."
                                    : "The file is deleted permanently.")
        }
    }

    private func segment(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: typography.secondary, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: typography.metric(25))
                .background(selected ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                // Keep the spacing inside the hit area so the whole strip is clickable.
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ value: String) -> some View {
        Text(value)
            .font(.system(size: typography.body))
            .foregroundStyle(.tertiary)
            .padding(10)
    }

    /// The modified-only filter shares the file tree's expanded folders, so switching keeps the layout.
    private func treeIdentity(_ location: WorkspaceFileLocation) -> String {
        "\(location.identity)|\(showsChanges ? "changes" : "files")"
    }

    private func treeRoot(_ location: WorkspaceFileLocation,
                          stageState: WorkspaceFileChange.StageState?) -> some View {
        let identity = treeIdentity(location)
        let isExpanded = !collapsedRoots.contains(identity)
        return Button {
            if isExpanded { collapsedRoots.insert(identity) }
            else { collapsedRoots.remove(identity) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text((location.root as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: typography.body))
            .padding(.leading, 11)
            .padding(.trailing, stageState == nil ? 8 : 30)
            .frame(height: typography.metric(24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if let stageState { stageToggle(stageState, path: "", location: location) }
        }
        .help(location.root)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .contextMenu { rootMenu(location) }
    }

    @ViewBuilder
    private func rootMenu(_ location: WorkspaceFileLocation) -> some View {
        if !showsChanges {
            Button("New File…", systemImage: "doc.badge.plus") { startDraft(in: "", isFolder: false, at: location) }
            Button("New Folder…", systemImage: "folder.badge.plus") { startDraft(in: "", isFolder: true, at: location) }
            Button("Paste", systemImage: "doc.on.clipboard") { paste(into: "", in: location) }
            Divider()
        }
        if location.isLocal {
            Button("Open in New Tab", systemImage: "terminal") { onNewTab(location.root) }
        }
        Button("Find in Space…", systemImage: "magnifyingglass") { onFindInFolder(location, "") }
        Button("Collapse All Folders", systemImage: "rectangle.compress.vertical") { collapseAll(location) }
        Divider()
        if !showsChanges {
            Button(modifiedOnly ? "Show All Files" : "Show Modified Only",
                   systemImage: "line.3.horizontal.decrease") { modifiedOnly.toggle() }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
        Divider()
        pathActions(location, path: "")
    }

    /// The name field of a file or folder being created, indented as its first child.
    private func draftRow(depth: Int) -> some View {
        let isFolder = draft?.isFolder == true
        return HStack(spacing: 6) {
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: typography.body))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            TextField(isFolder ? "Folder name" : "File name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: typography.body))
                .focused($draftFocused)
                .onSubmit { commitDraft() }
                .onExitCommand { endDraft() }
                .padding(.horizontal, 4)
                .frame(height: typography.metric(20))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent, lineWidth: 1))
        }
        .padding(.leading, CGFloat(depth) * 19 + 11)
        .padding(.trailing, 8)
        .frame(height: typography.metric(23))
        .onAppear { DispatchQueue.main.async { draftFocused = true } }
        // Clicking elsewhere creates what was typed, as in Zed; an empty name is dropped. Focus
        // lost before the field ever had it is the previous field's, arriving late, and is ignored.
        .onChange(of: draftFocused) { _, focused in
            if focused { draft?.hasHadFocus = true }
            else if draft?.hasHadFocus == true { commitDraft() }
        }
    }

    private func treeRow(_ row: WorkspaceTreeRow, location: WorkspaceFileLocation,
                         change: WorkspaceFileChange?,
                         directoryKind: WorkspaceFileChange.Kind?,
                         stageState: WorkspaceFileChange.StageState?, hasGit: Bool) -> some View {
        let node = row.node
        let kind = node.isDirectory ? directoryKind : change?.kind
        let identity = treeIdentity(location) + "|" + node.path
        let isExpanded = expandedDirectories.contains(identity)
        let isSelected = selectedItem == identity
        return Button {
            if node.isDirectory {
                toggleDirectory(identity, isExpanded: isExpanded)
            } else {
                selectedItem = identity
                if showsChanges { onOpenDiff(location, node.path) }
                else { onOpenFile(location, node.path) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory
                      ? (isExpanded ? "folder.fill" : "folder")
                      : (showsChanges ? "arrow.left.arrow.right" : fileIcon(node.path)))
                    .font(.system(size: typography.body))
                    .frame(width: 17)
                    .foregroundStyle(node.isDirectory ? Color.secondary : (showsChanges ? theme.accent : .secondary))
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(!node.isDirectory && kind == .deleted)
                    .foregroundStyle(kind.map(statusColor) ?? Color.primary)
                Spacer(minLength: 0)
                if let change, !node.isDirectory {
                    Text(change.statusLabel)
                        .font(.system(size: typography.caption, weight: .semibold))
                        .foregroundStyle(statusColor(change.kind))
                } else if let kind {
                    Circle()
                        .fill(statusColor(kind).opacity(0.8))
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 2)
                }
            }
            .font(.system(size: typography.body))
            .padding(.leading, CGFloat(row.depth) * 19 + 11)
            .padding(.trailing, stageState == nil ? 8 : 30)
            .frame(height: typography.metric(23))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                ForEach(0..<row.depth, id: \.self) { level in
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, CGFloat(level) * 19 + 29)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if let stageState { stageToggle(stageState, path: node.path, location: location) }
        }
        .help(node.path)
        .accessibilityValue(node.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "File")
        .contextMenu {
            if node.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    toggleDirectory(identity, isExpanded: isExpanded)
                }
                Button("Find in Folder…", systemImage: "magnifyingglass") { onFindInFolder(location, node.path) }
                if showsChanges && location.isLocal {
                    Button("Open in New Tab", systemImage: "terminal") {
                        onNewTab(location.absolutePath(node.path))
                    }
                }
            } else {
                Button("Open", systemImage: "doc.text") {
                    selectedItem = identity
                    onOpenFile(location, node.path)
                }
                .disabled(change?.kind == .deleted)
                if change != nil {
                    Button("Open Changes", systemImage: "arrow.left.arrow.right") {
                        selectedItem = identity
                        onOpenDiff(location, node.path)
                    }
                }
            }
            Divider()
            if !showsChanges { fileActions(location, node: node) }
            if hasGit {
                if let kind {
                    if node.isDirectory || change?.worktreeStatus != " " {
                        Button(node.isDirectory ? "Stage Folder" : "Stage Changes", systemImage: "plus.circle") {
                            runOperation(location) { try WorkspaceFiles.stage(node.path, at: location) }
                        }
                    }
                    if node.isDirectory ? kind != .untracked
                        : (change?.indexStatus != " " && change?.indexStatus != "?") {
                        Button(node.isDirectory ? "Unstage Folder" : "Unstage Changes", systemImage: "minus.circle") {
                            runOperation(location) { try WorkspaceFiles.unstage(node.path, at: location) }
                        }
                    }
                }
                if !showsChanges { gitFileActions(location, node: node, change: change) }
                Divider()
            }
            if showsChanges {
                pathActions(location, path: node.path)
            } else {
                Button("Rename…", systemImage: "pencil") {
                    nameInput = (node.path as NSString).lastPathComponent
                    renamePrompt = WorkspaceRenamePrompt(location: location, path: node.path, isDirectory: node.isDirectory)
                }
                if location.isLocal {
                    Button("Move to Trash", systemImage: "trash") { trash(node.path, in: location) }
                }
                Button("Delete…", systemImage: "xmark.bin", role: .destructive) {
                    pendingDelete = WorkspaceFileTarget(location: location, path: node.path, isDirectory: node.isDirectory)
                }
            }
        }
    }

    /// Creating, opening, copying and pasting around a row of the Files tree, in Zed's order.
    @ViewBuilder
    private func fileActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode) -> some View {
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        Button("New File…", systemImage: "doc.badge.plus") { startDraft(in: folder, isFolder: false, at: location) }
        Button("New Folder…", systemImage: "folder.badge.plus") { startDraft(in: folder, isFolder: true, at: location) }
        Divider()
        if location.isLocal {
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.absolutePath(node.path)) }
            Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: location.absolutePath(node.path)))
            }
            Button("Open in New Tab", systemImage: "terminal") { onNewTab(location.absolutePath(folder)) }
            Divider()
        }
        Button("Cut", systemImage: "scissors") { copyItem(node.path, in: location, cut: true) }
        Button("Copy", systemImage: "doc.on.doc") { copyItem(node.path, in: location, cut: false) }
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(node.path, in: location) }
        Button("Paste", systemImage: "doc.on.clipboard") { paste(into: folder, in: location) }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.absolutePath(node.path)) }
        Button("Copy Relative Path") { AppActions.copy(node.path) }
        Divider()
    }

    /// Ignore rules and hosting-site links for a row of the Files tree in a Git repository.
    @ViewBuilder
    private func gitFileActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode,
                                change: WorkspaceFileChange?) -> some View {
        Button("Add to .gitignore", systemImage: "eye.slash") {
            runOperation(location) {
                try WorkspaceFiles.ignore(node.path, isDirectory: node.isDirectory, inExclude: false, at: location)
            }
        }
        Button("Add to .git/info/exclude") {
            runOperation(location) {
                try WorkspaceFiles.ignore(node.path, isDirectory: node.isDirectory, inExclude: true, at: location)
            }
        }
        // A permalink points at a commit, so only files it contains have one.
        if !node.isDirectory, change?.kind != .untracked, change?.kind != .added {
            Button("Open File Permalink", systemImage: "link") {
                runOperation(location, reloads: false, { try WorkspaceFiles.permalink(node.path, at: location) }) {
                    NSWorkspace.shared.open($0)
                }
            }
            Button("Copy File Permalink") {
                runOperation(location, reloads: false, { try WorkspaceFiles.permalink(node.path, at: location) }) {
                    AppActions.copy($0.absoluteString)
                }
            }
        }
    }

    @ViewBuilder
    private func pathActions(_ location: WorkspaceFileLocation, path: String) -> some View {
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.absolutePath(path)) }
        if !path.isEmpty {
            Button("Copy Relative Path") { AppActions.copy(path) }
        }
        if location.isLocal {
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.absolutePath(path)) }
        }
    }

    private func toggleDirectory(_ identity: String, isExpanded: Bool) {
        if isExpanded {
            expandedDirectories.remove(identity)
        } else {
            expandedDirectories.insert(identity)
        }
    }

    private func collapseAll(_ location: WorkspaceFileLocation) {
        let prefix = treeIdentity(location) + "|"
        expandedDirectories = expandedDirectories.filter { !$0.hasPrefix(prefix) }
    }

    /// A checkbox that stages the file or everything under the folder, or unstages it when all of it is staged.
    private func stageToggle(_ state: WorkspaceFileChange.StageState, path: String,
                             location: WorkspaceFileLocation) -> some View {
        let name = path.isEmpty ? "all changes" : (path as NSString).lastPathComponent
        return Button {
            runOperation(location) {
                if state == .all { try WorkspaceFiles.unstage(path, at: location) }
                else { try WorkspaceFiles.stage(path, at: location) }
            }
        } label: {
            Image(systemName: state == .all ? "checkmark.square.fill"
                  : (state == .partial ? "minus.square.fill" : "square"))
                .font(.system(size: typography.body))
                .foregroundStyle(state == .none ? Color.secondary : theme.accent)
                .frame(width: 22, height: typography.metric(23))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
        .help(state == .all ? "Unstage \(name)" : "Stage \(name)")
    }

    /// Stage state of every changed file, of each folder above one, and of the root under "".
    private func stageStates(_ changes: [WorkspaceFileChange]) -> [String: WorkspaceFileChange.StageState] {
        var states: [String: WorkspaceFileChange.StageState] = [:]
        for change in changes {
            let state = change.stageState
            states[change.path] = state
            var directory = (change.path as NSString).deletingLastPathComponent
            while true {
                states[directory] = states[directory].map { $0.merged(with: state) } ?? state
                if directory.isEmpty { break }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return states
    }

    /// Runs a Git or file operation off the main thread, then reloads the listing unless told not to.
    private func runOperation<Value>(_ location: WorkspaceFileLocation, reloads: Bool = true,
                                     _ operation: @escaping () throws -> Value,
                                     completion: @escaping (Value) -> Void = { _ in }) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            switch result {
            case .success(let value): completion(value)
            case .failure(let failure): operationError = failure.localizedDescription
            }
            // Reload in place, so staging does not blank the tree behind a spinner.
            if reloads, self.location?.identity == location.identity { loadListing(quietly: true) }
        }
    }

    // MARK: File operations

    /// Shows a name field in the tree, under `folder` ("" is the Space root), for a new item.
    private func startDraft(in folder: String, isFolder: Bool, at location: WorkspaceFileLocation) {
        let identity = treeIdentity(location)
        collapsedRoots.remove(identity)
        var parent = folder
        while !parent.isEmpty {
            expandedDirectories.insert(identity + "|" + parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        draftName = ""
        draft = WorkspaceFileDraft(location: location, folder: folder, isFolder: isFolder)
    }

    /// Removes the name field, dropping its focus first so a later field does not inherit it.
    private func endDraft() {
        draftFocused = false
        draft = nil
    }

    private func commitDraft() {
        guard let draft else { return }
        endDraft()
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let location = draft.location
        let path = draft.folder.isEmpty ? name : draft.folder + "/" + name
        runOperation(location) {
            if draft.isFolder { try WorkspaceFiles.createFolder(path, at: location) }
            else { try WorkspaceFiles.createFile(path, at: location) }
        } completion: {
            if draft.isFolder { createdDirectories[location.identity, default: []].insert(path) }
            reveal(path, in: location)
            if !draft.isFolder { onOpenFile(location, path) }
        }
    }

    private func submitRename(_ prompt: WorkspaceRenamePrompt) {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let location = prompt.location
        let original = prompt.path
        runOperation(location) { try WorkspaceFiles.renameItem(original, to: name, at: location) } completion: {
            movePathState(from: original, to: $0, in: location)
        }
    }

    private func copyItem(_ path: String, in location: WorkspaceFileLocation, cut: Bool) {
        let absolute = location.absolutePath(path)
        var changeCount = 0
        // Local items also go on the general pasteboard, so Finder can paste them.
        if location.isLocal {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: absolute) as NSURL])
            changeCount = pasteboard.changeCount
        }
        clipboard = WorkspaceFileClipboard(machineID: location.machine?.id, paths: [absolute],
                                           isCut: cut, changeCount: changeCount)
    }

    /// Pastes what the explorer copied or cut on this machine, or, in a local Space, files
    /// copied in Finder since then.
    private func paste(into directory: String, in location: WorkspaceFileLocation) {
        let pasteboard = NSPasteboard.general
        var sources: [String] = []
        var move = false
        if let clipboard, clipboard.machineID == location.machine?.id,
           !location.isLocal || clipboard.changeCount == pasteboard.changeCount {
            sources = clipboard.paths
            move = clipboard.isCut
        } else if location.isLocal,
                  let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            sources = urls.map(\.path)
        }
        guard !sources.isEmpty else {
            operationError = "Nothing to paste. Copy or cut a file on \(location.machineLabel) first."
            return
        }
        runOperation(location) { try WorkspaceFiles.paste(sources, into: directory, move: move, at: location) } completion: {
            if move { clipboard = nil }
            placePasted($0, in: location)
        }
    }

    private func duplicate(_ path: String, in location: WorkspaceFileLocation) {
        let source = location.absolutePath(path)
        let folder = (path as NSString).deletingLastPathComponent
        runOperation(location) { try WorkspaceFiles.paste([source], into: folder, move: false, at: location) } completion: {
            placePasted($0, in: location)
        }
    }

    /// Keeps pasted empty folders visible and selects the last pasted item.
    private func placePasted(_ paths: [String], in location: WorkspaceFileLocation) {
        if location.isLocal {
            var isDirectory: ObjCBool = false
            for path in paths where FileManager.default.fileExists(atPath: location.absolutePath(path),
                                                                   isDirectory: &isDirectory) && isDirectory.boolValue {
                createdDirectories[location.identity, default: []].insert(path)
            }
        }
        if let last = paths.last { reveal(last, in: location) }
    }

    private func trash(_ path: String, in location: WorkspaceFileLocation) {
        runOperation(location) { try WorkspaceFiles.trash(path, at: location) } completion: {
            forgetPathState(path, in: location)
        }
    }

    private func delete(_ target: WorkspaceFileTarget) {
        let location = target.location
        runOperation(location) { try WorkspaceFiles.delete(target.path, at: location) } completion: {
            forgetPathState(target.path, in: location)
        }
    }

    /// Expands the folders above `path` and selects it.
    private func reveal(_ path: String, in location: WorkspaceFileLocation) {
        let identity = treeIdentity(location)
        collapsedRoots.remove(identity)
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            expandedDirectories.insert(identity + "|" + parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        selectedItem = identity + "|" + path
    }

    /// Carries expanded folders, the selection and created folders over to a renamed item.
    private func movePathState(from original: String, to renamed: String, in location: WorkspaceFileLocation) {
        let identity = treeIdentity(location) + "|"
        func moved(_ key: String, prefix: String) -> String? {
            guard key.hasPrefix(prefix) else { return nil }
            let rest = key.dropFirst(prefix.count)
            if rest == original { return prefix + renamed }
            if rest.hasPrefix(original + "/") { return prefix + renamed + rest.dropFirst(original.count) }
            return nil
        }
        expandedDirectories = Set(expandedDirectories.map { moved($0, prefix: identity) ?? $0 })
        if let selectedItem { self.selectedItem = moved(selectedItem, prefix: identity) ?? selectedItem }
        if let created = createdDirectories[location.identity] {
            createdDirectories[location.identity] = Set(created.map { moved($0, prefix: "") ?? $0 })
        }
    }

    private func forgetPathState(_ path: String, in location: WorkspaceFileLocation) {
        createdDirectories[location.identity]?.remove(path)
        createdDirectories[location.identity] = createdDirectories[location.identity]?.filter { !$0.hasPrefix(path + "/") }
    }

    private func statusColor(_ kind: WorkspaceFileChange.Kind) -> Color {
        theme.vcs(kind)
    }

    /// Strongest change kind under each directory, keyed by directory path.
    private func directoryKinds(_ changes: [WorkspaceFileChange]) -> [String: WorkspaceFileChange.Kind] {
        var kinds: [String: WorkspaceFileChange.Kind] = [:]
        for change in changes {
            var directory = (change.path as NSString).deletingLastPathComponent
            while !directory.isEmpty {
                if let existing = kinds[directory], existing.rawValue >= change.kind.rawValue { break }
                kinds[directory] = change.kind
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return kinds
    }

    private func fileIcon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc.text"
        }
    }

    /// Shows whether the explorer browses this Mac or an SSH machine.
    private var machineIcon: some View {
        Image(systemName: machine == nil ? "desktopcomputer" : "network")
            .font(.system(size: typography.secondary))
            .foregroundStyle(machine == nil ? Color.secondary : theme.accent)
            .help(machine.map { "SSH · \($0.label)" } ?? "Local")
    }

    private func machineChanged() {
        remoteSnapshot = nil
        remoteWorkspaceID = nil
        listing = nil
        error = nil
        if let machine { loadRemote(machine) }
    }

    private func refresh() {
        WorkspaceFiles.forgetRecentResults()
        if let machine { loadRemote(machine) }
        else { loadListing() }
    }

    private func loadRemote(_ profile: HerdrMachineProfile) {
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.remoteSnapshot(profile) } }.value
            guard machine?.id == profile.id else { return }
            switch result {
            case .success(let snapshot):
                remoteSnapshot = snapshot
                remoteWorkspaceID = snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
            case .failure(let failure):
                error = failure.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadListing(quietly: Bool = false) {
        guard let location else { listing = nil; return }
        isLoading = !quietly
        error = nil
        let start = TerminalPipelineMetrics.now()
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.listing(at: location) } }.value
            guard self.location?.identity == location.identity else { return }
            switch result {
            case .success(let value):
                listing = value
                if location.isLocal, let created = createdDirectories[location.identity] {
                    createdDirectories[location.identity] = created.filter { path in
                        var isDirectory: ObjCBool = false
                        return FileManager.default.fileExists(atPath: location.absolutePath(path), isDirectory: &isDirectory)
                            && isDirectory.boolValue
                    }
                }
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
            listingVersion += 1
            TerminalPipelineMetrics.spanShown("file-list", start: start, detail: location.isLocal ? "local" : "ssh")
        }
    }
}

struct WorkspaceTreeNode {
    let displayName: String
    let path: String
    let isDirectory: Bool
    let children: [WorkspaceTreeNode]

    /// `directories` adds folders that hold no listed file, such as one just created in the explorer.
    static func visibleRows(paths: [String], directories: Set<String> = [], expanded: Set<String>,
                            identity: String) -> [WorkspaceTreeRow] {
        let root = WorkspaceTreeBuilderNode(name: "", path: "")
        func insert(_ path: String, isDirectory: Bool) {
            let components = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !components.isEmpty,
                  !components.contains("."), !components.contains("..") else { return }
            var current = root
            for component in components {
                if let existing = current.children[component] {
                    current = existing
                } else {
                    let childPath = current.path.isEmpty ? component : current.path + "/" + component
                    let child = WorkspaceTreeBuilderNode(name: component, path: childPath)
                    current.children[component] = child
                    current = child
                }
            }
            if isDirectory { current.isDirectory = true }
        }
        for path in paths { insert(path, isDirectory: false) }
        for path in directories { insert(path, isDirectory: true) }

        var rows: [WorkspaceTreeRow] = []
        func append(_ nodes: [WorkspaceTreeNode], depth: Int) {
            for node in nodes {
                rows.append(WorkspaceTreeRow(node: node, depth: depth))
                let key = identity + "|" + node.path
                if node.isDirectory && expanded.contains(key) {
                    append(node.children, depth: depth + 1)
                }
            }
        }
        append(root.children.values.map(compact).sorted(by: ordered), depth: 1)
        return rows
    }

    private static func compact(_ source: WorkspaceTreeBuilderNode) -> WorkspaceTreeNode {
        var node = source
        var names = [node.name]
        while node.children.count == 1,
              let child = node.children.values.first,
              !child.children.isEmpty {
            node = child
            names.append(node.name)
        }
        let children = node.children.values.map(compact).sorted(by: ordered)
        return WorkspaceTreeNode(displayName: names.joined(separator: " / "), path: node.path,
                                 isDirectory: node.isDirectory || !children.isEmpty, children: children)
    }

    private static func ordered(_ lhs: WorkspaceTreeNode, _ rhs: WorkspaceTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

struct WorkspaceTreeRow: Identifiable {
    let node: WorkspaceTreeNode
    let depth: Int
    var id: String { node.path }
}

final class WorkspaceTreeBuilderNode {
    let name: String
    let path: String
    var children: [String: WorkspaceTreeBuilderNode] = [:]
    var isDirectory = false

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Files and folders copied or cut in the explorer, waiting to be pasted.
private struct WorkspaceFileClipboard {
    /// nil for this Mac.
    let machineID: String?
    let paths: [String]
    let isCut: Bool
    /// The general pasteboard's change count after a local copy; copying anything else later replaces this.
    let changeCount: Int
}

private struct WorkspaceFileTarget {
    let location: WorkspaceFileLocation
    let path: String
    let isDirectory: Bool
}

/// A file or folder being named in the tree before it exists.
private struct WorkspaceFileDraft {
    let location: WorkspaceFileLocation
    /// The folder it is created in; "" is the Space root.
    let folder: String
    let isFolder: Bool
    var hasHadFocus = false
}

private struct WorkspaceRenamePrompt {
    let location: WorkspaceFileLocation
    let path: String
    let isDirectory: Bool

    var title: String { isDirectory ? "Rename Folder" : "Rename File" }
    var message: String { "Enter a new name for “\((path as NSString).lastPathComponent)”." }
}

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
    /// Opens a file or its changes; `preview` opens it in the preview tab, replaced by the next preview.
    let onOpenFile: (_ location: WorkspaceFileLocation, _ path: String, _ preview: Bool) -> Void
    let onOpenDiff: (_ location: WorkspaceFileLocation, _ path: String, _ preview: Bool) -> Void
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
    @State private var tree = WorkspaceExplorerTree()
    @State private var treeCache = WorkspaceTreeCache()
    @State private var operationError: String?
    @State private var clipboard: WorkspaceFileClipboard?
    /// A file or folder being named in place in the tree, before it is created.
    @State private var draft: WorkspaceFileDraft?
    @State private var draftName = ""
    @FocusState private var draftFocused: Bool
    /// Whether the Files tree has keyboard focus, so file shortcuts apply to its selection.
    @FocusState private var treeFocused: Bool
    @State private var keyMonitor: Any?
    @State private var windowBox = WindowBox()
    @State private var pendingDelete: WorkspaceFileTarget?
    /// Bumped on every listing load so the Git bar refreshes with the explorer.
    @State private var listingVersion = 0
    /// What was read of expanded ignored folders, by folder path, for the current listing.
    @State private var ignoredContents: [String: WorkspaceFolderContents] = [:]
    /// Bumped when `ignoredContents` changes, so the Files tree is rebuilt.
    @State private var ignoredContentsVersion = 0
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
        .background(WindowReader(box: windowBox))
        .task(id: machine) { machineChanged() }
        .onAppear {
            keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleFileShortcut(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
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
                let shownTree = shownTree(listing, location: location)
                let changesByPath = Dictionary(listing.changes.map { ($0.path, $0) },
                                               uniquingKeysWith: { first, _ in first })
                let directoryKinds = WorkspaceExplorer.directoryKinds(listing.changes)
                let stageStates = showsChanges ? WorkspaceExplorer.stageStates(listing.changes) : [:]
                let rows = shownTree.visibleRows(expanded: tree.expanded, identity: treeIdentity(location))
                let shownDraft = !showsChanges && draft?.location.identity == location.identity ? draft : nil
                let draftFolder = shownDraft?.renaming == nil ? shownDraft?.folder : nil
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            treeRoot(location, stageState: listing.hasGit ? stageStates[""] : nil)
                            if !tree.collapsedRoots.contains(treeIdentity(location)) {
                                if draftFolder == "" { draftRow(depth: 1) }
                                if (showsChanges || isFilteredFiles) && !listing.hasGit {
                                    hint("No Git repository in this Space")
                                } else if shownTree.isEmpty {
                                    hint(showsChanges ? "No changes" : (modifiedOnly ? "No modified files" : "No files"))
                                }
                                if !showsChanges && listing.totalFiles > listing.files.count {
                                    hint("Showing \(listing.files.count) of \(listing.totalFiles) files; tracked files come first")
                                }
                                ForEach(rows) { row in
                                    if shownDraft?.renaming == row.node.path {
                                        draftRow(depth: row.depth)
                                    } else {
                                        treeRow(row, location: location,
                                                change: changesByPath[row.node.path],
                                                directoryKind: directoryKinds[row.node.path],
                                                stageState: listing.hasGit ? stageStates[row.node.path] : nil,
                                                hasGit: listing.hasGit)
                                    }
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
                                .onTapGesture {
                                    tree.selected = nil
                                    treeFocused = true
                                }
                                .contextMenu { rootMenu(location) }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($treeFocused)
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

    /// The tree the explorer shows: every file, the modified ones, or the changes.
    private func shownTree(_ listing: WorkspaceFileListing, location: WorkspaceFileLocation) -> WorkspaceTree {
        if showsChanges {
            return treeCache.tree(.changes, listing: listingVersion) { WorkspaceTree(paths: listing.changes.map(\.path)) }
        }
        if modifiedOnly {
            return treeCache.tree(.modified, listing: listingVersion) {
                let changed = Set(listing.changes.map(\.path))
                return WorkspaceTree(paths: listing.files.filter { changed.contains($0) })
            }
        }
        return filesTree(listing, location: location)
    }

    /// Every listed file with the folders created empty. `loadListing` builds it with the listing,
    /// so it is built here only after a folder is created, renamed or deleted.
    private func filesTree(_ listing: WorkspaceFileListing, location: WorkspaceFileLocation) -> WorkspaceTree {
        let created = tree.createdDirectories[location.identity] ?? []
        return treeCache.tree(.files, listing: listingVersion, contents: ignoredContentsVersion, directories: created) {
            let entries = WorkspaceExplorer.filesTreeEntries(listing, ignoredContents: ignoredContents, created: created)
            return WorkspaceTree(paths: entries.paths, directories: entries.directories)
        }
    }

    private func treeRoot(_ location: WorkspaceFileLocation,
                          stageState: WorkspaceFileChange.StageState?) -> some View {
        let identity = treeIdentity(location)
        let isExpanded = !tree.collapsedRoots.contains(identity)
        return Button {
            if isExpanded { tree.collapsedRoots.insert(identity) }
            else { tree.collapsedRoots.remove(identity) }
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
                .keyboardShortcut(ExplorerFileCommand.newFile.shortcut)
            Button("New Folder…", systemImage: "folder.badge.plus") { startDraft(in: "", isFolder: true, at: location) }
                .keyboardShortcut(ExplorerFileCommand.newFolder.shortcut)
            Button("Paste", systemImage: "doc.on.clipboard") { paste(into: "", in: location) }
                .keyboardShortcut(ExplorerFileCommand.paste.shortcut)
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

    /// The name field of a file or folder being created, indented as its first child, or of
    /// one being renamed, in place of its row.
    private func draftRow(depth: Int) -> some View {
        let isFolder = draft?.isFolder == true
        return HStack(spacing: 6) {
            Image(systemName: isFolder ? "folder" : draft?.renaming.map(WorkspaceExplorer.fileIcon) ?? "doc.text")
                .font(.system(size: typography.body))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            TextField(isFolder ? "Folder name" : "File name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: typography.body))
                .focused($draftFocused)
                .onSubmit {
                    commitDraft()
                    treeFocused = true
                }
                .onExitCommand {
                    endDraft()
                    treeFocused = true
                }
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
            if focused {
                if draft?.hasHadFocus == false, draft?.renaming != nil { selectNameStem() }
                draft?.hasHadFocus = true
            } else if draft?.hasHadFocus == true {
                commitDraft()
            }
        }
    }

    private func treeRow(_ row: WorkspaceTreeRow, location: WorkspaceFileLocation,
                         change: WorkspaceFileChange?,
                         directoryKind: WorkspaceFileChange.Kind?,
                         stageState: WorkspaceFileChange.StageState?, hasGit: Bool) -> some View {
        let node = row.node
        let kind = node.isDirectory ? directoryKind : change?.kind
        let isIgnored = !showsChanges && listing?.ignored.contains(node.path) == true
        let identity = treeIdentity(location) + "|" + node.path
        let isExpanded = tree.expanded.contains(identity)
        let isSelected = tree.selected == identity
        return Button {
            tree.selected = identity
            treeFocused = true
            if node.isDirectory {
                toggleDirectory(identity, path: node.path, isExpanded: isExpanded, location: location)
            } else {
                if showsChanges { onOpenDiff(location, node.path, true) }
                else { onOpenFile(location, node.path, true) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory
                      ? (isExpanded ? "folder.fill" : "folder")
                      : (showsChanges ? "arrow.left.arrow.right" : WorkspaceExplorer.fileIcon(node.path)))
                    .font(.system(size: typography.body))
                    .frame(width: 17)
                    .foregroundStyle(node.isDirectory ? Color.secondary : (showsChanges ? theme.accent : .secondary))
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(!node.isDirectory && kind == .deleted)
                    .foregroundStyle(kind.map(statusColor) ?? (isIgnored ? Color.secondary : Color.primary))
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
        // A click opens a file in the preview tab; a double click keeps it open.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !node.isDirectory else { return }
            if showsChanges { onOpenDiff(location, node.path, false) }
            else { onOpenFile(location, node.path, false) }
        })
        .overlay(alignment: .trailing) {
            if let stageState { stageToggle(stageState, path: node.path, location: location) }
        }
        .help(isIgnored ? node.path + " (ignored by Git)" : node.path)
        .accessibilityValue(node.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "File")
        .contextMenu {
            if node.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    toggleDirectory(identity, path: node.path, isExpanded: isExpanded, location: location)
                }
                Button("Find in Folder…", systemImage: "magnifyingglass") { onFindInFolder(location, node.path) }
                if showsChanges && location.isLocal {
                    Button("Open in New Tab", systemImage: "terminal") {
                        onNewTab(location.absolutePath(node.path))
                    }
                }
            } else {
                Button("Open", systemImage: "doc.text") {
                    tree.selected = identity
                    onOpenFile(location, node.path, false)
                }
                .disabled(change?.kind == .deleted)
                if change != nil {
                    Button("Open Changes", systemImage: "arrow.left.arrow.right") {
                        tree.selected = identity
                        onOpenDiff(location, node.path, false)
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
                if !showsChanges && !isIgnored { gitFileActions(location, node: node, change: change) }
                Divider()
            }
            if showsChanges {
                pathActions(location, path: node.path)
            } else {
                Button("Rename…", systemImage: "pencil") { startRename(node.path, isDirectory: node.isDirectory, at: location) }
                    .keyboardShortcut(ExplorerFileCommand.rename.shortcut)
                if location.isLocal {
                    Button("Move to Trash", systemImage: "trash") { trash(node.path, in: location) }
                        .keyboardShortcut(ExplorerFileCommand.trash.shortcut)
                }
                Button("Delete…", systemImage: "xmark.bin", role: .destructive) {
                    pendingDelete = WorkspaceFileTarget(location: location, path: node.path, isDirectory: node.isDirectory)
                }
                .keyboardShortcut(ExplorerFileCommand.delete.shortcut)
            }
        }
    }

    /// Creating, opening, copying and pasting around a row of the Files tree, in Zed's order.
    @ViewBuilder
    private func fileActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode) -> some View {
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        Button("New File…", systemImage: "doc.badge.plus") { startDraft(in: folder, isFolder: false, at: location) }
            .keyboardShortcut(ExplorerFileCommand.newFile.shortcut)
        Button("New Folder…", systemImage: "folder.badge.plus") { startDraft(in: folder, isFolder: true, at: location) }
            .keyboardShortcut(ExplorerFileCommand.newFolder.shortcut)
        Divider()
        if location.isLocal {
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.absolutePath(node.path)) }
                .keyboardShortcut(ExplorerFileCommand.reveal.shortcut)
            Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: location.absolutePath(node.path)))
            }
            .keyboardShortcut(ExplorerFileCommand.openInDefaultApp.shortcut)
            Button("Open in New Tab", systemImage: "terminal") { onNewTab(location.absolutePath(folder)) }
            Divider()
        }
        Button("Cut", systemImage: "scissors") { copyItem(node.path, in: location, cut: true) }
            .keyboardShortcut(ExplorerFileCommand.cut.shortcut)
        Button("Copy", systemImage: "doc.on.doc") { copyItem(node.path, in: location, cut: false) }
            .keyboardShortcut(ExplorerFileCommand.copy.shortcut)
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(node.path, in: location) }
            .keyboardShortcut(ExplorerFileCommand.duplicate.shortcut)
        Button("Paste", systemImage: "doc.on.clipboard") { paste(into: folder, in: location) }
            .keyboardShortcut(ExplorerFileCommand.paste.shortcut)
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.absolutePath(node.path)) }
            .keyboardShortcut(ExplorerFileCommand.copyPath.shortcut)
        Button("Copy Relative Path") { AppActions.copy(node.path) }
            .keyboardShortcut(ExplorerFileCommand.copyRelativePath.shortcut)
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

    private func toggleDirectory(_ identity: String, path: String, isExpanded: Bool, location: WorkspaceFileLocation) {
        tree.toggle(identity, isExpanded: isExpanded)
        if !isExpanded, !showsChanges { readIgnoredFolders([path], at: location) }
    }

    /// Reads the contents of expanded ignored folders, which the listing leaves out.
    private func readIgnoredFolders(_ folders: [String], at location: WorkspaceFileLocation) {
        guard let listing else { return }
        let toRead = WorkspaceExplorer.ignoredFoldersToRead(expanded: folders, ignored: listing.ignored,
                                                           read: Set(ignoredContents.keys))
        guard !toRead.isEmpty else { return }
        let version = listingVersion
        Task {
            let read = await Task.detached { Self.readFolders(toRead, at: location) }.value
            guard self.location?.identity == location.identity, listingVersion == version else { return }
            ignoredContents.merge(read) { _, new in new }
            ignoredContentsVersion += 1
        }
    }

    /// Folders that cannot be read, such as one deleted since, are left out.
    nonisolated private static func readFolders(_ folders: [String],
                                                at location: WorkspaceFileLocation) -> [String: WorkspaceFolderContents] {
        var read: [String: WorkspaceFolderContents] = [:]
        for folder in folders {
            if let contents = try? WorkspaceFiles.folderContents(folder, at: location) { read[folder] = contents }
        }
        return read
    }

    private func collapseAll(_ location: WorkspaceFileLocation) {
        tree.collapseAll(treeIdentity(location))
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

    /// Shows a name field in the tree, under `folder` ("" is the Space root), for a new item or
    /// for renaming the item at `renaming`.
    private func startDraft(in folder: String, isFolder: Bool, at location: WorkspaceFileLocation,
                            renaming: String? = nil) {
        tree.expand(folder, in: treeIdentity(location))
        draftName = renaming.map { ($0 as NSString).lastPathComponent } ?? ""
        draft = WorkspaceFileDraft(location: location, folder: folder, isFolder: isFolder, renaming: renaming)
    }

    /// Selects the name without its extension, as Finder and Zed do, so typing replaces only it.
    private func selectNameStem() {
        let stem = draft?.isFolder == true ? draftName : (draftName as NSString).deletingPathExtension
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
        }
    }

    private func startRename(_ path: String, isDirectory: Bool, at location: WorkspaceFileLocation) {
        startDraft(in: (path as NSString).deletingLastPathComponent, isFolder: isDirectory, at: location, renaming: path)
    }

    /// Runs a file shortcut on the selected row, or on the Space root when nothing is selected,
    /// while the Files tree of this window has focus. Returns whether the key was used.
    private func handleFileShortcut(_ event: NSEvent) -> Bool {
        guard treeFocused, !showsChanges, draft == nil, pendingDelete == nil, listing != nil, let location,
              event.window != nil, event.window === windowBox.window,
              let command = ExplorerFileCommand.allCases.first(where: { $0.matches(event) }) else { return false }
        let path = tree.selectedPath(in: treeIdentity(location)) ?? ""
        guard !path.isEmpty || command.appliesToRoot else { return false }
        let directories = listing.map { filesTree($0, location: location).directories } ?? []
        let isDirectory = WorkspaceExplorer.isDirectory(path, directories: directories,
                                                        created: tree.createdDirectories[location.identity] ?? [])
        let folder = WorkspaceExplorer.folder(for: path, isDirectory: isDirectory)
        let absolute = location.absolutePath(path)
        switch command {
        case .newFile: startDraft(in: folder, isFolder: false, at: location)
        case .newFolder: startDraft(in: folder, isFolder: true, at: location)
        case .reveal, .openInDefaultApp, .trash:
            guard location.isLocal else { return false }
            if command == .reveal { AppActions.reveal(absolute) }
            else if command == .trash { trash(path, in: location) }
            else { NSWorkspace.shared.open(URL(fileURLWithPath: absolute)) }
        case .cut, .copy: copyItem(path, in: location, cut: command == .cut)
        case .duplicate: duplicate(path, in: location)
        case .paste: paste(into: folder, in: location)
        case .copyPath: AppActions.copy(absolute)
        case .copyRelativePath: AppActions.copy(path)
        case .rename: startRename(path, isDirectory: isDirectory, at: location)
        case .delete: pendingDelete = WorkspaceFileTarget(location: location, path: path, isDirectory: isDirectory)
        }
        return true
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
        if let original = draft.renaming {
            guard name != (original as NSString).lastPathComponent else { return }
            runOperation(location) { try WorkspaceFiles.renameItem(original, to: name, at: location) } completion: {
                movePathState(from: original, to: $0, in: location)
            }
            return
        }
        let path = WorkspaceExplorer.path(of: name, in: draft.folder)
        runOperation(location) {
            if draft.isFolder { try WorkspaceFiles.createFolder(path, at: location) }
            else { try WorkspaceFiles.createFile(path, at: location) }
        } completion: {
            if draft.isFolder { tree.createdDirectories[location.identity, default: []].insert(path) }
            reveal(path, in: location)
            if !draft.isFolder { onOpenFile(location, path, false) }
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
        let (sources, move) = WorkspaceExplorer.pasteSources(
            clipboard: clipboard, location: location, pasteboardChangeCount: pasteboard.changeCount
        ) {
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
                .map(\.path) ?? []
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
                tree.createdDirectories[location.identity, default: []].insert(path)
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
        tree.reveal(path, in: treeIdentity(location))
    }

    private func movePathState(from original: String, to renamed: String, in location: WorkspaceFileLocation) {
        tree.move(from: original, to: renamed, in: treeIdentity(location), location: location.identity)
    }

    private func forgetPathState(_ path: String, in location: WorkspaceFileLocation) {
        tree.forget(path, location: location.identity)
    }

    private func statusColor(_ kind: WorkspaceFileChange.Kind) -> Color {
        theme.vcs(kind)
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
        let created = tree.createdDirectories[location.identity] ?? []
        let expanded = tree.expandedFolders(in: "\(location.identity)|files")
        func exists(_ path: String) -> Bool {
            guard location.isLocal else { return true }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: location.absolutePath(path), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        Task {
            // The Files tree is built here too, so a large Space is not sorted on the main thread.
            let result = await Task.detached {
                Result { () -> (WorkspaceFileListing, WorkspaceTree, Set<String>, [String: WorkspaceFolderContents]) in
                    let listing = try WorkspaceFiles.listing(at: location)
                    let kept = created.filter(exists)
                    // Expanded ignored folders are read again, so they stay open across reloads.
                    let folders = WorkspaceExplorer.ignoredFoldersToRead(expanded: expanded, ignored: listing.ignored, read: [])
                    let contents = Self.readFolders(folders, at: location)
                    let entries = WorkspaceExplorer.filesTreeEntries(listing, ignoredContents: contents, created: kept)
                    return (listing, WorkspaceTree(paths: entries.paths, directories: entries.directories), kept, contents)
                }
            }.value
            guard self.location?.identity == location.identity else { return }
            var filesTree: (tree: WorkspaceTree, directories: Set<String>)?
            switch result {
            case .success(let (value, builtTree, kept, contents)):
                listing = value
                ignoredContents = contents
                tree.pruneCreated(location: location.identity, exists: exists)
                filesTree = (builtTree, kept)
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
            listingVersion += 1
            ignoredContentsVersion += 1
            if let filesTree {
                treeCache.store(filesTree.tree, .files, listing: listingVersion, contents: ignoredContentsVersion,
                                directories: filesTree.directories)
            }
            TerminalPipelineMetrics.spanShown("file-list", start: start, detail: location.isLocal ? "local" : "ssh")
        }
    }
}

struct WorkspaceTreeNode {
    let displayName: String
    let path: String
    let isDirectory: Bool
    let children: [WorkspaceTreeNode]
}

/// A folder tree built once from a listing, off the main thread for the Files tree: folders
/// first, names in natural order, a chain of single folders on one row. `visibleRows` walks only
/// expanded folders, so a render costs the rows shown rather than the files listed.
struct WorkspaceTree {
    let nodes: [WorkspaceTreeNode]
    /// Every folder, including those inside a chain shown on one row.
    let directories: Set<String>

    var isEmpty: Bool { nodes.isEmpty }

    /// `directories` adds folders that hold no listed file, such as one just created in the explorer.
    init(paths: [String], directories: Set<String> = []) {
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

        var folders = Set<String>()
        func compact(_ source: WorkspaceTreeBuilderNode) -> WorkspaceTreeNode {
            var node = source
            var names = [node.name]
            while node.children.count == 1,
                  let child = node.children.values.first,
                  !child.children.isEmpty {
                folders.insert(node.path)
                node = child
                names.append(node.name)
            }
            let children = node.children.values.map(compact).sorted(by: Self.ordered)
            let isDirectory = node.isDirectory || !children.isEmpty
            if isDirectory { folders.insert(node.path) }
            return WorkspaceTreeNode(displayName: names.joined(separator: " / "), path: node.path,
                                     isDirectory: isDirectory, children: children)
        }
        nodes = root.children.values.map(compact).sorted(by: Self.ordered)
        self.directories = folders
    }

    /// The rows shown when the folders keyed "<identity>|<path>" in `expanded` are open.
    func visibleRows(expanded: Set<String>, identity: String) -> [WorkspaceTreeRow] {
        var rows: [WorkspaceTreeRow] = []
        func append(_ nodes: [WorkspaceTreeNode], depth: Int) {
            for node in nodes {
                rows.append(WorkspaceTreeRow(node: node, depth: depth))
                if node.isDirectory && expanded.contains(identity + "|" + node.path) {
                    append(node.children, depth: depth + 1)
                }
            }
        }
        append(nodes, depth: 1)
        return rows
    }

    private static func ordered(_ lhs: WorkspaceTreeNode, _ rhs: WorkspaceTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

/// The trees the explorer shows, kept until the listing or the created folders they were
/// built from change, so rendering a large Space does not rebuild its tree.
@MainActor
final class WorkspaceTreeCache {
    enum Kind { case files, modified, changes }

    private struct Key: Equatable {
        let listing: Int
        /// Version of the ignored folders' contents read since the listing.
        let contents: Int
        let directories: Set<String>
    }

    private var trees: [Kind: (key: Key, tree: WorkspaceTree)] = [:]

    /// The tree of `kind` for listing version `listing`, built with `build` when none is kept.
    func tree(_ kind: Kind, listing: Int, contents: Int = 0, directories: Set<String> = [],
              build: () -> WorkspaceTree) -> WorkspaceTree {
        let key = Key(listing: listing, contents: contents, directories: directories)
        if let kept = trees[kind], kept.key == key { return kept.tree }
        let tree = build()
        trees[kind] = (key, tree)
        return tree
    }

    /// Keeps a tree built elsewhere, such as the Files tree built with its listing.
    func store(_ tree: WorkspaceTree, _ kind: Kind, listing: Int, contents: Int = 0, directories: Set<String> = []) {
        trees[kind] = (Key(listing: listing, contents: contents, directories: directories), tree)
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
private struct WorkspaceFileTarget {
    let location: WorkspaceFileLocation
    let path: String
    let isDirectory: Bool
}

/// A file or folder being named in the tree: a new one, or one being renamed.
private struct WorkspaceFileDraft {
    let location: WorkspaceFileLocation
    /// The folder it is created in; "" is the Space root.
    let folder: String
    let isFolder: Bool
    /// The item being renamed; nil for a new one.
    let renaming: String?
    var hasHadFocus = false
}

/// File shortcuts of the Files tree, with Zed's bindings. They act only while the tree has
/// focus, so Command-C, Command-D and the rest keep their usual meaning in terminals and editors.
enum ExplorerFileCommand: CaseIterable {
    case newFile, newFolder, reveal, openInDefaultApp, cut, copy, duplicate, paste
    case copyPath, copyRelativePath, rename, trash, delete

    var shortcut: KeyboardShortcut {
        switch self {
        case .newFile: return KeyboardShortcut("n", modifiers: .command)
        case .newFolder: return KeyboardShortcut("n", modifiers: [.command, .option])
        case .reveal: return KeyboardShortcut("r", modifiers: [.command, .option])
        case .openInDefaultApp: return KeyboardShortcut(.return, modifiers: [.control, .shift])
        case .cut: return KeyboardShortcut("x", modifiers: .command)
        case .copy: return KeyboardShortcut("c", modifiers: .command)
        case .duplicate: return KeyboardShortcut("d", modifiers: .command)
        case .paste: return KeyboardShortcut("v", modifiers: .command)
        case .copyPath: return KeyboardShortcut("c", modifiers: [.command, .option])
        case .copyRelativePath: return KeyboardShortcut("c", modifiers: [.command, .option, .shift])
        case .rename: return KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
        case .trash: return KeyboardShortcut(.delete, modifiers: [])
        case .delete: return KeyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }

    /// Commands that make sense with nothing selected, on the Space root.
    var appliesToRoot: Bool {
        [.newFile, .newFolder, .reveal, .openInDefaultApp, .paste, .copyPath].contains(self)
    }

    func matches(_ event: NSEvent) -> Bool {
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifiers else { return false }
        switch shortcut.key.character {
        case KeyEquivalent.delete.character: return event.keyCode == 51
        case KeyEquivalent.return.character: return event.keyCode == 36 || event.keyCode == 76
        default: return event.charactersIgnoringModifiers?.lowercased() == String(shortcut.key.character)
        }
    }
}

/// The window a view is in, for telling apart key events of other windows.
private final class WindowBox {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { box.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if box.window == nil { DispatchQueue.main.async { box.window = view.window } }
    }
}

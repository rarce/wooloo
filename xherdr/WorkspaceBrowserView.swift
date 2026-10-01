import SwiftUI
import UniformTypeIdentifiers

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
    /// The active editor tab's file, selected in the tree when it changes.
    var activeFile: WorkspaceActiveFile?
    /// Opens only a file's staged or unstaged changes.
    var onOpenScopedDiff: (_ location: WorkspaceFileLocation, _ path: String, _ scope: WorkspaceDiffScope) -> Void = { _, _, _ in }

    @State private var remoteSnapshot: HerdrSnapshot?
    @State private var remoteWorkspaceID: String?
    /// Not private so snapshot tests can open folders and select a row before it appears.
    @StateObject var model = WorkspaceExplorerModel()
    @FocusState private var draftFocused: Bool
    /// Whether the Files tree has keyboard focus, so file shortcuts apply to its selection.
    @FocusState private var treeFocused: Bool
    @State private var keyMonitor: Any?
    @State private var windowBox = WindowBox()
    /// Bumped by Git bar operations so the repository panel refreshes too.
    @State private var gitVersion = 0
    @AppStorage("RepositoryCollapsed") private var repositoryCollapsed = false
    /// A file whose history the repository panel shows.
    @State private var historyPath: String?
    /// Changes waiting for confirmation before they are discarded.
    @State private var pendingDiscard: PendingDiscard?
    /// The index of the row at the top of the tree's view, once it scrolls past the first row,
    /// for the folders pinned above it.
    @State private var stickyTop: Int?
    /// Where the rows start in the tree's content, below the root and its hints.
    @State private var rowsOffset: CGFloat = 0

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
        // Also once the Space's listing arrives, and when switching between Files and Changes.
        .onChange(of: ActiveFileReveal(file: activeFile, listed: model.listedIdentity, changes: model.showsChanges),
                  initial: true) { _, reveal in
            if let file = reveal.file { model.revealActiveFile(file) }
        }
        .alert("Operation failed", isPresented: Binding(
            get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } }
        )) {
            Button("OK") { model.operationError = nil }
        } message: {
            Text(model.operationError ?? "")
        }
    }

    private var repository: some View {
        WorkspaceRepositoryView(location: location, refreshVersion: refreshVersion + gitVersion,
                                isCollapsed: $repositoryCollapsed,
                                onChange: { loadListing() },
                                onNewSpace: location?.isLocal == true ? onNewSpace : nil,
                                onOpenCommitFile: onOpenCommitFile,
                                historyPath: $historyPath)
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
                if !model.showsChanges {
                    // A plain button, because a borderless Menu ignores its label's color and weight.
                    Button { model.modifiedOnly.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.modifiedOnly ? "line.3.horizontal.decrease.circle.fill"
                                                           : "line.3.horizontal.decrease.circle")
                            if model.modifiedOnly { Text("Modified") }
                        }
                        .font(.system(size: typography.secondary, weight: model.modifiedOnly ? .semibold : .regular))
                        .foregroundStyle(model.modifiedOnly ? theme.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.modifiedOnly ? "Showing modified files; click to show all" : "Show modified files only")
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
                segment("Files", icon: "doc.text", selected: !model.showsChanges) { model.showsChanges = false }
                segment("Changes", icon: "arrow.left.arrow.right", selected: model.showsChanges) { model.showsChanges = true }
            }
            .padding(.horizontal, 3)
            Divider()

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                Text(error)
                    .font(.system(size: typography.body))
                    .foregroundStyle(theme.warning)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let listing = model.listing, let location {
                let shownTree = model.shownTree(listing, location: location)
                let changesByPath = Dictionary(listing.changes.map { ($0.path, $0) },
                                               uniquingKeysWith: { first, _ in first })
                let directoryKinds = WorkspaceExplorer.directoryKinds(listing.changes)
                let stageStates = model.showsChanges ? WorkspaceExplorer.stageStates(listing.changes) : [:]
                let rows = model.visibleRows(listing, location: location)
                let shownDraft = !model.showsChanges && model.draft?.location.identity == location.identity ? model.draft : nil
                let draftFolder = shownDraft?.renaming == nil ? shownDraft?.folder : nil
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                treeRoot(location, stageState: listing.hasGit ? stageStates[""] : nil)
                                if !model.tree.collapsedRoots.contains(model.treeIdentity(location)) {
                                    if draftFolder == "" { draftRow(depth: 1) }
                                    if (model.showsChanges || model.isFilteredFiles) && !listing.hasGit {
                                        hint("No Git repository in this Space")
                                    } else if shownTree.isEmpty {
                                        hint(model.showsChanges ? "No changes" : (model.modifiedOnly ? "No modified files" : "No files"))
                                    }
                                    if !model.showsChanges && listing.totalFiles > listing.files.count {
                                        hint("Showing \(listing.files.count) of \(listing.totalFiles) files; tracked files come first")
                                    }
                                    Color.clear
                                        .frame(height: 0)
                                        .background(GeometryReader { anchor in
                                            Color.clear.preference(key: ExplorerScrollMetrics.self, value: ExplorerScrollMetrics(
                                                rowsTop: anchor.frame(in: .named(ExplorerScrollMetrics.space)).minY))
                                        })
                                    ForEach(rows) { row in
                                        if shownDraft?.renaming == row.node.path {
                                            draftRow(depth: row.depth)
                                        } else {
                                            treeRow(row, location: location,
                                                    change: changesByPath[row.node.path],
                                                    directoryKind: directoryKinds[row.node.path],
                                                    stageState: listing.hasGit ? stageStates[row.node.path] : nil,
                                                    hasGit: listing.hasGit)
                                            .id(row.node.path)
                                        }
                                        if row.node.isDirectory, draftFolder == row.node.path { draftRow(depth: row.depth + 1) }
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                            .background(GeometryReader { content in
                                Color.clear.preference(key: ExplorerScrollMetrics.self, value: ExplorerScrollMetrics(
                                    contentTop: content.frame(in: .named(ExplorerScrollMetrics.space)).minY))
                            })
                            // The space under the last row opens the Space's menu too.
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                            .background {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.tree.selected = nil
                                        treeFocused = true
                                    }
                                    .contextMenu { rootMenu(location) }
                                    .onDrop(of: ExplorerDropDelegate.types,
                                            delegate: ExplorerDropDelegate(row: "", folder: "", location: location, model: model))
                            }
                        }
                        .coordinateSpace(name: ExplorerScrollMetrics.space)
                        .onPreferenceChange(ExplorerScrollMetrics.self) { metrics in
                            // The rows' start is measured while it is in view, and kept once it scrolls away.
                            if let rowsTop = metrics.rowsTop, let contentTop = metrics.contentTop,
                               rowsTop - contentTop != rowsOffset {
                                rowsOffset = rowsTop - contentTop
                            }
                            guard let contentTop = metrics.contentTop else { return }
                            let scrolled = -contentTop - rowsOffset
                            let top = scrolled > 0 ? Int(scrolled / typography.metric(23)) : nil
                            if top != stickyTop { stickyTop = top }
                        }
                        .overlay(alignment: .top) {
                            stickyFolders(rows, location: location, listing: listing, stageStates: stageStates,
                                          directoryKinds: directoryKinds, proxy: proxy)
                        }
                        // Keeps a row chosen with the keyboard in view, scrolling no more than needed.
                        .onChange(of: model.tree.selected) { _, _ in
                            if let path = model.tree.selectedPath(in: model.treeIdentity(location)) { proxy.scrollTo(path) }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($treeFocused)
                .id(model.treeIdentity(location))
            } else {
                hint("Select a Space to browse")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let location, model.listing?.hasGit == true {
                Divider()
                WorkspaceGitBar(location: location, reloadToken: model.listingVersion,
                                changes: model.showsChanges ? model.listing?.changes ?? [] : nil,
                                onChange: {
                                    gitVersion += 1
                                    loadListing(quietly: true)
                                },
                                onOpenWorktree: location.isLocal ? onOpenWorktree : nil,
                                onError: { model.operationError = $0 })
            }
        }
        .background(theme.sidebarBackground)
        .confirmationDialog(model.pendingDelete.map { target in
                                let items = target.paths.count > 1 ? "\(target.paths.count) items"
                                                                   : "“" + (target.path as NSString).lastPathComponent + "”"
                                return target.permanently ? "Delete \(items)?" : "Move \(items) to the Trash?"
                            } ?? "",
                            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                            presenting: model.pendingDelete) { target in
            Button(target.permanently ? "Delete" : "Move to Trash", role: .destructive) { model.delete(target) }
        } message: { target in
            if target.permanently {
                Text(target.paths.count > 1 ? "The items and everything in them are deleted permanently."
                     : target.isDirectory ? "The folder and everything in it are deleted permanently."
                     : "The file is deleted permanently.")
            } else {
                Text("You can restore it from the Trash.")
            }
        }
        .confirmationDialog(pendingDiscard.map { "Discard changes to \($0.name)?" } ?? "",
                            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            presenting: pendingDiscard) { target in
            Button("Discard Changes", role: .destructive) {
                model.runOperation(target.location) {
                    for change in target.changes { try WorkspaceFiles.discard(change, at: target.location) }
                }
            }
        } message: { target in
            Text(target.changes.contains { $0.kind == .untracked || $0.kind == .added }
                 ? "Files are restored to their last commit, and new files are deleted. This cannot be undone."
                 : "Files are restored to their last commit. This cannot be undone.")
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

    private func treeRoot(_ location: WorkspaceFileLocation,
                          stageState: WorkspaceFileChange.StageState?) -> some View {
        let identity = model.treeIdentity(location)
        let isExpanded = !model.tree.collapsedRoots.contains(identity)
        return Button {
            if isExpanded { model.tree.collapsedRoots.insert(identity) }
            else { model.tree.collapsedRoots.remove(identity) }
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
        .background(model.dropFolder == "" ? theme.accent.opacity(0.14) : .clear)
        .help(location.root)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .contextMenu { rootMenu(location) }
        .onDrop(of: ExplorerDropDelegate.types,
                delegate: ExplorerDropDelegate(row: "", folder: "", location: location, model: model))
    }

    @ViewBuilder
    private func rootMenu(_ location: WorkspaceFileLocation) -> some View {
        if !model.showsChanges {
            Button("New File…", systemImage: "doc.badge.plus") { model.startDraft(in: "", isFolder: false, at: location) }
                .keyboardShortcut(ExplorerFileCommand.newFile.shortcut)
            Button("New Folder…", systemImage: "folder.badge.plus") { model.startDraft(in: "", isFolder: true, at: location) }
                .keyboardShortcut(ExplorerFileCommand.newFolder.shortcut)
            Button("Paste", systemImage: "doc.on.clipboard") { model.paste(into: "", in: location) }
                .keyboardShortcut(ExplorerFileCommand.paste.shortcut)
            Divider()
        }
        if location.isLocal {
            Button("Open in New Tab", systemImage: "terminal") { onNewTab(location.root) }
            Divider()
        }
        Button(model.undoName(at: location).map { "Undo \($0)" } ?? "Undo", systemImage: "arrow.uturn.backward") {
            model.undo(at: location)
        }
        .keyboardShortcut(ExplorerFileCommand.undo.shortcut)
        .disabled(model.undoName(at: location) == nil)
        Button(model.redoName(at: location).map { "Redo \($0)" } ?? "Redo", systemImage: "arrow.uturn.forward") {
            model.redo(at: location)
        }
        .keyboardShortcut(ExplorerFileCommand.redo.shortcut)
        .disabled(model.redoName(at: location) == nil)
        Divider()
        Button("Find in Space…", systemImage: "magnifyingglass") { onFindInFolder(location, "") }
            .keyboardShortcut(ExplorerFileCommand.findInFolder.shortcut)
        Button("Collapse All Folders", systemImage: "rectangle.compress.vertical") { model.collapseAll(location) }
            .keyboardShortcut(ExplorerFileCommand.collapseAll.shortcut)
        Divider()
        if !model.showsChanges {
            Button(model.modifiedOnly ? "Show All Files" : "Show Modified Only",
                   systemImage: "line.3.horizontal.decrease") { model.modifiedOnly.toggle() }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
        Divider()
        pathActions(location, path: "")
    }

    /// The folders holding the rows in view, pinned at the top while the tree scrolls. Clicking
    /// one selects it and scrolls back to it, just below the folders that hold it.
    @ViewBuilder
    private func stickyFolders(_ rows: [WorkspaceTreeRow], location: WorkspaceFileLocation, listing: WorkspaceFileListing,
                               stageStates: [String: WorkspaceFileChange.StageState],
                               directoryKinds: [String: WorkspaceFileChange.Kind], proxy: ScrollViewProxy) -> some View {
        let sticky = stickyTop.map { WorkspaceExplorer.stickyRows(rows, top: $0) } ?? []
        if !sticky.isEmpty {
            VStack(spacing: 0) {
                ForEach(sticky) { row in
                    treeRow(row, location: location, change: nil, directoryKind: directoryKinds[row.node.path],
                            stageState: listing.hasGit ? stageStates[row.node.path] : nil, hasGit: listing.hasGit)
                        .allowsHitTesting(false)
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.tree.selected = model.treeIdentity(location) + "|" + row.node.path
                                    treeFocused = true
                                    guard let index = rows.firstIndex(where: { $0.node.path == row.node.path }) else { return }
                                    proxy.scrollTo(rows[max(0, index - (row.depth - 1))].node.path, anchor: .top)
                                }
                                .onDrop(of: ExplorerDropDelegate.types,
                                        delegate: ExplorerDropDelegate(row: row.node.path, folder: row.node.path,
                                                                       location: location, model: model))
                        }
                }
            }
            .background(theme.sidebarBackground)
            .overlay(alignment: .bottom) { Divider() }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        }
    }

    /// The name field of a file or folder being created, indented as its first child, or of
    /// one being renamed, in place of its row.
    private func draftRow(depth: Int) -> some View {
        let isFolder = model.draft?.isFolder == true
        return HStack(spacing: 6) {
            Image(systemName: isFolder ? "folder" : model.draft?.renaming.map(WorkspaceExplorer.fileIcon) ?? "doc.text")
                .font(.system(size: typography.body))
                .frame(width: 17)
                .foregroundStyle(.secondary)
            TextField(isFolder ? "Folder name" : "File name", text: $model.draftName)
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
                if model.draft?.hasHadFocus == false, model.draft?.renaming != nil { selectNameStem() }
                model.draft?.hasHadFocus = true
            } else if model.draft?.hasHadFocus == true {
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
        let isIgnored = !model.showsChanges && model.listing?.ignored.contains(node.path) == true
        let identity = model.treeIdentity(location) + "|" + node.path
        let isExpanded = model.tree.expanded.contains(identity)
        let isSelected = model.tree.selected == identity || model.tree.isMarked(identity)
        // A drop goes in the folder under the pointer, or in the folder of the file under it;
        // that folder and what it shows are highlighted.
        let dropFolder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        let isDropTarget = model.dropFolder.map { $0.isEmpty || node.path == $0 || node.path.hasPrefix($0 + "/") } ?? false
        return Button {
            treeFocused = true
            // Command-clicks add rows to the selection and Shift-clicks select a range, as in Finder.
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.command) { return model.toggleMark(node.path, in: location) }
            if modifiers.contains(.shift) { return model.extendSelection(to: node.path, in: location) }
            model.tree.selected = identity
            if node.isDirectory {
                model.toggleDirectory(identity, path: node.path, isExpanded: isExpanded, location: location)
            } else {
                if model.showsChanges { onOpenDiff(location, node.path, true) }
                else { onOpenFile(location, node.path, true) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory
                      ? (isExpanded ? "folder.fill" : "folder")
                      : (model.showsChanges ? "arrow.left.arrow.right" : WorkspaceExplorer.fileIcon(node.path)))
                    .font(.system(size: typography.body))
                    .frame(width: 17)
                    .foregroundStyle(node.isDirectory ? Color.secondary : (model.showsChanges ? theme.accent : .secondary))
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
            .background(isDropTarget ? theme.accent.opacity(0.14) : .clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                ForEach(0..<row.depth, id: \.self) { level in
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, CGFloat(level) * 19 + 19)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        // A click opens a file in the preview tab; a double click keeps it open.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !node.isDirectory, NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
            if model.showsChanges { onOpenDiff(location, node.path, false) }
            else { onOpenFile(location, node.path, false) }
        })
        .overlay(alignment: .trailing) {
            if let stageState { stageToggle(stageState, path: node.path, location: location) }
        }
        .onDrag { model.startDrag(node.path, in: location) }
        .onDrop(of: ExplorerDropDelegate.types,
                delegate: ExplorerDropDelegate(row: node.path, folder: dropFolder, location: location, model: model))
        .help(isIgnored ? node.path + " (ignored by Git)" : node.path)
        .accessibilityValue(node.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "File")
        .contextMenu {
            let targets = model.menuTargets(node.path, in: location)
            if targets.count > 1 {
                selectionMenu(targets, location: location, hasGit: hasGit)
            } else {
                if node.isDirectory {
                    Button(isExpanded ? "Collapse" : "Expand",
                           systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                        model.toggleDirectory(identity, path: node.path, isExpanded: isExpanded, location: location)
                    }
                    Button("Find in Folder…", systemImage: "magnifyingglass") { onFindInFolder(location, node.path) }
                        .keyboardShortcut(ExplorerFileCommand.findInFolder.shortcut)
                    if model.showsChanges && location.isLocal {
                        Button("Open in New Tab", systemImage: "terminal") {
                            onNewTab(location.absolutePath(node.path))
                        }
                    }
                } else {
                    Button("Open", systemImage: "doc.text") {
                        model.tree.selected = identity
                        onOpenFile(location, node.path, false)
                    }
                    .keyboardShortcut(model.showsChanges ? nil : ExplorerFileCommand.open.shortcut)
                    .disabled(change?.kind == .deleted)
                    if change != nil {
                        Button("Open Changes", systemImage: "arrow.left.arrow.right") {
                            model.tree.selected = identity
                            onOpenDiff(location, node.path, false)
                        }
                        .keyboardShortcut(model.showsChanges ? ExplorerFileCommand.open.shortcut : nil)
                    }
                }
                Divider()
                if !model.showsChanges { fileActions(location, node: node) }
                if hasGit {
                    if let kind {
                        if node.isDirectory || change?.worktreeStatus != " " {
                            Button(node.isDirectory ? "Stage Folder" : "Stage Changes", systemImage: "plus.circle") {
                                model.runOperation(location) { try WorkspaceFiles.stage(node.path, at: location) }
                            }
                        }
                        if node.isDirectory ? kind != .untracked
                            : (change?.indexStatus != " " && change?.indexStatus != "?") {
                            Button(node.isDirectory ? "Unstage Folder" : "Unstage Changes", systemImage: "minus.circle") {
                                model.runOperation(location) { try WorkspaceFiles.unstage(node.path, at: location) }
                            }
                        }
                    }
                    if model.showsChanges {
                        changeActions(location, node: node, change: change)
                    } else if !isIgnored {
                        gitFileActions(location, node: node, change: change)
                    }
                    Divider()
                }
                if model.showsChanges {
                    pathActions(location, path: node.path)
                    if hasGit {
                        Divider()
                        ignoreActions(location, node: node, enabled: node.isDirectory ? kind == .untracked
                                                                                       : change?.kind == .untracked)
                        if !node.isDirectory {
                            Divider()
                            Button("View File History", systemImage: "clock.arrow.circlepath") { historyPath = node.path }
                                .disabled(change?.kind == .untracked || change?.kind == .added)
                        }
                    }
                } else {
                    Button("Rename…", systemImage: "pencil") { model.startRename(node.path, isDirectory: node.isDirectory, at: location) }
                        .keyboardShortcut(ExplorerFileCommand.rename.shortcut)
                    if location.isLocal {
                        Button("Move to Trash", systemImage: "trash") { model.trash([node.path], in: location) }
                            .keyboardShortcut(ExplorerFileCommand.trash.shortcut)
                    }
                    Button("Delete…", systemImage: "xmark.bin", role: .destructive) {
                        model.pendingDelete = WorkspaceFileTarget(location: location, path: node.path, isDirectory: node.isDirectory)
                    }
                    .keyboardShortcut(ExplorerFileCommand.delete.shortcut)
                }
            }
        }
    }

    /// The context menu of a row among several selected ones: what applies to all of them.
    @ViewBuilder
    private func selectionMenu(_ paths: [String], location: WorkspaceFileLocation, hasGit: Bool) -> some View {
        let changes = (model.listing?.changes ?? []).filter { change in
            paths.contains { change.path == $0 || change.path.hasPrefix($0 + "/") }
        }
        Text("\(paths.count) Items Selected")
        Divider()
        if !model.showsChanges {
            Button("Cut", systemImage: "scissors") { model.copyItems(paths, in: location, cut: true) }
                .keyboardShortcut(ExplorerFileCommand.cut.shortcut)
            Button("Copy", systemImage: "doc.on.doc") { model.copyItems(paths, in: location, cut: false) }
                .keyboardShortcut(ExplorerFileCommand.copy.shortcut)
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(paths, in: location) }
                .keyboardShortcut(ExplorerFileCommand.duplicate.shortcut)
            Divider()
        }
        Button("Copy Paths", systemImage: "doc.on.doc") {
            AppActions.copy(paths.map(location.absolutePath).joined(separator: "\n"))
        }
        .keyboardShortcut(ExplorerFileCommand.copyPath.shortcut)
        Button("Copy Relative Paths") { AppActions.copy(paths.joined(separator: "\n")) }
            .keyboardShortcut(ExplorerFileCommand.copyRelativePath.shortcut)
        if hasGit && !changes.isEmpty {
            Divider()
            Button("Stage Changes", systemImage: "plus.circle") {
                model.runOperation(location) { for path in paths { try WorkspaceFiles.stage(path, at: location) } }
            }
            .disabled(!changes.contains { $0.worktreeStatus != " " })
            Button("Unstage Changes", systemImage: "minus.circle") {
                model.runOperation(location) {
                    for change in changes where change.indexStatus != " " && change.indexStatus != "?" {
                        try WorkspaceFiles.unstage(change.path, at: location)
                    }
                }
            }
            .disabled(!changes.contains { $0.indexStatus != " " && $0.indexStatus != "?" })
            if model.showsChanges {
                Button("Discard Changes…", systemImage: "arrow.uturn.backward", role: .destructive) {
                    pendingDiscard = PendingDiscard(location: location, name: "\(paths.count) items", changes: changes)
                }
            }
        }
        if !model.showsChanges {
            Divider()
            if location.isLocal {
                Button("Move to Trash", systemImage: "trash") { model.trash(paths, in: location) }
                    .keyboardShortcut(ExplorerFileCommand.trash.shortcut)
            }
            Button("Delete…", systemImage: "xmark.bin", role: .destructive) {
                model.pendingDelete = WorkspaceFileTarget(location: location, paths: paths, isDirectory: false)
            }
            .keyboardShortcut(ExplorerFileCommand.delete.shortcut)
        }
    }

    /// Creating, opening, copying and pasting around a row of the Files tree, in Zed's order.
    @ViewBuilder
    private func fileActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode) -> some View {
        let folder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        Button("New File…", systemImage: "doc.badge.plus") { model.startDraft(in: folder, isFolder: false, at: location) }
            .keyboardShortcut(ExplorerFileCommand.newFile.shortcut)
        Button("New Folder…", systemImage: "folder.badge.plus") { model.startDraft(in: folder, isFolder: true, at: location) }
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
        Button("Cut", systemImage: "scissors") { model.copyItems([node.path], in: location, cut: true) }
            .keyboardShortcut(ExplorerFileCommand.cut.shortcut)
        Button("Copy", systemImage: "doc.on.doc") { model.copyItems([node.path], in: location, cut: false) }
            .keyboardShortcut(ExplorerFileCommand.copy.shortcut)
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate([node.path], in: location) }
            .keyboardShortcut(ExplorerFileCommand.duplicate.shortcut)
        Button("Paste", systemImage: "doc.on.clipboard") { model.paste(into: folder, in: location) }
            .keyboardShortcut(ExplorerFileCommand.paste.shortcut)
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.absolutePath(node.path)) }
            .keyboardShortcut(ExplorerFileCommand.copyPath.shortcut)
        Button("Copy Relative Path") { AppActions.copy(node.path) }
            .keyboardShortcut(ExplorerFileCommand.copyRelativePath.shortcut)
        Divider()
    }

    /// Ignore rules, history and hosting-site links for a row of the Files tree in a Git repository.
    @ViewBuilder
    private func gitFileActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode,
                                change: WorkspaceFileChange?) -> some View {
        ignoreActions(location, node: node, enabled: true)
        // History and permalinks come from commits, so only files they contain have them.
        if !node.isDirectory, change?.kind != .untracked, change?.kind != .added {
            Button("View File History", systemImage: "clock.arrow.circlepath") { historyPath = node.path }
            Button("Open File Permalink", systemImage: "link") {
                model.runOperation(location, reloads: false, { try WorkspaceFiles.permalink(node.path, at: location) }) {
                    NSWorkspace.shared.open($0)
                }
            }
            Button("Copy File Permalink") {
                model.runOperation(location, reloads: false, { try WorkspaceFiles.permalink(node.path, at: location) }) {
                    AppActions.copy($0.absoluteString)
                }
            }
        }
    }

    @ViewBuilder
    private func ignoreActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode, enabled: Bool) -> some View {
        Button("Add to .gitignore", systemImage: "eye.slash") {
            model.runOperation(location) {
                try WorkspaceFiles.ignore(node.path, isDirectory: node.isDirectory, inExclude: false, at: location)
            }
        }
        .disabled(!enabled)
        Button("Add to .git/info/exclude") {
            model.runOperation(location) {
                try WorkspaceFiles.ignore(node.path, isDirectory: node.isDirectory, inExclude: true, at: location)
            }
        }
        .disabled(!enabled)
    }

    /// Discarding a row's changes and opening only its staged or unstaged changes, as in Zed's
    /// Changes panel.
    @ViewBuilder
    private func changeActions(_ location: WorkspaceFileLocation, node: WorkspaceTreeNode,
                               change: WorkspaceFileChange?) -> some View {
        let changes = node.isDirectory
            ? (model.listing?.changes ?? []).filter { $0.path.hasPrefix(node.path + "/") }
            : change.map { [$0] } ?? []
        Button("Discard Changes…", systemImage: "arrow.uturn.backward", role: .destructive) {
            pendingDiscard = PendingDiscard(location: location, name: "“\(node.displayName)”", changes: changes)
        }
        .disabled(changes.isEmpty)
        if let change, !node.isDirectory {
            Divider()
            Button("Unstaged Changes", systemImage: "pencil.line") {
                onOpenScopedDiff(location, node.path, .unstaged)
            }
            .disabled(change.worktreeStatus == " ")
            Button("Staged Changes", systemImage: "tray.full") {
                onOpenScopedDiff(location, node.path, .staged)
            }
            .disabled(change.indexStatus == " " || change.indexStatus == "?")
        }
    }

    @ViewBuilder
    private func pathActions(_ location: WorkspaceFileLocation, path: String) -> some View {
        Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.absolutePath(path)) }
            .keyboardShortcut(ExplorerFileCommand.copyPath.shortcut)
        if !path.isEmpty {
            Button("Copy Relative Path") { AppActions.copy(path) }
                .keyboardShortcut(ExplorerFileCommand.copyRelativePath.shortcut)
        }
        if location.isLocal {
            Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.absolutePath(path)) }
        }
    }

    /// A checkbox that stages the file or everything under the folder, or unstages it when all of it is staged.
    private func stageToggle(_ state: WorkspaceFileChange.StageState, path: String,
                             location: WorkspaceFileLocation) -> some View {
        let name = path.isEmpty ? "all changes" : (path as NSString).lastPathComponent
        return Button {
            model.stageToggle(state, path: path, location: location)
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

    // MARK: File operations

    /// Selects the name without its extension, as Finder and Zed do, so typing replaces only it.
    private func selectNameStem() {
        let stem = model.draft?.isFolder == true ? model.draftName : (model.draftName as NSString).deletingPathExtension
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
        }
    }

    /// Runs a file shortcut on the selected row, or on the Space root when nothing is selected,
    /// while the Files tree of this window has focus. Returns whether the key was used.
    private func handleFileShortcut(_ event: NSEvent) -> Bool {
        guard treeFocused, event.window != nil, event.window === windowBox.window,
              let command = ExplorerFileCommand.allCases.first(where: { $0.matches(event) }) else { return false }
        // Holding Return would rename again right after the name is committed.
        if command == .rename && event.isARepeat { return true }
        return model.perform(command, open: { location, path, preview in
            if model.showsChanges { onOpenDiff(location, path, preview) } else { onOpenFile(location, path, preview) }
        }, findInFolder: onFindInFolder)
    }

    /// Removes the name field, dropping its focus first so a later field does not inherit it.
    private func endDraft() {
        draftFocused = false
        model.draft = nil
    }

    private func commitDraft() {
        guard model.draft != nil else { return }
        draftFocused = false
        model.commitDraft(openFile: onOpenFile)
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
        model.clearListing()
        if let machine { loadRemote(machine) }
    }

    private func refresh() {
        WorkspaceFiles.forgetRecentResults()
        if let machine { loadRemote(machine) }
        else { loadListing() }
    }

    private func loadRemote(_ profile: HerdrMachineProfile) {
        model.isLoading = true
        model.error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.remoteSnapshot(profile) } }.value
            guard machine?.id == profile.id else { return }
            switch result {
            case .success(let snapshot):
                remoteSnapshot = snapshot
                remoteWorkspaceID = snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
            case .failure(let failure):
                model.error = failure.localizedDescription
                model.isLoading = false
            }
        }
    }

    private func loadListing(quietly: Bool = false) {
        model.loadListing(at: location, quietly: quietly)
    }
}

/// Changes to discard once the user confirms.
private struct PendingDiscard {
    let location: WorkspaceFileLocation
    let name: String
    let changes: [WorkspaceFileChange]
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

/// File shortcuts of the Files tree, with Zed's bindings. They act only while the tree has
/// focus, so Command-C, Command-D and the rest keep their usual meaning in terminals and editors.
enum ExplorerFileCommand: CaseIterable {
    case newFile, newFolder, reveal, openInDefaultApp, cut, copy, duplicate, paste
    case copyPath, copyRelativePath, rename, trash, trashAsking, delete, findInFolder
    case undo, redo
    case selectNext, selectPrevious, extendNext, extendPrevious, collapse, expand, collapseAll, open, openPreview, deselect

    /// The key shown in menus.
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
        case .rename: return KeyboardShortcut(.return, modifiers: [])
        case .trash: return KeyboardShortcut(.delete, modifiers: .command)
        case .trashAsking: return KeyboardShortcut(.delete, modifiers: [])
        case .delete: return KeyboardShortcut(.delete, modifiers: [.command, .option])
        case .findInFolder: return KeyboardShortcut("f", modifiers: [.command, .option, .shift])
        case .undo: return KeyboardShortcut("z", modifiers: .command)
        case .redo: return KeyboardShortcut("z", modifiers: [.command, .shift])
        case .selectNext: return KeyboardShortcut(.downArrow, modifiers: [])
        case .selectPrevious: return KeyboardShortcut(.upArrow, modifiers: [])
        case .extendNext: return KeyboardShortcut(.downArrow, modifiers: .shift)
        case .extendPrevious: return KeyboardShortcut(.upArrow, modifiers: .shift)
        case .collapse: return KeyboardShortcut(.leftArrow, modifiers: [])
        case .expand: return KeyboardShortcut(.rightArrow, modifiers: [])
        case .collapseAll: return KeyboardShortcut(.leftArrow, modifiers: .command)
        case .open: return KeyboardShortcut(.downArrow, modifiers: .command)
        case .openPreview: return KeyboardShortcut(.space, modifiers: [])
        case .deselect: return KeyboardShortcut(.escape, modifiers: [])
        }
    }

    /// Further keys for the same command: F2 renames, and the forward delete key trashes, as in Zed.
    private var alternates: [KeyboardShortcut] {
        switch self {
        case .rename: return [KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])]
        case .trashAsking: return [KeyboardShortcut(.deleteForward, modifiers: [])]
        default: return []
        }
    }

    /// Commands that make sense with nothing selected, on the Space root.
    var appliesToRoot: Bool {
        [.newFile, .newFolder, .reveal, .openInDefaultApp, .paste, .copyPath, .findInFolder, .undo, .redo,
         .selectNext, .selectPrevious, .extendNext, .extendPrevious, .collapse, .expand, .collapseAll].contains(self)
    }

    /// Commands that also apply in the Changes tree, which offers no file operations.
    var appliesToChanges: Bool {
        [.copyPath, .copyRelativePath, .findInFolder, .undo, .redo, .selectNext, .selectPrevious, .extendNext, .extendPrevious,
         .collapse, .expand,
         .collapseAll, .open, .openPreview, .deselect].contains(self)
    }

    func matches(_ event: NSEvent) -> Bool {
        ([shortcut] + alternates).contains { Self.shortcut($0, matches: event) }
    }

    private static func shortcut(_ shortcut: KeyboardShortcut, matches event: NSEvent) -> Bool {
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

/// Drops on a row of the Files tree, or on its root: an item of the tree moves there, or is
/// copied with Option held, and files from Finder or other apps are copied.
private struct ExplorerDropDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .plainText]
    /// The row under the pointer, "" for the root, and the folder a drop there goes in.
    let row: String
    let folder: String
    let location: WorkspaceFileLocation
    let model: WorkspaceExplorerModel

    private var copies: Bool { NSEvent.modifierFlags.contains(.option) }

    private func action(_ info: DropInfo) -> WorkspaceDropAction? {
        let dragged = model.draggedItems(info.itemProviders(for: Self.types), location: location)
        // Text is taken only from the tree's own drags, which carry a remote item's path.
        guard dragged != nil || info.hasItemsConforming(to: [.fileURL]) else { return nil }
        return model.dropAction(of: dragged, into: folder, copy: copies)
    }

    func validateDrop(info: DropInfo) -> Bool { action(info) != nil }

    func dropEntered(info: DropInfo) {
        model.dragEntered(row: row, folder: folder, location: location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch action(info) {
        case .move: return DropProposal(operation: .move)
        case .copy: return DropProposal(operation: .copy)
        case nil: return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        model.dragExited(row: row)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dragEnded()
        let providers = info.itemProviders(for: Self.types)
        if let dragged = model.draggedItems(providers, location: location) {
            return model.dropItems(dragged, into: folder, copy: copies, in: location) != nil
        }
        let files = info.itemProviders(for: [.fileURL])
        guard !files.isEmpty else { return false }
        let (folder, location, model, copies) = (folder, location, model, copies)
        Task { @MainActor in
            var paths: [String] = []
            for provider in files {
                if let url = await Self.fileURL(provider) { paths.append(url.path) }
            }
            if let dragged = model.draggedItems(files: paths, location: location) {
                model.dropItems(dragged, into: folder, copy: copies, in: location)
            } else {
                model.importFiles(paths, into: folder, in: location)
            }
        }
        return true
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).flatMap { $0.isFileURL ? $0 as URL : nil })
            }
        }
    }
}

/// Where the tree's content and its first row are in the scrolled view, for the pinned folders.
private struct ExplorerScrollMetrics: PreferenceKey, Equatable {
    static let space = "explorer-scroll"
    var contentTop: CGFloat?
    var rowsTop: CGFloat?

    static var defaultValue = ExplorerScrollMetrics()

    static func reduce(value: inout ExplorerScrollMetrics, nextValue: () -> ExplorerScrollMetrics) {
        let next = nextValue()
        value.contentTop = next.contentTop ?? value.contentTop
        value.rowsTop = next.rowsTop ?? value.rowsTop
    }
}

/// What reveals the active file again in the tree.
private struct ActiveFileReveal: Equatable {
    let file: WorkspaceActiveFile?
    let listed: String?
    let changes: Bool
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

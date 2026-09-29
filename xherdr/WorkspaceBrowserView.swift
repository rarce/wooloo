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
        .alert("Git operation failed", isPresented: Binding(
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
                    expanded: expandedDirectories,
                    identity: treeIdentity(location)
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        treeRoot(location, stageState: listing.hasGit ? stageStates[""] : nil)
                        if !collapsedRoots.contains(treeIdentity(location)) {
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
                            }
                        }
                    }
                    .padding(.vertical, 3)
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
        .contextMenu {
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
                if location.isLocal {
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
            if hasGit, let kind = node.isDirectory ? directoryKind : change?.kind {
                Divider()
                if node.isDirectory || change?.worktreeStatus != " " {
                    Button(node.isDirectory ? "Stage Folder" : "Stage Changes", systemImage: "plus.circle") {
                        runGit(location) { try WorkspaceFiles.stage(node.path, at: location) }
                    }
                }
                if node.isDirectory ? kind != .untracked
                    : (change?.indexStatus != " " && change?.indexStatus != "?") {
                    Button(node.isDirectory ? "Unstage Folder" : "Unstage Changes", systemImage: "minus.circle") {
                        runGit(location) { try WorkspaceFiles.unstage(node.path, at: location) }
                    }
                }
            }
            Divider()
            pathActions(location, path: node.path)
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
            runGit(location) {
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

    private func runGit(_ location: WorkspaceFileLocation, _ operation: @escaping () throws -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            if case .failure(let failure) = result { operationError = failure.localizedDescription }
            // Reload in place, so staging does not blank the tree behind a spinner.
            if self.location?.identity == location.identity { loadListing(quietly: true) }
        }
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
            case .success(let value): listing = value
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
            listingVersion += 1
            TerminalPipelineMetrics.spanShown("file-list", start: start, detail: location.isLocal ? "local" : "ssh")
        }
    }
}

private struct WorkspaceTreeNode {
    let displayName: String
    let path: String
    let isDirectory: Bool
    let children: [WorkspaceTreeNode]

    static func visibleRows(paths: [String], expanded: Set<String>, identity: String) -> [WorkspaceTreeRow] {
        let root = WorkspaceTreeBuilderNode(name: "", path: "")
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !components.isEmpty,
                  !components.contains("."), !components.contains("..") else { continue }
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
        }

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
                                 isDirectory: !children.isEmpty, children: children)
    }

    private static func ordered(_ lhs: WorkspaceTreeNode, _ rhs: WorkspaceTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

private struct WorkspaceTreeRow: Identifiable {
    let node: WorkspaceTreeNode
    let depth: Int
    var id: String { node.path }
}

private final class WorkspaceTreeBuilderNode {
    let name: String
    let path: String
    var children: [String: WorkspaceTreeBuilderNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

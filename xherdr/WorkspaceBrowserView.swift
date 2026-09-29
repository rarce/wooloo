import SwiftUI

struct WorkspaceBrowserView: View {
    let localSnapshot: HerdrSnapshot?
    let localWorkspaceID: String?
    let localSession: String
    let refreshVersion: Int
    let onOpenFile: (WorkspaceFileLocation, String) -> Void
    let onOpenDiff: (WorkspaceFileLocation, String) -> Void

    @State private var machines: [HerdrMachineProfile] = []
    @State private var selectedMachineID = "local"
    @State private var remoteSnapshot: HerdrSnapshot?
    @State private var remoteWorkspaceID: String?
    @State private var listing: WorkspaceFileListing?
    @State private var error: String?
    @State private var isLoading = false
    @State private var showsChanges = false
    @State private var modifiedOnly = false
    @State private var expandedDirectories: Set<String> = []
    @State private var collapsedModifiedDirectories: Set<String> = []
    @State private var collapsedRoots: Set<String> = []
    @State private var selectedItem: String?

    private var isFilteredFiles: Bool { !showsChanges && modifiedOnly }

    private var machine: HerdrMachineProfile? {
        machines.first { $0.id == selectedMachineID }
    }

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
        (location?.identity ?? "none|\(selectedMachineID)|\(workspaceID ?? "")") + "|\(refreshVersion)"
    }

    var body: some View {
        VSplitView {
            explorer
                .frame(minHeight: 190)
            WorkspaceRepositoryView(location: location, refreshVersion: refreshVersion)
                .frame(minHeight: 160)
        }
        .background(Color(red: 0.105, green: 0.115, blue: 0.13))
        .task { loadMachines() }
        .task(id: listingIdentity) { loadListing() }
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPLORER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
                if !showsChanges {
                    Menu {
                        Button {
                            modifiedOnly = false
                        } label: {
                            Label("All files", systemImage: modifiedOnly ? "doc.text" : "checkmark")
                        }
                        Button {
                            modifiedOnly = true
                        } label: {
                            Label("Modified only", systemImage: modifiedOnly ? "checkmark" : "line.3.horizontal.decrease")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                            if modifiedOnly { Text("Modified") }
                        }
                        .font(.system(size: 10, weight: modifiedOnly ? .semibold : .regular))
                        .foregroundStyle(modifiedOnly ? Color.cyan : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(modifiedOnly ? "Showing modified files" : "Showing all files")
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Refresh files and changes")
            }
            .padding(.horizontal, 11)
            .frame(height: 35)
            Divider()

            HStack(spacing: 5) {
                Menu {
                    Button("Local") { selectMachine("local") }
                    ForEach(machines) { profile in
                        Button(profile.label) { selectMachine(profile.id) }
                    }
                } label: {
                    Label(machine?.label ?? "Local", systemImage: "desktopcomputer")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 27)

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
                .frame(height: 26)
            }

            HStack(spacing: 2) {
                segment("Files", icon: "doc.text", selected: !showsChanges) { showsChanges = false }
                segment("Changes", icon: "arrow.left.arrow.right", selected: showsChanges) { showsChanges = true }
            }
            .padding(4)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let listing, let location {
                let changedPaths = Set(listing.changes.map(\.path))
                let paths = showsChanges ? listing.changes.map(\.path)
                    : (modifiedOnly ? listing.files.filter { changedPaths.contains($0) } : listing.files)
                let changesByPath = Dictionary(listing.changes.map { ($0.path, $0) },
                                               uniquingKeysWith: { first, _ in first })
                let rows = WorkspaceTreeNode.visibleRows(
                    paths: paths,
                    expanded: expandedDirectories,
                    collapsed: collapsedModifiedDirectories,
                    expandAll: isFilteredFiles,
                    identity: treeIdentity(location)
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        treeRoot(location)
                        if !collapsedRoots.contains(treeIdentity(location)) {
                            if (showsChanges || isFilteredFiles) && !listing.hasGit {
                                hint("No Git repository in this Space")
                            } else if paths.isEmpty {
                                hint(showsChanges ? "No changes" : (modifiedOnly ? "No modified files" : "No files"))
                            }
                            ForEach(rows) { row in
                                treeRow(row, location: location,
                                        change: changesByPath[row.node.path])
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
        }
        .background(Color(red: 0.105, green: 0.115, blue: 0.13))
    }

    private func segment(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(selected ? Color.white.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func hint(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(10)
    }

    private func treeIdentity(_ location: WorkspaceFileLocation) -> String {
        "\(location.identity)|\(showsChanges ? "changes" : (modifiedOnly ? "modified" : "files"))"
    }

    private func treeRoot(_ location: WorkspaceFileLocation) -> some View {
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
            .font(.system(size: 11))
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(location.root)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func treeRow(_ row: WorkspaceTreeRow, location: WorkspaceFileLocation,
                         change: WorkspaceFileChange?) -> some View {
        let node = row.node
        let identity = treeIdentity(location) + "|" + node.path
        let isExpanded = isFilteredFiles
            ? !collapsedModifiedDirectories.contains(identity) : expandedDirectories.contains(identity)
        let isSelected = selectedItem == identity
        return Button {
            if node.isDirectory {
                if isFilteredFiles {
                    if isExpanded { collapsedModifiedDirectories.insert(identity) }
                    else { collapsedModifiedDirectories.remove(identity) }
                } else if isExpanded {
                    expandedDirectories.remove(identity)
                } else {
                    expandedDirectories.insert(identity)
                }
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
                    .font(.system(size: 11))
                    .frame(width: 17)
                    .foregroundStyle(node.isDirectory ? Color.secondary : (showsChanges ? .cyan : .secondary))
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if (showsChanges || isFilteredFiles), let change {
                    Text(change.statusLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.leading, CGFloat(row.depth) * 19 + 11)
            .padding(.trailing, 8)
            .frame(height: 23)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                ForEach(0..<row.depth, id: \.self) { level in
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, CGFloat(level) * 19 + 29)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .help(node.path)
        .accessibilityValue(node.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "File")
    }

    private func fileIcon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc.text"
        }
    }

    private func selectMachine(_ id: String) {
        selectedMachineID = id
        remoteSnapshot = nil
        remoteWorkspaceID = nil
        listing = nil
        error = nil
        if let machine { loadRemote(machine) }
    }

    private func refresh() {
        loadMachines()
        if let machine { loadRemote(machine) }
        else { loadListing() }
    }

    private func loadMachines() {
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.machines() } }.value
            if case .success(let profiles) = result { machines = profiles }
        }
    }

    private func loadRemote(_ profile: HerdrMachineProfile) {
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.remoteSnapshot(profile) } }.value
            guard selectedMachineID == profile.id else { return }
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

    private func loadListing() {
        guard let location else { listing = nil; return }
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.listing(at: location) } }.value
            guard self.location?.identity == location.identity else { return }
            switch result {
            case .success(let value): listing = value
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct WorkspaceTreeNode {
    let displayName: String
    let path: String
    let isDirectory: Bool
    let children: [WorkspaceTreeNode]

    static func visibleRows(paths: [String], expanded: Set<String>, collapsed: Set<String>,
                            expandAll: Bool, identity: String) -> [WorkspaceTreeRow] {
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
                if node.isDirectory && (expandAll ? !collapsed.contains(key) : expanded.contains(key)) {
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

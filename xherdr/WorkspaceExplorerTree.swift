import Foundation

/// The Files and Changes trees' expanded folders, selection and folders created empty. Tree
/// keys are "<tree identity>|<path>", where the identity names the Space and the tree.
struct WorkspaceExplorerTree {
    var expanded: Set<String> = []
    /// Tree identities whose root is collapsed.
    var collapsedRoots: Set<String> = []
    var selected: String?
    /// Folders created or pasted empty, which Git does not list, by location identity.
    var createdDirectories: [String: Set<String>] = [:]

    mutating func toggle(_ key: String, isExpanded: Bool) {
        if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
    }

    mutating func collapseAll(_ identity: String) {
        expanded = expanded.filter { !$0.hasPrefix(identity + "|") }
    }

    /// Opens the root and `folder` with every folder above it; "" is the root itself.
    mutating func expand(_ folder: String, in identity: String) {
        collapsedRoots.remove(identity)
        var parent = folder
        while !parent.isEmpty {
            expanded.insert(identity + "|" + parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    /// Expands the folders above `path` and selects it.
    mutating func reveal(_ path: String, in identity: String) {
        expand((path as NSString).deletingLastPathComponent, in: identity)
        selected = identity + "|" + path
    }

    /// Paths of the expanded folders of the tree `identity`.
    func expandedFolders(in identity: String) -> [String] {
        let prefix = identity + "|"
        return expanded.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// The selected item's path when it belongs to the tree `identity`.
    func selectedPath(in identity: String) -> String? {
        let prefix = identity + "|"
        return selected.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    /// Carries expanded folders, the selection and created folders over to a renamed item.
    mutating func move(from original: String, to renamed: String, in identity: String, location: String) {
        func moved(_ key: String, prefix: String) -> String? {
            guard key.hasPrefix(prefix) else { return nil }
            let rest = key.dropFirst(prefix.count)
            if rest == original { return prefix + renamed }
            if rest.hasPrefix(original + "/") { return prefix + renamed + rest.dropFirst(original.count) }
            return nil
        }
        let prefix = identity + "|"
        expanded = Set(expanded.map { moved($0, prefix: prefix) ?? $0 })
        if let selected { self.selected = moved(selected, prefix: prefix) ?? selected }
        if let created = createdDirectories[location] {
            createdDirectories[location] = Set(created.map { moved($0, prefix: "") ?? $0 })
        }
    }

    /// Drops a deleted item and everything under it from the created folders.
    mutating func forget(_ path: String, location: String) {
        createdDirectories[location] = createdDirectories[location]?.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    /// Keeps only the created folders that still exist.
    mutating func pruneCreated(location: String, exists: (String) -> Bool) {
        guard let created = createdDirectories[location] else { return }
        createdDirectories[location] = created.filter(exists)
    }
}

/// What the explorer copied or cut, to paste on the same machine.
struct WorkspaceFileClipboard {
    /// nil for this Mac.
    let machineID: String?
    let paths: [String]
    let isCut: Bool
    /// The general pasteboard's change count after a local copy; copying anything else later replaces this.
    let changeCount: Int
}

/// Decisions of the Files and Changes trees that do not depend on the view.
enum WorkspaceExplorer {
    /// Stage state of every changed file, of each folder above one, and of the root under "".
    static func stageStates(_ changes: [WorkspaceFileChange]) -> [String: WorkspaceFileChange.StageState] {
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

    /// Strongest change kind under each directory, keyed by directory path.
    static func directoryKinds(_ changes: [WorkspaceFileChange]) -> [String: WorkspaceFileChange.Kind] {
        var kinds: [String: WorkspaceFileChange.Kind] = [:]
        for change in changes {
            var directory = (change.path as NSString).deletingLastPathComponent
            while !directory.isEmpty {
                if let existing = kinds[directory], existing.folderPriority >= change.kind.folderPriority { break }
                kinds[directory] = change.kind
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return kinds
    }

    /// The folders pinned at the top of the tree while it scrolls, outermost first, as in VS
    /// Code: the folders holding the row that shows just below them. `top` is the index of the
    /// row at the top of the view. A folder lets go once the row below it is no longer its own.
    static func stickyRows(_ rows: [WorkspaceTreeRow], top: Int, limit: Int = 5) -> [WorkspaceTreeRow] {
        guard top >= 0 else { return [] }
        var sticky: [WorkspaceTreeRow] = []
        for depth in 1...max(limit, 1) {
            let index = top + depth
            guard index < rows.count, rows[index].depth > depth,
                  // The nearest row above at this depth is the folder holding it.
                  let folder = rows[..<index].last(where: { $0.depth == depth }), folder.node.isDirectory,
                  rows[index].node.path.hasPrefix(folder.node.path + "/") else { break }
            sticky.append(folder)
        }
        return sticky
    }

    static func fileIcon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc.text"
        }
    }

    /// The files and folders of the Files tree: the listing's, the ignored folders Git lists
    /// without contents, what was read of the expanded ones, and folders created empty.
    static func filesTreeEntries(_ listing: WorkspaceFileListing, ignoredContents: [String: WorkspaceFolderContents],
                                 created: Set<String>) -> (paths: [String], directories: Set<String>) {
        var paths = listing.files
        var directories = created.union(listing.ignored.directories)
        for contents in ignoredContents.values {
            paths += contents.files
            directories.formUnion(contents.directories)
        }
        return (paths, directories)
    }

    /// Ignored folders among `expanded` whose contents have not been read yet, parents first.
    static func ignoredFoldersToRead(expanded: [String], ignored: WorkspaceIgnoredEntries,
                                     read: Set<String>, limit: Int = 50) -> [String] {
        Array(expanded.filter { !read.contains($0) && ignored.contains($0) }.sorted().prefix(limit))
    }

    /// Whether `path` is a folder: the root, a folder created empty, or one with listed files.
    static func isDirectory(_ path: String, directories: Set<String>, created: Set<String>) -> Bool {
        path.isEmpty || created.contains(path) || directories.contains(path)
    }

    /// The folder new items go in for a selected item: the item itself when it is a folder.
    static func folder(for path: String, isDirectory: Bool) -> String {
        isDirectory ? path : (path as NSString).deletingLastPathComponent
    }

    /// The path of a new item named `name` in `folder`; "" is the root.
    static func path(of name: String, in folder: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// What a paste copies or moves: the explorer's own clipboard when it was filled on this
    /// machine and, locally, nothing was copied since; otherwise files copied in Finder.
    static func pasteSources(clipboard: WorkspaceFileClipboard?, location: WorkspaceFileLocation,
                             pasteboardChangeCount: Int, pasteboardFiles: () -> [String]) -> (paths: [String], move: Bool) {
        if let clipboard, clipboard.machineID == location.machine?.id,
           !location.isLocal || clipboard.changeCount == pasteboardChangeCount {
            return (clipboard.paths, clipboard.isCut)
        }
        return location.isLocal ? (pasteboardFiles(), false) : ([], false)
    }
}

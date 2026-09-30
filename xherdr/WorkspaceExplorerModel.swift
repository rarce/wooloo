import AppKit

/// A file or folder chosen for deletion, waiting for confirmation.
struct WorkspaceFileTarget {
    let location: WorkspaceFileLocation
    let path: String
    let isDirectory: Bool
}

/// A file or folder being named in the tree: a new one, or one being renamed.
struct WorkspaceFileDraft {
    let location: WorkspaceFileLocation
    /// The folder it is created in; "" is the Space root.
    let folder: String
    let isFolder: Bool
    /// The item being renamed; nil for a new one.
    let renaming: String?
    var hasHadFocus = false
}

/// Effects of explorer commands beyond files and Git, replaceable in tests.
struct WorkspaceExplorerEffects {
    var copy: (String) -> Void = { AppActions.copy($0) }
    var reveal: (String) -> Void = { AppActions.reveal($0) }
    var openInDefaultApp: (String) -> Void = { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
    /// Puts files on the general pasteboard, so Finder can paste them, and returns its change count.
    var putFilesOnPasteboard: ([String]) -> Int = { paths in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        return pasteboard.changeCount
    }
    var pasteboardChangeCount: () -> Int = { NSPasteboard.general.changeCount }
    /// Files copied on the general pasteboard, such as in Finder.
    var pasteboardFiles: () -> [String] = {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .map(\.path) ?? []
    }
}

/// The explorer's listing, trees, name field, clipboard and the file and Git operations run
/// from it. `WorkspaceBrowserView` renders it and keeps focus and windows to itself.
@MainActor
final class WorkspaceExplorerModel: ObservableObject {
    @Published var listing: WorkspaceFileListing?
    @Published var error: String?
    @Published var isLoading = false
    @Published var showsChanges = false
    @Published var modifiedOnly = false
    @Published var tree = WorkspaceExplorerTree()
    @Published var operationError: String?
    @Published private(set) var clipboard: WorkspaceFileClipboard?
    /// A file or folder being named in place in the tree, before it is created.
    @Published var draft: WorkspaceFileDraft?
    @Published var draftName = ""
    @Published var pendingDelete: WorkspaceFileTarget?
    /// Bumped on every listing load so the Git bar refreshes with the explorer.
    @Published private(set) var listingVersion = 0
    /// What was read of expanded ignored folders, by folder path, for the current listing.
    @Published private(set) var ignoredContents: [String: WorkspaceFolderContents] = [:]
    /// Bumped when `ignoredContents` changes, so the Files tree is rebuilt.
    @Published private(set) var ignoredContentsVersion = 0
    /// The location of the last listing asked for.
    private(set) var location: WorkspaceFileLocation?
    /// The last operation started, with the reload that follows it, for tests to wait on.
    private(set) var lastOperation: Task<Void, Never>?
    private let treeCache = WorkspaceTreeCache()
    var effects = WorkspaceExplorerEffects()

    var isFilteredFiles: Bool { !showsChanges && modifiedOnly }

    /// The modified-only filter shares the file tree's expanded folders, so switching keeps the layout.
    func treeIdentity(_ location: WorkspaceFileLocation) -> String {
        "\(location.identity)|\(showsChanges ? "changes" : "files")"
    }

    // MARK: Listing

    func clearListing() {
        listing = nil
        error = nil
    }

    /// Loads the files and changes of `location`; `quietly` keeps the tree shown instead of a spinner.
    @discardableResult
    func loadListing(at location: WorkspaceFileLocation?, quietly: Bool = false) -> Task<Void, Never>? {
        self.location = location
        guard let location else { listing = nil; return nil }
        isLoading = !quietly
        error = nil
        let start = TerminalPipelineMetrics.now()
        let created = tree.createdDirectories[location.identity] ?? []
        let expanded = tree.expandedFolders(in: "\(location.identity)|files")
        let exists = { Self.folderExists($0, at: location) }
        return Task {
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

    /// Whether a created folder still exists; on an SSH machine it is assumed to.
    nonisolated private static func folderExists(_ path: String, at location: WorkspaceFileLocation) -> Bool {
        guard location.isLocal else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: location.absolutePath(path), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The tree the explorer shows: every file, the modified ones, or the changes.
    func shownTree(_ listing: WorkspaceFileListing, location: WorkspaceFileLocation) -> WorkspaceTree {
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
    func filesTree(_ listing: WorkspaceFileListing, location: WorkspaceFileLocation) -> WorkspaceTree {
        let created = tree.createdDirectories[location.identity] ?? []
        return treeCache.tree(.files, listing: listingVersion, contents: ignoredContentsVersion, directories: created) {
            let entries = WorkspaceExplorer.filesTreeEntries(listing, ignoredContents: ignoredContents, created: created)
            return WorkspaceTree(paths: entries.paths, directories: entries.directories)
        }
    }

    /// Opens or closes a folder; an ignored folder opened in the Files tree has its contents read.
    @discardableResult
    func toggleDirectory(_ identity: String, path: String, isExpanded: Bool,
                         location: WorkspaceFileLocation) -> Task<Void, Never>? {
        tree.toggle(identity, isExpanded: isExpanded)
        guard !isExpanded, !showsChanges else { return nil }
        return readIgnoredFolders([path], at: location)
    }

    /// Reads the contents of expanded ignored folders, which the listing leaves out.
    @discardableResult
    func readIgnoredFolders(_ folders: [String], at location: WorkspaceFileLocation) -> Task<Void, Never>? {
        guard let listing else { return nil }
        let toRead = WorkspaceExplorer.ignoredFoldersToRead(expanded: folders, ignored: listing.ignored,
                                                           read: Set(ignoredContents.keys))
        guard !toRead.isEmpty else { return nil }
        let version = listingVersion
        return Task {
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

    func collapseAll(_ location: WorkspaceFileLocation) {
        tree.collapseAll(treeIdentity(location))
    }

    // MARK: Operations

    /// Runs a Git or file operation off the main thread, then reloads the listing unless told not to.
    @discardableResult
    func runOperation<Value>(_ location: WorkspaceFileLocation, reloads: Bool = true,
                             _ operation: @escaping () throws -> Value,
                             completion: @escaping (Value) -> Void = { _ in }) -> Task<Void, Never> {
        let task = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            switch result {
            case .success(let value): completion(value)
            case .failure(let failure): operationError = failure.localizedDescription
            }
            // Reload in place, so staging does not blank the tree behind a spinner.
            if reloads, self.location?.identity == location.identity {
                await loadListing(at: location, quietly: true)?.value
            }
        }
        lastOperation = task
        return task
    }

    /// The stage checkbox of a file or folder ("" is the root): unstages it when all of it is
    /// staged, and stages it otherwise.
    @discardableResult
    func stageToggle(_ state: WorkspaceFileChange.StageState, path: String,
                     location: WorkspaceFileLocation) -> Task<Void, Never> {
        runOperation(location) {
            if state == .all { try WorkspaceFiles.unstage(path, at: location) }
            else { try WorkspaceFiles.stage(path, at: location) }
        }
    }

    /// Shows a name field in the tree, under `folder` ("" is the Space root), for a new item or
    /// for renaming the item at `renaming`.
    func startDraft(in folder: String, isFolder: Bool, at location: WorkspaceFileLocation, renaming: String? = nil) {
        tree.expand(folder, in: treeIdentity(location))
        draftName = renaming.map { ($0 as NSString).lastPathComponent } ?? ""
        draft = WorkspaceFileDraft(location: location, folder: folder, isFolder: isFolder, renaming: renaming)
    }

    func startRename(_ path: String, isDirectory: Bool, at location: WorkspaceFileLocation) {
        startDraft(in: (path as NSString).deletingLastPathComponent, isFolder: isDirectory, at: location, renaming: path)
    }

    /// Creates or renames what the name field names; an empty or unchanged name only closes it.
    /// A new file is opened with `openFile`.
    @discardableResult
    func commitDraft(openFile: @escaping (WorkspaceFileLocation, String, Bool) -> Void) -> Task<Void, Never>? {
        guard let draft else { return nil }
        self.draft = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let location = draft.location
        if let original = draft.renaming {
            guard name != (original as NSString).lastPathComponent else { return nil }
            return runOperation(location) { try WorkspaceFiles.renameItem(original, to: name, at: location) } completion: {
                self.tree.move(from: original, to: $0, in: self.treeIdentity(location), location: location.identity)
            }
        }
        let path = WorkspaceExplorer.path(of: name, in: draft.folder)
        return runOperation(location) {
            if draft.isFolder { try WorkspaceFiles.createFolder(path, at: location) }
            else { try WorkspaceFiles.createFile(path, at: location) }
        } completion: {
            if draft.isFolder { self.tree.createdDirectories[location.identity, default: []].insert(path) }
            self.reveal(path, in: location)
            if !draft.isFolder { openFile(location, path, false) }
        }
    }

    /// Runs a file shortcut on the Files tree's selected row, or on the Space root when nothing
    /// is selected. Returns whether the key was used.
    func perform(_ command: ExplorerFileCommand) -> Bool {
        guard !showsChanges, draft == nil, pendingDelete == nil, let listing, let location else { return false }
        let path = tree.selectedPath(in: treeIdentity(location)) ?? ""
        guard !path.isEmpty || command.appliesToRoot else { return false }
        let isDirectory = WorkspaceExplorer.isDirectory(path, directories: filesTree(listing, location: location).directories,
                                                        created: tree.createdDirectories[location.identity] ?? [])
        let folder = WorkspaceExplorer.folder(for: path, isDirectory: isDirectory)
        let absolute = location.absolutePath(path)
        switch command {
        case .newFile: startDraft(in: folder, isFolder: false, at: location)
        case .newFolder: startDraft(in: folder, isFolder: true, at: location)
        case .reveal, .openInDefaultApp, .trash:
            guard location.isLocal else { return false }
            if command == .reveal { effects.reveal(absolute) }
            else if command == .trash { trash(path, in: location) }
            else { effects.openInDefaultApp(absolute) }
        case .cut, .copy: copyItem(path, in: location, cut: command == .cut)
        case .duplicate: duplicate(path, in: location)
        case .paste: paste(into: folder, in: location)
        case .copyPath: effects.copy(absolute)
        case .copyRelativePath: effects.copy(path)
        case .rename: startRename(path, isDirectory: isDirectory, at: location)
        case .delete: pendingDelete = WorkspaceFileTarget(location: location, path: path, isDirectory: isDirectory)
        }
        return true
    }

    func copyItem(_ path: String, in location: WorkspaceFileLocation, cut: Bool) {
        let absolute = location.absolutePath(path)
        // Local items also go on the general pasteboard, so Finder can paste them.
        let changeCount = location.isLocal ? effects.putFilesOnPasteboard([absolute]) : 0
        clipboard = WorkspaceFileClipboard(machineID: location.machine?.id, paths: [absolute],
                                           isCut: cut, changeCount: changeCount)
    }

    /// Pastes what the explorer copied or cut on this machine, or, in a local Space, files
    /// copied in Finder since then.
    @discardableResult
    func paste(into directory: String, in location: WorkspaceFileLocation) -> Task<Void, Never>? {
        let (sources, move) = WorkspaceExplorer.pasteSources(
            clipboard: clipboard, location: location, pasteboardChangeCount: effects.pasteboardChangeCount(),
            pasteboardFiles: effects.pasteboardFiles
        )
        guard !sources.isEmpty else {
            operationError = "Nothing to paste. Copy or cut a file on \(location.machineLabel) first."
            return nil
        }
        return runOperation(location) { try WorkspaceFiles.paste(sources, into: directory, move: move, at: location) } completion: {
            if move { self.clipboard = nil }
            self.placePasted($0, in: location)
        }
    }

    @discardableResult
    func duplicate(_ path: String, in location: WorkspaceFileLocation) -> Task<Void, Never> {
        let source = location.absolutePath(path)
        let folder = (path as NSString).deletingLastPathComponent
        return runOperation(location) { try WorkspaceFiles.paste([source], into: folder, move: false, at: location) } completion: {
            self.placePasted($0, in: location)
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

    @discardableResult
    func trash(_ path: String, in location: WorkspaceFileLocation) -> Task<Void, Never> {
        runOperation(location) { try WorkspaceFiles.trash(path, at: location) } completion: {
            self.tree.forget(path, location: location.identity)
        }
    }

    @discardableResult
    func delete(_ target: WorkspaceFileTarget) -> Task<Void, Never> {
        let location = target.location
        return runOperation(location) { try WorkspaceFiles.delete(target.path, at: location) } completion: {
            self.tree.forget(target.path, location: location.identity)
        }
    }

    /// Expands the folders above `path` and selects it.
    private func reveal(_ path: String, in location: WorkspaceFileLocation) {
        tree.reveal(path, in: treeIdentity(location))
    }
}

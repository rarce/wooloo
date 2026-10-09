import AppKit

/// Files and folders chosen for deletion, waiting for confirmation.
struct WorkspaceFileTarget {
    let location: WorkspaceFileLocation
    let paths: [String]
    /// Whether the one item is a folder.
    let isDirectory: Bool
    /// Deleted for good rather than moved to the Trash.
    var permanently = true

    init(location: WorkspaceFileLocation, paths: [String], isDirectory: Bool, permanently: Bool = true) {
        self.location = location
        self.paths = paths
        self.isDirectory = isDirectory
        self.permanently = permanently
    }

    init(location: WorkspaceFileLocation, path: String, isDirectory: Bool, permanently: Bool = true) {
        self.init(location: location, paths: [path], isDirectory: isDirectory, permanently: permanently)
    }

    var path: String { paths[0] }
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

/// A file operation of the explorer that can be undone.
enum WorkspaceFileEdit: Equatable {
    /// Items that appeared: new, pasted, duplicated or dropped. Undoing moves them to the Trash.
    case created([String])
    /// Items moved or renamed. Undoing moves them back.
    case moved([WorkspaceMove])
    /// Items moved to the Trash. Undoing puts them back.
    case trashed([WorkspaceTrashedItem])

    var isEmpty: Bool {
        switch self {
        case .created(let paths): return paths.isEmpty
        case .moved(let moves): return moves.isEmpty
        case .trashed(let items): return items.isEmpty
        }
    }
}

struct WorkspaceMove: Equatable {
    let from: String
    let to: String
}

struct WorkspaceTrashedItem: Equatable {
    let path: String
    /// Where the item is in the Trash.
    let trashPath: String
}

/// An undoable operation and the name menus give it, such as "Rename".
struct WorkspaceUndoEntry {
    let name: String
    let edit: WorkspaceFileEdit
}

/// What a drop on the explorer does.
enum WorkspaceDropAction {
    case move, copy
}

/// The file of the active editor tab, which the explorer selects.
struct WorkspaceActiveFile: Hashable {
    let location: WorkspaceFileLocation
    let path: String
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
    /// What was read of expanded ignored or linked folders, by folder path, for the current listing.
    @Published private(set) var ignoredContents: [String: WorkspaceFolderContents] = [:]
    /// Bumped when `ignoredContents` changes, so the Files tree is rebuilt.
    @Published private(set) var ignoredContentsVersion = 0
    /// The location of the last listing asked for.
    private(set) var location: WorkspaceFileLocation?
    /// The location `listing` belongs to; the previous Space's stays shown while the next loads.
    @Published private(set) var listedIdentity: String?
    /// The last operation started, with the reload that follows it, for tests to wait on.
    private(set) var lastOperation: Task<Void, Never>?
    private let treeCache = WorkspaceTreeCache()
    private var listingTask: Task<Void, Never>?
    private var listingRequest = 0
    private var locationGeneration = 0
    /// Injectable so concurrency and SSH polling can be checked without a live server.
    var readListing: (WorkspaceFileLocation) throws -> WorkspaceFileListing = WorkspaceFiles.listing
    private var watcher: WorkspaceFileWatcher?
    private var monitoringToken: UUID?
    private var monitoredLocation: WorkspaceFileLocation?
    private var gitWatchPaths: [String] = []
    private var pendingRefresh: Task<Void, Never>?
    private var needsRefresh = false
    private var applicationIsActive = true
    /// Refreshes pause while the app is inactive; tests of a mounted browser turn this off, since
    /// the test host's activation can change at any moment.
    var pausesWhileInactive = true
    var isWatchingFiles: Bool { watcher != nil }
    var effects = WorkspaceExplorerEffects()

    var isFilteredFiles: Bool { !showsChanges && modifiedOnly }

    /// The modified-only filter shares the file tree's expanded folders, so switching keeps the layout.
    func treeIdentity(_ location: WorkspaceFileLocation) -> String {
        "\(location.identity)|\(showsChanges ? "changes" : "files")"
    }

    // MARK: Listing

    func clearListing() {
        locationGeneration += 1
        listingRequest += 1
        location = nil
        listing = nil
        listedIdentity = nil
        error = nil
    }

    /// Loads the files and changes of `location`; `quietly` keeps the tree shown instead of a spinner,
    /// as does reloading the location already shown (e.g. after a save).
    @discardableResult
    func loadListing(at location: WorkspaceFileLocation?, quietly: Bool = false) -> Task<Void, Never>? {
        let isReload = listing != nil && self.location?.identity == location?.identity
        if self.location?.identity != location?.identity { locationGeneration += 1 }
        self.location = location
        listingRequest += 1
        guard location != nil else { clearListing(); isLoading = false; return nil }
        isLoading = !quietly && !isReload
        error = nil
        // Requests made during a load share its worker, which performs a follow-up load.
        if let listingTask { return listingTask }
        let task = Task {
            defer { listingTask = nil }
            while let location = self.location {
                let request = listingRequest
                let generation = locationGeneration
                await readAndPublishListing(at: location, generation: generation)
                if request == listingRequest { break }
            }
        }
        listingTask = task
        return task
    }

    private func readAndPublishListing(at location: WorkspaceFileLocation, generation: Int) async {
        let start = TerminalPipelineMetrics.now()
        let created = tree.createdDirectories[location.identity] ?? []
        let expanded = tree.expandedFolders(in: "\(location.identity)|files")
        let exists = { Self.folderExists($0, at: location) }
        let readListing = readListing
        // The Files tree is built here too, so a large Space is not sorted on the main thread.
        let result = await BlockingWork.run {
            Result { () -> (WorkspaceFileListing, WorkspaceTree, Set<String>, [String: WorkspaceFolderContents]) in
                WorkspaceFiles.forgetRecentResults(at: location)
                let listing = try readListing(location)
                let kept = created.filter(exists)
                // Expanded ignored and linked folders are read again, so they stay open across reloads.
                let folders = WorkspaceExplorer.ignoredFoldersToRead(expanded: expanded, ignored: listing.ignored, read: [],
                                                                      symbolicLinkDirectories: Set(listing.symbolicLinks.filter { $0.value.isDirectory }.keys))
                let contents = Self.readFolders(folders, at: location)
                let entries = WorkspaceExplorer.filesTreeEntries(listing, ignoredContents: contents, created: kept)
                return (listing, WorkspaceTree(paths: entries.paths, directories: entries.directories, symbolicLinks: entries.symbolicLinks), kept, contents)
            }
        }
        guard locationGeneration == generation, self.location?.identity == location.identity else { return }
        var filesTree: (tree: WorkspaceTree, directories: Set<String>)?
        switch result {
        case .success(let (value, builtTree, kept, contents)):
            listing = value
            listedIdentity = location.identity
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

    // MARK: Synchronization

    /// Owned by the visible browser's SwiftUI task. SSH polls only while active; local Spaces
    /// use recursive events, with polling as a fallback if a stream cannot be started.
    func monitor(at location: WorkspaceFileLocation?, pollingInterval: Duration = .seconds(3)) async {
        stopMonitoring()
        guard let location else { return }
        let token = UUID()
        monitoringToken = token
        monitoredLocation = location
        defer { if monitoringToken == token { stopMonitoring() } }
        if location.isLocal {
            await installLocalWatcher(at: location, token: token)
        }
        while !Task.isCancelled, monitoringToken == token {
            do { try await Task.sleep(for: pollingInterval) } catch { break }
            guard !Task.isCancelled, monitoringToken == token else { break }
            // A repository may have been initialized or removed outside the app since the
            // Space opened. Retry unavailable streams and update newly discovered Git paths.
            if location.isLocal, watcher == nil
                || (listedIdentity == location.identity && (listing?.hasGit == true) != !gitWatchPaths.isEmpty) {
                await installLocalWatcher(at: location, token: token)
            }
            if !location.isLocal || watcher == nil { requestRefresh() }
        }
    }

    private func installLocalWatcher(at location: WorkspaceFileLocation, token: UUID) async {
        guard let paths = await BlockingWork.run(priority: .utility, {
            Optional(WorkspaceFiles.localGitWatchPaths(at: location).map(WorkspaceFileWatcher.canonicalPath))
        }) else { return }
        guard !Task.isCancelled, monitoringToken == token else { return }
        gitWatchPaths = paths
        let next = WorkspaceFileWatcher(paths: [location.root] + paths) { [weak self] events in
            guard let self, self.monitoringToken == token else { return }
            if self.eventsAffectListing(events, at: location) { self.requestRefresh() }
        }
        watcher?.stop()
        watcher = next
        // Reconcile edits made while discovering the metadata paths and installing the stream.
        requestRefresh()
    }

    func stopMonitoring() {
        monitoringToken = nil
        monitoredLocation = nil
        watcher?.stop()
        watcher = nil
        gitWatchPaths = []
        pendingRefresh?.cancel()
        pendingRefresh = nil
        needsRefresh = false
    }

    func setApplicationActive(_ active: Bool) {
        applicationIsActive = active || !pausesWhileInactive
        if active { requestRefresh() }
    }

    /// A bounded batching window: continuous writes cannot postpone the refresh forever.
    func requestRefresh() {
        guard monitoredLocation != nil else { return }
        needsRefresh = true
        guard applicationIsActive, draft == nil, pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.pendingRefresh = nil
            self.refreshIfNeeded()
        }
    }

    /// Also called when the inline name field closes, to apply changes held during editing.
    func refreshIfNeeded() {
        guard needsRefresh, applicationIsActive, draft == nil, let location = monitoredLocation else { return }
        needsRefresh = false
        loadListing(at: location, quietly: true)
    }

    private func eventsAffectListing(_ events: [WorkspaceFileWatcher.Event], at location: WorkspaceFileLocation) -> Bool {
        let root = WorkspaceFileWatcher.canonicalPath(location.root)
        return events.contains { event in
            if event.requiresRescan { return true }
            let path = event.path
            if let gitPath = gitWatchPaths.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                let relative = String(path.dropFirst(gitPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // Locks, object writes and logs do not affect the displayed status. Watching
                // index/HEAD's directory still catches their atomic replacement by Git.
                if relative.hasSuffix(".lock") { return false }
                let first = relative.split(separator: "/").first.map(String.init) ?? ""
                return !["objects", "logs", "hooks", "COMMIT_EDITMSG"].contains(first)
            }
            guard path == root || path.hasPrefix(root + "/") else { return false }
            let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
            // Ignore build/dependency churn in collapsed ignored folders. Expanded folders
            // remain live, and events on the folder itself still refresh additions/deletions.
            if let listing, listedIdentity == location.identity {
                for folder in listing.ignored.directories where relative.hasPrefix(folder + "/") {
                    if !tree.expanded.contains("\(location.identity)|files|\(folder)") { return false }
                }
            }
            return true
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
            return WorkspaceTree(paths: entries.paths, directories: entries.directories, symbolicLinks: entries.symbolicLinks)
        }
    }

    /// Opens or closes a folder; an ignored or linked folder opened in the Files tree has its contents read.
    @discardableResult
    func toggleDirectory(_ identity: String, path: String, isExpanded: Bool,
                         location: WorkspaceFileLocation) -> Task<Void, Never>? {
        tree.toggle(identity, isExpanded: isExpanded)
        guard !isExpanded, !showsChanges else { return nil }
        return readIgnoredFolders([path], at: location)
    }

    /// Reads the contents of expanded ignored and linked folders, which the listing leaves out.
    @discardableResult
    func readIgnoredFolders(_ folders: [String], at location: WorkspaceFileLocation) -> Task<Void, Never>? {
        guard let listing else { return nil }
        let toRead = WorkspaceExplorer.ignoredFoldersToRead(expanded: folders, ignored: listing.ignored,
                                                           read: Set(ignoredContents.keys),
                                                           symbolicLinkDirectories: Set(listing.symbolicLinks.filter { $0.value.isDirectory }.keys)
                                                               .union(ignoredContents.values.flatMap { $0.symbolicLinks.filter { $0.value.isDirectory }.keys }))
        guard !toRead.isEmpty else { return nil }
        let version = listingVersion
        return Task {
            guard let results = await BlockingWork.run({
                Optional(toRead.map { folder in (folder, Result { try WorkspaceFiles.folderContents(folder, at: location) }) })
            }) else { return }
            guard self.location?.identity == location.identity, listingVersion == version else { return }
            for (folder, result) in results {
                switch result {
                case .success(let contents): ignoredContents[folder] = contents
                case .failure(let failure):
                    tree.expanded.remove("\(location.identity)|files|" + folder)
                    operationError = "\(folder): \(failure.localizedDescription)"
                }
            }
            ignoredContentsVersion += 1
        }
    }

    /// Folders that cannot be read, such as one deleted since, are left out.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    nonisolated private static func readFolders(_ folders: [String],
                                                at location: WorkspaceFileLocation) -> [String: WorkspaceFolderContents] {
        var read: [String: WorkspaceFolderContents] = [:]
        for folder in folders {
            if let contents = try? WorkspaceFiles.folderContents(folder, at: location) { read[folder] = contents }
        }
        return read
    }

    /// Selects the active editor's file and opens the folders above it, as Zed's auto-reveal
    /// does. A file the shown tree does not list, such as an ignored one, is left alone, as is
    /// the tree while an item is being named.
    func revealActiveFile(_ file: WorkspaceActiveFile) {
        guard let listing, listedIdentity == file.location.identity, draft == nil else { return }
        let isChanged = { listing.changes.contains { $0.path == file.path } }
        let isListed = showsChanges ? isChanged() : (listing.files.contains(file.path) || ignoredContents.values.contains { $0.files.contains(file.path) })
            && (!modifiedOnly || isChanged())
        guard isListed else { return }
        tree.reveal(file.path, in: treeIdentity(file.location))
    }

    /// The rows the tree shows, in order; none while its root is collapsed.
    func visibleRows(_ listing: WorkspaceFileListing, location: WorkspaceFileLocation) -> [WorkspaceTreeRow] {
        let identity = treeIdentity(location)
        guard !tree.collapsedRoots.contains(identity) else { return [] }
        return shownTree(listing, location: location).visibleRows(expanded: tree.expanded, identity: identity)
    }

    func collapseAll(_ location: WorkspaceFileLocation) {
        tree.collapseAll(treeIdentity(location))
    }

    // MARK: Operations

    /// Runs a Git or file operation off the main thread, then reloads the listing unless told not to.
    @discardableResult
    func runOperation<Value>(_ location: WorkspaceFileLocation, reloads: Bool = true,
                             _ operation: @escaping () throws -> Value,
                             completion: @escaping (Value) -> Void = { _ in },
                             failure: @escaping () -> Void = {}) -> Task<Void, Never> {
        let task = Task {
            let result = await BlockingWork.run(priority: .userInitiated) { Result { try operation() } }
            switch result {
            case .success(let value): completion(value)
            case .failure(let error):
                operationError = error.localizedDescription
                failure()
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
                self.record("Rename", .moved([WorkspaceMove(from: original, to: $0)]), at: location)
            }
        }
        let path = WorkspaceExplorer.path(of: name, in: draft.folder)
        return runOperation(location) {
            if draft.isFolder { try WorkspaceFiles.createFolder(path, at: location) }
            else { try WorkspaceFiles.createFile(path, at: location) }
        } completion: {
            if draft.isFolder { self.tree.createdDirectories[location.identity, default: []].insert(path) }
            self.reveal(path, in: location)
            self.record(draft.isFolder ? "New Folder" : "New File", .created([path]), at: location)
            if !draft.isFolder { openFile(location, path, false) }
        }
    }

    /// Whether `perform` would act now: the tree shown, the selection, or the Space root when
    /// nothing is selected, suits the command, and nothing is being named or confirmed. The
    /// command palette lists only these.
    func canPerform(_ command: ExplorerFileCommand) -> Bool {
        guard !showsChanges || command.appliesToChanges,
              draft == nil, pendingDelete == nil, listing != nil, let location else { return false }
        let path = tree.selectedPath(in: treeIdentity(location)) ?? ""
        guard !path.isEmpty || command.appliesToRoot else { return false }
        switch command {
        case .reveal, .openInDefaultApp: return location.isLocal
        case .undo: return undoName(at: location) != nil
        case .redo: return redoName(at: location) != nil
        default: return true
        }
    }

    /// Runs a file shortcut on the selected rows, or on the Space root when nothing is
    /// selected. Cutting, copying, duplicating, copying paths, trashing and deleting act on
    /// every selected row; the rest on the one selected last. `open` opens a file, in the
    /// preview tab when asked; `findInFolder` searches a folder. Returns whether the key was used.
    func perform(_ command: ExplorerFileCommand,
                 open: (WorkspaceFileLocation, String, Bool) -> Void = { _, _, _ in },
                 findInFolder: (WorkspaceFileLocation, String) -> Void = { _, _ in }) -> Bool {
        guard canPerform(command), let listing, let location else { return false }
        let path = tree.selectedPath(in: treeIdentity(location)) ?? ""
        let rows = visibleRows(listing, location: location)
        let row = rows.first { $0.node.path == path }
        let isDirectory = row?.node.isDirectory ?? WorkspaceExplorer.isDirectory(
            path, directories: filesTree(listing, location: location).directories,
            created: tree.createdDirectories[location.identity] ?? []
        )
        let folder = WorkspaceExplorer.folder(for: path, isDirectory: isDirectory)
        let absolute = location.absolutePath(path)
        let paths = path.isEmpty ? [] : tree.selectedPaths(in: treeIdentity(location))
        let isOnlyDirectory = paths.count == 1 && isDirectory
        switch command {
        case .newFile: startDraft(in: folder, isFolder: false, at: location)
        case .newFolder: startDraft(in: folder, isFolder: true, at: location)
        case .reveal, .openInDefaultApp:
            guard location.isLocal else { return false }
            if command == .reveal { effects.reveal(absolute) } else { effects.openInDefaultApp(absolute) }
        case .cut, .copy: copyItems(paths, in: location, cut: command == .cut)
        case .duplicate: duplicate(paths, in: location)
        case .paste: paste(into: folder, in: location)
        case .copyPath: effects.copy(path.isEmpty ? absolute : paths.map(location.absolutePath).joined(separator: "\n"))
        case .copyRelativePath: effects.copy(paths.joined(separator: "\n"))
        case .rename: startRename(path, isDirectory: isDirectory, at: location)
        // A Space over SSH has no Trash, so its items are deleted, after asking.
        case .trash where location.isLocal: trash(paths, in: location)
        case .trash, .trashAsking:
            pendingDelete = WorkspaceFileTarget(location: location, paths: paths, isDirectory: isOnlyDirectory,
                                                permanently: !location.isLocal)
        case .delete: pendingDelete = WorkspaceFileTarget(location: location, paths: paths, isDirectory: isOnlyDirectory)
        case .findInFolder: findInFolder(location, folder)
        case .undo: return undo(at: location) != nil
        case .redo: return redo(at: location) != nil
        case .open, .openPreview:
            if isDirectory {
                toggleDirectory(treeIdentity(location) + "|" + path, path: path,
                                isExpanded: tree.expanded.contains(treeIdentity(location) + "|" + path), location: location)
            } else {
                open(location, path, command == .openPreview)
            }
        // Escape first keeps only the selected row, then selects nothing.
        case .deselect:
            if tree.selectedPaths(in: treeIdentity(location)).count > 1 { tree.clearMarks() } else { tree.selected = nil }
        case .extendNext, .extendPrevious:
            let index = rows.firstIndex { $0.node.path == path }
            let next = index.map { command == .extendNext ? $0 + 1 : $0 - 1 } ?? (path.isEmpty && command == .extendNext ? 0 : -1)
            guard rows.indices.contains(next) else { break }
            extendSelection(to: rows[next].node.path, in: location)
        case .selectNext, .selectPrevious, .collapse, .expand, .collapseAll:
            navigate(command, from: path, rows: rows, location: location)
        }
        return true
    }

    /// Moves the selection through the rows shown, or opens and closes folders, as the arrow
    /// keys do in Zed. With nothing selected the Space root is, just above the first row.
    private func navigate(_ command: ExplorerFileCommand, from path: String, rows: [WorkspaceTreeRow],
                          location: WorkspaceFileLocation) {
        let identity = treeIdentity(location)
        let index = path.isEmpty ? nil : rows.firstIndex { $0.node.path == path }
        let row = index.map { rows[$0] }
        func select(_ row: WorkspaceTreeRow?) { tree.selected = row.map { identity + "|" + $0.node.path } }
        /// The nearest row shown above `path` that contains it, or the root.
        func shownAncestor(in rows: [WorkspaceTreeRow]) -> WorkspaceTreeRow? {
            rows.last { path.hasPrefix($0.node.path + "/") }
        }
        let isExpanded = row.map { tree.expanded.contains(identity + "|" + $0.node.path) } ?? false
        switch command {
        case .selectNext:
            let next = index.map { $0 + 1 } ?? (path.isEmpty ? 0 : rows.count)
            if next < rows.count { select(rows[next]) }
            else if index == nil, !path.isEmpty { select(shownAncestor(in: rows)) }
        case .selectPrevious:
            if let index { select(index > 0 ? rows[index - 1] : nil) }
            else if !path.isEmpty { select(shownAncestor(in: rows)) }
        case .collapse:
            if path.isEmpty { tree.collapsedRoots.insert(identity) }
            else if let row, row.node.isDirectory, isExpanded {
                toggleDirectory(identity + "|" + path, path: path, isExpanded: true, location: location)
            } else { select(shownAncestor(in: rows)) }
        case .expand:
            if path.isEmpty {
                if tree.collapsedRoots.contains(identity) { tree.collapsedRoots.remove(identity) }
                else { select(rows.first) }
            } else if let row, let index, row.node.isDirectory {
                if !isExpanded {
                    toggleDirectory(identity + "|" + path, path: path, isExpanded: false, location: location)
                } else if index + 1 < rows.count, rows[index + 1].node.path.hasPrefix(path + "/") {
                    select(rows[index + 1])
                }
            }
        case .collapseAll:
            collapseAll(location)
            // The selection moves up to the top-level row that held it.
            if !path.isEmpty, let listing {
                select(visibleRows(listing, location: location).first {
                    $0.node.path == path || path.hasPrefix($0.node.path + "/")
                })
            }
        default: break
        }
    }

    // MARK: Selection

    /// Adds a row to the selection or takes it out, as a Command-click does.
    func toggleMark(_ path: String, in location: WorkspaceFileLocation) {
        tree.toggleMark(treeIdentity(location) + "|" + path)
    }

    /// Selects the rows shown from the anchor to `path`, as a Shift-click does.
    func extendSelection(to path: String, in location: WorkspaceFileLocation) {
        guard let listing else { return }
        let identity = treeIdentity(location)
        tree.markRange(to: identity + "|" + path,
                       rows: visibleRows(listing, location: location).map { identity + "|" + $0.node.path })
    }

    /// What a context menu on `path` acts on: the selected rows when it is one of them, or else
    /// just it, as in VS Code.
    func menuTargets(_ path: String, in location: WorkspaceFileLocation) -> [String] {
        let identity = treeIdentity(location)
        return tree.isMarked(identity + "|" + path) ? tree.selectedPaths(in: identity) : [path]
    }

    // MARK: Clipboard and file operations

    func copyItems(_ paths: [String], in location: WorkspaceFileLocation, cut: Bool) {
        let absolute = paths.map(location.absolutePath)
        // Local items also go on the general pasteboard, so Finder can paste them.
        let changeCount = location.isLocal ? effects.putFilesOnPasteboard(absolute) : 0
        clipboard = WorkspaceFileClipboard(machineID: location.machine?.id, paths: absolute,
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
            // A cut from this Space can be moved back; one from elsewhere cannot.
            let moved = move ? Self.moves(from: sources, to: $0, in: location) : nil
            if move { self.clipboard = nil }
            for move in moved ?? [] {
                self.tree.move(from: move.from, to: move.to, in: self.treeIdentity(location), location: location.identity)
            }
            self.placePasted($0, in: location)
            if !move { self.record("Paste", .created($0), at: location) }
            if let moved { self.record("Move", .moved(moved), at: location) }
        }
    }

    /// Copies each item beside itself.
    @discardableResult
    func duplicate(_ paths: [String], in location: WorkspaceFileLocation) -> Task<Void, Never> {
        runOperation(location) {
            try paths.flatMap { path in
                try WorkspaceFiles.paste([location.absolutePath(path)], into: (path as NSString).deletingLastPathComponent,
                                         move: false, at: location)
            }
        } completion: {
            self.placePasted($0, in: location)
            self.record("Duplicate", .created($0), at: location)
        }
    }

    /// Keeps pasted empty folders visible and selects the pasted items.
    private func placePasted(_ paths: [String], in location: WorkspaceFileLocation) {
        if location.isLocal {
            var isDirectory: ObjCBool = false
            for path in paths where FileManager.default.fileExists(atPath: location.absolutePath(path),
                                                                   isDirectory: &isDirectory) && isDirectory.boolValue {
                tree.createdDirectories[location.identity, default: []].insert(path)
            }
        }
        tree.reveal(paths, in: treeIdentity(location))
    }

    @discardableResult
    func trash(_ paths: [String], in location: WorkspaceFileLocation) -> Task<Void, Never> {
        runOperation(location) {
            try paths.map { WorkspaceTrashedItem(path: $0, trashPath: try WorkspaceFiles.trash($0, at: location)) }
        } completion: {
            for path in paths { self.tree.forget(path, location: location.identity) }
            self.record("Move to Trash", .trashed($0), at: location)
        }
    }

    /// Deletes a confirmed target, or moves it to the Trash.
    @discardableResult
    func delete(_ target: WorkspaceFileTarget) -> Task<Void, Never> {
        let location = target.location
        guard target.permanently else { return trash(target.paths, in: location) }
        return runOperation(location) { for path in target.paths { try WorkspaceFiles.delete(path, at: location) } } completion: {
            for path in target.paths { self.tree.forget(path, location: location.identity) }
        }
    }

    // MARK: Undo

    /// What can be undone in each Space, by location identity, the last done last.
    @Published private(set) var undoStacks: [String: [WorkspaceUndoEntry]] = [:]
    /// What was undone and can be done again, by location identity.
    @Published private(set) var redoStacks: [String: [WorkspaceUndoEntry]] = [:]
    /// Set while an undo or redo runs, so a repeated key does not apply the same entry twice.
    private var isUndoing = false
    private static let undoLimit = 50

    /// The name of what Command-Z undoes in `location`, such as "Rename".
    func undoName(at location: WorkspaceFileLocation) -> String? { undoStacks[location.identity]?.last?.name }
    func redoName(at location: WorkspaceFileLocation) -> String? { redoStacks[location.identity]?.last?.name }

    private func record(_ name: String, _ edit: WorkspaceFileEdit, at location: WorkspaceFileLocation) {
        guard !edit.isEmpty else { return }
        var stack = undoStacks[location.identity, default: []]
        stack.append(WorkspaceUndoEntry(name: name, edit: edit))
        undoStacks[location.identity] = Array(stack.suffix(Self.undoLimit))
        redoStacks[location.identity] = nil
    }

    /// Undoes the last file operation in `location`: what was created goes to the Trash, what
    /// moved goes back, and what went to the Trash comes back. Nil when there is nothing to undo.
    @discardableResult
    func undo(at location: WorkspaceFileLocation) -> Task<Void, Never>? { step(at: location, redoing: false) }

    @discardableResult
    func redo(at location: WorkspaceFileLocation) -> Task<Void, Never>? { step(at: location, redoing: true) }

    private func step(at location: WorkspaceFileLocation, redoing: Bool) -> Task<Void, Never>? {
        let key = location.identity
        guard !isUndoing, let entry = (redoing ? redoStacks : undoStacks)[key]?.last else { return nil }
        isUndoing = true
        return runOperation(location) { try Self.apply(entry.edit, at: location) } completion: { inverse in
            self.isUndoing = false
            if redoing { self.redoStacks[key]?.removeLast() } else { self.undoStacks[key]?.removeLast() }
            let done = WorkspaceUndoEntry(name: entry.name, edit: inverse)
            if redoing { self.undoStacks[key, default: []].append(done) } else { self.redoStacks[key, default: []].append(done) }
            self.place(inverse, in: location)
        } failure: {
            // The entry stays, so it can be tried again once what blocked it is fixed.
            self.isUndoing = false
        }
    }

    /// Reverses `edit` and returns what reverses that in turn.
    nonisolated private static func apply(_ edit: WorkspaceFileEdit, at location: WorkspaceFileLocation) throws -> WorkspaceFileEdit {
        switch edit {
        case .created(let paths):
            guard location.isLocal else {
                throw WorkspaceFileError.message("\(location.machineLabel) has no Trash, so undoing would delete "
                                                 + "for good; delete the items instead")
            }
            return .trashed(try paths.map { WorkspaceTrashedItem(path: $0, trashPath: try WorkspaceFiles.trash($0, at: location)) })
        case .moved(let moves):
            for move in moves.reversed() { try WorkspaceFiles.moveItem(move.to, to: move.from, at: location) }
            return .moved(moves.map { WorkspaceMove(from: $0.to, to: $0.from) })
        case .trashed(let items):
            for item in items { try WorkspaceFiles.restore(item.trashPath, to: item.path, at: location) }
            return .created(items.map(\.path))
        }
    }

    /// Updates the tree after an undo or redo whose reverse is `inverse`.
    private func place(_ inverse: WorkspaceFileEdit, in location: WorkspaceFileLocation) {
        switch inverse {
        case .trashed(let items):
            for item in items { tree.forget(item.path, location: location.identity) }
        case .moved(let moves):
            // An inverse is the move just made, so the items now sit at its destinations.
            for move in moves {
                tree.move(from: move.from, to: move.to, in: treeIdentity(location), location: location.identity)
            }
            placePasted(moves.map(\.to), in: location)
        case .created(let paths):
            placePasted(paths, in: location)
        }
    }

    /// The moves a cut and paste made, as Space paths; nil when an item came from outside the Space.
    private static func moves(from sources: [String], to results: [String], in location: WorkspaceFileLocation) -> [WorkspaceMove]? {
        let root = location.root.hasSuffix("/") ? location.root : location.root + "/"
        var moves: [WorkspaceMove] = []
        for (source, result) in zip(sources, results) {
            guard source.hasPrefix(root) else { return nil }
            let from = String(source.dropFirst(root.count))
            if from != result { moves.append(WorkspaceMove(from: from, to: result)) }
        }
        return moves
    }

    // MARK: Drag and drop

    /// The pasteboard type that marks a drag from an explorer tree.
    static let dragType = "dev.wooloo.explorer-item"
    /// The last drag started from any explorer tree: its location identity, the row dragged and
    /// the items it carries. A drag whose items carry `dragType` is this one.
    private static var currentDrag: (location: String, row: String, paths: [String])?

    /// What dragging a row carries: the file of a local item, so Finder, other apps and
    /// terminals take it; the path of a remote one, as text; and `dragType`, so the tree knows
    /// it. Dragging one of the selected rows moves them all within the tree, though only the
    /// row dragged goes to other apps.
    func startDrag(_ path: String, in location: WorkspaceFileLocation) -> NSItemProvider {
        let paths = menuTargets(path, in: location)
        Self.currentDrag = (location.identity, path, paths)
        let absolute = location.absolutePath(path)
        let provider = location.isLocal ? NSItemProvider(object: URL(fileURLWithPath: absolute) as NSURL)
                                        : NSItemProvider(object: absolute as NSString)
        provider.suggestedName = (path as NSString).lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .all) { completion in
            completion(Data(([location.identity] + paths).joined(separator: "\n").utf8), nil)
            return nil
        }
        return provider
    }

    /// The items of this tree being dragged when `providers` come from an explorer drag of them.
    func draggedItems(_ providers: [NSItemProvider], location: WorkspaceFileLocation) -> [String]? {
        guard let drag = Self.currentDrag, drag.location == location.identity,
              providers.contains(where: { $0.registeredTypeIdentifiers.contains(Self.dragType) }) else { return nil }
        return drag.paths
    }

    /// The items of this tree that dropped files stand for, when they are just the row last
    /// dragged from it: the drop's own check for a drag whose items lost `dragType` on the way.
    func draggedItems(files: [String], location: WorkspaceFileLocation) -> [String]? {
        guard let drag = Self.currentDrag, drag.location == location.identity,
              files == [location.absolutePath(drag.row)] else { return nil }
        return drag.paths
    }

    /// What dropping on `folder` ("" is the root) does: items of this tree move, or are copied
    /// with Option held; files from elsewhere are copied. Nil refuses the drop, as for a folder
    /// dropped into itself or items dropped where they already are.
    func dropAction(of dragged: [String]?, into folder: String, copy: Bool) -> WorkspaceDropAction? {
        guard !showsChanges, draft == nil else { return nil }
        guard let dragged else { return .copy }
        if dragged.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return nil }
        if !copy && dragged.allSatisfy({ ($0 as NSString).deletingLastPathComponent == folder }) { return nil }
        return copy ? .copy : .move
    }

    /// Moves or copies items of this tree into `folder`, keeping their open folders and selection.
    @discardableResult
    func dropItems(_ paths: [String], into folder: String, copy: Bool, in location: WorkspaceFileLocation) -> Task<Void, Never>? {
        guard dropAction(of: paths, into: folder, copy: copy) != nil else { return nil }
        let sources = paths.map(location.absolutePath)
        return runOperation(location) { try WorkspaceFiles.paste(sources, into: folder, move: !copy, at: location) } completion: {
            let moves = zip(paths, $0).map { WorkspaceMove(from: $0, to: $1) }.filter { $0.from != $0.to }
            if !copy {
                for move in moves {
                    self.tree.move(from: move.from, to: move.to, in: self.treeIdentity(location), location: location.identity)
                }
            }
            self.placePasted($0, in: location)
            self.record(copy ? "Copy" : "Move", copy ? .created($0) : .moved(moves), at: location)
        }
    }

    /// Copies files of this Mac, such as ones dropped from Finder, into `folder`.
    @discardableResult
    func importFiles(_ paths: [String], into folder: String, in location: WorkspaceFileLocation) -> Task<Void, Never>? {
        guard !paths.isEmpty, dropAction(of: nil, into: folder, copy: true) != nil else { return nil }
        return runOperation(location) { try WorkspaceFiles.importItems(paths, into: folder, at: location) } completion: {
            self.placePasted($0, in: location)
            self.record("Copy", .created($0), at: location)
        }
    }

    /// The folder a drag hovers over, "" for the root, shown highlighted with what it holds.
    @Published private(set) var dropFolder: String?
    /// The row the drag is over, which may be a file of `dropFolder`.
    private var dropRow: String?
    private var springLoad: Task<Void, Never>?

    /// Highlights the folder under a drag; a closed folder held under it opens after a moment,
    /// as in Finder.
    func dragEntered(row: String, folder: String, location: WorkspaceFileLocation) {
        dropRow = row
        dropFolder = folder
        springLoad?.cancel()
        let key = treeIdentity(location) + "|" + folder
        guard row == folder, !folder.isEmpty, !tree.expanded.contains(key) else { return }
        springLoad = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, dropRow == row else { return }
            toggleDirectory(key, path: folder, isExpanded: false, location: location)
        }
    }

    func dragExited(row: String) {
        guard dropRow == row else { return }
        dragEnded()
    }

    func dragEnded() {
        springLoad?.cancel()
        dropRow = nil
        dropFolder = nil
    }

    /// Expands the folders above `path` and selects it.
    private func reveal(_ path: String, in location: WorkspaceFileLocation) {
        tree.reveal(path, in: treeIdentity(location))
    }
}

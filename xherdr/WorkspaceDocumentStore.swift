import Foundation

/// The documents open as tabs in the main area: which one is active, the single preview tab,
/// and loading, saving and closing them. Each Space has its own tabs.
@MainActor
final class WorkspaceDocumentStore: ObservableObject {
    private enum LoadedContents {
        case text(WorkspaceFileContents)
        case pdf(WorkspacePDF.Contents)
        case image(WorkspaceImage.Contents)
    }
    /// Every Space's documents; `visibleDocuments` are the shown Space's.
    @Published var documents: [WorkspaceDocument] = [] {
        didSet { schedulePersistence() }
    }
    /// The active document, or `WorkspaceSearchModel.tabID`; nil shows the terminals.
    @Published var activeID: String? {
        didSet {
            if let activeID, let document = document(activeID), document.kind == .file, !document.isUntitled {
                remember(document)
            }
            if !switchingSpace && !applyingRestoration {
                let key = WorkspaceSessionPersistence.key(for: space)
                activeBySpace[key] = activeID.flatMap { document($0)?.backupID }
                selectionChanged.insert(key)
                schedulePersistence()
            }
        }
    }
    /// Files shown most recently first, for Go to File.
    private var recentFiles: [(space: String?, location: String, path: String)] = []
    /// The Space whose documents are shown and where new ones open.
    @Published private(set) var space: String?

    @Published var persistenceError: String?
    var backsUpSessions: Bool { persistence != nil }
    private let persistence: WorkspaceSessionPersistence?
    private let backupDelay: UInt64
    private let persistenceOwner = UUID()
    private var persistenceTask: Task<Void, Never>?
    private var restorations: [String: Task<Void, Never>] = [:]
    private var managedSpaces: [String: String?] = [:]
    private var failedRestorations: Set<String> = []
    private var activeBySpace: [String: UUID] = [:]
    private var selectionChanged: Set<String> = []
    private var closedBeforeRestoration: Set<String> = []
    private var discardedBySpace: [String: Set<UUID>] = [:]
    private var applyingRestoration = false
    private var switchingSpace = false
    private var changeRevision: UInt64 = 0

    init(persistence: WorkspaceSessionPersistence? = XherdrApp.isHostingTests ? nil : .shared,
         backupDelay: UInt64 = 500_000_000) {
        self.persistence = persistence
        self.backupDelay = backupDelay
        if persistence != nil {
            WorkspaceSessionRegistry.shared.register(self)
            restoreSpace(nil)
        }
    }

    deinit {
        persistenceTask?.cancel()
        if let persistence {
            let owner = persistenceOwner
            Task { await persistence.release(owner) }
        }
    }

    private func restoreSpace(_ space: String?) {
        guard let persistence else { return }
        let key = WorkspaceSessionPersistence.key(for: space)
        guard !managedSpaces.keys.contains(key) else { return }
        managedSpaces.updateValue(space, forKey: key)
        let owner = persistenceOwner
        restorations[key] = Task { [weak self] in
            do {
                guard let self else { return }
                let restored = try await persistence.restore(space, owner: owner)
                self.applyingRestoration = true
                defer { self.applyingRestoration = false }
                var warnings = restored.warnings
                var reload: [String] = []
                for snapshot in restored.session.documents {
                    do {
                        var document = try snapshot.document()
                        if document.space == nil, self.space != nil { document.space = self.space }
                        if let number = document.untitledNumber, self.documents.contains(where: {
                            $0.space == document.space && $0.untitledNumber == number && $0.backupID != document.backupID
                        }) {
                            document.untitledNumber = (1...).first { number in
                                !self.documents.contains { $0.space == document.space && $0.untitledNumber == number }
                            }
                        }
                        guard !self.closedBeforeRestoration.contains(document.id) else { continue }
                        if let existing = self.documents.firstIndex(where: { $0.id == document.id }) {
                            if document.isDirty && !self.documents[existing].isDirty {
                                document.reveal = self.documents[existing].reveal
                                document.focusRequest = self.documents[existing].focusRequest
                                self.documents[existing] = document
                                if self.activeID == document.id { self.activeBySpace[key] = document.backupID }
                            } else if document.isDirty && self.documents[existing].text != document.text {
                                // Two windows edited the same file independently. Preserve both buffers.
                                var recovered = snapshot
                                recovered.path = ""
                                recovered.originalPath = snapshot.path
                                recovered.kind = .file
                                recovered.untitledNumber = (1...).first { number in
                                    !self.documents.contains { $0.space == document.space && $0.untitledNumber == number }
                                }
                                recovered.savedText = ""
                                recovered.version = nil
                                recovered.isPreview = false
                                document = try recovered.document()
                                self.documents.append(document)
                                warnings.append("Another buffer for \(snapshot.path) was recovered as \(document.title).")
                            }
                            continue
                        }
                        self.documents.append(document)
                        if document.isLoading { reload.append(document.id) }
                    } catch { warnings.append(error.localizedDescription) }
                }
                if !self.selectionChanged.contains(key) {
                    self.activeBySpace[key] = restored.session.activeDocument
                    if self.space == space {
                        self.activeID = restored.session.activeDocument.flatMap { id in
                            self.visibleDocuments.first { $0.backupID == id }?.id
                        }
                    }
                }
                if !warnings.isEmpty { self.persistenceError = warnings.joined(separator: "\n") }
                for id in reload { self.load(id) }
            } catch {
                self?.failedRestorations.insert(key)
                self?.persistenceError = error.localizedDescription
            }
        }
    }

    /// Exposed for deterministic restoration/quit checks; ordinary editing need not wait.
    func waitForRestoration() async {
        for task in Array(restorations.values) { await task.value }
    }

    private func schedulePersistence(immediately: Bool = false) {
        guard persistence != nil else { return }
        changeRevision &+= 1
        guard !applyingRestoration, !switchingSpace else { return }
        persistenceTask?.cancel()
        let delay = immediately ? 0 : backupDelay
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                try await self.flushPersistence()
            } catch is CancellationError {
                // A newer edit owns the next snapshot.
            } catch { self?.persistenceError = error.localizedDescription }
        }
    }

    /// Capture the latest buffer state after restoration, then await ordered disk writes.
    /// A window disappearing also calls this, retaining its store until writes complete.
    func flushPersistence() async throws {
        guard let persistence else { return }
        persistenceTask?.cancel()
        persistenceTask = nil
        await waitForRestoration()
        guard failedRestorations.isEmpty else {
            throw WorkspaceFileError.message(persistenceError ?? "Could not restore editor session")
        }
        while true {
            let revision = changeRevision
            for (key, space) in managedSpaces.sorted(by: { $0.key < $1.key }) {
                let snapshot = WorkspaceSessionSnapshot(space: space, activeDocument: activeBySpace[key],
                    documents: documents.filter { $0.space == space }.map(WorkspaceDocumentSnapshot.init),
                    discardedBackups: discardedBySpace[key] ?? [])
                try await persistence.save(snapshot, owner: persistenceOwner)
                discardedBySpace[key]?.subtract(snapshot.discardedBackups)
            }
            // An edit or in-flight file save may finish while disk I/O is running. Quit and
            // window close must wait for that newer state as well, not just the first snapshot.
            if revision == changeRevision { return }
        }
    }

    var visibleDocuments: [WorkspaceDocument] {
        documents.filter { $0.space == space }
    }

    func document(_ id: String) -> WorkspaceDocument? {
        documents.first { $0.id == id }
    }

    /// Shows another Space's tabs; the previous Space's stay open, hidden, until it is shown
    /// again. Documents opened before any Space was known join the first one shown.
    func showSpace(_ space: String?) {
        restoreSpace(space)
        guard space != self.space else { return }
        switchingSpace = true
        defer { switchingSpace = false; schedulePersistence() }
        if self.space == nil, space != nil {
            for index in documents.indices where documents[index].space == nil {
                let previousID = documents[index].id
                documents[index].space = space
                if activeID == previousID { activeID = documents[index].id }
            }
        }
        self.space = space
        let key = WorkspaceSessionPersistence.key(for: space)
        if let activeID, document(activeID)?.space == space {
            activeBySpace[key] = document(activeID)?.backupID
        } else {
            activeID = activeBySpace[key].flatMap { id in visibleDocuments.first { $0.backupID == id }?.id }
        }
    }

    /// Opens a document, or activates it when it is already open. A preview replaces the
    /// previous preview unless that one has unsaved edits.
    func open(_ kind: WorkspaceDocumentKind, path: String, at location: WorkspaceFileLocation,
              reveal: WorkspaceDocumentReveal? = nil, commit: String? = nil, originalPath: String? = nil,
              scope: WorkspaceDiffScope? = nil, preview: Bool = false, focus: Bool = false) {
        var document = WorkspaceDocument(space: space, location: location, path: path, kind: kind)
        document.reveal = reveal
        if focus { document.focusRequest = UUID() }
        if let scope { document.diffScope = scope }
        document.commit = commit
        document.originalPath = originalPath
        document.isPreview = preview
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            if let reveal { documents[index].reveal = reveal }
            if focus { documents[index].focusRequest = UUID() }
            if let scope, documents[index].diffPatches.isEmpty || documents[index].diffPatches[scope] != nil {
                documents[index].diffScope = scope
            }
            if !preview { documents[index].isPreview = false }
            activeID = document.id
            return
        }
        if preview, let index = documents.firstIndex(where: { $0.isPreview && $0.space == space }) {
            if documents[index].isDirty {
                documents[index].isPreview = false
            } else {
                documents[index] = document
                activeID = document.id
                load(document.id)
                return
            }
        }
        documents.append(document)
        activeID = document.id
        load(document.id)
    }

    /// Opens a new empty file, "Untitled-N", as a regular tab of the current Space and focuses
    /// it. N is the lowest number no untitled tab of the Space uses, as in VS Code. Nothing is
    /// written until it is saved, which asks where (see `saveUntitled`).
    @discardableResult
    func newUntitled(at location: WorkspaceFileLocation) -> String {
        let used = Set(documents.filter { $0.space == space }.compactMap(\.untitledNumber))
        let number = (1...).first { !used.contains($0) }!
        var document = WorkspaceDocument(space: space, location: location, path: "", kind: .file)
        document.untitledNumber = number
        document.isLoading = false
        document.focusRequest = UUID()
        documents.append(document)
        activeID = document.id
        return document.id
    }

    /// The Space-relative path a Save As field names, or why it cannot be saved there. The
    /// field may also hold an absolute path inside the Space root, or start with `./`.
    nonisolated static func untitledSavePath(_ input: String, root: String) -> Result<String, WorkspaceFileError> {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootPrefix) { path.removeFirst(rootPrefix.count) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty, !path.hasSuffix("/") else { return .failure(.message("Enter a file name")) }
        do {
            try WorkspaceFiles.validateRelativePath(path)
            try WorkspaceFiles.validateName((path as NSString).lastPathComponent)
        } catch let error as WorkspaceFileError {
            return .failure(error)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
        return .success(path)
    }

    /// Saves an untitled document as a new file at a Space-relative path, local or over SSH,
    /// creating missing folders and refusing a file that already exists. The tab then becomes
    /// that file's regular tab. Returns the error to show, or nil once saved.
    func saveUntitled(_ id: String, as input: String) async -> String? {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].isUntitled else {
            return "The document is no longer open"
        }
        let document = documents[index]
        let path: String
        switch Self.untitledSavePath(input, root: document.location.root) {
        case .success(let value): path = value
        case .failure(let failure): return failure.localizedDescription
        }
        guard !WorkspacePDF.supports(path) else { return "PDF files can only be previewed; choose a text file extension" }
        guard !WorkspaceImage.supports(path) else { return "Image files can only be previewed; choose a text file extension" }
        let (text, location) = (document.text, document.location)
        documents[index].isSaving = true
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws -> String in
                try WorkspaceFiles.createFile(path, at: location)
                return try WorkspaceFiles.save(text, path: path, expectedVersion: WorkspaceFiles.gitBlobHash(Data()),
                                               at: location)
            }
        }.value
        guard let currentIndex = documents.firstIndex(where: { $0.id == id }) else { return nil }
        documents[currentIndex].isSaving = false
        switch result {
        case .success(let version):
            var saved = WorkspaceDocument(space: document.space, location: location, path: path, kind: .file)
            saved.backupID = document.backupID
            saved.cursorPositions = documents[currentIndex].cursorPositions
            saved.scrollPosition = documents[currentIndex].scrollPosition
            // Edits made while saving stay unsaved.
            saved.text = documents[currentIndex].text
            saved.savedText = text
            saved.version = version
            saved.isLoading = false
            saved.markdownMode = .source
            saved.focusRequest = UUID()
            // A tab left open on a file of that name that had been deleted gives way.
            documents.removeAll { $0.id == saved.id }
            guard let replaced = documents.firstIndex(where: { $0.id == id }) else { return nil }
            documents[replaced] = saved
            if activeID == id { activeID = saved.id }
            schedulePersistence(immediately: true)
            return nil
        case .failure(let failure):
            return failure.localizedDescription
        }
    }

    /// Moves a tab of the current Space to `insertIndex`, a gap between its tabs (0 is before the
    /// first, `count` after the last), as Herdr's `tab.move` places terminal tabs.
    func move(_ id: String, to insertIndex: Int) {
        var visible = visibleDocuments
        guard let from = visible.firstIndex(where: { $0.id == id }), (0...visible.count).contains(insertIndex),
              insertIndex != from, insertIndex != from + 1 else { return }
        let document = visible.remove(at: from)
        visible.insert(document, at: insertIndex > from ? insertIndex - 1 : insertIndex)
        // Other Spaces' tabs keep their places; the shown ones fill their own slots in the new order.
        var next = visible.makeIterator()
        documents = documents.map { $0.space == space ? next.next()! : $0 }
    }

    /// The files at a location shown in the current Space, most recently first.
    func recentPaths(at location: WorkspaceFileLocation) -> [String] {
        recentFiles.filter { $0.space == space && $0.location == location.identity }.map(\.path)
    }

    private func remember(_ document: WorkspaceDocument) {
        recentFiles.removeAll {
            $0.space == document.space && $0.location == document.location.identity && $0.path == document.path
        }
        recentFiles.insert((document.space, document.location.identity, document.path), at: 0)
        if recentFiles.count > 200 { recentFiles.removeLast() }
    }

    /// Turns a preview into a regular tab that later previews do not replace.
    func keepOpen(_ id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].isPreview else { return }
        documents[index].isPreview = false
    }

    /// Editing a preview keeps it open, so later previews never replace unsaved work.
    func keepEditedPreviewsOpen() {
        for index in documents.indices where documents[index].isPreview && documents[index].isDirty {
            documents[index].isPreview = false
        }
    }

    /// Reads a document's file, diff or commit diff from disk or over SSH.
    func load(_ id: String) {
        guard let initialIndex = documents.firstIndex(where: { $0.id == id }) else { return }
        let request = UUID()
        documents[initialIndex].loadRequest = request
        let document = documents[initialIndex]
        let (kind, path, location) = (document.kind, document.path, document.location)
        let (commit, originalPath) = (document.commit, document.originalPath)
        let isPDF = document.isPDF
        let isImage = document.isImage
        let start = TerminalPipelineMetrics.now()
        Task {
            defer {
                TerminalPipelineMetrics.spanShown("open-\(kind)", start: start, detail: location.isLocal ? "local" : "ssh")
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> LoadedContents in
                    if kind == .commit, let commit {
                        return .text(WorkspaceFileContents(text: try WorkspaceFiles.commitDiff(
                            commit, path: path, originalPath: originalPath, at: location), version: ""))
                    }
                    if kind == .change {
                        let patches = try WorkspaceFiles.diff(path, at: location)
                        return .text(WorkspaceFileContents(text: patches[.all] ?? "", version: "", patches: patches))
                    }
                    if isPDF { return .pdf(try WorkspacePDF.read(path, at: location)) }
                    if isImage { return .image(try WorkspaceImage.read(path, at: location)) }
                    return .text(try WorkspaceFiles.read(path, at: location))
                }
            }.value
            guard let index = documents.firstIndex(where: { $0.id == id && $0.loadRequest == request }) else { return }
            documents[index].isLoading = false
            switch result {
            case .success(.pdf(let content)):
                if let pdf = documents[index].pdf {
                    pdf.replace(with: content.document)
                } else {
                    documents[index].pdf = PDFPreviewModel(document: content.document)
                }
                documents[index].version = content.version
                documents[index].error = nil
            case .success(.image(let content)):
                if let image = documents[index].image {
                    image.replace(with: content)
                } else {
                    documents[index].image = ImagePreviewModel(contents: content)
                }
                documents[index].version = content.version
                documents[index].error = nil
            case .success(.text(let content)):
                // A slow local/SSH read must not replace work entered after it started.
                if documents[index].text == document.text { documents[index].text = content.text }
                documents[index].savedText = content.text
                documents[index].version = content.version
                documents[index].diffPatches = content.patches
                documents[index].error = nil
                let length = (documents[index].text as NSString).length
                documents[index].cursorPositions = documents[index].cursorPositions.map { position in
                    guard position.range.location != NSNotFound else { return position }
                    let start = min(max(position.range.location, 0), length)
                    return .init(range: NSRange(location: start, length: min(max(position.range.length, 0), length - start)))
                }
                if content.patches[documents[index].diffScope] == nil { documents[index].diffScope = .all }
            case .failure(let failure):
                documents[index].error = failure.localizedDescription
            }
        }
    }

    /// Saves a file with unsaved edits, unless it changed on disk since it was read.
    func save(_ id: String, onSaved: @escaping () -> Void = {}) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              documents[index].isEditable,
              let version = documents[index].version,
              documents[index].isDirty else { return }
        let document = documents[index]
        documents[index].isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkspaceFiles.save(document.text, path: document.path,
                                                 expectedVersion: version, at: document.location) }
            }.value
            guard let currentIndex = documents.firstIndex(where: { $0.id == id && $0.backupID == document.backupID }) else { return }
            documents[currentIndex].isSaving = false
            switch result {
            case .success(let nextVersion):
                documents[currentIndex].version = nextVersion
                documents[currentIndex].savedText = document.text
                documents[currentIndex].error = nil
                schedulePersistence(immediately: true)
                onSaved()
            case .failure(let failure):
                documents[currentIndex].error = failure.localizedDescription
            }
        }
    }

    /// Closes a document. Unsaved edits need `force`; without it nothing closes and this
    /// returns false so the caller can ask first.
    @discardableResult
    func close(_ id: String, force: Bool = false) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return true }
        if documents[index].isDirty && !force { return false }
        let key = WorkspaceSessionPersistence.key(for: documents[index].space)
        discardedBySpace[key, default: []].insert(documents[index].backupID)
        closedBeforeRestoration.insert(id)
        documents.remove(at: index)
        if activeID == id { activeID = nil }
        schedulePersistence(immediately: true)
        return true
    }

    /// Whether a file has unsaved edits in an open tab.
    func hasUnsavedEdits(at location: WorkspaceFileLocation, path: String) -> Bool {
        documents.contains {
            $0.kind == .file && $0.isDirty && $0.path == path && $0.location.identity == location.identity
        }
    }

    /// Reads again the open files that something else wrote, keeping tabs with unsaved edits.
    func reloadUnedited(_ paths: [String], at location: WorkspaceFileLocation) {
        for document in documents where document.kind == .file && !document.isDirty
            && document.location.identity == location.identity && paths.contains(document.path) {
            load(document.id)
        }
    }
}

import Foundation

/// The documents open as tabs in the main area: which one is active, the single preview tab,
/// and loading, saving and closing them. Each Space has its own tabs.
@MainActor
final class WorkspaceDocumentStore: ObservableObject {
    /// Every Space's documents; `visibleDocuments` are the shown Space's.
    @Published var documents: [WorkspaceDocument] = []
    /// The active document, or `WorkspaceSearchModel.tabID`; nil shows the terminals.
    @Published var activeID: String? {
        didSet {
            if let activeID, let document = document(activeID), document.kind == .file, !document.isUntitled {
                remember(document)
            }
        }
    }
    /// Files shown most recently first, for Go to File.
    private var recentFiles: [(space: String?, location: String, path: String)] = []
    /// The Space whose documents are shown and where new ones open.
    @Published private(set) var space: String?

    var visibleDocuments: [WorkspaceDocument] {
        documents.filter { $0.space == space }
    }

    func document(_ id: String) -> WorkspaceDocument? {
        documents.first { $0.id == id }
    }

    /// Shows another Space's tabs; the previous Space's stay open, hidden, until it is shown
    /// again. Documents opened before any Space was known join the first one shown.
    func showSpace(_ space: String?) {
        guard space != self.space else { return }
        if self.space == nil, space != nil {
            for index in documents.indices where documents[index].space == nil {
                let previousID = documents[index].id
                documents[index].space = space
                if activeID == previousID { activeID = documents[index].id }
            }
        }
        self.space = space
        if let activeID, activeID != WorkspaceSearchModel.tabID,
           document(activeID)?.space != space {
            self.activeID = nil
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
        guard let document = document(id) else { return }
        let (kind, path, location) = (document.kind, document.path, document.location)
        let (commit, originalPath) = (document.commit, document.originalPath)
        let start = TerminalPipelineMetrics.now()
        Task {
            defer {
                TerminalPipelineMetrics.spanShown("open-\(kind)", start: start, detail: location.isLocal ? "local" : "ssh")
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> WorkspaceFileContents in
                    if kind == .commit, let commit {
                        return WorkspaceFileContents(text: try WorkspaceFiles.commitDiff(
                            commit, path: path, originalPath: originalPath, at: location), version: "")
                    }
                    if kind == .change {
                        let patches = try WorkspaceFiles.diff(path, at: location)
                        return WorkspaceFileContents(text: patches[.all] ?? "", version: "", patches: patches)
                    }
                    return try WorkspaceFiles.read(path, at: location)
                }
            }.value
            guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
            documents[index].isLoading = false
            switch result {
            case .success(let content):
                documents[index].text = content.text
                documents[index].savedText = content.text
                documents[index].version = content.version
                documents[index].diffPatches = content.patches
                if content.patches[documents[index].diffScope] == nil { documents[index].diffScope = .all }
            case .failure(let failure):
                documents[index].error = failure.localizedDescription
            }
        }
    }

    /// Saves a file with unsaved edits, unless it changed on disk since it was read.
    func save(_ id: String, onSaved: @escaping () -> Void = {}) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              let version = documents[index].version,
              documents[index].isDirty else { return }
        let document = documents[index]
        documents[index].isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkspaceFiles.save(document.text, path: document.path,
                                                 expectedVersion: version, at: document.location) }
            }.value
            guard let currentIndex = documents.firstIndex(where: { $0.id == id }) else { return }
            documents[currentIndex].isSaving = false
            switch result {
            case .success(let nextVersion):
                documents[currentIndex].version = nextVersion
                documents[currentIndex].savedText = document.text
                documents[currentIndex].error = nil
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
        documents.remove(at: index)
        if activeID == id { activeID = nil }
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

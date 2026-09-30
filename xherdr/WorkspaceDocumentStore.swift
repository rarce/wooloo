import Foundation

/// The documents open as tabs in the main area: which one is active, the single preview tab,
/// and loading, saving and closing them.
@MainActor
final class WorkspaceDocumentStore: ObservableObject {
    @Published var documents: [WorkspaceDocument] = []
    /// The active document, or `WorkspaceSearchModel.tabID`; nil shows the terminals.
    @Published var activeID: String?

    func document(_ id: String) -> WorkspaceDocument? {
        documents.first { $0.id == id }
    }

    /// Opens a document, or activates it when it is already open. A preview replaces the
    /// previous preview unless that one has unsaved edits.
    func open(_ kind: WorkspaceDocumentKind, path: String, at location: WorkspaceFileLocation,
              reveal: WorkspaceDocumentReveal? = nil, commit: String? = nil, originalPath: String? = nil,
              preview: Bool = false) {
        var document = WorkspaceDocument(location: location, path: path, kind: kind)
        document.reveal = reveal
        document.commit = commit
        document.originalPath = originalPath
        document.isPreview = preview
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            if let reveal { documents[index].reveal = reveal }
            if !preview { documents[index].isPreview = false }
            activeID = document.id
            return
        }
        if preview, let index = documents.firstIndex(where: \.isPreview) {
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

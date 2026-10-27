import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import MarkdownView

enum WorkspaceDocumentKind: String, Codable {
    case file
    case change
    /// A file's diff within a past commit.
    case commit

    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .change: return "arrow.left.arrow.right"
        case .commit: return "clock.arrow.circlepath"
        }
    }
}

/// Whether document editors wrap lines to their width (View > Wrap Lines), for the whole app. The
/// app's defaults are the only place it is kept: views read it with `@AppStorage`, which redraws
/// them when it changes, so open editors rewrap at once.
enum EditorLineWrapping {
    static let storageKey = "EditorWrapLines"

    static func toggle(in defaults: UserDefaults = .standard) {
        defaults.set(!defaults.bool(forKey: storageKey), forKey: storageKey)
    }
}

/// Where to put the cursor when a document opens, e.g. at a search match.
struct WorkspaceDocumentReveal: Equatable {
    let line: Int
    /// UTF-16 range within the line to select.
    let range: NSRange?
    let token = UUID()
}

/// An open file against its file on disk, which something else may write or delete.
enum WorkspaceDiskState: Equatable {
    case current
    /// The file on disk is now this version, while the tab has unsaved edits (or its reload failed).
    case changed(version: String)
    case deleted
}

struct WorkspaceDocument: Identifiable {
    /// Stable backup identity, including across Save As and changes to a draft's display number.
    var backupID = UUID()
    var cursorPositions = [CursorPosition(line: 1, column: 1)]
    var scrollPosition = CGPoint.zero
    /// Where the editor was scrolled, as text; a new editor goes back to it rather than to
    /// `scrollPosition` when there is one.
    var scrollAnchor: EditorScrollAnchor?
    /// nil uses automatic detection and file associations.
    var syntaxOverride: String?

    /// One change, so one update of the document store.
    mutating func recordScroll(_ position: CGPoint, anchor: EditorScrollAnchor?) {
        scrollPosition = position
        scrollAnchor = anchor
    }

    /// The Space whose tab row shows this document; see `WorkspaceDocumentStore.showSpace`.
    var space: String?
    let location: WorkspaceFileLocation
    let path: String
    let kind: WorkspaceDocumentKind
    /// Full hash for `.commit` documents.
    var commit: String?
    /// Pre-rename path for `.commit` documents.
    var originalPath: String?
    var text = ""
    var savedText = ""
    var version: String?
    /// PDFKit state lives with the tab so switching tabs preserves its position and zoom.
    var pdf: PDFPreviewModel?
    var image: ImagePreviewModel?
    /// Identifies the latest load, including a close/reopen of a tab with the same ID.
    var loadRequest = UUID()
    var isLoading = true
    var isSaving = false
    var error: String?
    var reveal: WorkspaceDocumentReveal? {
        didSet { if reveal != nil, markdownMode == .preview { markdownMode = .source } }
    }
    /// Markdown and notebooks open as rendered previews; a search reveal shows the source.
    var markdownMode: MarkdownDisplayMode = .preview
    var supportsPreview: Bool { MarkdownDisplayMode.supports(path) || NotebookDocument.supports(path) }
    /// A `.change` document's patches; more than one when the file has staged and unstaged changes.
    var diffPatches: [WorkspaceDiffScope: String] = [:]
    var diffScope: WorkspaceDiffScope = .all
    /// Opened with a single click in the explorer: the next such file replaces it, until it is
    /// kept open by a double click or an edit.
    var isPreview = false
    /// Set to give the editor the keyboard once it is shown, as Go to File does.
    var focusRequest: UUID?
    /// A new file not yet on disk, shown as "Untitled-N" until it is saved somewhere; its
    /// `path` is empty and `location` is where saving it starts.
    var untitledNumber: Int?
    /// Whether the file on disk still matches `version`; see `WorkspaceDocumentStore.checkDisk`.
    var diskState = WorkspaceDiskState.current
    /// Set when saving would overwrite a newer file on disk, to ask first.
    var asksToOverwrite = false
    /// The version on disk that the question asked about: Overwrite replaces only that one, so a
    /// change that arrives while the question is shown is never overwritten unseen.
    var overwriteVersion: String?
    /// Changes when the store replaces `text` with what is on disk, for a shown editor, which
    /// only reads its text binding when it is created, to take the new text.
    var diskReload: UUID?

    var isUntitled: Bool { untitledNumber != nil }
    var isDeletedOnDisk: Bool { diskState == .deleted }
    /// Whether Save has something to write: edits, or a file deleted on disk to recreate.
    var canSave: Bool { isEditable && (isDirty || isUntitled || isDeletedOnDisk) }
    var isPDF: Bool { kind == .file && !isUntitled && WorkspacePDF.supports(path) }
    var isImage: Bool { kind == .file && !isUntitled && WorkspaceImage.supports(path) }
    var isReadOnly: Bool { isPDF || isImage }
    var isEditable: Bool { kind == .file && !isReadOnly }
    var icon: String {
        if isImage { return "photo" }
        if isPDF { return "doc.richtext" }
        return kind == .file && !isUntitled ? WorkspaceExplorer.fileIcon(path) : kind.icon
    }
    var id: String {
        if isUntitled { return "\(space ?? "")|\(location.identity)|untitled|\(backupID.uuidString)" }
        return "\(space ?? "")|\(location.identity)|\(kind.rawValue)|\(commit ?? "")|\(path)"
    }
    var isDirty: Bool { isEditable && text != savedText }
    /// The patch a diff document shows.
    var patch: String { diffPatches[diffScope] ?? text }
    var diffSource: DiffSource {
        DiffSource(location: location, path: path, originalPath: originalPath, commit: commit,
                   scope: kind == .change ? diffScope : .all)
    }
    /// The path shown for the document: an untitled one has none yet.
    var displayPath: String { isUntitled ? title : path }
    var title: String {
        if let untitledNumber { return "Untitled-\(untitledNumber)" }
        let name = (path as NSString).lastPathComponent
        return commit.map { "\(name) @ \($0.prefix(7))" } ?? name
    }
}

struct WorkspaceDocumentView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @Binding var document: WorkspaceDocument
    let onSave: () -> Void
    var onReload: () -> Void = {}
    /// The file changed on disk under unsaved edits: keep them, so the next save overwrites it.
    var onKeepEdits: () -> Void = {}
    var onCompareDisk: () -> Void = {}
    var onOpenFile: (String) -> Void = { _ in }
    /// Records where the editor is scrolled. The document store looks the document up by id:
    /// `document`, a binding to its index, can outlive that index when a tab before it closes.
    var onScroll: (CGPoint, EditorScrollAnchor?) -> Void = { _, _ in }
    /// Puts the second text in the document while it still has the first, by id like
    /// `onScroll`; false when it changed since. Undo of a cell edit made in a notebook preview
    /// goes through it, so it never overwrites later edits.
    var onReplaceText: (String, String) -> Bool = { _, _ in false }
    /// Receives the command palette's editor commands while this document is shown.
    var commandTarget: EditorCommandTarget?
    /// Whether this document's panel has focus. With split panels several documents show at
    /// once; only the focused one takes the editor commands and ⌘S, ⌘F and ⌘G.
    var isFocused = true
    @State private var commandToken = UUID()
    private var cursorPositions: [CursorPosition] {
        get { document.cursorPositions }
        nonmutating set { document.cursorPositions = newValue }
    }
    @State private var sessionCoordinator = EditorSessionCoordinator()
    @State private var revealCoordinator = EditorRevealCoordinator()
    @State private var lineChangeCoordinator = EditorLineChangeCoordinator()
    @State private var multiCursorCoordinator = EditorMultiCursorCoordinator()
    /// Bumped when the repository may have changed, to reload the change bars' Git bases.
    @State private var gitBasesVersion = 0
    @State private var gitDirectoryWatcher: GitDirectoryWatcher?
    /// Not private so snapshot tests can open the find bar with a query.
    @StateObject var find = DocumentFindModel()
    @State private var previewFocus: MarkdownFindFocus?
    @State private var previewActions = MarkdownPreviewActions()
    @State private var notebookSearchText: [String] = []
    /// Set by Replace so the next match is selected once the edited text comes back.
    @State private var revealsAfterEdit = false
    @AppStorage(DiffDisplayMode.storageKey) private var diffMode = DiffDisplayMode.unified
    @AppStorage(NotebookDiffMode.storageKey) private var notebookDiffMode = NotebookDiffMode.cells
    @Environment(\.undoManager) private var undoManager
    @State private var notebookEditError: String?
    @AppStorage(MarkdownPreviewStyle.storageKey) private var previewStyle = MarkdownPreviewStyle.theme
    @AppStorage(EditorLineWrapping.storageKey) private var wrapsLines = false

    @AppStorage(SyntaxAssociation.storageKey) private var syntaxAssociationsJSON = "[]"
    @State private var diffDetectedSyntax: EditorSyntax?
    /// The diff whose notebook could not be read as cells, so it shows the JSON patch.
    @State private var notebookCellsUnavailable: DiffSource?
    @State private var diffDetectedSource: DiffSource?
    @State private var diffDetectedAssociations: [SyntaxAssociation] = []

    private var syntaxAssociations: [SyntaxAssociation] { SyntaxAssociation.decode(syntaxAssociationsJSON) }
    private var detectedSyntax: EditorSyntax {
        if document.kind != .file, diffDetectedSource == document.diffSource,
           diffDetectedAssociations == syntaxAssociations, let diffDetectedSyntax { return diffDetectedSyntax }
        return EditorSyntax.resolve(path: document.path, text: document.text, associations: syntaxAssociations)
    }
    private var syntax: EditorSyntax {
        EditorSyntax.named(document.syntaxOverride) ?? detectedSyntax
    }

    private var editorTheme: EditorTheme { theme.editorTheme }

    /// A Markdown preview searches its rendered text; the source and split views search the source.
    private var findTarget: DocumentFindModel.Target {
        document.supportsPreview && document.markdownMode == .preview ? .preview : .source
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: document.icon)
                    .foregroundStyle(theme.accent)
                Text(document.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let commit = document.commit {
                    Text(commit.prefix(7))
                        .foregroundStyle(theme.accent)
                        .help(commit)
                }
                Spacer()
                if !document.isReadOnly {
                    EditorSyntaxPicker(detected: detectedSyntax, path: document.path,
                                       selection: Binding(get: { document.syntaxOverride }, set: {
                                           document.syntaxOverride = $0
                                           document.isPreview = false
                                       }), associationsJSON: $syntaxAssociationsJSON)
                }
                Text("\(document.location.machineLabel) · \(document.location.workspaceLabel)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if document.kind == .file && document.supportsPreview {
                    Picker("View", selection: $document.markdownMode) {
                        ForEach(MarkdownDisplayMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    .help("Show the source, the rendered preview, or both")
                    if document.markdownMode != .source {
                        Toggle(isOn: Binding(get: { previewStyle == .document },
                                             set: { previewStyle = $0 ? .document : .theme })) {
                            Image(systemName: previewStyle == .document ? "doc.richtext.fill" : "doc.richtext")
                                .foregroundStyle(previewStyle == .document ? theme.accent : .secondary)
                        }
                        .toggleStyle(.button)
                        .help("Show the preview as a white document page instead of in the theme's colors")
                    }
                }
                if document.diffPatches.count > 1 {
                    Picker("Changes", selection: $document.diffScope) {
                        ForEach(WorkspaceDiffScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    .help("Show all changes since the last commit, only staged changes, or only unstaged changes")
                }
                if document.kind != .file && NotebookDocument.supports(document.path) {
                    Picker("Notebook changes", selection: $notebookDiffMode) {
                        ForEach(NotebookDiffMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    .help("Show the notebook's changes cell by cell, or as changes to its JSON")
                }
                if document.kind != .file && (!showsNotebookCells || notebookCellsUnavailable == document.diffSource) {
                    Picker("View", selection: $diffMode) {
                        ForEach(DiffDisplayMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    .help("Show changes in one column or old and new side by side")
                }
                if document.isEditable {
                    Button(document.isUntitled ? "Save As…" : "Save") { onSave() }
                        .keyboardShortcut(isFocused ? KeyboardShortcut("s", modifiers: .command) : nil)
                        .disabled(document.isLoading || document.isSaving || !document.canSave)
                }
                if document.isReadOnly {
                    Button("Reload", action: onReload)
                        .disabled(document.isLoading)
                        .help("Reload the preview from its local or SSH Space")
                }
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()
            if document.kind == .file && !document.isLoading, let notice = diskNotice {
                diskBanner(notice)
                Divider()
            }
            if document.isEditable && find.isVisible {
                DocumentFindBar(model: find, allowsReplace: findTarget == .source,
                                onReplace: replaceCurrentMatch, onReplaceAll: replaceAllMatches,
                                onSelectAll: selectAllMatches)
                Divider()
            }

            if document.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.error, document.version == nil, !document.isUntitled {
                Text(error)
                    .font(.system(size: typography.emphasis))
                    .foregroundStyle(theme.warning)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if document.kind == .file {
                VStack(spacing: 0) {
                    if let error = document.error {
                        Text(error)
                            .font(.system(size: typography.body))
                            .foregroundStyle(theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    if document.isPDF, let pdf = document.pdf {
                        PDFPreviewView(model: pdf, focusRequest: document.focusRequest,
                                       onFocus: { document.focusRequest = nil })
                    } else if document.isImage, let image = document.image {
                        ImagePreviewView(model: image, focusRequest: document.focusRequest,
                                         onFocus: { document.focusRequest = nil })
                    } else if document.supportsPreview {
                        switch document.markdownMode {
                        case .source: editor
                        case .preview: documentPreview
                        case .split: HSplitView { editor; documentPreview }
                        }
                    } else {
                        editor
                    }
                }
            } else if showsNotebookCells {
                NotebookDiffView(text: document.patch, source: document.diffSource,
                                 onFallback: { notebookCellsUnavailable = $0 ? document.diffSource : nil }) { jsonDiff }
            } else {
                jsonDiff
            }
            Divider()
            HStack {
                Text(document.kind == .file ? (document.isImage ? "\(document.image?.contents.format ?? "Image") · Read only" : document.isPDF ? "PDF · Read only" : document.isDirty ? "Unsaved changes" : NotebookDocument.supports(document.path) ? "Notebook · Saved output" : "UTF-8 text")
                     : (document.kind == .commit ? "Commit diff" : "Git diff"))
                Spacer()
                if document.isEditable, cursorPositions.count > 1 {
                    Text("\(cursorPositions.count) cursors")
                } else if document.isEditable, let cursor = cursorPositions.first {
                    let place = cursor.lineAndColumn(in: document.text)
                    Text("Ln \(place.line), Col \(place.column)")
                }
                if document.isSaving { ProgressView().controlSize(.small) }
            }
            .font(.system(size: typography.secondary))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: 23)
        }
        .background(theme.contentBackground)
        .background {
            if isFocused && document.kind == .file && !document.isImage { findShortcuts }
        }
        .onChange(of: find.isVisible) { _, _ in updateFind(anchor: cursorPositions.first?.range.location) }
        .onChange(of: find.options) { _, _ in
            updateFind(anchor: cursorPositions.first?.range.location)
            if find.current != nil { find.reveal() }
        }
        .onChange(of: document.markdownMode) { _, _ in updateFind(anchor: 0) }
        .onChange(of: document.text) { _, _ in
            updateFind(anchor: nil)
            if revealsAfterEdit {
                revealsAfterEdit = false
                find.reveal()
            }
        }
        .onChange(of: find.current) { _, _ in syncEditorMatches() }
        .onChange(of: find.revealRequest) { _, _ in revealFindMatch() }
        .onAppear { if isFocused { commandTarget?.register(commandToken) { run($0) } } }
        .onDisappear { commandTarget?.unregister(commandToken) }
        .onChange(of: isFocused) { _, focused in
            if focused {
                commandTarget?.register(commandToken) { run($0) }
            } else {
                commandTarget?.unregister(commandToken)
            }
        }
    }

    /// An editor command from the command palette.
    private func run(_ command: EditorCommand) {
        guard document.kind == .file, !document.isImage else { return }
        if document.isPDF {
            guard let pdf = document.pdf, !pdf.isLocked else { return }
            switch command {
            case .find: pdf.openFind()
            case .findNext: pdf.showsFind ? pdf.moveMatch(1) : pdf.openFind()
            case .findPrevious: pdf.showsFind ? pdf.moveMatch(-1) : pdf.openFind()
            default: break
            }
            return
        }
        switch command {
        case .save:
            if document.canSave && !document.isSaving { onSave() }
        case .find: openFind(replace: false)
        case .findAndReplace: openFind(replace: true)
        case .findNext: find.isVisible ? find.move(1) : openFind(replace: false)
        case .findPrevious: find.isVisible ? find.move(-1) : openFind(replace: false)
        case .selectNextOccurrence, .selectPreviousOccurrence, .selectAllOccurrences, .addCursorAbove,
             .addCursorBelow, .undoSelection, .redoSelection:
            multiCursorCoordinator.perform(command)
        }
    }

    /// ⌘F, ⌥⌘F, ⌘G and ⇧⌘G, handled here so they reach the document rather than the terminal.
    private var findShortcuts: some View {
        Group {
            Button("Find") { run(.find) }
                .keyboardShortcut("f", modifiers: .command)
            if !document.isPDF {
                Button("Find and Replace") { openFind(replace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            Button("Find Next") { run(.findNext) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { run(.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var editor: some View {
        HStack(spacing: 0) {
            sourceEditor
            EditorGitOverview(coordinator: lineChangeCoordinator)
                .frame(width: 10)
        }
    }

    private var sourceEditor: some View {
        CodeEditSourceEditor(
            $document.text,
            language: syntax.language,
            theme: editorTheme,
            font: typography.codeFont,
            tabWidth: 4,
            lineHeight: 1.15,
            wrapLines: wrapsLines,
            cursorPositions: $document.cursorPositions,
            highlightProviders: syntax.isConfiguration ? [ConfigurationHighlightProvider()] : [TreeSitterClient()],
            highlightingID: syntax.isConfiguration ? "configuration" : nil,
            coordinators: [revealCoordinator, lineChangeCoordinator, multiCursorCoordinator, sessionCoordinator]
        )
        .onAppear {
            sessionCoordinator.restore(document.reveal == nil ? document.scrollPosition : nil,
                                       anchor: document.scrollAnchor, onScroll: onScroll)
        }
        .onAppear { applyReveal() }
        .onChange(of: document.reveal) { _, _ in applyReveal() }
        .onAppear { applyFocusRequest() }
        .onChange(of: document.focusRequest) { _, _ in applyFocusRequest() }
        .onChange(of: document.diskReload) { _, _ in revealCoordinator.showText(document.text) }
        .onAppear { updateLineChangeColors() }
        .onChange(of: theme.id) { _, _ in updateLineChangeColors() }
        .task(id: "\(document.version ?? "")|\(gitBasesVersion)") { await loadGitBases() }
        .task(id: document.location.identity) { await watchGitDirectory() }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceFiles.repositoryDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)) { notification in
                if notification.name != WorkspaceFiles.repositoryDidChange || notification.object == nil
                    || notification.object as? String == document.location.identity {
                    gitBasesVersion += 1
                }
            }
        .frame(minWidth: 200)
    }

    private var preview: some View {
        previewActions.openFile = onOpenFile
        previewActions.toggleTask = toggleTask
        previewActions.revealLine = revealSource
        let actions = previewActions
        return MarkdownPreviewView(text: document.text, path: document.path, location: document.location,
                                   onOpenFile: { actions.openFile($0) }, highlight: previewHighlight,
                                   focus: previewFocus, onToggleTask: { actions.toggleTask($0, $1) },
                                   onRevealLine: { actions.revealLine($0) })
            .equatable()
            .frame(minWidth: 200)
    }

    @ViewBuilder
    private var documentPreview: some View {
        if NotebookDocument.supports(document.path) {
            NotebookPreviewView(text: document.text, path: document.path, location: document.location,
                                onOpenFile: onOpenFile, style: previewStyle,
                                matches: find.isVisible && findTarget == .preview ? find.previewMatches : [],
                                currentMatch: find.current, revealRequest: find.revealRequest,
                                onSearchText: { text in
                                    guard text != notebookSearchText else { return }
                                    notebookSearchText = text
                                    updateFind(anchor: nil)
                                }, onFindCommand: { key, shift, option in
                                    if key == "escape" { find.close() }
                                    else if key == "f" { openFind(replace: option) }
                                    else if key == "g" { find.isVisible ? find.move(shift ? -1 : 1) : openFind(replace: false) }
                                    else if key == "z" { undoNotebookEdit(redo: shift) }
                                }, onEdit: document.isEditable ? { edit, base in editNotebook(edit, base: base) } : nil)
                .frame(minWidth: 200)
                .alert("Cannot change the notebook", isPresented: Binding(get: { notebookEditError != nil },
                                                                          set: { if !$0 { notebookEditError = nil } })) {
                    Button("OK") { notebookEditError = nil }
                } message: {
                    Text(notebookEditError ?? "")
                }
        } else { preview }
    }

    /// A checkbox clicked in the preview. The change is unsaved, like an edit in the source; in
    /// Split it goes through the editor so ⌘Z undoes it.
    private func toggleTask(line: Int, checked: Bool) {
        guard document.kind == .file, !document.isLoading,
              let edit = MarkdownTasks.toggle(line: line, checked: checked, in: document.text) else { return }
        if document.markdownMode != .split || !revealCoordinator.replace([edit]) {
            document.text = (document.text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        }
    }

    private var jsonDiff: some View {
        WorkspaceDiffView(text: document.patch, source: document.diffSource, mode: diffMode,
                          syntaxOverride: document.syntaxOverride, associations: syntaxAssociations,
                          onDetectedSyntax: {
                              diffDetectedSyntax = $0
                              diffDetectedSource = document.diffSource
                              diffDetectedAssociations = syntaxAssociations
                          })
    }

    private var showsNotebookCells: Bool {
        document.kind != .file && NotebookDocument.supports(document.path) && notebookDiffMode == .cells
    }

    /// A cell edit made in the notebook preview, against the text it was rendered from (an edit
    /// to a page about to be replaced is dropped). Like a checkbox in a Markdown preview, it is
    /// unsaved; in Split it goes through the editor, and in Preview through the window's undo.
    /// Returns whether the notebook changed.
    private func editNotebook(_ edit: NotebookEdit, base: String) -> Bool {
        guard document.kind == .file, !document.isLoading, document.text == base else { return false }
        let replacement: NotebookEditing.Replacement?
        do { replacement = try NotebookEditing.replacement(for: edit, in: base) }
        catch { notebookEditError = error.localizedDescription; return false }
        guard let replacement else { return false }
        if document.markdownMode == .split, let shown = revealCoordinator.text {
            // The range is in `base`; an editor showing other text would take it elsewhere.
            return shown == base && revealCoordinator.replace([(replacement.range, replacement.text)])
        }
        let text = (base as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
        document.text = text
        if let undoManager {
            NotebookUndo.register(undoManager, current: text, previous: base, name: edit.actionName,
                                  replace: onReplaceText)
        }
        return true
    }

    /// ⌘Z or ⇧⌘Z pressed in a notebook preview, outside a cell being edited.
    private func undoNotebookEdit(redo: Bool) {
        if document.markdownMode == .split, revealCoordinator.undo(redo: redo) { return }
        guard let undoManager else { return }
        if redo { if undoManager.canRedo { undoManager.redo() } }
        else if undoManager.canUndo { undoManager.undo() }
    }

    /// A block double-clicked in the preview: shows the source beside it at the block's line.
    private func revealSource(line: Int) {
        guard document.kind == .file else { return }
        if document.markdownMode == .preview { document.markdownMode = .split }
        document.reveal = WorkspaceDocumentReveal(line: line, range: nil)
        document.focusRequest = UUID()
    }

    // MARK: Changes on disk

    /// What the banner under the header says about the file on disk, if anything.
    private var diskNotice: String? {
        switch document.diskState {
        case .current: return nil
        case .changed:
            // Without edits the tab reloads; it stays marked only when that reload failed.
            guard document.isDirty else { return nil }
            return "This file changed on disk. Reload it and discard your edits, or keep them and overwrite the file when you save."
        case .deleted:
            return document.isEditable ? "This file was deleted on disk. Save to create it again."
                : "This file was deleted on disk."
        }
    }

    private func diskBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(notice)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .changed = document.diskState {
                Button("Compare", action: onCompareDisk)
                    .help("Compare a snapshot of your buffer with the file on disk")
                Button("Reload", action: onReload)
                    .help("Read the file again, discarding your unsaved edits")
                Button("Keep Mine", action: onKeepEdits)
                    .help("Keep your edits; saving overwrites the file on disk")
            }
        }
        .font(.system(size: typography.body))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.warning.opacity(0.12))
    }

    // MARK: Change bars

    private func updateLineChangeColors() {
        lineChangeCoordinator.setColors(added: NSColor(theme.vcs(.added)), modified: NSColor(theme.vcs(.modified)),
                                        deleted: NSColor(theme.vcs(.deleted)))
    }

    private func loadGitBases() async {
        guard document.version != nil else { return }
        let (path, location) = (document.path, document.location)
        guard let bases = await WorkspaceFiles.blocking(at: location, priority: .utility, {
            Optional(WorkspaceFiles.gitBases(path, at: location))
        }) else { return }
        guard !Task.isCancelled else { return }
        lineChangeCoordinator.setBases(head: bases.head, index: bases.index)
    }

    /// Reloads the Git bases when the index or HEAD changes, e.g. after staging or committing in
    /// a terminal. Local repositories only; over SSH the bases reload on refresh or reactivation.
    private func watchGitDirectory() async {
        let location = document.location
        // Not over SSH, where it would only wait for a slot of the machine to learn nothing.
        guard location.isLocal else {
            gitDirectoryWatcher = nil
            return
        }
        let directory = await WorkspaceFiles.blocking(at: location, priority: .utility) {
            WorkspaceFiles.localGitDirectory(at: location)
        }
        guard !Task.isCancelled else { return }
        gitDirectoryWatcher = directory.flatMap { GitDirectoryWatcher(directory: $0) { gitBasesVersion += 1 } }
    }

    // MARK: Find

    private var previewHighlight: MarkdownSearchHighlight? {
        guard find.isVisible, findTarget == .preview, !find.previewMatches.isEmpty else { return nil }
        var matches: [String: [MarkdownSearchHighlight.Match]] = [:]
        for (index, match) in find.previewMatches.enumerated() {
            matches[match.key, default: []].append(.init(range: match.range, index: index))
        }
        return MarkdownSearchHighlight(matches: matches, current: find.current,
                                       color: theme.matchHighlight, currentColor: theme.activeMatchHighlight)
    }

    private func openFind(replace: Bool) {
        if replace, NotebookDocument.supports(document.path), document.markdownMode == .preview {
            document.markdownMode = .source
        }
        var selected: String?
        if findTarget == .source, let range = cursorPositions.first?.range, range.length > 0,
           NSMaxRange(range) <= (document.text as NSString).length {
            selected = (document.text as NSString).substring(with: range)
        }
        find.open(replace: replace, query: selected)
        updateFind(anchor: cursorPositions.first?.range.location)
    }

    private func updateFind(anchor: Int?) {
        find.update(text: document.text, target: findTarget, anchor: anchor,
                    previewTextNodes: NotebookDocument.supports(document.path) ? notebookSearchText : nil)
        syncEditorMatches()
    }

    private func syncEditorMatches() {
        let ranges = find.isVisible && findTarget == .source ? find.sourceMatches.map(\.range) : []
        revealCoordinator.setFindMatches(ranges, current: find.current,
                                         color: NSColor(theme.matchHighlight),
                                         currentColor: NSColor(theme.activeMatchHighlight))
    }

    /// Selects the current match in the editor, or scrolls the preview to its block.
    private func revealFindMatch() {
        guard let current = find.current else { return }
        switch find.target {
        case .source:
            guard current < find.sourceMatches.count else { return }
            let range = find.sourceMatches[current].range
            // Selected through the coordinator, which records each match stepped to from the find
            // bar as a ⌘U step and scrolls to it; the editor, without the keyboard, does not
            // report it to the binding.
            multiCursorCoordinator.reveal(range)
            cursorPositions = [CursorPosition(range: range)]
        case .preview:
            guard current < find.previewMatches.count else { return }
            previewFocus = MarkdownFindFocus(block: find.previewMatches[current].block, match: current)
        }
    }

    private func replaceCurrentMatch() {
        guard find.target == .source, let current = find.current, current < find.sourceMatches.count else { return }
        let match = find.sourceMatches[current]
        // The edit updates the text binding, which recomputes matches keeping the index: the next match.
        revealsAfterEdit = true
        revealCoordinator.replace([(match.range, find.replacementText(for: match, in: document.text))])
    }

    private func replaceAllMatches() {
        guard find.target == .source, !find.sourceMatches.isEmpty else { return }
        let text = document.text
        revealCoordinator.replace(find.sourceMatches.map { ($0.range, find.replacementText(for: $0, in: text)) })
    }

    /// ⌥↩ in the find bar: a cursor on every match, then back to the editor as in Zed.
    private func selectAllMatches() {
        guard find.target == .source, !find.sourceMatches.isEmpty else { return }
        let ranges = find.sourceMatches.map(\.range)
        let current = find.current.flatMap { $0 < ranges.count ? ranges[$0] : nil }
        find.close()
        multiCursorCoordinator.select(ranges, newest: current)
    }

    /// Selects the requested line or match and scrolls it into view.
    private func applyReveal() {
        guard let reveal = document.reveal,
              let line = WorkspaceSearch.range(ofLine: reveal.line, in: document.text as NSString) else { return }
        // A column typed in Go to File can lie past the end of the line.
        let selection = reveal.range.map {
            let start = min($0.location, line.length)
            return NSRange(location: line.location + start, length: min($0.length, line.length - start))
        } ?? NSRange(location: line.location, length: 0)
        cursorPositions = [CursorPosition(range: selection)]
        document.reveal = nil
        DispatchQueue.main.async {
            revealCoordinator.scrollSelectionToVisible()
            multiCursorCoordinator.syncSelection()
        }
    }

    private func applyFocusRequest() {
        guard document.focusRequest != nil else { return }
        document.focusRequest = nil
        revealCoordinator.focus()
    }
}

/// Keeps the editor controller so a reveal can scroll the new selection into view, find matches
/// can be highlighted, and replacements go through the editor's undo stack.
final class EditorRevealCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?
    private var findRanges: [NSRange] = []
    private var currentFind: Int?
    private var findColor = NSColor.systemYellow
    private var currentFindColor = NSColor.systemOrange
    private var findLayers: [CALayer] = []
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var redrawsAfterLayout = false
    private var focusesWhenReady = false

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        drawFindMatches()
        // The text view joins its window after this returns.
        if focusesWhenReady { DispatchQueue.main.async { [weak self] in self?.focus() } }
    }

    func scrollSelectionToVisible() { controller?.textView.scrollSelectionToVisible() }

    /// The text the editor shows, or nil when no editor is shown.
    var text: String? { controller?.textView.string }

    /// Undoes or redoes the editor's last change, for ⌘Z pressed in a preview beside it.
    /// Returns false when no editor is shown.
    @discardableResult
    func undo(redo: Bool) -> Bool {
        guard let undo = controller?.textView._undoManager else { return false }
        if redo { undo.redo() } else { undo.undo() }
        return true
    }

    /// Puts text the document read again from disk into the editor, replacing only the part that
    /// differs, so the cursors and the scroll position stay where they were as far as possible.
    /// The replacement can be undone, as in VS Code.
    func showText(_ text: String) {
        guard let textView = controller?.textView, textView.string != text else { return }
        let old = textView.string as NSString
        let new = text as NSString
        let range = Self.changedRange(from: old, to: new)
        let replacement = new.substring(with: NSRange(location: range.location,
                                                      length: new.length - (old.length - range.length)))
        replace([(range, replacement)])
    }

    /// The range of `old` that differs from `new`, after their common prefix and before their common
    /// suffix, never splitting a surrogate pair.
    static func changedRange(from old: NSString, to new: NSString) -> NSRange {
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < shorter - prefix
                && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
        return NSRange(location: prefix, length: old.length - prefix - suffix)
    }

    /// Gives the editor the keyboard, now or once its text view is in a window.
    func focus() {
        guard let textView = controller?.textView, let window = textView.window else {
            focusesWhenReady = true
            return
        }
        focusesWhenReady = false
        window.makeFirstResponder(textView)
    }

    func textViewDidChangeText(controller: TextViewController) {
        // Ranges are stale until the find bar recomputes them from the new text.
        removeFindLayers()
    }

    func destroy() {
        removeFindLayers()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        scrollObserver = nil
        frameObserver = nil
        controller = nil
    }

    func setFindMatches(_ ranges: [NSRange], current: Int?, color: NSColor, currentColor: NSColor) {
        findRanges = ranges
        currentFind = current
        findColor = color
        currentFindColor = currentColor
        drawFindMatches()
    }

    /// Replaces ranges from last to first as one undoable edit.
    /// Returns false when no editor is shown to take the edit.
    @discardableResult
    func replace(_ replacements: [(range: NSRange, text: String)]) -> Bool {
        guard let textView = controller?.textView, textView.isEditable else { return false }
        let undo = textView._undoManager
        undo?.beginGrouping()
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            textView.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        undo?.endGrouping()
        return true
    }

    private func removeFindLayers() {
        findLayers.forEach { $0.removeFromSuperlayer() }
        findLayers = []
    }

    /// Draws a highlight under each visible match, redrawn as the editor scrolls.
    private func drawFindMatches() {
        removeFindLayers()
        guard let textView = controller?.textView else { return }
        if scrollObserver == nil, let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in self?.drawFindMatches() }
        }
        if frameObserver == nil {
            // The text resizes when it rewraps, as when line wrapping turns on or off or the editor
            // resizes with wrapping on; draw again once the lines are laid out where they now go.
            textView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in self?.drawFindMatchesAfterLayout() }
        }
        guard !findRanges.isEmpty, let visible = textView.visibleTextRange else { return }
        let text = textView.textStorage.string as NSString
        let first = findRanges.partitioningIndex { NSMaxRange($0) >= visible.location }
        for index in findRanges.indices[first...] {
            let range = findRanges[index]
            guard range.location <= NSMaxRange(visible), NSMaxRange(range) <= text.length else { break }
            let color = index == currentFind ? currentFindColor : findColor
            // One rectangle per line, so matches spanning newlines are covered too.
            var start = range.location
            while start < NSMaxRange(range) {
                let newline = text.range(of: "\n", range: NSRange(location: start, length: NSMaxRange(range) - start))
                let end = newline.location == NSNotFound ? NSMaxRange(range) : newline.location
                if end > start { drawFindRows(from: start, to: end, color: color, in: textView) }
                start = end + 1
            }
        }
    }

    private func drawFindMatchesAfterLayout() {
        guard !findRanges.isEmpty, !redrawsAfterLayout else { return }
        redrawsAfterLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            redrawsAfterLayout = false
            controller?.textView.layoutSubtreeIfNeeded()
            drawFindMatches()
        }
    }

    /// One rectangle per row of `start..<end`, which lies in one line: with line wrapping on, a
    /// match can cross into the next row.
    private func drawFindRows(from start: Int, to end: Int, color: NSColor, in textView: TextView) {
        let layout = textView.layoutManager
        var location = start
        while location < end, let lower = layout?.rectForOffset(location),
              let line = layout?.textLineForOffset(location),
              let row = line.data.lineFragments.getLine(atOffset: location - line.range.location) {
            let rowEnd = min(end, line.range.location + row.range.max)
            guard rowEnd > location, let last = layout?.rectForOffset(rowEnd - 1) else { return }
            let layer = CALayer()
            layer.frame = CGRect(x: lower.minX, y: lower.minY, width: max(last.maxX - lower.minX, 2),
                                 height: lower.height)
            layer.cornerRadius = 2
            layer.backgroundColor = color.cgColor
            textView.layer?.insertSublayer(layer, at: 1)
            findLayers.append(layer)
            location = rowEnd
        }
    }
}

extension CursorPosition {
    /// The editor fills in line and column once it reports a selection; a position set from a
    /// range, such as one restored after a relaunch, has -1 until then.
    func lineAndColumn(in text: String) -> (line: Int, column: Int) {
        if line > 0, column > 0 { return (line, column) }
        let string = text as NSString
        let location = range.location == NSNotFound ? 0 : min(max(range.location, 0), string.length)
        var line = 1, start = 0
        while start < location {
            var end = 0, contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            // The last line has no line break to step over.
            guard end > contentsEnd, end <= location else { break }
            line += 1
            start = end
        }
        // Columns count UTF-16 units from the line's start, as the editor does.
        return (line, location - start + 1)
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, for a predicate that is false then true.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

/// Undo for edits made outside the editor, such as a notebook cell changed in its preview. Each
/// step puts the text back only while the document still has the text the step left, so undoing
/// after the document changed some other way does nothing rather than losing that change.
enum NotebookUndo {
    private static let target = NSObject()

    static func register(_ manager: UndoManager, current: String, previous: String, name: String,
                         replace: @escaping (String, String) -> Bool) {
        manager.registerUndo(withTarget: target) { [weak manager] _ in
            guard replace(current, previous), let manager else { return }
            register(manager, current: previous, previous: current, name: name, replace: replace)
        }
        manager.setActionName(name)
    }
}

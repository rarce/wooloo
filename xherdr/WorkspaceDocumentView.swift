import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import MarkdownView

enum WorkspaceDocumentKind: String {
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

/// Where to put the cursor when a document opens, e.g. at a search match.
struct WorkspaceDocumentReveal: Equatable {
    let line: Int
    /// UTF-16 range within the line to select.
    let range: NSRange?
    let token = UUID()
}

struct WorkspaceDocument: Identifiable {
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

    var isUntitled: Bool { untitledNumber != nil }
    var isPDF: Bool { kind == .file && !isUntitled && WorkspacePDF.supports(path) }
    var isEditable: Bool { kind == .file && !isPDF }
    var id: String {
        if let untitledNumber { return "\(space ?? "")|\(location.identity)|untitled|\(untitledNumber)" }
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
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @Binding var document: WorkspaceDocument
    let onSave: () -> Void
    var onReload: () -> Void = {}
    var onOpenFile: (String) -> Void = { _ in }
    /// Receives the command palette's editor commands while this document is shown.
    var commandTarget: EditorCommandTarget?
    @State private var commandToken = UUID()
    @State private var cursorPositions = [CursorPosition(line: 1, column: 1)]
    @State private var revealCoordinator = EditorRevealCoordinator()
    @State private var lineChangeCoordinator = EditorLineChangeCoordinator()
    @State private var multiCursorCoordinator = EditorMultiCursorCoordinator()
    /// Bumped when the repository may have changed, to reload the change bars' Git bases.
    @State private var gitBasesVersion = 0
    @State private var gitDirectoryWatcher: GitDirectoryWatcher?
    /// Not private so snapshot tests can open the find bar with a query.
    @StateObject var find = DocumentFindModel()
    @State private var previewFocus: MarkdownFindFocus?
    @State private var notebookSearchText: [String] = []
    /// Set by Replace so the next match is selected once the edited text comes back.
    @State private var revealsAfterEdit = false
    @AppStorage(DiffDisplayMode.storageKey) private var diffMode = DiffDisplayMode.unified
    @AppStorage(MarkdownPreviewStyle.storageKey) private var previewStyle = MarkdownPreviewStyle.theme

    private var language: CodeLanguage {
        if NotebookDocument.supports(document.path) { return .json }
        return CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: document.path),
            prefixBuffer: String(document.text.prefix(512)),
            suffixBuffer: String(document.text.suffix(512))
        )
    }

    private var editorTheme: EditorTheme { theme.editorTheme }

    /// A Markdown preview searches its rendered text; the source and split views search the source.
    private var findTarget: DocumentFindModel.Target {
        document.supportsPreview && document.markdownMode == .preview ? .preview : .source
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: document.isPDF ? "doc.richtext" : document.kind.icon)
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
                if document.kind != .file {
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
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(document.isLoading || document.isSaving || !(document.isDirty || document.isUntitled))
                }
                if document.isPDF {
                    Button("Reload", action: onReload)
                        .disabled(document.isLoading)
                        .help("Reload the PDF from its local or SSH Space")
                }
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()
            if document.kind == .file && !document.isPDF && find.isVisible {
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
            } else {
                WorkspaceDiffView(text: document.patch, source: document.diffSource, mode: diffMode)
            }
            Divider()
            HStack {
                Text(document.kind == .file ? (document.isPDF ? "PDF · Read only" : document.isDirty ? "Unsaved changes" : NotebookDocument.supports(document.path) ? "Notebook · Saved output" : "UTF-8 text")
                     : (document.kind == .commit ? "Commit diff" : "Git diff"))
                Spacer()
                if document.isEditable, cursorPositions.count > 1 {
                    Text("\(cursorPositions.count) cursors")
                } else if document.isEditable, let cursor = cursorPositions.first {
                    Text("Ln \(cursor.line), Col \(cursor.column)")
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
            if document.kind == .file { findShortcuts }
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
        .onAppear { commandTarget?.register(commandToken) { run($0) } }
        .onDisappear { commandTarget?.unregister(commandToken) }
    }

    /// An editor command from the command palette.
    private func run(_ command: EditorCommand) {
        guard document.kind == .file else { return }
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
            if (document.isDirty || document.isUntitled) && !document.isSaving { onSave() }
        case .find: openFind(replace: false)
        case .findAndReplace: openFind(replace: true)
        case .findNext: find.isVisible ? find.move(1) : openFind(replace: false)
        case .findPrevious: find.isVisible ? find.move(-1) : openFind(replace: false)
        case .selectNextOccurrence, .selectAllOccurrences, .addCursorAbove, .addCursorBelow, .undoSelection:
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
        CodeEditSourceEditor(
            $document.text,
            language: language,
            theme: editorTheme,
            font: typography.codeFont,
            tabWidth: 4,
            lineHeight: 1.15,
            wrapLines: false,
            cursorPositions: $cursorPositions,
            coordinators: [revealCoordinator, lineChangeCoordinator, multiCursorCoordinator]
        )
        .onAppear { applyReveal() }
        .onChange(of: document.reveal) { _, _ in applyReveal() }
        .onAppear { applyFocusRequest() }
        .onChange(of: document.focusRequest) { _, _ in applyFocusRequest() }
        .onAppear { updateLineChangeColors() }
        .onChange(of: theme.id) { _, _ in updateLineChangeColors() }
        .task(id: "\(document.version ?? "")|\(gitBasesVersion)") { await loadGitBases() }
        .task(id: document.location.identity) { await watchGitDirectory() }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceFiles.repositoryDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)) { _ in gitBasesVersion += 1 }
        .frame(minWidth: 200)
    }

    private var preview: some View {
        MarkdownPreviewView(text: document.text, path: document.path, location: document.location,
                            onOpenFile: onOpenFile, highlight: previewHighlight, focus: previewFocus,
                            onToggleTask: toggleTask, onRevealLine: revealSource)
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
                                })
                .frame(minWidth: 200)
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

    /// A block double-clicked in the preview: shows the source beside it at the block's line.
    private func revealSource(line: Int) {
        guard document.kind == .file else { return }
        if document.markdownMode == .preview { document.markdownMode = .split }
        document.reveal = WorkspaceDocumentReveal(line: line, range: nil)
        document.focusRequest = UUID()
    }

    // MARK: Change bars

    private func updateLineChangeColors() {
        lineChangeCoordinator.setColors(added: NSColor(theme.vcs(.added)), modified: NSColor(theme.vcs(.modified)),
                                        deleted: NSColor(theme.vcs(.deleted)))
    }

    private func loadGitBases() async {
        guard document.version != nil else { return }
        let (path, location) = (document.path, document.location)
        let bases = await Task.detached(priority: .utility) {
            WorkspaceFiles.gitBases(path, at: location)
        }.value
        guard !Task.isCancelled else { return }
        lineChangeCoordinator.setBases(head: bases.head, index: bases.index)
    }

    /// Reloads the Git bases when the index or HEAD changes, e.g. after staging or committing in
    /// a terminal. Local repositories only; over SSH the bases reload on refresh or reactivation.
    private func watchGitDirectory() async {
        let location = document.location
        let directory = await Task.detached(priority: .utility) {
            WorkspaceFiles.localGitDirectory(at: location)
        }.value
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
            cursorPositions = [CursorPosition(range: find.sourceMatches[current].range)]
            DispatchQueue.main.async { revealCoordinator.scrollSelectionToVisible() }
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
        DispatchQueue.main.async { revealCoordinator.scrollSelectionToVisible() }
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
    private var focusesWhenReady = false

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        drawFindMatches()
        // The text view joins its window after this returns.
        if focusesWhenReady { DispatchQueue.main.async { [weak self] in self?.focus() } }
    }

    func scrollSelectionToVisible() { controller?.textView.scrollSelectionToVisible() }

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
        scrollObserver = nil
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
                if end > start, let lower = textView.layoutManager.rectForOffset(start),
                   let upper = textView.layoutManager.rectForOffset(end) {
                    let width = upper.minY == lower.minY ? upper.minX - lower.minX : lower.width
                    let layer = CALayer()
                    layer.frame = CGRect(x: lower.minX, y: lower.minY, width: max(width, 2), height: lower.height)
                    layer.cornerRadius = 2
                    layer.backgroundColor = color.cgColor
                    textView.layer?.insertSublayer(layer, at: 1)
                    findLayers.append(layer)
                }
                start = end + 1
            }
        }
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

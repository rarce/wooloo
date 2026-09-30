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
    var isLoading = true
    var isSaving = false
    var error: String?
    var reveal: WorkspaceDocumentReveal? {
        didSet { if reveal != nil, markdownMode == .preview { markdownMode = .source } }
    }
    /// Markdown files open as a rendered preview; a reveal (e.g. a search match) shows the source.
    var markdownMode: MarkdownDisplayMode = .preview
    /// A `.change` document's patches; more than one when the file has staged and unstaged changes.
    var diffPatches: [WorkspaceDiffScope: String] = [:]
    var diffScope: WorkspaceDiffScope = .all
    /// Opened with a single click in the explorer: the next such file replaces it, until it is
    /// kept open by a double click or an edit.
    var isPreview = false

    var id: String { "\(space ?? "")|\(location.identity)|\(kind.rawValue)|\(commit ?? "")|\(path)" }
    var isDirty: Bool { kind == .file && text != savedText }
    /// The patch a diff document shows.
    var patch: String { diffPatches[diffScope] ?? text }
    var diffSource: DiffSource {
        DiffSource(location: location, path: path, originalPath: originalPath, commit: commit,
                   scope: kind == .change ? diffScope : .all)
    }
    var title: String {
        let name = (path as NSString).lastPathComponent
        return commit.map { "\(name) @ \($0.prefix(7))" } ?? name
    }
}

struct WorkspaceDocumentView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @Binding var document: WorkspaceDocument
    let onSave: () -> Void
    var onOpenFile: (String) -> Void = { _ in }
    @State private var cursorPositions = [CursorPosition(line: 1, column: 1)]
    @State private var revealCoordinator = EditorRevealCoordinator()
    @State private var lineChangeCoordinator = EditorLineChangeCoordinator()
    /// Bumped when the repository may have changed, to reload the change bars' Git bases.
    @State private var gitBasesVersion = 0
    @State private var gitDirectoryWatcher: GitDirectoryWatcher?
    /// Not private so snapshot tests can open the find bar with a query.
    @StateObject var find = DocumentFindModel()
    @State private var previewFocus: MarkdownFindFocus?
    /// Set by Replace so the next match is selected once the edited text comes back.
    @State private var revealsAfterEdit = false
    @AppStorage(DiffDisplayMode.storageKey) private var diffMode = DiffDisplayMode.unified

    private var language: CodeLanguage {
        CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: document.path),
            prefixBuffer: String(document.text.prefix(512)),
            suffixBuffer: String(document.text.suffix(512))
        )
    }

    private var editorTheme: EditorTheme { theme.editorTheme }

    /// A Markdown preview searches its rendered text; the source and split views search the source.
    private var findTarget: DocumentFindModel.Target {
        MarkdownDisplayMode.supports(document.path) && document.markdownMode == .preview ? .preview : .source
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: document.kind.icon)
                    .foregroundStyle(theme.accent)
                Text(document.path)
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
                if document.kind == .file && MarkdownDisplayMode.supports(document.path) {
                    Picker("View", selection: $document.markdownMode) {
                        ForEach(MarkdownDisplayMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    .help("Show the Markdown source, the rendered preview, or both")
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
                if document.kind == .file {
                    Button("Save") { onSave() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(document.isLoading || document.isSaving || !document.isDirty)
                }
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()
            if document.kind == .file && find.isVisible {
                DocumentFindBar(model: find, allowsReplace: findTarget == .source,
                                onReplace: replaceCurrentMatch, onReplaceAll: replaceAllMatches)
                Divider()
            }

            if document.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.error, document.version == nil {
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
                    if MarkdownDisplayMode.supports(document.path) {
                        switch document.markdownMode {
                        case .source: editor
                        case .preview: preview
                        case .split: HSplitView { editor; preview }
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
                Text(document.kind == .file ? (document.isDirty ? "Unsaved changes" : "UTF-8 text")
                     : (document.kind == .commit ? "Commit diff" : "Git diff"))
                Spacer()
                if document.kind == .file, let cursor = cursorPositions.first {
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
    }

    /// ⌘F, ⌥⌘F, ⌘G and ⇧⌘G, handled here so they reach the document rather than the terminal.
    private var findShortcuts: some View {
        Group {
            Button("Find") { openFind(replace: false) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find and Replace") { openFind(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { find.isVisible ? find.move(1) : openFind(replace: false) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { find.isVisible ? find.move(-1) : openFind(replace: false) }
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
            coordinators: [revealCoordinator, lineChangeCoordinator]
        )
        .onAppear { applyReveal() }
        .onChange(of: document.reveal) { _, _ in applyReveal() }
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
                            onOpenFile: onOpenFile, highlight: previewHighlight, focus: previewFocus)
            .frame(minWidth: 200)
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
        var selected: String?
        if findTarget == .source, let range = cursorPositions.first?.range, range.length > 0,
           NSMaxRange(range) <= (document.text as NSString).length {
            selected = (document.text as NSString).substring(with: range)
        }
        find.open(replace: replace, query: selected)
        updateFind(anchor: cursorPositions.first?.range.location)
    }

    private func updateFind(anchor: Int?) {
        find.update(text: document.text, target: findTarget, anchor: anchor)
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

    /// Selects the requested line or match and scrolls it into view.
    private func applyReveal() {
        guard let reveal = document.reveal,
              let line = WorkspaceSearch.range(ofLine: reveal.line, in: document.text as NSString) else { return }
        let selection = reveal.range.map { NSRange(location: line.location + $0.location, length: $0.length) }
            ?? NSRange(location: line.location, length: 0)
        cursorPositions = [CursorPosition(range: selection)]
        document.reveal = nil
        DispatchQueue.main.async { revealCoordinator.scrollSelectionToVisible() }
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

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        drawFindMatches()
    }

    func scrollSelectionToVisible() { controller?.textView.scrollSelectionToVisible() }

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
    func replace(_ replacements: [(range: NSRange, text: String)]) {
        guard let textView = controller?.textView, textView.isEditable else { return }
        let undo = textView._undoManager
        undo?.beginGrouping()
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            textView.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        undo?.endGrouping()
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

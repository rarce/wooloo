import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

enum WorkspaceDocumentKind: String {
    case file
    case change

    var icon: String { self == .file ? "doc.text" : "arrow.left.arrow.right" }
}

/// Where to put the cursor when a document opens, e.g. at a search match.
struct WorkspaceDocumentReveal: Equatable {
    let line: Int
    /// UTF-16 range within the line to select.
    let range: NSRange?
    let token = UUID()
}

struct WorkspaceDocument: Identifiable {
    let location: WorkspaceFileLocation
    let path: String
    let kind: WorkspaceDocumentKind
    var text = ""
    var savedText = ""
    var version: String?
    var isLoading = true
    var isSaving = false
    var error: String?
    var reveal: WorkspaceDocumentReveal?

    var id: String { "\(location.identity)|\(kind.rawValue)|\(path)" }
    var isDirty: Bool { kind == .file && text != savedText }
    var title: String { (path as NSString).lastPathComponent }
}

struct WorkspaceDocumentView: View {
    @Environment(\.xherdrTheme) private var theme
    @Binding var document: WorkspaceDocument
    let onSave: () -> Void
    @State private var cursorPositions = [CursorPosition(line: 1, column: 1)]
    @State private var revealCoordinator = EditorRevealCoordinator()

    private var language: CodeLanguage {
        CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: document.path),
            prefixBuffer: String(document.text.prefix(512)),
            suffixBuffer: String(document.text.suffix(512))
        )
    }

    private var editorTheme: EditorTheme { theme.editorTheme }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: document.kind.icon)
                    .foregroundStyle(theme.accent)
                Text(document.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(document.location.machineLabel) · \(document.location.workspaceLabel)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if document.kind == .file {
                    Button("Save") { onSave() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(document.isLoading || document.isSaving || !document.isDirty)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()

            if document.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.error, document.version == nil {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warning)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if document.kind == .file {
                VStack(spacing: 0) {
                    if let error = document.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    CodeEditSourceEditor(
                        $document.text,
                        language: language,
                        theme: editorTheme,
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                        tabWidth: 4,
                        lineHeight: 1.15,
                        wrapLines: false,
                        cursorPositions: $cursorPositions,
                        coordinators: [revealCoordinator]
                    )
                    .onAppear { applyReveal() }
                    .onChange(of: document.reveal) { _, _ in applyReveal() }
                }
            } else {
                GeometryReader { viewport in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(document.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(String(line).isEmpty ? " " : String(line))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(diffColor(String(line)))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(diffBackground(String(line)))
                            }
                        }
                        .frame(minWidth: viewport.size.width, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
            }
            Divider()
            HStack {
                Text(document.kind == .file ? (document.isDirty ? "Unsaved changes" : "UTF-8 text") : "Git diff")
                Spacer()
                if document.kind == .file, let cursor = cursorPositions.first {
                    Text("Ln \(cursor.line), Col \(cursor.column)")
                }
                if document.isSaving { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: 23)
        }
        .background(theme.contentBackground)
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

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return theme.accent }
        if line.hasPrefix("@@") { return theme.diffHunk }
        if line.hasPrefix("+") { return theme.diffAdded }
        if line.hasPrefix("-") { return theme.diffRemoved }
        return .primary
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return theme.diffAdded.opacity(0.1) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return theme.diffRemoved.opacity(0.1) }
        if line.hasPrefix("@@") { return theme.diffHunk.opacity(0.1) }
        return .clear
    }
}

/// Keeps the editor controller so a reveal can scroll the new selection into view.
final class EditorRevealCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }

    func scrollSelectionToVisible() { controller?.textView.scrollSelectionToVisible() }

    func destroy() { controller = nil }
}

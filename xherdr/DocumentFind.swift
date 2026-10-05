import AppKit
import Markdown
import MarkdownView
import SwiftUI

/// A match in rendered Markdown: a range of one `Text` or `InlineCode` node.
struct MarkdownFindMatch {
    let key: String
    let range: Range<Int>
    /// Index of the top-level block that contains it, for scrolling.
    let block: Int
}

/// The preview block to scroll to for the current match.
struct MarkdownFindFocus: Equatable {
    let block: Int
    let match: Int
}

/// Find and replace within one open document, like an editor's ⌘F bar. The source is searched
/// as text; a Markdown preview is searched as the text it renders.
@MainActor
final class DocumentFindModel: ObservableObject {
    enum Target { case source, preview }

    static let maximumMatches = 10_000

    @Published var isVisible = false
    @Published var showsReplace = false
    @Published var options = WorkspaceSearchOptions()
    @Published var replacement = ""
    @Published private(set) var sourceMatches: [NSTextCheckingResult] = []
    @Published private(set) var previewMatches: [MarkdownFindMatch] = []
    @Published private(set) var current: Int?
    @Published private(set) var error: String?
    /// Changes when the query field should take focus.
    @Published private(set) var focusRequest = 0
    /// Changes when the current match should be selected and scrolled into view.
    @Published private(set) var revealRequest = 0
    private(set) var target: Target = .source
    private(set) var expression: NSRegularExpression?

    var count: Int { target == .source ? sourceMatches.count : previewMatches.count }
    var isTruncated: Bool { count >= Self.maximumMatches }

    func open(replace: Bool, query: String?) {
        if let query, !query.isEmpty, !query.contains("\n") {
            options.query = options.regex ? NSRegularExpression.escapedPattern(for: query) : query
        }
        isVisible = true
        if replace { showsReplace = true }
        focusRequest += 1
    }

    func close() {
        isVisible = false
        sourceMatches = []
        previewMatches = []
        current = nil
    }

    /// Recomputes matches. With `anchor`, the current match becomes the first one at or after it;
    /// otherwise the current index is kept, so after a replacement it points at the next match.
    func update(text: String, target: Target, anchor: Int?, previewTextNodes: [String]? = nil) {
        self.target = target
        guard isVisible, !options.query.isEmpty else {
            expression = nil
            error = nil
            sourceMatches = []
            previewMatches = []
            current = nil
            return
        }
        do {
            let expression = try WorkspaceSearch.expression(for: options)
            self.expression = expression
            error = nil
            switch target {
            case .source:
                var matches: [NSTextCheckingResult] = []
                expression.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
                    guard let match, match.range.length > 0 else { return }
                    matches.append(match)
                    if matches.count >= Self.maximumMatches { stop.pointee = true }
                }
                sourceMatches = matches
                previewMatches = []
            case .preview:
                if let previewTextNodes {
                    var matches: [MarkdownFindMatch] = []
                    for (block, string) in previewTextNodes.enumerated() {
                        expression.enumerateMatches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) { match, _, stop in
                            guard let match, match.range.length > 0 else { return }
                            matches.append(MarkdownFindMatch(key: "notebook-\(block)", range: match.range.location..<NSMaxRange(match.range), block: block))
                            if matches.count >= Self.maximumMatches { stop.pointee = true }
                        }
                        if matches.count >= Self.maximumMatches { break }
                    }
                    previewMatches = matches
                } else { previewMatches = Self.markdownMatches(in: text, expression: expression) }
                sourceMatches = []
            }
        } catch {
            self.expression = nil
            self.error = error.localizedDescription
            sourceMatches = []
            previewMatches = []
        }
        if count == 0 {
            current = nil
        } else if let anchor, target == .source {
            current = sourceMatches.firstIndex { $0.range.location >= anchor } ?? 0
        } else if anchor != nil {
            current = 0
        } else {
            current = min(current ?? 0, count - 1)
        }
    }

    func move(_ delta: Int) {
        guard count > 0 else { return }
        current = ((current ?? (delta > 0 ? -1 : 0)) + delta + count) % count
        revealRequest += 1
    }

    func reveal() { revealRequest += 1 }

    /// The replacement text for a source match, expanding `$1` and escapes in regex mode.
    func replacementText(for match: NSTextCheckingResult, in text: String) -> String {
        guard let expression else { return replacement }
        return expression.replacementString(for: match, in: text, offset: 0,
                                            template: WorkspaceSearch.template(replacement, regex: options.regex))
    }

    // MARK: Markdown

    /// Matches in the text MarkdownView renders, in document order. Images, code blocks and HTML
    /// aren't rendered as searchable text and are skipped.
    private static func markdownMatches(in markdown: String, expression: NSRegularExpression) -> [MarkdownFindMatch] {
        var walker = MarkdownFindWalker(expression: expression)
        walker.visit(Document(parsing: markdown))
        return walker.matches
    }
}

private struct MarkdownFindWalker: MarkupWalker {
    let expression: NSRegularExpression
    var matches: [MarkdownFindMatch] = []

    mutating func visitText(_ text: Markdown.Text) { add(text.plainText, of: text) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) { add(inlineCode.code, of: inlineCode) }
    mutating func visitImage(_ image: Markdown.Image) {}

    private mutating func add(_ string: String, of markup: any Markup) {
        guard matches.count < DocumentFindModel.maximumMatches else { return }
        var block: any Markup = markup
        while let parent = block.parent, parent.parent != nil { block = parent }
        let key = MarkdownSearchHighlight.key(for: markup)
        for match in expression.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
        where match.range.length > 0 {
            matches.append(MarkdownFindMatch(key: key, range: match.range.location..<NSMaxRange(match.range),
                                             block: block.indexInParent))
        }
    }
}

/// The bar under a document's header: query, options, match navigation and, for the source, replace.
struct DocumentFindBar: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @ObservedObject var model: DocumentFindModel
    let allowsReplace: Bool
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    /// Puts a cursor on every match in the editor.
    var onSelectAll: (() -> Void)?

    @FocusState private var focusedField: Field?

    private enum Field { case query, replace }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if allowsReplace {
                    iconButton(model.showsReplace ? "chevron.down" : "chevron.right",
                               help: "Show or hide replace (⌥⌘F)") {
                        model.showsReplace.toggle()
                        if model.showsReplace { focusedField = .replace }
                    }
                }
                field("Find", text: $model.options.query, focus: .query)
                    .onSubmit { model.move(1) }
                toggle("Aa", help: "Match Case", isOn: $model.options.caseSensitive)
                toggle("ab", help: "Match Whole Word", isOn: $model.options.wholeWord, underline: true)
                toggle(".*", help: "Use Regular Expression", isOn: $model.options.regex)
                Text(counter)
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(model.error != nil ? theme.error : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 70)
                    .help(model.error ?? "")
                iconButton("chevron.up", help: "Previous Match (⇧⌘G)") { model.move(-1) }
                    .disabled(model.count == 0)
                iconButton("chevron.down", help: "Next Match (⌘G)") { model.move(1) }
                    .disabled(model.count == 0)
                if let onSelectAll, allowsReplace {
                    iconButton("character.cursor.ibeam", help: "Select All Matches (⌥↩)", action: onSelectAll)
                        .keyboardShortcut(.return, modifiers: .option)
                        .disabled(model.count == 0)
                }
                Button("Done") { model.close() }
                    .controlSize(.small)
                    .help("Close the find bar (Esc)")
            }
            if allowsReplace && model.showsReplace {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 24, height: 1)
                    field(model.options.regex ? "Replace ($1 inserts a capture group)" : "Replace",
                          text: $model.replacement, focus: .replace)
                        .onSubmit(onReplace)
                    Button("Replace", action: onReplace)
                        .disabled(model.current == nil)
                        .help("Replace the current match and select the next one (↩ in the replace field)")
                    Button("All", action: onReplaceAll)
                        .disabled(model.count == 0)
                        .help("Replace every match; Undo reverts them together")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focusedField = .query }
        .onChange(of: model.focusRequest) { _, _ in focusedField = .query }
        .onExitCommand { model.close() }
    }

    private var counter: String {
        if model.error != nil { return "Invalid" }
        if model.options.query.isEmpty { return "" }
        guard model.count > 0 else { return "No results" }
        let total = model.isTruncated ? "\(model.count)+" : "\(model.count)"
        return model.current.map { "\($0 + 1) of \(total)" } ?? total
    }

    private func field(_ prompt: String, text: Binding<String>, focus: Field) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: typography.code, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: typography.metric(24))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(focus == .query && model.error != nil ? theme.error.opacity(0.7)
                        : (focusedField == focus ? theme.accent.opacity(0.5) : Color.clear)))
            .focused($focusedField, equals: focus)
    }

    private func toggle(_ label: String, help: String, isOn: Binding<Bool>, underline: Bool = false) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(label)
                .font(.system(size: typography.body, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 26, height: typography.metric(22))
                .background(isOn.wrappedValue ? theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isOn.wrappedValue ? theme.accent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: typography.body))
                .frame(width: 24, height: typography.metric(22))
                .foregroundStyle(Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

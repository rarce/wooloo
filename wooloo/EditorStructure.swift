import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Darwin
import SwiftUI

/// Shared by outline, breadcrumbs and future file-symbol navigation. Cursor changes only read
/// this cached hierarchy; parsing/indexing never happens on the cursor path.
struct EditorStructure {
    static let supported: Set<String> = ["markdown", "swift", "javascript", "jsx", "typescript", "tsx", "python"]

    static func chain(at offset: Int, in symbols: [SourceSymbol], documentLength: Int) -> [SourceSymbol] {
        var result: [SourceSymbol] = [], siblings = symbols
        while !siblings.isEmpty {
            var low = 0, high = siblings.count
            while low < high {
                let mid = (low + high) / 2
                if siblings[mid].range.location <= offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { break }
            let symbol = siblings[low - 1]
            guard offset < NSMaxRange(symbol.range)
                    || (offset == documentLength && NSMaxRange(symbol.range) == documentLength) else { break }
            result.append(symbol)
            siblings = symbol.children
        }
        return result
    }

    /// A small block-only Markdown index also works while the source editor is not mounted
    /// (preview mode). It deliberately never parses inline formatting or fenced code languages.
    static func markdown(_ source: String) -> [SourceSymbol] {
        struct Heading {
            let name: String
            let level: Int
            let range: NSRange
            let selection: NSRange
        }
        let text = source as NSString
        var headings: [Heading] = []
        var position = 0
        var fence: (Character, Int)?
        var rawHTML: String?
        var previous: (String, NSRange)?
        while position < text.length && !Task.isCancelled {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: position, length: 0))
            let range = NSRange(location: position, length: contentsEnd - position)
            let line = text.substring(with: range)
            position = end
            let spaces = line.prefix(while: { $0 == " " }).count
            let trimmed = String(line.dropFirst(min(spaces, 4)))
            if let open = fence {
                let count = trimmed.prefix(while: { $0 == open.0 }).count
                if spaces <= 3 && count >= open.1 && trimmed.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                previous = nil
                continue
            }
            if let tag = rawHTML {
                if trimmed.lowercased().contains("</\(tag)>") { rawHTML = nil }
                previous = nil
                continue
            }
            if let match = trimmed.range(of: #"^<(pre|script|style|textarea)(?:\s|>)"#,
                                         options: [.regularExpression, .caseInsensitive]) {
                let prefix = String(trimmed[match]).dropFirst()
                let tag = String(prefix.prefix(while: { $0.isLetter })).lowercased()
                if !trimmed.lowercased().contains("</\(tag)>") { rawHTML = tag }
                previous = nil
                continue
            }
            if spaces <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 && (first != "`" || !trimmed.dropFirst(count).contains("`")) {
                    fence = (first, count)
                    previous = nil
                    continue
                }
            }
            guard spaces <= 3, !trimmed.isEmpty, !trimmed.hasPrefix("\t") else { previous = nil; continue }
            // Container blocks do not create document-level headings. Do not use their text
            // (or thematic breaks) as the title of a following Setext underline.
            if trimmed.range(of: #"^(?:>|[-+*]\s|\d+[.)]\s)"#, options: .regularExpression) != nil {
                previous = nil
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.count == hashes || trimmed.dropFirst(hashes).first?.isWhitespace == true {
                var name = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                // A closing ATX sequence needs whitespace before it; literal trailing # stays.
                if let closing = name.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
                    name.removeSubrange(closing)
                }
                headings.append(Heading(name: name.isEmpty ? "Untitled heading" : name, level: hashes,
                                        range: range, selection: range))
                previous = nil
            } else {
                let marker = trimmed.trimmingCharacters(in: .whitespaces)
                if let prior = previous, let first = marker.first, first == "=" || first == "-",
                   marker.allSatisfy({ $0 == first }), !prior.0.isEmpty {
                    headings.append(Heading(name: prior.0, level: first == "=" ? 1 : 2,
                                            range: NSRange(location: prior.1.location,
                                                           length: NSMaxRange(range) - prior.1.location),
                                            selection: prior.1))
                    previous = nil
                    continue
                }
                let thematic = trimmed.filter { !$0.isWhitespace }
                if thematic.count >= 3, let first = thematic.first, "-*_".contains(first),
                   thematic.allSatisfy({ $0 == first }) {
                    previous = nil
                } else { previous = (trimmed, range) }
            }
        }
        var children: [Int: [SourceSymbol]] = [:], roots: [SourceSymbol] = []
        var parents: [Int?] = [], ends: [Int] = [], stack: [Int] = []
        for index in headings.indices {
            while let last = stack.last, headings[last].level >= headings[index].level {
                ends[last] = headings[index].range.location
                stack.removeLast()
            }
            parents.append(stack.last)
            ends.append(text.length)
            stack.append(index)
        }
        for index in headings.indices.reversed() {
            let heading = headings[index]
            let symbol = SourceSymbol(name: heading.name, kind: "heading",
                                      range: NSRange(location: heading.range.location,
                                                     length: ends[index] - heading.range.location),
                                      selectionRange: heading.selection,
                                      children: (children[index] ?? []).reversed())
            if let parent = parents[index] { children[parent, default: []].append(symbol) }
            else { roots.append(symbol) }
        }
        return roots.reversed()
    }
}

/// One per document view, including split panes. Tree state stays in the existing editor client;
/// only value snapshots are published on the main actor. Debounce coalesces bursts of edits.
@MainActor
final class EditorStructureModel: ObservableObject, @preconcurrency TextViewCoordinator {
    @Published private(set) var symbols: [SourceSymbol] = []
    @Published private(set) var isIndexing = false
    private weak var controller: TextViewController?
    private var pending: Task<Void, Never>?
    private var revision = UUID()
    private var source = ""
    private var languageID = "plaintext"

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        // SwiftUI invokes coordinator setup while updating NSViewControllerRepresentable.
        // Publish on the next main turn, outside that update transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.update(source: self.source, languageID: self.languageID)
        }
    }

    func update(source: String, languageID: String) {
        pending?.cancel()
        let revision = UUID()
        self.revision = revision
        self.source = source
        self.languageID = languageID
        // Old ranges must never be clickable against a new revision.
        symbols = []
        guard EditorStructure.supported.contains(languageID) else { isIndexing = false; return }
        isIndexing = true
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            if languageID == "markdown" {
                let worker = Task.detached(priority: .utility) { EditorStructure.markdown(source) }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.revision == revision else { return }
                self.symbols = result
                self.isIndexing = false
            } else {
                self.requestCode(source: source, languageID: languageID, revision: revision, retries: 3)
            }
        }
    }

    private func requestCode(source: String, languageID: String, revision: UUID, retries: Int) {
        guard self.revision == revision else { return }
        guard let client = controller?.treeSitterClient else { isIndexing = false; return }
        client.querySymbols(source: source, languageID: languageID) { [weak self] result in
            guard let self, self.revision == revision else { return }
            if let result {
                self.symbols = result
                self.isIndexing = false
            } else if retries > 0 {
                self.pending = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.requestCode(source: source, languageID: languageID, revision: revision, retries: retries - 1)
                }
            } else { self.isIndexing = false }
        }
    }

    deinit { pending?.cancel() }
}

/// Where Go to File finds the focused editor's symbols for `@` (⇧⌘O) and sends the one chosen.
/// The focused document view registers itself, as with `EditorCommandTarget`.
@MainActor
final class EditorSymbolTarget {
    private var owner: UUID?
    private var symbols: (() -> [QuickOpenSymbol])?
    private var navigate: ((SourceSymbol) -> Void)?

    /// `owner` identifies the view, so a view going away does not unregister its replacement.
    func register(_ owner: UUID, symbols: @escaping () -> [QuickOpenSymbol],
                  navigate: @escaping (SourceSymbol) -> Void) {
        self.owner = owner
        self.symbols = symbols
        self.navigate = navigate
    }

    func unregister(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        symbols = nil
        navigate = nil
    }

    /// The focused editor's symbols now; none without one.
    func currentSymbols() -> [QuickOpenSymbol] { symbols?() ?? [] }

    func navigate(to symbol: SourceSymbol) { navigate?(symbol) }
}

/// Controlled expansion reveals the cursor's ancestors without requiring every symbol in a
/// large file to be expanded. Users can still collapse a branch until the active path changes.
struct EditorOutlineRow: View {
    @Environment(\.woolooTheme) private var theme
    let symbol: SourceSymbol
    let activePath: Set<Int>
    let selectedID: Int?
    let onNavigate: (SourceSymbol) -> Void
    @State private var expandedOverride: Bool?

    var body: some View {
        Group {
            if symbol.children.isEmpty { label }
            else {
                DisclosureGroup(isExpanded: Binding(get: { expandedOverride ?? activePath.contains(symbol.id) },
                                                    set: { expandedOverride = $0 })) {
                    ForEach(symbol.children) { child in
                        EditorOutlineRow(symbol: child, activePath: activePath,
                                         selectedID: selectedID, onNavigate: onNavigate)
                    }
                } label: { label }
            }
        }
        .onChange(of: activePath) { _, _ in
            if activePath.contains(symbol.id) { expandedOverride = nil }
        }
    }

    private var label: some View {
        Button { onNavigate(symbol) } label: {
            Label(symbol.name, systemImage: symbol.kind == "heading" ? "number" : symbol.kind == "type" ? "cube" : "function")
                .foregroundStyle(selectedID == symbol.id ? theme.accent : Color(nsColor: theme.editorTheme.text))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol.name)
        .accessibilityLabel("Go to \(symbol.name)")
        .padding(.vertical, 3)
    }
}

/// Extracts symbols across the files of a Space for `#` in Go to File (`Go to Symbol in Space…`).
/// Reuses `EditorStructure.markdown` and `TreeSitterClient.symbols(in:language:)` so single-file
/// outline and Space symbol search produce the same symbols.
enum WorkspaceSymbolIndexer {
    static let maximumFiles = 2_000
    static let maximumFileBytes = 512_000
    static let maximumTotalBytes = 16_000_000
    static let maximumSymbols = 50_000

    static func language(for path: String) -> CodeLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn": return .markdown
        case "swift": return .swift
        case "js", "mjs", "cjs": return .javascript
        case "jsx": return .jsx
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "py", "pyi": return .python
        default: return nil
        }
    }

    /// Extracts all flattened symbols from a single file's contents.
    static func extract(path: String, source: String) -> [QuickOpenWorkspaceSymbol] {
        guard let language = language(for: path) else { return [] }
        let rawSymbols: [SourceSymbol] = language.id == .markdown
            ? EditorStructure.markdown(source)
            : TreeSitterClient.symbols(in: source, language: language)
        guard !rawSymbols.isEmpty else { return [] }
        let starts = utf16LineStarts(in: source)
        let flattened = QuickOpenSymbol.flatten(rawSymbols) { line(at: $0, starts: starts) }
        return flattened.map { QuickOpenWorkspaceSymbol(path: path, symbol: $0) }
    }

    /// Reads supported files in `paths` at `location` (local or SSH) and extracts their symbols
    /// within bounded file, byte, and symbol budgets.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func index(paths: [String], at location: WorkspaceFileLocation) throws -> WorkspaceSymbolListing {
        let supported = paths.filter { language(for: $0) != nil }
        var truncated = supported.count > maximumFiles
        let candidates = Array(supported.prefix(maximumFiles))
        guard !candidates.isEmpty else { return WorkspaceSymbolListing(symbols: [], truncated: false) }

        if let machine = location.machine {
            return try indexRemote(candidates, at: location, machine: machine, initiallyTruncated: truncated)
        }
        return indexLocal(candidates, at: location, initiallyTruncated: truncated)
    }

    private static func indexLocal(_ candidates: [String], at location: WorkspaceFileLocation,
                                   initiallyTruncated: Bool) -> WorkspaceSymbolListing {
        var symbols: [QuickOpenWorkspaceSymbol] = []
        var totalBytes = 0
        var truncated = initiallyTruncated
        for path in candidates {
            if Task.isCancelled { return WorkspaceSymbolListing(symbols: [], truncated: false) }
            guard (try? WorkspaceFiles.validateRelativePath(path)) != nil else { continue }
            let absolute = location.absolutePath(path)
            var info = stat()
            guard stat(absolute, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = Int(info.st_size)
            guard size > 0, size <= maximumFileBytes else { continue }
            if totalBytes + size > maximumTotalBytes {
                truncated = true
                break
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolute)),
                  let source = String(data: data, encoding: .utf8) else { continue }
            totalBytes += data.count
            let extracted = extract(path: path, source: source)
            if symbols.count + extracted.count > maximumSymbols {
                symbols.append(contentsOf: extracted.prefix(maximumSymbols - symbols.count))
                truncated = true
                break
            }
            symbols.append(contentsOf: extracted)
        }
        return WorkspaceSymbolListing(symbols: symbols, truncated: truncated)
    }

    private static func indexRemote(_ candidates: [String], at location: WorkspaceFileLocation,
                                    machine: HerdrMachineProfile,
                                    initiallyTruncated: Bool) throws -> WorkspaceSymbolListing {
        let valid = candidates.filter { (try? WorkspaceFiles.validateRelativePath($0)) != nil }
        guard !valid.isEmpty else { return WorkspaceSymbolListing(symbols: [], truncated: initiallyTruncated) }
        var input = Data()
        for path in valid {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }
        let body = #"for p do [ -f "$p" ] || continue; s=$(wc -c < "$p" 2>/dev/null) || continue; s=${s##* }; "#
            + #"[ "$s" -gt 0 ] && [ "$s" -le "# + String(maximumFileBytes)
            + #" ] || continue; printf '%s\0%s\0' "$p" "$s"; cat "$p"; done"#
        let script = "LC_ALL=C; export LC_ALL; cd \(WorkspaceFiles.quote(location.root)) || exit 1; "
            + "xargs -0 sh -c \(WorkspaceFiles.quote(body)) sh | head -c \(maximumTotalBytes)"
        let data = try WorkspaceFiles.ssh(machine, script, input: input,
                                          limit: maximumTotalBytes + 64_000, timeout: 15, label: "symbols")
        var truncated = initiallyTruncated || data.count >= maximumTotalBytes
        var symbols: [QuickOpenWorkspaceSymbol] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            if Task.isCancelled { return WorkspaceSymbolListing(symbols: [], truncated: false) }
            guard let pathEnd = data[offset...].firstIndex(of: 0) else { truncated = true; break }
            let pathData = data[offset..<pathEnd]
            offset = data.index(after: pathEnd)
            guard let sizeEnd = data[offset...].firstIndex(of: 0) else { truncated = true; break }
            let sizeString = String(decoding: data[offset..<sizeEnd], as: UTF8.self)
            offset = data.index(after: sizeEnd)
            guard let size = Int(sizeString), size >= 0, data.distance(from: offset, to: data.endIndex) >= size else {
                truncated = true
                break
            }
            let contentEnd = data.index(offset, offsetBy: size)
            let path = String(decoding: pathData, as: UTF8.self)
            if let source = String(data: data[offset..<contentEnd], encoding: .utf8) {
                let extracted = extract(path: path, source: source)
                if symbols.count + extracted.count > maximumSymbols {
                    symbols.append(contentsOf: extracted.prefix(maximumSymbols - symbols.count))
                    truncated = true
                    break
                }
                symbols.append(contentsOf: extracted)
            }
            offset = contentEnd
        }
        return WorkspaceSymbolListing(symbols: symbols, truncated: truncated)
    }

    private static func utf16LineStarts(in source: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    /// 1-based line number for a UTF-16 offset.
    private static func line(at offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(low, 1)
    }
}

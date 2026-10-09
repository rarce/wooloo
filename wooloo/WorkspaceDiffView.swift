import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftTreeSitter
import SwiftUI

enum DiffDisplayMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case split = "Split"

    static let storageKey = "DiffDisplayMode"

    var id: Self { self }
    var icon: String {
        switch self {
        case .unified: "rectangle.grid.1x2"
        case .split: "rectangle.split.2x1"
        }
    }
}

// MARK: - Model

/// A syntax capture within one line, in UTF-16 offsets.
struct DiffSyntaxSpan {
    let range: Range<Int>
    let capture: CaptureName
}

struct DiffLine {
    enum Kind { case context, added, removed }

    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    var missingNewline = false
    /// Words changed within a paired edit, in UTF-16 offsets.
    var emphasis: [Range<Int>] = []
    /// Outer captures first, so inner ones paint over them.
    var syntax: [DiffSyntaxSpan] = []
}

struct DiffHunk {
    let header: String
    let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    var lines: [DiffLine] = []

    /// First line of each side at or after the hunk; an empty side starts after `start`.
    var oldFirst: Int { oldCount == 0 ? oldStart + 1 : oldStart }
    var newFirst: Int { newCount == 0 ? newStart + 1 : newStart }
    var oldNext: Int { oldFirst + oldCount }
    var newNext: Int { newFirst + newCount }
}

struct DiffFile {
    var oldPath: String?
    var newPath: String?
    /// `new file mode`, `rename from`, `Binary files …` and similar extended header lines.
    var notes: [String] = []
    var hunks: [DiffHunk] = []
    /// The whole new file, when loaded, so unchanged lines between hunks can be shown.
    var newLines: [String]?
    var newSyntax: [[DiffSyntaxSpan]] = []

    var path: String {
        if let newPath, newPath != "/dev/null" { return newPath }
        return oldPath ?? ""
    }
    var status: String? {
        if oldPath == "/dev/null" || notes.contains(where: { $0.hasPrefix("new file") }) { return "Added" }
        if newPath == "/dev/null" || notes.contains(where: { $0.hasPrefix("deleted file") }) { return "Deleted" }
        if let oldPath, let newPath, oldPath != newPath { return "Renamed from \(oldPath)" }
        return nil
    }
    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    var lineNumberDigits: Int {
        let last = hunks.last?.lines.last
        return String(max(last?.oldNumber ?? 0, last?.newNumber ?? 0, newLines?.count ?? 0, 999)).count
    }
}

/// Unchanged lines before hunk `hunk` of file `file`; `hunk == hunks.count` is the end of the file.
struct DiffGap: Hashable {
    let file: Int
    let hunk: Int
}

enum DiffRow {
    case file(DiffFile)
    case hunk(String)
    case gap(DiffGap, count: Int)
    case line(DiffLine, digits: Int)
    case pair(DiffLine?, DiffLine?, digits: Int)
}

/// A unified diff (`git diff`, `git diff-tree -p`) parsed into files, hunks and numbered lines,
/// with word-level emphasis on edited lines and, given the whole files, syntax highlighting.
struct ParsedDiff {
    var files: [DiffFile] = []

    init(_ patch: String) {
        files = Self.parse(patch)
        for index in files.indices {
            for hunk in files[index].hunks.indices {
                Self.highlightEdits(&files[index].hunks[hunk].lines)
            }
        }
    }

    init(_ patch: String, old: String?, new: String?) {
        self = ParsedDiff(patch).withSides(old: old, new: new)
    }

    /// This diff with syntax colors from the whole files, without parsing the patch again.
    func withSides(old: String?, new: String?) -> ParsedDiff {
        var diff = self
        if files.count == 1 { diff.attachSides(old: old, new: new) }
        return diff
    }

    func rows(_ mode: DiffDisplayMode, expanded: Set<DiffGap>) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (fileIndex, file) in files.enumerated() {
            rows.append(.file(file))
            let digits = file.lineNumberDigits
            func line(_ line: DiffLine) -> DiffRow {
                mode == .split ? .pair(line, line, digits: digits) : .line(line, digits: digits)
            }
            func gap(_ gap: DiffGap, from first: Int, to next: Int, oldDelta: Int) {
                guard let newLines = file.newLines, first < next, next - 1 <= newLines.count else { return }
                guard expanded.contains(gap) else { rows.append(.gap(gap, count: next - first)); return }
                for number in first..<next {
                    rows.append(line(DiffLine(kind: .context, text: newLines[number - 1], oldNumber: number + oldDelta,
                                              newNumber: number,
                                              syntax: number <= file.newSyntax.count ? file.newSyntax[number - 1] : [])))
                }
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                gap(DiffGap(file: fileIndex, hunk: hunkIndex),
                    from: hunkIndex == 0 ? 1 : file.hunks[hunkIndex - 1].newNext, to: hunk.newFirst,
                    oldDelta: hunk.oldFirst - hunk.newFirst)
                rows.append(.hunk(hunk.header))
                if mode == .split {
                    rows += Self.pairs(hunk.lines).map { .pair($0.0, $0.1, digits: digits) }
                } else {
                    rows += hunk.lines.map { .line($0, digits: digits) }
                }
            }
            if let last = file.hunks.last, let newLines = file.newLines {
                gap(DiffGap(file: fileIndex, hunk: file.hunks.count), from: last.newNext, to: newLines.count + 1,
                    oldDelta: last.oldNext - last.newNext)
            }
        }
        return rows
    }

    /// Splits on LF only and drops a CR before it, so CRLF files line up with their patch.
    static func lines(_ text: String) -> [String] {
        text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { bytes in
            let line = Substring(bytes)
            return String(line.utf8.last == 13 ? line.dropLast() : line)
        }
    }

    // MARK: Parsing

    private static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0, oldLeft = 0, newLeft = 0

        func closeHunk() {
            if let current = hunk { file?.hunks.append(current) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let current = file { files.append(current) }
            file = nil
        }

        for line in lines(text) {
            // Counts from the hunk header tell body lines apart from a following file's headers.
            if hunk != nil, oldLeft > 0 || newLeft > 0 {
                let body = String(line.dropFirst())
                switch line.first {
                case "+":
                    hunk?.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine))
                    newLine += 1; newLeft -= 1
                case "-":
                    hunk?.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil))
                    oldLine += 1; oldLeft -= 1
                case "\\":
                    if let last = hunk?.lines.indices.last { hunk?.lines[last].missingNewline = true }
                default:
                    hunk?.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                }
                continue
            }
            if line.hasPrefix("\\"), let last = hunk?.lines.indices.last {
                hunk?.lines[last].missingNewline = true
            } else if line.hasPrefix("diff ") {
                closeFile()
                file = DiffFile()
            } else if line.hasPrefix("@@"), let header = hunkHeader(line) {
                closeHunk()
                if file == nil { file = DiffFile() }
                (oldLine, oldLeft, newLine, newLeft) = header
                hunk = DiffHunk(header: line, oldStart: oldLine, oldCount: oldLeft, newStart: newLine, newCount: newLeft)
            } else if line.hasPrefix("--- ") {
                // Diffs without a `diff --git` line (e.g. an untracked file) start at `---`.
                if file == nil || file?.hunks.isEmpty == false || hunk != nil { closeFile(); file = DiffFile() }
                file?.oldPath = diffPath(line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                file?.newPath = diffPath(line.dropFirst(4))
            } else if !line.isEmpty, file != nil, hunk == nil {
                file?.notes.append(line)
                if line.hasPrefix("rename from ") { file?.oldPath = String(line.dropFirst(12)) }
                if line.hasPrefix("rename to ") { file?.newPath = String(line.dropFirst(10)) }
            }
        }
        closeFile()
        return files
    }

    /// `@@ -old[,count] +new[,count] @@` → start and length of each side.
    private static func hunkHeader(_ line: String) -> (Int, Int, Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",")
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    private static func diffPath(_ value: Substring) -> String {
        let path = String(value.split(separator: "\t", maxSplits: 1).first ?? value)
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    // MARK: Pairing

    /// Change blocks: each run of deletions followed by additions. Their lines pair up in order,
    /// as GitHub and diff-highlight do; context lines pair with themselves.
    private static func blocks(_ lines: [DiffLine]) -> [(removed: Range<Int>, added: Range<Int>)] {
        var result: [(Range<Int>, Range<Int>)] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else { index += 1; continue }
            let removedStart = index
            while index < lines.count, lines[index].kind == .removed { index += 1 }
            let addedStart = index
            while index < lines.count, lines[index].kind == .added { index += 1 }
            result.append((removedStart..<addedStart, addedStart..<index))
        }
        return result
    }

    private static func pairs(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var result: [(DiffLine?, DiffLine?)] = []
        var index = 0
        var changes = blocks(lines)[...]
        while index < lines.count {
            if let block = changes.first, block.removed.lowerBound == index {
                changes.removeFirst()
                for offset in 0..<max(block.removed.count, block.added.count) {
                    result.append((offset < block.removed.count ? lines[block.removed.lowerBound + offset] : nil,
                                   offset < block.added.count ? lines[block.added.lowerBound + offset] : nil))
                }
                index = block.added.upperBound
            } else {
                result.append((lines[index], lines[index]))
                index += 1
            }
        }
        return result
    }

    // MARK: Word-level emphasis

    private static let maximumEmphasisLength = 1_000

    private static func highlightEdits(_ lines: inout [DiffLine]) {
        for block in blocks(lines) {
            for offset in 0..<min(block.removed.count, block.added.count) {
                let old = block.removed.lowerBound + offset, new = block.added.lowerBound + offset
                guard let (oldEmphasis, newEmphasis) = wordDiff(lines[old].text, lines[new].text) else { continue }
                lines[old].emphasis = oldEmphasis
                lines[new].emphasis = newEmphasis
            }
        }
    }

    /// Diffs two lines by words, whitespace runs and punctuation with Swift's Myers
    /// `CollectionDifference`. Returns nil when the lines share too little for emphasis to help.
    private static func wordDiff(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>])? {
        guard old != new, old.utf16.count <= maximumEmphasisLength, new.utf16.count <= maximumEmphasisLength else { return nil }
        let oldTokens = tokens(old), newTokens = tokens(new)
        var oldChanged = Array(repeating: false, count: oldTokens.count)
        var newChanged = Array(repeating: false, count: newTokens.count)
        for change in newTokens.difference(from: oldTokens) {
            switch change {
            case .remove(let offset, _, _): oldChanged[offset] = true
            case .insert(let offset, _, _): newChanged[offset] = true
            }
        }
        // Like delta's max-line-distance: whole-line coloring reads better than scattered fragments.
        let kept = zip(oldTokens, oldChanged).filter { !$1 && !$0.allSatisfy(\.isWhitespace) }.reduce(0) { $0 + $1.0.count }
        let visible = max(old.filter { !$0.isWhitespace }.count, new.filter { !$0.isWhitespace }.count, 1)
        guard Double(kept) / Double(visible) >= 0.4 else { return nil }
        return (ranges(oldTokens, oldChanged), ranges(newTokens, newChanged))
    }

    private static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentClass = 0
        for character in line {
            let characterClass = character.isLetter || character.isNumber || character == "_" ? 1
                : character.isWhitespace ? 2 : 3
            if currentClass == characterClass && characterClass != 3 {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(character)
                currentClass = characterClass
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func ranges(_ tokens: [String], _ changed: [Bool]) -> [Range<Int>] {
        var flags = changed
        // Join changed words separated by whitespace into one highlighted run.
        for index in tokens.indices.dropFirst().dropLast()
        where !flags[index] && flags[index - 1] && flags[index + 1] && tokens[index].allSatisfy(\.isWhitespace) {
            flags[index] = true
        }
        var result: [Range<Int>] = []
        var offset = 0
        for (token, flag) in zip(tokens, flags) {
            let next = offset + token.utf16.count
            if flag {
                if let last = result.last, last.upperBound == offset {
                    result[result.count - 1] = last.lowerBound..<next
                } else {
                    result.append(offset..<next)
                }
            }
            offset = next
        }
        return result
    }

    // MARK: Whole files

    /// Highlights each line from its whole file and keeps the new file for expanding unchanged
    /// lines. A side that no longer matches the patch (e.g. edited since) is ignored.
    private mutating func attachSides(old: String?, new: String?) {
        let oldLines = old.map(Self.lines), newLines = new.map(Self.lines)
        let lines = files[0].hunks.flatMap(\.lines)
        func matches(_ side: [String]?, _ number: (DiffLine) -> Int?) -> Bool {
            guard let side else { return false }
            return lines.allSatisfy { line in
                guard let value = number(line) else { return true }
                return value <= side.count && side[value - 1] == line.text
            }
        }
        let oldMatches = matches(oldLines) { $0.kind == .added ? nil : $0.oldNumber }
        let newMatches = matches(newLines) { $0.kind == .removed ? nil : $0.newNumber }
        guard oldMatches || newMatches, let sample = newMatches ? new : old else { return }
        let language = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: files[0].path),
                                                       prefixBuffer: String(sample.prefix(512)),
                                                       suffixBuffer: String(sample.suffix(512)))
        var newDocument: DiffHighlighter.Document?
        var newSyntax: [[DiffSyntaxSpan]] = [], oldSyntax: [[DiffSyntaxSpan]] = []
        if newMatches, let new {
            newDocument = DiffHighlighter.Document(new, language: language)
            newSyntax = newDocument?.syntax() ?? []
        }
        // Only removed lines take colors from the old file: it is skipped without any, parsed by
        // editing the new file's tree where the patch changed it, and queried only around them.
        let changes = Self.changes(files[0].hunks)
        let removed = changes.filter { $0.removed > 0 }.map { $0.old..<($0.old + $0.removed) }
        if oldMatches, let old, !removed.isEmpty {
            let document = newDocument?.reparsed(as: old, changes: changes) ?? DiffHighlighter.Document(old, language: language)
            oldSyntax = document?.syntax(lines: removed) ?? []
        }
        for hunk in files[0].hunks.indices {
            for index in files[0].hunks[hunk].lines.indices {
                let line = files[0].hunks[hunk].lines[index]
                if line.kind == .removed, let number = line.oldNumber, number <= oldSyntax.count {
                    files[0].hunks[hunk].lines[index].syntax = oldSyntax[number - 1]
                } else if line.kind != .removed, let number = line.newNumber, number <= newSyntax.count {
                    files[0].hunks[hunk].lines[index].syntax = newSyntax[number - 1]
                }
            }
        }
        if newMatches, var newLines {
            if new?.utf8.last == 10, newLines.last == "" { newLines.removeLast() }
            files[0].newLines = newLines
            files[0].newSyntax = newSyntax
        }
    }

    /// Each run of removed and added lines between context lines, in 0-based line numbers.
    static func changes(_ hunks: [DiffHunk]) -> [DiffHighlighter.Change] {
        var result: [DiffHighlighter.Change] = []
        for hunk in hunks {
            var old = hunk.oldFirst - 1, new = hunk.newFirst - 1
            var change: DiffHighlighter.Change?
            for line in hunk.lines {
                if line.kind == .context {
                    if let current = change { result.append(current) }
                    change = nil
                    old += 1
                    new += 1
                    continue
                }
                if change == nil { change = DiffHighlighter.Change(old: old, removed: 0, new: new, added: 0) }
                if line.kind == .removed {
                    change?.removed += 1
                    old += 1
                } else {
                    change?.added += 1
                    new += 1
                }
            }
            if let current = change { result.append(current) }
        }
        return result
    }
}

/// Runs a language's tree-sitter highlight query over a whole file, as CodeEditSourceEditor does
/// for the editor, and splits the captures by line.
enum DiffHighlighter {
    /// `TreeSitterModel` loads its queries lazily and isn't thread-safe; a loaded `Query` is
    /// immutable and can run on any thread, each with its own parser and cursor.
    private static let lock = NSLock()

    private static func query(for language: CodeLanguage) -> Query? {
        lock.lock()
        defer { lock.unlock() }
        return TreeSitterModel.shared.query(for: language.id)
    }

    /// Lines `old..<old + removed` of the old file became lines `new..<new + added` of the new
    /// file, counted from 0.
    struct Change {
        var old: Int
        var removed: Int
        var new: Int
        var added: Int
    }

    private struct Capture {
        let location: Int
        let length: Int
        let index: Int
        let name: CaptureName
    }

    static func highlight(_ text: String, language: CodeLanguage) -> [[DiffSyntaxSpan]] {
        Document(text, language: language)?.syntax() ?? []
    }

    /// A parsed file. Offsets are in UTF-16 units, which tree-sitter reads as UTF-16LE bytes.
    struct Document {
        private let text: String
        private let units: [UInt16]
        /// Where each line starts; a final newline starts an empty last line.
        private let lineStarts: [Int]
        private let language: Language
        private let query: Query
        private let tree: MutableTree

        init?(_ text: String, language: CodeLanguage) {
            guard let treeSitterLanguage = language.language, let query = DiffHighlighter.query(for: language) else {
                return nil
            }
            self.init(text, language: treeSitterLanguage, query: query, editing: nil)
        }

        private init?(_ text: String, language: Language, query: Query, editing tree: MutableTree?) {
            let parser = Parser()
            guard (try? parser.setLanguage(language)) != nil else { return nil }
            let parsed = tree.map { parser.parse(tree: $0, string: text) } ?? parser.parse(text)
            guard let parsed else { return nil }
            self.text = text
            self.units = Array(text.utf16)
            self.lineStarts = Self.lineStarts(units)
            self.language = language
            self.query = query
            self.tree = parsed
        }

        private static func lineStarts(_ units: [UInt16]) -> [Int] {
            var starts = [0]
            for (offset, unit) in units.enumerated() where unit == 10 { starts.append(offset + 1) }
            return starts
        }

        /// The last line starting at or before `offset`.
        private static func line(at offset: Int, _ starts: [Int]) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return max(0, low - 1)
        }

        /// Where line `line` starts, the end of the text just past the last line, else nil.
        private static func offset(_ line: Int, _ starts: [Int], _ count: Int) -> Int? {
            line < starts.count ? starts[line] : line == starts.count ? count : nil
        }

        private static func point(_ offset: Int, _ starts: [Int]) -> Point {
            let row = line(at: offset, starts)
            return Point(row: row, column: (offset - starts[row]) * 2)
        }

        /// `old`, the old side of `changes` with this document as the new side, parsed by editing
        /// this tree so that tree-sitter reparses only around the changes. Nil when the files also
        /// differ elsewhere, as when one was edited after the patch was taken.
        func reparsed(as old: String, changes: [Change]) -> Document? {
            let oldUnits = Array(old.utf16), oldStarts = Self.lineStarts(oldUnits)
            func oldOffset(_ line: Int) -> Int? { Self.offset(line, oldStarts, oldUnits.count) }
            func newOffset(_ line: Int) -> Int? { Self.offset(line, lineStarts, units.count) }

            // The text between changes must be the same on both sides.
            var oldLine = 0, newLine = 0
            var edits: [InputEdit] = []
            for change in changes {
                guard change.old >= oldLine, change.new >= newLine,
                      let keptOld = oldOffset(oldLine), let removedStart = oldOffset(change.old),
                      let removedEnd = oldOffset(change.old + change.removed),
                      let keptNew = newOffset(newLine), let start = newOffset(change.new),
                      let addedEnd = newOffset(change.new + change.added),
                      oldUnits[keptOld..<removedStart] == units[keptNew..<start] else { return nil }
                let startPoint = Self.point(start, lineStarts)
                let lower = Self.point(removedStart, oldStarts), upper = Self.point(removedEnd, oldStarts)
                let endPoint = upper.row == lower.row
                    ? Point(row: startPoint.row, column: startPoint.column + upper.column - lower.column)
                    : Point(row: startPoint.row + upper.row - lower.row, column: upper.column)
                edits.append(InputEdit(startByte: start * 2, oldEndByte: addedEnd * 2,
                                       newEndByte: (start + removedEnd - removedStart) * 2, startPoint: startPoint,
                                       oldEndPoint: Self.point(addedEnd, lineStarts), newEndPoint: endPoint))
                oldLine = change.old + change.removed
                newLine = change.new + change.added
            }
            guard let keptOld = oldOffset(oldLine), let keptNew = newOffset(newLine),
                  oldUnits[keptOld...] == units[keptNew...], let tree = tree.mutableCopy() else { return nil }
            // From the last change back, so each edit starts where it did in this text.
            for edit in edits.reversed() { tree.edit(edit) }
            return Document(old, language: language, query: query, editing: tree)
        }

        /// Captures split by line: for every line, or for the lines in `lines` and maybe others.
        func syntax(lines: [Range<Int>]? = nil) -> [[DiffSyntaxSpan]] {
            // Capture indexes name the same capture in every match; look each name up once.
            var names: [Int: CaptureName?] = [:]
            var captures: [Capture] = []
            func collect(_ cursor: QueryCursor) {
                for match in cursor.resolve(with: .init(string: text)) {
                    for capture in match.captures {
                        let range = capture.range
                        guard range.length > 0 else { continue }
                        let name: CaptureName?
                        if let known = names[capture.index] {
                            name = known
                        } else {
                            name = CaptureName.fromString(capture.name)
                            names[capture.index] = name
                        }
                        guard let name else { continue }
                        captures.append(Capture(location: range.location, length: range.length, index: capture.index,
                                                name: name))
                    }
                }
            }
            // One cursor per run of lines: even a run every few lines costs less than querying
            // everything between them.
            if lines == nil { collect(query.execute(in: tree)) }
            for range in lines ?? [] {
                let start = Self.offset(range.lowerBound, lineStarts, units.count) ?? units.count
                let end = Self.offset(range.upperBound, lineStarts, units.count) ?? units.count
                let cursor = query.execute(in: tree)
                cursor.setRange(NSRange(location: start, length: end - start))
                collect(cursor)
            }
            // Outer captures first, so inner ones paint over them. For the same range the lowest
            // capture index wins, as in CodeEditSourceEditor; one found by two cursors counts once.
            captures.sort {
                if $0.length != $1.length { return $0.length > $1.length }
                if $0.location != $1.location { return $0.location < $1.location }
                return $0.index < $1.index
            }

            var result = Array(repeating: [DiffSyntaxSpan](), count: lineStarts.count)
            var previous: Capture?
            for capture in captures {
                if let previous, previous.location == capture.location, previous.length == capture.length { continue }
                previous = capture
                let end = capture.location + capture.length
                var line = Self.line(at: capture.location, lineStarts)
                while line < lineStarts.count, lineStarts[line] < end {
                    let start = lineStarts[line]
                    let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : units.count
                    let lower = max(capture.location, start) - start, upper = min(end, lineEnd) - start
                    if upper > lower { result[line].append(DiffSyntaxSpan(range: lower..<upper, capture: capture.name)) }
                    line += 1
                }
            }
            return result
        }
    }
}

// MARK: - View

/// Where a diff document's patch comes from, to load the whole files around it.
struct DiffSource: Equatable {
    let location: WorkspaceFileLocation
    let path: String
    let originalPath: String?
    let commit: String?
    let scope: WorkspaceDiffScope

    static func == (lhs: DiffSource, rhs: DiffSource) -> Bool {
        lhs.location.identity == rhs.location.identity && lhs.path == rhs.path && lhs.originalPath == rhs.originalPath
            && lhs.commit == rhs.commit && lhs.scope == rhs.scope
    }
}

/// Renders a unified diff as a GitHub-style unified or side-by-side view with line numbers,
/// syntax colors, word-level emphasis on edited lines, and expandable unchanged lines.
struct WorkspaceDiffView: View {
    private struct LoadKey: Equatable {
        let text: String
        let source: DiffSource
    }

    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let text: String
    let source: DiffSource
    let mode: DiffDisplayMode
    @State private var parsed: ParsedDiff?
    @State private var parsedKey: LoadKey?
    @State private var expanded: Set<DiffGap> = []

    var body: some View {
        Group {
            if let parsed, parsedKey == LoadKey(text: text, source: source) {
                if parsed.files.isEmpty {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: typography.emphasis))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if mode == .split {
                    ScrollView(.vertical) {
                        rows(parsed.rows(.split, expanded: expanded))
                    }
                } else {
                    GeometryReader { viewport in
                        ScrollView([.vertical, .horizontal]) {
                            rows(parsed.rows(.unified, expanded: expanded))
                                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(text: text, source: source)) {
            let key = LoadKey(text: text, source: source)
            let start = TerminalPipelineMetrics.now()
            let detail = key.source.location.isLocal ? "local" : "ssh"
            // Show the patch first, then again with syntax colors once the whole files arrive.
            let plain = await Task.detached(priority: .userInitiated) { ParsedDiff(key.text) }.value
            guard !Task.isCancelled else { return }
            expanded = []
            parsed = plain
            parsedKey = key
            TerminalPipelineMetrics.spanShown("diff-patch", start: start, detail: detail)
            guard !plain.files.isEmpty else { return }
            guard let full = try? await BlockingWork.run(priority: .utility, { () -> ParsedDiff in
                let source = key.source
                let sides = WorkspaceFiles.diffSides(source.path, originalPath: source.originalPath, commit: source.commit,
                                                     scope: source.scope, at: source.location)
                return plain.withSides(old: sides.old, new: sides.new)
            }) else { return }
            guard !Task.isCancelled else { return }
            parsed = full
            TerminalPipelineMetrics.spanShown("diff-highlighted", start: start, detail: detail)
        }
    }

    private func rows(_ rows: [DiffRow]) -> some View {
        let palette = SyntaxPalette(theme.editorTheme)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index], palette: palette)
            }
        }
        .font(.system(size: typography.code, design: .monospaced))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ row: DiffRow, palette: SyntaxPalette) -> some View {
        switch row {
        case .file(let file):
            fileHeader(file)
        case .hunk(let header):
            Text(header)
                .foregroundStyle(theme.diffHunk)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.diffHunk.opacity(0.1))
        case .gap(let gap, let count):
            Button {
                expanded.insert(gap)
            } label: {
                Label(count == 1 ? "Show 1 unchanged line" : "Show \(count) unchanged lines",
                      systemImage: "arrow.up.and.down")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.diffHunk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.diffHunk.opacity(0.05))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .line(let line, let digits):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(line.oldNumber, digits: digits, kind: line.kind)
                number(line.newNumber, digits: digits, kind: line.kind)
                content(line, wraps: false, palette: palette)
            }
            .background(background(line.kind))
        case .pair(let old, let new, let digits):
            HStack(spacing: 0) {
                side(old, number: old?.oldNumber, digits: digits, palette: palette)
                Rectangle().fill(theme.muted.opacity(0.35)).frame(width: 1)
                side(new, number: new?.newNumber, digits: digits, palette: palette)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Text(file.path).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            if let status = file.status {
                Text(status).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if file.hunks.isEmpty, let note = file.notes.last {
                Text(note).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("+\(file.additions)").foregroundStyle(theme.diffAdded)
            Text("−\(file.deletions)").foregroundStyle(theme.diffRemoved)
        }
        .font(.system(size: typography.body))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.muted.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1) }
    }

    @ViewBuilder
    private func side(_ line: DiffLine?, number value: Int?, digits: Int, palette: SyntaxPalette) -> some View {
        if let line {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(value, digits: digits, kind: line.kind)
                content(line, wraps: true, palette: palette)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background(line.kind))
        } else {
            Rectangle()
                .fill(theme.muted.opacity(0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func number(_ value: Int?, digits: Int, kind: DiffLine.Kind) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(kind == .context ? theme.muted : color(kind).opacity(0.8))
            .frame(width: CGFloat(digits) * characterWidth + 12, alignment: .trailing)
            .padding(.trailing, 4)
            .textSelection(.disabled)
    }

    private func content(_ line: DiffLine, wraps: Bool, palette: SyntaxPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(color(line.kind))
                .frame(width: characterWidth + 8)
            Text(attributed(line, palette: palette))
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 1)
    }

    /// Splits the line at every syntax and emphasis boundary and styles each run.
    private func attributed(_ line: DiffLine, palette: SyntaxPalette) -> AttributedString {
        let text = line.text
        let length = text.utf16.count
        var bounds: Set<Int> = [0, length]
        for range in line.emphasis { bounds.insert(range.lowerBound); bounds.insert(range.upperBound) }
        for span in line.syntax { bounds.insert(span.range.lowerBound); bounds.insert(span.range.upperBound) }
        let offsets = bounds.filter { $0 <= length }.sorted()

        var result = AttributedString()
        for (lower, upper) in zip(offsets, offsets.dropFirst()) where upper > lower {
            let start = String.Index(utf16Offset: lower, in: text), end = String.Index(utf16Offset: upper, in: text)
            var run = AttributedString(text[start..<end].replacingOccurrences(of: "\t", with: "    "))
            if let span = line.syntax.last(where: { $0.range.contains(lower) }), let color = palette.color(span.capture) {
                run.foregroundColor = color
            }
            if line.emphasis.contains(where: { $0.contains(lower) }) {
                run.backgroundColor = color(line.kind).opacity(0.35)
            }
            result += run
        }
        if line.missingNewline {
            var marker = AttributedString("  ⊘ no newline at end of file")
            marker.foregroundColor = theme.muted
            result += marker
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }

    private var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: typography.codeFont]).width
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diffAdded
        case .removed: theme.diffRemoved
        case .context: .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diffAdded.opacity(0.12)
        case .removed: theme.diffRemoved.opacity(0.12)
        case .context: .clear
        }
    }
}

/// The editor theme's syntax colors, mapped from captures as `EditorTheme.colorFor` does.
struct SyntaxPalette {
    let keywords, comments, numbers, strings, types, attributes: Color

    init(_ theme: EditorTheme) {
        keywords = Color(nsColor: theme.keywords)
        comments = Color(nsColor: theme.comments)
        numbers = Color(nsColor: theme.numbers)
        strings = Color(nsColor: theme.strings)
        types = Color(nsColor: theme.types)
        attributes = Color(nsColor: theme.attributes)
    }

    func color(_ capture: CaptureName) -> Color? {
        switch capture {
        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
             .keywordReturn, .keywordFunction, .repeat, .conditional, .tag: keywords
        case .comment: comments
        case .number, .float: numbers
        case .string: strings
        case .type: types
        case .typeAlternate: attributes
        default: nil
        }
    }
}

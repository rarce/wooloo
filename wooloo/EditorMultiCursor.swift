import AppKit
import Carbon.HIToolbox
import CodeEditSourceEditor

/// The editor's selections, sorted by location, and the one added last, which the multi-cursor
/// commands continue from.
struct MultiCursorSelection: Equatable {
    var ranges: [NSRange]
    var newest: NSRange

    init(ranges: [NSRange], newest: NSRange) {
        var seen = Set<NSRange>()
        self.ranges = ranges.filter { seen.insert($0).inserted }.sorted { $0.location < $1.location }
        self.newest = newest
    }
}

/// Multi-cursor commands as in Zed, on plain ranges so they can be tested without an editor.
/// Occurrences match case-sensitively; `wordwise` also requires word boundaries, which is how a
/// run started from a cursor (rather than a selection) matches. ⌥⌘↑/↓ keep their goal as a
/// display column (`DisplayColumns`), so tabs and wide characters do not shift it.
enum MultiCursor {
    /// ⌘D: selects the word under an empty newest selection (and under every other cursor), or
    /// adds the next occurrence of the newest selection after it, wrapping around. With
    /// `replaceNewest` (⌘K ⌘D) the newest selection is dropped in favor of the next occurrence.
    static func selectNext(_ selection: MultiCursorSelection, in text: NSString, wordwise: Bool,
                           replaceNewest: Bool = false) -> MultiCursorSelection? {
        if selection.newest.length == 0 {
            guard let newest = wordRange(at: selection.newest.location, in: text) else { return nil }
            let ranges = selection.ranges.map { $0.length == 0 ? wordRange(at: $0.location, in: text) ?? $0 : $0 }
            return MultiCursorSelection(ranges: ranges, newest: newest)
        }
        let query = text.substring(with: selection.newest)
        let others = selection.ranges.filter { !replaceNewest || $0 != selection.newest }
        let candidates = occurrences(of: query, in: text, wholeWord: wordwise).filter { match in
            match != selection.newest && !others.contains { NSIntersectionRange($0, match).length > 0 || $0 == match }
        }
        guard let next = candidates.first(where: { $0.location >= NSMaxRange(selection.newest) })
                ?? candidates.first else { return nil }
        return MultiCursorSelection(ranges: others + [next], newest: next)
    }

    /// ⇧⌘L: selects every occurrence of the newest selection, or of the word under it when empty.
    static func selectAll(_ selection: MultiCursorSelection, in text: NSString,
                          wordwise: Bool) -> MultiCursorSelection? {
        var newest = selection.newest
        var wholeWord = wordwise
        if newest.length == 0 {
            guard let word = wordRange(at: newest.location, in: text) else { return nil }
            newest = word
            wholeWord = true
        }
        let matches = occurrences(of: text.substring(with: newest), in: text, wholeWord: wholeWord)
        guard !matches.isEmpty else { return nil }
        return MultiCursorSelection(ranges: matches, newest: matches.contains(newest) ? newest : matches[0])
    }

    /// ⌥⌘↑ / ⌥⌘↓: adds a cursor on the line above the topmost selection or below the bottommost
    /// (below where it ends, when it spans lines), at display column `goalColumn` (clamped to the
    /// line). A selection on one line adds the same display columns, on the nearest line long
    /// enough to hold part of them.
    static func addCursor(_ selection: MultiCursorSelection, in text: NSString, above: Bool,
                          goalColumn: Int, tabWidth: Int = 4) -> MultiCursorSelection? {
        guard let base = above ? selection.ranges.first : selection.ranges.last else { return nil }
        let startLine = text.lineRange(for: NSRange(location: base.location, length: 0))
        let singleLine = base.length > 0 && NSMaxRange(base) <= contentsEnd(of: startLine, in: text)
        let width = singleLine
            ? DisplayColumns.column(of: NSMaxRange(base), in: text, tabWidth: tabWidth)
                - DisplayColumns.column(of: base.location, in: text, tabWidth: tabWidth)
            : 0
        var line = above ? startLine : text.lineRange(for: NSRange(location: NSMaxRange(base), length: 0))
        while true {
            if above {
                guard line.location > 0 else { return nil }
                line = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            } else {
                guard NSMaxRange(line) < text.length || (NSMaxRange(line) == text.length && endsWithNewline(line, text))
                else { return nil }
                if NSMaxRange(line) == text.length {
                    line = NSRange(location: text.length, length: 0)
                } else {
                    line = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
                }
            }
            let contents = text.substring(with: NSRange(location: line.location,
                                                        length: contentsEnd(of: line, in: text) - line.location))
            let start = DisplayColumns.offset(forColumn: goalColumn, in: contents, tabWidth: tabWidth)
            let end = width > 0 ? DisplayColumns.offset(forColumn: goalColumn + width, in: contents, tabWidth: tabWidth) : start
            if width > 0 && end <= start { continue }
            let added = NSRange(location: line.location + start, length: end - start)
            return MultiCursorSelection(ranges: selection.ranges + [added], newest: added)
        }
    }

    /// Esc: keeps only the newest selection.
    static func collapse(_ selection: MultiCursorSelection) -> MultiCursorSelection? {
        selection.ranges.count > 1 ? MultiCursorSelection(ranges: [selection.newest], newest: selection.newest) : nil
    }

    /// The word containing `offset`, or ending right before it.
    static func wordRange(at offset: Int, in text: NSString) -> NSRange? {
        var start = min(offset, text.length)
        var end = start
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Non-overlapping, case-sensitive occurrences of `query`.
    static func occurrences(of query: String, in text: NSString, wholeWord: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var matches: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let match = text.range(of: query, options: .literal, range: search)
            guard match.location != NSNotFound else { break }
            if !wholeWord || isWholeWord(match, in: text) { matches.append(match) }
            let next = wholeWord && !isWholeWord(match, in: text) ? match.location + 1 : NSMaxRange(match)
            search = NSRange(location: next, length: text.length - next)
        }
        return matches
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        (range.location == 0 || !isWordCharacter(text.character(at: range.location - 1)))
            && (NSMaxRange(range) == text.length || !isWordCharacter(text.character(at: NSMaxRange(range))))
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true } // Surrogate halves belong to words.
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private static func contentsEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func endsWithNewline(_ line: NSRange, _ text: NSString) -> Bool {
        line.length > 0 && [0x0A, 0x0D].contains(text.character(at: NSMaxRange(line) - 1))
    }
}

/// Display columns of a line as a monospaced editor draws it: a tab advances to the next tab
/// stop, East Asian wide characters and emoji take two columns, and combining marks none, as part
/// of their grapheme cluster. Offsets are UTF-16, as in `NSString` and the editor's ranges.
/// (`wcwidth` is no substitute: it answers -1 for anything non-ASCII in the app's C locale.)
enum DisplayColumns {
    /// The display column of `offset` within its line, counting only the grapheme clusters that
    /// end at or before it.
    static func column(of offset: Int, in text: NSString, tabWidth: Int) -> Int {
        let offset = min(max(offset, 0), text.length)
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        // An offset inside a cluster (say, a ⌘D match on the "e" of a decomposed "é") counts
        // from the start of that cluster.
        let end = offset < NSMaxRange(line)
            ? max(text.rangeOfComposedCharacterSequence(at: offset).location, line.location) : offset
        let prefix = text.substring(with: NSRange(location: line.location, length: end - line.location))
        return column(ofUTF16Offset: end - line.location, in: prefix, tabWidth: tabWidth)
    }

    /// The display column at UTF-16 `offset` in `line`, counting only whole grapheme clusters
    /// before it.
    static func column(ofUTF16Offset offset: Int, in line: String, tabWidth: Int) -> Int {
        var column = 0
        var utf16 = 0
        forEachCluster(in: line, tabWidth: tabWidth) { length, width in
            guard utf16 + length <= offset else { return false }
            column += width
            utf16 += length
            return true
        }
        return column
    }

    /// The UTF-16 offset in `line` (without its line break) that shows at display `column`, clamped
    /// to the line's end. A column inside a tab or a wide character goes to the nearer side of
    /// it, and to the far side when both are equally near, as VS Code does; the offset is always
    /// on a grapheme cluster boundary.
    static func offset(forColumn target: Int, in line: String, tabWidth: Int) -> Int {
        var column = 0
        var utf16 = 0
        var inside: Int?
        forEachCluster(in: line, tabWidth: tabWidth) { length, width in
            guard column < target else { return false }
            let next = column + width
            if next > target {
                inside = target - column < next - target ? utf16 : utf16 + length
                return false
            }
            column = next
            utf16 += length
            return true
        }
        return inside ?? utf16
    }

    /// The columns `character` takes when it starts at display `column`.
    static func width(of character: Character, at column: Int, tabWidth: Int) -> Int {
        if character == "\t" { return tabStop(after: column, tabWidth: tabWidth) - column }
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .control:
            return 0 // CR LF is one cluster of two controls.
        case .nonspacingMark, .enclosingMark, .format:
            // Alone they draw nothing; a prepended format character (U+0600) leads a visible cluster.
            if scalars.count == 1 { return 0 }
        default:
            break
        }
        let properties = first.properties
        // U+FE0E asks for the narrow text glyph of an emoji, even one shown as emoji by default.
        if properties.isEmoji, scalars.contains("\u{FE0E}") { return 1 }
        // Emoji shown as emoji by default (flags among them), then text-default emoji turned into
        // emoji by U+FE0F, keycaps and ZWJ sequences.
        if isWide(first) || properties.isEmojiPresentation { return 2 }
        if scalars.count > 1, properties.isEmoji,
           scalars.contains(where: { [0xFE0F, 0x20E3, 0x200D].contains($0.value) }) {
            return 2
        }
        return 1
    }

    private static func tabStop(after column: Int, tabWidth: Int) -> Int {
        let tabWidth = max(tabWidth, 1)
        return (column / tabWidth + 1) * tabWidth
    }

    /// Calls `visit` with the UTF-16 length and display width of each grapheme cluster of `line`,
    /// in order, until it returns false. All-ASCII lines (most code, and minified files with very
    /// long lines) skip grapheme breaking, which is several times slower; `line` holds no line
    /// break, so CR LF never appears as two clusters.
    private static func forEachCluster(in line: String, tabWidth: Int, _ visit: (_ length: Int, _ width: Int) -> Bool) {
        var column = 0
        if line.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in line.utf8 {
                let width = byte == 0x09 ? tabStop(after: column, tabWidth: tabWidth) - column
                    : byte < 0x20 || byte == 0x7F ? 0 : 1
                guard visit(1, width) else { return }
                column += width
            }
            return
        }
        for character in line {
            let width = width(of: character, at: column, tabWidth: tabWidth)
            guard visit(character.utf16.count, width) else { return }
            column += width
        }
    }

    /// East Asian Wide and Fullwidth ranges (Unicode 16's EastAsianWidth.txt, W and F), coarsely:
    /// unassigned code points inside a range count as wide, and combining marks within them are
    /// caught earlier by their category.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x3247,
             0x3250...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x16FE0...0x18DFF, 0x1AFF0...0x1B2FF, 0x1F200...0x1F2FF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// Runs the multi-cursor shortcuts while the document editor has focus, and keeps track of the
/// newest selection, which the editor itself does not order.
final class EditorMultiCursorCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?
    private var keyMonitor: Any?
    /// The selections last seen, sorted, and the newest of them.
    private var ranges: [NSRange] = []
    private var newest: NSRange?
    /// The text a ⌘D or ⇧⌘L run started from a cursor selected, matched as a whole word.
    private var wordwiseQuery: String?
    /// The column ⌥⌘↑/↓ keeps while adding cursors, and the selection it left.
    private var goalColumn: (column: Int, after: [NSRange])?
    /// Selections before each command, for ⌘U, with the ranges the command left.
    private var history: [(before: MultiCursorSelection, after: [NSRange])] = []
    /// ⌘K was pressed and the next key may complete ⌘K ⌘D.
    private var awaitsChord = false

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        track(controller.textView.selectionManager.textSelections.map(\.range))
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        track(newPositions.map(\.range))
    }

    func textViewDidChangeText(controller: TextViewController) {
        history.removeAll()
    }

    func destroy() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        controller = nil
    }

    /// Puts a cursor on each range, e.g. every find match, and focuses the editor.
    func select(_ ranges: [NSRange], newest: NSRange?) {
        guard let textView = controller?.textView, let first = ranges.first else { return }
        textView.window?.makeFirstResponder(textView)
        apply(MultiCursorSelection(ranges: ranges, newest: newest.flatMap { ranges.contains($0) ? $0 : nil } ?? first))
    }

    // MARK: Keys

    /// Runs the shortcut in `event`, returning whether it was used. Internal for tests.
    func handle(_ event: NSEvent) -> Bool {
        guard let textView = controller?.textView, textView.isEditable, let window = textView.window,
              event.window === window || event.windowNumber == window.windowNumber,
              window.firstResponder === textView else {
            awaitsChord = false
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)
        if awaitsChord {
            awaitsChord = false
            if flags == .command && key == "d" { run { self.selectNext($0, text: $1, replaceNewest: true) } }
            return flags == .command && key == "d"
        }
        switch (flags, key, code) {
        case (.command, "d", _):
            perform(.selectNextOccurrence)
        case (.command, "k", _):
            awaitsChord = true
        case ([.command, .shift], "l", _), (.command, _, kVK_F2):
            perform(.selectAllOccurrences)
        case ([.command, .option], _, kVK_UpArrow), ([.command, .control], "p", _):
            perform(.addCursorAbove)
        case ([.command, .option], _, kVK_DownArrow), ([.command, .control], "n", _):
            perform(.addCursorBelow)
        case (.command, "u", _):
            return perform(.undoSelection)
        case ([], _, kVK_Escape):
            guard ranges.count > 1 else { return false }
            run { selection, _ in MultiCursor.collapse(selection) }
        default:
            return false
        }
        return true
    }

    // MARK: Commands

    /// Runs a cursor command, from its key or the command palette, giving the editor the keyboard.
    /// Returns false when there is nothing to do, such as no selection to undo.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard let textView = controller?.textView, textView.isEditable else { return false }
        if textView.window?.firstResponder !== textView { textView.window?.makeFirstResponder(textView) }
        switch command {
        case .selectNextOccurrence:
            run { self.selectNext($0, text: $1, replaceNewest: false) }
        case .selectAllOccurrences:
            run { selection, text in
                let result = MultiCursor.selectAll(selection, in: text, wordwise: self.isWordwise(selection, text))
                if selection.newest.length == 0, let result { self.wordwiseQuery = text.substring(with: result.newest) }
                return result
            }
        case .addCursorAbove:
            run { self.addCursor($0, text: $1, above: true) }
        case .addCursorBelow:
            run { self.addCursor($0, text: $1, above: false) }
        case .undoSelection:
            return undoSelection()
        case .save, .find, .findAndReplace, .findNext, .findPrevious:
            return false
        }
        return true
    }

    private func selectNext(_ selection: MultiCursorSelection, text: NSString,
                            replaceNewest: Bool) -> MultiCursorSelection? {
        let result = MultiCursor.selectNext(selection, in: text, wordwise: isWordwise(selection, text),
                                            replaceNewest: replaceNewest)
        if selection.newest.length == 0, let result { wordwiseQuery = text.substring(with: result.newest) }
        return result
    }

    private func addCursor(_ selection: MultiCursorSelection, text: NSString, above: Bool) -> MultiCursorSelection? {
        let column = goalColumn.flatMap { $0.after == selection.ranges ? $0.column : nil }
            ?? DisplayColumns.column(of: (above ? selection.ranges.first : selection.ranges.last)?.location ?? 0,
                                     in: text, tabWidth: tabWidth)
        let result = MultiCursor.addCursor(selection, in: text, above: above, goalColumn: column, tabWidth: tabWidth)
        goalColumn = result.map { (column, $0.ranges) }
        return result
    }

    private var tabWidth: Int { max(controller?.tabWidth ?? 4, 1) }

    /// Whether the newest selection is still the word a ⌘D run started from a cursor selected.
    private func isWordwise(_ selection: MultiCursorSelection, _ text: NSString) -> Bool {
        selection.newest.length > 0 && wordwiseQuery == text.substring(with: selection.newest)
    }

    /// ⌘U: returns to the selections before the last command, while they are unchanged since.
    private func undoSelection() -> Bool {
        guard let last = history.last, last.after == ranges else {
            history.removeAll()
            return false
        }
        history.removeLast()
        apply(last.before)
        return true
    }

    private func run(_ command: (MultiCursorSelection, NSString) -> MultiCursorSelection?) {
        guard let textView = controller?.textView else { return }
        let current = MultiCursorSelection(ranges: ranges, newest: newest ?? ranges.last ?? NSRange(location: 0, length: 0))
        guard let result = command(current, textView.textStorage.string as NSString), result != current else { return }
        history.append((current, result.ranges))
        apply(result)
    }

    private func apply(_ selection: MultiCursorSelection) {
        guard let textView = controller?.textView else { return }
        newest = selection.newest
        ranges = selection.ranges
        textView.selectionManager.setSelectedRanges(selection.ranges)
        textView.needsDisplay = true
        if let rect = textView.layoutManager.rectForOffset(selection.newest.location) {
            textView.scrollToVisible(rect.insetBy(dx: -20, dy: -rect.height))
        }
    }

    /// Follows the selections as the editor changes them, keeping `newest` on the same cursor
    /// across edits and on the cursor an Option-click adds.
    private func track(_ new: [NSRange]) {
        let sorted = new.sorted { $0.location < $1.location }
        defer { ranges = sorted }
        if let newest, sorted.contains(newest) { return }
        if sorted.count == ranges.count, let index = newest.flatMap({ ranges.firstIndex(of: $0) }) {
            newest = sorted[index]
        } else if sorted.count == ranges.count + 1, let added = sorted.first(where: { !ranges.contains($0) }) {
            newest = added
        } else {
            newest = sorted.last
        }
    }
}

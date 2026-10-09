import AppKit
import Carbon.HIToolbox
import CodeEditSourceEditor
import CodeEditTextView

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
        selectOccurrence(selection, in: text, wordwise: wordwise, replaceNewest: replaceNewest, backward: false)
    }

    /// ⌃⌘D: as ⌘D, but adds the previous occurrence before the newest selection, wrapping around
    /// to the end. ⌘K ⌃⌘D replaces the newest selection.
    static func selectPrevious(_ selection: MultiCursorSelection, in text: NSString, wordwise: Bool,
                               replaceNewest: Bool = false) -> MultiCursorSelection? {
        selectOccurrence(selection, in: text, wordwise: wordwise, replaceNewest: replaceNewest, backward: true)
    }

    private static func selectOccurrence(_ selection: MultiCursorSelection, in text: NSString, wordwise: Bool,
                                         replaceNewest: Bool, backward: Bool) -> MultiCursorSelection? {
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
        let found = backward
            ? candidates.last(where: { NSMaxRange($0) <= selection.newest.location }) ?? candidates.last
            : candidates.first(where: { $0.location >= NSMaxRange(selection.newest) }) ?? candidates.first
        guard let found else { return nil }
        return MultiCursorSelection(ranges: others + [found], newest: found)
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
    /// enough to hold part of them. `width` overrides the base selection's own display width, so
    /// a run of presses keeps the width it started with after adding a shorter part on a short line.
    static func addCursor(_ selection: MultiCursorSelection, in text: NSString, above: Bool,
                          goalColumn: Int, width: Int? = nil, tabWidth: Int = 4) -> MultiCursorSelection? {
        guard let base = above ? selection.ranges.first : selection.ranges.last else { return nil }
        let startLine = text.lineRange(for: NSRange(location: base.location, length: 0))
        let width = width ?? displayWidth(of: base, in: text, tabWidth: tabWidth)
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

    /// The display columns a selection on one line covers; 0 for a cursor or one spanning lines,
    /// which ⌥⌘↑/↓ repeat as cursors.
    static func displayWidth(of range: NSRange, in text: NSString, tabWidth: Int) -> Int {
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        guard range.length > 0, NSMaxRange(range) <= contentsEnd(of: line, in: text) else { return 0 }
        return DisplayColumns.column(of: NSMaxRange(range), in: text, tabWidth: tabWidth)
            - DisplayColumns.column(of: range.location, in: text, tabWidth: tabWidth)
    }

    /// Option-drag: one selection per line from the line holding `anchor` to the one holding
    /// `head`, covering display columns `anchorColumn` to `headColumn` (either way round). As in
    /// Zed, a line whose display width is less than the left column is skipped, and one that
    /// ends inside the columns is selected to its end, so a line exactly as long as the left
    /// column gets a cursor at its end. The selection on the head's line is the newest; nil when
    /// every line is too short.
    static func columnSelection(in text: NSString, anchor: Int, anchorColumn: Int, head: Int, headColumn: Int,
                                tabWidth: Int = 4) -> MultiCursorSelection? {
        let anchorLine = text.lineRange(for: NSRange(location: min(max(anchor, 0), text.length), length: 0))
        let headLine = text.lineRange(for: NSRange(location: min(max(head, 0), text.length), length: 0))
        var line = anchorLine.location <= headLine.location ? anchorLine : headLine
        let last = max(anchorLine.location, headLine.location)
        var rows: [DisplayRow] = []
        while true {
            rows.append(DisplayRow(range: NSRange(location: line.location,
                                                  length: contentsEnd(of: line, in: text) - line.location),
                                   endsLine: true))
            guard line.location < last else { break }
            if NSMaxRange(line) < text.length {
                line = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            } else if endsWithNewline(line, text) {
                line = NSRange(location: text.length, length: 0)
            } else {
                break
            }
        }
        let anchorFirst = anchorLine.location <= headLine.location
        return columnSelection(in: text, rows: rows, anchorColumn: anchorColumn,
                               headRow: anchorFirst ? rows.count - 1 : 0, headColumn: headColumn, tabWidth: tabWidth)
    }

    /// A row of text as the editor shows it: a whole line, or with line wrapping on, the part of
    /// one on a row of its own. `range` leaves out the line break.
    struct DisplayRow: Equatable {
        var range: NSRange
        /// Whether the row is the last of its line, rather than one the line wraps after.
        var endsLine: Bool
    }

    /// Option-drag over display rows, `rows` being every row from the top of the block to its
    /// bottom in order, the anchor's and the head's rows at either end: one selection per row
    /// covering display columns `anchorColumn` to `headColumn`, counted from the row's start, so
    /// that a block over wrapped lines is rectangular on screen, as in Zed. Rows too short for the left column are skipped and
    /// those ending inside the columns are selected to their end, as for whole lines; a wrapped
    /// row is skipped too when that would leave only a cursor at its end, which shows at the
    /// start of the next row. The selection on `headRow` is the newest.
    static func columnSelection(in text: NSString, rows: [DisplayRow], anchorColumn: Int,
                                headRow: Int, headColumn: Int, tabWidth: Int = 4) -> MultiCursorSelection? {
        let left = max(min(anchorColumn, headColumn), 0)
        let right = max(anchorColumn, headColumn, 0)
        var ranges: [NSRange] = []
        var newest: NSRange?
        for (index, row) in rows.enumerated() {
            let contents = text.substring(with: row.range)
            let width = DisplayColumns.column(ofUTF16Offset: contents.utf16.count, in: contents, tabWidth: tabWidth)
            guard width >= left else { continue }
            let start = DisplayColumns.offset(forColumn: left, in: contents, tabWidth: tabWidth)
            let stop = DisplayColumns.offset(forColumn: right, in: contents, tabWidth: tabWidth)
            if !row.endsLine, stop <= start, start == row.range.length { continue }
            let range = NSRange(location: row.range.location + start, length: max(stop - start, 0))
            ranges.append(range)
            if index == headRow { newest = range }
        }
        guard let fallback = ranges.last else { return nil }
        return MultiCursorSelection(ranges: ranges, newest: newest ?? fallback)
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

    static func contentsEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func endsWithNewline(_ line: NSRange, _ text: NSString) -> Bool {
        line.length > 0 && [0x0A, 0x0D].contains(text.character(at: NSMaxRange(line) - 1))
    }
}

/// Runs the multi-cursor shortcuts and Option-drag column selection while the document editor
/// has focus, keeps track of the newest selection, which the editor itself does not order, and
/// of the selection changes ⌘U goes back through and ⇧⌘U forward again.
final class EditorMultiCursorCoordinator: TextViewCoordinator {
    /// What changed the selections, for ⌘U: a cursor command, navigation keys (arrows, Home,
    /// End, Page Up and Down, with or without modifiers, and the Emacs-style ⌃F, ⌃B, ⌃N, ⌃P,
    /// ⌃A, ⌃E and ⌃V; a run of them is one step), the mouse (a click, or a click and its drag,
    /// as one step), or anything else, such as ⌘A, find or a reveal (each a step of its own).
    enum SelectionChange: Equatable { case command, keys, mouse, other }

    /// How many selection changes ⌘U can go back through, and ⇧⌘U forward again.
    static let historyLimit = 100
    /// How many ranges each of the two histories keeps across its steps, the selections before
    /// and after each, so that a few ⇧⌘L over tens of thousands of matches do not keep millions
    /// of them; the oldest steps go first, but the latest is always kept. Internal for tests.
    var historyRangeLimit = 100_000

    private weak var controller: TextViewController?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// The selections last seen, sorted, and the newest of them.
    private var ranges: [NSRange] = []
    private var newest: NSRange?
    /// The text a ⌘D or ⇧⌘L run started from a cursor selected, matched as a whole word.
    private var wordwiseQuery: String?
    /// The display column and width ⌥⌘↑/↓ keep while adding cursors, and the selection they left.
    /// A press that follows any other change starts over from the selection it adds to.
    private var addCursorGoal: (column: Int, width: Int, after: [NSRange])?
    /// Selections before each change, for ⌘U, with the ranges the change left.
    private var history: [(before: MultiCursorSelection, after: [NSRange], change: SelectionChange)] = []
    /// Steps ⌘U went back through, latest last, for ⇧⌘U: the ranges ⌘U left and the selections
    /// it left them for. Any newly recorded change clears it.
    private var redoHistory: [(before: [NSRange], after: MultiCursorSelection, change: SelectionChange)] = []
    /// ⌘U or ⇧⌘U moved through the history last, so the next change starts a step of its own
    /// rather than extending the step they returned to.
    private var steppedThroughHistory = false
    /// An edit happened in this turn of the run loop, which the next key or click in the
    /// editor's window also ends. The selection changes that come with it (the editor moving the
    /// cursors past the typed text, marked text, closing brackets) are not steps.
    private var isEditing = false
    private var editGeneration = 0
    /// The text storage the history belongs to; the editor swaps it when the document's text is
    /// replaced from outside, which does not report an edit.
    private var textStorageID: ObjectIdentifier?
    /// The mouse-down that began the last mouse gesture in the editor's window, and the one whose
    /// changes were last recorded, so that a click and its drag are one step but a later drag is not.
    private var mouseDown: TimeInterval?
    private var recordedMouseDown: TimeInterval?
    /// ⌘K was pressed and the next key may complete ⌘K ⌘D or ⌘K ⌃⌘D.
    private var awaitsChord = false
    /// An Option-drag: the offset and display column it started at, and whether it has left them.
    /// With line wrapping on, `row` is where the display row it started on starts.
    private var columnDrag: (anchor: Int, column: Int, row: Int, started: Bool)?
    /// Repeats the last drag event of an Option-drag while the mouse is held still, so that the
    /// block keeps growing as the editor scrolls under a mouse past its edge, or as it is scrolled.
    private var columnDragTimer: Timer?
    private var columnDragEvent: NSEvent?
    /// The coordinator is setting the selections itself and records them on its own.
    private var isApplying = false
    /// The coordinator is making an Option-click, which starts a mouse step its drag continues.
    private var isOptionClicking = false
    /// The event behind a selection change, which tells clicks and arrows from edits. Internal
    /// for tests, which have no real events.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    /// The key event the key monitor last let through to the editor, until the end of the turn
    /// of the run loop that dispatches it. `NSApp.currentEvent` is still the last event handled
    /// long after it, so a change made in code later counts as made by a key only while that key
    /// is being handled.
    private var dispatchingKey: NSEvent?

    func prepareCoordinator(controller: TextViewController) {
        if self.controller !== controller {
            // A new editor, as when the document is reloaded or its Markdown mode changes: the
            // view keeps this coordinator, but the old selections and history mean nothing in it.
            endColumnDrag()
            ranges = []
            newest = nil
            history.removeAll()
            redoHistory.removeAll()
            addCursorGoal = nil
            wordwiseQuery = nil
            isEditing = false
        }
        self.controller = controller
        textStorageID = ObjectIdentifier(controller.textView.textStorage)
        track(controller.textView.selectionManager.textSelections.map(\.range))
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        mouseMonitor = mouseMonitor ?? NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouse(event) == true ? nil : event
        }
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        track(newPositions.map(\.range))
    }

    func textViewDidChangeText(controller: TextViewController) {
        history.removeAll()
        redoHistory.removeAll()
        addCursorGoal = nil
        // Called once per range an edit replaces, so once for each of many cursors: only the
        // first schedules the end of the turn.
        guard !isEditing else { return }
        isEditing = true
        editGeneration += 1
        let generation = editGeneration
        DispatchQueue.main.async { [weak self] in
            if self?.editGeneration == generation { self?.isEditing = false }
        }
    }

    func destroy() {
        // An editor being released no longer reads as `controller`, so one that is set belongs
        // to a newer editor, which SwiftUI made before releasing this one; it keeps the monitors.
        guard controller == nil else { return }
        endColumnDrag()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        controller = nil
    }

    /// Puts a cursor on each range, e.g. every find match, and focuses the editor.
    func select(_ ranges: [NSRange], newest: NSRange?) {
        guard let textView = controller?.textView, let first = ranges.first else { return }
        textView.window?.makeFirstResponder(textView)
        syncSelection()
        let selection = MultiCursorSelection(ranges: ranges,
                                             newest: newest.flatMap { ranges.contains($0) ? $0 : nil } ?? first)
        record(selection.ranges, change: .other, continues: false)
        apply(selection)
    }

    /// Records a selection the editor took without reporting it, which it does while it does not
    /// have the keyboard: a find match selected from the find bar, or a reveal. Called before
    /// anything that reads or changes the selections, and by the document view after a reveal.
    func syncSelection() {
        guard let textView = controller?.textView else { return }
        let actual = textView.selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
        guard actual != ranges else { return }
        track(actual, change: (.other, false))
    }

    // MARK: Keys

    /// Runs the shortcut in `event`, returning whether it was used. Internal for tests.
    ///
    /// ⌃⌘D only arrives while macOS's Look Up shortcut is turned off: the system takes it first.
    func handle(_ event: NSEvent) -> Bool {
        guard let textView = controller?.textView, textView.isEditable, let window = textView.window,
              event.window === window || event.windowNumber == window.windowNumber,
              window.firstResponder === textView else {
            awaitsChord = false
            return false
        }
        // A new key ends the turn of any edit before it.
        isEditing = false
        dispatchingKey = event
        DispatchQueue.main.async { [weak self] in
            if self?.dispatchingKey === event { self?.dispatchingKey = nil }
        }
        syncSelection()
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)
        if awaitsChord {
            awaitsChord = false
            switch (flags, key) {
            case (.command, "d"):
                run { self.selectOccurrence($0, text: $1, backward: false, replaceNewest: true) }
            case ([.command, .control], "d"):
                run { self.selectOccurrence($0, text: $1, backward: true, replaceNewest: true) }
            default:
                return false
            }
            return true
        }
        switch (flags, key, code) {
        case (.command, "d", _):
            perform(.selectNextOccurrence)
        case ([.command, .control], "d", _):
            perform(.selectPreviousOccurrence)
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
        case ([.command, .shift], "u", _):
            return perform(.redoSelection)
        case ([], _, kVK_Escape):
            guard ranges.count > 1 else { return false }
            run { selection, _ in MultiCursor.collapse(selection) }
        default:
            return false
        }
        return true
    }

    // MARK: Mouse

    /// Option-click adds a cursor, or removes the selection under it, as the editor does; dragging
    /// on from there to another column or line selects that block of columns instead
    /// (`MultiCursor.columnSelection`), over display rows when lines wrap. The coordinator takes
    /// the whole gesture from the editor, whose own drag handling would replace the block with
    /// one range. Internal for tests.
    func handleMouse(_ event: NSEvent) -> Bool {
        guard let textView = controller?.textView, let window = textView.window,
              event.window === window || event.windowNumber == window.windowNumber else {
            endColumnDrag()
            return false
        }
        let point = textView.convert(event.locationInWindow, from: nil)
        let text = textView.textStorage.string as NSString
        switch event.type {
        case .leftMouseDown:
            endColumnDrag()
            isEditing = false
            syncSelection()
            mouseDown = event.timestamp
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags == .option, event.clickCount == 1, textView.isEditable, isOverTextView(event, textView),
                  let offset = textView.layoutManager.textOffsetAtPoint(point) else { return false }
            // The window does not see the click, so it would not become key on its own.
            if !window.isKeyWindow { window.makeKey() }
            if window.firstResponder !== textView { window.makeFirstResponder(textView) }
            if textView.layoutManager.wrapLines, let position = wrappedPosition(at: point, in: text) {
                columnDrag = (offset, position.column, position.row.range.location, false)
            } else {
                columnDrag = (offset, displayColumn(at: point, offset: offset, in: text), 0, false)
            }
            optionClick(at: offset)
            return true
        case .leftMouseDragged:
            guard columnDrag != nil else { return false }
            columnDragEvent = event
            dragColumns(to: event)
            textView.autoscroll(with: event)
            // Like the editor's own drag: mouse events stop while the mouse is held still past the
            // edge, but the selection should go on growing as the view scrolls.
            columnDragTimer = columnDragTimer ?? Timer.scheduledTimer(withTimeInterval: 0.022, repeats: true) {
                [weak self] _ in
                guard let self, let event = self.columnDragEvent, let textView = self.controller?.textView else { return }
                textView.autoscroll(with: event)
                self.dragColumns(to: event)
            }
            return true
        case .leftMouseUp:
            guard columnDrag != nil else { return false }
            endColumnDrag()
            return true
        default:
            return false
        }
    }

    /// Selects the block from where the Option-drag started to the mouse in `event`.
    private func dragColumns(to event: NSEvent) {
        guard var drag = columnDrag, let textView = controller?.textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let text = textView.textStorage.string as NSString
        let block: MultiCursorSelection?
        if textView.layoutManager.wrapLines {
            guard let head = wrappedPosition(at: point, in: text) else { return }
            if !drag.started {
                guard head.column != drag.column || head.row.range.location != drag.row else { return }
                drag.started = true
                columnDrag = drag
            }
            let headRow = head.row.range.location
            let rows = displayRows(from: min(drag.row, headRow), to: max(drag.row, headRow), in: text)
            block = MultiCursor.columnSelection(in: text, rows: rows, anchorColumn: drag.column,
                                                headRow: headRow < drag.row ? 0 : rows.count - 1,
                                                headColumn: head.column, tabWidth: tabWidth)
        } else {
            let offset = textView.layoutManager.textOffsetAtPoint(point) ?? (point.y < 0 ? 0 : text.length)
            let column = displayColumn(at: point, offset: offset, in: text)
            let sameLine = text.lineRange(for: NSRange(location: offset, length: 0))
                == text.lineRange(for: NSRange(location: drag.anchor, length: 0))
            if !drag.started {
                guard column != drag.column || !sameLine else { return }
                drag.started = true
                columnDrag = drag
            }
            block = MultiCursor.columnSelection(in: text, anchor: drag.anchor, anchorColumn: drag.column,
                                                head: offset, headColumn: column, tabWidth: tabWidth)
        }
        guard let block, block.ranges != ranges || block.newest != newest else { return }
        record(block.ranges, change: .mouse, continues: mouseDown != nil && recordedMouseDown == mouseDown)
        recordedMouseDown = mouseDown
        apply(block)
    }

    private func endColumnDrag() {
        columnDragTimer?.invalidate()
        columnDragTimer = nil
        columnDragEvent = nil
        columnDrag = nil
    }

    private func isOverTextView(_ event: NSEvent, _ textView: NSView) -> Bool {
        guard let contentView = textView.window?.contentView else { return false }
        let point = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = contentView.hitTest(point) else { return false }
        return hit === textView || hit.isDescendant(of: textView)
    }

    /// The display column under `point`, at the character boundary `offset` the editor found
    /// there, plus the columns past the end of a short line.
    private func displayColumn(at point: NSPoint, offset: Int, in text: NSString) -> Int {
        let column = DisplayColumns.column(of: offset, in: text, tabWidth: tabWidth)
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        guard let controller, let layout = controller.textView.layoutManager,
              offset == MultiCursor.contentsEnd(of: line, in: text) else { return column }
        guard let endX = layout.rectForOffset(offset)?.minX
                ?? (offset > line.location ? layout.rectForOffset(offset - 1)?.maxX : nil) else { return column }
        return column + columnsPast(endX, to: point.x)
    }

    /// Whole character widths from `endX` to `x`, for the mouse past the end of a row.
    private func columnsPast(_ endX: CGFloat, to x: CGFloat) -> Int {
        guard let controller else { return 0 }
        let charWidth = (" " as NSString).size(withAttributes: [.font: controller.font]).width
        guard charWidth > 0, x > endX else { return 0 }
        return Int(((x - endX) / charWidth).rounded())
    }

    /// With line wrapping on, the display row under `point` (the first or last when the point is
    /// above or below the text), its top, and the display column under `point` counted from the
    /// row's start, plus the columns past its end.
    private func wrappedPosition(at point: NSPoint, in text: NSString) -> (row: MultiCursor.DisplayRow, column: Int)? {
        guard let layout = controller?.textView.layoutManager else { return nil }
        let y = min(max(point.y, 0), max(layout.estimatedHeight() - 1, 0))
        guard let line = layout.textLineForPosition(y) ?? layout.textLineForIndex(layout.lineCount - 1) else {
            return nil
        }
        let rows = displayRows(of: line, in: text)
        guard let under = rows.last(where: { $0.y <= y }) ?? rows.first else { return nil }
        let row = under.row
        let contents = text.substring(with: row.range)
        let found = layout.textOffsetAtPoint(NSPoint(x: point.x, y: under.y + 1)) ?? row.range.location
        let offset = min(max(found, row.range.location), NSMaxRange(row.range))
        var column = DisplayColumns.column(ofUTF16Offset: offset - row.range.location, in: contents,
                                          tabWidth: tabWidth)
        if offset == NSMaxRange(row.range) {
            let endX = offset > row.range.location
                ? layout.rectForOffset(offset - 1)?.maxX : layout.rectForOffset(row.range.location)?.minX
            if let endX { column += columnsPast(endX, to: point.x) }
        }
        return (row, column)
    }

    /// The display rows that start from offset `top` to offset `bottom`, in order. Rows are
    /// told apart by where they start rather than by their place on screen, which moves as
    /// lines scrolled into view are laid out.
    private func displayRows(from top: Int, to bottom: Int, in text: NSString) -> [MultiCursor.DisplayRow] {
        guard let layout = controller?.textView.layoutManager,
              let first = layout.textLineForOffset(top)?.index,
              let last = layout.textLineForOffset(bottom)?.index else { return [] }
        var rows: [MultiCursor.DisplayRow] = []
        for index in first...max(first, last) {
            guard let line = layout.textLineForIndex(index) else { break }
            rows += displayRows(of: line, in: text).map(\.row).filter {
                $0.range.location >= top && $0.range.location <= bottom
            }
        }
        return rows
    }

    /// The rows a line takes on screen, with their tops, laying it out first if it is not yet.
    private func displayRows(of line: TextLineStorage<TextLine>.TextLinePosition,
                             in text: NSString) -> [(row: MultiCursor.DisplayRow, y: CGFloat)] {
        let contentsEnd = MultiCursor.contentsEnd(of: line.range, in: text)
        let whole = (row: MultiCursor.DisplayRow(range: NSRange(location: line.range.location,
                                                                length: contentsEnd - line.range.location),
                                                 endsLine: true), y: line.yPos)
        guard let layout = controller?.textView.layoutManager else { return [whole] }
        if line.data.lineFragments.isEmpty { _ = layout.rectForOffset(line.range.location) }
        var rows: [(row: MultiCursor.DisplayRow, y: CGFloat)] = []
        for fragment in line.data.lineFragments {
            let start = line.range.location + fragment.range.location
            let end = start + fragment.range.length
            // A row holding nothing but the line break belongs to the row before it.
            if start >= contentsEnd, !rows.isEmpty {
                rows[rows.count - 1].row.endsLine = true
                continue
            }
            let range = NSRange(location: start, length: max(min(end, contentsEnd) - start, 0))
            rows.append((MultiCursor.DisplayRow(range: range, endsLine: end >= NSMaxRange(line.range)),
                         line.yPos + fragment.yPos))
        }
        return rows.isEmpty ? [whole] : rows
    }

    /// The editor's Option-click, which `track` records as a click.
    private func optionClick(at offset: Int) {
        guard let textView = controller?.textView else { return }
        isOptionClicking = true
        defer { isOptionClicking = false }
        textView.unmarkText()
        let selections = textView.selectionManager.textSelections.map(\.range)
        if selections.count > 1, let hit = selections.firstIndex(where: {
            $0.length == 0 ? $0.location == offset : NSLocationInRange(offset, $0)
        }) {
            textView.selectionManager.setSelectedRanges(selections.indices.filter { $0 != hit }.map { selections[$0] })
        } else {
            textView.selectionManager.addSelectedRange(NSRange(location: offset, length: 0))
        }
        textView.needsDisplay = true
    }

    // MARK: Commands

    /// Runs a cursor command, from its key or the command palette, giving the editor the keyboard.
    /// Returns false when there is nothing to do, such as no selection to undo.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        guard let textView = controller?.textView, textView.isEditable else { return false }
        if textView.window?.firstResponder !== textView { textView.window?.makeFirstResponder(textView) }
        syncSelection()
        switch command {
        case .selectNextOccurrence:
            run { self.selectOccurrence($0, text: $1, backward: false, replaceNewest: false) }
        case .selectPreviousOccurrence:
            run { self.selectOccurrence($0, text: $1, backward: true, replaceNewest: false) }
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
        case .redoSelection:
            return redoSelection()
        case .save, .find, .findAndReplace, .findNext, .findPrevious:
            return false
        }
        return true
    }

    private func selectOccurrence(_ selection: MultiCursorSelection, text: NSString, backward: Bool,
                                  replaceNewest: Bool) -> MultiCursorSelection? {
        let wordwise = isWordwise(selection, text)
        let result = backward
            ? MultiCursor.selectPrevious(selection, in: text, wordwise: wordwise, replaceNewest: replaceNewest)
            : MultiCursor.selectNext(selection, in: text, wordwise: wordwise, replaceNewest: replaceNewest)
        if selection.newest.length == 0, let result { wordwiseQuery = text.substring(with: result.newest) }
        return result
    }

    /// Keeps the first press's display column and width while each press adds to what the last
    /// one left, so a part clamped to a short line does not narrow the lines after it.
    private func addCursor(_ selection: MultiCursorSelection, text: NSString, above: Bool) -> MultiCursorSelection? {
        let goal = addCursorGoal.flatMap { $0.after == selection.ranges ? $0 : nil }
        let base = above ? selection.ranges.first : selection.ranges.last
        let column = goal?.column ?? DisplayColumns.column(of: base?.location ?? 0, in: text, tabWidth: tabWidth)
        let width = goal?.width ?? base.map { MultiCursor.displayWidth(of: $0, in: text, tabWidth: tabWidth) } ?? 0
        guard let result = MultiCursor.addCursor(selection, in: text, above: above, goalColumn: column,
                                                 width: width, tabWidth: tabWidth) else { return nil }
        addCursorGoal = (column, width, result.ranges)
        return result
    }

    private var tabWidth: Int { max(controller?.tabWidth ?? 4, 1) }

    /// Whether the newest selection is still the word a ⌘D run started from a cursor selected.
    private func isWordwise(_ selection: MultiCursorSelection, _ text: NSString) -> Bool {
        selection.newest.length > 0 && wordwiseQuery == text.substring(with: selection.newest)
    }

    // MARK: Selection history

    /// ⌘U: returns to the selections before the last change, while they are unchanged since.
    private func undoSelection() -> Bool {
        guard let last = history.last, last.after == ranges else {
            history.removeAll()
            return false
        }
        history.removeLast()
        redoHistory.append((last.before.ranges, currentSelection, last.change))
        trim(&redoHistory) { $0.before.count + $0.after.ranges.count }
        steppedThroughHistory = true
        apply(last.before)
        return true
    }

    /// ⇧⌘U: goes forward again through a change ⌘U went back from, while the selections are
    /// still the ones ⌘U left.
    private func redoSelection() -> Bool {
        guard let next = redoHistory.last, next.before == ranges else {
            redoHistory.removeAll()
            return false
        }
        redoHistory.removeLast()
        history.append((currentSelection, next.after.ranges, next.change))
        trimHistory()
        steppedThroughHistory = true
        apply(next.after)
        return true
    }

    private var currentSelection: MultiCursorSelection {
        MultiCursorSelection(ranges: ranges, newest: newest ?? ranges.last ?? NSRange(location: 0, length: 0))
    }

    /// Records a change from the current selections to `after`, which ends what ⇧⌘U could go
    /// forward through. With `continues`, a change of the same kind right after the last one
    /// extends that step instead of adding one, and a step that ends where it began is dropped.
    private func record(_ after: [NSRange], change: SelectionChange, continues: Bool) {
        guard after != ranges else { return }
        redoHistory.removeAll()
        defer { steppedThroughHistory = false }
        if continues, !steppedThroughHistory, let last = history.last, last.change == change, last.after == ranges {
            if last.before.ranges == after {
                history.removeLast()
            } else {
                history[history.count - 1].after = after
                trimHistory()
            }
            return
        }
        history.append((currentSelection, after, change))
        trimHistory()
    }

    private func trimHistory() {
        trim(&history) { $0.before.ranges.count + $0.after.count }
    }

    /// Drops the oldest steps past `historyLimit`, then while the steps hold more than
    /// `historyRangeLimit` ranges in all, keeping the latest step whatever its size.
    private func trim<Step>(_ steps: inout [Step], ranges: (Step) -> Int) {
        if steps.count > Self.historyLimit { steps.removeFirst(steps.count - Self.historyLimit) }
        var total = steps.reduce(0) { $0 + ranges($1) }
        var dropped = 0
        while total > historyRangeLimit, dropped < steps.count - 1 {
            total -= ranges(steps[dropped])
            dropped += 1
        }
        steps.removeFirst(dropped)
    }

    /// The kind of change the current event makes, and whether it continues the last step: more
    /// navigation keys, or more of the click (and its drag) that started the step. Changes with
    /// no event of the editor behind them, such as a find match or a reveal, are steps of their
    /// own.
    private func userChange() -> (change: SelectionChange, continues: Bool) {
        if isOptionClicking {
            recordedMouseDown = mouseDown
            return (.mouse, false)
        }
        guard let event = currentEvent() else { return (.other, false) }
        switch event.type {
        case .keyDown:
            // Only while the key is being handled: a change made in code after it is a step of
            // its own, not part of the key's run.
            guard event === dispatchingKey else { return (.other, false) }
            return Self.isNavigationKey(event) ? (.keys, true) : (.other, false)
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.type == .leftMouseDown { mouseDown = event.timestamp }
            // A drag continues its click's step only when that click was recorded: a click that
            // left the selections alone must not join its drag to an earlier click.
            let continues = mouseDown != nil && recordedMouseDown == mouseDown
            recordedMouseDown = mouseDown
            return (.mouse, continues)
        default:
            return (.other, false)
        }
    }

    /// Arrows, Home, End, Page Up and Page Down, which move or extend the selections, and the
    /// Emacs-style keys that do the same: ⌃F, ⌃B, ⌃N, ⌃P, ⌃A, ⌃E and ⌃V, with or without ⇧.
    static func isNavigationKey(_ event: NSEvent) -> Bool {
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
            .contains(Int(event.keyCode)) { return true }
        guard event.modifierFlags.intersection([.command, .option, .control]) == .control,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["f", "b", "n", "p", "a", "e", "v"].contains(key)
    }

    private func run(_ command: (MultiCursorSelection, NSString) -> MultiCursorSelection?) {
        guard let textView = controller?.textView else { return }
        let current = MultiCursorSelection(ranges: ranges, newest: newest ?? ranges.last ?? NSRange(location: 0, length: 0))
        guard let result = command(current, textView.textStorage.string as NSString), result != current else { return }
        record(result.ranges, change: .command, continues: false)
        apply(result)
    }

    private func apply(_ selection: MultiCursorSelection) {
        guard let textView = controller?.textView else { return }
        newest = selection.newest
        ranges = selection.ranges
        isApplying = true
        textView.selectionManager.setSelectedRanges(selection.ranges)
        isApplying = false
        textView.needsDisplay = true
        if let rect = textView.layoutManager.rectForOffset(selection.newest.location) {
            textView.scrollToVisible(rect.insetBy(dx: -20, dy: -rect.height))
        }
    }

    /// Follows the selections as the editor changes them, keeping `newest` on the same cursor
    /// across edits and on the cursor an Option-click adds, and records every change that is not
    /// part of an edit for ⌘U, as `change` says or as the current event tells.
    private func track(_ new: [NSRange], change: (change: SelectionChange, continues: Bool)? = nil) {
        let sorted = new.sorted { $0.location < $1.location }
        let storageID = controller.map { ObjectIdentifier($0.textView.textStorage) }
        if storageID != textStorageID {
            // New text from outside: the old selections mean nothing in it.
            textStorageID = storageID
            history.removeAll()
            redoHistory.removeAll()
        } else if !isApplying, !isEditing, sorted != ranges, !ranges.isEmpty {
            let user = change ?? userChange()
            record(sorted, change: user.change, continues: user.continues)
        }
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

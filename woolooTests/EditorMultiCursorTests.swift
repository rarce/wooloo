import XCTest
import SwiftUI
import Carbon.HIToolbox
import CodeEditSourceEditor
import CodeEditTextView
@testable import wooloo

/// Multi-cursor commands as in Zed: the range logic alone, then the shortcuts, typing, undo and
/// copy/paste on a real CodeEditSourceEditor hosted offscreen.
final class EditorMultiCursorTests: XCTestCase {
    private final class ControllerSpy: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func range(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }

    private func cursor(_ location: Int) -> MultiCursorSelection {
        MultiCursorSelection(ranges: [range(location)], newest: range(location))
    }

    // MARK: - Ranges

    func testSelectNextFromACursorSelectsTheWordThenWholeWordOccurrencesWrappingAround() throws {
        let text = "foo foobar Foo foo\nfoo" as NSString
        var selection = try XCTUnwrap(MultiCursor.selectNext(cursor(16), in: text, wordwise: false))
        XCTAssertEqual(selection.ranges, [range(15, 3)])

        selection = try XCTUnwrap(MultiCursor.selectNext(selection, in: text, wordwise: true))
        XCTAssertEqual(selection.ranges, [range(15, 3), range(19, 3)])
        XCTAssertEqual(selection.newest, range(19, 3))

        // Wraps to the start, skipping "foobar" and "Foo".
        selection = try XCTUnwrap(MultiCursor.selectNext(selection, in: text, wordwise: true))
        XCTAssertEqual(selection.ranges, [range(0, 3), range(15, 3), range(19, 3)])
        XCTAssertNil(MultiCursor.selectNext(selection, in: text, wordwise: true))
    }

    func testSelectNextFromASelectionMatchesInsideWordsAndIsCaseSensitive() throws {
        let text = "foo foobar Foo" as NSString
        let start = MultiCursorSelection(ranges: [range(0, 3)], newest: range(0, 3))
        let selection = try XCTUnwrap(MultiCursor.selectNext(start, in: text, wordwise: false))
        XCTAssertEqual(selection.ranges, [range(0, 3), range(4, 3)])
        XCTAssertNil(MultiCursor.selectNext(selection, in: text, wordwise: false))
    }

    func testSkipReplacesTheNewestSelectionWithTheNextOccurrence() throws {
        let text = "a x a x a" as NSString
        let start = MultiCursorSelection(ranges: [range(0, 1), range(4, 1)], newest: range(4, 1))
        let selection = try XCTUnwrap(MultiCursor.selectNext(start, in: text, wordwise: true, replaceNewest: true))
        XCTAssertEqual(selection.ranges, [range(0, 1), range(8, 1)])
        XCTAssertEqual(selection.newest, range(8, 1))
    }

    func testSelectAllSelectsEveryOccurrenceOfTheWordUnderTheCursor() throws {
        let text = "let beta = beta + betamax\nbeta" as NSString
        let selection = try XCTUnwrap(MultiCursor.selectAll(cursor(13), in: text, wordwise: false))
        XCTAssertEqual(selection.ranges, [range(4, 4), range(11, 4), range(26, 4)])
        XCTAssertEqual(selection.newest, range(11, 4))
        XCTAssertNil(MultiCursor.selectAll(cursor(9), in: text, wordwise: false), "no word under the cursor")
    }

    func testAddingCursorsBelowKeepsTheGoalColumnAcrossShortLines() throws {
        let text = "0123456789\nab\n0123456789\n" as NSString
        var selection = try XCTUnwrap(MultiCursor.addCursor(cursor(7), in: text, above: false, goalColumn: 7))
        XCTAssertEqual(selection.newest, range(13), "clamped to the end of \"ab\"")
        selection = try XCTUnwrap(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 7))
        XCTAssertEqual(selection.ranges, [range(7), range(13), range(21)])
        selection = try XCTUnwrap(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 7))
        XCTAssertEqual(selection.newest, range(25), "the empty last line")
        XCTAssertNil(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 7))
        XCTAssertNil(MultiCursor.addCursor(cursor(3), in: text, above: true, goalColumn: 3), "already on the first line")
    }

    func testAddingASelectionAboveSkipsLinesTooShortForIt() throws {
        let text = "0123456789\nab\n0123456789" as NSString
        let start = MultiCursorSelection(ranges: [range(18, 3)], newest: range(18, 3))
        let selection = try XCTUnwrap(MultiCursor.addCursor(start, in: text, above: true, goalColumn: 4))
        XCTAssertEqual(selection.ranges, [range(4, 3), range(18, 3)])
    }

    func testAGivenWidthKeepsTheFirstSelectionsWidthPastAShortLine() throws {
        let text = "0123456789\nabcde\n0123456789" as NSString
        let start = MultiCursorSelection(ranges: [range(3, 4)], newest: range(3, 4))
        let first = try XCTUnwrap(MultiCursor.addCursor(start, in: text, above: false, goalColumn: 3))
        XCTAssertEqual(first.newest, range(14, 2), "the part of columns 3–7 that \"abcde\" holds")
        let narrowed = try XCTUnwrap(MultiCursor.addCursor(first, in: text, above: false, goalColumn: 3))
        XCTAssertEqual(narrowed.newest, range(20, 2), "without a width, the short part is the base")
        let kept = try XCTUnwrap(MultiCursor.addCursor(first, in: text, above: false, goalColumn: 3, width: 4))
        XCTAssertEqual(kept.newest, range(20, 4))
        XCTAssertEqual(MultiCursor.displayWidth(of: range(3, 4), in: text, tabWidth: 4), 4)
        XCTAssertEqual(MultiCursor.displayWidth(of: range(8, 5), in: text, tabWidth: 4), 0, "spans lines")
    }

    func testSelectPreviousWalksBackwardsAndWrapsToTheEnd() throws {
        let text = "foo bar foo foobar foo" as NSString
        var selection = try XCTUnwrap(MultiCursor.selectPrevious(cursor(20), in: text, wordwise: false))
        XCTAssertEqual(selection.ranges, [range(19, 3)], "an empty selection takes the word first")
        selection = try XCTUnwrap(MultiCursor.selectPrevious(selection, in: text, wordwise: true))
        XCTAssertEqual(selection.ranges, [range(8, 3), range(19, 3)], "skipping \"foobar\"")
        XCTAssertEqual(selection.newest, range(8, 3))
        selection = try XCTUnwrap(MultiCursor.selectPrevious(selection, in: text, wordwise: true))
        XCTAssertEqual(selection.newest, range(0, 3))
        XCTAssertNil(MultiCursor.selectPrevious(selection, in: text, wordwise: true))

        let first = MultiCursorSelection(ranges: [range(0, 3)], newest: range(0, 3))
        let wrapped = try XCTUnwrap(MultiCursor.selectPrevious(first, in: text, wordwise: false))
        XCTAssertEqual(wrapped.newest, range(19, 3), "wraps around to the last occurrence")
        let skipped = try XCTUnwrap(MultiCursor.selectPrevious(
            MultiCursorSelection(ranges: [range(8, 3), range(19, 3)], newest: range(8, 3)),
            in: text, wordwise: true, replaceNewest: true))
        XCTAssertEqual(skipped.ranges, [range(0, 3), range(19, 3)], "⌘K ⌃⌘D replaces the newest")
    }

    func testColumnSelectionSkipsLinesShorterThanItsLeftColumn() throws {
        // Lines: "abcdef" 0, "ab" 7, "a" 10, "\tabcd" 12, "abcdefgh" 18.
        let text = "abcdef\nab\na\n\tabcd\nabcdefgh" as NSString
        let down = try XCTUnwrap(MultiCursor.columnSelection(in: text, anchor: 2, anchorColumn: 2,
                                                             head: 23, headColumn: 5))
        XCTAssertEqual(down.ranges, [range(2, 3), range(9), range(13, 1), range(20, 3)],
                       "\"ab\" gets a cursor at its end, \"a\" none, and the tab counts its 4 columns")
        XCTAssertEqual(down.newest, range(20, 3), "the line under the mouse")

        let up = try XCTUnwrap(MultiCursor.columnSelection(in: text, anchor: 23, anchorColumn: 5,
                                                           head: 2, headColumn: 2))
        XCTAssertEqual(up.ranges, down.ranges, "dragged either way")
        XCTAssertEqual(up.newest, range(2, 3))

        let cursors = try XCTUnwrap(MultiCursor.columnSelection(in: text, anchor: 1, anchorColumn: 1,
                                                                head: 19, headColumn: 1))
        XCTAssertEqual(cursors.ranges, [range(1), range(8), range(11), range(12), range(19)],
                       "one column: a cursor on every line long enough, before a tab nearer its start")
        XCTAssertNil(MultiCursor.columnSelection(in: "a\nb" as NSString, anchor: 0, anchorColumn: 5,
                                                 head: 2, headColumn: 7), "every line is too short")
        let wide = try XCTUnwrap(MultiCursor.columnSelection(in: "日本語\nabcdef" as NSString, anchor: 1,
                                                             anchorColumn: 2, head: 8, headColumn: 4))
        XCTAssertEqual(wide.ranges, [range(1, 1), range(6, 2)], "display columns line up wide characters")
        let trailing = try XCTUnwrap(MultiCursor.columnSelection(in: "ab\n" as NSString, anchor: 0, anchorColumn: 0,
                                                                 head: 3, headColumn: 1))
        XCTAssertEqual(trailing.ranges, [range(0, 1), range(3)], "the empty last line")
    }

    func testColumnSelectionOverDisplayRowsCountsColumnsFromEachRowsStart() throws {
        // "abcdef ghij" wraps after "abcdef " (row 0, 0–7) to "ghij" (row 1, 7–11); then "xy" (12)
        // and "\tz" (15).
        let text = "abcdef ghij\nxy\n\tz" as NSString
        let rows = [
            MultiCursor.DisplayRow(range: range(0, 7), endsLine: false),
            MultiCursor.DisplayRow(range: range(7, 4), endsLine: true),
            MultiCursor.DisplayRow(range: range(12, 2), endsLine: true),
            MultiCursor.DisplayRow(range: range(15, 2), endsLine: true),
        ]
        let block = try XCTUnwrap(MultiCursor.columnSelection(in: text, rows: rows, anchorColumn: 1,
                                                              headRow: 3, headColumn: 3))
        XCTAssertEqual(block.ranges, [range(1, 2), range(8, 2), range(13, 1), range(15, 1)],
                       "columns 1–3 of each row, counted from the row's start, to the end of \"xy\"")
        XCTAssertEqual(block.newest, range(15, 1), "the head's row")

        let up = try XCTUnwrap(MultiCursor.columnSelection(in: text, rows: rows, anchorColumn: 3,
                                                           headRow: 0, headColumn: 1))
        XCTAssertEqual(up.ranges, block.ranges)
        XCTAssertEqual(up.newest, range(1, 2), "the head's row at the top")

        // Column 4: a cursor inside "abcdef " and at the end of "ghij", exactly that long; "xy" is
        // too short.
        let end = try XCTUnwrap(MultiCursor.columnSelection(in: text, rows: Array(rows.prefix(3)),
                                                            anchorColumn: 4, headRow: 2, headColumn: 4))
        XCTAssertEqual(end.ranges, [range(4), range(11)])
        let wrapEnd = MultiCursor.columnSelection(in: text, rows: [rows[0]], anchorColumn: 7, headRow: 0,
                                                  headColumn: 7)
        XCTAssertNil(wrapEnd, "no cursor at the end of a wrapped row, which would show on the next one")

        // Whole lines as rows give the same block as the line-based selection.
        let lines = try XCTUnwrap(MultiCursor.columnSelection(in: text, anchor: 0, anchorColumn: 1,
                                                              head: 15, headColumn: 3))
        let lineRows = [range(0, 11), range(12, 2), range(15, 2)].map {
            MultiCursor.DisplayRow(range: $0, endsLine: true)
        }
        XCTAssertEqual(MultiCursor.columnSelection(in: text, rows: lineRows, anchorColumn: 1, headRow: 2,
                                                   headColumn: 3), lines)
    }

    func testDisplayColumnsMatchUTF16ColumnsForPlainASCII() {
        let text = "let x = 1\n    return x\n" as NSString
        for offset in 0...text.length {
            let line = text.lineRange(for: range(min(offset, text.length)))
            XCTAssertEqual(DisplayColumns.column(of: offset, in: text, tabWidth: 4), offset - line.location)
        }
        XCTAssertEqual(DisplayColumns.offset(forColumn: 6, in: "    return x", tabWidth: 4), 6)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 40, in: "    return x", tabWidth: 4), 12, "clamped")
    }

    func testAddingCursorsKeepsTheDisplayColumnAcrossTabs() throws {
        let text = "\tx\n    abcd\n\t\tz\nab" as NSString
        XCTAssertEqual(DisplayColumns.column(of: 1, in: text, tabWidth: 4), 4, "after the tab")
        var selection = try XCTUnwrap(MultiCursor.addCursor(cursor(1), in: text, above: false,
                                                            goalColumn: 4, tabWidth: 4))
        XCTAssertEqual(selection.newest, range(7), "under the tab's end, not after one space")
        selection = try XCTUnwrap(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 4, tabWidth: 4))
        XCTAssertEqual(selection.newest, range(13), "between the two tabs")
        selection = try XCTUnwrap(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 4, tabWidth: 4))
        XCTAssertEqual(selection.newest, range(18), "clamped to the shorter last line")

        // A column inside a tab goes to the nearer tab stop, the later one on a tie.
        XCTAssertEqual(DisplayColumns.offset(forColumn: 1, in: "\tx", tabWidth: 4), 0)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 2, in: "\tx", tabWidth: 4), 1)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 3, in: "\tx", tabWidth: 4), 1)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 2, in: "\tx", tabWidth: 8), 0, "the editor's tab width")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "ab\tx", tabWidth: 4), 4, "tab stops, not tab widths")
    }

    func testAddingCursorsKeepsTheDisplayColumnAcrossWideCharacters() throws {
        let text = "日本語x\nabcdefgh" as NSString
        XCTAssertEqual(DisplayColumns.column(of: 2, in: text, tabWidth: 4), 4)
        let below = try XCTUnwrap(MultiCursor.addCursor(cursor(2), in: text, above: false, goalColumn: 4))
        XCTAssertEqual(below.newest, range(9))
        let above = try XCTUnwrap(MultiCursor.addCursor(cursor(12), in: text, above: true, goalColumn: 3))
        XCTAssertEqual(above.newest, range(2), "column 3 is inside 本; the later boundary on a tie")
        XCTAssertEqual(DisplayColumns.offset(forColumn: 5, in: "日本語x", tabWidth: 4), 3, "inside 語")

        // A selection keeps its display width.
        let selected = MultiCursorSelection(ranges: [range(1, 1)], newest: range(1, 1))
        let added = try XCTUnwrap(MultiCursor.addCursor(selected, in: text, above: false, goalColumn: 2))
        XCTAssertEqual(added.newest, range(7, 2), "本 covers columns 2–4, \"cd\" below")
    }

    func testEmojiAndCombiningMarksAreWholeClustersOfTheirWidth() throws {
        let family = "👨‍👩‍👧"
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "👍x", tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: family.utf16.count, in: family + "x", tabWidth: 4), 2,
                       "a ZWJ sequence is one wide cluster")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "❤️x", tabWidth: 4), 2, "text emoji with U+FE0F")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 4, in: "🇨🇱x", tabWidth: 4), 2, "a flag")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "e\u{301}x", tabWidth: 4), 1, "e + combining acute")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 1, in: "\u{301}x", tabWidth: 4), 0, "a lone combining mark")

        let text = "\(family)x\nabcdef\ne\u{301}xy" as NSString
        let familyEnd = family.utf16.count
        let secondLine = familyEnd + 2
        let below = try XCTUnwrap(MultiCursor.addCursor(cursor(familyEnd), in: text, above: false, goalColumn: 2))
        XCTAssertEqual(below.newest, range(secondLine + 2))
        let into = try XCTUnwrap(MultiCursor.addCursor(cursor(secondLine + 1), in: text, above: true, goalColumn: 1))
        XCTAssertEqual(into.newest, range(familyEnd), "never inside the ZWJ sequence")
        let third = secondLine + 7
        let combining = try XCTUnwrap(MultiCursor.addCursor(cursor(secondLine + 1), in: text, above: false,
                                                            goalColumn: 1))
        XCTAssertEqual(combining.newest, range(third + 2), "after the whole é, not between e and its accent")
        let fromAccent = try XCTUnwrap(MultiCursor.addCursor(cursor(third + 3), in: text, above: true, goalColumn: 2))
        XCTAssertEqual(fromAccent.newest, range(secondLine + 2))
    }

    func testTabsAfterWideCharactersAdvanceToTheNextTabStop() {
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "日\tx", tabWidth: 4), 4)
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 4, in: "日本語\tx", tabWidth: 4), 8, "from 6 to 8")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "日本\tx", tabWidth: 4), 8, "a full tab from a stop")
        XCTAssertEqual(DisplayColumns.offset(forColumn: 7, in: "日本語\tx", tabWidth: 4), 4, "a tie inside the tab goes to its end")
    }

    func testVariationSelectorsKeycapsAndPrependedCharacters() {
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "❤\u{FE0E}x", tabWidth: 4), 1, "U+FE0E: text style")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "⌚\u{FE0E}x", tabWidth: 4), 1,
                       "U+FE0E narrows an emoji-default watch too")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 1, in: "⌚x", tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "1\u{FE0F}\u{20E3}x", tabWidth: 4), 2, "a keycap")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "✌\u{1F3FB}x", tabWidth: 4), 2,
                       "a skin tone makes a text-default emoji wide")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 1, in: "✌x", tabWidth: 4), 1)
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "\u{0600}1x", tabWidth: 4), 1,
                       "a prepended format character leads a visible cluster")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 1, in: "\u{200B}x", tabWidth: 4), 0, "a lone format character")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "a\u{7}b", tabWidth: 4), 2, "a control character")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 3, in: "a\u{7}bé", tabWidth: 4), 2,
                       "the same outside the all-ASCII path")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 1, in: "\u{3248}", tabWidth: 4), 1,
                       "ambiguous-width circled numbers stay narrow")
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: 2, in: "\u{1AFF0}", tabWidth: 4), 2, "Kana Extended-B")
    }

    func testColumnsInsideAClusterCountFromItsStart() {
        let text = "ae\u{301}b\n👍x" as NSString
        XCTAssertEqual(DisplayColumns.column(of: 2, in: text, tabWidth: 4), 1, "between e and its accent")
        XCTAssertEqual(DisplayColumns.column(of: 3, in: text, tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.column(of: 6, in: text, tabWidth: 4), 0, "between the surrogates of 👍")
        XCTAssertEqual(DisplayColumns.column(of: 7, in: text, tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.column(of: 99, in: text, tabWidth: 4), 3, "clamped to the text")
        XCTAssertEqual(DisplayColumns.offset(forColumn: 3, in: "", tabWidth: 4), 0, "an empty line")
    }

    func testAddingCursorsAcrossCRLFLinesStaysOutOfTheLineBreaks() throws {
        let text = "a\tb\r\nxy\r\n12345" as NSString
        var selection = try XCTUnwrap(MultiCursor.addCursor(cursor(2), in: text, above: false, goalColumn: 4))
        XCTAssertEqual(selection.newest, range(7), "clamped before the CR of \"xy\"")
        selection = try XCTUnwrap(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 4))
        XCTAssertEqual(selection.newest, range(13))
        XCTAssertNil(MultiCursor.addCursor(selection, in: text, above: false, goalColumn: 4), "the last line")
        let above = try XCTUnwrap(MultiCursor.addCursor(cursor(13), in: text, above: true, goalColumn: 3))
        XCTAssertEqual(above.newest, range(7))
    }

    func testAddingACursorBelowASelectionSpanningLinesStartsAfterItsEnd() throws {
        let text = "abc\ndef\nghi\njkl" as NSString
        let start = MultiCursorSelection(ranges: [range(1, 5)], newest: range(1, 5))
        let below = try XCTUnwrap(MultiCursor.addCursor(start, in: text, above: false, goalColumn: 1))
        XCTAssertEqual(below.ranges, [range(1, 5), range(9)], "on \"ghi\", not inside the selection on \"def\"")
        let above = try XCTUnwrap(MultiCursor.addCursor(
            MultiCursorSelection(ranges: [range(5, 5)], newest: range(5, 5)), in: text, above: true, goalColumn: 1))
        XCTAssertEqual(above.newest, range(1), "above its start")
    }

    func testLongASCIILinesMapColumnsBothWays() {
        let line = String(repeating: "abc\t", count: 50_000)
        XCTAssertEqual(DisplayColumns.column(ofUTF16Offset: line.utf16.count, in: line, tabWidth: 4), 200_000)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 4_002, in: line, tabWidth: 4), 4_002)
        XCTAssertEqual(DisplayColumns.offset(forColumn: 4_004, in: "日" + line, tabWidth: 4), 4_001,
                       "behind a wide character, through grapheme breaking")
    }

    // MARK: - Editor

    func testCommandDTwiceThenTypingReplacesBothOccurrencesAsOneUndoStep() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = foo + 1\n")
        textView.selectionManager.setSelectedRange(range(5))

        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertEqual(selectedRanges(textView), [range(4, 3), range(10, 3)])

        textView.insertText("barbaz")
        XCTAssertEqual(textView.string, "let barbaz = barbaz + 1\n")
        XCTAssertEqual(selectedRanges(textView), [range(10), range(19)])

        textView.insertText("!")
        XCTAssertEqual(textView.string, "let barbaz! = barbaz! + 1\n")

        textView._undoManager?.undo()
        textView._undoManager?.undo()
        XCTAssertEqual(textView.string, "let foo = foo + 1\n")
    }

    func testSelectAllEscapeAndUndoSelection() throws {
        let (coordinator, textView) = try makeEditor(text: "a b a b a\n")
        textView.selectionManager.setSelectedRange(range(4))

        XCTAssertTrue(coordinator.handle(key("l", [.command, .shift])))
        XCTAssertEqual(selectedRanges(textView), [range(0, 1), range(4, 1), range(8, 1)])

        XCTAssertTrue(coordinator.handle(key("u", .command)), "⌘U returns to the cursor")
        XCTAssertEqual(selectedRanges(textView), [range(4)])

        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertTrue(coordinator.handle(key("k", .command)))
        XCTAssertTrue(coordinator.handle(key("d", .command)), "⌘K ⌘D skips to the next one")
        XCTAssertEqual(selectedRanges(textView), [range(0, 1), range(4, 1)])

        XCTAssertTrue(coordinator.handle(key("\u{1B}", [], code: kVK_Escape)))
        XCTAssertEqual(selectedRanges(textView), [range(0, 1)], "Esc keeps the newest selection")
        XCTAssertFalse(coordinator.handle(key("\u{1B}", [], code: kVK_Escape)), "one selection: Esc passes through")
    }

    func testCommandPaletteRunsCursorCommandsAndFocusesTheEditor() throws {
        let (coordinator, textView) = try makeEditor(text: "a b a b a\n")
        textView.selectionManager.setSelectedRange(range(4))
        textView.window?.makeFirstResponder(nil)
        XCTAssertTrue(coordinator.perform(.selectAllOccurrences))
        XCTAssertTrue(textView.window?.firstResponder === textView, "The editor takes the keyboard")
        XCTAssertEqual(selectedRanges(textView), [range(0, 1), range(4, 1), range(8, 1)])
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4)])
        XCTAssertFalse(coordinator.perform(.undoSelection), "Nothing left to undo")
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView).count, 2)
        XCTAssertFalse(coordinator.perform(.find), "Finding belongs to the document view")
    }

    func testAddCursorBelowThenTypeOnEachLine() throws {
        let (coordinator, textView) = try makeEditor(text: "one\ntwo\nthree\n")
        textView.selectionManager.setSelectedRange(range(0))

        XCTAssertTrue(coordinator.handle(key("", [.command, .option], code: kVK_DownArrow)))
        XCTAssertTrue(coordinator.handle(key("n", [.command, .control])))
        textView.insertText("- ")
        XCTAssertEqual(textView.string, "- one\n- two\n- three\n")
    }

    func testAddCursorBelowUsesTheEditorsTabWidth() throws {
        let (coordinator, textView) = try makeEditor(text: "\tx\n    ab\n")
        textView.selectionManager.setSelectedRange(range(1))
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView), [range(1), range(7)], "a tab of 4 columns, not one")
    }

    func testRepeatedAddCursorBelowKeepsTheDisplayGoalAcrossAShortLine() throws {
        let (coordinator, textView) = try makeEditor(text: "\t\tx\nab\n\t\ty\n")
        textView.selectionManager.setSelectedRange(range(2))
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView), [range(2), range(6)], "clamped to the end of \"ab\"")
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView), [range(2), range(6), range(9)], "column 8 again, after both tabs")
    }

    func testRepeatedAddCursorBelowKeepsTheFirstSelectionsWidth() throws {
        let (coordinator, textView) = try makeEditor(text: "0123456789\nabcde\n0123456789\n")
        textView.selectionManager.setSelectedRange(range(3, 4))
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView), [range(3, 4), range(14, 2), range(20, 4)],
                       "columns 3–7 again after the shorter part on \"abcde\"")

        // Any other change starts a new run from the selection it then adds to.
        textView.selectionManager.setSelectedRange(range(14, 2))
        XCTAssertTrue(coordinator.perform(.addCursorBelow))
        XCTAssertEqual(selectedRanges(textView), [range(14, 2), range(20, 2)])
    }

    func testControlCommandDAddsThePreviousOccurrence() throws {
        let (coordinator, textView) = try makeEditor(text: "a x a x a\n")
        textView.selectionManager.setSelectedRange(range(8))
        XCTAssertTrue(coordinator.handle(key("d", [.command, .control])))
        XCTAssertTrue(coordinator.handle(key("d", [.command, .control])))
        XCTAssertEqual(selectedRanges(textView), [range(4, 1), range(8, 1)])
        XCTAssertTrue(coordinator.handle(key("k", .command)))
        XCTAssertTrue(coordinator.handle(key("d", [.command, .control])), "⌘K ⌃⌘D skips to the one before")
        XCTAssertEqual(selectedRanges(textView), [range(0, 1), range(8, 1)])
        XCTAssertTrue(coordinator.perform(.selectPreviousOccurrence), "from the command palette too")
        XCTAssertEqual(selectedRanges(textView), [range(0, 1), range(4, 1), range(8, 1)])
    }

    func testOptionDragSelectsAColumnBlockThatCommandUUndoesInOneStep() throws {
        let (coordinator, textView) = try makeEditor(text: "abcdef\nab\nabcdef\n")
        textView.selectionManager.setSelectedRange(range(0))
        var event: NSEvent?
        coordinator.currentEvent = { event }

        event = mouse(.leftMouseDown, at: 1, in: textView, timestamp: 1)
        XCTAssertTrue(coordinator.handleMouse(event!))
        XCTAssertEqual(selectedRanges(textView), [range(0), range(1)], "Option-click adds a cursor")

        event = mouse(.leftMouseDragged, at: 1, in: textView, timestamp: 2)
        XCTAssertTrue(coordinator.handleMouse(event!))
        XCTAssertEqual(selectedRanges(textView), [range(0), range(1)], "not yet out of the clicked column")

        event = mouse(.leftMouseDragged, at: 14, in: textView, timestamp: 3)
        XCTAssertTrue(coordinator.handleMouse(event!))
        XCTAssertEqual(selectedRanges(textView), [range(1, 3), range(8, 1), range(11, 3)],
                       "columns 1–4 on each line, to the end of the short one")
        event = mouse(.leftMouseUp, at: 14, in: textView, timestamp: 4)
        XCTAssertTrue(coordinator.handleMouse(event!))

        event = nil
        XCTAssertTrue(coordinator.handle(key("u", .command)))
        XCTAssertEqual(selectedRanges(textView), [range(0)], "the click and its drag are one step")

        let plain = mouse(.leftMouseDown, at: 3, in: textView, flags: [], timestamp: 5)
        XCTAssertFalse(coordinator.handleMouse(plain), "a plain click stays with the editor")
    }

    func testOptionDragGoesOnGrowingWhileTheEditorScrollsUnderAStillMouse() throws {
        let text = Array(repeating: "abcdef", count: 60).joined(separator: "\n") + "\n"
        let (coordinator, textView) = try makeEditor(text: text)
        textView.selectionManager.setSelectedRange(range(0))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDown, at: 1, in: textView, timestamp: 1)))
        let drag = mouse(.leftMouseDragged, at: 5 * 7 + 4, in: textView, timestamp: 2)
        XCTAssertTrue(coordinator.handleMouse(drag))
        XCTAssertEqual(selectedRanges(textView).count, 6, "lines 0–5")

        // No more mouse events arrive while the mouse is held still and the view scrolls under it
        // (here, as by a scroll wheel), yet the block follows the line now under the mouse.
        let lineHeight = try XCTUnwrap(textView.layoutManager.rectForOffset(0)).height
        let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 10 * lineHeight))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
        try waitUntil { self.selectedRanges(textView).count == 16 }
        XCTAssertEqual(selectedRanges(textView).last, range(15 * 7 + 1, 3), "columns 1–4 on line 15")

        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseUp, at: 15 * 7 + 4, in: textView, timestamp: 3)))
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 10 * lineHeight))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(selectedRanges(textView).count, 16, "the mouse-up ends the drag")
    }

    func testCommandUKeepsAClickAndALaterDragApart() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = foo + 1\n")
        textView.selectionManager.setSelectedRange(range(0))
        var event: NSEvent?
        coordinator.currentEvent = { event }

        event = mouse(.leftMouseDown, at: 5, in: textView, flags: [], timestamp: 1)
        textView.selectionManager.setSelectedRange(range(5))
        // A second click on the same spot changes nothing; its drag is a step of its own. The
        // mouse monitor sees the click, which it leaves to the editor.
        event = mouse(.leftMouseDown, at: 5, in: textView, flags: [], timestamp: 2)
        XCTAssertFalse(coordinator.handleMouse(event!))
        textView.selectionManager.setSelectedRange(range(5))
        event = mouse(.leftMouseDragged, at: 8, in: textView, flags: [], timestamp: 3)
        textView.selectionManager.setSelectedRange(range(5, 3))
        event = nil

        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(5)])
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(0)])
    }

    func testCommandUReturnsFromClicksAndRunsOfArrowKeys() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = foo + 1\n")
        textView.selectionManager.setSelectedRange(range(0))
        var event: NSEvent?
        coordinator.currentEvent = { event }

        event = key("", [], code: kVK_RightArrow)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        for _ in 0..<3 { textView.moveRight(nil) }
        XCTAssertEqual(selectedRanges(textView), [range(3)])
        event = mouse(.leftMouseDown, at: 5, in: textView, flags: [], timestamp: 1)
        textView.selectionManager.setSelectedRange(range(5))
        event = mouse(.leftMouseDown, at: 11, in: textView, flags: [], timestamp: 2)
        textView.selectionManager.setSelectedRange(range(11))
        event = nil

        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(5)])
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(3)])
        XCTAssertTrue(coordinator.perform(.undoSelection), "three arrow presses are one step")
        XCTAssertEqual(selectedRanges(textView), [range(0)])
        XCTAssertFalse(coordinator.perform(.undoSelection))

        // A command between arrow runs keeps them apart, and typing forgets everything.
        textView.selectionManager.setSelectedRange(range(5))
        XCTAssertTrue(coordinator.handle(key("d", .command)))
        event = key("", [.shift], code: kVK_RightArrow)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        textView.moveRightAndModifySelection(nil)
        event = nil
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4, 3)])
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(5)])
        event = mouse(.leftMouseDown, at: 2, in: textView, flags: [], timestamp: 3)
        textView.selectionManager.setSelectedRange(range(2))
        event = key("x", [])
        textView.insertText("x")
        XCTAssertFalse(coordinator.perform(.undoSelection), "an edit clears the history")
    }

    func testCommandUHistoryKeepsTheLatestChanges() throws {
        let (coordinator, textView) = try makeEditor(text: "abc\n")
        textView.selectionManager.setSelectedRange(range(0))
        var event: NSEvent?
        coordinator.currentEvent = { event }
        for step in 1...(EditorMultiCursorCoordinator.historyLimit + 20) {
            event = mouse(.leftMouseDown, at: 1, in: textView, flags: [], timestamp: TimeInterval(step))
            textView.selectionManager.setSelectedRange(range(step % 2 + 1))
        }
        event = nil
        var undone = 0
        while coordinator.perform(.undoSelection) { undone += 1 }
        XCTAssertEqual(undone, EditorMultiCursorCoordinator.historyLimit)
    }

    func testCommandUHistoriesKeepTheLatestStepsWithinTheirRangeLimit() throws {
        let (coordinator, textView) = try makeEditor(text: "a a a a a a a a a a\n")
        let matches = (0..<10).map { range($0 * 2, 1) }
        coordinator.historyRangeLimit = 25
        textView.selectionManager.setSelectedRange(range(0))
        textView.selectionManager.setSelectedRange(range(2))       // 2 ranges, before and after
        textView.selectionManager.setSelectedRanges(matches)       // 11
        textView.selectionManager.setSelectedRange(range(4))       // 11
        textView.selectionManager.setSelectedRange(range(6))       // 2: 26 in all, the first goes
        var undone = 0
        while coordinator.perform(.undoSelection) { undone += 1 }
        XCTAssertEqual(undone, 3)
        XCTAssertEqual(selectedRanges(textView), [range(2)])
        var redone = 0
        while coordinator.perform(.redoSelection) { redone += 1 }
        XCTAssertEqual(redone, 3, "⇧⌘U keeps the same steps, 24 ranges")
        XCTAssertEqual(selectedRanges(textView), [range(6)])

        // A single step over the limit is still kept, alone.
        coordinator.historyRangeLimit = 5
        textView.selectionManager.setSelectedRange(range(8))
        textView.selectionManager.setSelectedRanges(matches)
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(8)])
        XCTAssertFalse(coordinator.perform(.undoSelection))
    }

    func testASelectionMadeInCodeAfterArrowKeysIsAStepOfItsOwn() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = foo + 1\n")
        textView.selectionManager.setSelectedRange(range(0))
        // As in the app: AppKit's current event stays the last key handled after it is done.
        let arrow = key("", [], code: kVK_RightArrow)
        coordinator.currentEvent = { arrow }

        XCTAssertFalse(coordinator.handle(arrow), "the key monitor lets it through to the editor")
        for _ in 0..<3 { textView.moveRight(nil) }
        // A later turn of the run loop, once the arrow has been handled.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.selectionManager.setSelectedRange(range(10, 3))

        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(3)], "the change in code is not part of the arrows' run")
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(0)])
        XCTAssertFalse(coordinator.perform(.undoSelection))
    }

    func testCopyingSelectionsPastesOnePieceAtEachCursor() throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let (_, textView) = try makeEditor(text: "alpha beta\n1 2\n")
        textView.selectionManager.setSelectedRanges([range(0, 5), range(6, 4)])
        textView.copy(textView)
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha\nbeta")

        textView.selectionManager.setSelectedRanges([range(12), range(14)])
        textView.paste(textView)
        XCTAssertEqual(textView.string, "alpha beta\n1alpha 2beta\n")

        textView._undoManager?.undo()
        XCTAssertEqual(textView.string, "alpha beta\n1 2\n", "one undo step")

        textView.selectionManager.setSelectedRanges([range(12)])
        textView.paste(textView)
        XCTAssertEqual(textView.string, "alpha beta\n1alpha\nbeta 2\n", "one cursor pastes the joined text")
    }

    func testCommandURecordsSelectAllEmacsKeysAndSelectionsMadeElsewhere() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = 1\nlet bar = 2\nend\n")
        textView.selectionManager.setSelectedRange(range(4))
        var event: NSEvent?
        coordinator.currentEvent = { event }

        event = key("a", .command)
        textView.selectAll(nil)
        XCTAssertEqual(selectedRanges(textView), [range(0, 28)])
        event = key("n", .control)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        textView.moveDown(nil)
        event = key("e", .control)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        textView.moveToEndOfParagraph(nil)
        event = key("", [], code: kVK_LeftArrow)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        textView.moveLeft(nil)
        let afterKeys = selectedRanges(textView)
        XCTAssertNotEqual(afterKeys, [range(0, 28)])
        // A find match or a reveal, set while the editor does not have the keyboard, which it
        // does not report; the next key in the editor records it.
        event = key("g", .command)
        window?.makeFirstResponder(nil)
        textView.selectionManager.setSelectedRange(range(4, 3))
        window?.makeFirstResponder(textView)
        event = nil
        coordinator.syncSelection()
        // And one made in code while the editor has the keyboard.
        textView.selectionManager.setSelectedRange(range(16, 3))

        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4, 3)])
        XCTAssertTrue(coordinator.perform(.undoSelection), "the find match")
        XCTAssertEqual(selectedRanges(textView), afterKeys)
        XCTAssertTrue(coordinator.perform(.undoSelection), "⌃N, ⌃E and ← are one run of navigation keys")
        XCTAssertEqual(selectedRanges(textView), [range(0, 28)])
        XCTAssertTrue(coordinator.perform(.undoSelection), "⌘A")
        XCTAssertEqual(selectedRanges(textView), [range(4)])
        XCTAssertFalse(coordinator.perform(.undoSelection))
    }

    func testRedoSelectionGoesForwardUntilANewChange() throws {
        let (coordinator, textView) = try makeEditor(text: "a b a b a\n")
        textView.selectionManager.setSelectedRange(range(4))
        var event: NSEvent?
        coordinator.currentEvent = { event }

        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertTrue(coordinator.handle(key("d", .command)))
        XCTAssertEqual(selectedRanges(textView), [range(4, 1), range(8, 1)])
        XCTAssertFalse(coordinator.handle(key("u", [.command, .shift])), "nothing to redo yet")

        XCTAssertTrue(coordinator.handle(key("u", .command)))
        XCTAssertTrue(coordinator.handle(key("u", .command)))
        XCTAssertEqual(selectedRanges(textView), [range(4)])
        XCTAssertTrue(coordinator.handle(key("u", [.command, .shift])))
        XCTAssertEqual(selectedRanges(textView), [range(4, 1)])
        XCTAssertTrue(coordinator.perform(.redoSelection), "from the command palette too")
        XCTAssertEqual(selectedRanges(textView), [range(4, 1), range(8, 1)])
        XCTAssertFalse(coordinator.perform(.redoSelection))
        XCTAssertTrue(coordinator.perform(.undoSelection), "redone steps can be undone again")
        XCTAssertEqual(selectedRanges(textView), [range(4, 1)])

        // Arrows after ⌘U start a step of their own rather than extending the one ⌘U returned to.
        event = key("", [], code: kVK_RightArrow)
        XCTAssertFalse(coordinator.handle(event!), "the key monitor lets it through to the editor")
        textView.moveRight(nil)
        event = nil
        XCTAssertFalse(coordinator.perform(.redoSelection), "a new change ends the redo history")
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4, 1)])
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4)])
    }

    func testEditsClearUndoAndRedoAndTheirOwnSelectionChangesAreNotSteps() throws {
        let (coordinator, textView) = try makeEditor(text: "let foo = 1\n")
        textView.selectionManager.setSelectedRange(range(0))
        textView.selectionManager.setSelectedRange(range(4))
        textView.selectionManager.setSelectedRange(range(8))
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(textView), [range(4)])

        textView.insertText("x")
        // Selections set in the same turn as an edit belong to it, as when the editor closes a
        // bracket or composes marked text.
        textView.selectionManager.setSelectedRange(range(2))
        XCTAssertFalse(coordinator.perform(.undoSelection), "an edit clears ⌘U")
        XCTAssertFalse(coordinator.perform(.redoSelection), "and ⇧⌘U")

        textView.setMarkedText("e", selectedRange: range(1), replacementRange: range(NSNotFound))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.setMarkedText("é", selectedRange: range(1), replacementRange: range(NSNotFound))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.insertText("é", replacementRange: range(NSNotFound))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(textView.string, "leét xfoo = 1\n")
        XCTAssertFalse(coordinator.perform(.undoSelection), "composing marked text records nothing")

        // The next key the editor's window gets ends the edit's turn, whether or not it has run out.
        textView.insertText("!")
        XCTAssertFalse(coordinator.handle(key("", [], code: kVK_LeftArrow)), "the arrow is the editor's")
        textView.moveLeft(nil)
        XCTAssertTrue(coordinator.perform(.undoSelection), "changes after the edit are steps again")
        XCTAssertEqual(selectedRanges(textView), [range(4)])
    }

    func testRedoHistoryKeepsTheLatestSteps() throws {
        let (coordinator, textView) = try makeEditor(text: "abc\n")
        textView.selectionManager.setSelectedRange(range(0))
        for step in 1...(EditorMultiCursorCoordinator.historyLimit + 20) {
            textView.selectionManager.setSelectedRange(range(step % 2 + 1))
        }
        var undone = 0
        while coordinator.perform(.undoSelection) { undone += 1 }
        XCTAssertEqual(undone, EditorMultiCursorCoordinator.historyLimit)
        var redone = 0
        while coordinator.perform(.redoSelection) { redone += 1 }
        XCTAssertEqual(redone, EditorMultiCursorCoordinator.historyLimit)
        XCTAssertEqual(selectedRanges(textView), [range((EditorMultiCursorCoordinator.historyLimit + 20) % 2 + 1)])
    }

    func testOptionDragOverWrappedLinesSelectsTheSameColumnsOfEachRowOnScreen() throws {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let (coordinator, textView) = try makeEditor(text: long + "\nab\n" + long + "\n", wrapLines: true, width: 320)
        let rows = displayRows(textView)
        let secondLine = try XCTUnwrap(rows.firstIndex { $0.location == long.utf16.count + 1 })
        XCTAssertGreaterThan(secondLine, 2, "the first line wraps to three rows or more")

        // From column 2 of the first row to column 5 of the first row after "ab".
        textView.selectionManager.setSelectedRange(range(0))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDown, at: 2, in: textView, timestamp: 1)))
        let head = rows[secondLine + 1].location + 5
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDragged, at: head, in: textView, timestamp: 2)))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseUp, at: head, in: textView, timestamp: 3)))

        let expected = rows[...(secondLine + 1)].map { row in
            let start = min(row.location + 2, NSMaxRange(row))
            return range(start, min(row.location + 5, NSMaxRange(row)) - start)
        }
        XCTAssertEqual(selectedRanges(textView), expected, "columns 2–5 of every row, to the end of \"ab\"")
        let lefts = try selectedRanges(textView).map {
            try XCTUnwrap(textView.layoutManager.rectForOffset($0.location)).minX
        }
        XCTAssertEqual(Set(lefts).count, 1, "the block is rectangular on screen")

        XCTAssertTrue(coordinator.perform(.undoSelection), "the drag is one step")
        XCTAssertEqual(selectedRanges(textView), [range(0)])
    }

    func testOptionDragOverWrappedLinesPastTheEndSkipsEmptyLinesAndKeepsTheLastRow() throws {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let text = long + "\n\n" + "abcdefgh"
        let (coordinator, textView) = try makeEditor(text: text, wrapLines: true, width: 320)
        let rows = displayRows(textView)
        textView.selectionManager.setSelectedRange(range(0))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDown, at: 2, in: textView, timestamp: 1)))
        // Below the last line, past its end: the block runs to the last row and its end.
        let last = try XCTUnwrap(textView.layoutManager.rectForOffset(text.utf16.count - 1))
        let below = textView.convert(NSPoint(x: last.maxX + 200, y: last.maxY + 400), to: nil)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: below, modifierFlags: .option,
                                      timestamp: 2, windowNumber: window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertTrue(coordinator.handleMouse(drag))
        XCTAssertTrue(coordinator.handleMouse(NSEvent.mouseEvent(
            with: .leftMouseUp, location: below, modifierFlags: .option, timestamp: 3,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!))
        let selected = selectedRanges(textView)
        let lastRow = try XCTUnwrap(rows.last)
        XCTAssertEqual(lastRow, range(long.utf16.count + 2, 8))
        XCTAssertEqual(selected.last, range(lastRow.location + 2, 6), "the last row from column 2 to its end")
        XCTAssertFalse(selected.contains { $0.location == long.utf16.count + 1 }, "the empty line is too short")
        XCTAssertEqual(selected.count, rows.count - 1, "every row but the empty line")
    }

    func testOptionDragWithoutWrappingFollowsWholeLines() throws {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let (coordinator, textView) = try makeEditor(text: long + "\nabcdefgh\n", width: 320)
        XCTAssertEqual(displayRows(textView).prefix(2), [range(0, long.utf16.count), range(long.utf16.count + 1, 8)])
        textView.selectionManager.setSelectedRange(range(0))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDown, at: 2, in: textView, timestamp: 1)))
        let head = long.utf16.count + 1 + 5
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseDragged, at: head, in: textView, timestamp: 2)))
        XCTAssertTrue(coordinator.handleMouse(mouse(.leftMouseUp, at: head, in: textView, timestamp: 3)))
        XCTAssertEqual(selectedRanges(textView), [range(2, 3), range(long.utf16.count + 3, 3)])
    }

    func testAReplacedEditorStartsAFreshHistoryAndKeepsTheCoordinator() throws {
        // As when a document is reloaded or its Markdown mode changes: the view keeps its
        // coordinator while SwiftUI replaces the editor.
        let model = SwappedEditorModel()
        let coordinator = EditorMultiCursorCoordinator()
        coordinator.currentEvent = { nil }
        let spy = ControllerSpy()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let host = NSHostingView(rootView: SwappedEditor(model: model, theme: theme.editorTheme,
                                                         coordinators: [spy, coordinator])
            .frame(width: 500, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        try waitUntil { spy.controller?.textView.visibleTextRange != nil }
        let first = try XCTUnwrap(spy.controller?.textView)
        window.makeFirstResponder(first)
        first.selectionManager.setSelectedRange(range(0))
        first.selectionManager.setSelectedRange(range(4))
        XCTAssertTrue(coordinator.perform(.undoSelection))
        XCTAssertEqual(selectedRanges(first), [range(0)])

        for split in [true, false] {
            let old = spy.controller
            model.split = split
            try waitUntil { spy.controller != nil && spy.controller !== old }
            let textView = try XCTUnwrap(spy.controller?.textView)
            try waitUntil { textView.window != nil }
            window.makeFirstResponder(textView)
            textView.selectionManager.setSelectedRange(range(4))
            XCTAssertFalse(coordinator.perform(.redoSelection), "nothing to redo in the new editor")
            XCTAssertFalse(coordinator.perform(.undoSelection), "nor to undo")
            XCTAssertTrue(coordinator.perform(.selectNextOccurrence), "the coordinator still runs the new editor")
            XCTAssertEqual(selectedRanges(textView), [range(4, 3)])
        }
    }

    /// The rows the editor shows, wrapped or not, without their line breaks, laying every line out.
    private func displayRows(_ textView: TextView) -> [NSRange] {
        let text = textView.string as NSString
        var rows: [NSRange] = []
        for index in 0..<textView.layoutManager.lineCount {
            guard let line = textView.layoutManager.textLineForIndex(index) else { break }
            _ = textView.layoutManager.rectForOffset(line.range.location)
            let contentsEnd = MultiCursor.contentsEnd(of: line.range, in: text)
            for fragment in line.data.lineFragments {
                let start = line.range.location + fragment.range.location
                // Skip a row of nothing but the line break.
                guard start < contentsEnd || fragment.range.location == 0 else { continue }
                rows.append(NSRange(location: start, length: min(start + fragment.range.length, contentsEnd) - start))
            }
        }
        return rows
    }

    // MARK: - Helpers

    private final class SwappedEditorModel: ObservableObject {
        @Published var split = false
    }

    /// An editor shown alone or beside another view, which SwiftUI builds anew on each change.
    private struct SwappedEditor: View {
        @ObservedObject var model: SwappedEditorModel
        let theme: EditorTheme
        let coordinators: [TextViewCoordinator]

        var body: some View {
            if model.split {
                HSplitView { editor; Text("Preview") }
            } else {
                editor
            }
        }

        private var editor: some View {
            CodeEditSourceEditor(.constant("let foo = 1\nfoo\n"), language: .default, theme: theme,
                                 font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
                                 lineHeight: 1.15, wrapLines: false, cursorPositions: .constant([]),
                                 highlightProviders: [], coordinators: coordinators)
        }
    }

    private func selectedRanges(_ textView: TextView) -> [NSRange] {
        textView.selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: Int? = nil) -> NSEvent {
        let codes: [String: Int] = ["d": kVK_ANSI_D, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "u": kVK_ANSI_U,
                                    "n": kVK_ANSI_N, "p": kVK_ANSI_P,
                                    "a": kVK_ANSI_A, "e": kVK_ANSI_E, "g": kVK_ANSI_G]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: UInt16(code ?? codes[characters] ?? 0))!
    }

    /// A mouse event just right of the left edge of the character at `offset`.
    private func mouse(_ type: NSEvent.EventType, at offset: Int, in textView: TextView,
                       flags: NSEvent.ModifierFlags = .option, timestamp: TimeInterval) -> NSEvent {
        let rect = textView.layoutManager.rectForOffset(offset) ?? .zero
        let point = textView.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: timestamp,
                                  windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    private func makeEditor(text: String, wrapLines: Bool = false,
                            width: CGFloat = 500) throws -> (EditorMultiCursorCoordinator, TextView) {
        let coordinator = EditorMultiCursorCoordinator()
        coordinator.currentEvent = { nil }
        let spy = ControllerSpy()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let editor = CodeEditSourceEditor(
            NSTextStorage(string: text),
            language: .default,
            theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            tabWidth: 4,
            lineHeight: 1.15,
            wrapLines: wrapLines,
            cursorPositions: .constant([]),
            highlightProviders: [],
            coordinators: [spy, coordinator]
        )
        let size = NSSize(width: width, height: 300)
        let host = NSHostingView(rootView: editor.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()

        try waitUntil {
            guard let textView = spy.controller?.textView else { return false }
            return textView.enclosingScrollView != nil && textView.visibleTextRange != nil
        }
        let textView = try XCTUnwrap(spy.controller?.textView)
        window.makeFirstResponder(textView)
        XCTAssertTrue(window.firstResponder === textView)
        return (coordinator, textView)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the editor")
                throw CocoaError(.userCancelled)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

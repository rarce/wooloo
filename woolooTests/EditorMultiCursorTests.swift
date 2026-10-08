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

    // MARK: - Helpers

    private func selectedRanges(_ textView: TextView) -> [NSRange] {
        textView.selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: Int? = nil) -> NSEvent {
        let codes: [String: Int] = ["d": kVK_ANSI_D, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "u": kVK_ANSI_U,
                                    "n": kVK_ANSI_N, "p": kVK_ANSI_P]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: UInt16(code ?? codes[characters] ?? 0))!
    }

    private func makeEditor(text: String) throws -> (EditorMultiCursorCoordinator, TextView) {
        let coordinator = EditorMultiCursorCoordinator()
        let spy = ControllerSpy()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let editor = CodeEditSourceEditor(
            NSTextStorage(string: text),
            language: .default,
            theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            tabWidth: 4,
            lineHeight: 1.15,
            wrapLines: false,
            cursorPositions: .constant([]),
            highlightProviders: [],
            coordinators: [spy, coordinator]
        )
        let size = NSSize(width: 500, height: 300)
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

import XCTest
import SwiftUI
import Carbon.HIToolbox
import CodeEditSourceEditor
import CodeEditTextView
@testable import xherdr

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

    func testAddCursorBelowThenTypeOnEachLine() throws {
        let (coordinator, textView) = try makeEditor(text: "one\ntwo\nthree\n")
        textView.selectionManager.setSelectedRange(range(0))

        XCTAssertTrue(coordinator.handle(key("", [.command, .option], code: kVK_DownArrow)))
        XCTAssertTrue(coordinator.handle(key("n", [.command, .control])))
        textView.insertText("- ")
        XCTAssertEqual(textView.string, "- one\n- two\n- three\n")
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
        let theme = try XCTUnwrap(XherdrTheme.named(XherdrTheme.fallbackID))
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

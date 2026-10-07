import XCTest
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView
@testable import wooloo

/// The document editor's find highlights and replacements, drawn by `EditorRevealCoordinator` on a real
/// CodeEditSourceEditor hosted offscreen.
final class EditorFindHighlightTests: XCTestCase {
    /// Hands the test the controller the editor builds, as `EditorRevealCoordinator` keeps its own private.
    private final class ControllerSpy: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    private struct Highlight {
        let frame: CGRect
        let isCurrent: Bool
    }

    private let matchColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.5, alpha: 1)
    private let currentColor = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1)
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    // MARK: - Drawing

    func testEachVisibleMatchIsHighlightedWithTheCurrentOneInItsColor() throws {
        let text = "let beta = 1\nlet gamma = beta\n"
        let (coordinator, textView) = try makeEditor(text: text)
        let ranges = [NSRange(location: 4, length: 4), NSRange(location: 25, length: 4)]
        XCTAssertEqual((text as NSString).substring(with: ranges[1]), "beta")

        coordinator.setFindMatches(ranges, current: 1, color: matchColor, currentColor: currentColor)

        let drawn = highlights(in: textView)
        XCTAssertEqual(drawn.map(\.isCurrent), [false, true])
        XCTAssertEqual(drawn.map(\.frame), ranges.map { expectedFrame(from: $0.location, to: NSMaxRange($0), in: textView) })
        XCTAssertGreaterThan(drawn[1].frame.minY, drawn[0].frame.minY)
    }

    func testMovingTheCurrentMatchRedrawsInsteadOfStacking() throws {
        let (coordinator, textView) = try makeEditor(text: "beta beta beta\n")
        let ranges = [0, 5, 10].map { NSRange(location: $0, length: 4) }

        coordinator.setFindMatches(ranges, current: 0, color: matchColor, currentColor: currentColor)
        XCTAssertEqual(highlights(in: textView).map(\.isCurrent), [true, false, false])
        coordinator.setFindMatches(ranges, current: 2, color: matchColor, currentColor: currentColor)
        XCTAssertEqual(highlights(in: textView).map(\.isCurrent), [false, false, true])
        coordinator.setFindMatches(ranges, current: nil, color: matchColor, currentColor: currentColor)
        XCTAssertEqual(highlights(in: textView).map(\.isCurrent), [false, false, false])
    }

    func testAMatchSpanningLinesGetsOneRectanglePerLine() throws {
        let text = "let beta = 1\nlet gamma\n"
        let (coordinator, textView) = try makeEditor(text: text)
        // "beta = 1\nlet": from line one into line two.
        let range = NSRange(location: 4, length: 12)

        coordinator.setFindMatches([range], current: nil, color: matchColor, currentColor: currentColor)

        XCTAssertEqual(highlights(in: textView).map(\.frame), [
            expectedFrame(from: 4, to: 12, in: textView),
            expectedFrame(from: 13, to: 16, in: textView),
        ])
    }

    func testEmptyAndOutOfBoundsMatchesAreNotDrawn() throws {
        let text = "beta\nbeta\n"
        let (coordinator, textView) = try makeEditor(text: text)
        let ranges = [
            NSRange(location: 0, length: 4),
            NSRange(location: 5, length: 0),
            // Stale: ends past the text, as after an edit the find bar has not caught up with.
            NSRange(location: 8, length: 10),
        ]

        coordinator.setFindMatches(ranges, current: 2, color: matchColor, currentColor: currentColor)

        XCTAssertEqual(highlights(in: textView).map(\.frame), [expectedFrame(from: 0, to: 4, in: textView)])
    }

    func testClearingTheMatchesRemovesTheHighlights() throws {
        let (coordinator, textView) = try makeEditor(text: "beta beta\n")
        coordinator.setFindMatches([NSRange(location: 0, length: 4), NSRange(location: 5, length: 4)], current: 0,
                                   color: matchColor, currentColor: currentColor)
        XCTAssertEqual(highlights(in: textView).count, 2)

        coordinator.setFindMatches([], current: nil, color: matchColor, currentColor: currentColor)

        XCTAssertTrue(highlights(in: textView).isEmpty)
    }

    func testOnlyMatchesInTheVisibleRangeAreDrawnAndScrollingRedraws() throws {
        let lines = (0..<300).map { "line \($0) match" }
        let text = lines.joined(separator: "\n") + "\n"
        let (coordinator, textView) = try makeEditor(text: text, height: 200)
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var offset = 0
        for line in lines {
            ranges.append(NSRange(location: offset + (line as NSString).length - 5, length: 5))
            offset += (line as NSString).length + 1
        }
        XCTAssertTrue(ranges.allSatisfy { nsText.substring(with: $0) == "match" })
        let last = ranges.count - 1

        coordinator.setFindMatches(ranges, current: last, color: matchColor, currentColor: currentColor)

        let top = highlights(in: textView)
        XCTAssertEqual(top.count, visibleMatchCount(ranges, in: textView))
        XCTAssertGreaterThan(top.count, 0)
        XCTAssertLessThan(top.count, 30)
        XCTAssertFalse(top.contains(where: \.isCurrent))

        // Scrolling to the middle draws the matches there, skipping those above by binary search.
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let middleLine = try XCTUnwrap(textView.layoutManager.rectForOffset(ranges[150].location))
        clipView.scroll(to: NSPoint(x: 0, y: middleLine.minY))
        try waitUntil { self.highlights(in: textView).first?.frame.minY ?? 0 > top.last?.frame.maxY ?? 0 }
        let middle = highlights(in: textView)
        XCTAssertEqual(middle.count, visibleMatchCount(ranges, in: textView))
        let visible = textView.visibleRect
        XCTAssertTrue(middle.allSatisfy { $0.frame.intersects(visible) }, "\(middle.map(\.frame)) outside \(visible)")
        let visibleText = try XCTUnwrap(textView.visibleTextRange)
        let firstVisible = try XCTUnwrap(ranges.firstIndex { NSMaxRange($0) >= visibleText.location })
        XCTAssertEqual(firstVisible, 150, accuracy: 2)
        XCTAssertEqual(middle.first?.frame, expectedFrame(from: ranges[firstVisible].location,
                                                          to: NSMaxRange(ranges[firstVisible]), in: textView))

        // At the end the current match, the last one, comes into view.
        clipView.scroll(to: NSPoint(x: 0, y: textView.frame.height - clipView.bounds.height))
        try waitUntil { self.highlights(in: textView).contains(where: \.isCurrent) }
        let bottom = highlights(in: textView)
        XCTAssertEqual(bottom.count, visibleMatchCount(ranges, in: textView))
        XCTAssertEqual(bottom.last?.isCurrent, true)
        XCTAssertEqual(bottom.last?.frame, expectedFrame(from: ranges[last].location, to: NSMaxRange(ranges[last]), in: textView))
    }

    // MARK: - Editing

    func testReplaceSubstitutesEveryRangeAsOneUndoableEdit() throws {
        let text = "a beta b beta c beta\n"
        let (coordinator, textView) = try makeEditor(text: text)
        let ranges = [2, 9, 16].map { NSRange(location: $0, length: 4) }
        coordinator.setFindMatches(ranges, current: 0, color: matchColor, currentColor: currentColor)
        XCTAssertEqual(highlights(in: textView).count, 3)

        // Given in document order with different lengths: each range refers to the original text.
        coordinator.replace([(ranges[0], "X"), (ranges[1], "YYYYYY"), (ranges[2], "")])

        XCTAssertEqual(textView.string, "a X b YYYYYY c \n")
        // The highlights were for the old text; the find bar sends fresh ones.
        XCTAssertTrue(highlights(in: textView).isEmpty)

        let undo = try XCTUnwrap(textView._undoManager)
        undo.undo()
        XCTAssertEqual(textView.string, text)
        XCTAssertFalse(undo.canUndo)
    }

    func testReplaceDoesNothingInAReadOnlyEditor() throws {
        let text = "a beta b\n"
        let (coordinator, textView) = try makeEditor(text: text, isEditable: false)

        coordinator.replace([(NSRange(location: 2, length: 4), "X")])

        XCTAssertEqual(textView.string, text)
    }

    func testDestroyRemovesTheHighlightsAndDetachesFromTheEditor() throws {
        let lines = (0..<200).map { "match \($0)" }
        let text = lines.joined(separator: "\n")
        let (coordinator, textView) = try makeEditor(text: text, height: 200)
        let ranges = (text as NSString).ranges(of: "match")
        coordinator.setFindMatches(ranges, current: 0, color: matchColor, currentColor: currentColor)
        XCTAssertFalse(highlights(in: textView).isEmpty)

        coordinator.destroy()

        XCTAssertTrue(highlights(in: textView).isEmpty)
        coordinator.setFindMatches(ranges, current: 0, color: matchColor, currentColor: currentColor)
        XCTAssertTrue(highlights(in: textView).isEmpty)
        coordinator.replace([(ranges[0], "X")])
        XCTAssertEqual(textView.string, text)
        // Scrolling no longer redraws.
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        clipView.scroll(to: NSPoint(x: 0, y: 1000))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(highlights(in: textView).isEmpty)
    }

    // MARK: - Helpers

    /// Hosts a CodeEditSourceEditor with a fresh `EditorRevealCoordinator` in an offscreen window.
    private func makeEditor(text: String, isEditable: Bool = true,
                            height: CGFloat = 300) throws -> (EditorRevealCoordinator, TextView) {
        let coordinator = EditorRevealCoordinator()
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
            isEditable: isEditable,
            coordinators: [spy, coordinator]
        )
        let size = NSSize(width: 500, height: height)
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
        XCTAssertEqual(textView.string, text)
        return (coordinator, textView)
    }

    /// The find highlight layers in drawing order, recognized by the test's colors.
    private func highlights(in textView: TextView) -> [Highlight] {
        (textView.layer?.sublayers ?? []).compactMap { layer in
            guard let color = layer.backgroundColor else { return nil }
            if color == matchColor.cgColor { return Highlight(frame: layer.frame, isCurrent: false) }
            if color == currentColor.cgColor { return Highlight(frame: layer.frame, isCurrent: true) }
            return nil
        }
        .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// The rectangle for a single-line stretch of text, as the coordinator should draw it.
    private func expectedFrame(from start: Int, to end: Int, in textView: TextView) -> CGRect {
        guard let lower = textView.layoutManager.rectForOffset(start),
              let upper = textView.layoutManager.rectForOffset(end) else {
            XCTFail("No layout for \(start)..<\(end)")
            return .null
        }
        return CGRect(x: lower.minX, y: lower.minY, width: max(upper.minX - lower.minX, 2), height: lower.height)
    }

    private func visibleMatchCount(_ ranges: [NSRange], in textView: TextView) -> Int {
        guard let visible = textView.visibleTextRange else { return 0 }
        return ranges.filter { NSMaxRange($0) >= visible.location && $0.location <= NSMaxRange(visible) }.count
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

private extension NSString {
    func ranges(of needle: String) -> [NSRange] {
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: length)
        while true {
            let found = range(of: needle, range: search)
            guard found.location != NSNotFound else { return result }
            result.append(found)
            search = NSRange(location: NSMaxRange(found), length: length - NSMaxRange(found))
        }
    }
}

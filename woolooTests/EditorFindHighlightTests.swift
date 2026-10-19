import XCTest
import CryptoKit
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
    private var controller: TextViewController?

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

    // MARK: - Wrapped lines

    /// A line of 60-odd characters per row at the editor's width.
    private let wrappedLine = String(repeating: "word ", count: 60)

    /// The rows the text from `start` to `end` takes on screen, one rectangle each.
    private func rowFrames(from start: Int, to end: Int, in textView: TextView) -> [CGRect] {
        let layout: TextLayoutManager = textView.layoutManager
        var frames: [CGRect] = []
        var row: CGRect?
        for offset in start..<end {
            guard let rect = layout.rectForOffset(offset) else { continue }
            if let current = row, current.minY == rect.minY {
                row = current.union(rect)
            } else {
                if let row { frames.append(row) }
                row = rect
            }
        }
        if let row { frames.append(row) }
        return frames
    }

    func testAMatchAcrossASoftWrapGetsOneRectanglePerRow() throws {
        let (coordinator, textView) = try makeEditor(text: wrappedLine + "\n", wrapLines: true)
        let firstRow = try XCTUnwrap(textView.layoutManager.textLineForIndex(0)?.data.lineFragments.first)
        let rowEnd = firstRow.range.max
        let across = NSRange(location: rowEnd - 4, length: 9)
        let toRowEnd = NSRange(location: rowEnd - 9, length: 9)

        for range in [across, toRowEnd] {
            coordinator.setFindMatches([range], current: 0, color: matchColor, currentColor: currentColor)
            let drawn = highlights(in: textView).map(\.frame)
            let rows = rowFrames(from: range.location, to: NSMaxRange(range), in: textView)
            XCTAssertEqual(drawn.count, rows.count, "\(range)")
            for (frame, row) in zip(drawn, rows) {
                XCTAssertEqual(frame.minX, row.minX, accuracy: 0.5)
                XCTAssertEqual(frame.maxX, row.maxX, accuracy: 0.5, "\(range) covers the whole row")
                XCTAssertEqual(frame.minY, row.minY)
            }
        }
        XCTAssertEqual(highlights(in: textView).count, 1, "a match ending at the row's end stays on its row")
    }

    func testHighlightsFollowTheTextWhenWrappingChanges() throws {
        let text = wrappedLine + "\nbeta\n"
        let (coordinator, textView) = try makeEditor(text: text)
        let beta = (text as NSString).range(of: "beta")
        coordinator.setFindMatches([beta], current: 0, color: matchColor, currentColor: currentColor)
        let unwrapped = try XCTUnwrap(highlights(in: textView).first?.frame)

        try XCTUnwrap(controller).wrapLines = true
        try waitUntil { (self.highlights(in: textView).first?.frame.minY ?? 0) > unwrapped.minY }
        // Redrawn once the lines are laid out where they now go, which can take more than one turn.
        try waitUntil {
            self.highlights(in: textView).map(\.frame)
                == [self.expectedFrame(from: beta.location, to: NSMaxRange(beta), in: textView)]
        }
        XCTAssertEqual(highlights(in: textView).map(\.frame), [expectedFrame(from: beta.location, to: NSMaxRange(beta),
                                                                            in: textView)])

        try XCTUnwrap(controller).wrapLines = false
        try waitUntil { self.highlights(in: textView).first?.frame.minY == unwrapped.minY }
        XCTAssertEqual(highlights(in: textView).map(\.frame), [unwrapped])
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
        try settle(0.1)
        XCTAssertTrue(highlights(in: textView).isEmpty)
    }

    // MARK: - Helpers

    /// Hosts a CodeEditSourceEditor with a fresh `EditorRevealCoordinator` in an offscreen window.
    private func makeEditor(text: String, isEditable: Bool = true, wrapLines: Bool = false,
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
            wrapLines: wrapLines,
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
        controller = spy.controller
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

    /// Runs the run loop for `time`, then until the work queued on the main queue by then has run, such as a
    /// redraw after the text rewrapped: a run for a fixed time can end before it gets there.
    private func settle(_ time: TimeInterval = 0.05) throws {
        RunLoop.main.run(until: Date().addingTimeInterval(time))
        var done = false
        DispatchQueue.main.async { done = true }
        try waitUntil { done }
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

/// Opt-in Release measurements of the native source editor and its search/indexing paths.
/// No syntax provider is installed: these timings isolate text layout, editing and Find.
extension EditorFindHighlightTests {
    @MainActor
    func testEditorPerformance() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WOOLOO_BENCH_EDITOR"] == "1" else { throw XCTSkip("Run scripts/editor-bench.sh") }
        let output = try XCTUnwrap(environment["WOOLOO_BENCH_OUT"])
        let repetitions = max(1, Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 5)
        func report(_ record: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data + Data([10]))
        }
        try report(["config": ["width": 500, "height": 600, "resize_width": 380, "base_font": 13,
                                "scrollbars": Int(NSScroller.preferredScrollerStyle.rawValue), "code_font": 13, "theme": WoolooTheme.fallbackID,
                                "renderer": "CodeEditSourceEditor-plain", "capture": "AppKit-cacheDisplay-v1",
                                "repeat": repetitions]])
        var samples: [String: [Double]] = [:]
        func time(_ name: String, _ body: () throws -> Void) rethrows {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples[name, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let source = (0..<20_000).map { "let value\($0) = \($0) // café 👩🏽‍💻\n" }.joined()
        let longLine = String(repeating: "value123 ", count: 240_000)
        let paths = (0..<100_000).map { "src/module\($0 % 100)/ContentView\($0).swift" }
        let index = QuickOpenIndex(paths)
        let searchText = Data(("1000\n" + (0..<1000).map { "src/f\($0).swift\u{0}1\u{0}let value = 1\n" }.joined()).utf8)
        let expression = try WorkspaceSearch.expression(for: .init(query: "value"))
        let inputs = ["source-20000-lines": Data(source.utf8), "long-line-2mb": Data(longLine.utf8),
                      "quick-open-100000": Data(paths.joined(separator: "\n").utf8), "project-search-1000": searchText]
        let digests = inputs.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        for _ in 0..<repetitions {
            for (name, text, wraps) in [("source-20000-lines", source, false), ("long-line-2mb", longLine, true)] {
                let spy = ControllerSpy()
                let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
                var host: NSHostingView<AnyView>!
                var window: NSWindow!
                func draw() throws {
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                try time(name + "/first-render") {
                    let editor = CodeEditSourceEditor(NSTextStorage(string: text), language: .default,
                        theme: theme.editorTheme, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                        tabWidth: 4, lineHeight: 1.15, wrapLines: wraps, cursorPositions: .constant([]),
                        highlightProviders: [], isEditable: true, coordinators: [spy])
                    host = NSHostingView(rootView: AnyView(editor.frame(maxWidth: .infinity, maxHeight: .infinity)))
                    host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
                    window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try waitUntil { spy.controller?.textView?.visibleTextRange != nil }
                    try draw()
                }
                defer { window.close() }
                let view = try XCTUnwrap(spy.controller?.textView)
                XCTAssertEqual(view.string, text)
                try time(name + "/resize") {
                    window.setContentSize(NSSize(width: 380, height: 600))
                    try draw()
                }
                XCTAssertEqual(host.bounds.width, 380, accuracy: 1)
                try time(name + "/insert") {
                    view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
                    try draw()
                }
                XCTAssertEqual(view.string, "x" + text)
                let find = DocumentFindModel()
                find.open(replace: false, query: "value")
                time(name + "/find") { find.update(text: view.string, target: .source, anchor: nil) }
                XCTAssertEqual(find.count, DocumentFindModel.maximumMatches)
            }
            var builtIndex: QuickOpenIndex?
            time("quick-open-100000/index") { builtIndex = QuickOpenIndex(paths) }
            XCTAssertEqual(builtIndex?.paths.count, paths.count)
            time("quick-open-100000/match") {
                let matches = QuickOpenMatcher.match(QuickOpenQuery("ContentView999"), in: index, recents: [])
                XCTAssertFalse(matches?.isEmpty ?? true)
                XCTAssertTrue(matches?.contains(where: { $0.path.hasSuffix("ContentView999.swift") }) ?? false)
            }
            time("project-search-1000/parse") {
                let result = WorkspaceSearch.parse(searchText, expression: expression)
                XCTAssertEqual(result.matchCount, 1000)
                XCTAssertEqual(result.files.count, 1000)
            }
        }
        for (key, times) in samples.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/").map(String.init)
            let sorted = times.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
            try report(["style": "Source", "scenario": parts[0], "stage": parts[1], "n": sorted.count,
                        "sha256": digests[parts[0]]!, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
                        "max_ms": sorted.last!])
        }
    }
}

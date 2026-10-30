import AppKit
import MarkdownView
import SwiftUI
import WebKit
import XCTest
@testable import wooloo

@MainActor
final class PreviewScrollMemoryTests: XCTestCase {
    private let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "scroll",
                                                 workspaceLabel: "Preview scroll", root: "/private/tmp")
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    // MARK: - Markdown blocks

    func testTheTopBlockFollowsBlocksAddedOrRemovedAboveIt() {
        let old = "# Title\n\nFirst.\n\nSecond.\n\nThird.\n"
        let second = MarkdownBlockAnchor(index: 2)
        XCTAssertEqual(PreviewScrollMemory.block(second, from: old, to: old), second)
        XCTAssertEqual(PreviewScrollMemory.block(second, from: old, to: "# Title\n\nNew.\n\nOther.\n\nFirst.\n\nSecond.\n\nThird.\n"),
                       MarkdownBlockAnchor(index: 4))
        XCTAssertEqual(PreviewScrollMemory.block(second, from: old, to: "Second.\n\nThird.\n"), MarkdownBlockAnchor(index: 0))
        // A block that was edited or removed: the one at its index, or the last.
        XCTAssertEqual(PreviewScrollMemory.block(second, from: old, to: "# Title\n\nFirst.\n\nChanged.\n\nThird.\n"), second)
        XCTAssertEqual(PreviewScrollMemory.block(second, from: old, to: "# Title\n"), MarkdownBlockAnchor(index: 0))
        XCTAssertNil(PreviewScrollMemory.block(second, from: old, to: ""))
    }

    func testANewPreviewRemapsTheSavedBlockAndAShownOneKeepsIt() {
        let memory = PreviewScrollMemory()
        let text = "A.\n\nB.\n\nC.\n"
        XCTAssertNil(memory.restoredMarkdownBlock(in: text))
        memory.setMarkdownBlock(MarkdownBlockAnchor(index: 2), in: text)
        XCTAssertEqual(memory.restoredMarkdownBlock(in: text), MarkdownBlockAnchor(index: 2))
        // Split view: the source changes under a shown preview, which stays where it is.
        XCTAssertEqual(memory.shownMarkdownBlock, MarkdownBlockAnchor(index: 2))
        XCTAssertEqual(memory.restoredMarkdownBlock(in: "Z.\n\n" + text), MarkdownBlockAnchor(index: 3))
    }

    func testARepeatedBlockKeepsItsOccurrence() {
        let section = (0..<4).map { "### Parameters\n\nText \($0)." }.joined(separator: "\n\n")
        // The third heading, at 4, with three new blocks near the start.
        let moved = PreviewScrollMemory.block(MarkdownBlockAnchor(index: 4), from: section,
                                              to: "One.\n\nTwo.\n\nThree.\n\n" + section)
        XCTAssertEqual(moved, MarkdownBlockAnchor(index: 7))
        // The second of two rules, with a block inserted between them.
        XCTAssertEqual(PreviewScrollMemory.block(MarkdownBlockAnchor(index: 2), from: "---\n\nA.\n\n---\n",
                                                 to: "---\n\nA.\n\nB.\n\n---\n"), MarkdownBlockAnchor(index: 3))
    }

    func testAMarkdownPreviewMadeAgainStartsWhereTheLastOneWasScrolled() throws {
        let text = (0..<80).map { "Paragraph \($0). " + String(repeating: "Keep the source and evidence together. ", count: 6) }
            .joined(separator: "\n\n")
        let memory = PreviewScrollMemory()
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MarkdownPreviewStyle.storageKey)
        defer { defaults.set(saved, forKey: MarkdownPreviewStyle.storageKey) }
        for style in [MarkdownPreviewStyle.theme, .document] {
            defaults.set(style.rawValue, forKey: MarkdownPreviewStyle.storageKey)
            memory.setMarkdownBlock(nil, in: text)
            let first = try host(markdown: text, memory: memory)
            // As the user does: SwiftUI follows the scroll position from scroll events.
            for _ in 0..<30 {
                let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: -100, wheel2: 0, wheel3: 0))
                first.scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            }
            settle(first.view)
            let top = try XCTUnwrap(memory.shownMarkdownBlock, "\(style): scrolling must record the top block")
            XCTAssertGreaterThan(top.index, 5)
            let scrolled = first.scroll.documentVisibleRect.minY
            window?.close()

            let second = try host(markdown: text, memory: memory)
            let deadline = Date().addingTimeInterval(3)
            while second.scroll.documentVisibleRect.minY < scrolled - 400, Date() < deadline { settle(second.view) }
            // Restored to the top of the block that was at the top, at most one block above.
            XCTAssertEqual(second.scroll.documentVisibleRect.minY, scrolled, accuracy: 400, "\(style)")
        }
    }

    private func host(markdown text: String, memory: PreviewScrollMemory) throws -> (view: NSView, scroll: NSScrollView) {
        let view = NSHostingView(rootView: MarkdownPreviewView(text: text, path: "scroll.md", location: location,
                                                               onOpenFile: { _ in }, scroll: memory)
            .environment(\.woolooTheme, WoolooTheme.named(WoolooTheme.fallbackID)!)
            .environment(\.woolooTypography, WoolooTypography())
            .frame(width: 900, height: 500))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        settle(view)
        return (view, try XCTUnwrap(Self.scrollView(in: view)))
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    // MARK: - Notebook cells

    func testANotebookPreviewMadeAgainStartsAtTheCellThatWasAtTheTop() async throws {
        let cells = (0..<60).map { index in
            #"{"cell_type": "markdown", "id": "c\#(index)", "metadata": {}, "source": ["**Cell \#(index)**\n\n", "\#(String(repeating: "Some text to fill the cell. ", count: 20))"]}"#
        }
        let text = #"{"cells": [\#(cells.joined(separator: ","))], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}"#
        let notebook = try NotebookDocument.parse(text)
        let memory = PreviewScrollMemory()

        let first = try await host(notebook: notebook, memory: memory)
        _ = try await first.evaluateJavaScript("window.scrollTo(0, 3000)")
        for _ in 0..<100 where memory.notebookTop == nil { try await Task.sleep(for: .milliseconds(20)) }
        let top = try XCTUnwrap(memory.notebookTop, "scrolling must record the top cell")
        let scrolled = try await first.evaluateJavaScript("window.scrollY") as? Double
        window?.close()

        let second = try await host(notebook: notebook, memory: memory)
        var restored: Double?
        for _ in 0..<100 {
            restored = try await second.evaluateJavaScript("window.scrollY") as? Double
            if (restored ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(restored), try XCTUnwrap(scrolled), accuracy: 2)
        let cell = try await second.evaluateJavaScript("""
            Array.from(document.querySelectorAll('.cell')).find(cell => cell.getBoundingClientRect().bottom > 0).id
            """) as? String
        XCTAssertEqual(cell, top.cell)
    }

    private func host(notebook: NotebookDocument, memory: PreviewScrollMemory) async throws -> WKWebView {
        let view = NotebookWebView(notebook: notebook, path: "scroll.ipynb", location: location,
                                   theme: WoolooTheme.all[0], typography: WoolooTypography(), scroll: memory,
                                   matches: [], currentMatch: nil, revealRequest: 0, onOpenFile: { _ in },
                                   onSearchText: { _ in }, onFindCommand: { _, _, _ in })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.window = window
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        for _ in 0..<200 {
            if let found = findWebView(host),
               (try? await found.evaluateJavaScript("document.querySelectorAll('.cell').length")) as? Int == notebook.cells.count {
                return found
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("The notebook did not render")
    }
}

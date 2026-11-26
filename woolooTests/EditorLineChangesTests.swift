import XCTest
import SwiftUI
import CodeEditSourceEditor
@testable import wooloo

/// The editor's Git change bars: line hunks against the index, and staged hunks against HEAD.
final class EditorLineChangesTests: XCTestCase {
    private typealias Change = GutterView.LineChange

    private final class ControllerSpy: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    func testRecreatedSplitEditorRestoresCachedGutterColorsAndChanges() throws {
        let coordinator = EditorLineChangeCoordinator()
        let spy = ControllerSpy()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let colors = (added: NSColor.systemGreen, modified: NSColor.systemOrange, deleted: NSColor.systemRed)
        coordinator.setColors(added: colors.added, modified: colors.modified, deleted: colors.deleted)
        coordinator.setBases(head: "original\n", index: "original\n")
        let sourceEditor = CodeEditSourceEditor(
            .constant("changed\n"), language: .markdown, theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.15, wrapLines: false, cursorPositions: .constant([]),
            coordinators: [spy, coordinator]
        )
        let editor = HStack(spacing: 0) {
            sourceEditor
            EditorGitOverview(coordinator: coordinator).frame(width: 10)
        }
        let size = NSSize(width: 700, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        // Source -> Preview -> Split recreates the controller with the same coordinator.
        let source = NSHostingView(rootView: editor.frame(width: size.width, height: size.height))
        source.frame = NSRect(origin: .zero, size: size)
        window.contentView = source
        source.layoutSubtreeIfNeeded()
        XCTAssertNotNil(spy.controller?.gutterView)
        window.contentView = NSView(frame: source.frame)
        coordinator.destroy()

        let split = NSHostingView(rootView: HSplitView {
            editor.frame(minWidth: 200)
            Text("Preview").frame(minWidth: 200)
        }.frame(width: size.width, height: size.height))
        split.frame = NSRect(origin: .zero, size: size)
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        let controller = try XCTUnwrap(spy.controller)
        let gutter = try XCTUnwrap(controller.gutterView)
        XCTAssertEqual(controller.textView.string, "changed\n")

        let expected = [Change(line: 0, count: 1, kind: .modified, isStaged: false)]
        let deadline = Date().addingTimeInterval(5)
        while gutter.lineChanges != expected && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(gutter.lineChanges, expected)
        let overview = try XCTUnwrap(coordinator.overview)
        XCTAssertTrue(overview.textView === controller.textView)
        XCTAssertEqual(overview.changes, expected)
        XCTAssertEqual(overview.colors.modified, colors.modified)
        XCTAssertEqual(gutter.lineChangeColors.added, colors.added)
        XCTAssertEqual(gutter.lineChangeColors.modified, colors.modified)
        XCTAssertEqual(gutter.lineChangeColors.deleted, colors.deleted)
        withExtendedLifetime([spy, coordinator] as [any TextViewCoordinator]) {}
    }

    @MainActor
    func testInlineBlameFollowsTheCaretAndSitsAfterTheLastWrappedFragment() async throws {
        let spy = ControllerSpy()
        let coordinator = EditorGitBlameCoordinator()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let longLine = String(repeating: "word ", count: 13) + "end"
        let text = "short\n\(longLine)\n"
        let first = WorkspaceCommit(id: "first-sha", shortHash: "first", subject: "First change",
                                    author: "Alice", date: Date(timeIntervalSince1970: 1_700_000_000))
        let second = WorkspaceCommit(id: "second-sha", shortHash: "second", subject: "Second change",
                                     author: "Bob", date: first.date)
        coordinator.setBlame(EditorGitBlame(text: ["short\n", longLine + "\n"], commits: [first, second]))
        var cursors = [CursorPosition(line: 1, column: 1)]
        let editor = CodeEditSourceEditor(
            .constant(text), language: .markdown, theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.15, wrapLines: true,
            cursorPositions: Binding(get: { cursors }, set: { cursors = $0 }),
            coordinators: [spy, coordinator]
        )
        let size = NSSize(width: 420, height: 240)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let controller = try XCTUnwrap(spy.controller)

        @MainActor
        func waitForAnnotation(containing author: String) async throws -> NSTextField {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if let field = controller.textView.subviews.compactMap({ $0 as? NSTextField }).first(where: {
                    !$0.isHidden && $0.stringValue.contains(author)
                }) { return field }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            throw BlameTestError.noAnnotation(author)
        }
        XCTAssertTrue(window.makeFirstResponder(controller.textView))
        controller.setCursorPositions([CursorPosition(line: 1, column: 1)])
        let firstAnnotation = try await waitForAnnotation(containing: "Alice")
        XCTAssertTrue(firstAnnotation.toolTip?.contains("first-sha") == true)

        controller.setCursorPositions([CursorPosition(line: 2, column: 1)])
        let row = try XCTUnwrap(controller.textView.layoutManager.textLineForIndex(1))
        let last = try XCTUnwrap(row.data.lineFragments.last)
        XCTAssertGreaterThan(last.yPos, 0)
        XCTAssertEqual(controller.textView.selectionManager.textSelections.first?.range.location, row.range.location)
        let secondAnnotation = try await waitForAnnotation(containing: "Bob")
        XCTAssertGreaterThan(secondAnnotation.frame.minX, last.data.width)
        XCTAssertEqual(secondAnnotation.frame.midY, row.yPos + last.yPos + last.height / 2, accuracy: 1)
        XCTAssertEqual(controller.textView.string, text)

        controller.setCursorPositions([CursorPosition(line: 3, column: 1)])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(secondAnnotation.isHidden, "The virtual end-of-file line has no attribution")
    }

    private enum BlameTestError: Error {
        case noAnnotation(String)
    }

    func testOverviewKeepsSmallChangesAndEOFDeletionsVisible() {
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 300)
        let middle = EditorGitOverviewView.markerRect(top: 500, bottom: 501,
                                                      documentHeight: 1_000, bounds: bounds)
        XCTAssertEqual(middle.minY, 150)
        XCTAssertEqual(middle.height, 3)
        let deletion = EditorGitOverviewView.markerRect(top: 1_000, bottom: 1_000,
                                                        documentHeight: 1_000, bounds: bounds)
        XCTAssertEqual(deletion.maxY, bounds.maxY)
        XCTAssertEqual(deletion.height, 3)
        XCTAssertEqual(EditorGitOverviewView.markerRect(top: 0, bottom: 1,
            documentHeight: 1, bounds: .zero), .zero)
    }

    func testOverviewNavigatesWrappedChangesWithoutMovingSelection() throws {
        let spy = ControllerSpy()
        let theme = try XCTUnwrap(WoolooTheme.named(WoolooTheme.fallbackID))
        let text = (0..<200).map { "line \($0) " + String(repeating: "wrapped content ", count: 8) }
            .joined(separator: "\n")
        let editor = CodeEditSourceEditor(
            .constant(text), language: .markdown, theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.15, wrapLines: true, cursorPositions: .constant([]), coordinators: [spy]
        )
        let size = NSSize(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(spy.controller?.textView)
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let overview = EditorGitOverviewView(frame: CGRect(x: 0, y: 0, width: 10, height: 300))
        overview.textView = textView
        overview.changes = [.init(line: 150, count: 1, kind: .modified, isStaged: false),
                            .init(line: 200, count: 0, kind: .deleted, isStaged: true)]
        let selections = textView.selectionManager.textSelections.map(\.range)
        let target = try XCTUnwrap(textView.layoutManager.textLineForIndex(150)).range.location
        let marker = try XCTUnwrap(overview.markers().first)
        overview.revealMarker(at: CGPoint(x: marker.rect.midX, y: marker.rect.midY))
        let targetRect = try XCTUnwrap(textView.layoutManager.rectForOffset(target))
        XCTAssertTrue(scroll.documentVisibleRect.intersects(targetRect))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), selections)
        let eofMarker = try XCTUnwrap(overview.markers().last)
        overview.revealMarker(at: CGPoint(x: eofMarker.rect.midX, y: eofMarker.rect.midY))
        let eofRect = try XCTUnwrap(textView.layoutManager.rectForOffset(textView.length))
        XCTAssertTrue(scroll.documentVisibleRect.intersects(eofRect))
        XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), selections)
        overview.changes = []
        XCTAssertTrue(overview.markers().isEmpty)
    }

    func testIdenticalTextHasNoChanges() {
        XCTAssertEqual(EditorLineChanges.hunks(from: "a\nb\n", to: "a\nb\n"), [])
    }

    func testAddedModifiedAndDeletedLines() {
        let base = "a\nb\nc\nd\ne\n"
        XCTAssertEqual(EditorLineChanges.hunks(from: base, to: "a\nb\nx\ny\nc\nd\ne\n"),
                       [Change(line: 2, count: 2, kind: .added, isStaged: false)])
        XCTAssertEqual(EditorLineChanges.hunks(from: base, to: "a\nB\nc\nd\ne\n"),
                       [Change(line: 1, count: 1, kind: .modified, isStaged: false)])
        XCTAssertEqual(EditorLineChanges.hunks(from: base, to: "a\nd\ne\n"),
                       [Change(line: 1, count: 0, kind: .deleted, isStaged: false)])
        XCTAssertEqual(EditorLineChanges.hunks(from: base, to: "A\nb\nc\ne\nf\n"), [
            Change(line: 0, count: 1, kind: .modified, isStaged: false),
            Change(line: 3, count: 0, kind: .deleted, isStaged: false),
            Change(line: 4, count: 1, kind: .added, isStaged: false),
        ])
    }

    func testDeletionAtTheEndOfTextWithoutTrailingNewline() {
        XCTAssertEqual(EditorLineChanges.hunks(from: "a\nb", to: "a"),
                       [Change(line: 1, count: 0, kind: .deleted, isStaged: false)])
    }

    func testTooManyDifferencesMarkTheChangedMiddleAsOneHunk() {
        let count = EditorLineChanges.maximumEditDistance
        let base = (0..<count).map { "old \($0)" }.joined(separator: "\n")
        let text = (0..<count).map { "new \($0)" }.joined(separator: "\n")
        XCTAssertEqual(EditorLineChanges.hunks(from: "top\n" + base + "\nend", to: "top\n" + text + "\nend"),
                       [Change(line: 1, count: count, kind: .modified, isStaged: false)])
    }

    func testUntrackedFilesHaveNoBars() {
        XCTAssertEqual(EditorLineChanges.changes(text: "a\n", head: nil, index: nil), [])
    }

    func testStagedHunksAreMarked() {
        // Line b is staged; line d is changed only in the editor.
        let head = "a\nb\nc\nd\n", index = "a\nB\nc\nd\n", text = "a\nB\nc\nD\n"
        XCTAssertEqual(EditorLineChanges.changes(text: text, head: head, index: index), [
            Change(line: 1, count: 1, kind: .modified, isStaged: true),
            Change(line: 3, count: 1, kind: .modified, isStaged: false),
        ])
        // A staged change reverted in the editor differs from the index but not from HEAD.
        XCTAssertEqual(EditorLineChanges.changes(text: head, head: head, index: index),
                       [Change(line: 1, count: 1, kind: .modified, isStaged: false)])
        // A new file added to the index is all staged.
        XCTAssertEqual(EditorLineChanges.changes(text: "a\n", head: nil, index: "a\n"),
                       [Change(line: 0, count: 1, kind: .added, isStaged: true)])
    }

    func testGitBasesReadHeadAndIndex() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let location = try sandbox.repository("repo", files: ["dir/a.txt": "one\n"])
        XCTAssertTrue(WorkspaceFiles.gitBases("dir/a.txt", at: location) == ("one\n", "one\n"))
        try sandbox.write(["dir/a.txt": "two\n", "new.txt": "new\n"], in: "repo")
        try sandbox.sh("git add dir/a.txt", in: "repo")
        XCTAssertTrue(WorkspaceFiles.gitBases("dir/a.txt", at: location) == ("one\n", "two\n"))
        XCTAssertTrue(WorkspaceFiles.gitBases("new.txt", at: location) == (nil, nil))
        try sandbox.sh("git add new.txt", in: "repo")
        XCTAssertTrue(WorkspaceFiles.gitBases("new.txt", at: location) == (nil, "new\n"))
    }

    func testWatcherReportsStagingAndCommits() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let location = try sandbox.repository("repo")
        let directory = try XCTUnwrap(WorkspaceFiles.localGitDirectory(at: location))
        XCTAssertTrue(directory.hasSuffix("/.git"))
        var changes = 0
        let watcher = try XCTUnwrap(GitDirectoryWatcher(directory: directory) { changes += 1 })
        try sandbox.write(["a.txt": "two\n"], in: "repo")
        try sandbox.sh("git add a.txt", in: "repo")
        let staged = expectation(description: "staged")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { staged.fulfill() }
        wait(for: [staged], timeout: 2)
        XCTAssertEqual(changes, 1, "a burst of writes is reported once")
        try sandbox.sh("git commit -q -m Two", in: "repo")
        let committed = expectation(description: "committed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { committed.fulfill() }
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(changes, 2)
        withExtendedLifetime(watcher) {}
        XCTAssertNil(WorkspaceFiles.localGitDirectory(at: sandbox.location("missing")))
    }
}

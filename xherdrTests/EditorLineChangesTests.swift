import XCTest
import SwiftUI
import CodeEditSourceEditor
@testable import xherdr

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
        let theme = try XCTUnwrap(XherdrTheme.named(XherdrTheme.fallbackID))
        let colors = (added: NSColor.systemGreen, modified: NSColor.systemOrange, deleted: NSColor.systemRed)
        coordinator.setColors(added: colors.added, modified: colors.modified, deleted: colors.deleted)
        coordinator.setBases(head: "original\n", index: "original\n")
        let editor = CodeEditSourceEditor(
            .constant("changed\n"), language: .markdown, theme: theme.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.15, wrapLines: false, cursorPositions: .constant([]),
            coordinators: [spy, coordinator]
        )
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
        XCTAssertEqual(gutter.lineChangeColors.added, colors.added)
        XCTAssertEqual(gutter.lineChangeColors.modified, colors.modified)
        XCTAssertEqual(gutter.lineChangeColors.deleted, colors.deleted)
        withExtendedLifetime([spy, coordinator] as [any TextViewCoordinator]) {}
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

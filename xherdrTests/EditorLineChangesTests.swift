import XCTest
import CodeEditSourceEditor
@testable import xherdr

/// The editor's Git change bars: line hunks against the index, and staged hunks against HEAD.
final class EditorLineChangesTests: XCTestCase {
    private typealias Change = GutterView.LineChange

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

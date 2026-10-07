import XCTest
@testable import wooloo

/// The Search tab's state: searching as the query changes, match navigation and replace,
/// against a disposable repository.
@MainActor
final class WorkspaceSearchModelTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var model: WorkspaceSearchModel!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: [
            "a.txt": "foo one foo\nbar\n",
            "b.txt": "foo two\n",
        ])
        model = WorkspaceSearchModel()
    }

    override func tearDown() async throws {
        sandbox.tearDown()
    }

    /// Waits until no search or replace is running.
    private func settle() async {
        for _ in 0..<500 where model.isSearching || model.isReplacing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isSearching || model.isReplacing, "The search did not finish")
    }

    private func search(_ query: String) async {
        model.options.query = query
        if model.location == nil { model.setLocation(repo) } else { model.search(debounce: false) }
        await settle()
    }

    func testSearchListsEveryOccurrenceInOrder() async {
        await search("foo")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.result?.matchCount, 3)
        XCTAssertEqual(model.matches, [
            WorkspaceSearchMatchRef(path: "a.txt", line: 1, occurrence: 0),
            WorkspaceSearchMatchRef(path: "a.txt", line: 1, occurrence: 1),
            WorkspaceSearchMatchRef(path: "b.txt", line: 1, occurrence: 0),
        ])
        XCTAssertEqual(model.title, "foo")
    }

    func testMoveWrapsAroundTheMatches() async {
        await search("foo")
        model.move(-1)
        XCTAssertEqual(model.activeMatch, 2)
        model.move(1)
        XCTAssertEqual(model.activeMatch, 0)
    }

    /// A narrower search keeps the active match inside the new list.
    func testActiveMatchIsClampedToNewResults() async {
        await search("foo")
        model.activeMatch = 2
        await search("two")
        XCTAssertEqual(model.matches.count, 1)
        XCTAssertEqual(model.activeMatch, 0)
    }

    func testEmptyQueryOrNoSpaceClearsResults() async {
        await search("foo")
        await search("")
        XCTAssertNil(model.result)
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertEqual(model.title, "Project Search")

        await search("foo")
        model.setLocation(nil)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isSearching)
    }

    func testInvalidPatternIsReportedWithoutSearching() async {
        model.options.regex = true
        model.options.query = "("
        model.setLocation(repo)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.matches.isEmpty)
    }

    /// While typing, only the last query is searched and shown.
    func testDebouncedSearchKeepsOnlyTheLatestQuery() async {
        await search("foo")
        model.options.query = "fo"
        model.search(debounce: true)
        model.options.query = "bar"
        model.search(debounce: true)
        await settle()
        XCTAssertEqual(model.matches, [WorkspaceSearchMatchRef(path: "a.txt", line: 2, occurrence: 0)])
    }

    /// Replace Next changes only the active occurrence, reports the written file and searches again.
    func testReplaceNextChangesOnlyTheActiveMatch() async throws {
        var modified: [String] = []
        model.didModifyFiles = { _, files in modified += files }
        await search("foo")
        model.replacement = "baz"
        model.activeMatch = 1
        model.replaceNext()
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "foo one baz\nbar\n")
        XCTAssertEqual(try sandbox.read("b.txt", in: "repo"), "foo two\n")
        XCTAssertEqual(modified, ["a.txt"])
        XCTAssertEqual(model.status, "Replaced 1 match in 1 file")
        XCTAssertEqual(model.matches.count, 2)
    }

    /// Files with unsaved edits in an open document are never written.
    func testReplaceSkipsFilesWithUnsavedEdits() async throws {
        model.hasUnsavedEdits = { _, path in path == "b.txt" }
        await search("foo")
        model.replacement = "baz"
        model.replaceAll()
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "baz one baz\nbar\n")
        XCTAssertEqual(try sandbox.read("b.txt", in: "repo"), "foo two\n")
        XCTAssertEqual(model.status, "Replaced 2 matches in 1 file · skipped 1 with unsaved edits")

        model.activeMatch = 0
        model.replaceNext()
        XCTAssertEqual(model.status, "b.txt has unsaved edits; save or close it first")
        XCTAssertFalse(model.isReplacing)
    }

    func testReplaceReportsFilesThatChangedSinceTheSearch() async throws {
        await search("foo")
        try sandbox.sh("rm b.txt", in: "repo")
        model.replacement = "baz"
        model.replaceAll()
        await settle()
        let status = try XCTUnwrap(model.status)
        XCTAssertTrue(status.hasPrefix("Replaced 2 matches in 1 file · failed: b.txt: "), status)
    }
}

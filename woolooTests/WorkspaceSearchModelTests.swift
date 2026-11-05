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

    private actor ReadGate {
        var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private func waitForStart(_ gate: ReadGate) async {
        for _ in 0..<500 {
            if await gate.started { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The delayed operation did not start")
    }

    func testChangingSpaceInvalidatesOpeningAndReplacingBeforeTheNewSearchFinishes() async throws {
        await search("foo")
        let other = try sandbox.repository("other", files: ["a.txt": "foo in B\n"])
        let gate = ReadGate()
        model.readSearch = { options, location in
            let value = try await WorkspaceFiles.blocking(at: location) { try WorkspaceSearch.search(options, at: location) }
            await gate.wait()
            return value
        }
        model.replacement = "changed"
        model.setLocation(other)
        XCTAssertNil(model.result)
        XCTAssertNil(model.locationForResult("a.txt"))
        model.replaceNext()
        model.replaceAll()
        XCTAssertFalse(model.isReplacing)
        await waitForStart(gate)
        XCTAssertEqual(try sandbox.read("a.txt", in: "other"), "foo in B\n")
        await gate.release()
        await settle()
        XCTAssertEqual(model.locationForResult("a.txt"), other)
    }

    func testQueryChangesInvalidateResultsWithoutAMountedViewAndRejectOldConfirmation() async throws {
        await search("foo")
        let revision = try XCTUnwrap(model.resultRevision)
        model.options.query = "bar"
        XCTAssertNil(model.result)
        XCTAssertNil(model.locationForResult("a.txt"))
        model.replaceNext()
        XCTAssertFalse(model.isReplacing)
        await settle()
        model.replacement = "changed"
        model.replaceAll(expectedRevision: revision)
        XCTAssertFalse(model.isReplacing)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "foo one foo\nbar\n")
    }

    func testLiveNavigationRejectsActionsBeforeTheLocationCallbackRuns() async throws {
        await search("foo")
        model.currentFileIdentity = { "another-context" }
        XCTAssertNil(model.locationForResult("a.txt"))
        model.replaceNext()
        model.replaceAll()
        XCTAssertFalse(model.isReplacing)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "foo one foo\nbar\n")
    }

    func testLateSearchCannotReplaceResultsAfterReturningToTheOriginalSpace() async throws {
        await search("foo")
        let original = repo!
        let other = try sandbox.repository("other", files: ["other.txt": "foo in B\n"])
        let gate = ReadGate()
        model.readSearch = { options, location in
            let value = try await WorkspaceFiles.blocking(at: location) { try WorkspaceSearch.search(options, at: location) }
            if location.identity == other.identity { await gate.wait() }
            return value
        }
        model.setLocation(other)
        await waitForStart(gate)
        model.setLocation(original)
        await settle()
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.result?.matchCount, 3)
        XCTAssertEqual(model.locationForResult("a.txt"), original)
        XCTAssertNil(model.locationForResult("other.txt"))
    }

    func testReplaceFinishesInItsOriginalSpaceWithoutPublishingStatusInAnotherSpace() async throws {
        await search("foo")
        let other = try sandbox.repository("other", files: ["a.txt": "foo in B\n"])
        let started = expectation(description: "replace started")
        let gate = DispatchSemaphore(value: 0)
        model.replaceFile = { path, options, replacement, target, location in
            started.fulfill()
            gate.wait()
            return try WorkspaceSearch.replace(in: path, options: options, replacement: replacement, only: target, at: location)
        }
        var modified: [WorkspaceFileLocation] = []
        model.didModifyFiles = { location, _ in modified.append(location) }
        model.replacement = "changed"
        model.replaceNext()
        await fulfillment(of: [started], timeout: 5)
        model.setLocation(other)
        gate.signal()
        await settle()
        XCTAssertEqual(modified, [repo!])
        XCTAssertNil(model.status)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "changed one foo\nbar\n")
        XCTAssertEqual(try sandbox.read("a.txt", in: "other"), "foo in B\n")
        XCTAssertEqual(model.locationForResult("a.txt"), other)
    }

    func testRenamingSpaceRefreshesMetadataWithoutRepeatingItsSearch() async throws {
        await search("foo")
        let revision = model.resultRevision
        let renamed = WorkspaceFileLocation(machine: repo.machine, session: repo.session, workspaceID: repo.workspaceID,
                                            workspaceLabel: "Renamed", root: repo.root)
        model.setLocation(renamed)
        XCTAssertEqual(model.location?.workspaceLabel, "Renamed")
        XCTAssertEqual(model.resultRevision, revision)
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

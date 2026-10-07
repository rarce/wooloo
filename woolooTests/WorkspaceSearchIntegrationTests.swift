import XCTest
@testable import wooloo

/// Project search and replace through the shell script, with and without Git.
final class WorkspaceSearchIntegrationTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!

    override func setUpWithError() throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: [
            ".gitignore": "build/\n",
            "src/a.swift": "let foo = 1\nlet bar = foo\n",
            "docs/readme.md": "Foo in docs\n",
        ])
        try sandbox.write(["notes.txt": "foo untracked\n", "build/out.txt": "foo ignored\n"], in: "repo")
    }

    override func tearDown() {
        sandbox.tearDown()
    }

    private func search(_ query: String, in location: WorkspaceFileLocation? = nil,
                        configure: (inout WorkspaceSearchOptions) -> Void = { _ in }) throws -> [String: Int] {
        var options = WorkspaceSearchOptions(query: query)
        configure(&options)
        let result = try WorkspaceSearch.search(options, at: location ?? repo)
        return result.files.reduce(into: [:]) { $0[$1.path] = $1.matchCount }
    }

    func testSearchCoversTrackedAndUntrackedButNotIgnoredFiles() throws {
        XCTAssertEqual(try search("foo"), ["src/a.swift": 2, "docs/readme.md": 1, "notes.txt": 1])
        XCTAssertEqual(try search("foo") { $0.includeIgnored = true },
                       ["src/a.swift": 2, "docs/readme.md": 1, "notes.txt": 1, "build/out.txt": 1])
        XCTAssertEqual(try search("Foo") { $0.caseSensitive = true }, ["docs/readme.md": 1])
        XCTAssertEqual(try search("nothing matches this"), [:])
    }

    func testSearchFiltersByGlobs() throws {
        XCTAssertEqual(try search("foo") { $0.include = "*.swift" }, ["src/a.swift": 2])
        XCTAssertEqual(try search("foo") { $0.exclude = "*.md, notes.*" }, ["src/a.swift": 2])
        XCTAssertEqual(try search("foo") { $0.include = "*.{md,txt}" }, ["docs/readme.md": 1, "notes.txt": 1])
    }

    func testRegexSearch() throws {
        XCTAssertEqual(try search("fo+ =") { $0.regex = true }, ["src/a.swift": 1])
        XCTAssertThrowsError(try search("(") { $0.regex = true })
    }

    func testSearchWithoutGitUsesGrep() throws {
        try sandbox.write(["plain/src/a.swift": "let foo = 1\n", "plain/b.txt": "no match\n"], in: ".")
        XCTAssertEqual(try search("foo", in: sandbox.location("plain")), ["src/a.swift": 1])
    }

    /// The query reaches the shell script; it must be searched for, never run.
    func testQueryIsNeverExecuted() throws {
        let marker = sandbox.path("pwned")
        for query in ["$(touch \(marker))", "`touch \(marker)`", "'; touch \(marker); echo '"] {
            _ = try search(query)
            _ = try search(query) { $0.regex = true }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testReplaceAllOrOneMatch() throws {
        let options = WorkspaceSearchOptions(query: "foo")
        XCTAssertEqual(try WorkspaceSearch.replace(in: "src/a.swift", options: options, replacement: "baz",
                                                   only: WorkspaceSearchMatchRef(path: "src/a.swift", line: 2, occurrence: 0),
                                                   at: repo), 1)
        XCTAssertEqual(try sandbox.read("src/a.swift", in: "repo"), "let foo = 1\nlet bar = baz\n")

        XCTAssertThrowsError(try WorkspaceSearch.replace(in: "src/a.swift", options: options, replacement: "baz",
                                                         only: WorkspaceSearchMatchRef(path: "src/a.swift", line: 2, occurrence: 0),
                                                         at: repo), "The match on line 2 is gone")

        XCTAssertEqual(try WorkspaceSearch.replace(in: "src/a.swift", options: options, replacement: "$0", at: repo), 1)
        XCTAssertEqual(try sandbox.read("src/a.swift", in: "repo"), "let $0 = 1\nlet bar = baz\n")
    }

    func testRegexReplaceUsesCaptures() throws {
        var options = WorkspaceSearchOptions(query: "let (\\w+) = (\\w+)")
        options.regex = true
        XCTAssertEqual(try WorkspaceSearch.replace(in: "src/a.swift", options: options, replacement: "var $1: Int = $2",
                                                   at: repo), 2)
        XCTAssertEqual(try sandbox.read("src/a.swift", in: "repo"), "var foo: Int = 1\nvar bar: Int = foo\n")
    }
}

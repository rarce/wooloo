import SwiftUI
import XCTest
@testable import wooloo

private actor GitHubReadFixture {
    var requests: [String] = []
    var shouldFail = false
    var slowRoot: String?
    let repository = WorkspaceGitHubRepository(nameWithOwner: "team/app", url: "https://github.com/team/app", hasIssuesEnabled: true)

    func fail() { shouldFail = true }
    func delay(_ root: String) { slowRoot = root }
    func read(_ location: WorkspaceFileLocation, kind: WorkspaceGitHubKind) async throws -> [WorkspaceGitHubItem] {
        requests.append(location.root + "|" + kind.rawValue)
        if location.root == slowRoot { try await Task.sleep(for: .milliseconds(80)) }
        if shouldFail { throw WorkspaceFileError.message("HTTP 403: API rate limit exceeded") }
        return [WorkspaceGitHubItem(number: 7, title: location.root + kind.rawValue,
                                    url: "https://github.com/team/app/issues/7", author: nil)]
    }
}

@MainActor
final class WorkspaceGitHubTests: XCTestCase {
    private func location(_ root: String = "/repo", machine: HerdrMachineProfile? = nil) -> WorkspaceFileLocation {
        WorkspaceFileLocation(machine: machine, session: "test", workspaceID: "w1", workspaceLabel: "Test", root: root)
    }

    private func model(_ fixture: GitHubReadFixture) -> WorkspaceGitHubModel {
        WorkspaceGitHubModel(loadRepository: { _ in await fixture.repository }, loadItems: { location, kind, _ in
            try await fixture.read(location, kind: kind)
        })
    }

    func testTabSwitchReusesCacheAndRefreshKeepsStaleResultsOnFailure() async {
        let fixture = GitHubReadFixture()
        let model = model(fixture)
        await model.load(location(), kind: .issues)
        let issues = model.items
        await model.load(location(), kind: .prs)
        XCTAssertNotEqual(model.items, issues)
        await model.load(location(), kind: .issues)
        XCTAssertEqual(model.items, issues)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        await fixture.fail()
        await model.load(location(), kind: .issues, refresh: true)
        XCTAssertEqual(model.items, issues)
        XCTAssertTrue(model.error?.contains("limit") == true)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedNewContextNeverShowsPreviousSpacesResults() async {
        let fixture = GitHubReadFixture()
        let model = model(fixture)
        await model.load(location(), kind: .issues)
        await fixture.fail()
        await model.load(location("/other"), kind: .issues)
        XCTAssertNil(model.items)
        XCTAssertNotNil(model.error)
    }

    func testLateResponseCannotReplaceNewContext() async {
        let fixture = GitHubReadFixture()
        await fixture.delay("/slow")
        let model = model(fixture)
        let old = Task { await model.load(location("/slow"), kind: .issues) }
        // Let the old load enter its deliberately slow request.
        while await fixture.requests.isEmpty { await Task.yield() }
        await model.load(location("/fast"), kind: .prs)
        await old.value
        XCTAssertEqual(model.items?.first?.title, "/fastprs")
        XCTAssertEqual(model.context, WorkspaceGitHubModel.contextKey(location("/fast")))
    }

    func testDisabledIssuesDoNotRequestIssueList() async {
        let fixture = GitHubReadFixture()
        let model = WorkspaceGitHubModel(loadRepository: { _ in
            WorkspaceGitHubRepository(nameWithOwner: "team/app", url: "https://github.com/team/app", hasIssuesEnabled: false)
        }, loadItems: { location, kind, _ in try await fixture.read(location, kind: kind) })
        await model.load(location(), kind: .issues)
        XCTAssertEqual(model.items, [])
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHostIdentitySeparatesCredentials() {
        let a = HerdrMachineProfile(id: "server", label: "Server", target: "alice@server", session: "test", enabled: true)
        let b = HerdrMachineProfile(id: "server", label: "Server", target: "bob@server", session: "test", enabled: true)
        XCTAssertNotEqual(WorkspaceGitHubModel.contextKey(location(machine: a)),
                          WorkspaceGitHubModel.contextKey(location(machine: b)))
    }

    func testOverflowKeepsActiveTabAndWideStripShowsAllTabs() {
        let strip = PanelTabStrip(tabs: PanelTab.explorer, selection: .constant("branches"))
        let narrow = strip.visibleTabs(in: 200)
        XCTAssertTrue(narrow.contains { $0.id == "branches" })
        XCTAssertLessThan(narrow.count, 4)
        XCTAssertEqual(strip.visibleTabs(in: 560), PanelTab.explorer)
    }

    func testCommandPassesArgumentsLiterallyWithoutExecutingShellSyntax() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("wooloo-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("gh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let dangerous = "https://github.com/team/$(touch SHOULD_NOT_EXIST)'repo"
        let script = "PATH=\(WorkspaceFiles.quote(directory.path)):$PATH\n" + WorkspaceGitHub.command(["pr", "list", "--repo", dangerous])
        let data = try WorkspaceFiles.shell(script, at: location(directory.path), limit: 10_000)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pr\nlist\n--repo\n\(dangerous)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testGitHubURLsAndErrorStates() throws {
        let issue = try JSONDecoder().decode(WorkspaceGitHubItem.self, from: Data("""
            {"number":12,"title":"Issue","url":"https://github.com/team/app/issues/12","author":null}
            """.utf8))
        XCTAssertNotNil(issue.browserURL)
        XCTAssertNil(WorkspaceGitHubItem(number: 1, title: "Unsafe", url: "file:///etc/passwd", author: nil).browserURL)
        XCTAssertTrue(WorkspaceGitHub.message(for: WorkspaceFileError.message("WOOL_GH_MISSING"), machine: "Server").contains("Server"))
        XCTAssertTrue(WorkspaceGitHub.message(for: WorkspaceFileError.message("gh auth login"), machine: "Server").contains("gh auth login"))
    }
}

import XCTest
@testable import xherdr

/// What the Git bar's commit and sync buttons offer.
final class WorkspaceGitBarPlanTests: XCTestCase {
    private func change(_ path: String, _ index: Character, _ worktree: Character) -> WorkspaceFileChange {
        WorkspaceFileChange(path: path, indexStatus: index, worktreeStatus: worktree, originalPath: nil)
    }

    func testStagedChangesAreCommittedFirst() {
        let plan = WorkspaceCommitPlan(changes: [change("src/a.swift", "M", " "), change("b.txt", " ", "M")])
        XCTAssertEqual(plan.defaultMode, .staged)
        XCTAssertEqual(plan.suggestion, "Update a.swift", "The suggestion names the one staged file")

        let unstaged = WorkspaceCommitPlan(changes: [change("b.txt", " ", "M"), change("new.txt", "?", "?")])
        XCTAssertEqual(unstaged.defaultMode, .tracked)
        XCTAssertEqual(unstaged.suggestion, "Update b.txt", "Untracked files are not committed by default")
    }

    func testSuggestionDescribesTheChange() {
        XCTAssertEqual(WorkspaceCommitPlan(changes: [change("dir/new.txt", "A", " ")]).suggestion, "Create new.txt")
        XCTAssertEqual(WorkspaceCommitPlan(changes: [change("gone.txt", "D", " ")]).suggestion, "Delete gone.txt")
        XCTAssertEqual(WorkspaceCommitPlan(changes: [change("new.txt", "?", "?")]).suggestion, nil,
                       "Nothing tracked to commit by default")
        XCTAssertNil(WorkspaceCommitPlan(changes: [change("a", "M", " "), change("b", "M", " ")]).suggestion)
    }

    func testModesNeedChangesAndAMessage() {
        let two = WorkspaceCommitPlan(changes: [change("a", " ", "M"), change("b", " ", "M"), change("c", "?", "?")])
        XCTAssertFalse(two.isAvailable(.tracked, typed: "  \n"), "Two files have no suggested message")
        XCTAssertTrue(two.isAvailable(.tracked, typed: "Fix"))
        XCTAssertFalse(two.isAvailable(.staged, typed: "Fix"), "Nothing is staged")
        XCTAssertTrue(two.isAvailable(.all, typed: "Fix"))
        XCTAssertTrue(two.isAvailable(.amend, typed: ""))
        XCTAssertFalse(WorkspaceCommitPlan(changes: []).isAvailable(.all, typed: "Fix"))

        let one = WorkspaceCommitPlan(changes: [change("a", " ", "M")])
        XCTAssertTrue(one.isAvailable(.tracked, typed: ""), "The suggestion stands in for a message")
    }

    func testMessageFallsBackToTheSuggestionExceptForAmend() {
        let plan = WorkspaceCommitPlan(changes: [change("a.txt", " ", "M")])
        XCTAssertEqual(plan.message(for: .tracked, typed: "  Fix it \n"), "Fix it")
        XCTAssertEqual(plan.message(for: .tracked, typed: ""), "Update a.txt")
        XCTAssertEqual(plan.message(for: .amend, typed: ""), "", "An empty amend keeps the last message")
    }

    private func status(branch: String? = "main", upstream: String? = "origin/main", ahead: Int = 0, behind: Int = 0,
                        remotes: [String] = ["origin"]) -> WorkspaceSyncPlan {
        WorkspaceSyncPlan(status: WorkspaceBranchStatus(branch: branch, shortHead: "abc1234", upstream: upstream,
                                                        ahead: ahead, behind: behind, remotes: remotes))
    }

    func testSyncPrefersPublishThenPullThenPush() {
        let publish = status(branch: "feature", upstream: nil, remotes: ["upstream", "origin"])
        guard case .publish(let remote, let branch) = publish.primaryAction else { return XCTFail("\(publish.primaryAction)") }
        XCTAssertEqual([remote, branch], ["origin", "feature"])
        XCTAssertEqual(publish.primaryTitle, "Publish")
        XCTAssertFalse(publish.tracksUpstream)

        let both = status(ahead: 1, behind: 2)
        XCTAssertEqual(both.primaryTitle, "Pull 2")
        XCTAssertEqual(both.primaryHelp, "Pull 2 commits; 1 commit to push afterwards")

        let ahead = status(ahead: 3)
        XCTAssertEqual(ahead.primaryTitle, "Push 3")
        XCTAssertEqual(ahead.primaryHelp, "Push 3 commits")

        XCTAssertEqual(status().primaryTitle, "Fetch")
        XCTAssertEqual(status(behind: 1).primaryHelp, "Pull 1 commit")
    }

    func testDetachedHeadOrNoRemotes() {
        XCTAssertEqual(status(branch: nil, upstream: nil).primaryTitle, "Fetch", "A detached HEAD cannot be published")
        let local = status(upstream: nil, remotes: [])
        XCTAssertFalse(local.hasRemote)
        XCTAssertEqual(local.primaryHelp, "This repository has no remotes")
    }
}

/// `WorkspaceGitBarModel` against a disposable repository.
@MainActor
final class WorkspaceGitBarModelTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var model: WorkspaceGitBarModel!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: ["a.txt": "one\n"])
        try sandbox.sh("git branch other", in: "repo")
        model = WorkspaceGitBarModel()
        await model.load(repo)
    }

    override func tearDown() async throws {
        sandbox.tearDown()
    }

    /// Waits until the running operation and the reload after it are done.
    private func settle() async {
        for _ in 0..<500 where model.running != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.running, "The operation did not finish")
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Runs one operation and returns what it reported: nil inside for success, else the error.
    private func run(_ start: (@escaping (String?) -> Void) -> Void) async -> String?? {
        var outcome: String??
        start { outcome = .some($0) }
        await settle()
        return outcome
    }

    private func log() throws -> String {
        try sandbox.sh("git log --format=%s", in: "repo").trimmingCharacters(in: .newlines)
    }

    func testLoadReadsBranchesAndStatus() {
        XCTAssertEqual(model.status?.branch, "main")
        XCTAssertEqual(model.localBranches.map(\.name).sorted(), ["main", "other"])
        XCTAssertTrue(model.otherWorktrees.isEmpty)
        XCTAssertNotNil(model.currentWorktree)
    }

    func testCommitUsesTheSuggestionAndClearsTheMessage() async throws {
        try sandbox.write(["a.txt": "two\n"], in: "repo")
        let plan = WorkspaceCommitPlan(changes: [WorkspaceFileChange(path: "a.txt", indexStatus: " ",
                                                                     worktreeStatus: "M", originalPath: nil)])
        model.message = "   "
        let outcome = await run { model.commit(.tracked, plan: plan, finished: $0) }
        XCTAssertEqual(outcome, .some(nil))
        XCTAssertEqual(try log(), "Update a.txt\nInitial")
        XCTAssertEqual(model.message, "")
    }

    /// A failed commit reports Git's error and keeps the typed message.
    func testFailedCommitKeepsTheMessage() async throws {
        model.message = "Nothing to commit"
        let outcome = await run { model.commit(.tracked, plan: WorkspaceCommitPlan(changes: []), finished: $0) }
        XCTAssertNotNil(outcome ?? nil)
        XCTAssertEqual(model.message, "Nothing to commit")
        XCTAssertEqual(try log(), "Initial")
    }

    func testSwitchingBranchReloadsTheStatus() async throws {
        let other = try XCTUnwrap(model.localBranches.first { $0.name == "other" })
        let outcome = await run { model.switchBranch(other, finished: $0) }
        XCTAssertEqual(outcome, .some(nil))
        XCTAssertEqual(model.status?.branch, "other")
    }

    /// One operation runs at a time; another started meanwhile is ignored.
    func testOperationsDoNotOverlap() async throws {
        let other = try XCTUnwrap(model.localBranches.first { $0.name == "other" })
        var second: String??
        model.perform(.fetch) { _ in }
        XCTAssertEqual(model.running, "Fetch…")
        model.switchBranch(other) { second = .some($0) }
        await settle()
        XCTAssertNil(second)
        XCTAssertEqual(model.status?.branch, "main")
    }
}

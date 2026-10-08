import XCTest
@testable import wooloo

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

    /// Waits until the running operation is done and `reloaded` holds after the reload that follows.
    private func settle(until reloaded: () -> Bool = { true }) async {
        for _ in 0..<500 where model.running != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.running, "The operation did not finish")
        for _ in 0..<500 where !reloaded() { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
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
        var outcome: String??
        model.switchBranch(other) { outcome = .some($0) }
        await settle { model.status?.branch == "other" }
        XCTAssertEqual(outcome, .some(nil))
        XCTAssertEqual(model.status?.branch, "other", "The bar reloads after switching")
    }

    func testCreatingABranchSwitchesToIt() async throws {
        var outcome: String??
        model.createBranch("topic") { outcome = .some($0) }
        await settle { model.status?.branch == "topic" }
        XCTAssertEqual(outcome, .some(nil))
        XCTAssertEqual(model.localBranches.map(\.name).sorted(), ["main", "other", "topic"])
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

/// The branch picker's rows for what was typed.
final class WorkspaceBranchPickerTests: XCTestCase {
    private func branch(_ name: String, remote: Bool = false, current: Bool = false,
                        upstream: String = "") -> WorkspaceBranch {
        WorkspaceBranch(id: (remote ? "refs/remotes/" : "refs/heads/") + name, name: name, isRemote: remote,
                        isCurrent: current, upstream: upstream)
    }

    private var branches: [WorkspaceBranch] {
        [branch("bugfix"), branch("main", current: true, upstream: "origin/main"), branch("topic/feature"),
         branch("origin/main", remote: true), branch("origin/release", remote: true)]
    }

    private func rows(_ query: String, worktrees: [WorkspaceWorktree] = []) -> [WorkspaceBranchPickerRow] {
        WorkspaceBranchPicker.rows(query: query, branches: branches, worktrees: worktrees, root: "/repo")
    }

    /// The current branch first, then local branches, then remote ones no local branch tracks.
    func testListsTheCurrentBranchThenLocalThenUntrackedRemoteBranches() {
        XCTAssertEqual(rows("").map(\.title), ["main", "bugfix", "topic/feature", "origin/release"])
    }

    func testFiltersFuzzilyAndOffersToCreateTheTypedName() throws {
        let found = rows("tf")
        XCTAssertEqual(found.map(\.title), ["topic/feature", "tf"])
        XCTAssertEqual(found[0].positions, [0, 6])
        XCTAssertEqual(found[1].choice, .create("tf"))

        XCTAssertEqual(rows(" release ").first?.title, "origin/release")
        XCTAssertEqual(rows("release").last?.choice, .create("release"),
                       "A remote branch of that name does not stop creating a local one")
    }

    func testDoesNotOfferExistingOrInvalidNames() {
        XCTAssertFalse(rows("bugfix").contains { if case .create = $0.choice { true } else { false } })
        for name in ["has space", "-x", "a..b", "end/", "x.lock", "a:b", "wip~1", "@"] {
            XCTAssertFalse(WorkspaceBranchPicker.isPlausibleBranchName(name), name)
            XCTAssertEqual(rows(name).filter { if case .create = $0.choice { true } else { false } }, [], name)
        }
        for name in ["feature/login", "fix-123", "v2.0", "UPPER_case"] {
            XCTAssertTrue(WorkspaceBranchPicker.isPlausibleBranchName(name), name)
        }
    }

    /// A branch checked out in another worktree opens that worktree instead of switching.
    func testBranchesCheckedOutElsewhereOpenTheirWorktree() {
        let worktrees = [
            WorkspaceWorktree(path: "/repo", branch: "main", isBare: false, isLocked: false, isPrunable: false),
            WorkspaceWorktree(path: "/repo-feature", branch: "topic/feature", isBare: false, isLocked: false, isPrunable: false)
        ]
        let found = rows("", worktrees: worktrees)
        XCTAssertEqual(found.first { $0.title == "topic/feature" }?.choice,
                       .branch(branch("topic/feature"), worktreePath: "/repo-feature"))
        XCTAssertEqual(found.first { $0.title == "main" }?.choice,
                       .branch(branch("main", current: true, upstream: "origin/main"), worktreePath: nil))
        XCTAssertEqual(found.first { $0.title == "bugfix" }?.choice, .branch(branch("bugfix"), worktreePath: nil))
    }
}

import XCTest
@testable import wooloo

/// The Add Worktree sheet's suggested branch, path and new branch name.
final class AddWorktreeRequestTests: XCTestCase {
    private func branch(_ name: String, remote: Bool = false, current: Bool = false) -> WorkspaceBranch {
        WorkspaceBranch(id: (remote ? "refs/remotes/" : "refs/heads/") + name, name: name, isRemote: remote,
                        isCurrent: current, upstream: "")
    }

    private func listing(_ branches: [WorkspaceBranch]) -> WorkspaceRepositoryListing {
        WorkspaceRepositoryListing(commits: [], branches: branches, worktrees: [], root: "/work/app")
    }

    func testFirstFreeLocalBranchIsCheckedOutBesideTheRepository() throws {
        let request = try XCTUnwrap(AddWorktreeRequest.suggested(for: listing([
            branch("main", current: true), branch("origin/main", remote: true), branch("feature/login"),
        ])))
        XCTAssertEqual(request.branchID, "refs/heads/feature/login")
        XCTAssertEqual(request.path, "/work/app-feature-login")
        XCTAssertEqual(request.newBranch, "", "A free local branch is checked out as it is")
    }

    /// The current branch or a remote one cannot be checked out twice, so a new branch is proposed.
    func testCheckedOutOrRemoteBranchesNeedANewBranch() throws {
        let current = try XCTUnwrap(AddWorktreeRequest.suggested(for: listing([branch("main", current: true)])))
        XCTAssertEqual(current.newBranch, "main-worktree")
        XCTAssertEqual(current.path, "/work/app-main")

        let remote = branch("origin/fix", remote: true)
        let fromRemote = try XCTUnwrap(AddWorktreeRequest.suggested(for: listing([branch("main", current: true), remote]),
                                                                   from: remote))
        XCTAssertEqual(fromRemote.branchID, "refs/remotes/origin/fix")
        XCTAssertEqual(fromRemote.newBranch, "fix-worktree")
        XCTAssertEqual(fromRemote.path, "/work/app-origin-fix")
    }

    func testNoBranchesNoRequest() {
        XCTAssertNil(AddWorktreeRequest.suggested(for: listing([])))
    }
}

/// `WorkspaceRepositoryModel` against disposable repositories.
@MainActor
final class WorkspaceRepositoryModelTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var model: WorkspaceRepositoryModel!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: ["a.txt": "one\n"])
        try sandbox.write(["a.txt": "two\n", "b.txt": "new\n"], in: "repo")
        try sandbox.sh("git add -A && git commit -q -m Second && git branch other", in: "repo")
        model = WorkspaceRepositoryModel()
        await model.load(repo)
    }

    override func tearDown() async throws {
        sandbox.tearDown()
    }

    /// Waits for an operation to reload the repository or report an error.
    private func settle(from version: Int) async {
        for _ in 0..<500 where model.reloadVersion == version && model.operationError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.load(repo)
    }

    private var worktrees: [String] {
        (model.listing?.worktrees ?? []).map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    func testLoadListsCommitsBranchesAndWorktrees() {
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.listing?.commits.map(\.subject), ["Second", "Initial"])
        XCTAssertEqual(model.listing?.branches.filter { !$0.isRemote }.map(\.name).sorted(), ["main", "other"])
        XCTAssertEqual(worktrees, ["repo"])
    }

    /// Reloading the repository already shown, as after a save, keeps it instead of a spinner.
    func testReloadKeepsTheListingShown() async {
        let reload = Task { await model.load(repo) }
        await Task.yield()
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.listing)
        await reload.value
    }

    func testFolderWithoutGitReportsAnError() async throws {
        try sandbox.write(["plain/x.txt": "x\n"], in: ".")
        await model.load(sandbox.location("plain"))
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isLoading)

        await model.load(nil)
        XCTAssertNil(model.listing)
        XCTAssertNil(model.error)
    }

    func testCommitFilesAreLoadedForTheSelectedCommit() async throws {
        let head = try XCTUnwrap(model.listing?.commits.first?.id)
        await model.loadCommitFiles(head, at: repo)
        XCTAssertEqual(model.commitFiles?.map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(model.commitFiles?.first { $0.path == "b.txt" }?.status, "A")

        await model.loadCommitFiles("0000000000000000000000000000000000000000", at: repo)
        XCTAssertNil(model.commitFiles)
        XCTAssertNotNil(model.commitFilesError)

        await model.loadCommitFiles(nil, at: repo)
        XCTAssertNil(model.commitFiles)
        XCTAssertNil(model.commitFilesError)
    }

    func testAddingAndRemovingWorktrees() async throws {
        let other = try XCTUnwrap(model.listing?.branches.first { $0.name == "other" })
        var version = model.reloadVersion
        model.addWorktree(at: repo, branch: other, path: "  \(sandbox.path("repo-other"))\n", newBranch: " ")
        await settle(from: version)
        XCTAssertNil(model.operationError)
        XCTAssertEqual(worktrees, ["repo", "repo-other"])
        XCTAssertEqual(model.listing?.worktrees.first { $0.path.hasSuffix("repo-other") }?.branch, "other")

        let main = try XCTUnwrap(model.listing?.branches.first { $0.name == "main" })
        version = model.reloadVersion
        model.addWorktree(at: repo, branch: main, path: sandbox.path("repo-main"), newBranch: "main-worktree")
        await settle(from: version)
        XCTAssertEqual(model.listing?.worktrees.first { $0.path.hasSuffix("repo-main") }?.branch, "main-worktree")

        let tree = try XCTUnwrap(model.listing?.worktrees.first { $0.path.hasSuffix("repo-other") })
        version = model.reloadVersion
        model.removeWorktree(tree, at: repo)
        await settle(from: version)
        XCTAssertEqual(worktrees, ["repo", "repo-main"])
    }

    /// Removing a worktree with uncommitted changes fails and leaves it in place.
    func testDirtyWorktreeIsNotRemoved() async throws {
        try sandbox.sh("git worktree add -q ../repo-dirty other", in: "repo")
        try sandbox.write(["a.txt": "unsaved work\n"], in: "repo-dirty")
        await model.load(repo)
        let tree = try XCTUnwrap(model.listing?.worktrees.first { $0.path.hasSuffix("repo-dirty") })
        let version = model.reloadVersion
        model.removeWorktree(tree, at: repo)
        await settle(from: version)
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo-dirty"), "unsaved work\n")
        XCTAssertEqual(worktrees, ["repo", "repo-dirty"])
        model.clearOperationError()
        XCTAssertNil(model.operationError)
    }

    func testSwitchingBranchNotifiesTheExplorer() async throws {
        let other = try XCTUnwrap(model.listing?.branches.first { $0.name == "other" })
        var switched = false
        let version = model.reloadVersion
        model.switchBranch(other, at: repo) { switched = true }
        await settle(from: version)
        XCTAssertTrue(switched)
        XCTAssertEqual(try sandbox.sh("git branch --show-current", in: "repo"), "other\n")
    }
}

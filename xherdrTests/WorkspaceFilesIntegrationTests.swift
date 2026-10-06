import XCTest
@testable import xherdr

/// `WorkspaceFiles` against real Git repositories and files in a local sandbox.
final class WorkspaceFilesIntegrationTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!

    override func setUpWithError() throws {
        sandbox = try WorkspaceGitSandbox()
    }

    override func tearDown() {
        sandbox.tearDown()
    }

    private func changes(_ location: WorkspaceFileLocation) throws -> [String: String] {
        try WorkspaceFiles.listing(at: location).changes.reduce(into: [:]) {
            $0[$1.path] = String([$1.indexStatus, $1.worktreeStatus])
        }
    }

    // MARK: Listing

    func testListingShowsTrackedAndUntrackedFilesWithTheirChanges() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "one\n", "dir/b.txt": "b\n"])
        try sandbox.sh("echo two >> a.txt && git add a.txt && echo three >> a.txt && echo new > notes.md && rm dir/b.txt",
                       in: "repo")
        let listing = try WorkspaceFiles.listing(at: repo)
        XCTAssertTrue(listing.hasGit)
        XCTAssertEqual(listing.files, ["a.txt", "dir/b.txt", "notes.md"])
        XCTAssertEqual(listing.totalFiles, 3)
        XCTAssertEqual(listing.changes.map(\.path), ["a.txt", "dir/b.txt", "notes.md"])
        XCTAssertEqual(listing.changes.map(\.kind), [.modified, .deleted, .untracked])
        XCTAssertEqual(listing.changes[0].stageState, .partial)
    }

    func testListingShowsIgnoredFilesAndIgnoredFoldersWithoutTheirContents() throws {
        let repo = try sandbox.repository("repo", files: [".gitignore": "*.log\nnode_modules/\n", "a/y.txt": "y\n"])
        try sandbox.write(["a/x.log": "x", "b/z.log": "z", "node_modules/pkg/index.js": "i", "node_modules/.bin/tool": "t",
                           "debug.log": "d"], in: "repo")
        let listing = try WorkspaceFiles.listing(at: repo)
        XCTAssertEqual(listing.files, [".gitignore", "a/x.log", "a/y.txt", "debug.log"])
        XCTAssertEqual(listing.totalFiles, 4)
        // Git lists b/ and b/z.log; the folder stands for both.
        XCTAssertEqual(listing.ignored.directories, ["b", "node_modules"])
        XCTAssertEqual(listing.ignored.files, ["a/x.log", "debug.log"])
        XCTAssertTrue(listing.ignored.contains("node_modules/pkg/index.js"))
        XCTAssertFalse(listing.ignored.contains("a/y.txt"))
        XCTAssertTrue(listing.changes.isEmpty, "ignored files are not changes")

        let modules = try WorkspaceFiles.folderContents("node_modules", at: repo)
        XCTAssertEqual(modules.directories.sorted(), ["node_modules/.bin", "node_modules/pkg"])
        XCTAssertEqual(modules.files, [])
        XCTAssertEqual(try WorkspaceFiles.folderContents("node_modules/pkg", at: repo).files, ["node_modules/pkg/index.js"])
        XCTAssertFalse(try WorkspaceFiles.folderContents("", at: repo).directories.contains(".git"))
    }

    func testFolderContentsStayInsideTheSpace() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.write(["outside/secret.txt": "s"], in: ".")
        try sandbox.sh("ln -s ../outside escape && ln -s a.txt link.txt", in: "repo")
        for path in ["../outside", "escape", "escape/..", "/etc"] {
            XCTAssertThrowsError(try WorkspaceFiles.folderContents(path, at: repo), path)
        }
        let root = try WorkspaceFiles.folderContents("", at: repo)
        XCTAssertTrue(root.files.contains("link.txt"))
        XCTAssertTrue(root.directories.contains("escape"))
        XCTAssertEqual(root.symbolicLinks["escape"], WorkspaceSymbolicLink(target: "../outside", isDirectory: true))
    }

    func testListingWithoutGitIncludesSymbolicLinksWithoutFollowingDirectories() throws {
        try sandbox.write(["plain/a.txt": "a", "plain/sub/c.txt": "c"], in: ".")
        try sandbox.sh("ln -s /etc/hosts outside && ln -s sub alias && ln -s missing broken", in: "plain")
        let listing = try WorkspaceFiles.listing(at: sandbox.location("plain"))
        XCTAssertFalse(listing.hasGit)
        XCTAssertEqual(listing.files, ["a.txt", "alias", "broken", "outside", "sub/c.txt"])
        XCTAssertEqual(listing.symbolicLinks["alias"], WorkspaceSymbolicLink(target: "sub", isDirectory: true))
        XCTAssertEqual(listing.symbolicLinks["broken"], WorkspaceSymbolicLink(target: "missing", isDirectory: false))
        XCTAssertTrue(listing.changes.isEmpty)
    }

    func testListingIdentifiesTrackedIgnoredAndBrokenLinks() throws {
        let repo = try sandbox.repository("repo", files: [".gitignore": "ignored*\n", "dir/a.txt": "a\n"])
        try sandbox.sh("ln -s dir/a.txt tracked && git add tracked && git commit -qm Link"
                       + " && ln -s dir folder && ln -s missing broken && ln -s dir ignored-folder", in: "repo")
        let listing = try WorkspaceFiles.listing(at: repo)
        XCTAssertEqual(listing.symbolicLinks, [
            "tracked": WorkspaceSymbolicLink(target: "dir/a.txt", isDirectory: false),
            "folder": WorkspaceSymbolicLink(target: "dir", isDirectory: true),
            "broken": WorkspaceSymbolicLink(target: "missing", isDirectory: false),
            "ignored-folder": WorkspaceSymbolicLink(target: "dir", isDirectory: true),
        ])
        XCTAssertFalse(listing.files.contains("folder/a.txt"), "Linked folders load only when expanded")
    }

    func testSavingThroughLinksPreservesTheLinkAndUpdatesTheTarget() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.write(["outside/secret.txt": "s\n"], in: ".")
        try sandbox.write(["dir/b.txt": "b\n"], in: "repo")
        try sandbox.sh("ln -s a.txt link.txt && ln -s dir internal && ln -s ../outside folder && ln -s missing broken", in: "repo")
        for (path, target) in [("link.txt", "a.txt"), ("internal/b.txt", "dir/b.txt")] {
            let file = try WorkspaceFiles.read(path, at: repo)
            _ = try WorkspaceFiles.save("new\n", path: path, expectedVersion: file.version, at: repo)
            XCTAssertEqual(try sandbox.read(target, in: "repo"), "new\n")
            XCTAssertThrowsError(try WorkspaceFiles.save("stale", path: path, expectedVersion: file.version, at: repo))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.path("repo/link.txt")), "a.txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.path("repo/folder")), "../outside")
        XCTAssertThrowsError(try WorkspaceFiles.read("folder/secret.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.save("escape", path: "folder/secret.txt",
                                                    expectedVersion: WorkspaceFiles.gitBlobHash(Data("s\n".utf8)), at: repo))
        XCTAssertEqual(try sandbox.read("outside/secret.txt", in: "."), "s\n")
        XCTAssertThrowsError(try WorkspaceFiles.read("broken", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.read("../outside/secret.txt", at: repo))
        try sandbox.sh("ln -s . loop && ln -s loop loop-again", in: "repo")
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("loop", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("loop-again", at: repo))
    }

    // MARK: Staging and commits

    func testStageAndUnstageFilesAndFolders() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "dir/b.txt": "b\n", "dir/c.txt": "c\n"])
        try sandbox.sh("echo x >> a.txt && echo x >> dir/b.txt && echo x >> dir/c.txt", in: "repo")

        try WorkspaceFiles.stage("dir", at: repo)
        XCTAssertEqual(try changes(repo), ["a.txt": " M", "dir/b.txt": "M ", "dir/c.txt": "M "])
        try WorkspaceFiles.unstage("", at: repo)
        XCTAssertEqual(try changes(repo), ["a.txt": " M", "dir/b.txt": " M", "dir/c.txt": " M"])
        try WorkspaceFiles.stage("", at: repo)
        XCTAssertEqual(try changes(repo), ["a.txt": "M ", "dir/b.txt": "M ", "dir/c.txt": "M "])

        XCTAssertThrowsError(try WorkspaceFiles.stage("../outside", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.stage("/etc", at: repo))
    }

    func testDiscardRestoresHeadAndDeletesNewFiles() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "b.txt": "b\n", "old.txt": "o\n", "gone.txt": "g\n"])
        try sandbox.sh("echo x >> a.txt && git add a.txt && echo y >> a.txt && echo new > new.txt && echo added > added.txt"
                       + " && git add added.txt && git mv old.txt renamed.txt && rm gone.txt", in: "repo")
        for change in try WorkspaceFiles.listing(at: repo).changes {
            try WorkspaceFiles.discard(change, at: repo)
        }
        XCTAssertEqual(try changes(repo), [:])
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "a\n")
        XCTAssertEqual(try sandbox.read("old.txt", in: "repo"), "o\n")
        XCTAssertEqual(try sandbox.read("gone.txt", in: "repo"), "g\n")
        XCTAssertThrowsError(try sandbox.read("new.txt", in: "repo"))
        XCTAssertThrowsError(try sandbox.read("added.txt", in: "repo"))
        XCTAssertThrowsError(try sandbox.read("renamed.txt", in: "repo"))
    }

    func testFileHistoryFollowsRenames() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "b.txt": "b\n"])
        try sandbox.sh("echo x >> b.txt && git commit -qam 'Touch b' && git mv a.txt c.txt && git commit -qm 'Rename a'"
                       + " && echo y >> c.txt && git commit -qam 'Edit c'", in: "repo")
        let subjects = try WorkspaceFiles.fileHistory("c.txt", at: repo).map(\.subject)
        XCTAssertEqual(subjects.count, 3)
        XCTAssertEqual(Array(subjects.prefix(2)), ["Edit c", "Rename a"])
        XCTAssertThrowsError(try WorkspaceFiles.fileHistory("../x", at: repo))
    }

    func testCommitModesChooseWhatIsCommitted() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.sh("echo more >> a.txt && echo new > new.txt", in: "repo")

        XCTAssertThrowsError(try WorkspaceFiles.commit(message: "  \n", mode: .staged, at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.commit(message: "Nothing staged", mode: .staged, at: repo))

        try WorkspaceFiles.commit(message: "Tracked\n\nBody text", mode: .tracked, at: repo)
        XCTAssertEqual(try changes(repo), ["new.txt": "??"])
        XCTAssertEqual(try WorkspaceFiles.repository(at: repo).commits.first?.subject, "Tracked")

        try WorkspaceFiles.commit(message: "All", mode: .all, at: repo)
        XCTAssertEqual(try changes(repo), [:])

        try WorkspaceFiles.commit(message: "", mode: .amend, at: repo)
        var commits = try WorkspaceFiles.repository(at: repo).commits
        XCTAssertEqual(commits.map(\.subject), ["All", "Tracked", "Initial"])

        try WorkspaceFiles.commit(message: "Everything", mode: .amend, at: repo)
        commits = try WorkspaceFiles.repository(at: repo).commits
        XCTAssertEqual(commits.map(\.subject), ["Everything", "Tracked", "Initial"])
    }

    // MARK: Reading and saving

    func testSaveReplacesTheFileAndKeepsItsPermissions() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.sh("chmod 755 a.txt", in: "repo")
        let file = try WorkspaceFiles.read("a.txt", at: repo)
        XCTAssertEqual(file.text, "one\n")
        XCTAssertEqual(file.version, WorkspaceFiles.gitBlobHash(Data("one\n".utf8)))

        let version = try WorkspaceFiles.save("two\n", path: "a.txt", expectedVersion: file.version, at: repo)
        XCTAssertEqual(version, WorkspaceFiles.gitBlobHash(Data("two\n".utf8)))
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "two\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.path("repo/a.txt"))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path("repo"))
            .filter { $0.hasPrefix(".xherdr-") }
        XCTAssertEqual(leftovers, [])
    }

    func testSaveRejectsAFileChangedSinceItWasRead() throws {
        let repo = try sandbox.repository("repo")
        let file = try WorkspaceFiles.read("a.txt", at: repo)
        try sandbox.write(["a.txt": "changed elsewhere\n"], in: "repo")
        XCTAssertThrowsError(try WorkspaceFiles.save("mine\n", path: "a.txt", expectedVersion: file.version, at: repo)) {
            XCTAssertTrue($0.localizedDescription.contains("changed on disk"))
        }
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "changed elsewhere\n")

        let tooLarge = String(repeating: "x", count: WorkspaceFiles.maximumFileBytes + 1)
        let current = try WorkspaceFiles.read("a.txt", at: repo).version
        XCTAssertThrowsError(try WorkspaceFiles.save(tooLarge, path: "a.txt", expectedVersion: current, at: repo))
    }

    func testReadRefusesFilesItCannotEditSafely() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "dir/b.txt": "b\n"])
        try sandbox.sh("""
            printf 'a\\000b' > binary.dat
            printf '\\377\\376' > latin.txt
            head -c \(WorkspaceFiles.maximumFileBytes + 1) /dev/zero | tr '\\000' x > large.txt
            ln -s /etc/hosts escape.txt
            ln -s a.txt inside.txt
            """, in: "repo")
        for path in ["binary.dat", "latin.txt", "large.txt", "escape.txt", "dir", "missing.txt", "../repo/a.txt", "/etc/hosts"] {
            XCTAssertThrowsError(try WorkspaceFiles.read(path, at: repo), path)
        }
        XCTAssertEqual(try WorkspaceFiles.read("inside.txt", at: repo).text, "a\n")
        XCTAssertThrowsError(try WorkspaceFiles.save("x", path: "escape.txt",
                                                     expectedVersion: WorkspaceFiles.gitBlobHash(Data()), at: repo))
    }

    // MARK: Diffs

    func testFileWithStagedAndUnstagedChangesHasThreeDiffs() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "1\n2\n3\n"])
        try sandbox.sh("printf 'ONE\\n2\\n3\\n' > a.txt && git add a.txt && printf 'ONE\\n2\\nTHREE\\n' > a.txt", in: "repo")

        let patches = try WorkspaceFiles.diff("a.txt", at: repo)
        XCTAssertEqual(Set(patches.keys), [.all, .staged, .unstaged])
        XCTAssertTrue(patches[.staged]!.contains("+ONE"))
        XCTAssertFalse(patches[.staged]!.contains("+THREE"))
        XCTAssertTrue(patches[.unstaged]!.contains("+THREE"))
        XCTAssertFalse(patches[.unstaged]!.contains("+ONE"))
        XCTAssertTrue(patches[.all]!.contains("+ONE") && patches[.all]!.contains("+THREE"))

        let staged = WorkspaceFiles.diffSides("a.txt", originalPath: nil, commit: nil, scope: .staged, at: repo)
        XCTAssertEqual(staged.old, "1\n2\n3\n")
        XCTAssertEqual(staged.new, "ONE\n2\n3\n")
        let unstaged = WorkspaceFiles.diffSides("a.txt", originalPath: nil, commit: nil, scope: .unstaged, at: repo)
        XCTAssertEqual(unstaged.old, "ONE\n2\n3\n")
        XCTAssertEqual(unstaged.new, "ONE\n2\nTHREE\n")
    }

    func testDiffBeforeTheFirstCommitComparesWithAnEmptyTree() throws {
        try sandbox.sh("git init -q -b main fresh")
        try sandbox.configure("fresh")
        try sandbox.sh("echo a > a.txt && git add a.txt && echo b > a.txt", in: "fresh")
        let patches = try WorkspaceFiles.diff("a.txt", at: sandbox.location("fresh"))
        XCTAssertEqual(Set(patches.keys), [.all, .staged, .unstaged])
        XCTAssertTrue(patches[.all]!.contains("+b"))
        XCTAssertFalse(patches[.all]!.contains("+a"))
    }

    /// An untracked file has no Git diff; the app builds one that adds every line.
    func testUntrackedFileDiffAddsEachLine() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.write(["new.txt": "x\ny\n", "partial.txt": "last"], in: "repo")

        let lines = ParsedDiff(try WorkspaceFiles.diff("new.txt", at: repo)[.all]!).files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.text), ["x", "y"])
        XCTAssertEqual(lines.map(\.newNumber), [1, 2])

        let partial = ParsedDiff(try WorkspaceFiles.diff("partial.txt", at: repo)[.all]!).files[0].hunks[0].lines
        XCTAssertEqual(partial.map(\.text), ["last"])
        XCTAssertTrue(partial[0].missingNewline)
    }

    // MARK: History

    func testRepositoryHistoryAndCommitFiles() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "one\n", "old name.txt": "same text\nfor rename\n"])
        try sandbox.sh("git mv 'old name.txt' 'new name.txt' && echo two >> a.txt && git commit -qam Second && git branch feature",
                       in: "repo")

        let listing = try WorkspaceFiles.repository(at: repo)
        XCTAssertEqual(listing.root, sandbox.path("repo"))
        XCTAssertEqual(listing.commits.map(\.subject), ["Second", "Initial"])
        XCTAssertEqual(listing.branches.map(\.name), ["feature", "main"])
        XCTAssertEqual(listing.branches.first { $0.isCurrent }?.name, "main")
        XCTAssertEqual(listing.worktrees.map(\.path), [sandbox.path("repo")])

        let head = listing.commits[0].id
        let files = try WorkspaceFiles.commitFiles(head, at: repo)
        XCTAssertEqual(files.map(\.path), ["a.txt", "new name.txt"])
        XCTAssertEqual(files.map(\.status), ["M", "R"])
        XCTAssertEqual(files[1].originalPath, "old name.txt")
        XCTAssertEqual(files[0].additions, 1)

        let rename = try WorkspaceFiles.commitDiff(head, path: "new name.txt", originalPath: "old name.txt", at: repo)
        XCTAssertTrue(rename.contains("rename from old name.txt"))
        let sides = WorkspaceFiles.diffSides("a.txt", originalPath: nil, commit: head, scope: .all, at: repo)
        XCTAssertEqual(sides.old, "one\n")
        XCTAssertEqual(sides.new, "one\ntwo\n")

        // The first commit has no parent: its files are all added.
        let root = listing.commits[1].id
        XCTAssertEqual(try WorkspaceFiles.commitFiles(root, at: repo).map(\.status), ["A", "A"])
        XCTAssertNil(WorkspaceFiles.diffSides("a.txt", originalPath: nil, commit: root, scope: .all, at: repo).old)

        XCTAssertThrowsError(try WorkspaceFiles.commitFiles("HEAD", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.commitDiff(head, path: "../a.txt", originalPath: nil, at: repo))
    }

    // MARK: Branches and worktrees

    func testSwitchBranch() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.sh("git branch feature", in: "repo")
        let branches = try WorkspaceFiles.repository(at: repo).branches
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        let main = try XCTUnwrap(branches.first { $0.name == "main" })

        XCTAssertThrowsError(try WorkspaceFiles.switchBranch(main, at: repo), "main is already current")
        try WorkspaceFiles.switchBranch(feature, at: repo)
        XCTAssertEqual(try WorkspaceFiles.branchStatus(at: repo).branch, "feature")
        let remote = WorkspaceBranch(id: "refs/remotes/origin/x", name: "origin/x", isRemote: true, isCurrent: false, upstream: "")
        XCTAssertThrowsError(try WorkspaceFiles.switchBranch(remote, at: repo))
    }

    func testWorktreesAreAddedAndOnlyCleanOnesRemoved() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.sh("git branch feature", in: "repo")
        let branches = try WorkspaceFiles.repository(at: repo).branches
        let feature = try XCTUnwrap(branches.first { $0.name == "feature" })
        let main = try XCTUnwrap(branches.first { $0.name == "main" })
        let remote = WorkspaceBranch(id: "refs/remotes/origin/main", name: "origin/main", isRemote: true, isCurrent: false, upstream: "")

        XCTAssertThrowsError(try WorkspaceFiles.addWorktree(at: repo, path: "relative", branch: feature, newBranch: nil))
        XCTAssertThrowsError(try WorkspaceFiles.addWorktree(at: repo, path: sandbox.path("r"), branch: remote, newBranch: nil))
        XCTAssertThrowsError(try WorkspaceFiles.addWorktree(at: repo, path: sandbox.path("x"), branch: main, newBranch: "-x"))

        let dirty = sandbox.path("dirty"), clean = sandbox.path("clean")
        try WorkspaceFiles.addWorktree(at: repo, path: dirty, branch: feature, newBranch: nil)
        try WorkspaceFiles.addWorktree(at: repo, path: clean, branch: main, newBranch: "topic")
        // Git lists linked worktrees in directory order, so compare without order.
        func worktreeBranches() throws -> [String: String?] {
            try WorkspaceFiles.repository(at: repo).worktrees.reduce(into: [:]) { $0.updateValue($1.branch, forKey: $1.path) }
        }
        XCTAssertEqual(try worktreeBranches(), [sandbox.path("repo"): "main", dirty: "feature", clean: "topic"])

        // Git's own check refuses to remove a worktree with changes or untracked files.
        try sandbox.sh("echo edit >> a.txt", in: "dirty")
        XCTAssertThrowsError(try WorkspaceFiles.removeWorktree(at: repo, path: dirty))
        try sandbox.sh("git checkout -q a.txt && echo new > untracked.txt", in: "dirty")
        XCTAssertThrowsError(try WorkspaceFiles.removeWorktree(at: repo, path: dirty))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty + "/untracked.txt"))

        try sandbox.sh("rm untracked.txt && git worktree lock .", in: "dirty")
        XCTAssertThrowsError(try WorkspaceFiles.removeWorktree(at: repo, path: dirty), "locked")
        XCTAssertThrowsError(try WorkspaceFiles.removeWorktree(at: repo, path: sandbox.path("repo")), "main worktree")
        XCTAssertThrowsError(try WorkspaceFiles.removeWorktree(at: repo, path: sandbox.path("unknown")))

        try WorkspaceFiles.removeWorktree(at: repo, path: clean)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean))
        XCTAssertEqual(try worktreeBranches(), [sandbox.path("repo"): "main", dirty: "feature"])
    }

    func testPublishPushFetchAndPullWithARemote() throws {
        try sandbox.sh("git init -q --bare -b main origin.git")
        let repo = try sandbox.repository("repo")
        try sandbox.sh("git remote add origin ../origin.git", in: "repo")

        var status = try WorkspaceFiles.branchStatus(at: repo)
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.upstream)
        XCTAssertEqual(status.remotes, ["origin"])

        XCTAssertThrowsError(try WorkspaceFiles.sync(.publish(remote: "--mirror", branch: "main"), at: repo))
        try WorkspaceFiles.sync(.publish(remote: "origin", branch: "main"), at: repo)
        XCTAssertEqual(try WorkspaceFiles.branchStatus(at: repo).upstream, "origin/main")

        try sandbox.sh("echo local >> a.txt && git commit -qam Local", in: "repo")
        XCTAssertEqual(try WorkspaceFiles.branchStatus(at: repo).ahead, 1)
        try WorkspaceFiles.sync(.push, at: repo)
        XCTAssertEqual(try WorkspaceFiles.branchStatus(at: repo).ahead, 0)

        try sandbox.sh("git clone -q origin.git other")
        try sandbox.configure("other")
        try sandbox.sh("echo other > b.txt && git add b.txt && git commit -qm Other && git push -q", in: "other")
        try WorkspaceFiles.sync(.fetch, at: repo)
        status = try WorkspaceFiles.branchStatus(at: repo)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.ahead, 0)

        try WorkspaceFiles.sync(.pull, at: repo)
        XCTAssertEqual(try WorkspaceFiles.branchStatus(at: repo).behind, 0)
        XCTAssertEqual(try sandbox.read("b.txt", in: "repo"), "other\n")
    }

    // MARK: Explorer file operations

    func testCreateRenameAndDeleteFilesAndFolders() throws {
        let repo = try sandbox.repository("repo")
        try WorkspaceFiles.createFile("docs/new/-note.md", at: repo)
        XCTAssertEqual(try sandbox.read("docs/new/-note.md", in: "repo"), "")
        XCTAssertThrowsError(try WorkspaceFiles.createFile("a.txt", at: repo)) {
            XCTAssertEqual($0.localizedDescription, "a.txt already exists")
        }
        try WorkspaceFiles.createFolder("empty", at: repo)
        XCTAssertThrowsError(try WorkspaceFiles.createFolder("empty", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.createFile("../outside.txt", at: repo))

        XCTAssertEqual(try WorkspaceFiles.renameItem("docs/new", to: "old", at: repo), "docs/old")
        XCTAssertEqual(try sandbox.read("docs/old/-note.md", in: "repo"), "")
        XCTAssertThrowsError(try WorkspaceFiles.renameItem("docs", to: "a.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.renameItem("docs", to: "x/y", at: repo))
        XCTAssertEqual(try WorkspaceFiles.renameItem("a.txt", to: "A.txt", at: repo), "A.txt")
        XCTAssertEqual(try sandbox.read("A.txt", in: "repo"), "one\n")

        try WorkspaceFiles.delete("docs", at: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/docs")))
        XCTAssertThrowsError(try WorkspaceFiles.delete("", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.delete("..", at: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("repo")))
    }

    func testFileOperationsStayInsideTheSpaceThroughLinkedFolders() throws {
        let repo = try sandbox.repository("repo")
        try sandbox.write(["outside/secret.txt": "s"], in: ".")
        try sandbox.sh("ln -s ../outside escape", in: "repo")
        let a = sandbox.path("repo/a.txt")

        XCTAssertThrowsError(try WorkspaceFiles.delete("escape/secret.txt", at: repo)) {
            XCTAssertEqual($0.localizedDescription, "Path is outside the selected Space")
        }
        XCTAssertThrowsError(try WorkspaceFiles.renameItem("escape/secret.txt", to: "s.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.moveItem("escape/secret.txt", to: "s.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.moveItem("a.txt", to: "escape/new/a.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.createFile("escape/new.txt", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.createFolder("escape/new", at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.paste([a], into: "escape", move: false, at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.paste([a], into: "escape", move: true, at: repo))
        XCTAssertEqual(try sandbox.read("outside/secret.txt", in: "."), "s")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("outside")), ["secret.txt"])
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n")

        // The link itself is an item of the Space.
        XCTAssertEqual(try WorkspaceFiles.renameItem("escape", to: "away", at: repo), "away")
        try WorkspaceFiles.delete("away", at: repo)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: sandbox.path("repo/away")))
        XCTAssertEqual(try sandbox.read("outside/secret.txt", in: "."), "s")
    }

    func testPasteCopiesWithFreeNamesAndMoves() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "dir/b.txt": "b\n", "out/c.txt": "c\n"])
        let a = sandbox.path("repo/a.txt")
        XCTAssertEqual(try WorkspaceFiles.paste([a], into: "", move: false, at: repo), ["a copy.txt"])
        XCTAssertEqual(try WorkspaceFiles.paste([a], into: "", move: false, at: repo), ["a copy 2.txt"])
        XCTAssertEqual(try WorkspaceFiles.paste([a, sandbox.path("repo/dir")], into: "out", move: false, at: repo),
                       ["out/a.txt", "out/dir"])
        XCTAssertEqual(try sandbox.read("out/dir/b.txt", in: "repo"), "b\n")
        XCTAssertEqual(try WorkspaceFiles.paste([sandbox.path("repo/dir")], into: "", move: false, at: repo), ["dir copy"])
    }

    func testMoveRefusesExistingNamesAndItsOwnSubfolders() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "dir/sub/b.txt": "b\n", "out/a.txt": "x\n"])
        XCTAssertThrowsError(try WorkspaceFiles.paste([sandbox.path("repo/a.txt")], into: "out", move: true, at: repo))
        XCTAssertThrowsError(try WorkspaceFiles.paste([sandbox.path("repo/dir")], into: "dir/sub", move: true, at: repo))
        XCTAssertEqual(try WorkspaceFiles.paste([sandbox.path("repo/dir")], into: "out", move: true, at: repo), ["out/dir"])
        XCTAssertEqual(try sandbox.read("out/dir/sub/b.txt", in: "repo"), "b\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/dir")))
        XCTAssertThrowsError(try WorkspaceFiles.paste(["relative"], into: "", move: false, at: repo))
    }

    func testIgnoreAppendsAnchoredPatternsOnce() throws {
        let repo = try sandbox.repository("repo", files: ["a.txt": "a\n", "sub/.gitignore": "*.log", "sub/b[1].txt": "b\n"])
        let space = sandbox.location("repo/sub")
        try WorkspaceFiles.ignore("b[1].txt", isDirectory: false, inExclude: false, at: space)
        try WorkspaceFiles.ignore("b[1].txt", isDirectory: false, inExclude: false, at: space)
        XCTAssertEqual(try sandbox.read("sub/.gitignore", in: "repo"), "*.log\n/b\\[1].txt\n")

        try WorkspaceFiles.ignore("cache", isDirectory: true, inExclude: true, at: space)
        XCTAssertTrue(try sandbox.read(".git/info/exclude", in: "repo").hasSuffix("\n/sub/cache/\n"))
        try sandbox.write(["sub/cache/x.bin": "x"], in: "repo")
        XCTAssertEqual(try changes(repo), ["sub/.gitignore": " M"])
    }

    func testPermalinkUsesTheUpstreamRemoteAndHead() throws {
        let repo = try sandbox.repository("repo", files: ["src/a b.swift": "a\n"])
        XCTAssertThrowsError(try WorkspaceFiles.permalink("src/a b.swift", at: repo))
        try sandbox.sh("git remote add origin git@github.com:owner/repo.git && git remote add fork https://gitlab.com/me/repo", in: "repo")
        let head = try sandbox.sh("git rev-parse HEAD", in: "repo").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try WorkspaceFiles.permalink("a b.swift", at: sandbox.location("repo/src")).absoluteString,
                       "https://github.com/owner/repo/blob/\(head)/src/a%20b.swift")
    }
}

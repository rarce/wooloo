import XCTest
@testable import xherdr

/// Parsing of Git's machine-readable output. The fixtures were recorded from git 2.x in a
/// disposable repository, with paths shortened.
final class WorkspaceGitParsingTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testStatusKeepsRenameSourceAndSortsByPath() {
        let changes = WorkspaceFiles.parseStatus(data("RM renamed.txt\0a.txt\0?? untracked.txt\0 D Gone.txt\0"))
        XCTAssertEqual(changes.map(\.path), ["Gone.txt", "renamed.txt", "untracked.txt"])

        let renamed = changes[1]
        XCTAssertEqual(renamed.originalPath, "a.txt")
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertEqual(renamed.stageState, .partial)

        XCTAssertEqual(changes[2].kind, .untracked)
        XCTAssertEqual(changes[2].stageState, .none)
        XCTAssertEqual(changes[0].kind, .deleted)
        XCTAssertNil(changes[0].originalPath)
    }

    func testStatusKindsAndStageStates() {
        func change(_ status: String) -> WorkspaceFileChange {
            let characters = Array(status)
            return WorkspaceFileChange(path: "f", indexStatus: characters[0], worktreeStatus: characters[1], originalPath: nil)
        }
        XCTAssertEqual(change("UU").kind, .conflicted)
        XCTAssertEqual(change("AA").kind, .conflicted)
        XCTAssertEqual(change("DD").kind, .conflicted)
        XCTAssertEqual(change("A ").kind, .added)
        XCTAssertEqual(change("A ").stageState, .all)
        XCTAssertEqual(change("AM").stageState, .partial)
        XCTAssertEqual(change(" M").kind, .modified)
        XCTAssertEqual(change(" M").stageState, .none)
        XCTAssertEqual(WorkspaceFileChange.StageState.all.merged(with: .none), .partial)
        XCTAssertEqual(WorkspaceFileChange.StageState.all.merged(with: .all), .all)
    }

    func testLogKeepsSubjectsWithSeparatorsAndSkipsBrokenRecords() {
        let log = "c8515cac533043d5a53ffb3db97350fece607f69\u{1f}c8515ca\u{1f}Second\u{1f}Test Author\u{1f}1700000100\u{1e}\n"
            + "2820993e40e3d9ba573ee5f7827bd7c33576e6b5\u{1f}2820993\u{1f}First: subject with | pipes\u{1f}Test Author\u{1f}1700000000\u{1e}\n"
            + "broken\u{1f}record\u{1e}\n"
        let commits = WorkspaceFiles.parseLog(data(log))
        XCTAssertEqual(commits.map(\.shortHash), ["c8515ca", "2820993"])
        XCTAssertEqual(commits[1].subject, "First: subject with | pipes")
        XCTAssertEqual(commits[1].author, "Test Author")
        XCTAssertEqual(commits[1].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(WorkspaceFiles.parseLog(Data()).isEmpty)
    }

    private func commit(at date: Date) -> WorkspaceCommit {
        WorkspaceCommit(id: "c8515cac533043d5a53ffb3db97350fece607f69", shortHash: "c8515ca",
                        subject: "Second", author: "Test Author", date: date)
    }

    func testHistoryRelativeDatesAreEnglishAndMeasuredFromNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func age(_ seconds: TimeInterval) -> String {
            commit(at: now.addingTimeInterval(-seconds)).relativeDate(relativeTo: now)
        }
        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(59), "just now")
        XCTAssertEqual(age(60), "1 minute ago")
        XCTAssertEqual(age(5 * 60), "5 minutes ago")
        XCTAssertEqual(age(3 * 3600), "3 hours ago")
        XCTAssertEqual(age(2 * 86400), "2 days ago")
        XCTAssertEqual(age(3 * 7 * 86400), "3 weeks ago")
        XCTAssertEqual(age(400 * 86400), "1 year ago")
        // A commit dated slightly ahead of this clock is not "just now".
        XCTAssertEqual(age(-30), "in 30 seconds")
    }

    func testHistoryRelativeDateGetterUsesTheCurrentTime() {
        XCTAssertEqual(commit(at: Date()).relativeDate, "just now")
        XCTAssertEqual(commit(at: Date().addingTimeInterval(-2 * 86400 - 60)).relativeDate, "2 days ago")
    }

    func testHistoryAbsoluteDateIsEnglishMediumDateAndShortTimeInTheLocalZone() throws {
        // Built in the machine's zone, so the wall-clock time is the same wherever the test runs.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 14, minute: 7)))
        let text = commit(at: date).absoluteDate
            .replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(text, "Mar 5, 2024 at 2:07 PM")
    }

    func testBranchesMarkCurrentRemoteAndUpstreamAndSkipRemoteHead() {
        let refs = "refs/heads/feature\0 \0\0\n"
            + "refs/heads/main\0*\0origin/main\0\n"
            + "refs/remotes/origin/HEAD\0 \0\0\n"
            + "refs/remotes/origin/main\0 \0\0\n"
        let branches = WorkspaceFiles.parseBranches(data(refs))
        XCTAssertEqual(branches.map(\.name), ["feature", "main", "origin/main"])
        XCTAssertEqual(branches.map(\.isCurrent), [false, true, false])
        XCTAssertEqual(branches.map(\.isRemote), [false, false, true])
        XCTAssertEqual(branches[1].upstream, "origin/main")
        XCTAssertEqual(branches[2].id, "refs/remotes/origin/main")
    }

    func testWorktreesReadEveryRecordAndFlag() {
        let porcelain = "worktree /repo\0HEAD c8515ca\0branch refs/heads/main\0\0"
            + "worktree /wt\0HEAD c8515ca\0branch refs/heads/feature\0locked\0\0"
            + "worktree /detached\0HEAD c8515ca\0detached\0prunable gitdir file points to non-existent location\0\0"
            + "worktree /bare.git\0bare\0\0"
        let worktrees = WorkspaceFiles.parseWorktrees(data(porcelain))
        XCTAssertEqual(worktrees.map(\.path), ["/repo", "/wt", "/detached", "/bare.git"])
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feature", nil, nil])
        XCTAssertEqual(worktrees.map(\.isLocked), [false, true, false, false])
        XCTAssertEqual(worktrees.map(\.isPrunable), [false, false, true, false])
        XCTAssertEqual(worktrees.map(\.isBare), [false, false, false, true])
    }

    func testCommitFilesJoinNameStatusAndNumstat() {
        let nameStatus = "M\0a.txt\0A\0blob.bin\0D\0dir/b.txt\0R100\0old name.txt\0new name.txt\0"
        let numstat = "2\t1\ta.txt\0-\t-\tblob.bin\u{0}0\t1\tdir/b.txt\u{0}0\t0\t\0old name.txt\0new name.txt\0"
        let files = WorkspaceFiles.parseCommitFiles(nameStatus: data(nameStatus), numstat: data(numstat))
        XCTAssertEqual(files.map(\.path), ["a.txt", "blob.bin", "dir/b.txt", "new name.txt"])
        XCTAssertEqual(files.map(\.status), ["M", "A", "D", "R"])
        XCTAssertEqual(files[3].originalPath, "old name.txt")
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
        // Binary files have no line counts.
        XCTAssertNil(files[1].additions)
        XCTAssertNil(files[1].deletions)
        XCTAssertEqual(files[3].additions, 0)
    }

    func testBranchStatusReadsUpstreamAndDivergence() {
        let status = "# branch.oid adc78ae9afe5c280b9f3e1cb2b36100de76386e6\n# branch.head main\n"
            + "# branch.upstream origin/main\n# branch.ab +1 -3\n"
            + "2 RM N... 100644 100644 100644 ddc897f ddc897f R100 renamed.txt\ta.txt\n"
        let parsed = WorkspaceFiles.parseBranchStatus(data(status), remotes: ["origin"])
        XCTAssertEqual(parsed.branch, "main")
        XCTAssertEqual(parsed.shortHead, "adc78ae")
        XCTAssertEqual(parsed.upstream, "origin/main")
        XCTAssertEqual(parsed.ahead, 1)
        XCTAssertEqual(parsed.behind, 3)
        XCTAssertEqual(parsed.remotes, ["origin"])
    }

    func testBranchStatusOfDetachedHeadHasNoBranch() {
        let status = "# branch.oid adc78ae9afe5c280b9f3e1cb2b36100de76386e6\n# branch.head (detached)\n"
        let parsed = WorkspaceFiles.parseBranchStatus(data(status), remotes: [])
        XCTAssertNil(parsed.branch)
        XCTAssertNil(parsed.upstream)
        XCTAssertEqual(parsed.ahead, 0)
    }

    func testRelativePathsMustStayInsideTheSpace() {
        for valid in ["a.txt", "dir/b.txt", ".hidden", "dir with space/ñ.txt", "a..b"] {
            XCTAssertNoThrow(try WorkspaceFiles.validateRelativePath(valid), valid)
        }
        for invalid in ["", "/etc/passwd", "../x", "a/../../b", "./a", "a/./b", "a//b", "a/"] {
            XCTAssertThrowsError(try WorkspaceFiles.validateRelativePath(invalid), invalid)
        }
    }

    func testCommitHashesMustBeHex() {
        for valid in ["abcd", "c8515ca", String(repeating: "f", count: 64)] {
            XCTAssertNoThrow(try WorkspaceFiles.validateCommit(valid), valid)
        }
        for invalid in ["abc", "HEAD", "-abcd", "c8515ca~1", String(repeating: "f", count: 65)] {
            XCTAssertThrowsError(try WorkspaceFiles.validateCommit(invalid), invalid)
        }
    }

    /// Shell quoting protects every command sent over SSH, so it must survive a real shell.
    func testQuotedValuesReachTheShellUnchanged() throws {
        for value in ["plain", "it's", "$(touch /tmp/xherdr-pwned) `id` $HOME", "a b\nc", "'", ""] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + WorkspaceFiles.quote(value)]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value)
        }
    }

    /// File versions are Git blob hashes, so a local save and a remote `git hash-object` agree.
    func testBlobHashMatchesGit() {
        XCTAssertEqual(WorkspaceFiles.gitBlobHash(data("hello\n")), "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertEqual(WorkspaceFiles.gitBlobHash(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }
}

/// Pure helpers behind the explorer's file operations.
final class WorkspaceFileOperationHelperTests: XCTestCase {
    func testPermalinkURLsForCommonHosts() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        func link(_ remote: String) -> String? {
            WorkspaceFiles.permalinkURL(remote: remote, commit: sha, path: "dir/a#1.swift")?.absoluteString
        }
        XCTAssertEqual(link("git@github.com:owner/repo.git"), "https://github.com/owner/repo/blob/\(sha)/dir/a%231.swift")
        XCTAssertEqual(link("ssh://git@github.com:22/owner/repo.git"), "https://github.com/owner/repo/blob/\(sha)/dir/a%231.swift")
        XCTAssertEqual(link("https://user:token@github.com/owner/repo/"), "https://github.com/owner/repo/blob/\(sha)/dir/a%231.swift")
        XCTAssertEqual(link("https://gitlab.com/group/sub/repo.git"), "https://gitlab.com/group/sub/repo/-/blob/\(sha)/dir/a%231.swift")
        XCTAssertEqual(link("git@bitbucket.org:team/repo.git"), "https://bitbucket.org/team/repo/src/\(sha)/dir/a%231.swift")
        XCTAssertNil(link("../origin.git"))
        XCTAssertNil(link("/srv/git/repo.git"))
        XCTAssertNil(WorkspaceFiles.permalinkURL(remote: "git@github.com:o/r", commit: "HEAD", path: "a"))
    }

    func testIgnorePatternsMatchOnlyThePath() {
        XCTAssertEqual(WorkspaceFiles.ignorePattern("build", isDirectory: true), "/build/")
        XCTAssertEqual(WorkspaceFiles.ignorePattern("#notes!.md", isDirectory: false), "/#notes!.md")
        XCTAssertEqual(WorkspaceFiles.ignorePattern("a*b?[c]\\d", isDirectory: false), "/a\\*b\\?\\[c]\\\\d")
        XCTAssertEqual(WorkspaceFiles.ignorePattern("trailing  ", isDirectory: false), "/trailing\\ \\ ")
    }

    func testCopyNamesKeepTheExtension() {
        XCTAssertEqual(Array(WorkspaceFiles.copyNames(for: "a.txt", includingOriginal: true).prefix(3)),
                       ["a.txt", "a copy.txt", "a copy 2.txt"])
        XCTAssertEqual(Array(WorkspaceFiles.copyNames(for: ".env", includingOriginal: false).prefix(2)),
                       [".env copy", ".env copy 2"])
        XCTAssertEqual(WorkspaceFiles.copyNames(for: "Makefile", includingOriginal: false).first, "Makefile copy")
    }

    func testFileShortcutsMatchTheirKeysOnly() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        func commands(_ event: NSEvent) -> [ExplorerFileCommand] {
            ExplorerFileCommand.allCases.filter { $0.matches(event) }
        }
        XCTAssertEqual(commands(try key("c", .command)), [.copy])
        XCTAssertEqual(commands(try key("c", [.command, .option])), [.copyPath])
        XCTAssertEqual(commands(try key("C", [.command, .option, .shift])), [.copyRelativePath])
        XCTAssertEqual(commands(try key("n", [.command, .option])), [.newFolder])
        XCTAssertEqual(commands(try key("\u{7f}", code: 51)), [.trashAsking])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSDeleteFunctionKey)!), .function, code: 117)), [.trashAsking])
        XCTAssertEqual(commands(try key("\u{7f}", .command, code: 51)), [.trash])
        XCTAssertEqual(commands(try key("\u{7f}", [.command, .option], code: 51)), [.delete])
        XCTAssertEqual(commands(try key("\r", [.control, .shift], code: 36)), [.openInDefaultApp])
        XCTAssertEqual(commands(try key("\r", code: 36)), [.rename])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSF2FunctionKey)!), .function, code: 120)), [.rename])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), [.function, .numericPad], code: 125)),
                       [.selectNext])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .function], code: 125)),
                       [.open])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .function], code: 123)),
                       [.collapseAll])
        XCTAssertEqual(commands(try key(" ", code: 49)), [.openPreview])
        XCTAssertEqual(commands(try key("\u{1b}", code: 53)), [.deselect])
        XCTAssertEqual(commands(try key("F", [.command, .option, .shift], code: 3)), [.findInFolder])
        XCTAssertEqual(commands(try key(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.shift, .function], code: 126)),
                       [.extendPrevious])
        XCTAssertEqual(commands(try key("c")), [])
        XCTAssertEqual(commands(try key("c", [.command, .control])), [])

        let shortcuts = ExplorerFileCommand.allCases.map { "\($0.shortcut.key.character)|\($0.shortcut.modifiers.rawValue)" }
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
    }

    func testEmptyFoldersAppearInTheTree() {
        let rows = WorkspaceTree(paths: ["a.txt", "src/main.swift"], directories: ["empty", "src/new"])
            .visibleRows(expanded: ["s|src"], identity: "s")
        XCTAssertEqual(rows.map(\.node.path), ["empty", "src", "src/new", "src/main.swift", "a.txt"])
        XCTAssertEqual(rows.map(\.node.isDirectory), [true, true, true, false, false])
    }
}

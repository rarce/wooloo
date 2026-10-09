import XCTest
@testable import wooloo

/// The SSH paths of `WorkspaceFiles`. A fake `ssh` records its arguments, prints the warning
/// OpenSSH 10 writes to stderr, and runs the remote command with the local shell, so the
/// scripts sent to a remote machine run as they would there.
final class WorkspaceFilesRemoteTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private let machine = HerdrMachineProfile(id: "dev", label: "Dev box", target: "ssh://dev@example.test:2222",
                                              session: "default", enabled: true)
    private static let warning = "** WARNING: connection is not using a post-quantum key exchange algorithm."

    override func setUpWithError() throws {
        sandbox = try WorkspaceGitSandbox()
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            printf '%s\\0' "$@" >> '\(sandbox.path("ssh.log"))'
            printf '\\036' >> '\(sandbox.path("ssh.log"))'
            echo '\(Self.warning)' >&2
            [ -e '\(sandbox.path("slow"))' ] && sleep 0.4
            for command; do :; done
            [ -d '\(sandbox.path("shims"))' ] && PATH='\(sandbox.path("shims"))':$PATH && export PATH
            cd '\(sandbox.base)'
            exec /bin/sh -c "$command"
            """], in: ".")
        try sandbox.sh("chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
    }

    override func tearDown() {
        WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
        sandbox.tearDown()
    }

    private func remote(_ name: String, machine: HerdrMachineProfile? = nil) -> WorkspaceFileLocation {
        WorkspaceFileLocation(machine: machine ?? self.machine, session: "default", workspaceID: name,
                              workspaceLabel: name, root: sandbox.path(name))
    }

    /// Arguments of each ssh invocation, oldest first.
    private func invocations() throws -> [[String]] {
        let log = (try? String(contentsOfFile: sandbox.path("ssh.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\u{1e}").map { $0.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
    }

    func testSSHArgumentsAndTargets() throws {
        try sandbox.repository("repo")
        _ = try WorkspaceFiles.listing(at: remote("repo"))
        let arguments = try XCTUnwrap(try invocations().last)
        XCTAssertEqual(Array(arguments.prefix(5)), ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/wooloo-ssh-\(getuid())/%C"))
        XCTAssertEqual(Array(arguments.dropLast().suffix(3)), ["-p", "2222", "dev@example.test"])

        let plain = HerdrMachineProfile(id: "p", label: "Plain", target: "plain-host", session: "default", enabled: true)
        _ = try WorkspaceFiles.listing(at: remote("repo", machine: plain))
        let plainArguments = try XCTUnwrap(try invocations().last)
        XCTAssertEqual(plainArguments.dropLast().last, "plain-host")
        XCTAssertFalse(plainArguments.contains("-p"))

        let count = try invocations().count
        let hostile = HerdrMachineProfile(id: "h", label: "Hostile", target: "-oProxyCommand=touch /tmp/x",
                                          session: "default", enabled: true)
        XCTAssertThrowsError(try WorkspaceFiles.read("a.txt", at: remote("repo", machine: hostile)))
        XCTAssertEqual(try invocations().count, count, "ssh must not run with an option as its target")
    }

    /// Whatever ssh prints on stderr must never become part of a file or a listing.
    func testReadingOverSSHKeepsStderrOutOfTheContents() throws {
        try sandbox.repository("repo", files: ["a.txt": "one\n", "b.txt": "two\n"])
        let file = try WorkspaceFiles.read("a.txt", at: remote("repo"))
        XCTAssertEqual(file.text, "one\n")
        XCTAssertEqual(file.version, WorkspaceFiles.gitBlobHash(Data("one\n".utf8)))
        XCTAssertEqual(try WorkspaceFiles.listing(at: remote("repo")).files, ["a.txt", "b.txt"])
        XCTAssertEqual(try WorkspaceFiles.repository(at: remote("repo")).commits.map(\.subject), ["Initial"])
    }

    func testRemoteSaveReplacesTheFileOnlyWhenUnchanged() throws {
        try sandbox.repository("repo", files: ["it's here.txt": "one\n"])
        try sandbox.sh("chmod 640 \"it's here.txt\"", in: "repo")
        let location = remote("repo")
        let file = try WorkspaceFiles.read("it's here.txt", at: location)

        let version = try WorkspaceFiles.save("two\n", path: "it's here.txt", expectedVersion: file.version, at: location)
        XCTAssertEqual(version, WorkspaceFiles.gitBlobHash(Data("two\n".utf8)))
        XCTAssertEqual(try sandbox.read("it's here.txt", in: "repo"), "two\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.path("repo/it's here.txt"))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path("repo")).filter { $0.contains(".wooloo.") }
        XCTAssertEqual(leftovers, [])

        XCTAssertThrowsError(try WorkspaceFiles.save("three\n", path: "it's here.txt", expectedVersion: file.version, at: location)) {
            XCTAssertTrue($0.localizedDescription.contains("File changed on disk"), $0.localizedDescription)
        }
        XCTAssertEqual(try sandbox.read("it's here.txt", in: "repo"), "two\n")
        XCTAssertThrowsError(try WorkspaceFiles.save("x", path: "it's here.txt", expectedVersion: "'; rm -rf /; '", at: location)) {
            XCTAssertEqual($0.localizedDescription, "Invalid file version")
        }
    }

    func testRemoteReadRefusesFilesOutsideTheSpace() throws {
        try sandbox.repository("repo")
        try sandbox.write(["secret.txt": "secret\n"], in: ".")
        try sandbox.sh("ln -s ../secret.txt escape.txt && mkdir dir", in: "repo")
        let location = remote("repo")
        for path in ["escape.txt", "dir", "missing.txt", "../secret.txt", "/etc/hosts"] {
            XCTAssertThrowsError(try WorkspaceFiles.read(path, at: location), path)
        }
        XCTAssertThrowsError(try WorkspaceFiles.readData("a.txt", at: location, limit: 2)) {
            XCTAssertTrue($0.localizedDescription.contains("File is too large"), $0.localizedDescription)
        }
    }

    func testRemoteWalkWithoutGitMatchesTheLocalOne() throws {
        let depth = WorkspaceFiles.folderWalkMaximumDepth
        let chain = (1..<depth).map { "d\($0)" }.joined(separator: "/")
        try sandbox.write(["a b.txt": "x\n", "d1/b.txt": "x\n", "\(chain)/last.txt": "x\n",
                           "\(chain)/d\(depth)/too-deep.txt": "x\n", "node_modules/pkg/index.js": "x\n",
                           "app/.build/out.o": "x\n", ".git/HEAD": "x\n", "it's\nodd.txt": "x\n"], in: "loose")
        try sandbox.sh("ln -s d1 loose/alias")
        try sandbox.write(["c.txt": "x\n", "sub/d.txt": "x\n"], in: "small")
        try sandbox.sh("mkdir -p small/\(chain)/d\(depth) small/\(chain)/node_modules/x")
        var wide = ["top.txt": "x\n"]
        for index in 0..<300 { wide["w\(index)/f.txt"] = "x\n" }
        try sandbox.write(wide, in: "wide")

        for name in ["loose", "small", "wide"] {
            for includeIgnored in [false, true] {
                XCTAssertEqual(try WorkspaceFiles.quickOpenFiles(at: remote(name), includeIgnored: includeIgnored),
                               try WorkspaceFiles.quickOpenFiles(at: sandbox.location(name), includeIgnored: includeIgnored),
                               "\(name), ignored: \(includeIgnored)")
            }
            WorkspaceFiles.forgetRecentResults()
            let remoteListing = try WorkspaceFiles.listing(at: remote(name))
            let localListing = try WorkspaceFiles.listing(at: sandbox.location(name))
            XCTAssertEqual(remoteListing.files, localListing.files, name)
            XCTAssertEqual(remoteListing.ignored, localListing.ignored, name)
            XCTAssertEqual(remoteListing.symbolicLinks, localListing.symbolicLinks, name)
            XCTAssertEqual(remoteListing.partial, localListing.partial, name)
        }
        let loose = try WorkspaceFiles.quickOpenFiles(at: remote("loose"), includeIgnored: true)
        XCTAssertEqual(loose.files, ["a b.txt", "alias", "app/.build/out.o", "d1/b.txt", "\(chain)/last.txt",
                                     "it's\nodd.txt", "node_modules/pkg/index.js"])
        XCTAssertEqual(loose.ignored, ["app/.build/out.o", "node_modules/pkg/index.js"])
        XCTAssertTrue(loose.partial)
        XCTAssertFalse(try WorkspaceFiles.quickOpenFiles(at: remote("small")).partial,
                       "Empty or skipped folders at the depth limit leave nothing unread")
        XCTAssertEqual(try WorkspaceFiles.quickOpenFiles(at: remote("wide")).files.count, 301,
                       "A level read in several batches is read in full")
        WorkspaceFiles.forgetRecentResults()
        let listing = try WorkspaceFiles.listing(at: remote("loose"))
        XCTAssertEqual(listing.ignored.directories, ["app/.build", "node_modules"])
        XCTAssertEqual(listing.symbolicLinks["alias"], WorkspaceSymbolicLink(target: "d1", isDirectory: true))
        XCTAssertTrue(listing.partial)
    }

    /// A level stopped by the time limit ends the walk with what earlier levels found.
    func testRemoteWalkStopsAtItsTimeBudgetWithoutFailing() throws {
        defer { WorkspaceFiles.folderWalkBudget = 2 }
        var files = ["top.txt": "x\n"]
        for index in 0..<300 { files["w\(index)/nested/f.txt"] = "x\n" }
        try sandbox.write(files, in: "wide")
        WorkspaceFiles.folderWalkBudget = 0
        let timed = try WorkspaceFiles.quickOpenFiles(at: remote("wide"))
        XCTAssertEqual(timed.files, ["top.txt"], "Only the root is read once the time is up")
        XCTAssertTrue(timed.partial)
        WorkspaceFiles.forgetRecentResults()
        let listing = try WorkspaceFiles.listing(at: remote("wide"))
        XCTAssertEqual(listing.files, ["top.txt"])
        XCTAssertTrue(listing.partial)
    }

    /// Both walks outside Git follow one specification (above `WorkspaceFiles.folderWalkScript`);
    /// on folders with every kind of entry they must find the same files.
    func testRemoteAndLocalWalksAgreeOnEveryKindOfEntry() throws {
        let depth = WorkspaceFiles.folderWalkMaximumDepth
        let chain = (1...depth).map { "d\($0)" }.joined(separator: "/")
        try sandbox.write(["top.txt": "x\n", "-dash.txt": "x\n", "back\\slash.txt": "x\n", "star*.txt": "x\n",
                           "quote\"s 'and' $vars.txt": "x\n", "tab\tname.txt": "x\n", "naïve/über.txt": "x\n",
                           "wooloo-partial": "x\n", "sub/wooloo-partial": "x\n", "sub/wooloo-symbolic-links": "x\n",
                           ".hidden/inner.txt": "x\n", "sub/.git/config": "x\n", "lib/node_modules": "file\n",
                           "a/b/__pycache__/x.pyc": "x\n", "a/b/c.py": "x\n", ".venv/bin/python": "x\n",
                           "DerivedData/Build/x.o": "x\n", "locked/inner.txt": "x\n", "locked-deep/x/inner.txt": "x\n",
                           "new\nline/node_modules/x.js": "x\n", "new\nline/f.txt": "x\n",
                           "\(chain)/node_modules/pkg/i.js": "x\n"], in: "rich")
        try sandbox.sh("""
            mkdir empty empty-parent empty-parent/empty && mkfifo pipe sub/pipe \
            && ln -s missing broken && ln -s wooloo-partial to-marker && ln -s sub alias && ln -s ../a lib/up && ln -s ../sub lib/__pycache__ \
            && chmod 000 locked locked-deep/x
            """, in: "rich")
        defer { _ = try? sandbox.sh("chmod 755 locked locked-deep/x", in: "rich") }
        try sandbox.write(["only.txt": "x\n", "\(chain)/.git/HEAD": "x\n", "\(chain)/node_modules/a.js": "x\n"],
                          in: "limit")

        for name in ["rich", "limit"] {
            for includeIgnored in [false, true] {
                let local = try WorkspaceFiles.quickOpenFiles(at: sandbox.location(name), includeIgnored: includeIgnored)
                XCTAssertEqual(try WorkspaceFiles.quickOpenFiles(at: remote(name), includeIgnored: includeIgnored), local,
                               "\(name), ignored: \(includeIgnored)")
            }
            WorkspaceFiles.forgetRecentResults()
            let remoteListing = try WorkspaceFiles.listing(at: remote(name))
            let localListing = try WorkspaceFiles.listing(at: sandbox.location(name))
            XCTAssertEqual(remoteListing.files, localListing.files, name)
            XCTAssertEqual(remoteListing.ignored, localListing.ignored, name)
            XCTAssertEqual(remoteListing.symbolicLinks, localListing.symbolicLinks, name)
            XCTAssertEqual(remoteListing.partial, localListing.partial, name)
        }
        let rich = try WorkspaceFiles.quickOpenFiles(at: remote("rich"))
        XCTAssertEqual(rich.files, ["-dash.txt", ".hidden/inner.txt", "a/b/c.py", "alias", "back\\slash.txt", "broken",
                                    "lib/__pycache__", "lib/node_modules", "lib/up", "naïve/über.txt", "new\nline/f.txt",
                                    "quote\"s 'and' $vars.txt", "star*.txt", "sub/wooloo-partial",
                                    "sub/wooloo-symbolic-links", "tab\tname.txt", "to-marker", "top.txt", "wooloo-partial"])
        XCTAssertFalse(rich.partial, "Only skipped folders are at the depth limit")
        XCTAssertEqual(try WorkspaceFiles.listing(at: remote("rich")).ignored.directories,
                       [".venv", "DerivedData", "a/b/__pycache__", "new\nline/node_modules"],
                       "A folder at the depth limit is not read")
        XCTAssertEqual(try WorkspaceFiles.listing(at: remote("rich")).symbolicLinks["to-marker"]?.target, "wooloo-partial")
        XCTAssertTrue(try WorkspaceFiles.quickOpenFiles(at: remote("rich"), includeIgnored: true).partial,
                      "Read, the skipped folder at the depth limit has something unread")
        XCTAssertFalse(try WorkspaceFiles.quickOpenFiles(at: remote("limit")).partial)
    }

    /// Over SSH, one folder too large to read in time is stopped inside its `find`, here a
    /// stand-in that prints two names and part of a third and then hangs. The names it printed
    /// whole are kept and the cut one is dropped.
    func testRemoteWalkStopsInsideAHugeFolderAtItsTimeBudget() throws {
        defer { WorkspaceFiles.folderWalkBudget = 2 }
        try sandbox.write(["top.txt": "x\n", "big/real.txt": "x\n", "other/o.txt": "x\n"], in: "huge")
        try sandbox.write(["shims/find": """
            #!/bin/sh
            case " $* " in
            *" ./big "*" -type f "*) printf './big/a\\0./big/b\\0./big/cu'; exec sleep 30;;
            esac
            exec /usr/bin/find "$@"
            """], in: ".")
        try sandbox.sh("chmod 755 shims/find")
        WorkspaceFiles.folderWalkBudget = 1
        let started = Date()
        let walk = try WorkspaceFiles.quickOpenFiles(at: remote("huge"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "The walk stops at its time limit, not at the SSH timeout")
        XCTAssertTrue(walk.files.contains("top.txt"), "The root is read in full")
        XCTAssertTrue(walk.files.contains("big/a") && walk.files.contains("big/b"), "\(walk.files)")
        XCTAssertFalse(walk.files.contains { $0.hasPrefix("big/c") }, "The name cut short is dropped: \(walk.files)")
        XCTAssertTrue(walk.partial)

        WorkspaceFiles.forgetRecentResults()
        let listing = try WorkspaceFiles.listing(at: remote("huge"))
        XCTAssertTrue(listing.files.contains("big/b"))
        XCTAssertFalse(listing.files.contains { $0.hasPrefix("big/c") })
        XCTAssertTrue(listing.partial)
    }

    /// The watchdog can also stop the `find` of skipped folders: those it printed whole are kept,
    /// and nothing it started prints after the walk.
    func testRemoteWalkStoppedWhileListingSkippedFoldersKeepsTheWholeOnes() throws {
        defer { WorkspaceFiles.folderWalkBudget = 2 }
        try sandbox.write(["top.txt": "x\n", "big/real.txt": "x\n", "big/node_modules/m.js": "x\n"], in: "huge")
        try sandbox.write(["shims/find": """
            #!/bin/sh
            case " $* " in
            *" ./big "*" ( -name node_modules "*) printf './big/node_modules\\0./big/.ven'; exec sleep 30;;
            esac
            exec /usr/bin/find "$@"
            """], in: ".")
        try sandbox.sh("chmod 755 shims/find")
        WorkspaceFiles.folderWalkBudget = 1
        let started = Date()
        let listing = try WorkspaceFiles.listing(at: remote("huge"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(listing.files, ["big/real.txt", "top.txt"])
        XCTAssertEqual(listing.ignored.directories, ["big/node_modules"])
        XCTAssertTrue(listing.partial)
    }

    func testWalkRecordsDropOnlyANameCutShortByTheTimeLimit() {
        func records(_ text: String) -> [String] { WorkspaceFiles.folderWalkRecords(Data(text.utf8)) }
        XCTAssertEqual(records("./a\0./b\0\0wooloo-partial\0"), ["./a", "./b", "wooloo-partial"])
        XCTAssertEqual(records("./a\0./b/cu\0wooloo-partial\0\0wooloo-partial\0"), ["./a", "wooloo-partial", "wooloo-partial"])
        XCTAssertEqual(records("./a\0./node_mod\0wooloo-partial\0"), ["./a", "wooloo-partial"])
        var invalid = Data("./a\0./b".utf8)
        invalid.append(contentsOf: [0xE2, 0x82])
        invalid.append(contentsOf: Data("\0wooloo-partial\0".utf8))
        XCTAssertEqual(WorkspaceFiles.folderWalkRecords(invalid), ["./a", "wooloo-partial"],
                       "A name cut inside a character is not UTF-8 and left out")

        let walk = WorkspaceFiles.folderWalk(scriptOutput: Data(
            "./a\0wooloo-skipped\0./node_modules\0./b/.venv\0wooloo-files\0./c\0wooloo-skipped\0./d/__pyc\0wooloo-partial\0".utf8
        ), readingSkipped: false)
        XCTAssertEqual(walk.files, ["a", "c"])
        XCTAssertEqual(walk.skippedFolders, ["b/.venv", "node_modules"])
        XCTAssertTrue(walk.partial)
    }

    /// Link metadata follows the walk's records as printed: a link or target named like a marker,
    /// or a target that is not UTF-8, is not taken for one.
    func testWalkSectionsKeepLinkMetadataAsPrinted() {
        let metadata = Data("to-marker\0wooloo-partial\0f\0odd\0".utf8) + [0xFF] + Data("\0f\0".utf8)
        let sections = WorkspaceFiles.folderWalkSections(
            Data("./a\0./to-marker\0\0wooloo-partial\0wooloo-symbolic-links\0".utf8) + metadata)
        XCTAssertEqual(sections.records, ["./a", "./to-marker", "wooloo-partial"])
        XCTAssertEqual(sections.linkMetadata, metadata)
        XCTAssertEqual(WorkspaceFiles.folderWalkSections(Data("./a\0".utf8)).records, ["./a"])
        XCTAssertEqual(WorkspaceFiles.folderWalkSections(Data("./a\0wooloo-symbolic-links".utf8)).linkMetadata, Data())
    }

    func testRemoteIgnoredFoldersAreListedAndRead() throws {
        try sandbox.repository("repo", files: [".gitignore": "build/\n"])
        try sandbox.write(["build/out/app": "a", "build/.hidden": "h", "build/it's here.o": "o"], in: "repo")
        try sandbox.sh("ln -s out build/latest", in: "repo")
        let location = remote("repo")
        XCTAssertEqual(try WorkspaceFiles.listing(at: location).ignored.directories, ["build"])
        let contents = try WorkspaceFiles.folderContents("build", at: location)
        XCTAssertEqual(contents.directories.sorted(), ["build/latest", "build/out"])
        XCTAssertEqual(contents.files.sorted(), ["build/.hidden", "build/it's here.o"])
        XCTAssertEqual(contents.symbolicLinks["build/latest"], WorkspaceSymbolicLink(target: "out", isDirectory: true))
        XCTAssertEqual(try WorkspaceFiles.folderContents("build/latest", at: location).files, ["build/latest/app"])
        XCTAssertEqual(try WorkspaceFiles.folderContents("build/out", at: location).files, ["build/out/app"])
        try sandbox.sh("ln -s .. up", in: "repo/build")
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("../..", at: location))
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("build/up/..", at: location))
    }

    func testRemoteListingShowsNestedRepositoriesAsFolders() throws {
        try sandbox.repository("repo", files: ["a.txt": "one\n", ".gitignore": "ignored/\n"])
        try sandbox.write(["nested repo/f.txt": "f\n", "ignored/inner/g.txt": "g\n"], in: "repo")
        try sandbox.sh("git init -q 'nested repo' && git init -q ignored/inner && git init -q ünï"
                       + " && mkdir -p .claude/worktrees && git worktree add -q -b feature '.claude/worktrees/feature x'",
                       in: "repo")
        let listing = try WorkspaceFiles.listing(at: remote("repo"))
        let local = try WorkspaceFiles.listing(at: sandbox.location("repo"))
        XCTAssertEqual(listing.files, [".gitignore", "a.txt"])
        XCTAssertEqual(listing.nestedRepositories, [".claude/worktrees/feature x", "nested repo", "ünï"])
        XCTAssertEqual(listing.nestedRepositories, local.nestedRepositories)
        XCTAssertEqual(listing.ignored, local.ignored)
        XCTAssertEqual(listing.symbolicLinks, local.symbolicLinks)
        XCTAssertEqual(listing.changes.map(\.path), local.changes.map(\.path))
        XCTAssertEqual(try WorkspaceFiles.folderContents("nested repo", at: remote("repo")).files, ["nested repo/f.txt"])
        for includeIgnored in [false, true] {
            XCTAssertEqual(try WorkspaceFiles.quickOpenFiles(at: remote("repo"), includeIgnored: includeIgnored),
                           try WorkspaceFiles.quickOpenFiles(at: sandbox.location("repo"), includeIgnored: includeIgnored))
            XCTAssertEqual(try WorkspaceFiles.quickOpenFiles(at: remote("repo"), includeIgnored: includeIgnored)
                .files.filter { $0.hasSuffix("/") }, [])
        }
    }

    func testRemoteFolderWithoutGitIsListedWithFind() throws {
        try sandbox.write(["plain/a.txt": "a", "plain/sub/c.txt": "c", "plain/.git/config": "not a repo"], in: ".")
        try sandbox.sh("ln -s sub alias && ln -s missing broken", in: "plain")
        let listing = try WorkspaceFiles.listing(at: remote("plain"))
        XCTAssertFalse(listing.hasGit)
        XCTAssertEqual(listing.files, ["a.txt", "alias", "broken", "sub/c.txt"])
        XCTAssertEqual(listing.symbolicLinks["alias"], WorkspaceSymbolicLink(target: "sub", isDirectory: true))
    }

    func testRemoteLinksPreserveNamesTargetsAndSaveTheTarget() throws {
        try sandbox.repository("repo", files: ["dir/a.txt": "a\n", "-target\n.txt": "t\n"])
        try sandbox.write(["outside/file.txt": "external\n"], in: ".")
        try sandbox.sh("ln -s dir alias && ln -s ../outside external && ln -s missing broken && ln -s . loop", in: "repo")
        let name = "-$(touch pwned) it's\nlink"
        let target = "-target\n.txt"
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("repo/" + name), withDestinationPath: target)
        let location = remote("repo")
        let listing = try WorkspaceFiles.listing(at: location)
        XCTAssertEqual(listing.symbolicLinks[name], WorkspaceSymbolicLink(target: target, isDirectory: false))
        XCTAssertEqual(listing.symbolicLinks["broken"], WorkspaceSymbolicLink(target: "missing", isDirectory: false))
        XCTAssertEqual(listing.symbolicLinks["alias"], WorkspaceSymbolicLink(target: "dir", isDirectory: true))
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("external", at: location))
        XCTAssertThrowsError(try WorkspaceFiles.read("external/file.txt", at: location))
        XCTAssertThrowsError(try WorkspaceFiles.save("escape", path: "external/file.txt",
                                                    expectedVersion: WorkspaceFiles.gitBlobHash(Data("external\n".utf8)), at: location))
        XCTAssertEqual(try sandbox.read("outside/file.txt", in: "."), "external\n")
        XCTAssertThrowsError(try WorkspaceFiles.folderContents("loop", at: location))
        for path in [name, "alias/a.txt"] {
            let file = try WorkspaceFiles.read(path, at: location)
            _ = try WorkspaceFiles.save("new\n", path: path, expectedVersion: file.version, at: location)
            XCTAssertEqual(try WorkspaceFiles.read(path, at: location).text, "new\n")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.path("repo/" + name)), target)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.path("repo/external")), "../outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/pwned")))
        XCTAssertThrowsError(try WorkspaceFiles.read("broken", at: location))
    }

    /// Commit messages travel on stdin and paths as quoted words, so neither reaches the shell as code.
    /// The fake ssh starts in the sandbox, so an injected `touch pwned` would create it there.
    func testRemoteGitOperationsQuoteTheirArguments() throws {
        try sandbox.repository("repo")
        let location = remote("repo")
        let marker = sandbox.path("pwned")
        try sandbox.write(["$(touch pwned) it's.txt": "x\n"], in: "repo")
        try WorkspaceFiles.stage("$(touch pwned) it's.txt", at: location)
        let message = "Add '$(touch pwned)' and \"`touch pwned`\""
        try WorkspaceFiles.commit(message: message, mode: .staged, at: location)
        XCTAssertEqual(try WorkspaceFiles.repository(at: location).commits.first?.subject, message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))

        try sandbox.sh("echo more >> a.txt && git add a.txt && echo again >> a.txt", in: "repo")
        let patches = try WorkspaceFiles.diff("a.txt", at: location)
        XCTAssertEqual(Set(patches.keys), [.all, .staged, .unstaged])
        XCTAssertFalse(patches[.all]!.contains("WARNING"))
    }

    func testRemoteFileOperationsRunOverSSH() throws {
        try sandbox.repository("repo")
        let repo = remote("repo")
        try WorkspaceFiles.createFile("it's/new.txt", at: repo)
        XCTAssertEqual(try WorkspaceFiles.renameItem("it's/new.txt", to: "-renamed.txt", at: repo), "it's/-renamed.txt")
        XCTAssertEqual(try WorkspaceFiles.paste([sandbox.path("repo/a.txt")], into: "it's", move: false, at: repo),
                       ["it's/a.txt"])
        XCTAssertEqual(try sandbox.read("it's/a.txt", in: "repo"), "one\n")
        try WorkspaceFiles.moveItem("it's/a.txt", to: "back/-a.txt", at: repo)
        XCTAssertEqual(try sandbox.read("back/-a.txt", in: "repo"), "one\n")
        XCTAssertThrowsError(try WorkspaceFiles.moveItem("back/-a.txt", to: "a.txt", at: repo), "a.txt is in the way")
        try WorkspaceFiles.delete("it's", at: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/it's")))
        XCTAssertThrowsError(try WorkspaceFiles.trash("a.txt", at: repo))
    }

    @MainActor
    func testRemotePDFReadsBinaryBytesWithSpaceBoundariesAndSizeLimits() throws {
        try sandbox.repository("repo")
        let bytes = try PDFFixtures.data()
        let path = "it's a preview.PDF"
        try bytes.write(to: URL(fileURLWithPath: sandbox.path("repo/" + path)))
        let contents = try WorkspacePDF.read(path, at: remote("repo"))
        XCTAssertEqual(contents.document.pageCount, 3)
        XCTAssertEqual(contents.version, WorkspaceFiles.gitBlobHash(bytes))
        XCTAssertEqual(try WorkspaceFiles.readData(path, at: remote("repo"), limit: bytes.count), bytes)
        XCTAssertThrowsError(try WorkspaceFiles.readData(path, at: remote("repo"), limit: bytes.count - 1))
        XCTAssertThrowsError(try WorkspacePDF.read("../repo/" + path, at: remote("repo")))
        try bytes.write(to: URL(fileURLWithPath: sandbox.path("outside.pdf")))
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("repo/link.pdf"),
                                                   withDestinationPath: sandbox.path("outside.pdf"))
        XCTAssertThrowsError(try WorkspacePDF.read("link.pdf", at: remote("repo")))
    }

    func testRemoteImagePreviewDecodesBinaryBytesAndRejectsEscapingPaths() throws {
        try sandbox.repository("repo")
        let bytes = try ImageFixtures.data()
        let path = "it's a preview.PNG"
        try bytes.write(to: URL(fileURLWithPath: sandbox.path("repo/" + path)))
        let contents = try WorkspaceImage.read(path, at: remote("repo"))
        XCTAssertEqual(contents.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(contents.version, WorkspaceFiles.gitBlobHash(bytes))
        XCTAssertThrowsError(try WorkspaceFiles.readData(path, at: remote("repo"), limit: bytes.count - 1))
        XCTAssertThrowsError(try WorkspaceImage.read("../repo/" + path, at: remote("repo")))
        try bytes.write(to: URL(fileURLWithPath: sandbox.path("outside.png")))
        try FileManager.default.createSymbolicLink(atPath: sandbox.path("repo/link.png"),
                                                 withDestinationPath: sandbox.path("outside.png"))
        XCTAssertThrowsError(try WorkspaceImage.read("link.png", at: remote("repo")))
    }

    func testFilesOfThisMacAreSentToTheMachine() throws {
        try sandbox.repository("repo")
        try sandbox.write(["-notes/todo.txt": "todo\n", "-notes/deep/x.txt": "x\n", "a.txt": "mine\n"], in: "mac")
        let repo = remote("repo")
        XCTAssertEqual(try WorkspaceFiles.importItems([sandbox.path("mac/-notes"), sandbox.path("mac/a.txt")],
                                                      into: "", at: repo),
                       ["-notes", "a copy.txt"], "A taken name gets a copy name")
        XCTAssertEqual(try sandbox.read("-notes/deep/x.txt", in: "repo"), "x\n")
        XCTAssertEqual(try sandbox.read("a copy.txt", in: "repo"), "mine\n")
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path("repo")).filter { $0.hasPrefix(".wooloo") }
        XCTAssertEqual(leftovers, [], "The unpacking folder is removed")
        XCTAssertThrowsError(try WorkspaceFiles.importItems([sandbox.path("mac/a.txt")], into: "../out", at: repo))
    }

    /// A repository with staged, unstaged, untracked and ignored files, a second branch and a worktree.
    private func busyRepository() throws {
        try sandbox.repository("repo", files: ["a.txt": "one\n", "b.txt": "two\n", ".gitignore": "build/\n"])
        try sandbox.sh("""
            git branch feature && git worktree add -q ../wt feature
            echo staged >> a.txt && git add a.txt && echo more >> a.txt
            echo new > c.txt && mkdir -p build && echo o > build/out.o && rm b.txt
            """, in: "repo")
    }

    /// Everything a refresh shows, as text, so local and SSH results compare field by field.
    private func refresh(_ location: WorkspaceFileLocation) throws -> [String] {
        WorkspaceFiles.forgetRecentResults()
        let listing = try WorkspaceFiles.listing(at: location)
        let bar = try WorkspaceFiles.gitBar(at: location)
        let repository = try WorkspaceFiles.repository(at: location)
        return [String(describing: listing), String(describing: bar.status),
                String(describing: bar.repository), String(describing: repository)]
    }

    /// Over SSH, the listing, the Git bar and the repository panel read one remote script; the
    /// results match a local refresh.
    func testRefreshOverSSHRunsOneScriptWithTheLocalResults() throws {
        try busyRepository()
        let local = try refresh(sandbox.location("repo"))
        let before = try invocations().count
        let (remoteResult, processes) = try WorkspaceProcessLog.collect { try refresh(remote("repo")) }
        XCTAssertEqual(remoteResult, local)
        XCTAssertEqual(try invocations().count - before, 1)
        XCTAssertEqual(processes.map(\.label), ["git batch"])
        XCTAssertTrue(local[0].contains("c.txt") && local[0].contains("build"), local[0])
        XCTAssertTrue(local[3].contains("feature") && local[3].contains("/wt"), local[3])

        // The Git bar and repository panel reuse a recent batch; the listing, which follows
        // saves and file operations, reads afresh, and the root it reuses spares the root check.
        let (_, again) = try WorkspaceProcessLog.collect {
            _ = try WorkspaceFiles.gitBar(at: remote("repo"))
            _ = try WorkspaceFiles.repository(at: remote("repo"))
            _ = try WorkspaceFiles.listing(at: remote("repo"))
        }
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(try invocations().last?.last?.contains("rev-parse"), false, "The listing skips the root check")

        // Forgetting, as Git operations and an explicit refresh do, makes the next load read again.
        WorkspaceFiles.forgetRecentResults()
        let (_, forgotten) = try WorkspaceProcessLog.collect { _ = try WorkspaceFiles.gitBar(at: remote("repo")) }
        XCTAssertEqual(forgotten.count, 1)
    }

    /// Runs `body` on another thread; the returned group is done when it returns.
    private func inBackground(_ body: @escaping () -> Void) -> DispatchGroup {
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { body() }
        return group
    }

    /// A refresh starts the listing and the repository panel together, in no set order, and
    /// the Git bar once the listing arrives: whichever starts first, the others share its script.
    func testLoadsStartedTogetherOverSSHShareOneScript() throws {
        try busyRepository()
        let expected = try refresh(remote("repo"))
        try sandbox.write(["slow": ""], in: ".")
        for listingFirst in [true, false] {
            WorkspaceFiles.forgetRecentResults()
            let before = try invocations().count
            var first: String?
            var second: String?
            let started = inBackground {
                first = listingFirst ? self.outcome { try WorkspaceFiles.listing(at: self.remote("repo")) }
                                     : self.outcome { try WorkspaceFiles.repository(at: self.remote("repo")) }
            }
            Thread.sleep(forTimeInterval: 0.1)
            second = listingFirst ? outcome { try WorkspaceFiles.repository(at: remote("repo")) }
                                  : outcome { try WorkspaceFiles.listing(at: remote("repo")) }
            started.wait()
            let bar = outcome { try WorkspaceFiles.gitBar(at: remote("repo")) }
            let (listing, repository) = listingFirst ? (first, second) : (second, first)
            XCTAssertEqual(listing, expected[0], "listing first: \(listingFirst)")
            XCTAssertEqual(repository, expected[3], "listing first: \(listingFirst)")
            XCTAssertTrue(bar.contains(expected[1]), bar)
            XCTAssertEqual(try invocations().count - before, 1, "listing first: \(listingFirst)")
        }
    }

    /// A batch that a forget overtakes is returned to its callers but not kept for the next load.
    func testBatchOvertakenByAForgetIsNotReused() throws {
        try busyRepository()
        try sandbox.write(["slow": ""], in: ".")
        WorkspaceFiles.forgetRecentResults()
        let before = try invocations().count
        let running = inBackground { _ = try? WorkspaceFiles.listing(at: self.remote("repo")) }
        Thread.sleep(forTimeInterval: 0.1)
        WorkspaceFiles.forgetRecentResults()
        running.wait()
        _ = try WorkspaceFiles.gitBar(at: remote("repo"))
        XCTAssertEqual(try invocations().count - before, 2)
    }

    /// Locally, the work tree root is checked once per refresh instead of by both the listing and the repository load.
    func testLocalRefreshChecksTheRootOnce() throws {
        try busyRepository()
        let (_, processes) = try WorkspaceProcessLog.collect { try refresh(sandbox.location("repo")) }
        XCTAssertEqual(processes.filter { $0.label == "git rev-parse" }.count, 1)
        XCTAssertEqual(processes.filter { $0.label == "git status" }.count, 2, "The listing's and the Git bar's")
    }

    /// A load's result or error, as text.
    private func outcome<T>(_ load: () throws -> T) -> String {
        do { return String(describing: try load()) } catch { return "error: " + error.localizedDescription }
    }

    /// Outside a repository the batch stops after the root check, and every load reports what it did before.
    func testRemoteLoadsOutsideARepositoryMatchLocalOnes() throws {
        try sandbox.write(["plain/a.txt": "a", "plain/sub/c.txt": "c"], in: ".")
        try sandbox.sh("git init -q -b main empty")
        for name in ["plain", "empty"] {
            let local = sandbox.location(name)
            let ssh = remote(name)
            WorkspaceFiles.forgetRecentResults()
            XCTAssertEqual(String(describing: try WorkspaceFiles.listing(at: ssh)),
                           String(describing: try WorkspaceFiles.listing(at: local)), name)
            WorkspaceFiles.forgetRecentResults()
            XCTAssertEqual(outcome { try WorkspaceFiles.repository(at: ssh) },
                           outcome { try WorkspaceFiles.repository(at: local) }, name)
            XCTAssertEqual(outcome { try WorkspaceFiles.gitBar(at: ssh) }, outcome { try WorkspaceFiles.gitBar(at: local) }, name)
        }
        // Outside a repository the script lists the folder itself: a refresh is still one round trip.
        let before = try invocations().count
        _ = try refreshOutcomes(remote("plain"))
        XCTAssertEqual(try invocations().count - before, 1)
        XCTAssertEqual(try refreshOutcomes(remote("plain")), try refreshOutcomes(sandbox.location("plain")))
        XCTAssertEqual(try refreshOutcomes(remote("empty")), try refreshOutcomes(sandbox.location("empty")))

        WorkspaceFiles.forgetRecentResults()
        XCTAssertThrowsError(try WorkspaceFiles.repository(at: remote("plain"))) {
            XCTAssertTrue($0.localizedDescription.contains("not a git repository"), $0.localizedDescription)
        }
        XCTAssertEqual(try WorkspaceFiles.repository(at: remote("empty")).commits.count, 0, "A failed log leaves no commits")
    }

    /// Every load of a refresh, in the order the UI runs them, as results or errors.
    private func refreshOutcomes(_ location: WorkspaceFileLocation) throws -> [String] {
        WorkspaceFiles.forgetRecentResults()
        return [outcome { try WorkspaceFiles.listing(at: location) }, outcome { try WorkspaceFiles.gitBar(at: location) },
                outcome { try WorkspaceFiles.repository(at: location) }]
    }

    /// A damaged index fails the listing and the branch status but not the repository; each
    /// load reports the same over SSH as locally.
    func testRefreshWithFailingCommandsMatchesLocal() throws {
        try sandbox.repository("repo")
        try sandbox.sh("printf 'junk' > .git/index", in: "repo")
        let local = try refreshOutcomes(sandbox.location("repo"))
        XCTAssertTrue(local[0].hasPrefix("error: ") && local[1].hasPrefix("error: "), "\(local)")
        XCTAssertFalse(local[2].hasPrefix("error: "), local[2])
        let before = try invocations().count
        XCTAssertEqual(try refreshOutcomes(remote("repo")), local)
        XCTAssertEqual(try invocations().count - before, 1)
    }

    /// Each command of a batch keeps its own status, output and errors, and output that looks
    /// like a section header is still read as output.
    func testRemoteBatchKeepsEachCommandsOutcome() throws {
        try sandbox.repository("repo", files: ["fake.txt": "wooloo-section 0 3 0\nabc\n"])
        let results = try WorkspaceFiles.gitBatch(remote("repo"), [
            .init(["cat-file", "-p", "HEAD:fake.txt"], limit: 1_000),
            .init(["no-such-command"], limit: 1_000),
            .init(["cat-file", "-p", "HEAD:fake.txt"], limit: 5),
            .root,
        ])
        XCTAssertEqual(try results[0].get(), Data("wooloo-section 0 3 0\nabc\n".utf8))
        XCTAssertThrowsError(try results[1].get()) {
            XCTAssertTrue($0.localizedDescription.contains("not a git command"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try results[2].get()) { XCTAssertEqual($0.localizedDescription, "Output is too large") }
        XCTAssertEqual(String(decoding: try results[3].get(), as: UTF8.self).trimmingCharacters(in: .newlines),
                       sandbox.path("repo"))

        try sandbox.write(["plain/a.txt": "a"], in: ".")
        let before = try invocations().count
        let stopped = try WorkspaceFiles.gitBatch(remote("plain"), [.root, .init(["status"], limit: 1_000)])
        XCTAssertEqual(try invocations().count - before, 1)
        for result in stopped {
            XCTAssertThrowsError(try result.get()) {
                XCTAssertTrue($0.localizedDescription.contains("not a git repository"), $0.localizedDescription)
            }
        }
        XCTAssertNil(try? stopped[0].get())
    }

    /// The batch script from before its commands ran at once, one after another: the reference
    /// `remoteBatchScript` must print the same sections as, except that a failing last command
    /// failed the whole script.
    private static func sequentialBatchScript(_ commands: [(words: [String], gate: Bool)], otherwise: [String]?) -> String {
        var lines = [
            #"d=$(mktemp -d) || exit 1"#,
            #"trap 'rm -rf "$d"' EXIT"#,
            #"trap 'exit 1' HUP INT TERM"#,
            #"section() { "$@" >"$d/o" 2>"$d/e"; r=$?; "#
                + #"printf 'wooloo-section %s %s %s\n' "$r" $(wc -c <"$d/o") $(wc -c <"$d/e"); "#
                + #"cat "$d/o" "$d/e"; return $r; }"#,
        ]
        let quote = WorkspaceFiles.quote
        let stop = otherwise.map { " || { section " + $0.map(quote).joined(separator: " ") + "; exit 0; }" } ?? " || exit 0"
        for command in commands {
            lines.append("section " + command.words.map(quote).joined(separator: " ") + (command.gate ? stop : ""))
        }
        return (lines + ["exit 0"]).joined(separator: "\n") + "\n"
    }

    /// The sections `script` prints when `shell` runs it through the fake ssh, in the folder `name`.
    private func batchSections(_ name: String, _ script: String, shell: String = "sh") throws -> [String] {
        let command = "cd " + WorkspaceFiles.quote(sandbox.path(name)) + " && " + shell + " -c " + WorkspaceFiles.quote(script)
        let output = try WorkspaceFiles.remoteOutput(machine, script: command, label: "batch", limit: 1_000_000)
        return try WorkspaceFiles.parseBatchOutput(output).map {
            "\($0.status) " + String(decoding: $0.output, as: UTF8.self) + " | " + String(decoding: $0.errors, as: UTF8.self)
        }
    }

    /// Run at once, a batch prints the same sections in the same order as one after another:
    /// failures, a passed gate, a failed gate with and without its fallback, and a failing
    /// last command, which no longer fails the whole batch. Checked with the system `sh` and
    /// with dash, the `sh` of Debian and Ubuntu remotes.
    func testConcurrentBatchMatchesSequentialOne() throws {
        try sandbox.repository("repo", files: ["a.txt": "one\n", "b.txt": "two\n"])
        try sandbox.write(["repo/a.txt": "changed\n", "repo/new.txt": "new\n", "plain/c.txt": "c"], in: ".")
        let git = ["env", "GIT_OPTIONAL_LOCKS=0", "git"]
        let commands: [(words: [String], gate: Bool)] = [
            (git + ["status", "--porcelain=v2", "--branch"], false),
            (git + ["no-such-command"], false),
            (["sh", "-c", "sleep 0.1; echo late; echo warn >&2; exit 3"], false),
            (git + ["rev-parse", "--show-toplevel"], true),
            (git + ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], false),
            (git + ["status", "--porcelain=v1", "-z", "--untracked-files=all"], false),
            (git + ["log", "--format=%s"], false),
            (git + ["cat-file", "-p", "HEAD:missing.txt"], false),
        ]
        let shells = ["sh"] + (FileManager.default.isExecutableFile(atPath: "/bin/dash") ? ["/bin/dash"] : [])
        for shell in shells {
            for name in ["repo", "plain"] {
                for otherwise in [nil, ["ls"]] as [[String]?] {
                    let sequential = try batchSections(name, Self.sequentialBatchScript(commands, otherwise: otherwise))
                    let concurrent = try batchSections(name, WorkspaceFiles.remoteBatchScript(commands, otherwise: otherwise),
                                                       shell: shell)
                    XCTAssertEqual(concurrent, sequential, "\(shell) in \(name)")
                    XCTAssertEqual(sequential.count, name == "repo" ? commands.count : 4 + (otherwise == nil ? 0 : 1))
                }
            }
            XCTAssertEqual(try batchSections("repo", WorkspaceFiles.remoteBatchScript([]), shell: shell), [])
            XCTAssertEqual(try batchSections("repo", WorkspaceFiles.remoteBatchScript([(git + ["no-such-command"], false)]),
                                             shell: shell).count, 1)
        }
    }

    /// The commands of a batch run at once, on both sides of a gate: each waits until all three
    /// have started, which one after another would never happen, and gives up after 10 s.
    func testRemoteBatchRunsItsCommandsAtOnce() throws {
        try sandbox.repository("repo")
        let names = ["one", "two", "three"]
        let meeting = WorkspaceFiles.quote(sandbox.path("meeting"))
        try FileManager.default.createDirectory(atPath: sandbox.path("meeting"), withIntermediateDirectories: true)
        let sections = names.map { name in
            WorkspaceFiles.GitSection([], limit: 100, script: "cd \(meeting) && touch \(name) && n=0; "
                + "while [ ! -e one ] || [ ! -e two ] || [ ! -e three ]; do "
                + "n=$((n + 1)); [ $n -le 200 ] || exit 1; sleep 0.05; done; echo \(name)")
        }
        let results = try WorkspaceFiles.gitBatch(remote("repo"), [sections[0], .root, sections[1], sections[2]])
        XCTAssertEqual(results.map { (try? String(decoding: $0.get(), as: UTF8.self)) ?? "failed" },
                       ["one\n", sandbox.path("repo") + "\n", "two\n", "three\n"])
    }

    /// The script removes its temporary folder when the connection closes before it printed
    /// everything, which it learns from SIGPIPE, or when it is stopped while its commands run.
    func testBatchScriptCleansUpWhenCutShort() throws {
        try sandbox.repository("repo")
        let script = WorkspaceFiles.remoteBatchScript([
            // More than a pipe holds, so writing it blocks until the reader goes away.
            (["sh", "-c", "sleep 0.2; yes line | head -n 100000"], false),
            (["git", "rev-parse", "--show-toplevel"], true),
            (["sh", "-c", "sleep 0.3; echo late"], false),
        ])
        try FileManager.default.createDirectory(atPath: sandbox.path("tmp"), withIntermediateDirectories: true)
        let shells = ["sh"] + (FileManager.default.isExecutableFile(atPath: "/bin/dash") ? ["/bin/dash"] : [])
        for shell in shells {
            let run = "TMPDIR=" + WorkspaceFiles.quote(sandbox.path("tmp")) + " " + shell + " -c " + WorkspaceFiles.quote(script)
            try sandbox.sh("cd repo && " + run + " | head -c 10 > /dev/null; " + run + " > /dev/null & pid=$!; "
                           + "sleep 0.1; kill $pid; status=0; wait $pid || status=$?; [ $status -ne 0 ]")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("tmp")), [], shell)
        }
    }

    /// Two `git status` and the rest of a refresh run at once in a repository whose index is
    /// out of date, many times over and from several refreshes at once: none fails on
    /// `index.lock`, all read the same status, and no lock is left behind.
    func testConcurrentRefreshesTakeNoIndexLock() throws {
        var files: [String: String] = [:]
        for index in 0..<200 { files["dir\(index % 10)/file\(index).txt"] = "\(index)\n" }
        try sandbox.repository("repo", files: files)
        try sandbox.write(["repo/dir0/file0.txt": "changed\n", "repo/new.txt": "new\n"], in: ".")
        let location = remote("repo")
        let expected = try WorkspaceFiles.listing(at: location).changes.map(\.path)
        XCTAssertEqual(Set(expected), ["dir0/file0.txt", "new.txt"])
        let lock = NSLock()
        var outcomes: [String] = []
        for _ in 0..<5 {
            // A changed modification time leaves every index entry out of date for `git status`.
            try sandbox.sh("find . -path ./.git -prune -o -type f -exec touch {} +", in: "repo")
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                WorkspaceFiles.forgetRecentResults(at: location)
                let listing = outcome { try WorkspaceFiles.listing(at: location).changes.map(\.path) }
                let bar = outcome { try WorkspaceFiles.gitBar(at: location).status.branch ?? "detached" }
                lock.withLock { outcomes += [listing, bar] }
            }
        }
        XCTAssertEqual(outcomes.count, 40)
        XCTAssertFalse(outcomes.contains { $0.hasPrefix("error: ") }, "\(outcomes.filter { $0.hasPrefix("error: ") })")
        XCTAssertEqual(Set(outcomes), [String(describing: expected), "main"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/.git/index.lock")))
    }

    func testBatchOutputIsSplitByItsLengths() throws {
        let output = Data("wooloo-section 0 3 0\na\nbwooloo-section 128 0 5\nfatal".utf8)
        let sections = try WorkspaceFiles.parseBatchOutput(output)
        XCTAssertEqual(sections.map(\.status), [0, 128])
        XCTAssertEqual(sections.map(\.output), [Data("a\nb".utf8), Data()])
        XCTAssertEqual(sections.map(\.errors), [Data(), Data("fatal".utf8)])
        for malformed in ["wooloo-section 0 9 0\nshort", "garbage\n", "wooloo-section 0 1", "wooloo-section 0 -1 0\n"] {
            XCTAssertThrowsError(try WorkspaceFiles.parseBatchOutput(Data(malformed.utf8)), malformed)
        }
        XCTAssertEqual(try WorkspaceFiles.parseBatchOutput(Data()).count, 0)
    }

    /// A failed SSH command is recorded with its exit status; its stderr goes to the log
    /// without credentials.
    func testFailedSSHCommandsRecordTheirStatus() throws {
        let (_, processes) = WorkspaceProcessLog.collect {
            _ = try? WorkspaceFiles.remoteOutput(machine, script: "echo partial; echo oops >&2; exit 7", label: "probe")
        }
        XCTAssertEqual(processes.map(\.label), ["probe"])
        XCTAssertEqual(processes.map(\.status), [7])
        XCTAssertEqual(processes.map(\.succeeded), [false])
        XCTAssertEqual(processes.map(\.remote), [true])
        XCTAssertEqual(WorkspaceProcessLog.summary(of: "fatal: unable to access 'https://me:s3cret@git.example/x.git/'\n"),
                       "fatal: unable to access 'https://<redacted>@git.example/x.git/'")
        XCTAssertEqual(WorkspaceProcessLog.summary(of: (1...20).map(String.init).joined(separator: "\n")),
                       (13...20).map(String.init).joined(separator: " | "))
    }

    func testRemoteSearch() throws {
        try sandbox.repository("repo", files: ["src/a.swift": "let foo = 1\n", "b.txt": "no match\n"])
        let result = try WorkspaceSearch.search(WorkspaceSearchOptions(query: "foo"), at: remote("repo"))
        XCTAssertEqual(result.files.map(\.path), ["src/a.swift"])
        XCTAssertEqual(result.matchCount, 1)
    }
}

/// The Herdr command that lists SSH machines and reads their snapshots, replaced by a script
/// that logs its arguments and prints canned JSON.
final class WorkspaceHerdrCommandTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var savedCandidates: [String] = []

    override func setUpWithError() throws {
        sandbox = try WorkspaceGitSandbox()
        let snapshot = try JSONSerialization.data(withJSONObject: fakeSnapshot(label: "remote project"))
        try sandbox.write([
            "bin/herdr": """
                #!/bin/sh
                echo "$@" > '\(sandbox.path("herdr.log"))'
                case "$1" in
                machine) cat '\(sandbox.path("machines.json"))' ;;
                --machine) cat '\(sandbox.path("snapshot.json"))' ;;
                *) echo "unknown command" >&2; exit 2 ;;
                esac
                """,
            "machines.json": """
                [{"id": "dev", "label": "Dev box", "target": "dev@example.test", "session": "default", "enabled": true},
                 {"id": "old", "label": "Old box", "target": "old.test", "session": "default", "enabled": false}]
                """,
            "snapshot.json": String(decoding: snapshot, as: UTF8.self),
        ], in: ".")
        try sandbox.sh("chmod 755 bin/herdr")
        savedCandidates = WorkspaceFiles.herdrCandidates
        WorkspaceFiles.herdrCandidates = [sandbox.path("missing/herdr"), sandbox.path("bin/herdr")]
    }

    override func tearDown() {
        WorkspaceFiles.herdrCandidates = savedCandidates
        sandbox.tearDown()
    }

    private func loggedArguments() throws -> String {
        try sandbox.read("herdr.log", in: ".").trimmingCharacters(in: .newlines)
    }

    func testMachinesListsOnlyEnabledProfiles() throws {
        XCTAssertEqual(try WorkspaceFiles.machines().map(\.id), ["dev"])
        XCTAssertEqual(try loggedArguments(), "machine list --json")
    }

    func testRemoteSnapshotAsksTheMachinesHerdr() throws {
        let machine = HerdrMachineProfile(id: "dev", label: "Dev box", target: "dev@example.test",
                                          session: "default", enabled: true)
        let snapshot = try WorkspaceFiles.remoteSnapshot(machine)
        XCTAssertEqual(snapshot.workspaces.map(\.label), ["remote project"])
        XCTAssertEqual(try loggedArguments(), "--machine dev api snapshot")
    }

    func testMissingOrFailingHerdrIsReported() throws {
        try sandbox.write(["machines.json": "not json"], in: ".")
        XCTAssertThrowsError(try WorkspaceFiles.machines())

        WorkspaceFiles.herdrCandidates = [sandbox.path("missing/herdr")]
        XCTAssertThrowsError(try WorkspaceFiles.machines()) { error in
            XCTAssertEqual(error.localizedDescription, "Herdr executable was not found")
        }
    }

    /// Processes started inside `collect` are returned with their outcome; others are not kept.
    func testProcessLogCollectsOnlyDuringTheBody() throws {
        _ = try WorkspaceFiles.machines()
        let (ids, processes) = try WorkspaceProcessLog.collect {
            let ids = try WorkspaceFiles.machines().map(\.id)
            WorkspaceFiles.herdrCandidates = [sandbox.path("missing/herdr")]
            return ids
        }
        XCTAssertEqual(ids, ["dev"])
        XCTAssertEqual(processes.map(\.label), ["herdr"])
        XCTAssertEqual(processes.map(\.succeeded), [true])
        XCTAssertEqual(processes.map(\.remote), [false])
        XCTAssertGreaterThan(processes[0].bytes, 0)
    }

    func testChangeKindsAndGitActionsHaveLabels() {
        let kinds: [WorkspaceFileChange.Kind] = [.untracked, .renamed, .modified, .added, .deleted, .conflicted]
        XCTAssertEqual(kinds.map(\.label), ["U", "R", "M", "A", "D", "!"])

        let syncs: [WorkspaceGitSync] = [.fetch, .pull, .pullRebase, .push, .forcePush, .publish(remote: "origin", branch: "main")]
        XCTAssertEqual(syncs.map(\.title), ["Fetch", "Pull", "Pull (Rebase)", "Push", "Force Push", "Publish"])
        XCTAssertEqual(syncs.map(\.icon), ["arrow.triangle.2.circlepath", "arrow.down", "arrow.down",
                                           "arrow.up", "arrow.up", "icloud.and.arrow.up"])
        XCTAssertTrue(syncs.allSatisfy { NSImage(systemSymbolName: $0.icon, accessibilityDescription: nil) != nil })

        let modes: [WorkspaceCommitMode] = [.staged, .tracked, .all, .amend]
        XCTAssertEqual(modes.map(\.title), ["Commit", "Commit Tracked", "Commit All", "Amend"])
    }
}

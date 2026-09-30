import XCTest
@testable import xherdr

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
            for command; do :; done
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
        XCTAssertTrue(arguments.contains("ControlPath=/tmp/xherdr-ssh-\(getuid())/%C"))
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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path("repo")).filter { $0.contains(".xherdr.") }
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
        for path in ["escape.txt", "dir", "missing.txt", "../secret.txt"] {
            XCTAssertThrowsError(try WorkspaceFiles.read(path, at: location), path)
        }
        XCTAssertThrowsError(try WorkspaceFiles.readData("a.txt", at: location, limit: 2)) {
            XCTAssertTrue($0.localizedDescription.contains("File is too large"), $0.localizedDescription)
        }
    }

    func testRemoteFolderWithoutGitIsListedWithFind() throws {
        try sandbox.write(["plain/a.txt": "a", "plain/sub/c.txt": "c", "plain/.git/config": "not a repo"], in: ".")
        let listing = try WorkspaceFiles.listing(at: remote("plain"))
        XCTAssertFalse(listing.hasGit)
        XCTAssertEqual(listing.files, ["a.txt", "sub/c.txt"])
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
        try WorkspaceFiles.delete("it's", at: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("repo/it's")))
        XCTAssertThrowsError(try WorkspaceFiles.trash("a.txt", at: repo))
    }

    func testRemoteSearch() throws {
        try sandbox.repository("repo", files: ["src/a.swift": "let foo = 1\n", "b.txt": "no match\n"])
        let result = try WorkspaceSearch.search(WorkspaceSearchOptions(query: "foo"), at: remote("repo"))
        XCTAssertEqual(result.files.map(\.path), ["src/a.swift"])
        XCTAssertEqual(result.matchCount, 1)
    }
}

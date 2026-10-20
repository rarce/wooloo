import Foundation
import os

// Implementation of the shared WorkspaceFiles facade.
extension WorkspaceFiles {
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func listing(at location: WorkspaceFileLocation) throws -> WorkspaceFileListing {
        // Over SSH the listing comes from the refresh batch, which the Git bar and repository
        // panel share. It never reuses a finished one: it joins a running batch or starts one.
        if location.machine != nil { return try remoteRefresh(at: location, reusingFinished: false).listing.get() }
        // The work tree check is skipped when the repository panel or Git bar just found the root.
        let knownRoot = gitRoots.recent(for: location.identity)
        let generation = gitRoots.generation(for: location.identity)
        var results = try gitBatch(location, (knownRoot == nil ? [GitSection.root] : []) + listingGitSections)[...]
        let hasGit: Bool
        if knownRoot == nil, let rootResult = results.popFirst() {
            hasGit = rememberRoot(rootResult, at: location, generation: generation) != nil
        } else {
            hasGit = true
        }
        var listing = try makeListing(hasGit ? results : nil) { try folderWalk(at: location, readingSkipped: false) }
        listing.symbolicLinks = localSymbolicLinks(listing.files + listing.ignored.directories, root: location.root)
        return listing
    }

    /// The Git commands of a listing; SSH adds link metadata within the same batch.
    private static let listingGitSections = [
        GitSection(["ls-files", "--cached", "--others", "--exclude-standard", "-t", "-z", "--", "."], limit: maximumListingBytes),
        GitSection(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--", "."],
                   limit: maximumListingBytes),
        GitSection(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], limit: 4_000_000),
    ]
    private static let listingSections = listingGitSections
        + [GitSection([], limit: maximumListingBytes, script: symbolicLinkListingScript)]

    /// A listing from the outputs of `listingSections`, or, outside a work tree (nil), from
    /// the walk `withoutGit` makes.
    private static func makeListing(_ results: ArraySlice<Result<Data, Error>>?,
                                    withoutGit: () throws -> WorkspaceFolderWalk) throws -> WorkspaceFileListing {
        guard let results else { return nonGitListing(try withoutGit()) }
        let outputs = Array(results)
        let (tracked, untrackedEntries) = trackedFirst(nulStrings(try outputs[0].get()))
        // Git does not descend into an untracked folder holding another repository, such as a
        // worktree, and lists it as "folder/": a folder, not a file.
        let nested = untrackedEntries.filter { $0.hasSuffix("/") }
        let untracked = nested.isEmpty ? untrackedEntries : untrackedEntries.filter { !$0.hasSuffix("/") }
        let ignored = WorkspaceIgnoredEntries(gitEntries: nulStrings(try outputs[1].get()))
        let ignoredFiles = ignored.files.sorted()
        let files = (tracked + untracked + ignoredFiles).prefix(maximumFiles).sorted()
        let visible = Set(files).union(ignored.directories)
        return WorkspaceFileListing(files: files, changes: parseStatus(try outputs[2].get()), hasGit: true,
                                    totalFiles: tracked.count + untracked.count + ignoredFiles.count, ignored: ignored,
                                    nestedRepositories: Set(nested.map { String($0.dropLast()) }.filter { !$0.isEmpty }),
                                    symbolicLinks: outputs.count > 3 ? parseSymbolicLinks(try outputs[3].get()).filter { visible.contains($0.key) } : [:])
    }

    /// The files Go to File searches: tracked and untracked ones, and with `includeIgnored` those
    /// Git ignores, cut to `maximumFiles`; with the status of changed files for their colors.
    /// Lighter than `listing`, which also lists ignored folders for the explorer tree.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func quickOpenFiles(at location: WorkspaceFileLocation, includeIgnored: Bool = false) throws -> QuickOpenListing {
        guard (try? git(location, ["rev-parse", "--is-inside-work-tree"], limit: 100)) != nil else {
            return try quickOpenFilesWithoutGit(at: location, includeIgnored: includeIgnored)
        }
        let data = try git(location, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."],
                           limit: maximumListingBytes)
        // A conflicted file is listed once per stage. A folder holding another repository is
        // listed as "folder/", which is not a file to open.
        var files = Array(Set(nulStrings(data))).filter { !$0.hasSuffix("/") }.sorted()
        var ignored: Set<String> = []
        if includeIgnored {
            let ignoredData = try git(location, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--", "."],
                                      limit: maximumListingBytes)
            let ignoredFiles = nulStrings(ignoredData).filter { !$0.hasSuffix("/") }.sorted()
            ignored = Set(ignoredFiles)
            files += ignoredFiles
        }
        let status = try git(location, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], limit: 4_000_000)
        let changes = Dictionary(parseStatus(status).map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return QuickOpenListing(files: Array(files.prefix(maximumFiles)), truncated: files.count > maximumFiles,
                                changes: changes, ignored: ignored)
    }

    /// Splits `git ls-files -t` entries so that a listing cut to `maximumFiles` keeps every tracked file
    /// before untracked ones, such as a build cache missing from `.gitignore`.
    static func trackedFirst(_ entries: [String]) -> (tracked: [String], untracked: [String]) {
        var tracked = Set<String>()
        var untracked = Set<String>()
        for entry in entries where entry.count > 2 {
            let path = String(entry.dropFirst(2))
            if entry.hasPrefix("? ") { untracked.insert(path) } else { tracked.insert(path) }
        }
        return (tracked.sorted(), untracked.subtracting(tracked).sorted())
    }

    /// A changed file's patches. `.all` compares HEAD with the working tree; `.staged` and
    /// `.unstaged` are added when the file has both kinds of changes.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func diff(_ path: String, at location: WorkspaceFileLocation) throws -> [WorkspaceDiffScope: String] {
        try validateRelativePath(path)
        let options = ["--no-ext-diff", "--no-textconv", "--"]
        func patch(_ args: [String]) throws -> String {
            String(data: try git(location, ["diff"] + args + options + [path], limit: maximumDiffBytes), encoding: .utf8) ?? ""
        }
        let staged = try patch(["--cached"])
        let unstaged = try patch([])
        if !staged.isEmpty && !unstaged.isEmpty {
            let hasHead = (try? git(location, ["rev-parse", "--verify", "--quiet", "HEAD"], limit: 1_000)) != nil
            let base = hasHead ? "HEAD" : String(decoding: try git(location, ["hash-object", "-t", "tree", "/dev/null"], limit: 1_000),
                                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return [.all: try patch([base]), .staged: staged, .unstaged: unstaged]
        }
        if !staged.isEmpty || !unstaged.isEmpty { return [.all: staged + unstaged] }
        if (try? git(location, ["ls-files", "--error-unmatch", "--", path], limit: 1_000)) == nil,
           let file = try? read(path, at: location) {
            return [.all: untrackedPatch(file.text, path: path)]
        }
        return [.all: "No text diff available. Open the file to view its contents."]
    }

    /// Compare captured text on this Mac, including text read over SSH. Exit 1 means a
    /// difference, not a command failure. Inputs stay in a private temporary directory.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func comparisonPatch(disk: String, buffer: String, path: String,
                                temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> String {
        let root = temporaryRoot.appendingPathComponent("wooloo-compare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let name = (path as NSString).lastPathComponent
        try validateName(name)
        for (folder, text) in [("Disk", disk), ("Buffer", buffer)] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        let script = #"/usr/bin/git --no-pager -C "$1" diff --no-index --no-color --no-ext-diff --no-textconv --text -- "$2" "$3"; status=$?; [ "$status" -eq 0 ] || [ "$status" -eq 1 ]"#
        let bytes = try run("/bin/sh", ["-c", script, "sh", root.path, "Disk/" + name, "Buffer/" + name],
                            limit: maximumDiffBytes, label: "compare disk")
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A patch that adds every line of an untracked file, as `git diff --no-index /dev/null` would.
    static func untrackedPatch(_ text: String, path: String) -> String {
        let header = "--- /dev/null\n+++ b/\(path)\n"
        guard !text.isEmpty else { return header }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        return header + "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
            + (endsWithNewline ? "\n" : "\n\\ No newline at end of file\n")
    }

    /// The whole file before and after a patch, for syntax highlighting and expanding unchanged lines.
    /// A side is nil when it doesn't exist, isn't UTF-8 text, or is too large.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func diffSides(_ path: String, originalPath: String?, commit: String?, scope: WorkspaceDiffScope,
                          at location: WorkspaceFileLocation) -> (old: String?, new: String?) {
        guard (try? validateRelativePath(path)) != nil,
              originalPath.map({ (try? validateRelativePath($0)) != nil }) ?? true else { return (nil, nil) }
        if let commit {
            guard (try? validateCommit(commit)) != nil else { return (nil, nil) }
            // Commit paths are relative to the repository root, like `diff-tree` output.
            return (blob("\(commit)^:\(originalPath ?? path)", at: location), blob("\(commit):\(path)", at: location))
        }
        let worktree = { (try? read(path, at: location))?.text }
        switch scope {
        case .all: return (blob("HEAD:./\(path)", at: location), worktree())
        case .staged: return (blob("HEAD:./\(path)", at: location), blob(":./\(path)", at: location))
        case .unstaged: return (blob(":./\(path)", at: location), worktree())
        }
    }

    private static func blob(_ revision: String, at location: WorkspaceFileLocation) -> String? {
        guard let data = try? git(location, ["cat-file", "blob", revision], limit: fileByteLimit(for: revision)),
              !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Recent repository listings. When the Files sidebar refreshes, the Git bar and the
    /// repository panel each ask for one; they share a single load instead of running the same
    /// four git commands twice.
    private static let repositoryLoads = SharedLoads<WorkspaceRepositoryListing>(maxAge: 2)

    /// Recent work tree roots (`git rev-parse --show-toplevel`). The listing and the repository
    /// load both need one; whichever runs first finds it, and the other skips the command.
    private static let gitRoots = SharedLoads<String>(maxAge: 2)

    /// What one refresh of an SSH location shows: the explorer's listing, the Git bar's
    /// branch status and the repository, which the Git bar and repository panel share.
    private struct RemoteRefresh {
        let listing: Result<WorkspaceFileListing, Error>
        let status: Result<WorkspaceBranchStatus, Error>
        let repository: Result<WorkspaceRepositoryListing, Error>
    }

    /// Recent SSH refreshes. A refresh starts the listing and the repository panel together and
    /// the Git bar once the listing arrives, so all three read one remote script: one round trip.
    private static let remoteRefreshes = SharedLoads<RemoteRefresh>(maxAge: 2)

    /// Forgets recently loaded results, so the next load reads the repository again. Git
    /// operations run here do this themselves; an explicit refresh does it for changes made
    /// elsewhere, such as in a terminal.
    static func forgetRecentResults() {
        repositoryLoads.forget()
        gitRoots.forget()
        remoteRefreshes.forget()
        NotificationCenter.default.post(name: repositoryDidChange, object: nil)
    }

    /// A refresh of one Space must not invalidate batches being shared by other windows.
    static func forgetRecentResults(at location: WorkspaceFileLocation) {
        repositoryLoads.forget(location.identity)
        gitRoots.forget(location.identity)
        remoteRefreshes.forget(location.identity)
        NotificationCenter.default.post(name: repositoryDidChange, object: location.identity)
    }

    /// Posted, on any thread, after a Git or file operation here or an explicit refresh; open
    /// editors reload their change bars' Git bases.
    static let repositoryDidChange = Notification.Name("WorkspaceFiles.repositoryDidChange")
    /// Posted on the main queue, at most once per batching window, when files of a local Space
    /// changed, including ones its listing skips; the object is the location's identity. Open
    /// documents compare themselves with the disk.
    static let filesDidChange = Notification.Name("WorkspaceFiles.filesDidChange")

    /// A file's text at HEAD and in the index, for the editor's change bars. Nil when that version
    /// doesn't exist or isn't UTF-8 text.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func gitBases(_ path: String, at location: WorkspaceFileLocation) -> (head: String?, index: String?) {
        guard (try? validateRelativePath(path)) != nil else { return (nil, nil) }
        guard let index = blob(":./\(path)", at: location) else { return (nil, nil) }
        return (blob("HEAD:./\(path)", at: location), index)
    }

    /// The Git directory of a local repository, e.g. `.git` or `.git/worktrees/<name>`, which an
    /// editor watches for index and HEAD changes. Nil for SSH locations and outside a repository.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func localGitDirectory(at location: WorkspaceFileLocation) -> String? {
        guard location.isLocal,
              let data = try? git(location, ["rev-parse", "--absolute-git-dir"], limit: 4096),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else { return nil }
        return path
    }

    /// Both paths matter in a linked worktree: index/HEAD are private, refs are shared.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func localGitWatchPaths(at location: WorkspaceFileLocation) -> [String] {
        guard location.isLocal,
              let data = try? git(location, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], limit: 16_384)
        else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func repository(at location: WorkspaceFileLocation) throws -> WorkspaceRepositoryListing {
        if location.machine != nil { return try remoteRefresh(at: location).repository.get() }
        return try repositoryLoads.value(for: location.identity) { try loadRepository(at: location).repository.get() }
    }

    /// The Git bar's branch status and the repository, which it shows together. Over SSH both
    /// come from the refresh batch, which the listing that comes before the Git bar just ran.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func gitBar(at location: WorkspaceFileLocation) throws -> (status: WorkspaceBranchStatus,
                                                                      repository: WorkspaceRepositoryListing?) {
        if location.machine != nil {
            let refresh = try remoteRefresh(at: location)
            return (try refresh.status.get(), try? refresh.repository.get())
        }
        var status: Result<WorkspaceBranchStatus, Error>?
        let repository = try? repositoryLoads.value(for: location.identity) {
            let loaded = try loadRepository(at: location, withBranchStatus: true)
            status = loaded.status
            return try loaded.repository.get()
        }
        // The repository came from a load already done or running: the status is read alone.
        return (try status?.get() ?? branchStatus(at: location), repository)
    }

    /// The commands of a branch status, for `branchStatus` and `parseBranchStatus`.
    private static let branchStatusSections = [
        GitSection(["status", "--porcelain=v2", "--branch", "--untracked-files=no"], limit: 4_000_000),
        GitSection(["remote"], limit: 20_000),
    ]

    private static func branchStatus(from results: ArraySlice<Result<Data, Error>>) throws -> WorkspaceBranchStatus {
        let outputs = Array(results)
        let remoteData = (try? outputs[1].get()) ?? Data()
        let remotes = String(decoding: remoteData, as: UTF8.self).split(separator: "\n").map(String.init)
        return parseBranchStatus(try outputs[0].get(), remotes: remotes)
    }

    /// The commands of a repository listing after the root, for `makeRepository`.
    private static let repositorySections = [
        GitSection(["log", "-n", "50", "--format=\(logFormat)"], limit: 200_000),
        GitSection(["for-each-ref", "--format=%(refname)%00%(HEAD)%00%(upstream:short)%00", "refs/heads", "refs/remotes"],
                   limit: 200_000),
        GitSection(["worktree", "list", "--porcelain", "-z"], limit: 200_000),
    ]

    /// A repository listing from the outputs of `repositorySections`; an empty repository has no log.
    private static func makeRepository(_ results: ArraySlice<Result<Data, Error>>, root: String?) throws
        -> WorkspaceRepositoryListing {
        let outputs = Array(results)
        let logData = (try? outputs[0].get()) ?? Data()
        let refData = try outputs[1].get()
        let worktreeData = try outputs[2].get()
        return WorkspaceRepositoryListing(commits: parseLog(logData), branches: parseBranches(refData),
                                          worktrees: parseWorktrees(worktreeData), root: root ?? "")
    }

    private static func loadRepository(at location: WorkspaceFileLocation, withBranchStatus: Bool = false)
        throws -> (repository: Result<WorkspaceRepositoryListing, Error>, status: Result<WorkspaceBranchStatus, Error>?) {
        let knownRoot = gitRoots.recent(for: location.identity)
        let generation = gitRoots.generation(for: location.identity)
        // The branch status goes first, since a failed root check stops the commands after it.
        let sections = (withBranchStatus ? branchStatusSections : [])
            + (knownRoot == nil ? [GitSection.root] : []) + repositorySections
        var results = try gitBatch(location, sections)[...]
        let status = withBranchStatus ? Result { try branchStatus(from: results.prefix(2)) } : nil
        if withBranchStatus { results = results.dropFirst(2) }
        let repository = Result { () throws -> WorkspaceRepositoryListing in
            var root = knownRoot
            if root == nil, let rootResult = results.popFirst() {
                root = rememberRoot(rootResult, at: location, generation: generation)
                _ = try rootResult.get()
            }
            return try makeRepository(results, root: root)
        }
        return (repository, status)
    }

    /// The refresh of an SSH location, from a batch running or, with `reusingFinished`, one
    /// that finished less than 2 s ago, or else from a new one.
    private static func remoteRefresh(at location: WorkspaceFileLocation, reusingFinished: Bool = true) throws
        -> RemoteRefresh {
        try remoteRefreshes.value(for: location.identity, reusingFinished: reusingFinished) {
            try loadRemoteRefresh(at: location)
        }
    }

    /// One remote script with the listing, the branch status and the repository. Outside a work
    /// tree the root check fails, and the script lists the folder with `find` instead.
    private static func loadRemoteRefresh(at location: WorkspaceFileLocation) throws -> RemoteRefresh {
        guard let machine = location.machine else { throw WorkspaceFileError.message("Not an SSH location") }
        let knownRoot = gitRoots.recent(for: location.identity)
        let generation = gitRoots.generation(for: location.identity)
        // The branch status goes first, since a failed root check stops the commands after it.
        let sections = branchStatusSections + (knownRoot == nil ? [GitSection.root] : []) + listingSections
            + repositorySections
        let batch = try remoteGitBatch(machine, location, sections,
                                       otherwise: knownRoot == nil
                                           ? (folderWalkWords(location, readingSkipped: false, links: true), maximumListingBytes)
                                           : nil)
        var results = batch.results[...]
        let status = Result { try branchStatus(from: results.prefix(branchStatusSections.count)) }
        results = results.dropFirst(branchStatusSections.count)
        var root = knownRoot
        var rootError: Error?
        if knownRoot == nil, let rootResult = results.popFirst() {
            root = rememberRoot(rootResult, at: location, generation: generation)
            if case .failure(let error) = rootResult { rootError = error }
        }
        let listingResults = results.prefix(listingSections.count)
        let listing = Result { () throws -> WorkspaceFileListing in
            if rootError != nil {
                let data = try (batch.otherwise ?? .failure(WorkspaceFileError.message("Remote command output is incomplete"))).get()
                return nonGitListing(folderWalk(linkedScriptOutput: data))
            }
            return try makeListing(listingResults) { WorkspaceFolderWalk() }
        }
        let repository = Result { () throws -> WorkspaceRepositoryListing in
            if let rootError { throw rootError }
            return try makeRepository(results.dropFirst(listingSections.count), root: root)
        }
        return RemoteRefresh(listing: listing, status: status, repository: repository)
    }

    /// Keeps the root a root check found, unless results were forgotten since `generation`;
    /// nil when the check failed, outside a work tree.
    private static func rememberRoot(_ result: Result<Data, Error>, at location: WorkspaceFileLocation,
                                     generation: (Int, Int)) -> String? {
        guard case .success(let data) = result else { return nil }
        let root = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        gitRoots.store(root, for: location.identity, keyGeneration: generation)
        return root
    }

    /// Fields of `git log` records: hash, short hash, subject, author and commit time.
    static let logFormat = "%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"

    static func parseLog(_ data: Data) -> [WorkspaceCommit] {
        String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { record -> WorkspaceCommit? in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let timestamp = TimeInterval(fields[4]) else { return nil }
            return WorkspaceCommit(id: fields[0], shortHash: fields[1], subject: fields[2], author: fields[3],
                                   date: Date(timeIntervalSince1970: timestamp))
        }
    }

    /// Parses `for-each-ref` records of refname, HEAD marker and upstream, separated by NUL.
    static func parseBranches(_ data: Data) -> [WorkspaceBranch] {
        let refs = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return refs.compactMap { line -> WorkspaceBranch? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }
            let ref = fields[0]
            let remote = ref.hasPrefix("refs/remotes/")
            guard ref.hasPrefix("refs/heads/") || remote,
                  !ref.hasSuffix("/HEAD") else { return nil }
            let name = String(ref.dropFirst(remote ? "refs/remotes/".count : "refs/heads/".count))
            return WorkspaceBranch(id: ref, name: name, isRemote: remote,
                                   isCurrent: fields[1] == "*", upstream: fields[2])
        }
    }

    static func parseWorktrees(_ data: Data) -> [WorkspaceWorktree] {
        var worktrees: [WorkspaceWorktree] = []
        var path: String?
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false
        let worktreeFields = data.split(separator: 0, omittingEmptySubsequences: false)
            .compactMap { String(data: Data($0), encoding: .utf8) }
        for field in worktreeFields {
            if field.isEmpty {
                if let path { worktrees.append(WorkspaceWorktree(path: path, branch: branch, isBare: bare, isLocked: locked, isPrunable: prunable)) }
                path = nil; branch = nil; bare = false; locked = false; prunable = false
            } else if field.hasPrefix("worktree ") { path = String(field.dropFirst("worktree ".count)) }
            else if field.hasPrefix("branch refs/heads/") { branch = String(field.dropFirst("branch refs/heads/".count)) }
            else if field == "bare" { bare = true }
            else if field.hasPrefix("locked") { locked = true }
            else if field.hasPrefix("prunable") { prunable = true }
        }
        return worktrees
    }

    /// Files touched by a commit, compared with its first parent (or the empty tree for a root commit).
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func commitFiles(_ hash: String, at location: WorkspaceFileLocation) throws -> [WorkspaceCommitFile] {
        try validateCommit(hash)
        let base = ["diff-tree", "-r", "--root", "-m", "--first-parent", "--no-commit-id", "-M", "-z"]
        let statusData = try git(location, base + ["--name-status", hash, "--"], limit: 4_000_000)
        let numstatData = try git(location, base + ["--numstat", hash, "--"], limit: 4_000_000)
        return parseCommitFiles(nameStatus: statusData, numstat: numstatData)
    }

    /// Joins `diff-tree -z --name-status` and `--numstat` output into one entry per file.
    static func parseCommitFiles(nameStatus statusData: Data, numstat numstatData: Data) -> [WorkspaceCommitFile] {
        var files: [WorkspaceCommitFile] = []
        var fields = nulStrings(statusData)[...]
        while let code = fields.popFirst(), let letter = code.first {
            guard let first = fields.popFirst() else { break }
            if letter == "R" || letter == "C", let second = fields.popFirst() {
                files.append(WorkspaceCommitFile(path: second, originalPath: first, status: letter,
                                                 additions: nil, deletions: nil))
            } else {
                files.append(WorkspaceCommitFile(path: first, originalPath: nil, status: letter,
                                                 additions: nil, deletions: nil))
            }
        }

        // numstat -z: "added\tdeleted\tpath" or, for renames, "added\tdeleted\t" followed by old and new paths.
        var counts: [String: (Int?, Int?)] = [:]
        var stats = nulStrings(numstatData)[...]
        while let record = stats.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            var path = parts[2]
            if path.isEmpty {
                _ = stats.popFirst()
                guard let destination = stats.popFirst() else { break }
                path = destination
            }
            counts[path] = (Int(parts[0]), Int(parts[1]))
        }
        return files.map { file in
            let count = counts[file.path]
            return WorkspaceCommitFile(path: file.path, originalPath: file.originalPath, status: file.status,
                                       additions: count?.0, deletions: count?.1)
        }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func commitDiff(_ hash: String, path: String, originalPath: String?,
                           at location: WorkspaceFileLocation) throws -> String {
        try validateCommit(hash)
        try validateRelativePath(path)
        var paths = [path]
        if let originalPath {
            try validateRelativePath(originalPath)
            paths.insert(originalPath, at: 0)
        }
        let data = try git(location, ["diff-tree", "-p", "-r", "--root", "-m", "--first-parent", "-M",
                                      "--no-commit-id", hash, "--"] + paths, limit: maximumDiffBytes)
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? "No textual changes" : text
    }

    static func validateCommit(_ hash: String) throws {
        guard (4...64).contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
            throw WorkspaceFileError.message("Invalid commit")
        }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func addWorktree(at location: WorkspaceFileLocation, path: String,
                            branch: WorkspaceBranch, newBranch: String?) throws {
        defer { forgetRecentResults() }
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), path != "/" else {
            throw WorkspaceFileError.message("Enter an absolute worktree path")
        }
        var args = ["worktree", "add"]
        // Git checks out a branch only when given its short name; a full ref detaches HEAD.
        let start: String
        if let newBranch, !newBranch.isEmpty {
            guard isValidNewBranchName(newBranch) else {
                throw WorkspaceFileError.message("“\(newBranch)” is not a valid branch name")
            }
            args += ["-b", newBranch]
            start = branch.id
        } else if branch.isRemote {
            throw WorkspaceFileError.message("Enter a local branch name for a remote branch")
        } else {
            start = branch.name
        }
        args += ["--", path, start]
        _ = try git(location, args, limit: 20_000)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func removeWorktree(at location: WorkspaceFileLocation, path: String) throws {
        defer { forgetRecentResults() }
        let repository = try repository(at: location)
        guard path != repository.root,
              let tree = repository.worktrees.first(where: { $0.path == path }),
              !tree.isBare, !tree.isLocked, !tree.isPrunable else {
            throw WorkspaceFileError.message("This worktree cannot be removed")
        }
        _ = try git(location, ["worktree", "remove", "--", path], limit: 20_000)
    }

    /// Stages a file or folder; an empty path stages everything under the Space root.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func stage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["add", "--", try pathspec(path)], limit: 20_000)
    }

    /// Unstages a file or folder; an empty path unstages everything under the Space root.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func unstage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["restore", "--staged", "--", try pathspec(path)], limit: 20_000)
    }

    /// Discards a file's staged and unstaged changes, as Zed's Discard Changes does: a path in
    /// HEAD goes back to its committed version, and one that is not (untracked or newly added) is
    /// deleted. A rename also restores its source.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func discard(_ change: WorkspaceFileChange, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        let paths = [change.path] + (change.originalPath.map { [$0] } ?? [])
        for path in paths { try validateRelativePath(path) }
        for path in paths {
            if (try? git(location, ["cat-file", "-e", "HEAD:./\(path)"], limit: 1_000)) != nil {
                _ = try git(location, ["restore", "--source=HEAD", "--staged", "--worktree", "--", path], limit: 20_000)
            } else {
                _ = try git(location, ["rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--", path], limit: 20_000)
                _ = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + "rm -f \"$p\"", at: location, limit: 4_000)
            }
        }
    }

    /// The latest commits that changed a file, following it across renames.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func fileHistory(_ path: String, at location: WorkspaceFileLocation) throws -> [WorkspaceCommit] {
        try validateRelativePath(path)
        return parseLog(try git(location, ["log", "-n", "100", "--follow", "--format=\(logFormat)", "--", path], limit: 400_000))
    }

    private static func pathspec(_ path: String) throws -> String {
        if path.isEmpty { return "." }
        try validateRelativePath(path)
        return path
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func branchStatus(at location: WorkspaceFileLocation) throws -> WorkspaceBranchStatus {
        try branchStatus(from: gitBatch(location, branchStatusSections)[...])
    }

    /// Reads the `# branch.*` headers of `git status --porcelain=v2 --branch`.
    static func parseBranchStatus(_ data: Data, remotes: [String]) -> WorkspaceBranchStatus {
        var oid = ""
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("# branch.") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 3 else { continue }
            switch parts[1] {
            case "branch.oid": oid = parts[2]
            case "branch.head": branch = parts[2] == "(detached)" ? nil : parts[2]
            case "branch.upstream": upstream = parts[2]
            case "branch.ab" where parts.count >= 4:
                ahead = Int(parts[2].dropFirst()) ?? 0
                behind = Int(parts[3].dropFirst()) ?? 0
            default: break
            }
        }
        return WorkspaceBranchStatus(branch: branch, shortHead: String(oid.prefix(7)), upstream: upstream,
                                     ahead: ahead, behind: behind, remotes: remotes)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func sync(_ action: WorkspaceGitSync, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        let args: [String]
        switch action {
        case .fetch: args = ["fetch", "--prune"]
        case .pull: args = ["pull"]
        case .pullRebase: args = ["pull", "--rebase"]
        case .push: args = ["push"]
        case .forcePush: args = ["push", "--force-with-lease"]
        case .publish(let remote, let branch):
            guard !remote.hasPrefix("-"), !branch.hasPrefix("-") else {
                throw WorkspaceFileError.message("Invalid remote or branch name")
            }
            args = ["push", "--set-upstream", remote, branch]
        }
        _ = try git(location, args, limit: 200_000, timeout: 120)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func commit(message: String, mode: WorkspaceCommitMode, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || mode == .amend else {
            throw WorkspaceFileError.message("Enter a commit message")
        }
        var args = ["commit"]
        switch mode {
        case .staged: break
        case .tracked: args.append("--all")
        case .all: _ = try git(location, ["add", "--all", "--", "."], limit: 20_000)
        case .amend: args.append("--amend")
        }
        // Commit hooks can be slow, so allow longer than a plain Git read.
        if message.isEmpty {
            _ = try git(location, args + ["--no-edit"], limit: 200_000, timeout: 120)
        } else {
            _ = try git(location, args + ["--file", "-"], input: Data(message.utf8), limit: 200_000, timeout: 120)
        }
    }

    /// Switches to a local branch, or to a remote one through a new local branch that tracks it.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func switchBranch(_ branch: WorkspaceBranch, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        guard !branch.isCurrent, !branch.name.hasPrefix("-") else {
            throw WorkspaceFileError.message("Choose another branch")
        }
        // A remote branch by its full ref: `origin/x` alone could name a local branch called that.
        _ = try git(location, branch.isRemote ? ["switch", "--track", branch.id] : ["switch", branch.name],
                    limit: 20_000)
    }

    /// Creates a branch at HEAD and switches to it; uncommitted changes stay in the working tree.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func createBranch(_ name: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        guard isValidNewBranchName(name) else {
            throw WorkspaceFileError.message("“\(name)” is not a valid branch name")
        }
        _ = try git(location, ["switch", "-c", name], limit: 20_000)
    }

    /// Whether `name` could name a new branch. Git checks its full rules when creating one; this
    /// keeps out names it always refuses, and any that it could read as an option.
    static func isValidNewBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), name != "@",
              !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\").union(.whitespacesAndNewlines).union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    private static func git(_ location: WorkspaceFileLocation, _ args: [String], input: Data? = nil,
                            limit: Int, timeout: TimeInterval = 15, optionalLocks: Bool = true) throws -> Data {
        // No terminal is attached, so credential prompts must fail instead of hanging.
        let label = "git " + (args.first ?? "")
        if let machine = location.machine {
            let remote = (["env", "GIT_TERMINAL_PROMPT=0", "git", "-C", location.root] + args).map(quote).joined(separator: " ")
            return try ssh(machine, remote, input: input, limit: limit, timeout: timeout, label: label)
        }
        guard let localGit else {
            throw WorkspaceFileError.message("Git is not installed. Install Git to use repository features; terminals and the editor work without it.")
        }
        var environment = ["GIT_TERMINAL_PROMPT": "0"]
        if !optionalLocks { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        return try run(localGit, ["-C", location.root] + args, environment: environment,
                       input: input, limit: limit, timeout: timeout, label: label)
    }

    /// One Git command or listing script of a batch. A failed `gate` stops the batch: the commands after it need
    /// what it checks, so they fail with its error instead of running.
    struct GitSection {
        let args: [String]
        let limit: Int
        var gate = false
        var script: String?

        init(_ args: [String], limit: Int, gate: Bool = false, script: String? = nil) {
            self.args = args
            self.limit = limit
            self.gate = gate
            self.script = script
        }

        /// The work tree root; fails outside a work tree, including inside a `.git` folder.
        static let root = GitSection(["rev-parse", "--show-toplevel"], limit: 4_000, gate: true)
    }

    /// Returns git command results in order. Locally independent reads overlap in pairs,
    /// with gates completed before dependent commands start. Over SSH they run in one remote script, which costs one
    /// round trip instead of one per command. Throws only when the batch as a whole fails, for
    /// example when SSH cannot connect.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func gitBatch(_ location: WorkspaceFileLocation, _ sections: [GitSection],
                         timeout: TimeInterval = 15) throws -> [Result<Data, Error>] {
        guard let machine = location.machine else {
            func run(_ section: GitSection) -> Result<Data, Error> {
                Result {
                    if let script = section.script { return try shell(script, at: location, limit: section.limit) }
                    // Reading status must not rewrite the index and trigger our own watcher.
                    return try git(location, section.args, limit: section.limit, timeout: timeout, optionalLocks: false)
                }
            }
            var results: [Result<Data, Error>] = []
            var index = 0
            while index < sections.count {
                // Gates run alone, before any command that depends on them.
                if sections[index].gate {
                    let result = run(sections[index])
                    results.append(result)
                    index += 1
                    if case .failure(let error) = result {
                        results.append(contentsOf: sections[index...].map { _ in .failure(error) })
                        break
                    }
                    continue
                }
                let end = sections[index...].firstIndex(where: \.gate) ?? sections.endIndex
                let batch = Array(sections[index..<end])
                let outputs = OSAllocatedUnfairLock<[Result<Data, Error>?]>(initialState: Array(repeating: nil, count: batch.count))
                // At most two processes per local load (and at most eight BlockingWork loads).
                // Independent read commands overlap startup and I/O without a thread per command.
                DispatchQueue.concurrentPerform(iterations: min(2, batch.count)) { worker in
                    for offset in stride(from: worker, to: batch.count, by: 2) {
                        let result = run(batch[offset])
                        outputs.withLock { $0[offset] = result }
                    }
                }
                results.append(contentsOf: outputs.withLock { $0.map { $0! } })
                index = end
            }
            return results
        }
        return try remoteGitBatch(machine, location, sections, timeout: timeout).results
    }

    /// `gitBatch` over SSH. `otherwise` runs in place of the commands after a failed gate, as
    /// a command of its own whose result comes back apart; nil when no gate failed.
    private static func remoteGitBatch(_ machine: HerdrMachineProfile, _ location: WorkspaceFileLocation,
                                       _ sections: [GitSection], otherwise: (words: [String], limit: Int)? = nil,
                                       timeout: TimeInterval = 15)
        throws -> (results: [Result<Data, Error>], otherwise: Result<Data, Error>?) {
        let commands = sections.map { section in
            (words: section.script.map { ["sh", "-c", "cd " + quote(location.root) + " && " + $0] }
                ?? (["env", "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "git", "-C", location.root] + section.args), gate: section.gate)
        }
        let limit = sections.reduce(1_000) { $0 + $1.limit + 100 } + (otherwise.map { $0.limit + 100 } ?? 0)
        let output = try ssh(machine, "sh -c " + quote(remoteBatchScript(commands, otherwise: otherwise?.words)),
                             limit: limit, timeout: timeout * Double(max(1, sections.count)), label: "git batch")
        let parsed = try parseBatchOutput(output)
        let incomplete = WorkspaceFileError.message("Remote command output is incomplete")
        func outcome(_ index: Int, limit: Int) -> Result<Data, Error> {
            guard index < parsed.count else { return .failure(incomplete) }
            let section = parsed[index]
            if section.output.count > limit { return .failure(WorkspaceFileError.message("Output is too large")) }
            if section.status != 0 {
                return .failure(WorkspaceFileError.message(failureMessage(errors: section.errors, output: section.output)))
            }
            return .success(section.output)
        }
        var stopped: Error?
        var fallback: Result<Data, Error>?
        let results = sections.indices.map { index -> Result<Data, Error> in
            if let stopped { return .failure(stopped) }
            let result = outcome(index, limit: sections[index].limit)
            if sections[index].gate, case .failure(let error) = result {
                stopped = error
                // The script printed the gate's section, then the fallback's.
                if let otherwise, index < parsed.count { fallback = outcome(index + 1, limit: otherwise.limit) }
            }
            return result
        }
        return (results, fallback)
    }

    /// A POSIX shell script that runs each command with its output and errors in temporary
    /// files, then prints a header line, `wooloo-section <status> <output bytes> <error bytes>`,
    /// followed by both. The lengths delimit them, so no output can be mistaken for a header.
    /// After a failed gate, the script runs `otherwise` when given, then stops.
    ///
    /// The commands run at once, as background jobs, and the sections are printed in order once
    /// all have finished, so a batch costs its slowest command rather than their sum. On a remote
    /// with few processors they start in groups of twice its processor count, each once the
    /// previous group finished: there, more at once only adds memory, as each `git status` or
    /// `git ls-files` reads the whole index (docs/perf/README.md). A gate runs
    /// once the commands before it have started, and the commands after it only once it passed.
    /// This is safe because a batch only reads: its git commands run with `GIT_OPTIONAL_LOCKS=0`,
    /// so `git status` never takes `index.lock` to refresh the index. The script exits 0 once it
    /// printed every section, whatever their statuses, so each command fails on its own.
    static func remoteBatchScript(_ commands: [(words: [String], gate: Bool)], otherwise: [String]? = nil) -> String {
        // `start` runs a command in the background and `run` in the foreground, each into files
        // numbered by its section; `emit` prints sections. A signal stops the jobs still running,
        // and the exit then removes the folder. SIGPIPE is among them: without a terminal, sshd
        // sends no SIGHUP when the client goes away, so the script only learns it when `emit`
        // writes, and dash or BusyBox would otherwise die there without running the EXIT trap.
        // The folder is named from a template, which every `mktemp` takes and macOS needs to
        // honor TMPDIR, and the name shows what left it behind.
        var lines = [
            #"d=$(mktemp -d "${TMPDIR:-/tmp}/wooloo-batch.XXXXXX") || exit 1"#,
            #"p="#,
            #"trap 'rm -rf "$d"' EXIT"#,
            #"trap 'kill $p 2>/dev/null; exit 1' HUP INT PIPE TERM"#,
            #"export GIT_OPTIONAL_LOCKS=0"#,
            #"run() { i=$1; shift; "$@" >"$d/o$i" 2>"$d/e$i"; r=$?; echo "$r" >"$d/r$i"; return $r; }"#,
            #"start() { if [ "${c:-0}" -gt 0 ] 2>/dev/null && [ "$n" -ge $((c * 2)) ]; then wait; n=0; p=; fi; "#
                + #"run "$@" & p="$p $!"; n=$((n + 1)); }"#,
            #"emit() { for i do r=$(cat "$d/r$i" 2>/dev/null); "#
                + #"printf 'wooloo-section %s %s %s\n' "${r:-1}" $(wc -c <"$d/o$i") $(wc -c <"$d/e$i"); "#
                + #"cat "$d/o$i" "$d/e$i"; done; }"#,
        ]
        func words(_ words: [String]) -> String { words.map(quote).joined(separator: " ") }
        // Two background commands never reach the cap, so their batch skips looking up the processors.
        if commands.filter({ !$0.gate }).count > 2 {
            lines.append(#"c=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null); n=0"#)
        }
        for (index, command) in commands.enumerated() {
            guard command.gate else {
                lines.append("start \(index) " + words(command.words))
                continue
            }
            let printed = Array(0...index) + (otherwise == nil ? [] : [index + 1])
            lines.append("run \(index) " + words(command.words) + " || { "
                + (otherwise.map { "run \(index + 1) " + words($0) + "; " } ?? "")
                + "wait; emit " + printed.map(String.init).joined(separator: " ") + "; exit 0; }")
        }
        lines.append("wait")
        if !commands.isEmpty { lines.append("emit " + commands.indices.map(String.init).joined(separator: " ")) }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits the output of `remoteBatchScript` into each command's exit status, output and errors.
    static func parseBatchOutput(_ data: Data) throws -> [(status: Int32, output: Data, errors: Data)] {
        let bytes = [UInt8](data)
        var sections: [(status: Int32, output: Data, errors: Data)] = []
        var index = 0
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: 0x0A) else {
                throw WorkspaceFileError.message("Remote command output is malformed")
            }
            let fields = String(decoding: bytes[index..<newline], as: UTF8.self).split(separator: " ")
            guard fields.count == 4, fields[0] == "wooloo-section", let status = Int32(fields[1]),
                  let outputCount = Int(fields[2]), let errorCount = Int(fields[3]), outputCount >= 0, errorCount >= 0,
                  newline + 1 + outputCount + errorCount <= bytes.count else {
                throw WorkspaceFileError.message("Remote command output is malformed")
            }
            let outputStart = newline + 1
            let errorStart = outputStart + outputCount
            sections.append((status, Data(bytes[outputStart..<errorStart]), Data(bytes[errorStart..<errorStart + errorCount])))
            index = errorStart + errorCount
        }
        return sections
    }

    /// Avoid the Apple git/xcrun shims: on a fresh Mac they prompt to install developer tools.
    private static let localGit: String? = {
        let paths = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/var/db/xcode_select_link/usr/bin/git",
                     "/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .map { String($0) + "/git" }
        return paths.first {
            $0.hasPrefix("/") && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != "/usr/bin/git"
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    static func parseStatus(_ data: Data) -> [WorkspaceFileChange] {
        let records = nulStrings(data)
        var changes: [WorkspaceFileChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }
            let status = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") {
                if index < records.count { original = records[index]; index += 1 }
            }
            changes.append(WorkspaceFileChange(path: path, indexStatus: status[0],
                                               worktreeStatus: status[1], originalPath: original))
            if changes.count >= maximumEntries { break }
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Appends a pattern matching exactly this file or folder to the Space's `.gitignore`, or to
    /// the repository's `.git/info/exclude`, unless it is already there.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func ignore(_ path: String, isDirectory: Bool, inExclude: Bool, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        var file = "./.gitignore"
        var pattern = ignorePattern(path, isDirectory: isDirectory)
        if inExclude {
            // Exclude patterns are relative to the repository root, not the Space root.
            let lines = String(decoding: try git(location, ["rev-parse", "--show-prefix", "--git-path", "info/exclude"],
                                                 limit: 8_000), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2, !lines[1].isEmpty else { throw WorkspaceFileError.message("No Git repository") }
            file = lines[1].hasPrefix("/") ? lines[1] : "./" + lines[1]
            pattern = ignorePattern(lines[0] + path, isDirectory: isDirectory)
        }
        _ = try shell("f=\(quote(file)); p=\(quote(pattern)); mkdir -p \"$(dirname \"$f\")\" || exit 1; "
                      + "if [ -f \"$f\" ] && grep -qxF -e \"$p\" \"$f\"; then exit 0; fi; "
                      + "if [ -s \"$f\" ] && [ -n \"$(tail -c 1 \"$f\")\" ]; then printf '\\n' >> \"$f\"; fi; "
                      + "printf '%s\\n' \"$p\" >> \"$f\"", at: location, limit: 4_000)
    }

    /// A gitignore pattern anchored at its file's folder that matches only `path`.
    static func ignorePattern(_ path: String, isDirectory: Bool) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if isDirectory { return "/" + escaped + "/" }
        // Git drops trailing spaces unless they are escaped.
        let trailing = escaped.reversed().prefix { $0 == " " }.count
        return "/" + escaped.dropLast(trailing) + String(repeating: "\\ ", count: trailing)
    }

    /// A link to the file at the checked-out commit on the hosting site of the upstream remote
    /// (or `origin`, or the only remote).
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func permalink(_ path: String, at location: WorkspaceFileLocation) throws -> URL {
        try validateRelativePath(path)
        let lines = String(decoding: try git(location, ["rev-parse", "HEAD", "--show-prefix"], limit: 8_000), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { throw WorkspaceFileError.message("No commit checked out") }
        let remotes = String(decoding: (try? git(location, ["remote"], limit: 20_000)) ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let upstream = (try? git(location, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], limit: 4_000))
            .map { String(decoding: $0, as: UTF8.self) }
            .flatMap { value in remotes.first { value.hasPrefix($0 + "/") } }
        guard let remote = upstream ?? (remotes.contains("origin") ? "origin" : remotes.first) else {
            throw WorkspaceFileError.message("The repository has no remote")
        }
        let remoteURL = String(decoding: try git(location, ["remote", "get-url", remote], limit: 8_000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = permalinkURL(remote: remoteURL, commit: lines[0], path: lines[1] + path) else {
            throw WorkspaceFileError.message("Unsupported remote URL: \(remoteURL)")
        }
        return url
    }

    /// Maps SSH (`git@host:owner/repo.git`, `ssh://…`) and HTTPS remotes to the hosting site's
    /// blob URL: GitLab and Bitbucket have their own layouts, anything else uses GitHub's.
    static func permalinkURL(remote: String, commit: String, path: String) -> URL? {
        guard commit.count >= 7, commit.allSatisfy(\.isHexDigit) else { return nil }
        var host: String
        var repository: String
        if let components = URLComponents(string: remote), let scheme = components.scheme,
           ["http", "https", "ssh", "git"].contains(scheme), let value = components.host {
            host = value
            repository = components.path
        } else if let colon = remote.firstIndex(of: ":"), !remote.contains("://") {
            host = String(remote[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            repository = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        repository = repository.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard !host.isEmpty, repository.contains("/") else { return nil }
        let encodedPath = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "#"])) ?? String($0) }
            .joined(separator: "/")
        let layout: String
        if host.contains("gitlab") { layout = "-/blob" }
        else if host.contains("bitbucket") { layout = "src" }
        else if host.contains("codeberg") || host.contains("gitea") { layout = "src/commit" }
        else { layout = "blob" }
        return URL(string: "https://\(host)/\(repository)/\(layout)/\(commit)/\(encodedPath)")
    }

}

/// Shares one load per key between callers that ask at about the same time: a caller waits
/// for a load already running, and reuses a result younger than `maxAge`. A load that
/// `forget()` overtook is returned to its caller but not kept.
final class SharedLoads<Value> {
    private let maxAge: TimeInterval
    private let condition = NSCondition()
    private var results: [String: (time: TimeInterval, value: Value)] = [:]
    private var running: Set<String> = []
    private var generationCount = 0
    private var keyGenerations: [String: Int] = [:]

    init(maxAge: TimeInterval) { self.maxAge = maxAge }

    /// The result of a load of `key` running now, or of one that finished less than `maxAge`
    /// ago, or else of `load`. Without `reusingFinished`, only a load that finishes after this
    /// call is shared: its caller needs results read after it asked.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking, or BlockingWork.run for work on this Mac")
    func value(for key: String, reusingFinished: Bool = true, load: () throws -> Value) throws -> Value {
        condition.lock()
        let asked = ProcessInfo.processInfo.systemUptime
        while running.contains(key) { condition.wait() }
        if let recent = results[key],
           reusingFinished ? ProcessInfo.processInfo.systemUptime - recent.time < maxAge : recent.time >= asked {
            condition.unlock()
            return recent.value
        }
        running.insert(key)
        let startedGeneration = generationCount
        let startedKeyGeneration = keyGenerations[key, default: 0]
        condition.unlock()

        let result = Result { try load() }
        condition.lock()
        running.remove(key)
        if case .success(let value) = result, generationCount == startedGeneration,
           keyGenerations[key, default: 0] == startedKeyGeneration {
            results[key] = (ProcessInfo.processInfo.systemUptime, value)
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }

    func forget() {
        condition.lock()
        results.removeAll()
        generationCount += 1
        condition.unlock()
    }

    func forget(_ key: String) {
        condition.lock()
        results.removeValue(forKey: key)
        keyGenerations[key, default: 0] += 1
        condition.unlock()
    }

    /// Counts `forget()` calls; read before a load whose result is kept with `store`.
    var generation: Int {
        condition.lock()
        defer { condition.unlock() }
        return generationCount
    }

    /// A token for values found outside `value`, such as a root discovered in a batch.
    func generation(for key: String) -> (Int, Int) {
        condition.lock()
        defer { condition.unlock() }
        return (generationCount, keyGenerations[key, default: 0])
    }

    func store(_ value: Value, for key: String, keyGeneration: (Int, Int)) {
        condition.lock()
        if generationCount == keyGeneration.0, keyGenerations[key, default: 0] == keyGeneration.1 {
            results[key] = (ProcessInfo.processInfo.systemUptime, value)
        }
        condition.unlock()
    }

    /// A result younger than `maxAge`, without loading or waiting for a running load.
    func recent(for key: String) -> Value? {
        condition.lock()
        defer { condition.unlock() }
        guard let recent = results[key], ProcessInfo.processInfo.systemUptime - recent.time < maxAge else { return nil }
        return recent.value
    }

    /// Keeps a value found by other work, as if a load had returned it, unless `forget()` ran
    /// since `generation` was read.
    func store(_ value: Value, for key: String, generation: Int) {
        condition.lock()
        if generationCount == generation { results[key] = (ProcessInfo.processInfo.systemUptime, value) }
        condition.unlock()
    }
}

import Darwin
import CryptoKit
import Foundation

struct HerdrMachineProfile: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
}

struct WorkspaceFileLocation: Hashable {
    let machine: HerdrMachineProfile?
    let session: String
    let workspaceID: String
    let workspaceLabel: String
    let root: String

    var identity: String { "\(machine?.id ?? "local")|\(session)|\(workspaceID)|\(root)" }
    var machineLabel: String { machine?.label ?? "Local" }
    var isLocal: Bool { machine == nil }

    func absolutePath(_ relativePath: String) -> String {
        relativePath.isEmpty ? root : (root as NSString).appendingPathComponent(relativePath)
    }
}

struct WorkspaceFileChange: Identifiable {
    let path: String
    let indexStatus: Character
    let worktreeStatus: Character
    let originalPath: String?

    var id: String { path }
    var stageState: StageState {
        guard indexStatus != " " && indexStatus != "?" else { return .none }
        return worktreeStatus == " " ? .all : .partial
    }
    var kind: Kind {
        let statuses = [indexStatus, worktreeStatus]
        if indexStatus == "?" { return .untracked }
        if statuses.contains("U") || (indexStatus == "A" && worktreeStatus == "A")
            || (indexStatus == "D" && worktreeStatus == "D") { return .conflicted }
        if statuses.contains("D") { return .deleted }
        if indexStatus == "A" { return .added }
        if indexStatus == "R" || indexStatus == "C" { return .renamed }
        return .modified
    }
    var statusLabel: String { kind.label }

    enum StageState {
        case none, partial, all

        /// Combines the states of the files under a folder.
        func merged(with other: StageState) -> StageState { self == other ? self : .partial }
    }

    enum Kind: Int {
        case untracked, renamed, modified, added, deleted, conflicted

        var label: String {
            switch self {
            case .modified: return "M"
            case .untracked: return "U"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .conflicted: return "!"
            }
        }
    }
}

struct WorkspaceFileListing {
    let files: [String]
    let changes: [WorkspaceFileChange]
    let hasGit: Bool
    /// Files found before the listing was cut to `maximumFiles`.
    let totalFiles: Int
    /// What Git ignores: its files are in `files`, after tracked and untracked ones; its folders
    /// are listed without their contents, which the explorer reads when one is expanded.
    var ignored = WorkspaceIgnoredEntries()
}

/// Ignored files and folders of a repository, as `git ls-files --ignored --directory` lists them.
struct WorkspaceIgnoredEntries: Equatable {
    private(set) var files: Set<String> = []
    private(set) var directories: Set<String> = []

    init() {}

    /// Folders end in "/". Git also lists entries inside a listed folder; those are dropped, since
    /// the folder stands for everything in it.
    init(gitEntries: [String]) {
        let folders = Set(gitEntries.filter { $0.hasSuffix("/") && $0.count > 1 }.map { String($0.dropLast()) })
        func underFolder(_ path: String) -> Bool {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if folders.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        directories = folders.filter { !underFolder($0) }
        files = Set(gitEntries.filter { !$0.hasSuffix("/") && !$0.isEmpty && !underFolder($0) })
    }

    var isEmpty: Bool { files.isEmpty && directories.isEmpty }

    /// Whether `path` is ignored: listed itself, or inside an ignored folder.
    func contains(_ path: String) -> Bool {
        if files.contains(path) { return true }
        var folder = path
        while !folder.isEmpty {
            if directories.contains(folder) { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// The files and folders directly inside a folder, as paths from the Space root.
struct WorkspaceFolderContents: Equatable {
    var files: [String] = []
    var directories: [String] = []
}

struct WorkspaceFileContents {
    let text: String
    let version: String
    /// Patches of a changed file by scope, for `.change` documents.
    var patches: [WorkspaceDiffScope: String] = [:]
}

/// Which changes a file's diff shows. `.staged` and `.unstaged` exist only when a file has both.
enum WorkspaceDiffScope: String, CaseIterable, Identifiable {
    case all = "All"
    case staged = "Staged"
    case unstaged = "Unstaged"

    var id: Self { self }
}

struct WorkspaceCommit: Identifiable {
    let id: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date

    /// English relative age, e.g. "3 days ago".
    var relativeDate: String {
        let seconds = Date().timeIntervalSince(date)
        if seconds >= 0 && seconds < 60 { return "just now" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var absoluteDate: String { Self.absoluteFormatter.string(from: date) }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct WorkspaceCommitFile: Identifiable {
    let path: String
    /// Source path when Git detected a rename or copy.
    let originalPath: String?
    /// Git's name-status letter: A, M, D, R, C, T.
    let status: Character
    /// Nil for binary files.
    let additions: Int?
    let deletions: Int?

    var id: String { path }
}

struct WorkspaceBranch: Identifiable, Hashable {
    let id: String
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let upstream: String
}

struct WorkspaceWorktree: Identifiable {
    let path: String
    let branch: String?
    let isBare: Bool
    let isLocked: Bool
    let isPrunable: Bool
    var id: String { path }
}

struct WorkspaceBranchStatus {
    /// Nil when HEAD is detached.
    let branch: String?
    let shortHead: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let remotes: [String]
}

enum WorkspaceGitSync {
    case fetch, pull, pullRebase, push, forcePush
    case publish(remote: String, branch: String)

    var title: String {
        switch self {
        case .fetch: return "Fetch"
        case .pull: return "Pull"
        case .pullRebase: return "Pull (Rebase)"
        case .push: return "Push"
        case .forcePush: return "Force Push"
        case .publish: return "Publish"
        }
    }

    var icon: String {
        switch self {
        case .fetch: return "arrow.triangle.2.circlepath"
        case .pull, .pullRebase: return "arrow.down"
        case .push, .forcePush: return "arrow.up"
        case .publish: return "icloud.and.arrow.up"
        }
    }
}

enum WorkspaceCommitMode {
    /// Only what is already staged.
    case staged
    /// Every change to tracked files, like `git commit -a`.
    case tracked
    /// Tracked changes plus untracked files.
    case all
    case amend

    var title: String {
        switch self {
        case .staged: return "Commit"
        case .tracked: return "Commit Tracked"
        case .all: return "Commit All"
        case .amend: return "Amend"
        }
    }
}

struct WorkspaceRepositoryListing {
    let commits: [WorkspaceCommit]
    let branches: [WorkspaceBranch]
    let worktrees: [WorkspaceWorktree]
    let root: String
}

enum WorkspaceFileError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

enum WorkspaceFiles {
    static let maximumFileBytes = 1_000_000
    static let maximumDiffBytes = 2_000_000
    /// Files the explorer lists; it builds their tree once per listing, so this bounds memory and load time only.
    static let maximumFiles = 200_000
    /// Entries read from one expanded ignored folder.
    static let maximumFolderEntries = 5_000
    /// Output read for a file listing: `maximumFiles` paths of about 150 bytes.
    static let maximumListingBytes = 32_000_000
    /// Changes listed by `parseStatus`.
    static let maximumEntries = 2_000

    /// Where the Herdr command is looked for, in order; tests replace it.
    static var herdrCandidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
                                  "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]

    private static func herdrExecutable() throws -> String {
        guard let executable = herdrCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WorkspaceFileError.message("Herdr executable was not found")
        }
        return executable
    }

    static func machines() throws -> [HerdrMachineProfile] {
        let executable = try herdrExecutable()
        let data = try run(executable, ["machine", "list", "--json"], limit: 200_000)
        return try JSONDecoder().decode([HerdrMachineProfile].self, from: data).filter(\.enabled)
    }

    static func remoteSnapshot(_ machine: HerdrMachineProfile) throws -> HerdrSnapshot {
        let executable = try herdrExecutable()
        let data = try run(executable, ["--machine", machine.id, "api", "snapshot"], limit: 8_000_000)
        return try JSONDecoder().decode(RemoteSnapshotResponse.self, from: data).result.snapshot
    }

    static func location(snapshot: HerdrSnapshot, workspaceID: String,
                         session: String, machine: HerdrMachineProfile?) -> WorkspaceFileLocation? {
        guard let workspace = snapshot.workspaces.first(where: { $0.workspaceID == workspaceID }) else { return nil }
        let root = workspace.worktree?.checkoutPath
            ?? snapshot.panes.first(where: { $0.workspaceID == workspaceID && $0.paneID == snapshot.focusedPaneID })?.cwd
            ?? snapshot.panes.first(where: { $0.workspaceID == workspaceID })?.cwd
        guard let root, root.hasPrefix("/") else { return nil }
        return WorkspaceFileLocation(machine: machine, session: session,
                                     workspaceID: workspaceID, workspaceLabel: workspace.label, root: root)
    }

    static func listing(at location: WorkspaceFileLocation) throws -> WorkspaceFileListing {
        let hasGit = (try? git(location, ["rev-parse", "--is-inside-work-tree"], limit: 100)) != nil
        let files: [String]
        let changes: [WorkspaceFileChange]
        var totalFiles: Int?
        var ignored = WorkspaceIgnoredEntries()
        if hasGit {
            let fileData = try git(location, ["ls-files", "--cached", "--others", "--exclude-standard", "-t", "-z", "--", "."],
                                   limit: maximumListingBytes)
            let (tracked, untracked) = trackedFirst(nulStrings(fileData))
            let ignoredData = try git(location, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory",
                                                 "-z", "--", "."], limit: maximumListingBytes)
            ignored = WorkspaceIgnoredEntries(gitEntries: nulStrings(ignoredData))
            let ignoredFiles = ignored.files.sorted()
            totalFiles = tracked.count + untracked.count + ignoredFiles.count
            files = (tracked + untracked + ignoredFiles).prefix(maximumFiles).sorted()
            let status = try git(location, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], limit: 4_000_000)
            changes = parseStatus(status)
        } else if location.machine == nil {
            files = try localFiles(root: location.root)
            changes = []
        } else {
            let script = "cd \(quote(location.root)) && find . -type f -not -path './.git/*' -print0"
            files = nulStrings(try ssh(location.machine!, script, limit: maximumListingBytes))
                .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
                .sorted().prefix(maximumFiles).map { $0 }
            changes = []
        }
        return WorkspaceFileListing(files: files, changes: changes, hasGit: hasGit, totalFiles: totalFiles ?? files.count,
                                    ignored: ignored)
    }

    /// What is directly inside `folder` ("" is the root), for an ignored folder being expanded.
    /// Symbolic links are listed as files.
    static func folderContents(_ folder: String, at location: WorkspaceFileLocation) throws -> WorkspaceFolderContents {
        if !folder.isEmpty { try validateRelativePath(folder) }
        var contents = WorkspaceFolderContents()
        func add(_ name: String, isDirectory: Bool) {
            guard !name.isEmpty, !name.contains("/"), name != ".git",
                  contents.files.count + contents.directories.count < maximumFolderEntries else { return }
            let path = WorkspaceExplorer.path(of: name, in: folder)
            if isDirectory { contents.directories.append(path) } else { contents.files.append(path) }
        }
        if let machine = location.machine {
            let script = "root=$(realpath \(quote(location.root))) || exit 70; "
                + "dir=$(realpath \(quote(location.absolutePath(folder)))) || exit 71; "
                + "case \"$dir\" in \"$root\"|\"$root\"/*) ;; *) echo 'Folder is outside the selected Space' >&2; exit 72;; esac; "
                + "cd \"$dir\" || exit 73; "
                + "for f in .* *; do case \"$f\" in .|..) continue;; esac; "
                + "if [ -d \"$f\" ] && [ ! -L \"$f\" ]; then printf 'd%s\\0' \"$f\"; "
                + "elif [ -e \"$f\" ] || [ -L \"$f\" ]; then printf 'f%s\\0' \"$f\"; fi; done"
            for entry in nulStrings(try ssh(machine, script, limit: maximumListingBytes, label: "ls")) {
                add(String(entry.dropFirst()), isDirectory: entry.hasPrefix("d"))
            }
        } else {
            let base = URL(fileURLWithPath: location.root).resolvingSymlinksInPath()
            let url = folder.isEmpty ? base : base.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
                throw WorkspaceFileError.message("Folder is outside the selected Space")
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) {
                let values = try? item.resourceValues(forKeys: Set(keys))
                add(item.lastPathComponent, isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true)
            }
        }
        return contents
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

    static func read(_ path: String, at location: WorkspaceFileLocation) throws -> WorkspaceFileContents {
        let data = try readData(path, at: location, limit: maximumFileBytes)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.message("Only UTF-8 text files can be edited")
        }
        return WorkspaceFileContents(text: text, version: gitBlobHash(data))
    }

    /// Raw bytes of a file in the Space, e.g. an image referenced by a Markdown preview.
    static func readData(_ path: String, at location: WorkspaceFileLocation, limit: Int) throws -> Data {
        let data: Data
        if let machine = location.machine {
            let script = try remoteFilePrelude(path, at: location)
                + "size=$(wc -c < \"$file\"); [ \"$size\" -le \(limit) ] || { echo 'File is too large' >&2; exit 75; }; cat \"$file\""
            data = try ssh(machine, script, limit: limit)
        } else {
            let url = try localFileURL(path, root: location.root)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limit else { throw WorkspaceFileError.message("File is too large") }
            data = try Data(contentsOf: url)
        }
        guard data.count <= limit else { throw WorkspaceFileError.message("File is too large") }
        return data
    }

    static func save(_ text: String, path: String, expectedVersion: String,
                     at location: WorkspaceFileLocation) throws -> String {
        let data = Data(text.utf8)
        guard data.count <= maximumFileBytes else { throw WorkspaceFileError.message("File is too large") }
        if let machine = location.machine {
            guard expectedVersion.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
                throw WorkspaceFileError.message("Invalid file version")
            }
            let script = try remoteFilePrelude(path, at: location)
                + "current=$(cd / && GIT_DEFAULT_HASH=sha1 git hash-object --no-filters \"$file\") || exit 76; "
                + "[ \"$current\" = \(quote(expectedVersion)) ] || { echo 'File changed on disk; reload before saving' >&2; exit 77; }; "
                + "temp=$(mktemp \"$file.xherdr.XXXXXXXX\") || exit 78; "
                + "trap 'rm -f \"$temp\"' EXIT HUP INT TERM; "
                + "cp -p \"$file\" \"$temp\" && cat > \"$temp\" && mv -f \"$temp\" \"$file\""
            _ = try ssh(machine, script, input: data, limit: 1_000)
        } else {
            let url = try localFileURL(path, root: location.root)
            let original = try Data(contentsOf: url)
            guard gitBlobHash(original) == expectedVersion else {
                throw WorkspaceFileError.message("File changed on disk; reload before saving")
            }
            let permissions = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let temp = url.deletingLastPathComponent().appendingPathComponent(".xherdr-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else {
                throw WorkspaceFileError.message("Could not replace file: \(String(cString: strerror(errno)))")
            }
        }
        return gitBlobHash(data)
    }

    /// A changed file's patches. `.all` compares HEAD with the working tree; `.staged` and
    /// `.unstaged` are added when the file has both kinds of changes.
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
        guard let data = try? git(location, ["cat-file", "blob", revision], limit: maximumFileBytes),
              !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Recent repository listings. When the Files sidebar refreshes, the Git bar and the
    /// repository panel each ask for one; they share a single load instead of running the same
    /// four git commands twice.
    private static let repositoryLoads = SharedLoads<WorkspaceRepositoryListing>(maxAge: 2)

    /// Forgets recently loaded results, so the next load reads the repository again. Git
    /// operations run here do this themselves; an explicit refresh does it for changes made
    /// elsewhere, such as in a terminal.
    static func forgetRecentResults() {
        repositoryLoads.forget()
    }

    static func repository(at location: WorkspaceFileLocation) throws -> WorkspaceRepositoryListing {
        try repositoryLoads.value(for: location.identity) { try loadRepository(at: location) }
    }

    private static func loadRepository(at location: WorkspaceFileLocation) throws -> WorkspaceRepositoryListing {
        let rootData = try git(location, ["rev-parse", "--show-toplevel"], limit: 4_000)
        let root = String(decoding: rootData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let logData = (try? git(location, ["log", "-n", "50", "--format=\(logFormat)"], limit: 200_000)) ?? Data()
        let refData = try git(location, ["for-each-ref", "--format=%(refname)%00%(HEAD)%00%(upstream:short)%00", "refs/heads", "refs/remotes"], limit: 200_000)
        let worktreeData = try git(location, ["worktree", "list", "--porcelain", "-z"], limit: 200_000)
        return WorkspaceRepositoryListing(commits: parseLog(logData), branches: parseBranches(refData),
                                          worktrees: parseWorktrees(worktreeData), root: root)
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
            guard !newBranch.hasPrefix("-"), !newBranch.contains("\0") else {
                throw WorkspaceFileError.message("Invalid branch name")
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
    static func stage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["add", "--", try pathspec(path)], limit: 20_000)
    }

    /// Unstages a file or folder; an empty path unstages everything under the Space root.
    static func unstage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["restore", "--staged", "--", try pathspec(path)], limit: 20_000)
    }

    private static func pathspec(_ path: String) throws -> String {
        if path.isEmpty { return "." }
        try validateRelativePath(path)
        return path
    }

    static func branchStatus(at location: WorkspaceFileLocation) throws -> WorkspaceBranchStatus {
        let data = try git(location, ["status", "--porcelain=v2", "--branch", "--untracked-files=no"], limit: 4_000_000)
        let remoteData = (try? git(location, ["remote"], limit: 20_000)) ?? Data()
        let remotes = String(decoding: remoteData, as: UTF8.self).split(separator: "\n").map(String.init)
        return parseBranchStatus(data, remotes: remotes)
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

    static func switchBranch(_ branch: WorkspaceBranch, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        guard !branch.isRemote, !branch.isCurrent, !branch.name.hasPrefix("-") else {
            throw WorkspaceFileError.message("Choose another local branch")
        }
        _ = try git(location, ["switch", branch.name], limit: 20_000)
    }

    /// Runs a POSIX shell script in the Space root: locally with /bin/sh, remotely over SSH,
    /// so both paths execute the same text.
    static func shell(_ script: String, at location: WorkspaceFileLocation, limit: Int) throws -> Data {
        let rooted = "cd \(quote(location.root)) || exit 3\n" + script
        if let machine = location.machine { return try ssh(machine, rooted, limit: limit) }
        return try run("/bin/sh", ["-c", rooted], limit: limit)
    }

    private static func git(_ location: WorkspaceFileLocation, _ args: [String], input: Data? = nil,
                            limit: Int, timeout: TimeInterval = 15) throws -> Data {
        // No terminal is attached, so credential prompts must fail instead of hanging.
        let label = "git " + (args.first ?? "")
        if let machine = location.machine {
            let remote = (["env", "GIT_TERMINAL_PROMPT=0", "git", "-C", location.root] + args).map(quote).joined(separator: " ")
            return try ssh(machine, remote, input: input, limit: limit, timeout: timeout, label: label)
        }
        guard let localGit else {
            return try run("/usr/bin/env", ["GIT_TERMINAL_PROMPT=0", "git", "-C", location.root] + args,
                           input: input, limit: limit, timeout: timeout, label: label)
        }
        return try run(localGit, ["-C", location.root] + args, environment: ["GIT_TERMINAL_PROMPT": "0"],
                       input: input, limit: limit, timeout: timeout, label: label)
    }

    /// The git that `/usr/bin/git` forwards to. The shim looks it up again on every call, which
    /// takes longer than most git commands the app runs. `nil` when xcrun cannot find one, for
    /// example without the command line tools; git then runs through the shim.
    private static let localGit: String? = {
        guard let data = try? run("/usr/bin/xcrun", ["--find", "git"], limit: 4096, label: "xcrun"),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }()

    private static func localFiles(root: String) throws -> [String] {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsPackageDescendants]) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(rootURL.path + "/") else { continue }
                let path = String(resolved.dropFirst(rootURL.path.count + 1))
                files.append(path)
                if files.count >= maximumFiles { break }
            }
        }
        return files.sorted()
    }

    private static func localFileURL(_ path: String, root: String) throws -> URL {
        try validateRelativePath(path)
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw WorkspaceFileError.message("File is outside the selected Space or is not a regular file")
        }
        return url
    }

    private static func remoteFilePrelude(_ path: String, at location: WorkspaceFileLocation) throws -> String {
        try validateRelativePath(path)
        return "root=$(realpath \(quote(location.root))) || exit 70; "
            + "file=$(realpath \(quote(location.root + "/" + path))) || exit 71; "
            + "case \"$file\" in \"$root\"/*) ;; *) echo 'File is outside the selected Space' >&2; exit 72;; esac; "
            + "[ -f \"$file\" ] || exit 73; "
    }

    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
              !components.contains("") else {
            throw WorkspaceFileError.message("Invalid path outside the selected Space")
        }
    }

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

    private static func nulStrings(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    static func gitBlobHash(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func ssh(_ machine: HerdrMachineProfile, _ command: String,
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15,
                            label: String = "sh") throws -> Data {
        let target: String
        var port: String?
        if machine.target.hasPrefix("ssh://"), let url = URLComponents(string: machine.target),
           let host = url.host {
            target = (url.user.map { "\($0)@" } ?? "") + host
            port = url.port.map(String.init)
        } else {
            target = machine.target
        }
        guard !target.isEmpty, !target.hasPrefix("-") else {
            throw WorkspaceFileError.message("Invalid SSH target")
        }
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let directory = sshControlDirectory {
            // One connection per machine, kept for a minute, instead of a handshake per command.
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(directory)/%C", "-o", "ControlPersist=60"]
        }
        if let port { args += ["-p", port] }
        args += [target, command]
        return try run(sshExecutable, args, input: input, limit: limit, timeout: timeout, label: label, remote: true)
    }

    /// Output of a short read-only script on an SSH machine, e.g. the sidebar's host stats probe.
    static func remoteOutput(_ machine: HerdrMachineProfile, script: String, label: String) throws -> Data {
        try ssh(machine, script, limit: 64_000, timeout: 10, label: label)
    }

    /// Tests replace it with a script that runs the remote command locally.
    static var sshExecutable = "/usr/bin/ssh"

    /// Where SSH keeps the sockets of shared connections: a short path, since socket paths are
    /// limited to about 100 bytes, in a directory only this user can use. Nil turns sharing off.
    private static let sshControlDirectory: String? = {
        let path = "/tmp/xherdr-ssh-\(getuid())"
        mkdir(path, 0o700)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return path
    }()

    /// Runs a process and returns its output. `label` names it in the process log, for
    /// example `git status`, and `remote` marks commands sent over SSH.
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15,
                            label: String? = nil, remote: Bool = false) throws -> Data {
        let start = TerminalPipelineMetrics.now()
        var outputBytes = 0
        var succeeded = false
        defer {
            WorkspaceProcessLog.record(label: label ?? (executable as NSString).lastPathComponent, remote: remote,
                                       start: start, bytes: outputBytes, succeeded: succeeded)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        // Stderr stays apart from the output: SSH writes warnings there even when a command
        // succeeds, and they must not end up in a file's contents or a listing.
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let source = input.map { _ in Pipe() }
        // Without input, a command must not read the app's own stdin; SSH would forward it.
        process.standardInput = source ?? FileHandle.nullDevice
        try process.run()
        // Drained on its own thread, so a command that writes a lot to stderr cannot stall on a full pipe.
        var errorData = Data()
        let errorsRead = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            errorsRead.signal()
        }
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        var inputError: Error?
        if let input, let source {
            do { try source.fileHandleForWriting.write(contentsOf: input) }
            catch { inputError = error }
            try? source.fileHandleForWriting.close()
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                if process.isRunning { process.terminate() }
                break
            }
        }
        process.waitUntilExit()
        timer.cancel()
        errorsRead.wait()
        outputBytes = data.count
        succeeded = process.terminationStatus == 0
        guard data.count <= limit else { throw WorkspaceFileError.message("Output is too large") }
        guard process.terminationStatus == 0 else {
            let message = [errorData, data].lazy
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw WorkspaceFileError.message(message ?? "Command failed")
        }
        if let inputError { throw inputError }
        return data
    }
}

// MARK: File operations

/// Explorer file operations. They run as POSIX shell scripts in the Space root, so local and SSH
/// Spaces share one implementation; every path is Space-relative and prefixed with `./`, so
/// names starting with `-` cannot be read as options.
extension WorkspaceFiles {
    /// Checks one file or folder name typed in the explorer.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              !name.contains("\n") else {
            throw WorkspaceFileError.message("Invalid name")
        }
    }

    /// Creates an empty file, and any missing folders above it; `path` may name a subfolder.
    static func createFile(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseExisting("p")
                      + "mkdir -p \"$(dirname \"$p\")\" && : > \"$p\"", at: location, limit: 4_000)
    }

    static func createFolder(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseExisting("p") + "mkdir -p \"$p\"", at: location, limit: 4_000)
    }

    /// Renames a file or folder in place and returns its new path.
    static func renameItem(_ path: String, to name: String, at location: WorkspaceFileLocation) throws -> String {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        try validateName(name)
        let parent = (path as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? name : parent + "/" + name
        guard destination != path else { return path }
        // A case-only rename finds the file itself on a case-insensitive disk.
        let check = destination.lowercased() == path.lowercased() ? "" : refuseExisting("d")
        _ = try shell("p=\(quote("./" + path)); d=\(quote("./" + destination)); " + check + "mv \"$p\" \"$d\"",
                      at: location, limit: 4_000)
        return destination
    }

    /// Deletes a file or folder permanently.
    static func delete(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("rm -rf \(quote("./" + path))", at: location, limit: 4_000)
    }

    /// Moves a file or folder of a local Space to the Trash.
    static func trash(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        guard location.isLocal else { throw WorkspaceFileError.message("The Trash is only available on this Mac") }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: location.absolutePath(path)), resultingItemURL: nil)
    }

    /// Copies or moves files and folders, given by absolute paths on the Space's machine, into
    /// `directory` ("" is the Space root) and returns their new Space-relative paths. A copy that
    /// would land on an existing name gets a free "name copy" one instead, as in Finder.
    static func paste(_ sources: [String], into directory: String, move: Bool,
                      at location: WorkspaceFileLocation) throws -> [String] {
        defer { forgetRecentResults() }
        if !directory.isEmpty { try validateRelativePath(directory) }
        let target = location.absolutePath(directory)
        let prefix = directory.isEmpty ? "./" : "./" + directory + "/"
        var results: [String] = []
        for source in sources {
            guard source.hasPrefix("/"), source != "/", !source.contains("\0"), !source.contains("\n") else {
                throw WorkspaceFileError.message("Invalid source path")
            }
            let source = source.count > 1 && source.hasSuffix("/") ? String(source.dropLast()) : source
            let name = (source as NSString).lastPathComponent
            try validateName(name)
            let sameFolder = (source as NSString).deletingLastPathComponent == target
            if move {
                guard target != source, !target.hasPrefix(source + "/") else {
                    throw WorkspaceFileError.message("Cannot move \(name) into itself")
                }
                if sameFolder { results.append(String(prefix.dropFirst(2)) + name); continue }
                _ = try shell("s=\(quote(source)); d=\(quote(prefix + name)); " + refuseExisting("d") + "mv \"$s\" \"$d\"",
                              at: location, limit: 4_000)
                results.append(String(prefix.dropFirst(2)) + name)
            } else {
                let candidates = copyNames(for: name, includingOriginal: !sameFolder).map(quote).joined(separator: " ")
                let output = try shell("s=\(quote(source)); for c in \(candidates); do d=\(quote(prefix))\"$c\"; "
                                       + "if [ ! -e \"$d\" ] && [ ! -L \"$d\" ]; then cp -R \"$s\" \"$d\" && printf '%s' \"$c\"; exit; fi; "
                                       + "done; echo 'No free name for the copy' >&2; exit 1",
                                       at: location, limit: 4_000)
                results.append(String(prefix.dropFirst(2)) + String(decoding: output, as: UTF8.self))
            }
        }
        return results
    }

    /// Names tried for a copy: "a.txt", then "a copy.txt", "a copy 2.txt" and so on.
    static func copyNames(for name: String, includingOriginal: Bool) -> [String] {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        let copies = [stem + " copy" + suffix] + (2...99).map { "\(stem) copy \($0)\(suffix)" }
        return (includingOriginal ? [name] : []) + copies
    }

    /// Appends a pattern matching exactly this file or folder to the Space's `.gitignore`, or to
    /// the repository's `.git/info/exclude`, unless it is already there.
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

    /// Stops a script when the path in `variable` exists, even as a broken link.
    private static func refuseExisting(_ variable: String) -> String {
        "if [ -e \"$\(variable)\" ] || [ -L \"$\(variable)\" ]; then echo \"${\(variable)##*/} already exists\" >&2; exit 1; fi; "
    }
}

private struct RemoteSnapshotResponse: Decodable {
    let result: RemoteSnapshotResult
}

private struct RemoteSnapshotResult: Decodable {
    let snapshot: HerdrSnapshot
}

/// Every process `WorkspaceFiles` runs: git, SSH and shell commands behind the file explorer,
/// Git panels, diffs and documents. Each one goes to the metrics file as a `proc` event, and
/// benchmarks can collect them to count the processes an operation starts.
enum WorkspaceProcessLog {
    struct Record {
        let label: String
        let remote: Bool
        let nanos: UInt64
        let bytes: Int
        let succeeded: Bool
    }

    private static let lock = NSLock()
    private static var collected: [Record]?

    static func record(label: String, remote: Bool, start: UInt64, bytes: Int, succeeded: Bool) {
        let nanos = TerminalPipelineMetrics.now() - start
        TerminalPipelineMetrics.shared?.process(label: label, remote: remote, start: start, nanos: nanos,
                                                bytes: bytes, succeeded: succeeded)
        lock.lock()
        collected?.append(Record(label: label, remote: remote, nanos: nanos, bytes: bytes, succeeded: succeeded))
        lock.unlock()
    }

    /// Runs `body` and returns the processes started meanwhile, from any thread.
    static func collect<T>(_ body: () throws -> T) rethrows -> (result: T, processes: [Record]) {
        lock.lock()
        collected = []
        lock.unlock()
        defer {
            lock.lock()
            collected = nil
            lock.unlock()
        }
        let result = try body()
        lock.lock()
        let processes = collected ?? []
        lock.unlock()
        return (result, processes)
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
    private var generation = 0

    init(maxAge: TimeInterval) { self.maxAge = maxAge }

    func value(for key: String, load: () throws -> Value) throws -> Value {
        condition.lock()
        while running.contains(key) { condition.wait() }
        if let recent = results[key], ProcessInfo.processInfo.systemUptime - recent.time < maxAge {
            condition.unlock()
            return recent.value
        }
        running.insert(key)
        let startedGeneration = generation
        condition.unlock()

        let result = Result { try load() }
        condition.lock()
        running.remove(key)
        if case .success(let value) = result, generation == startedGeneration {
            results[key] = (ProcessInfo.processInfo.systemUptime, value)
        }
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }

    func forget() {
        condition.lock()
        results.removeAll()
        generation += 1
        condition.unlock()
    }
}

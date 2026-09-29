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
    static let maximumEntries = 2_000

    static func machines() throws -> [HerdrMachineProfile] {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WorkspaceFileError.message("Herdr executable was not found")
        }
        let data = try run(executable, ["machine", "list", "--json"], limit: 200_000)
        return try JSONDecoder().decode([HerdrMachineProfile].self, from: data).filter(\.enabled)
    }

    static func remoteSnapshot(_ machine: HerdrMachineProfile) throws -> HerdrSnapshot {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WorkspaceFileError.message("Herdr executable was not found")
        }
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
        if hasGit {
            let fileData = try git(location, ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."], limit: 4_000_000)
            files = Array(Set(nulStrings(fileData))).sorted().prefix(maximumEntries).map { $0 }
            let status = try git(location, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], limit: 4_000_000)
            changes = parseStatus(status)
        } else if location.machine == nil {
            files = try localFiles(root: location.root)
            changes = []
        } else {
            let script = "cd \(quote(location.root)) && find . -type f -not -path './.git/*' -print0"
            files = nulStrings(try ssh(location.machine!, script, limit: 4_000_000))
                .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
                .sorted().prefix(maximumEntries).map { $0 }
            changes = []
        }
        return WorkspaceFileListing(files: files, changes: changes, hasGit: hasGit)
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
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            return [.all: "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
                + lines.map { "+" + $0 }.joined(separator: "\n")]
        }
        return [.all: "No text diff available. Open the file to view its contents."]
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

    static func repository(at location: WorkspaceFileLocation) throws -> WorkspaceRepositoryListing {
        let rootData = try git(location, ["rev-parse", "--show-toplevel"], limit: 4_000)
        let root = String(decoding: rootData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let logData = (try? git(location, ["log", "-n", "50", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"], limit: 200_000)) ?? Data()
        let commits = String(decoding: logData, as: UTF8.self).split(separator: "\u{1e}").compactMap { record -> WorkspaceCommit? in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let timestamp = TimeInterval(fields[4]) else { return nil }
            return WorkspaceCommit(id: fields[0], shortHash: fields[1], subject: fields[2], author: fields[3],
                                   date: Date(timeIntervalSince1970: timestamp))
        }
        let refData = try git(location, ["for-each-ref", "--format=%(refname)%00%(HEAD)%00%(upstream:short)%00", "refs/heads", "refs/remotes"], limit: 200_000)
        let refs = String(decoding: refData, as: UTF8.self).split(separator: "\n")
        let branches = refs.compactMap { line -> WorkspaceBranch? in
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
        let worktreeData = try git(location, ["worktree", "list", "--porcelain", "-z"], limit: 200_000)
        var worktrees: [WorkspaceWorktree] = []
        var path: String?
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false
        let worktreeFields = worktreeData.split(separator: 0, omittingEmptySubsequences: false)
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
        return WorkspaceRepositoryListing(commits: commits, branches: branches, worktrees: worktrees, root: root)
    }

    /// Files touched by a commit, compared with its first parent (or the empty tree for a root commit).
    static func commitFiles(_ hash: String, at location: WorkspaceFileLocation) throws -> [WorkspaceCommitFile] {
        try validateCommit(hash)
        let base = ["diff-tree", "-r", "--root", "-m", "--first-parent", "--no-commit-id", "-M", "-z"]
        let statusData = try git(location, base + ["--name-status", hash, "--"], limit: 4_000_000)
        let numstatData = try git(location, base + ["--numstat", hash, "--"], limit: 4_000_000)

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

    private static func validateCommit(_ hash: String) throws {
        guard (4...64).contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
            throw WorkspaceFileError.message("Invalid commit")
        }
    }

    static func addWorktree(at location: WorkspaceFileLocation, path: String,
                            branch: WorkspaceBranch, newBranch: String?) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), path != "/" else {
            throw WorkspaceFileError.message("Enter an absolute worktree path")
        }
        var args = ["worktree", "add"]
        if let newBranch, !newBranch.isEmpty {
            guard !newBranch.hasPrefix("-"), !newBranch.contains("\0") else {
                throw WorkspaceFileError.message("Invalid branch name")
            }
            args += ["-b", newBranch]
        } else if branch.isRemote {
            throw WorkspaceFileError.message("Enter a local branch name for a remote branch")
        }
        args += ["--", path, branch.id]
        _ = try git(location, args, limit: 20_000)
    }

    static func removeWorktree(at location: WorkspaceFileLocation, path: String) throws {
        let repository = try repository(at: location)
        guard path != repository.root,
              let tree = repository.worktrees.first(where: { $0.path == path }),
              !tree.isBare, !tree.isLocked, !tree.isPrunable else {
            throw WorkspaceFileError.message("This worktree cannot be removed")
        }
        _ = try git(location, ["worktree", "remove", "--", path], limit: 20_000)
    }

    static func stage(_ path: String, at location: WorkspaceFileLocation) throws {
        try validateRelativePath(path)
        _ = try git(location, ["add", "--", path], limit: 20_000)
    }

    static func unstage(_ path: String, at location: WorkspaceFileLocation) throws {
        try validateRelativePath(path)
        _ = try git(location, ["restore", "--staged", "--", path], limit: 20_000)
    }

    static func branchStatus(at location: WorkspaceFileLocation) throws -> WorkspaceBranchStatus {
        let data = try git(location, ["status", "--porcelain=v2", "--branch", "--untracked-files=no"], limit: 4_000_000)
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
        let remoteData = (try? git(location, ["remote"], limit: 20_000)) ?? Data()
        let remotes = String(decoding: remoteData, as: UTF8.self).split(separator: "\n").map(String.init)
        return WorkspaceBranchStatus(branch: branch, shortHead: String(oid.prefix(7)), upstream: upstream,
                                     ahead: ahead, behind: behind, remotes: remotes)
    }

    static func sync(_ action: WorkspaceGitSync, at location: WorkspaceFileLocation) throws {
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
        let command = ["GIT_TERMINAL_PROMPT=0", "git", "-C", location.root] + args
        if let machine = location.machine {
            let remote = (["env"] + command).map(quote).joined(separator: " ")
            return try ssh(machine, remote, input: input, limit: limit, timeout: timeout)
        }
        return try run("/usr/bin/env", command, input: input, limit: limit, timeout: timeout)
    }

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
                if files.count >= maximumEntries { break }
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

    private static func parseStatus(_ data: Data) -> [WorkspaceFileChange] {
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

    private static func gitBlobHash(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func ssh(_ machine: HerdrMachineProfile, _ command: String,
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15) throws -> Data {
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
        if let port { args += ["-p", port] }
        args += [target, command]
        return try run("/usr/bin/ssh", args, input: input, limit: limit, timeout: timeout)
    }

    private static func run(_ executable: String, _ arguments: [String],
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let source = input.map { _ in Pipe() }
        if let source { process.standardInput = source }
        try process.run()
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
        guard data.count <= limit else { throw WorkspaceFileError.message("Output is too large") }
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WorkspaceFileError.message(message.isEmpty ? "Command failed" : message)
        }
        if let inputError { throw inputError }
        return data
    }
}

private struct RemoteSnapshotResponse: Decodable {
    let result: RemoteSnapshotResult
}

private struct RemoteSnapshotResult: Decodable {
    let snapshot: HerdrSnapshot
}

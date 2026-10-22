import Darwin
import CryptoKit
import Foundation
import os

struct HerdrMachineProfile: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
}

struct WorkspaceFileLocation: Codable, Hashable {
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

        /// Which change colors a folder holding several: conflicts, then deletions, then
        /// modifications, then new files, as in Zed.
        var folderPriority: Int {
            switch self {
            case .renamed: return 0
            case .untracked, .added: return 1
            case .modified: return 2
            case .deleted: return 3
            case .conflicted: return 4
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
    /// Untracked folders holding another repository, such as a worktree. Git lists each as
    /// "folder/" without its contents, which the explorer reads when one is expanded.
    var nestedRepositories: Set<String> = []
    var symbolicLinks: [String: WorkspaceSymbolicLink] = [:]
    /// True when a folder outside a repository was read only near its root (`WorkspaceFolderWalk`).
    var partial = false
    /// True when the walk of a folder outside a repository stopped at `maximumFiles` files.
    var truncated = false
}

/// The files of a folder outside a Git repository, as `WorkspaceFiles.folderWalk` reads them.
struct WorkspaceFolderWalk: Equatable {
    /// Files found, at most `WorkspaceFiles.maximumFiles`, the shallow ones kept first.
    var files: [String] = []
    /// Files inside skipped folders, when those were read.
    var ignoredFiles: Set<String> = []
    /// Skipped folders, when they were not read.
    var skippedFolders: [String] = []
    /// True when folders with something in them were left unread at the depth or time limit.
    var partial = false
    /// True when more than `WorkspaceFiles.maximumFiles` files were found.
    var truncated = false
    var symbolicLinks: [String: WorkspaceSymbolicLink] = [:]
}

struct WorkspaceSymbolicLink: Equatable {
    let target: String
    let isDirectory: Bool
}

/// Ignored files and folders of a repository, as `git ls-files --ignored --directory` lists them.
/// What Go to File searches at a location.
struct QuickOpenListing: Equatable, Sendable {
    var files: [String] = []
    /// True when the location has more files than `WorkspaceFiles.maximumFiles`.
    var truncated = false
    /// True when Go to File stopped walking a folder outside a repository at its depth or time
    /// limit, so deeper files may be missing.
    var partial = false
    /// The kind of change of each changed file.
    var changes: [String: WorkspaceFileChange.Kind] = [:]
    /// Files Git ignores, listed when asked for.
    var ignored: Set<String> = []
}

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
    var symbolicLinks: [String: WorkspaceSymbolicLink] = [:]
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

    /// The current time for relative ages; snapshot tests fix it.
    static var now: () -> Date = { Date() }

    /// English relative age, e.g. "3 days ago".
    var relativeDate: String { relativeDate(relativeTo: Self.now()) }

    func relativeDate(relativeTo now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds >= 0 && seconds < 60 { return "just now" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: now)
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

struct WorkspaceWorktree: Identifiable, Equatable {
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

/// A file's state on disk, as `WorkspaceFiles.diskVersions` finds it.
enum WorkspaceDiskVersion: Equatable, Sendable {
    /// Its Git blob hash, the version documents keep.
    case present(String)
    case missing
}

enum WorkspaceFiles {
    static let maximumFileBytes = 1_000_000

    static func fileByteLimit(for path: String) -> Int {
        NotebookDocument.supports(path) ? NotebookDocument.maximumFileBytes : maximumFileBytes
    }
    static let maximumDiffBytes = 2_000_000
    /// Files the explorer lists; it builds their tree once per listing, so this bounds memory and load time only.
    /// Tests replace it.
    static var maximumFiles = 200_000
    /// Entries read from one expanded ignored folder.
    static let maximumFolderEntries = 5_000
    /// Output read for a file listing: `maximumFiles` paths of about 150 bytes.
    static let maximumListingBytes = 32_000_000
    /// Changes listed by `parseStatus`.
    static let maximumEntries = 2_000

    static func location(snapshot: HerdrSnapshot, workspaceID: String,
                         session: String, machine: HerdrMachineProfile?) -> WorkspaceFileLocation? {
        guard let workspace = snapshot.workspaces.first(where: { $0.workspaceID == workspaceID }) else { return nil }
        // Herdr names a Space after its first tab's root pane, the first pane of that tab's layout
        // unless panes were moved in around it. Other panes and tabs, and focus, leave it alone,
        // so a `cd` there does not move the files.
        let firstTab = snapshot.tabs.first(where: { $0.workspaceID == workspaceID })?.tabID
        let rootPane = snapshot.layouts.first(where: { $0.tabID == firstTab })?.panes.first?.paneID
        let root = workspace.worktree?.checkoutPath
            ?? snapshot.panes.first(where: { $0.paneID == rootPane })?.cwd
            ?? snapshot.panes.first(where: { $0.tabID == firstTab })?.cwd
            ?? snapshot.panes.first(where: { $0.workspaceID == workspaceID })?.cwd
        guard let root, root.hasPrefix("/") else { return nil }
        return WorkspaceFileLocation(machine: machine, session: session,
                                     workspaceID: workspaceID, workspaceLabel: workspace.label, root: root)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func read(_ path: String, at location: WorkspaceFileLocation) throws -> WorkspaceFileContents {
        let data = try readData(path, at: location, limit: fileByteLimit(for: path))
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.message("Only UTF-8 text files can be edited")
        }
        return WorkspaceFileContents(text: text, version: gitBlobHash(data))
    }

    /// Raw bytes of a file in the Space, e.g. an image referenced by a Markdown preview.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
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

    /// Stage the complete replacement before the final path/version check. This rejects edits
    /// made during preparation (including a slow SSH upload). The final check and rename are
    /// still separate operations: writers that do not coordinate with us can race that interval.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func save(_ text: String, path: String, expectedVersion: String,
                     at location: WorkspaceFileLocation, afterPreparingLocalReplacement: (() throws -> Void)? = nil) throws -> String {
        let data = Data(text.utf8)
        guard data.count <= fileByteLimit(for: path) else { throw WorkspaceFileError.message("File is too large") }
        if let machine = location.machine {
            guard expectedVersion.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
                throw WorkspaceFileError.message("Invalid file version")
            }
            let script = try remoteFilePrelude(path, at: location)
                + "current=$(cd / && GIT_DEFAULT_HASH=sha1 git hash-object --no-filters \"$file\") || exit 76; "
                + "[ \"$current\" = \(quote(expectedVersion)) ] || { echo 'File changed on disk; reload before saving' >&2; exit 77; }; "
                + "temp=$(mktemp \"$file.wooloo.XXXXXXXX\") || exit 78; "
                + "trap 'rm -f \"$temp\"' EXIT HUP INT TERM; "
                + "cp -p \"$file\" \"$temp\" && cat > \"$temp\" || exit 78; "
                + "destination=$file; "
                + (try remoteFilePrelude(path, at: location))
                + "[ \"$file\" = \"$destination\" ] || { echo 'File changed on disk; reload before saving' >&2; exit 77; }; "
                + "current=$(cd / && GIT_DEFAULT_HASH=sha1 git hash-object --no-filters \"$file\") || exit 76; "
                + "[ \"$current\" = \(quote(expectedVersion)) ] || { echo 'File changed on disk; reload before saving' >&2; exit 77; }; "
                + "mv -f \"$temp\" \"$file\""
            _ = try ssh(machine, script, input: data, limit: 1_000)
        } else {
            let url = try localFileURL(path, root: location.root)
            let original = try Data(contentsOf: url)
            guard gitBlobHash(original) == expectedVersion else {
                throw WorkspaceFileError.message("File changed on disk; reload before saving")
            }
            let permissions = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let temp = url.deletingLastPathComponent().appendingPathComponent(".wooloo-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try data.write(to: temp)
            } catch let error as CocoaError {
                // Its message would name the temporary file, which nobody has heard of.
                throw CocoaError(error.code, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url,
                                                        NSUnderlyingErrorKey: error])
            }
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            // A per-call seam lets tests reproduce external edits without sleeps or global hooks.
            try afterPreparingLocalReplacement?()
            guard try localFileURL(path, root: location.root) == url,
                  gitBlobHash(try Data(contentsOf: url)) == expectedVersion else {
                throw WorkspaceFileError.message("File changed on disk; reload before saving")
            }
            guard rename(temp.path, url.path) == 0 else {
                throw WorkspaceFileError.message("Could not replace file: \(String(cString: strerror(errno)))")
            }
        }
        return gitBlobHash(data)
    }

    /// What is on disk now for each of `paths`, in the version `read` and `save` use, to tell open
    /// documents that something else wrote or deleted. Paths whose state could not be learned,
    /// such as when the machine is unreachable, are left out. Over SSH this is one command; on
    /// this Mac a file whose size, modification time and inode are unchanged is not read again.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func diskVersions(_ paths: [String], at location: WorkspaceFileLocation) -> [String: WorkspaceDiskVersion] {
        let paths = Array(Set(paths.filter { (try? validateRelativePath($0)) != nil })).sorted()
        guard !paths.isEmpty else { return [:] }
        var versions: [String: WorkspaceDiskVersion] = [:]
        if let machine = location.machine {
            // A file whose size, times and inode match those of the version last hashed is not
            // read again. The first line is the machine's clock; then one line per path: `-` when
            // it is not a regular file inside the Space, `= stamp` when unchanged, or its hash (`?`
            // when it could not be hashed, e.g. without git, which says nothing about the file)
            // and stamp. `stat -c` is GNU's and BusyBox's, `stat -f` BSD's and macOS's.
            let known = remoteVersions.withLock { cache in paths.map { cache[location.identity + "\0" + $0] } }
            let script = "root=$(realpath \(quote(location.root))) || exit 70; date +%s; "
                + zip(paths, known).map { path, known in
                    "if f=$(realpath \(quote(location.root + "/" + path)) 2>/dev/null) && case \"$f\" in \"$root\"/*) true;; *) false;; esac && [ -f \"$f\" ]; then "
                        + "s=$(stat -c '%s %Y %Z %i' \"$f\" 2>/dev/null || stat -f '%z %m %c %i' \"$f\" 2>/dev/null); "
                        + (known.map { "if [ -n \"$s\" ] && [ \"$s\" = \(quote($0.stamp)) ]; then echo \"= $s\"; else " } ?? "")
                        + "h=$(cd / && GIT_DEFAULT_HASH=sha1 git hash-object --no-filters \"$f\" 2>/dev/null) || h='?'; echo \"$h $s\"; "
                        + (known == nil ? "" : "fi; ")
                        + "else echo -; fi; "
                }.joined()
            guard let output = try? ssh(machine, script, limit: paths.count * 160 + 1_000) else { return [:] }
            var lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last == "" { lines.removeLast() }
            guard lines.count == paths.count + 1, let now = Int(lines.removeFirst()) else { return [:] }
            for ((path, known), line) in zip(zip(paths, known), lines) {
                if line == "-" { versions[path] = .missing; continue }
                let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let stamp = fields.count > 1 ? fields[1] : ""
                if fields[0] == "=", let known, known.stamp == stamp {
                    versions[path] = .present(known.version)
                } else if fields[0].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil {
                    versions[path] = .present(fields[0])
                    // Times are in seconds: a stamp changed in the last two seconds could hide a
                    // write made in the same second, so it is not trusted yet. The status change
                    // time counts too: tools that keep the modification time cannot set it back.
                    let modified = stamp.split(separator: " ").dropFirst().prefix(2).compactMap { Int($0) }.max()
                    remoteVersions.withLock { cache in
                        if cache.count > 500 { cache.removeAll() }
                        let key = location.identity + "\0" + path
                        if let modified, modified <= now - 2 {
                            cache[key] = RemoteVersion(stamp: stamp, version: fields[0])
                        } else {
                            cache[key] = nil
                        }
                    }
                }
            }
            return versions
        }
        let base = URL(fileURLWithPath: location.root).resolvingSymlinksInPath()
        for path in paths {
            let url = base.appendingPathComponent(path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(base.path + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                // Gone, or no longer a file inside the Space; a missing Space root says nothing.
                if FileManager.default.fileExists(atPath: base.path) { versions[path] = .missing }
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            // The status change time too: tools that keep the modification time cannot set it back.
            var status = stat()
            let changed = stat(url.path, &status) == 0 ? status.st_ctimespec : timespec()
            let stamp = LocalFileStamp(size: size,
                                       modified: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                                       changed: Int(changed.tv_sec) * 1_000_000_000 + Int(changed.tv_nsec),
                                       inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            if let known = localVersions.withLock({ $0[url.path] }), known.stamp == stamp {
                versions[path] = .present(known.version)
                continue
            }
            // Far past what any document opens: a version that differs, and the reload explains why.
            guard size <= 64 * 1_024 * 1_024 else { versions[path] = .present("size-\(size)"); continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let version = gitBlobHash(data)
            localVersions.withLock { cache in
                if cache.count > 500 { cache.removeAll() }
                cache[url.path] = LocalVersion(stamp: stamp, version: version)
            }
            versions[path] = .present(version)
        }
        return versions
    }

    private struct LocalFileStamp: Equatable {
        let size: Int
        let modified: TimeInterval
        let changed: Int
        let inode: UInt64
    }

    private struct LocalVersion {
        let stamp: LocalFileStamp
        let version: String
    }

    private struct RemoteVersion {
        let stamp: String
        let version: String
    }

    /// The last version hashed of each SSH file `diskVersions` was asked about, by location and path.
    private static let remoteVersions = OSAllocatedUnfairLock<[String: RemoteVersion]>(initialState: [:])

    /// The last version hashed of each local file `diskVersions` was asked about.
    private static let localVersions = OSAllocatedUnfairLock<[String: LocalVersion]>(initialState: [:])

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

    // Shared by the WorkspaceFiles implementation files.
    static func nulStrings(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    static func gitBlobHash(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
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
    /// Creates an empty file. With `keepingExisting`, a file already at `path` is left as it is
    /// and false is returned, for Go to File, whose listing may not have reached it.
    @discardableResult
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func createFile(_ path: String, at location: WorkspaceFileLocation, keepingExisting: Bool = false) throws -> Bool {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        let existing = keepingExisting ? "if [ -f \"$p\" ]; then echo existing; exit 0; fi; " : ""
        let output = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + existing + refuseExisting("p")
                               + "mkdir -p \"$(dirname \"$p\")\" && : > \"$p\"", at: location, limit: 4_000)
        return String(decoding: output, as: UTF8.self) != "existing\n"
    }

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func createFolder(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + refuseExisting("p") + "mkdir -p \"$p\"",
                      at: location, limit: 4_000)
    }

    /// Renames a file or folder in place and returns its new path.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func renameItem(_ path: String, to name: String, at location: WorkspaceFileLocation) throws -> String {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        try validateName(name)
        let parent = (path as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? name : parent + "/" + name
        guard destination != path else { return path }
        // A case-only rename finds the file itself on a case-insensitive disk.
        let check = destination.lowercased() == path.lowercased() ? "" : refuseExisting("d")
        _ = try shell("p=\(quote("./" + path)); d=\(quote("./" + destination)); " + refuseOutside("p", "d") + check
                      + "mv \"$p\" \"$d\"", at: location, limit: 4_000)
        return destination
    }

    /// Deletes a file or folder permanently.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func delete(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + "rm -rf \"$p\"", at: location, limit: 4_000)
    }

    /// Moves a file or folder of a local Space to the Trash and returns where it went there.
    @discardableResult
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func trash(_ path: String, at location: WorkspaceFileLocation) throws -> String {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        guard location.isLocal else { throw WorkspaceFileError.message("The Trash is only available on this Mac") }
        return try trashItem(URL(fileURLWithPath: location.absolutePath(path))).path
    }

    /// Moves an item to the Trash and returns where it went. Tests replace it, so they leave the Trash alone.
    static var trashItem: (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw WorkspaceFileError.message("\(url.lastPathComponent) was not moved to the Trash") }
        return result as URL
    }

    /// Puts an item moved to the Trash back at `path` in a local Space.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func restore(_ trashed: String, to path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        guard location.isLocal else { throw WorkspaceFileError.message("The Trash is only available on this Mac") }
        let name = (path as NSString).lastPathComponent
        let destination = location.absolutePath(path)
        let files = FileManager.default
        guard (try? files.attributesOfItem(atPath: trashed)) != nil else {
            throw WorkspaceFileError.message("\(name) is no longer in the Trash")
        }
        guard (try? files.attributesOfItem(atPath: destination)) == nil else {
            throw WorkspaceFileError.message("\(name) already exists")
        }
        try files.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try files.moveItem(atPath: trashed, toPath: destination)
    }

    /// Moves a file or folder to another path in the Space, creating the folders above it.
    /// An item already at `destination` is refused.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func moveItem(_ path: String, to destination: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        try validateRelativePath(destination)
        guard destination != path else { return }
        // A case-only rename finds the file itself on a case-insensitive disk.
        let check = destination.lowercased() == path.lowercased() ? "" : refuseExisting("d")
        _ = try shell("p=\(quote("./" + path)); d=\(quote("./" + destination)); " + refuseOutside("p", "d") + check
                      + "mkdir -p \"$(dirname \"$d\")\" && mv \"$p\" \"$d\"", at: location, limit: 4_000)
    }

    /// Copies or moves files and folders, given by absolute paths on the Space's machine, into
    /// `directory` ("" is the Space root) and returns their new Space-relative paths. A copy that
    /// would land on an existing name gets a free "name copy" one instead, as in Finder.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
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
                _ = try shell("s=\(quote(source)); d=\(quote(prefix + name)); " + refuseOutside("d") + refuseExisting("d")
                              + "mv \"$s\" \"$d\"", at: location, limit: 4_000)
                results.append(String(prefix.dropFirst(2)) + name)
            } else {
                let candidates = copyNames(for: name, includingOriginal: !sameFolder).map(quote).joined(separator: " ")
                let output = try shell("t=\(quote(prefix + name)); " + refuseOutside("t") + "s=\(quote(source)); for c in \(candidates); do d=\(quote(prefix))\"$c\"; "
                                       + "if [ ! -e \"$d\" ] && [ ! -L \"$d\" ]; then cp -R \"$s\" \"$d\" && printf '%s' \"$c\"; exit; fi; "
                                       + "done; echo 'No free name for the copy' >&2; exit 1",
                                       at: location, limit: 4_000)
                results.append(String(prefix.dropFirst(2)) + String(decoding: output, as: UTF8.self))
            }
        }
        return results
    }

    /// The most a drop from Finder sends to an SSH machine at once.
    static let maximumImportBytes = 256_000_000

    /// Copies files and folders of this Mac, such as ones dropped from Finder, into `directory`
    /// ("" is the Space root) and returns their new Space-relative paths; a name already taken
    /// gets a free "name copy" one, as a paste does. An SSH machine is sent each one as a tar
    /// archive over the shared connection, unpacked beside its destination and then moved there.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func importItems(_ sources: [String], into directory: String,
                            at location: WorkspaceFileLocation) throws -> [String] {
        guard let machine = location.machine else { return try paste(sources, into: directory, move: false, at: location) }
        defer { forgetRecentResults() }
        if !directory.isEmpty { try validateRelativePath(directory) }
        let prefix = directory.isEmpty ? "./" : "./" + directory + "/"
        var results: [String] = []
        for source in sources {
            let source = source.count > 1 && source.hasSuffix("/") ? String(source.dropLast()) : source
            let name = (source as NSString).lastPathComponent
            try validateName(name)
            // Without COPYFILE_DISABLE, macOS tar adds "._" files carrying extended attributes.
            let archive: Data
            do {
                archive = try run("/usr/bin/tar", ["-c", "-f", "-", "-C", (source as NSString).deletingLastPathComponent, "./" + name],
                                  environment: ["COPYFILE_DISABLE": "1"], limit: maximumImportBytes, timeout: 120, label: "tar")
            } catch WorkspaceFileError.message("Output is too large") {
                throw WorkspaceFileError.message("\(name) is too large to copy to \(machine.label)")
            }
            let candidates = copyNames(for: name, includingOriginal: true).map(quote).joined(separator: " ")
            let script = "cd \(quote(location.root)) || exit 3\n"
                + "t=$(mktemp -d \(quote(prefix + ".wooloo-import.XXXXXXXX"))) || exit 1; "
                + "trap 'rm -rf \"$t\"' EXIT HUP INT TERM; "
                + "tar -x -f - -C \"$t\" || exit 1; "
                + "for c in \(candidates); do d=\(quote(prefix))\"$c\"; "
                + "if [ ! -e \"$d\" ] && [ ! -L \"$d\" ]; then mv \"$t\"/\(quote(name)) \"$d\" && printf '%s' \"$c\"; exit; fi; "
                + "done; echo 'No free name for the copy' >&2; exit 1"
            let output = try ssh(machine, script, input: archive, limit: 4_000, timeout: 300, label: "import")
            results.append(String(prefix.dropFirst(2)) + String(decoding: output, as: UTF8.self))
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

    /// Stops a script when the path in `variable` exists, even as a broken link.
    /// Refuses paths whose folders lead out of the Space, for example through a linked folder.
    /// The item itself may be a link, since `rm` and `mv` act on the link. A folder that does not
    /// exist yet is judged by the nearest one above it that does. Runs from the Space root.
    // Shared by the WorkspaceFiles implementation files.
    static func refuseOutside(_ variables: String...) -> String {
        // Its own variable names, since the caller's script uses short ones such as `d`.
        "space_root=$(pwd -P) || exit 3; inside_space() { space_dir=$(dirname \"$1\"); "
            + "while [ ! -d \"$space_dir\" ]; do space_dir=$(dirname \"$space_dir\"); done; "
            + "space_dir=$(cd \"$space_dir\" && pwd -P) || return 1; "
            + "case \"$space_dir/\" in \"$space_root\"/*) return 0;; esac; return 1; }; "
            + variables.map { "inside_space \"$\($0)\" || { echo 'Path is outside the selected Space' >&2; exit 1; }; " }.joined()
    }

    private static func refuseExisting(_ variable: String) -> String {
        "if [ -e \"$\(variable)\" ] || [ -L \"$\(variable)\" ]; then echo \"${\(variable)##*/} already exists\" >&2; exit 1; fi; "
    }
}

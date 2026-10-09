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

enum WorkspaceFiles {
    static let maximumFileBytes = 1_000_000

    static func fileByteLimit(for path: String) -> Int {
        NotebookDocument.supports(path) ? NotebookDocument.maximumFileBytes : maximumFileBytes
    }
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
    private static var overriddenHerdrCandidates: [String]?
    static var herdrCandidates: [String] {
        get { overriddenHerdrCandidates ?? HerdrRuntimePaths.executableCandidates }
        set { overriddenHerdrCandidates = newValue }
    }

    private static func herdrExecutable() throws -> String {
        guard let executable = herdrCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WorkspaceFileError.message("Herdr executable was not found")
        }
        return executable
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func machines() throws -> [HerdrMachineProfile] {
        let executable = try herdrExecutable()
        let data = try run(executable, ["machine", "list", "--json"], limit: 200_000)
        return try JSONDecoder().decode([HerdrMachineProfile].self, from: data).filter(\.enabled)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    /// How many folders down the walk of a folder outside a repository reads.
    static let folderWalkMaximumDepth = 12
    /// Seconds the walk of a folder outside a repository spends after reading the root; tests replace it.
    static var folderWalkBudget: TimeInterval = 2
    /// Folders the walk outside a repository lists without reading, as Git lists ignored folders,
    /// unless ignored files are asked for. `.git` is never read.
    static let folderWalkSkippedFolders = ["node_modules", ".build", "DerivedData", "__pycache__", ".venv"]

    /// Go to File's files in a folder outside a repository, from `folderWalk`.
    private static func quickOpenFilesWithoutGit(at location: WorkspaceFileLocation,
                                                 includeIgnored: Bool) throws -> QuickOpenListing {
        let walk = try folderWalk(at: location, readingSkipped: includeIgnored)
        return QuickOpenListing(files: walk.files, truncated: walk.truncated, partial: walk.partial,
                                ignored: walk.ignoredFiles)
    }

    /// The explorer's listing of a folder outside a repository: skipped folders are listed like
    /// ignored ones, read when expanded.
    private static func nonGitListing(_ walk: WorkspaceFolderWalk) -> WorkspaceFileListing {
        WorkspaceFileListing(files: walk.files, changes: [], hasGit: false, totalFiles: walk.files.count,
                             ignored: WorkspaceIgnoredEntries(gitEntries: walk.skippedFolders.map { $0 + "/" }),
                             symbolicLinks: walk.symbolicLinks, partial: walk.partial || walk.truncated)
    }

    /// The files of a folder outside a repository, which may be as large as /private/tmp, for the
    /// explorer and Go to File. The walk reads one folder level at a time, so it always has the
    /// files nearest the root, and stops after `folderWalkMaximumDepth` levels or once
    /// `folderWalkBudget` seconds have passed after the root.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func folderWalk(at location: WorkspaceFileLocation, readingSkipped: Bool) throws -> WorkspaceFolderWalk {
        guard let machine = location.machine else {
            return finished(localFolderWalk(root: location.root, readingSkipped: readingSkipped), readingSkipped: readingSkipped)
        }
        let words = folderWalkWords(location, readingSkipped: readingSkipped, links: false)
        let data = try ssh(machine, words.map(quote).joined(separator: " "), limit: maximumListingBytes)
        return finished(folderWalk(records: nulStrings(data)), readingSkipped: readingSkipped)
    }

    /// `folderWalk` on this Mac.
    private static func localFolderWalk(root: String, readingSkipped: Bool) -> WorkspaceFolderWalk {
        let deadline = Date().addingTimeInterval(folderWalkBudget)
        let skipped = readingSkipped ? [] : Set(folderWalkSkippedFolders)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey]
        func entries(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? [])
                .filter { $0.lastPathComponent != ".git" }
        }
        var walk = WorkspaceFolderWalk()
        var level = [(url: URL(fileURLWithPath: root), path: "")]
        var depth = 1
        while !level.isEmpty {
            if depth > folderWalkMaximumDepth {
                // Folders at the limit count as unread only when something besides skipped folders is in them.
                walk.partial = level.contains { entries($0.url).contains { !skipped.contains($0.lastPathComponent) } }
                break
            }
            var next: [(url: URL, path: String)] = []
            for folder in level {
                // The root is always read in full.
                if depth > 1, Date() >= deadline {
                    walk.partial = true
                    return walk
                }
                for entry in entries(folder.url) {
                    let name = entry.lastPathComponent
                    let path = folder.path.isEmpty ? name : folder.path + "/" + name
                    let values = try? entry.resourceValues(forKeys: keys)
                    if values?.isRegularFile == true || values?.isSymbolicLink == true {
                        walk.files.append(path)
                        if walk.files.count > maximumFiles { return walk }
                    } else if values?.isDirectory == true, values?.isPackage != true {
                        if skipped.contains(name) { walk.skippedFolders.append(path) } else { next.append((entry, path)) }
                    }
                }
            }
            level = next
            depth += 1
        }
        return walk
    }

    /// A walk from the records `folderWalkWords` prints: files, skipped folders ending in "/", and
    /// `wooloo-partial` when folders were left unread.
    private static func folderWalk(records: some Sequence<String>) -> WorkspaceFolderWalk {
        var walk = WorkspaceFolderWalk()
        for record in records {
            guard record != "wooloo-partial" else {
                walk.partial = true
                continue
            }
            var path = record.hasPrefix("./") ? String(record.dropFirst(2)) : record
            guard !path.isEmpty else { continue }
            if path.hasSuffix("/") {
                path.removeLast()
                walk.skippedFolders.append(path)
            } else {
                walk.files.append(path)
            }
        }
        return walk
    }

    /// Cuts a walk to `maximumFiles`, keeping the shallow files it found first, sorts it, and marks
    /// the files read inside skipped folders as ignored.
    static func finished(_ walk: WorkspaceFolderWalk, readingSkipped: Bool) -> WorkspaceFolderWalk {
        var walk = walk
        if walk.files.count > maximumFiles {
            walk.files = Array(walk.files.prefix(maximumFiles))
            walk.truncated = true
        }
        walk.files.sort()
        walk.skippedFolders.sort()
        if readingSkipped {
            let names = Set(folderWalkSkippedFolders)
            walk.ignoredFiles = Set(walk.files.filter { $0.split(separator: "/").dropLast().contains { names.contains(String($0)) } })
        }
        return walk
    }

    /// The remote command of `folderWalk`, with the same limits as on this Mac. Each level is read
    /// by `find` on the folders the previous one found, in batches that stop once the time is up,
    /// so a slow level ends the walk with what was found instead of reaching the SSH timeout.
    /// Unreadable folders are skipped, as they are locally. With `links`, link metadata follows a
    /// `wooloo-symbolic-links` record.
    private static func folderWalkWords(_ location: WorkspaceFileLocation, readingSkipped: Bool, links: Bool) -> [String] {
        let skipped = readingSkipped ? [] : folderWalkSkippedFolders
        let unskipped = skipped.map { " ! -name " + quote($0) }.joined()
        let entries = #"find "$@" -mindepth 1 -maxdepth 1 ! -name .git"#
        var batch = #"if [ "$d" -gt 1 ] && [ "$(date +%s)" -ge "$end" ]; then exit 255; fi; "#
            + entries + #" \( -type f -o -type l \) -print0 2>/dev/null; "#
            + entries + " -type d" + unskipped + #" -print0 2>/dev/null >> "$t/next"; "#
        if links { batch += entries + #" -type l -print0 2>/dev/null >> "$t/links"; "# }
        if !skipped.isEmpty {
            batch += entries + #" -type d \( "# + skipped.map { "-name " + quote($0) }.joined(separator: " -o ")
                + #" \) -exec printf '%s/\0' {} + 2>/dev/null; "#
        }
        batch += "exit 0"
        let check = entries + unskipped + " -print 2>/dev/null | head -n 1; exit 0"
        var script = #"cd "$1" || exit 1; t=$(mktemp -d) || exit 1; trap 'rm -rf "$t"' EXIT; "#
            + "b=" + quote(batch) + "; c=" + quote(check) + "; "
            + "end=$(( $(date +%s) + " + String(Int(folderWalkBudget.rounded(.up))) + " )); d=1; export end t d; "
            + #"printf '.\0' > "$t/level"; : > "$t/links"; while [ -s "$t/level" ]; do "#
            + #"if [ "$d" -gt "# + String(folderWalkMaximumDepth) + " ]; then "
            + #"[ -n "$(xargs -0 sh -c "$c" sh < "$t/level" | head -n 1)" ] && printf 'wooloo-partial\0'; break; fi; "#
            + #": > "$t/next"; if ! xargs -0 -n 256 sh -c "$b" sh < "$t/level"; then printf 'wooloo-partial\0'; break; fi; "#
            + #"mv "$t/next" "$t/level"; d=$((d + 1)); done; "#
        if links {
            script += #"printf 'wooloo-symbolic-links\0'; [ -s "$t/links" ] && xargs -0 sh -c "#
                + quote(symbolicLinkMetadataScript) + " sh < \"$t/links\"; "
        }
        return ["sh", "-c", script + "exit 0", "sh", location.root]
    }

    /// What is directly inside `folder` ("" is the root), for an ignored folder being expanded.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
            let script = "root=\(quote(location.root)); dir=\(quote(location.absolutePath(folder))); "
                + "root=$(realpath \"$root\") || exit 70; resolved=$(realpath \"$dir\") || exit 71; "
                + "case \"$resolved/\" in \"$root/\"*) ;; *) echo 'Folder is outside the selected Space' >&2; exit 72;; esac; "
                + "parent=\(quote(folder)); "
                + "while [ -n \"$parent\" ]; do parent=$(dirname \"$parent\"); [ \"$parent\" = . ] && parent=''; "
                + "ancestor=$(realpath \"$root${parent:+/$parent}\") || exit 71; "
                + "[ \"$ancestor\" != \"$resolved\" ] || { echo 'Symbolic link points to an ancestor folder' >&2; exit 72; }; done; "
                + "cd \"$dir\" || exit 73; "
                + "for f in .* *; do case \"$f\" in .|..|.git) continue;; esac; "
                + "if [ -d \"$f\" ]; then printf 'd%s\\0' \"$f\"; "
                + "elif [ -e \"$f\" ] || [ -L \"$f\" ]; then printf 'f%s\\0' \"$f\"; fi; done; "
                + "printf 'wooloo-symbolic-links\\0'; " + symbolicLinkMetadataScript.replacingOccurrences(of: "for p do", with: "for p in .* *; do")
            let records = nulStrings(try ssh(machine, script, limit: maximumListingBytes, label: "ls"))
            let separator = records.firstIndex(of: "wooloo-symbolic-links") ?? records.count
            for entry in records.prefix(separator) {
                add(String(entry.dropFirst()), isDirectory: entry.hasPrefix("d"))
            }
            let metadata = Data((records.dropFirst(separator + 1).joined(separator: "\0") + "\0").utf8)
            for (name, link) in parseSymbolicLinks(metadata) where name != ".git" {
                contents.symbolicLinks[WorkspaceExplorer.path(of: name, in: folder)] = link
            }
        } else {
            let base = URL(fileURLWithPath: location.root).resolvingSymlinksInPath()
            let url = folder.isEmpty ? base : base.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
                throw WorkspaceFileError.message("Folder is outside the selected Space")
            }
            var ancestor = folder
            while !ancestor.isEmpty {
                ancestor = (ancestor as NSString).deletingLastPathComponent
                let parent = base.appendingPathComponent(ancestor).resolvingSymlinksInPath()
                guard url.path != parent.path else {
                    throw WorkspaceFileError.message("Symbolic link points to an ancestor folder")
                }
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) {
                let values = try? item.resourceValues(forKeys: Set(keys))
                var isDirectory: ObjCBool = false
                if values?.isSymbolicLink == true {
                    _ = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                } else {
                    isDirectory = ObjCBool(values?.isDirectory == true)
                }
                add(item.lastPathComponent, isDirectory: isDirectory.boolValue)
            }
            contents.symbolicLinks = localSymbolicLinks(contents.files + contents.directories, root: location.root)
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func read(_ path: String, at location: WorkspaceFileLocation) throws -> WorkspaceFileContents {
        let data = try readData(path, at: location, limit: fileByteLimit(for: path))
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.message("Only UTF-8 text files can be edited")
        }
        return WorkspaceFileContents(text: text, version: gitBlobHash(data))
    }

    /// Raw bytes of a file in the Space, e.g. an image referenced by a Markdown preview.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func save(_ text: String, path: String, expectedVersion: String,
                     at location: WorkspaceFileLocation) throws -> String {
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
                + "cp -p \"$file\" \"$temp\" && cat > \"$temp\" && mv -f \"$temp\" \"$file\""
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    /// A file's text at HEAD and in the index, for the editor's change bars. Nil when that version
    /// doesn't exist or isn't UTF-8 text.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func gitBases(_ path: String, at location: WorkspaceFileLocation) -> (head: String?, index: String?) {
        guard (try? validateRelativePath(path)) != nil else { return (nil, nil) }
        guard let index = blob(":./\(path)", at: location) else { return (nil, nil) }
        return (blob("HEAD:./\(path)", at: location), index)
    }

    /// The Git directory of a local repository, e.g. `.git` or `.git/worktrees/<name>`, which an
    /// editor watches for index and HEAD changes. Nil for SSH locations and outside a repository.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func localGitDirectory(at location: WorkspaceFileLocation) -> String? {
        guard location.isLocal,
              let data = try? git(location, ["rev-parse", "--absolute-git-dir"], limit: 4096),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else { return nil }
        return path
    }

    /// Both paths matter in a linked worktree: index/HEAD are private, refs are shared.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func localGitWatchPaths(at location: WorkspaceFileLocation) -> [String] {
        guard location.isLocal,
              let data = try? git(location, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], limit: 16_384)
        else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func repository(at location: WorkspaceFileLocation) throws -> WorkspaceRepositoryListing {
        if location.machine != nil { return try remoteRefresh(at: location).repository.get() }
        return try repositoryLoads.value(for: location.identity) { try loadRepository(at: location).repository.get() }
    }

    /// The Git bar's branch status and the repository, which it shows together. Over SSH both
    /// come from the refresh batch, which the listing that comes before the Git bar just ran.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
                let records = nulStrings(data)
                let separator = records.firstIndex(of: "wooloo-symbolic-links") ?? records.count
                var walk = finished(folderWalk(records: records.prefix(separator)), readingSkipped: false)
                let metadata = Data((records.dropFirst(separator + 1).joined(separator: "\0") + "\0").utf8)
                let listed = Set(walk.files)
                walk.symbolicLinks = parseSymbolicLinks(metadata).filter { listed.contains($0.key) }
                return nonGitListing(walk)
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func stage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["add", "--", try pathspec(path)], limit: 20_000)
    }

    /// Unstages a file or folder; an empty path unstages everything under the Space root.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func unstage(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        _ = try git(location, ["restore", "--staged", "--", try pathspec(path)], limit: 20_000)
    }

    /// Discards a file's staged and unstaged changes, as Zed's Discard Changes does: a path in
    /// HEAD goes back to its committed version, and one that is not (untracked or newly added) is
    /// deleted. A rename also restores its source.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func fileHistory(_ path: String, at location: WorkspaceFileLocation) throws -> [WorkspaceCommit] {
        try validateRelativePath(path)
        return parseLog(try git(location, ["log", "-n", "100", "--follow", "--format=\(logFormat)", "--", path], limit: 400_000))
    }

    private static func pathspec(_ path: String) throws -> String {
        if path.isEmpty { return "." }
        try validateRelativePath(path)
        return path
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    /// Runs a POSIX shell script in the Space root: locally with /bin/sh, remotely over SSH,
    /// so both paths execute the same text.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func shell(_ script: String, at location: WorkspaceFileLocation, limit: Int) throws -> Data {
        let rooted = "cd \(quote(location.root)) || exit 3\n" + script
        if let machine = location.machine { return try ssh(machine, rooted, limit: limit) }
        return try run("/bin/sh", ["-c", rooted], limit: limit)
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

    /// Runs git commands in order and returns each one's output or error. Locally each is its
    /// own process, as `git` runs it. Over SSH they run in one remote script, which costs one
    /// round trip instead of one per command. Throws only when the batch as a whole fails, for
    /// example when SSH cannot connect.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func gitBatch(_ location: WorkspaceFileLocation, _ sections: [GitSection],
                         timeout: TimeInterval = 15) throws -> [Result<Data, Error>] {
        guard let machine = location.machine else {
            var stopped: Error?
            return sections.map { section in
                if let stopped { return .failure(stopped) }
                let result = Result {
                    if let script = section.script { return try shell(script, at: location, limit: section.limit) }
                    // Reading status must not rewrite the index and trigger our own watcher.
                    return try git(location, section.args, limit: section.limit, timeout: timeout, optionalLocks: false)
                }
                if section.gate, case .failure(let error) = result { stopped = error }
                return result
            }
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
    static func remoteBatchScript(_ commands: [(words: [String], gate: Bool)], otherwise: [String]? = nil) -> String {
        var lines = [
            #"d=$(mktemp -d) || exit 1"#,
            #"trap 'rm -rf "$d"' EXIT"#,
            #"trap 'exit 1' HUP INT TERM"#,
            #"section() { "$@" >"$d/o" 2>"$d/e"; r=$?; "#
                + #"printf 'wooloo-section %s %s %s\n' "$r" $(wc -c <"$d/o") $(wc -c <"$d/e"); "#
                + #"cat "$d/o" "$d/e"; return $r; }"#,
        ]
        let stop = otherwise.map { " || { section " + $0.map(quote).joined(separator: " ") + "; exit 0; }" } ?? " || exit 0"
        for command in commands {
            lines.append("section " + command.words.map(quote).joined(separator: " ") + (command.gate ? stop : ""))
        }
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

    /// What a failed command reports: its errors, or its output when it wrote no errors.
    private static func failureMessage(errors: Data, output: Data) -> String {
        [errors, output].lazy
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Command failed"
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

    /// NUL-delimited metadata keeps spaces, quotes and newlines in link names intact.
    private static let symbolicLinkMetadataScript = #"for p do p=./${p#./}; if [ -L "$p" ]; then target=$(readlink "$p"; printf .); target=${target%?}; target=${target%?}; kind=f; [ -d "$p" ] && kind=d; printf '%s\0%s\0%s\0' "${p#./}" "$target" "$kind"; fi; done"#

    private static let symbolicLinkListingScript =
        "{ git ls-files --cached --others --exclude-standard -z -- .; "
        + "git ls-files --others --ignored --exclude-standard --directory -z -- .; } | xargs -0 sh -c "
        + quote(symbolicLinkMetadataScript) + " sh"

    private static func parseSymbolicLinks(_ data: Data) -> [String: WorkspaceSymbolicLink] {
        let entries = nulStrings(data)
        var links: [String: WorkspaceSymbolicLink] = [:]
        for index in stride(from: 0, to: entries.count - entries.count % 3, by: 3) {
            links[entries[index]] = WorkspaceSymbolicLink(target: entries[index + 1], isDirectory: entries[index + 2] == "d")
        }
        return links
    }

    /// The links among `paths`. A path that is not a valid one inside the Space is skipped, so
    /// one odd entry cannot fail a whole listing.
    private static func localSymbolicLinks(_ paths: [String], root: String) -> [String: WorkspaceSymbolicLink] {
        var links: [String: WorkspaceSymbolicLink] = [:]
        for path in paths {
            guard (try? validateRelativePath(path)) != nil else { continue }
            let absolute = (root as NSString).appendingPathComponent(path)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: absolute) else { continue }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
            links[path] = WorkspaceSymbolicLink(target: target, isDirectory: isDirectory.boolValue)
        }
        return links
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func remoteOutput(_ machine: HerdrMachineProfile, script: String, label: String,
                             limit: Int = 64_000) throws -> Data {
        try ssh(machine, script, limit: limit, timeout: 10, label: label)
    }

    /// Tests replace it with a script that runs the remote command locally.
    static var sshExecutable = "/usr/bin/ssh"

    /// Where SSH keeps the sockets of shared connections: a short path, since socket paths are
    /// limited to about 100 bytes, in a directory only this user can use. Nil turns sharing off.
    private static let sshControlDirectory: String? = {
        let path = "/tmp/wooloo-ssh-\(getuid())"
        mkdir(path, 0o700)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return path
    }()

    private static let processTimeouts = DispatchQueue(label: "dev.wooloo.process-timeouts")

    /// Runs a process and returns its output. `label` names it in the process log, for
    /// example `git status`, and `remote` marks commands sent over SSH.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15,
                            label: String? = nil, remote: Bool = false) throws -> Data {
        let start = TerminalPipelineMetrics.now()
        var outputBytes = 0
        var status: Int32?
        var errorText: String?
        defer {
            WorkspaceProcessLog.record(label: label ?? (executable as NSString).lastPathComponent, remote: remote,
                                       start: start, bytes: outputBytes, status: status, errors: errorText)
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
        // A thread, not a global queue: callers block here on Swift's cooperative threads, and once they
        // reach the system's limit of threads for global queues, work queued there never runs and every
        // caller waits forever.
        var errorData = Data()
        let errorsRead = DispatchSemaphore(value: 0)
        Thread {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            errorsRead.signal()
        }.start()
        // A private serial queue gets a thread beyond that limit too, so the timeout always fires.
        let timer = DispatchSource.makeTimerSource(queue: processTimeouts)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        // Input is written on its own thread too, so a command that prints while it reads cannot fill
        // the output pipe and wait on us while we wait on it. A command that exits early closes the
        // pipe; writing then fails with EPIPE instead of a SIGPIPE that would end the app.
        var inputError: Error?
        var inputWritten: DispatchSemaphore?
        if let input, let source {
            let writer = source.fileHandleForWriting
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                process.terminate()
                timer.cancel()
                throw WorkspaceFileError.message("Could not prepare the command's input")
            }
            let written = DispatchSemaphore(value: 0)
            inputWritten = written
            Thread {
                do { try writer.write(contentsOf: input) }
                catch { inputError = error }
                try? writer.close()
                written.signal()
            }.start()
        }
        var data = Data()
        var readError: Error?
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit {
                    if process.isRunning { process.terminate() }
                    break
                }
            }
        } catch {
            // Stop the command rather than leave it, its threads and its timer behind.
            readError = error
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        timer.cancel()
        // A process the command left running in the background can keep stderr or stdin open after
        // the command exits. Its threads are then left to finish on their own rather than waited on.
        let settled = DispatchTime.now() + 2
        let stderrRead = errorsRead.wait(timeout: settled) == .success
        let inputSettled = inputWritten.map { $0.wait(timeout: settled) == .success } ?? true
        let errorOutput = stderrRead ? errorData : Data()
        outputBytes = data.count
        // A signal means the timeout or the output limit stopped the process.
        status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
        if status != 0 { errorText = String(decoding: errorOutput, as: UTF8.self) }
        if let readError { throw readError }
        guard data.count <= limit else { throw WorkspaceFileError.message("Output is too large") }
        guard process.terminationStatus == 0 else {
            throw WorkspaceFileError.message(failureMessage(errors: errorOutput, output: data))
        }
        if inputSettled, let inputError { throw inputError }
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
    /// Creates an empty file. With `keepingExisting`, a file already at `path` is left as it is
    /// and false is returned, for Go to File, whose listing may not have reached it.
    @discardableResult
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func createFile(_ path: String, at location: WorkspaceFileLocation, keepingExisting: Bool = false) throws -> Bool {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        let existing = keepingExisting ? "if [ -f \"$p\" ]; then echo existing; exit 0; fi; " : ""
        let output = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + existing + refuseExisting("p")
                               + "mkdir -p \"$(dirname \"$p\")\" && : > \"$p\"", at: location, limit: 4_000)
        return String(decoding: output, as: UTF8.self) != "existing\n"
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func createFolder(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + refuseExisting("p") + "mkdir -p \"$p\"",
                      at: location, limit: 4_000)
    }

    /// Renames a file or folder in place and returns its new path.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func delete(_ path: String, at location: WorkspaceFileLocation) throws {
        defer { forgetRecentResults() }
        try validateRelativePath(path)
        _ = try shell("p=\(quote("./" + path)); " + refuseOutside("p") + "rm -rf \"$p\"", at: location, limit: 4_000)
    }

    /// Moves a file or folder of a local Space to the Trash and returns where it went there.
    @discardableResult
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

    /// Appends a pattern matching exactly this file or folder to the Space's `.gitignore`, or to
    /// the repository's `.git/info/exclude`, unless it is already there.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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
    /// Refuses paths whose folders lead out of the Space, for example through a linked folder.
    /// The item itself may be a link, since `rm` and `mv` act on the link. A folder that does not
    /// exist yet is judged by the nearest one above it that does. Runs from the Space root.
    private static func refuseOutside(_ variables: String...) -> String {
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
        /// The exit status; the negated signal when one stopped the process; nil when it never ran.
        let status: Int32?
        var succeeded: Bool { status == 0 }
    }

    private static let lock = NSLock()
    private static var collected: [Record]?
    private static let logger = Logger(subsystem: "dev.wooloo.workspace", category: "process")

    /// Records a finished process. `errors` is its stderr, given only when it failed; failed SSH
    /// commands are logged with it, since SSH reports there why a connection or command failed.
    static func record(label: String, remote: Bool, start: UInt64, bytes: Int, status: Int32?, errors: String? = nil) {
        let nanos = TerminalPipelineMetrics.now() - start
        TerminalPipelineMetrics.shared?.process(label: label, remote: remote, start: start, nanos: nanos,
                                                bytes: bytes, status: status)
        if remote, status != 0 {
            // 255 is SSH's own failure (connection, shared connection or authentication);
            // other statuses come from the remote command.
            let statusText = status.map(String.init) ?? "none"
            let reason = summary(of: errors ?? "")
            logger.error("SSH \(label, privacy: .public) failed: status \(statusText, privacy: .public) after \(nanos / 1_000_000) ms, \(bytes) output bytes; stderr: \(reason, privacy: .public)")
        }
        lock.lock()
        collected?.append(Record(label: label, remote: remote, nanos: nanos, bytes: bytes, status: status))
        lock.unlock()
    }

    /// Stderr for the log: the last lines, cut to 1,000 characters, with credentials in URLs
    /// (`https://user:token@host`) removed.
    static func summary(of errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline).suffix(8).joined(separator: " | ")
        let redacted = lines.replacingOccurrences(of: #"://[^/@\s]+@"#, with: "://<redacted>@", options: .regularExpression)
        return String(redacted.suffix(1_000))
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
    private var generationCount = 0
    private var keyGenerations: [String: Int] = [:]

    init(maxAge: TimeInterval) { self.maxAge = maxAge }

    /// The result of a load of `key` running now, or of one that finished less than `maxAge`
    /// ago, or else of `load`. Without `reusingFinished`, only a load that finishes after this
    /// call is shared: its caller needs results read after it asked.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
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

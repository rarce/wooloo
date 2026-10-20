import Darwin
import Foundation

// Implementation of the shared WorkspaceFiles facade.
extension WorkspaceFiles {
    /// File records the SSH walk prints at most: one name more than `maximumFiles`, so a walk cut
    /// there is truncated, and the empty record, `wooloo-partial` and `wooloo-end` that can
    /// follow; names beyond `maximumFiles` are cut by `finished`.
    static var folderWalkMaximumFileRecords: Int { maximumFiles + 3 }
    /// Byte budget of the entire SSH walk, including link metadata; tests replace it.
    /// A result that fills this budget is conservatively considered truncated.
    static var folderWalkMaximumBytes = maximumListingBytes
    /// Records the SSH walk prints at most before its link metadata: its files, then its linked
    /// and skipped folders, which have room for 1,000 records when the files take theirs. As when
    /// they shared one budget with the files, skipped folders past it are left out.
    /// `folderWalkMaximumBytes` separately bounds long paths and link metadata.
    static var folderWalkMaximumRecords: Int { folderWalkMaximumFileRecords + 1_000 }
    /// Links the SSH walk describes in full at most, the first it finds: each costs a `readlink`,
    /// about 0.6 ms on one CPU, so 5,000 take about 3 s.
    static let folderWalkMaximumLinks = 5_000
    /// Links after the first `folderWalkMaximumLinks` that the SSH walk looks at with the shell's
    /// own tests, about 7 µs each on one CPU, to list the linked folders among them, without
    /// their targets; a linked folder found after these shows as a file.
    static let folderWalkMaximumFolderLinks = 50_000
    /// How many folders down the walk of a folder outside a repository reads.
    static let folderWalkMaximumDepth = 12
    /// Seconds the walk of a folder outside a repository spends after reading the root; tests replace it.
    static var folderWalkBudget: TimeInterval = 2
    /// Folders the walk outside a repository lists without reading, as Git lists ignored folders,
    /// unless ignored files are asked for. `.git` is never read.
    static let folderWalkSkippedFolders = ["node_modules", ".build", "DerivedData", "__pycache__", ".venv"]

    /// Go to File's files in a folder outside a repository, from `folderWalk`.
    // Shared by the WorkspaceFiles implementation files.
    static func quickOpenFilesWithoutGit(at location: WorkspaceFileLocation,
                                                 includeIgnored: Bool) throws -> QuickOpenListing {
        let walk = try folderWalk(at: location, readingSkipped: includeIgnored)
        return QuickOpenListing(files: walk.files, truncated: walk.truncated, partial: walk.partial,
                                ignored: walk.ignoredFiles)
    }

    /// The explorer's listing of a folder outside a repository: skipped folders are listed like
    /// ignored ones, read when expanded.
    // Shared by the WorkspaceFiles implementation files.
    static func nonGitListing(_ walk: WorkspaceFolderWalk) -> WorkspaceFileListing {
        WorkspaceFileListing(files: walk.files, changes: [], hasGit: false, totalFiles: walk.files.count,
                             ignored: WorkspaceIgnoredEntries(gitEntries: walk.skippedFolders.map { $0 + "/" }),
                             symbolicLinks: walk.symbolicLinks, partial: walk.partial || walk.truncated,
                             truncated: walk.truncated)
    }

    /// The files of a folder outside a repository, which may be as large as /private/tmp, for the
    /// explorer and Go to File. The walk reads one folder level at a time, so it always has the
    /// files nearest the root, and stops after `folderWalkMaximumDepth` levels or once
    /// `folderWalkBudget` seconds have passed after the root.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func folderWalk(at location: WorkspaceFileLocation, readingSkipped: Bool) throws -> WorkspaceFolderWalk {
        guard let machine = location.machine else {
            return finished(localFolderWalk(root: location.root, readingSkipped: readingSkipped), readingSkipped: readingSkipped)
        }
        let words = folderWalkWords(location, readingSkipped: readingSkipped, links: false)
        let data = try ssh(machine, words.map(quote).joined(separator: " "), limit: maximumListingBytes)
        return folderWalk(scriptOutput: data, readingSkipped: readingSkipped)
    }

    /// A walk from the output of `folderWalkScript` without links.
    static func folderWalk(scriptOutput data: Data, readingSkipped: Bool) -> WorkspaceFolderWalk {
        let output = boundedFolderWalkOutput(data)
        var walk = finished(folderWalk(records: folderWalkRecords(output.data)),
                            readingSkipped: readingSkipped)
        walk.truncated = walk.truncated || output.truncated
        return walk
    }

    /// A walk from the output of `folderWalkScript` with links: those it lists, described in
    /// full, and the linked folders past them, without their targets.
    static func folderWalk(linkedScriptOutput data: Data) -> WorkspaceFolderWalk {
        let output = boundedFolderWalkOutput(data)
        let sections = folderWalkSections(output.data)
        var walk = finished(folderWalk(records: sections.records), readingSkipped: false)
        walk.truncated = walk.truncated || output.truncated
        let listed = Set(walk.files)
        walk.symbolicLinks = walk.symbolicLinks.merging(parseSymbolicLinks(sections.linkMetadata)) { _, full in full }
            .filter { listed.contains($0.key) }
        return walk
    }

    /// `head -c` can stop anywhere, including in UTF-8 or a section marker. Only the
    /// NUL-terminated prefix is usable. An unfinished section still drops its last record:
    /// the NUL might belong to a time-limit marker whose remaining bytes were cut off.
    private static func boundedFolderWalkOutput(_ data: Data) -> (data: Data, truncated: Bool) {
        guard data.count >= folderWalkMaximumBytes else { return (data, false) }
        guard let lastNUL = data.lastIndex(of: 0) else { return (Data(), true) }
        return (Data(data[...lastNUL]), true)
    }

    /// Seconds on a clock that only moves forward, for the walk's time limit; tests replace it.
    static var folderWalkClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Entries of one folder the walk on this Mac reads between looks at `folderWalkClock`.
    static let folderWalkClockInterval = 256

    /// `folderWalk` on this Mac. It follows the specification above `folderWalkScript`, and
    /// `WorkspaceFilesRemoteTests` checks that both find the same files; it differs only in leaving
    /// out macOS packages, which `find` cannot tell from folders. Folders are read with `readdir`
    /// rather than `FileManager`, which reads them whole, so the time limit can stop inside one.
    private static func localFolderWalk(root: String, readingSkipped: Bool) -> WorkspaceFolderWalk {
        let deadline = folderWalkClock() + folderWalkBudget
        let skipped = readingSkipped ? [] : Set(folderWalkSkippedFolders)
        var walk = WorkspaceFolderWalk()
        var level = [(absolute: root, path: "")]
        var depth = 1
        while !level.isEmpty {
            if depth > folderWalkMaximumDepth {
                // Folders at the limit count as unread only when something besides skipped folders is in them.
                walk.partial = level.contains { folder in
                    var unread = false
                    forEachFolderEntry(in: folder.absolute) { name, _ in
                        unread = !skipped.contains(name)
                        return !unread
                    }
                    return unread
                }
                break
            }
            // The root is always read in full.
            let timed = depth > 1
            var next: [(absolute: String, path: String)] = []
            for folder in level {
                if timed, folderWalkClock() >= deadline {
                    walk.partial = true
                    return walk
                }
                var read = 0
                var stopped = false
                forEachFolderEntry(in: folder.absolute) { name, kind in
                    read += 1
                    if timed, read.isMultiple(of: folderWalkClockInterval), folderWalkClock() >= deadline {
                        walk.partial = true
                        stopped = true
                        return false
                    }
                    let path = folder.path.isEmpty ? name : folder.path + "/" + name
                    switch kind {
                    case .file:
                        walk.files.append(path)
                        if walk.files.count > maximumFiles {
                            stopped = true
                            return false
                        }
                    case .folder:
                        let absolute = folder.absolute + "/" + name
                        guard !isPackage(absolute) else { break }
                        if skipped.contains(name) { walk.skippedFolders.append(path) } else { next.append((absolute, path)) }
                    case .other:
                        break
                    }
                    return true
                }
                if stopped { return walk }
            }
            level = next
            depth += 1
        }
        return walk
    }

    private enum FolderEntryKind {
        /// A regular file or a symbolic link, which the walk lists without following.
        case file
        case folder
        /// Sockets, pipes and devices, which the walk leaves out.
        case other
    }

    /// Calls `visit` with the name and kind of each entry in the folder at `path`, besides `.`,
    /// `..` and `.git`, until it returns false. Names that are not UTF-8 are left out, as the SSH
    /// walk leaves them out; an unreadable folder has no entries.
    private static func forEachFolderEntry(in path: String, _ visit: (String, FolderEntryKind) -> Bool) {
        guard let directory = opendir(path) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != "..", name != ".git" else { continue }
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var info = stat()
                guard lstat(path + "/" + name, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: type = DT_REG
                case S_IFLNK: type = DT_LNK
                case S_IFDIR: type = DT_DIR
                default: break
                }
            }
            let kind: FolderEntryKind = switch type {
            case DT_REG, DT_LNK: .file
            case DT_DIR: .folder
            default: .other
            }
            guard visit(name, kind) else { return }
        }
    }

    /// Whether the folder at `path` is a macOS package, such as an app, which the walk leaves out.
    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// The output of `folderWalkScript` with links: the walk's records, and the link metadata
    /// after its `wooloo-symbolic-links` record, which is left as printed since a link or its
    /// target can be named like the walk's markers.
    static func folderWalkSections(_ data: Data) -> (records: [String], linkMetadata: Data) {
        let marker = Data("wooloo-symbolic-links".utf8)
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard let separator = fields.first(where: { $0.elementsEqual(marker) }) else {
            return (folderWalkRecords(data), Data())
        }
        let metadataStart = min(separator.endIndex + 1, data.endIndex)
        return (folderWalkRecords(data[data.startIndex..<separator.startIndex]), Data(data[metadataStart...]))
    }

    /// The records of `folderWalkScript`'s output, in order. A walk stopped by its time limit can
    /// leave the last record before its `wooloo-partial`, or the last skipped folder before
    /// `wooloo-files`, cut short; those markers are always printed after a NUL, so a record
    /// directly before one, with no empty record between, was cut and is dropped. Names from
    /// `find` start with "./", so none is taken for a marker.
    static func folderWalkRecords(_ data: Data) -> [String] {
        var records: [String] = []
        var previousIsRecord = false
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            // Names that are not UTF-8 are left out, as locally.
            guard let record = String(data: Data(field), encoding: .utf8) else {
                previousIsRecord = false
                continue
            }
            let afterNUL = record == "wooloo-partial" || record == "wooloo-files"
            if afterNUL, previousIsRecord { records.removeLast() }
            previousIsRecord = !record.isEmpty && !afterNUL
            if !record.isEmpty { records.append(record) }
        }
        return records
    }

    private enum FolderWalkSection { case files, linkedFolders, skippedFolders, done }

    /// A walk from the records `folderWalkScript` prints: files, `wooloo-partial` when folders
    /// were left unread, and `wooloo-end`; then linked folders after `wooloo-linked-folders`,
    /// and skipped folders between `wooloo-skipped` and `wooloo-files`. Without its
    /// `wooloo-end`, the walk was cut at `folderWalkMaximumFileRecords` and is truncated; its
    /// last name is dropped, since it may be one the time limit cut short. Skipped folders cut
    /// at `folderWalkMaximumRecords`, without their `wooloo-files`, are left out.
    private static func folderWalk(records: some Sequence<String>) -> WorkspaceFolderWalk {
        var walk = WorkspaceFolderWalk()
        var section = FolderWalkSection.files
        var lastIsFile = false
        // The files end at `wooloo-end`, or, cut, where the next section or the records begin.
        var filesEnded = false
        func endFiles(complete: Bool) {
            guard !filesEnded else { return }
            filesEnded = true
            if !complete {
                walk.truncated = true
                if lastIsFile { walk.files.removeLast() }
            }
        }
        for record in records {
            var isFile = false
            switch record {
            case "wooloo-end":
                endFiles(complete: true)
            case "wooloo-partial":
                // Locally, a walk past `maximumFiles` files stops there, without reading further.
                if walk.files.count <= maximumFiles { walk.partial = true }
            case "wooloo-linked-folders":
                endFiles(complete: false)
                section = .linkedFolders
            case "wooloo-skipped":
                endFiles(complete: false)
                section = .skippedFolders
            case "wooloo-files":
                section = .done
            default:
                let path = record.hasPrefix("./") ? String(record.dropFirst(2)) : record
                guard !path.isEmpty else { continue }
                switch section {
                case .files:
                    if !filesEnded {
                        walk.files.append(path)
                        isFile = true
                    }
                case .linkedFolders: walk.symbolicLinks[path] = WorkspaceSymbolicLink(target: "", isDirectory: true)
                case .skippedFolders: walk.skippedFolders.append(path)
                case .done: break
                }
            }
            lastIsFile = isFile
        }
        endFiles(complete: false)
        // Skipped folders cut at `folderWalkMaximumRecords`: the last may be one the time limit cut
        // short. The files were all read, so the walk is not partial for that.
        if section == .skippedFolders, !walk.skippedFolders.isEmpty { walk.skippedFolders.removeLast() }
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

    // Shared by the WorkspaceFiles implementation files.
    static func folderWalkWords(_ location: WorkspaceFileLocation, readingSkipped: Bool, links: Bool) -> [String] {
        ["sh", "-c", folderWalkScript(readingSkipped: readingSkipped, links: links), "sh", location.root]
    }

    /// The SSH command of `folderWalk`, run as `sh -c <script> sh <root>`.
    ///
    /// The walk outside a repository has two implementations, this script and
    /// `localFolderWalk`, which must find the same files (`WorkspaceFilesRemoteTests` runs both on
    /// the same folders). One script for both would make the walk on this Mac about twice as slow
    /// (docs/perf/README.md) and lose its package check. Both follow this specification:
    /// - Levels are read in turn, the root first, up to `folderWalkMaximumDepth` levels; past that,
    ///   the walk is partial when a folder at the limit holds anything besides skipped folders.
    /// - Regular files and symbolic links, unfollowed, are files; sockets, pipes and devices are
    ///   left out, as are `.git` and unreadable folders, and names that are not UTF-8.
    /// - Folders named in `folderWalkSkippedFolders` are listed, not read, unless `readingSkipped`.
    /// - After the root, which is always read in full, the walk stops once `folderWalkBudget`
    ///   seconds have passed since it started, also inside a folder, and is then partial. Files
    ///   found until then are kept.
    /// - Anywhere, the root included, the walk stops once it found more than `maximumFiles` files
    ///   and is then truncated; over SSH, after `folderWalkMaximumFileRecords` records. Over SSH
    ///   only, skipped folders past `folderWalkMaximumRecords` records in all are left out.
    ///
    /// Each level is read by `find` on the folders the previous one found, 256 folders per batch.
    /// A watchdog marks the time as up and stops the `find` running then, so neither a slow level
    /// nor one huge folder reaches the SSH timeout. The records it prints are those of
    /// `folderWalkRecords`: the files, ending with `wooloo-end`, then the skipped folders and,
    /// with `links`, the linked folders past the first `maximumLinks` links; then link metadata
    /// follows a `wooloo-symbolic-links` record. The files pass through `head`, with NUL and
    /// newline swapped around it, so the walk stops after `folderWalkMaximumFileRecords` of them, also inside
    /// the root, and its output stays under the SSH output limit; the walk is then truncated, as
    /// on this Mac. Once `head` is done it marks "$t/cut", and the next `find` ends the walk there:
    /// a write into the pipe may not fail for a while, since `tr` buffers what it passes on. All
    /// these records pass through a second `head`, which stops at `folderWalkMaximumRecords`. The
    /// first `maximumLinks` links found are described in full, cut or not, and the next
    /// `folderWalkMaximumFolderLinks` only when they are linked folders, without their targets.
    static func folderWalkScript(readingSkipped: Bool, links: Bool, maximumLinks: Int = folderWalkMaximumLinks) -> String {
        let skipped = readingSkipped ? [] : folderWalkSkippedFolders
        let unskipped = skipped.map { " ! -name " + quote($0) }.joined()
        let entries = #"find "$@" -mindepth 1 -maxdepth 1 ! -name .git"#
        // `run_find` runs one find of a batch. After the root, the watchdog can stop it: it is
        // started in the background and its process ID left in "$t/pid" for the watchdog, which
        // marks the time as up ("$t/late") before reading that file, while `run_find` writes it
        // before checking the mark, so one of them always stops it. The batch then ends with
        // status 255, as it does once `head` has cut the walk ("$t/cut"). (Not `r`, which some
        // shells, such as mksh, define as an alias.) No find runs a command with -exec: a command
        // it started would outlive it and print after the walk.
        var batch = #"run_find() { [ ! -e "$t/cut" ] || exit 255; if [ "$d" -eq 1 ]; then "$@"; return 0; fi; "$@" & p=$!; echo "$p" > "$t/pid"; "#
            + #"[ -e "$t/late" ] && kill "$p" 2>/dev/null; wait "$p"; : > "$t/pid"; [ ! -e "$t/late" ] || exit 255; }; "#
            + #"if [ "$d" -gt 1 ] && [ -e "$t/late" ]; then exit 255; fi; "#
        // Links are collected first, so a walk cut in a huge folder still has those it lists there;
        // no folder adds more than the walk looks at. Skipped folders are collected too, and
        // printed after the files, so that they do not count against `folderWalkMaximumFileRecords`.
        let swap = #"tr '\000\n' '\n\000'"#
        let examinedLinks = maximumLinks + folderWalkMaximumFolderLinks
        if links {
            batch += "run_find " + entries + " -type l -print0 2>/dev/null | " + swap + " | head -n " + String(examinedLinks)
                + " | " + swap + #" >> "$t/links"; "#
        }
        batch += "run_find " + entries + #" \( -type f -o -type l \) -print0 2>/dev/null; "#
            + "run_find " + entries + " -type d" + unskipped + #" -print0 2>/dev/null >> "$t/next"; "#
        if !skipped.isEmpty {
            batch += "run_find " + entries + #" -type d \( "#
                + skipped.map { "-name " + quote($0) }.joined(separator: " -o ")
                + #" \) -print0 2>/dev/null >> "$t/skipped"; "#
        }
        batch += "exit 0"
        let check = entries + unskipped + " -print 2>/dev/null | head -n 1; exit 0"
        // `sleep` takes whole seconds in POSIX, so the budget is rounded up. The watchdog stops its
        // `sleep` when it is stopped itself at the end, and is waited for before "$t" is removed,
        // so nothing is left running or writing there.
        let seconds = Int(folderWalkBudget.rounded(.up))
        let watchdog = seconds <= 0
            ? #": > "$t/late"; "#
            : #"( trap 'kill "$s" 2>/dev/null; exit 0' TERM; sleep "# + String(seconds) + #" & s=$!; wait "$s"; "#
                + #": > "$t/late"; read p < "$t/pid" && kill "$p" ) > /dev/null 2>&1 & w=$!; "#
        // In the C locale, `tr` passes bytes that are not UTF-8 through unchanged.
        var script = #"LC_ALL=C; export LC_ALL; cd "$1" || exit 1; t=$(mktemp -d) || exit 1; w=; trap '[ -n "$w" ] && kill "$w" 2>/dev/null && wait "$w"; rm -rf "$t"' EXIT; "#
            + "b=" + quote(batch) + "; c=" + quote(check) + "; d=1; export t d; "
            + #": > "$t/pid"; "# + watchdog
            + #"printf '.\0' > "$t/level"; : > "$t/links"; : > "$t/skipped"; "#
        var records = #"{ while [ -s "$t/level" ]; do "#
            + #"if [ "$d" -gt "# + String(folderWalkMaximumDepth) + " ]; then "
            + #"[ -n "$(xargs -0 sh -c "$c" sh < "$t/level" | head -n 1)" ] && printf '\0wooloo-partial\0'; break; fi; "#
            + #": > "$t/next"; if ! xargs -0 -n 256 sh -c "$b" sh < "$t/level"; then printf '\0wooloo-partial\0'; break; fi; "#
            + #"mv "$t/next" "$t/level"; d=$((d + 1)); done; printf 'wooloo-end\0'; } 2>/dev/null "#
            + "| " + swap + " | { head -n " + String(folderWalkMaximumFileRecords) + #"; : > "$t/cut"; }; "#
        // Records stay swapped, a line each, until the second `head`. Linked folders go before
        // skipped folders, which the explorer lists anyway. The last skipped folder may be one the
        // time limit cut short: the newline before `wooloo-files` ends it, and `folderWalkRecords`
        // drops it.
        if links {
            // Within the walk's time limit: `[ -d ]` follows each link, which can be slow.
            let folderLinks = #"for p do [ ! -e "$t/late" ] || break; p=./${p#./}; [ -L "$p" ] && [ -d "$p" ] && printf '%s\0' "$p"; done; exit 0"#
            records += #"printf 'wooloo-linked-folders\n'; [ -s "$t/links" ] && "# + swap + #" < "$t/links" | tail -n +"#
                + String(maximumLinks + 1) + " | head -n " + String(folderWalkMaximumFolderLinks) + " | " + swap
                + " | xargs -0 sh -c " + quote(folderLinks) + " sh | " + swap + "; "
        }
        if !skipped.isEmpty {
            records += #"printf 'wooloo-skipped\n'; "# + swap + #" < "$t/skipped"; printf '\nwooloo-files\n'; "#
        }
        // Bound every section together, including metadata, before SSH's strict output limit.
        script += "{ { " + records + "} | head -n " + String(folderWalkMaximumRecords) + " | " + swap + "; "
        if links {
            script += #"printf 'wooloo-symbolic-links\0'; [ -s "$t/links" ] && "# + swap + #" < "$t/links" | head -n "#
                + String(maximumLinks) + " | " + swap + " | xargs -0 sh -c " + quote(symbolicLinkMetadataScript) + " sh; "
        }
        return script + "} | head -c " + String(folderWalkMaximumBytes) + "; exit 0"
    }

    /// What is directly inside `folder` ("" is the root), for an ignored folder being expanded.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
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

    /// NUL-delimited metadata keeps spaces, quotes and newlines in link names intact.
    private static let symbolicLinkMetadataScript = #"for p do p=./${p#./}; if [ -L "$p" ]; then target=$(readlink "$p"; printf .); target=${target%?}; target=${target%?}; kind=f; [ -d "$p" ] && kind=d; printf '%s\0%s\0%s\0' "${p#./}" "$target" "$kind"; fi; done"#

    // Shared by the WorkspaceFiles implementation files.
    static let symbolicLinkListingScript =
        "{ git ls-files --cached --others --exclude-standard -z -- .; "
        + "git ls-files --others --ignored --exclude-standard --directory -z -- .; } | xargs -0 sh -c "
        + quote(symbolicLinkMetadataScript) + " sh"

    // Shared by the WorkspaceFiles implementation files.
    static func parseSymbolicLinks(_ data: Data) -> [String: WorkspaceSymbolicLink] {
        let entries = nulStrings(data)
        var links: [String: WorkspaceSymbolicLink] = [:]
        for index in stride(from: 0, to: entries.count - entries.count % 3, by: 3) {
            links[entries[index]] = WorkspaceSymbolicLink(target: entries[index + 1], isDirectory: entries[index + 2] == "d")
        }
        return links
    }

    /// The links among `paths`. A path that is not a valid one inside the Space is skipped, so
    /// one odd entry cannot fail a whole listing.
    // Shared by the WorkspaceFiles implementation files.
    static func localSymbolicLinks(_ paths: [String], root: String) -> [String: WorkspaceSymbolicLink] {
        var links: [String: WorkspaceSymbolicLink] = [:]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let capacity = Int(PATH_MAX) + 1
        var targetBytes = [UInt8](repeating: 0, count: capacity)
        for path in paths {
            guard (try? validateRelativePath(path)) != nil else { continue }
            let absolute = prefix + path
            // Most listed files are not links. Avoid constructing a Foundation error for each
            // one; readlink reports EINVAL directly and the scratch buffer is reused.
            let length = targetBytes.withUnsafeMutableBytes {
                readlink(absolute, $0.baseAddress!.assumingMemoryBound(to: CChar.self), capacity)
            }
            guard length >= 0 else { continue }
            let target: String?
            if length == capacity {
                // Never report a truncated target if a filesystem allows a longer link.
                target = try? FileManager.default.destinationOfSymbolicLink(atPath: absolute)
            } else {
                target = String(bytes: targetBytes.prefix(length), encoding: .utf8)
            }
            guard let target else { continue }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
            links[path] = WorkspaceSymbolicLink(target: target, isDirectory: isDirectory.boolValue)
        }
        return links
    }
}

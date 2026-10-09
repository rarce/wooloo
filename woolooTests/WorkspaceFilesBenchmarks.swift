import XCTest
@testable import wooloo

/// Times what the file explorer, Git panels, diffs and documents ask `WorkspaceFiles` for, and
/// counts the git, SSH and shell processes each one starts. Skipped unless
/// `WOOLOO_BENCH_FILES=1`; `scripts/workspace-bench.sh` runs it and compares the JSON lines it
/// writes to `WOOLOO_BENCH_OUT` with a saved baseline.
///
/// Each operation runs against a small and a large disposable repository, locally under
/// /private/tmp and, when `WOOLOO_BENCH_SSH_TARGET` names an SSH target, on that machine under
/// /tmp. The repositories are built once and reused while their layout version holds.
final class WorkspaceFilesBenchmarks: XCTestCase {
    private struct Repository {
        let name: String
        let files: Int
        let commits: Int
    }

    private static let repositories = [Repository(name: "small", files: 40, commits: 30),
                                       Repository(name: "large", files: 20_000, commits: 400)]
    /// Bump when the setup script changes, so existing repositories are rebuilt.
    private static let layoutVersion = "1"

    /// A file with both staged and unstaged changes, a new untracked file, and a large file
    /// with hundreds of changed lines.
    private static let changedPath = "src/m2/f2.swift"
    private static let untrackedPath = "notes/new-0.md"
    private static let bigPath = "big/generated.swift"

    private let environment = ProcessInfo.processInfo.environment
    private var repetitions: Int { Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 5 }

    private func report(_ line: String) {
        print("WOOLOO-BENCH " + line)
        guard let path = environment["WOOLOO_BENCH_OUT"], !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    func testWorkspaceOperations() throws {
        guard environment["WOOLOO_BENCH_FILES"] == "1" else { throw XCTSkip("Set WOOLOO_BENCH_FILES=1 to run benchmarks") }
        var targets: [(name: String, machine: HerdrMachineProfile?, base: String)] = [("local", nil, "/private/tmp/wooloo-bench")]
        if let target = environment["WOOLOO_BENCH_SSH_TARGET"], !target.isEmpty {
            let machine = HerdrMachineProfile(id: "bench", label: "Benchmark", target: target, session: "default", enabled: true)
            targets.append(("ssh", machine, "/tmp/wooloo-bench"))
        }
        // Runs SSH batches one command after another, as before they ran at once, to compare.
        let sequential = environment["WOOLOO_BENCH_SEQUENTIAL_SSH"] == "1"
        WorkspaceFiles.concurrentRemoteBatches = !sequential
        defer { WorkspaceFiles.concurrentRemoteBatches = true }
        report(#"{"config":{"repeat":\#(repetitions),"ssh_target":"\#(environment["WOOLOO_BENCH_SSH_TARGET"] ?? "")","sequential_ssh":\#(sequential)}}"#)
        for target in targets {
            try prepareRepositories(machine: target.machine, base: target.base)
            for repository in Self.repositories {
                let location = WorkspaceFileLocation(machine: target.machine, session: "bench", workspaceID: "bench",
                                                     workspaceLabel: repository.name,
                                                     root: target.base + "/" + repository.name)
                try measure(location: location, target: target.name, repository: repository.name)
            }
            try measureFolderWalks(machine: target.machine, target: target.name, base: target.base)
        }
    }

    /// The walk of a folder outside Git (`WorkspaceFiles.folderWalk`): `tree` has 20,000 files in
    /// 1,040 folders and a skipped `node_modules`, read in full within the time limit; `huge` has
    /// one folder of 150,000 files below its root, read with a 0.05 s limit (1 s over SSH, where
    /// the limit is in whole seconds). Locally, the `-script` operations run the SSH script with
    /// /bin/sh instead, for comparison.
    private func measureFolderWalks(machine: HerdrMachineProfile?, target: String, base: String) throws {
        let output = try runSetup(machine: machine, arguments: [base, Self.walkLayoutVersion], script: Self.walkSetupScript)
        if output.contains("built") { print("Built walk folders at \(machine?.target ?? "local"):\(base)") }
        defer { WorkspaceFiles.folderWalkBudget = 2 }
        for (name, budget) in [("tree", 2.0), ("huge", 0.05)] {
            let location = WorkspaceFileLocation(machine: machine, session: "bench", workspaceID: "walk-" + name,
                                                 workspaceLabel: name, root: base + "/walk/" + name)
            WorkspaceFiles.folderWalkBudget = budget
            var operations: [(String, () throws -> WorkspaceFolderWalk)] = [
                ("folder-walk", { try WorkspaceFiles.folderWalk(at: location, readingSkipped: false) }),
            ]
            if machine == nil {
                let script = WorkspaceFiles.folderWalkScript(readingSkipped: false, links: false)
                operations.append(("folder-walk-script", {
                    let data = try WorkspaceFiles.run("/bin/sh", ["-c", script, "sh", location.root],
                                                      limit: WorkspaceFiles.maximumListingBytes, label: "sh")
                    return WorkspaceFiles.folderWalk(scriptOutput: data, readingSkipped: false)
                }))
            }
            for (operation, walk) in operations {
                _ = try walk()
                var nanos: [UInt64] = []
                var processes: [WorkspaceProcessLog.Record] = []
                var found = WorkspaceFolderWalk()
                for _ in 0..<repetitions {
                    let start = DispatchTime.now().uptimeNanoseconds
                    processes = try WorkspaceProcessLog.collect { found = try walk() }.processes
                    nanos.append(DispatchTime.now().uptimeNanoseconds - start)
                }
                var result = line(target: target, repository: "walk-" + name, operation: operation, nanos: nanos,
                                  processes: processes)
                result.removeLast()
                report(result + #","files":\#(found.files.count),"partial":\#(found.partial)}"#)
            }
        }
    }

    private func measure(location: WorkspaceFileLocation, target: String, repository: String) throws {
        let head = try XCTUnwrap(WorkspaceFiles.repository(at: location).commits.first?.id, "no commits in \(repository)")
        let operations: [(String, () throws -> Void)] = [
            // What one refresh of the Files sidebar runs: the listing, then the Git bar, which
            // loads the branch status and repository, then the repository panel. Over SSH all
            // three read one remote script; alone, as below, each runs the whole script.
            ("refresh", {
                WorkspaceFiles.forgetRecentResults()
                _ = try WorkspaceFiles.listing(at: location)
                _ = try WorkspaceFiles.gitBar(at: location)
                _ = try WorkspaceFiles.repository(at: location)
            }),
            ("file-list", { _ = try WorkspaceFiles.listing(at: location) }),
            ("git-bar", { _ = try WorkspaceFiles.gitBar(at: location) }),
            ("repository", { _ = try WorkspaceFiles.repository(at: location) }),
            ("open-file", { _ = try WorkspaceFiles.read(Self.changedPath, at: location) }),
            ("open-change", { _ = try WorkspaceFiles.diff(Self.changedPath, at: location) }),
            ("open-untracked", { _ = try WorkspaceFiles.diff(Self.untrackedPath, at: location) }),
            // The diff viewer fetches both whole files for syntax colors after showing the patch.
            ("diff-sides", {
                _ = WorkspaceFiles.diffSides(Self.changedPath, originalPath: nil, commit: nil, scope: .all, at: location)
            }),
            ("commit-files", { _ = try WorkspaceFiles.commitFiles(head, at: location) }),
            ("commit-diff", {
                _ = try WorkspaceFiles.commitDiff(head, path: Self.changedPath, originalPath: nil, at: location)
            }),
            ("open-big-change", { _ = try WorkspaceFiles.diff(Self.bigPath, at: location) }),
        ]
        for (name, operation) in operations {
            try operation() // warm the file system and git caches
            var nanos: [UInt64] = []
            var processes: [WorkspaceProcessLog.Record] = []
            for _ in 0..<repetitions {
                // Each operation reads the repository afresh, as after a change.
                WorkspaceFiles.forgetRecentResults()
                let start = DispatchTime.now().uptimeNanoseconds
                processes = try WorkspaceProcessLog.collect(operation).processes
                nanos.append(DispatchTime.now().uptimeNanoseconds - start)
            }
            report(line(target: target, repository: repository, operation: name, nanos: nanos, processes: processes))
        }

        // Parsing is CPU work in the app, the same wherever the files live.
        guard target == "local" else { return }
        let patch = try XCTUnwrap(WorkspaceFiles.diff(Self.bigPath, at: location)[.all])
        let sides = WorkspaceFiles.diffSides(Self.bigPath, originalPath: nil, commit: nil, scope: .all, at: location)
        // The explorer builds the Files tree once per listing, then walks it on every render.
        let files = try WorkspaceFiles.listing(at: location).files
        let tree = WorkspaceTree(paths: files)
        let expanded = Set(tree.nodes.prefix(3).map { "bench|" + $0.path })
        for (name, parse) in [("parse-big-diff", { _ = ParsedDiff(patch) }),
                              ("parse-big-diff-highlighted", { _ = ParsedDiff(patch, old: sides.old, new: sides.new) }),
                              ("file-tree", { _ = WorkspaceTree(paths: files) }),
                              ("file-tree-rows", { _ = tree.visibleRows(expanded: expanded, identity: "bench") })] {
            parse()
            var nanos: [UInt64] = []
            for _ in 0..<repetitions {
                let start = DispatchTime.now().uptimeNanoseconds
                parse()
                nanos.append(DispatchTime.now().uptimeNanoseconds - start)
            }
            report(line(target: target, repository: repository, operation: name, nanos: nanos, processes: []))
        }
    }

    private func line(target: String, repository: String, operation: String, nanos: [UInt64],
                      processes: [WorkspaceProcessLog.Record]) -> String {
        let sorted = nanos.sorted()
        func millis(_ p: Double) -> String {
            String(format: "%.2f", Double(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]) / 1e6)
        }
        let labels = Dictionary(grouping: processes, by: \.label).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { #""\#($0.key)":\#($0.value)"# }.joined(separator: ",")
        let processMillis = String(format: "%.2f", Double(processes.reduce(0) { $0 + $1.nanos }) / 1e6)
        let bytes = processes.reduce(0) { $0 + $1.bytes }
        return #"{"target":"\#(target)","repo":"\#(repository)","op":"\#(operation)","p50_ms":\#(millis(0.5)),"p95_ms":\#(millis(0.95)),"procs":\#(processes.count),"proc_ms":\#(processMillis),"bytes":\#(bytes),"by_label":{\#(labels)}}"#
    }

    // MARK: Disposable repositories

    private func prepareRepositories(machine: HerdrMachineProfile?, base: String) throws {
        for repository in Self.repositories {
            let started = Date()
            let output = try runSetup(machine: machine, arguments: [base, repository.name, String(repository.files),
                                                                    String(repository.commits), Self.layoutVersion])
            if output.contains("built") {
                print("Built \(repository.name) at \(machine?.target ?? "local"):\(base) in \(Int(Date().timeIntervalSince(started)))s")
            }
        }
    }

    private func runSetup(machine: HerdrMachineProfile?, arguments: [String],
                          script: String = WorkspaceFilesBenchmarks.setupScript) throws -> String {
        let process = Process()
        if let machine {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes", machine.target, "sh", "-s", "--"] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-s", "--"] + arguments
        }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkspaceFilesBenchmarks", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Repository setup failed: \(text)"])
        }
        return text
    }

    /// Builds `<base>/<name>` with `files` source files in 50 directories, `commits` commits
    /// that each change one file, and the working-tree changes the operations look at.
    private static let setupScript = #"""
    set -eu
    base=$1 name=$2 files=$3 commits=$4 version=$5
    dir=$base/$name
    if [ -f "$dir/.git/wooloo-bench-$version" ]; then echo ready; exit 0; fi
    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email bench@wooloo.dev
    git config user.name "wooloo bench"
    git config commit.gpgsign false
    body='import Foundation

    struct Sample {
        let name: String
        let value: Int

        func describe() -> String {
            "\(name): \(value)"
        }
    }
    '
    i=0
    while [ $i -lt 50 ]; do mkdir -p src/m$i; i=$((i + 1)); done
    i=0
    while [ $i -lt "$files" ]; do
        printf '// File %s\n%s%s%s' "$i" "$body" "$body" "$body" > src/m$((i % 50))/f$i.swift
        i=$((i + 1))
    done
    mkdir -p big
    i=0
    while [ $i -lt 5000 ]; do
        printf '    let value%s = compute(%s) // generated line\n' "$i" "$i"
        i=$((i + 1))
    done > big/generated.swift
    git add -A
    git commit -qm "Initial import"
    i=0
    limit=$((files < 50 ? files : 50))
    while [ $i -lt "$commits" ]; do
        file=src/m$((i % limit))/f$((i % limit)).swift
        printf '// Change %s\n' "$i" >> "$file"
        git commit -qam "Change $i"
        i=$((i + 1))
    done
    git branch -q feature/one
    git branch -q feature/two
    printf '// Staged change\n' >> src/m2/f2.swift
    git add src/m2/f2.swift
    printf '// Unstaged change\n' >> src/m2/f2.swift
    printf '// Unstaged change\n' >> src/m1/f1.swift
    awk 'NR % 3 == 0 { sub(/generated/, "edited") } { print }' big/generated.swift > big/generated.tmp
    mv big/generated.tmp big/generated.swift
    mkdir -p notes
    i=0
    while [ $i -lt 5 ]; do printf '# Note %s\n\nUntracked text.\n' "$i" > notes/new-$i.md; i=$((i + 1)); done
    touch ".git/wooloo-bench-$version"
    echo built
    """#
}

extension WorkspaceFilesBenchmarks {
    /// Bump when the walk setup script changes.
    fileprivate static let walkLayoutVersion = "1"

    /// Builds `<base>/walk/tree` and `<base>/walk/huge` for `measureFolderWalks`.
    fileprivate static let walkSetupScript = #"""
    set -eu
    base=$1 version=$2
    dir=$base/walk
    if [ -f "$dir/.wooloo-walk-$version" ]; then echo ready; exit 0; fi
    rm -rf "$dir"
    mkdir -p "$dir/tree/node_modules/pkg" "$dir/huge/big"
    cd "$dir/tree"
    i=0
    while [ $i -lt 40 ]; do
        j=0
        while [ $j -lt 25 ]; do
            mkdir -p a$i/b$j
            k=0
            while [ $k -lt 20 ]; do : > a$i/b$j/f$k.txt; k=$((k + 1)); done
            j=$((j + 1))
        done
        i=$((i + 1))
    done
    i=0
    while [ $i -lt 1000 ]; do : > node_modules/pkg/m$i.js; i=$((i + 1)); done
    cd "$dir/huge"
    : > top.txt
    i=0
    while [ $i -lt 150000 ]; do : > big/f$i; i=$((i + 1)); done
    touch "$dir/.wooloo-walk-$version"
    echo built
    """#
}

final class WorkspaceListingTests: XCTestCase {
    func testTrackedFilesComeBeforeUntrackedOnes() {
        let entries = ["? .build/a", "H wooloo/App.swift", "? notes.txt", "M both.swift", "M both.swift", "? both.swift"]
        let split = WorkspaceFiles.trackedFirst(entries)
        XCTAssertEqual(split.tracked, ["both.swift", "wooloo/App.swift"])
        XCTAssertEqual(split.untracked, [".build/a", "notes.txt"])
    }

    func testStageStateFollowsIndexAndWorktree() {
        func change(_ index: Character, _ worktree: Character) -> WorkspaceFileChange {
            WorkspaceFileChange(path: "a", indexStatus: index, worktreeStatus: worktree, originalPath: nil)
        }
        XCTAssertEqual(change("M", " ").stageState, .all)
        XCTAssertEqual(change("M", "M").stageState, .partial)
        XCTAssertEqual(change(" ", "M").stageState, .none)
        XCTAssertEqual(change("?", "?").stageState, .none)
        XCTAssertEqual(WorkspaceFileChange.StageState.all.merged(with: .none), .partial)
        XCTAssertEqual(WorkspaceFileChange.StageState.all.merged(with: .all), .all)
    }
}

import XCTest
@testable import wooloo

/// The explorer tree's expanded folders, selection and empty folders across reveals, renames and deletes.
final class WorkspaceExplorerTreeTests: XCTestCase {
    private let files = "space|files"
    private let changes = "space|changes"

    func testRevealOpensTheFoldersAboveAndSelects() {
        var tree = WorkspaceExplorerTree()
        tree.collapsedRoots = [files]
        tree.reveal("src/app/main.swift", in: files)
        XCTAssertEqual(tree.expanded, ["space|files|src", "space|files|src/app"])
        XCTAssertEqual(tree.selected, "space|files|src/app/main.swift")
        XCTAssertTrue(tree.collapsedRoots.isEmpty, "The root opens too")
        XCTAssertEqual(tree.selectedPath(in: files), "src/app/main.swift")
        XCTAssertNil(tree.selectedPath(in: changes), "The selection belongs to one tree")

        tree.reveal("README.md", in: files)
        XCTAssertEqual(tree.selectedPath(in: files), "README.md")
    }

    /// A new item's folder opens with every folder above it; the root needs no key.
    func testExpandingAFolderForANewItem() {
        var tree = WorkspaceExplorerTree()
        tree.expand("docs/guides", in: files)
        XCTAssertEqual(tree.expanded, ["space|files|docs", "space|files|docs/guides"])
        tree.collapsedRoots = [files]
        tree.expand("", in: files)
        XCTAssertTrue(tree.collapsedRoots.isEmpty)
        XCTAssertEqual(tree.expanded.count, 2)
    }

    func testToggleAndCollapseAllStayInTheirTree() {
        var tree = WorkspaceExplorerTree()
        tree.toggle("space|files|src", isExpanded: false)
        tree.toggle("space|files|docs", isExpanded: false)
        tree.toggle("space|changes|src", isExpanded: false)
        tree.toggle("space|files|docs", isExpanded: true)
        XCTAssertEqual(tree.expanded, ["space|files|src", "space|changes|src"])
        tree.collapseAll(files)
        XCTAssertEqual(tree.expanded, ["space|changes|src"])
    }

    /// Renaming a folder keeps its subfolders open, its selection and its empty folders.
    func testRenameCarriesStateToTheNewName() {
        var tree = WorkspaceExplorerTree()
        tree.expanded = ["space|files|src", "space|files|src/app", "space|files|srcs", "space|changes|src"]
        tree.selected = "space|files|src/app/main.swift"
        tree.createdDirectories = ["space": ["src/empty", "srcs/empty"], "other": ["src/empty"]]
        tree.move(from: "src", to: "lib", in: files, location: "space")
        XCTAssertEqual(tree.expanded, ["space|files|lib", "space|files|lib/app", "space|files|srcs", "space|changes|src"])
        XCTAssertEqual(tree.selected, "space|files|lib/app/main.swift")
        XCTAssertEqual(tree.createdDirectories["space"], ["lib/empty", "srcs/empty"])
        XCTAssertEqual(tree.createdDirectories["other"], ["src/empty"], "Other Spaces keep theirs")

        tree.selected = "space|files|README.md"
        tree.move(from: "lib", to: "src", in: files, location: "space")
        XCTAssertEqual(tree.selected, "space|files|README.md")
    }

    func testRenamingTheSelectedFile() {
        var tree = WorkspaceExplorerTree()
        tree.selected = "space|files|a/old.txt"
        tree.move(from: "a/old.txt", to: "a/new.txt", in: files, location: "space")
        XCTAssertEqual(tree.selected, "space|files|a/new.txt")
    }

    func testDeletingForgetsEmptyFoldersBelow() {
        var tree = WorkspaceExplorerTree()
        tree.createdDirectories = ["space": ["build", "build/cache", "builds"]]
        tree.forget("build", location: "space")
        XCTAssertEqual(tree.createdDirectories["space"], ["builds"])
        tree.forget("anything", location: "unknown")
        XCTAssertNil(tree.createdDirectories["unknown"])
    }

    func testPruningKeepsFoldersThatStillExist() {
        var tree = WorkspaceExplorerTree()
        tree.createdDirectories = ["space": ["kept", "gone"]]
        tree.pruneCreated(location: "space") { $0 == "kept" }
        XCTAssertEqual(tree.createdDirectories["space"], ["kept"])
    }
}

/// Stage checkboxes, change colors, shortcut targets and paste sources.
final class WorkspaceExplorerTests: XCTestCase {
    private func change(_ path: String, _ index: Character, _ worktree: Character) -> WorkspaceFileChange {
        WorkspaceFileChange(path: path, indexStatus: index, worktreeStatus: worktree, originalPath: nil)
    }

    func testFoldersCombineTheStageStateOfTheirFiles() {
        let states = WorkspaceExplorer.stageStates([
            change("src/a.swift", "M", " "), change("src/b.swift", "M", " "),
            change("docs/c.md", " ", "M"), change("top.txt", "A", "M"),
        ])
        XCTAssertEqual(states["src"], .all)
        XCTAssertEqual(states["docs"], WorkspaceFileChange.StageState.none)
        XCTAssertEqual(states["top.txt"], .partial)
        XCTAssertEqual(states[""], .partial, "The root sums up everything")
        XCTAssertEqual(WorkspaceExplorer.stageStates([change("a", "M", " ")])[""], .all)
    }

    func testFoldersShowTheirStrongestChange() {
        let kinds = WorkspaceExplorer.directoryKinds([
            change("src/app/a.swift", " ", "M"), change("src/new.swift", "?", "?"),
            change("src/app/b.swift", "U", "U"), change("docs/x.md", "?", "?"), change("root.txt", "D", " "),
        ])
        XCTAssertEqual(kinds["src/app"], .conflicted)
        XCTAssertEqual(kinds["src"], .conflicted)
        XCTAssertEqual(kinds["docs"], .untracked)
        XCTAssertNil(kinds[""], "The root has no color")

        let mixed = WorkspaceExplorer.directoryKinds([
            change("a/new.swift", "A", " "), change("a/old.swift", " ", "M"), change("a/gone.swift", " ", "D"),
            change("b/new.swift", "?", "?"), change("b/moved.swift", "R", " "),
        ])
        XCTAssertEqual(mixed["a"], .deleted, "Deletions outrank modifications, which outrank new files")
        XCTAssertEqual(mixed["b"], .untracked, "New files outrank renames")
    }

    func testMarkedRowsFollowARenameAndADelete() {
        let files = "space|files"
        var tree = WorkspaceExplorerTree()
        tree.selected = files + "|a/1.txt"
        tree.toggleMark(files + "|a/2.txt")
        tree.toggleMark(files + "|b.txt")
        tree.move(from: "a", to: "c", in: files, location: "space")
        XCTAssertEqual(tree.selectedPaths(in: files), ["b.txt", "c/1.txt", "c/2.txt"])
        XCTAssertEqual(tree.selected, files + "|b.txt")
        tree.forget("c", location: "space")
        XCTAssertEqual(tree.selectedPaths(in: files), ["b.txt"])
        XCTAssertEqual(WorkspaceExplorer.outermost(["a/b", "a", "ab", "a/c/d"]), ["a", "ab"])
    }

    func testStickyFoldersHoldTheRowBelowThem() {
        let rows = WorkspaceTree(paths: ["a/b/c/1.txt", "a/b/c/2.txt", "a/b/3.txt", "a/4.txt", "z.txt"])
            .visibleRows(expanded: ["s|a", "s|a/b", "s|a/b/c"], identity: "s")
        XCTAssertEqual(rows.map(\.node.path), ["a", "a/b", "a/b/c", "a/b/c/1.txt", "a/b/c/2.txt", "a/b/3.txt", "a/4.txt", "z.txt"])
        func sticky(_ top: Int, limit: Int = 5) -> [String] {
            WorkspaceExplorer.stickyRows(rows, top: top, limit: limit).map(\.node.path)
        }
        XCTAssertEqual(sticky(0), ["a", "a/b", "a/b/c"])
        XCTAssertEqual(sticky(1), ["a", "a/b", "a/b/c"])
        XCTAssertEqual(sticky(2), ["a", "a/b"], "a/b/c lets go once a/b/3.txt would show below it")
        XCTAssertEqual(sticky(4), ["a"], "Only a holds a/4.txt")
        XCTAssertEqual(sticky(6), [], "z.txt is at the top level")
        XCTAssertEqual(sticky(1, limit: 2), ["a", "a/b"])
        XCTAssertEqual(sticky(-1), [])
        XCTAssertEqual(sticky(20), [])
    }

    func testFileIcons() {
        XCTAssertEqual(WorkspaceExplorer.fileIcon("a/B.SWIFT"), "swift")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("README.markdown"), "doc.richtext")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("shot.JPG"), "photo")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("Makefile"), "doc.text")
    }

    /// A shortcut on a file acts in its folder; on a folder, in the folder itself.
    func testIgnoredEntriesKeepOnlyTheOutermostFolder() {
        let ignored = WorkspaceIgnoredEntries(gitEntries: [".DS_Store", "b/", "b/z.log", "Vendor/Pkg/.swiftpm/",
                                                           "Vendor/Pkg/.swiftpm/xcode/", "a/x.log", "/", ""])
        XCTAssertEqual(ignored.directories, ["b", "Vendor/Pkg/.swiftpm"])
        XCTAssertEqual(ignored.files, [".DS_Store", "a/x.log"])
        XCTAssertTrue(ignored.contains("Vendor/Pkg/.swiftpm/xcode/x"))
        XCTAssertTrue(ignored.contains("b"))
        XCTAssertFalse(ignored.contains("Vendor/Pkg"))
        XCTAssertFalse(ignored.contains("a"))
        XCTAssertTrue(WorkspaceIgnoredEntries().isEmpty)
    }

    func testFilesTreeIncludesIgnoredFoldersAndWhatWasReadOfThem() {
        let listing = WorkspaceFileListing(files: ["a.txt"], changes: [], hasGit: true, totalFiles: 1,
                                           ignored: WorkspaceIgnoredEntries(gitEntries: ["build/", "cache/"]))
        let contents = ["build": WorkspaceFolderContents(files: ["build/app"], directories: ["build/obj"])]
        let entries = WorkspaceExplorer.filesTreeEntries(listing, ignoredContents: contents, created: ["new"])
        XCTAssertEqual(entries.paths, ["a.txt", "build/app"])
        XCTAssertEqual(entries.directories, ["build", "cache", "build/obj", "new"])
        let tree = WorkspaceTree(paths: entries.paths, directories: entries.directories)
        XCTAssertEqual(tree.nodes.map(\.path), ["build", "cache", "new", "a.txt"])
        XCTAssertTrue(tree.nodes[1].isDirectory, "an unread ignored folder is still a folder")

        XCTAssertEqual(WorkspaceExplorer.ignoredFoldersToRead(expanded: ["src", "cache", "build/obj", "build"],
                                                              ignored: listing.ignored, read: ["build"]),
                       ["build/obj", "cache"])
    }

    func testShortcutTargets() {
        let folders = WorkspaceTree(paths: ["src/a.swift", "src/lib/b.swift", "README.md"]).directories
        XCTAssertTrue(WorkspaceExplorer.isDirectory("", directories: folders, created: []))
        XCTAssertTrue(WorkspaceExplorer.isDirectory("src/lib", directories: folders, created: []))
        XCTAssertFalse(WorkspaceExplorer.isDirectory("src/a.swift", directories: folders, created: []))
        XCTAssertFalse(WorkspaceExplorer.isDirectory("sr", directories: folders, created: []))
        XCTAssertTrue(WorkspaceExplorer.isDirectory("empty", directories: folders, created: ["empty"]))

        XCTAssertEqual(WorkspaceExplorer.folder(for: "src/a.swift", isDirectory: false), "src")
        XCTAssertEqual(WorkspaceExplorer.folder(for: "src/lib", isDirectory: true), "src/lib")
        XCTAssertEqual(WorkspaceExplorer.folder(for: "README.md", isDirectory: false), "")
        XCTAssertEqual(WorkspaceExplorer.path(of: "new.txt", in: ""), "new.txt")
        XCTAssertEqual(WorkspaceExplorer.path(of: "new.txt", in: "src"), "src/new.txt")
    }

    /// The explorer's own copy wins while nothing else was copied; after that, Finder's files do.
    /// On an SSH machine only the explorer's copy from that machine counts.
    func testPasteSources() {
        let local = WorkspaceFileLocation(machine: nil, session: "s", workspaceID: "w", workspaceLabel: "w", root: "/r")
        let machine = HerdrMachineProfile(id: "dev", label: "Dev", target: "dev", session: "s", enabled: true)
        let remote = WorkspaceFileLocation(machine: machine, session: "s", workspaceID: "w", workspaceLabel: "w", root: "/r")
        let finder = { ["/Users/me/Desktop/f.txt"] }
        let copied = WorkspaceFileClipboard(machineID: nil, paths: ["/r/a.txt"], isCut: true, changeCount: 5)

        let own = WorkspaceExplorer.pasteSources(clipboard: copied, location: local, pasteboardChangeCount: 5, pasteboardFiles: finder)
        XCTAssertEqual(own.paths, ["/r/a.txt"])
        XCTAssertTrue(own.move)

        let later = WorkspaceExplorer.pasteSources(clipboard: copied, location: local, pasteboardChangeCount: 6, pasteboardFiles: finder)
        XCTAssertEqual(later.paths, ["/Users/me/Desktop/f.txt"])
        XCTAssertFalse(later.move, "Files from Finder are copied, never moved")

        let onRemote = WorkspaceExplorer.pasteSources(clipboard: copied, location: remote, pasteboardChangeCount: 5, pasteboardFiles: finder)
        XCTAssertEqual(onRemote.paths, [], "A local copy does not paste on another machine")

        let remoteCopy = WorkspaceFileClipboard(machineID: "dev", paths: ["/r/b.txt"], isCut: false, changeCount: 0)
        let sameMachine = WorkspaceExplorer.pasteSources(clipboard: remoteCopy, location: remote, pasteboardChangeCount: 9,
                                                         pasteboardFiles: finder)
        XCTAssertEqual(sameMachine.paths, ["/r/b.txt"], "The pasteboard does not track remote copies")
        XCTAssertFalse(sameMachine.move)
    }
}

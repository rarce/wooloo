import XCTest
@testable import xherdr

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
    }

    func testFileIcons() {
        XCTAssertEqual(WorkspaceExplorer.fileIcon("a/B.SWIFT"), "swift")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("README.markdown"), "doc.richtext")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("shot.JPG"), "photo")
        XCTAssertEqual(WorkspaceExplorer.fileIcon("Makefile"), "doc.text")
    }

    /// A shortcut on a file acts in its folder; on a folder, in the folder itself.
    func testShortcutTargets() {
        let files = ["src/a.swift", "src/lib/b.swift", "README.md"]
        XCTAssertTrue(WorkspaceExplorer.isDirectory("", files: files, created: []))
        XCTAssertTrue(WorkspaceExplorer.isDirectory("src/lib", files: files, created: []))
        XCTAssertFalse(WorkspaceExplorer.isDirectory("src/a.swift", files: files, created: []))
        XCTAssertFalse(WorkspaceExplorer.isDirectory("sr", files: files, created: []))
        XCTAssertTrue(WorkspaceExplorer.isDirectory("empty", files: files, created: ["empty"]))

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

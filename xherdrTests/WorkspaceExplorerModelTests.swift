import XCTest
@testable import xherdr

/// `WorkspaceExplorerModel` against disposable folders and repositories.
@MainActor
final class WorkspaceExplorerModelTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var model: WorkspaceExplorerModel!
    private var copied: [String] = []
    private var revealed: [String] = []
    private var openedInApp: [String] = []
    private var opened: [(path: String, preview: Bool)] = []
    /// The general pasteboard as the fake effects see it.
    private var pasteboardCount = 0
    private var pasteboardFiles: [String] = []

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: ["a.txt": "one\n", "src/main.swift": "print(1)\n"])
        model = WorkspaceExplorerModel()
        model.effects = WorkspaceExplorerEffects(
            copy: { [unowned self] in copied.append($0) },
            reveal: { [unowned self] in revealed.append($0) },
            openInDefaultApp: { [unowned self] in openedInApp.append($0) },
            putFilesOnPasteboard: { [unowned self] in
                pasteboardFiles = $0
                pasteboardCount += 1
                return pasteboardCount
            },
            pasteboardChangeCount: { [unowned self] in pasteboardCount },
            pasteboardFiles: { [unowned self] in pasteboardFiles }
        )
    }

    override func tearDown() async throws {
        sandbox.tearDown()
    }

    private var files: String { "\(repo.identity)|files" }

    private func load(_ location: WorkspaceFileLocation? = nil, quietly: Bool = false) async {
        await model.loadListing(at: location ?? repo, quietly: quietly)?.value
    }

    private func openFile(_ location: WorkspaceFileLocation, _ path: String, _ preview: Bool) {
        opened.append((path, preview))
    }

    /// Commits the name field with `name` and waits for the operation and its reload.
    private func commit(_ name: String) async {
        model.draftName = name
        await model.commitDraft(openFile: openFile)?.value
    }

    /// Selects `path` in the Files tree and runs a shortcut.
    @discardableResult
    private func perform(_ command: ExplorerFileCommand, on path: String?) -> Bool {
        model.tree.selected = path.map { files + "|" + $0 }
        return model.perform(command)
    }

    /// Waits for the last operation a shortcut started, with the reload that follows it.
    private func settle() async {
        await model.lastOperation?.value
    }

    private func exists(_ path: String, in name: String = "repo") -> Bool {
        FileManager.default.fileExists(atPath: sandbox.path(name) + "/" + path)
    }

    private func staged() throws -> [String] {
        try sandbox.sh("git diff --cached --name-only", in: "repo").split(separator: "\n").map(String.init)
    }

    // MARK: Listing

    func testLoadingARepositoryListsFilesChangesAndBuildsTheFilesTree() async throws {
        try sandbox.write(["a.txt": "two\n", "new.txt": "x\n"], in: "repo")
        let task = model.loadListing(at: repo)
        XCTAssertTrue(model.isLoading, "A first load shows a spinner")
        await task?.value
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
        let listing = try XCTUnwrap(model.listing)
        XCTAssertTrue(listing.hasGit)
        XCTAssertEqual(Set(listing.files), ["a.txt", "new.txt", "src/main.swift"])
        XCTAssertEqual(Set(listing.changes.map(\.path)), ["a.txt", "new.txt"])
        XCTAssertEqual(model.listingVersion, 1)
        XCTAssertEqual(model.filesTree(listing, location: repo).directories, ["src"])

        model.modifiedOnly = true
        XCTAssertEqual(model.shownTree(listing, location: repo).nodes.map(\.path), ["a.txt", "new.txt"])
        model.showsChanges = true
        XCTAssertEqual(model.treeIdentity(repo), "\(repo.identity)|changes")
        XCTAssertEqual(model.shownTree(listing, location: repo).nodes.map(\.path), ["a.txt", "new.txt"])
    }

    func testLoadingAFolderWithoutGitListsItsFiles() async throws {
        try sandbox.write(["notes.md": "x\n", "docs/guide.md": "y\n"], in: "plain")
        await load(sandbox.location("plain"))
        let listing = try XCTUnwrap(model.listing)
        XCTAssertFalse(listing.hasGit)
        XCTAssertEqual(Set(listing.files), ["notes.md", "docs/guide.md"])
        XCTAssertTrue(listing.changes.isEmpty)
    }

    func testQuietReloadKeepsTheTreeShown() async throws {
        await load()
        try sandbox.write(["b.txt": "x\n"], in: "repo")
        let task = model.loadListing(at: repo, quietly: true)
        XCTAssertFalse(model.isLoading, "A quiet reload shows no spinner")
        XCTAssertNotNil(model.listing, "The old listing stays until the new one arrives")
        await task?.value
        XCTAssertTrue(model.listing?.files.contains("b.txt") == true)
        XCTAssertEqual(model.listingVersion, 2)
    }

    /// A repository Git cannot read shows its error in place of the tree.
    func testARepositoryThatCannotBeListedReportsAnError() async throws {
        try sandbox.sh("printf garbage > .git/index", in: "repo")
        await load()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.listing)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.listingVersion, 1)
    }

    func testNoLocationClearsTheListing() async {
        await load()
        XCTAssertNil(model.loadListing(at: nil))
        XCTAssertNil(model.listing)
        XCTAssertNil(model.location)
    }

    /// A listing that arrives after the explorer moved to another Space is dropped.
    func testALoadForAPreviousLocationIsDiscarded() async throws {
        let other = try sandbox.repository("other", files: ["b.txt": "x\n"])
        let first = model.loadListing(at: repo)
        let second = model.loadListing(at: other)
        await first?.value
        await second?.value
        XCTAssertEqual(model.listing?.files, ["b.txt"])
        XCTAssertEqual(model.listingVersion, 1, "Only the current location's load counts")
    }

    func testReloadDropsCreatedFoldersThatAreGoneAndRereadsOpenIgnoredFolders() async throws {
        try sandbox.write([".gitignore": "build/\n", "build/out.o": "x\n"], in: "repo")
        try FileManager.default.createDirectory(atPath: sandbox.path("repo/empty"), withIntermediateDirectories: true)
        model.tree.createdDirectories[repo.identity] = ["empty", "gone"]
        model.tree.expanded = [files + "|build"]
        await load()
        XCTAssertEqual(model.tree.createdDirectories[repo.identity], ["empty"])
        XCTAssertEqual(model.ignoredContents["build"]?.files, ["build/out.o"])
        let tree = model.filesTree(try XCTUnwrap(model.listing), location: repo)
        XCTAssertTrue(tree.directories.isSuperset(of: ["empty", "build", "src"]))
        XCTAssertEqual(tree.visibleRows(expanded: model.tree.expanded, identity: files).prefix(4).map(\.node.path),
                       ["build", "build/out.o", "empty", "src"])
    }

    func testOpeningAnIgnoredFolderReadsItsContentsOnce() async throws {
        try sandbox.write([".gitignore": "build/\n", "build/out.o": "x\n"], in: "repo")
        await load()
        XCTAssertNil(model.ignoredContents["build"])
        let version = model.ignoredContentsVersion
        await model.toggleDirectory(files + "|build", path: "build", isExpanded: false, location: repo)?.value
        XCTAssertTrue(model.tree.expanded.contains(files + "|build"))
        XCTAssertEqual(model.ignoredContents["build"]?.files, ["build/out.o"])
        XCTAssertEqual(model.ignoredContentsVersion, version + 1)

        XCTAssertNil(model.toggleDirectory(files + "|build", path: "build", isExpanded: true, location: repo),
                     "Closing reads nothing")
        XCTAssertNil(model.toggleDirectory(files + "|build", path: "build", isExpanded: false, location: repo),
                     "Contents already read are kept")
        XCTAssertNil(model.toggleDirectory(files + "|src", path: "src", isExpanded: false, location: repo),
                     "A folder Git lists needs no read")
    }

    // MARK: Name field

    func testCommittingANewFileCreatesSelectsAndOpensIt() async throws {
        await load()
        model.startDraft(in: "src/app", isFolder: false, at: repo)
        XCTAssertTrue(model.tree.expanded.isSuperset(of: [files + "|src", files + "|src/app"]),
                      "The folder opens for the name field")
        await commit("  view.swift \n")
        XCTAssertNil(model.draft)
        XCTAssertTrue(exists("src/app/view.swift"))
        XCTAssertEqual(model.tree.selected, files + "|src/app/view.swift")
        XCTAssertEqual(opened.map(\.path), ["src/app/view.swift"])
        XCTAssertEqual(opened.first?.preview, false, "A new file opens in its own tab")
        XCTAssertTrue(model.listing?.files.contains("src/app/view.swift") == true, "The listing reloads")
        XCTAssertNil(model.operationError)
    }

    func testCommittingANewFolderKeepsItInTheTree() async throws {
        await load()
        model.startDraft(in: "", isFolder: true, at: repo)
        await commit("assets")
        XCTAssertTrue(exists("assets"))
        XCTAssertEqual(model.tree.createdDirectories[repo.identity], ["assets"], "Git does not list empty folders")
        XCTAssertTrue(model.filesTree(try XCTUnwrap(model.listing), location: repo).directories.contains("assets"))
        XCTAssertEqual(model.tree.selected, files + "|assets")
        XCTAssertTrue(opened.isEmpty, "Folders are not opened")
    }

    func testAnEmptyNameOnlyClosesTheField() async {
        await load()
        model.startDraft(in: "", isFolder: false, at: repo)
        model.draftName = "  "
        XCTAssertNil(model.commitDraft(openFile: openFile))
        XCTAssertNil(model.draft)
        XCTAssertNil(model.commitDraft(openFile: openFile), "Nothing to commit without a field")
    }

    func testCreatingOverAnExistingItemReportsIt() async {
        await load()
        model.startDraft(in: "", isFolder: false, at: repo)
        await commit("a.txt")
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n", "The existing file is untouched")
    }

    func testRenamingAFolderCarriesItsTreeState() async throws {
        try sandbox.write(["src/app/view.swift": "x\n"], in: "repo")
        await load()
        model.tree.expanded = [files + "|src", files + "|src/app"]
        model.tree.selected = files + "|src/app/view.swift"
        model.startRename("src", isDirectory: true, at: repo)
        XCTAssertEqual(model.draftName, "src")
        XCTAssertEqual(model.draft?.renaming, "src")
        XCTAssertEqual(model.draft?.isFolder, true)
        await commit("lib")
        XCTAssertTrue(exists("lib/app/view.swift"))
        XCTAssertFalse(exists("src"))
        XCTAssertEqual(model.tree.expanded, [files + "|lib", files + "|lib/app"])
        XCTAssertEqual(model.tree.selected, files + "|lib/app/view.swift")
        XCTAssertTrue(opened.isEmpty)
    }

    func testRenamingToTheSameNameDoesNothing() async {
        await load()
        model.startRename("src/main.swift", isDirectory: false, at: repo)
        XCTAssertEqual(model.draftName, "main.swift")
        XCTAssertEqual(model.draft?.folder, "src")
        XCTAssertNil(model.commitDraft(openFile: openFile))
        XCTAssertTrue(exists("src/main.swift"))
    }

    func testRenamingOntoAnotherItemOrWithASlashIsRefused() async {
        await load()
        model.startRename("a.txt", isDirectory: false, at: repo)
        await commit("src")
        XCTAssertNotNil(model.operationError, "An existing name is refused")
        XCTAssertTrue(exists("a.txt"))

        model.operationError = nil
        model.startRename("a.txt", isDirectory: false, at: repo)
        await commit("src/b.txt")
        XCTAssertNotNil(model.operationError, "A name is not a path")
        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("src/b.txt"))
    }

    // MARK: Staging

    func testStageToggleStagesAndUnstagesAFile() async throws {
        try sandbox.write(["a.txt": "two\n"], in: "repo")
        await load()
        XCTAssertEqual(WorkspaceExplorer.stageStates(model.listing?.changes ?? [])["a.txt"], WorkspaceFileChange.StageState.none)
        await model.stageToggle(.none, path: "a.txt", location: repo).value
        XCTAssertEqual(try staged(), ["a.txt"])
        XCTAssertEqual(WorkspaceExplorer.stageStates(model.listing?.changes ?? [])["a.txt"], .all, "The listing reloads")

        await model.stageToggle(.all, path: "a.txt", location: repo).value
        XCTAssertEqual(try staged(), [])
        XCTAssertNil(model.operationError)
    }

    func testStageToggleOnAFolderAndTheRoot() async throws {
        try sandbox.write(["src/main.swift": "print(2)\n", "src/new.swift": "x\n", "b.txt": "x\n"], in: "repo")
        try sandbox.sh("git add src/main.swift", in: "repo")
        await load()
        let states = WorkspaceExplorer.stageStates(model.listing?.changes ?? [])
        XCTAssertEqual(states["src"], .partial)

        await model.stageToggle(.partial, path: "src", location: repo).value
        XCTAssertEqual(Set(try staged()), ["src/main.swift", "src/new.swift"], "A partly staged folder is staged whole")
        await model.stageToggle(.all, path: "src", location: repo).value
        XCTAssertEqual(try staged(), [])

        await model.stageToggle(.none, path: "", location: repo).value
        XCTAssertEqual(Set(try staged()), ["b.txt", "src/main.swift", "src/new.swift"], "The root stages everything")
        XCTAssertEqual(WorkspaceExplorer.stageStates(model.listing?.changes ?? [])[""], .all)
    }

    func testAFailedStageIsReportedAndStillReloads() async throws {
        await load()
        try sandbox.write(["b.txt": "x\n"], in: "repo")
        await model.stageToggle(.none, path: "missing.txt", location: repo).value
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(model.listing?.files.contains("b.txt") == true)
    }

    // MARK: Shortcuts

    func testShortcutsNeedAListingInTheFilesTreeWithNothingPending() async {
        XCTAssertFalse(perform(.newFile, on: nil), "No listing yet")
        await load()
        model.showsChanges = true
        XCTAssertFalse(perform(.newFile, on: nil), "Not in the Changes tree")
        model.showsChanges = false
        model.startDraft(in: "", isFolder: false, at: repo)
        XCTAssertFalse(perform(.copyPath, on: nil), "Not while naming an item")
        model.draft = nil
        model.pendingDelete = WorkspaceFileTarget(location: repo, path: "a.txt", isDirectory: false)
        XCTAssertFalse(perform(.copyPath, on: nil), "Not while a delete waits")
    }

    func testWithNothingSelectedOnlyRootCommandsApply() async {
        await load()
        for command in [ExplorerFileCommand.rename, .delete, .cut, .copy, .duplicate, .trash, .copyRelativePath] {
            XCTAssertFalse(perform(command, on: nil), "\(command)")
        }
        XCTAssertTrue(perform(.copyPath, on: nil))
        XCTAssertEqual(copied, [repo.absolutePath("")])
        XCTAssertTrue(perform(.newFolder, on: nil))
        XCTAssertEqual(model.draft?.folder, "")
        XCTAssertEqual(model.draft?.isFolder, true)
    }

    func testNewItemsGoInTheSelectedFolderOrBesideTheSelectedFile() async {
        await load()
        model.tree.createdDirectories[repo.identity] = ["empty"]
        XCTAssertTrue(perform(.newFile, on: "src"))
        XCTAssertEqual(model.draft?.folder, "src")
        XCTAssertEqual(model.draft?.isFolder, false)
        model.draft = nil
        XCTAssertTrue(perform(.newFolder, on: "src/main.swift"))
        XCTAssertEqual(model.draft?.folder, "src")
        model.draft = nil
        XCTAssertTrue(perform(.newFile, on: "empty"), "A folder created empty is a folder too")
        XCTAssertEqual(model.draft?.folder, "empty")
    }

    func testRenameDeleteAndPathShortcutsActOnTheSelection() async {
        await load()
        XCTAssertTrue(perform(.rename, on: "src"))
        XCTAssertEqual(model.draft?.renaming, "src")
        XCTAssertEqual(model.draft?.isFolder, true)
        XCTAssertEqual(model.draftName, "src")
        model.draft = nil

        XCTAssertTrue(perform(.delete, on: "src/main.swift"))
        XCTAssertEqual(model.pendingDelete?.path, "src/main.swift")
        XCTAssertEqual(model.pendingDelete?.isDirectory, false)
        model.pendingDelete = nil

        XCTAssertTrue(perform(.copyRelativePath, on: "src/main.swift"))
        XCTAssertTrue(perform(.copyPath, on: "src/main.swift"))
        XCTAssertEqual(copied, ["src/main.swift", repo.absolutePath("src/main.swift")])
        XCTAssertTrue(perform(.reveal, on: "a.txt"))
        XCTAssertTrue(perform(.openInDefaultApp, on: "a.txt"))
        XCTAssertEqual(revealed, [repo.absolutePath("a.txt")])
        XCTAssertEqual(openedInApp, [repo.absolutePath("a.txt")])
    }

    // MARK: Clipboard

    func testCopyThenPasteCopiesIntoTheSelectedFolder() async throws {
        await load()
        XCTAssertTrue(perform(.copy, on: "a.txt"))
        XCTAssertEqual(pasteboardFiles, [repo.absolutePath("a.txt")], "Finder can paste it too")
        XCTAssertTrue(perform(.paste, on: "src"))
        await settle()
        XCTAssertTrue(exists("src/a.txt"))
        XCTAssertTrue(exists("a.txt"))
        XCTAssertEqual(model.tree.selected, files + "|src/a.txt")
        XCTAssertNotNil(model.clipboard, "A copy can be pasted again")

        XCTAssertTrue(perform(.paste, on: "src/main.swift"))
        await settle()
        XCTAssertTrue(exists("src/a copy.txt"), "A second paste gets a free name")
        XCTAssertNil(model.operationError)
    }

    func testCutThenPasteMovesAndEmptiesTheClipboard() async {
        await load()
        XCTAssertTrue(perform(.cut, on: "a.txt"))
        XCTAssertEqual(model.clipboard?.isCut, true)
        XCTAssertTrue(perform(.paste, on: "src"))
        await settle()
        XCTAssertTrue(exists("src/a.txt"))
        XCTAssertFalse(exists("a.txt"))
        XCTAssertNil(model.clipboard)
        XCTAssertEqual(model.tree.selected, files + "|src/a.txt")
    }

    /// Files copied elsewhere after the explorer's own copy win, and are copied, not moved.
    func testPasteUsesFilesCopiedInFinderSinceTheExplorersCut() async throws {
        try sandbox.write(["outside.txt": "x\n"], in: "elsewhere")
        await load()
        XCTAssertTrue(perform(.cut, on: "a.txt"))
        pasteboardFiles = [sandbox.path("elsewhere/outside.txt")]
        pasteboardCount += 1
        XCTAssertTrue(perform(.paste, on: nil))
        await settle()
        XCTAssertTrue(exists("outside.txt"))
        XCTAssertTrue(exists("outside.txt", in: "elsewhere"), "Finder's files are copied")
        XCTAssertTrue(exists("a.txt"), "The cut item stays")
        XCTAssertNotNil(model.clipboard)
    }

    func testPasteWithNothingCopiedReportsIt() async {
        await load()
        XCTAssertTrue(perform(.paste, on: nil))
        await settle()
        XCTAssertEqual(model.operationError, "Nothing to paste. Copy or cut a file on Local first.")
    }

    func testPastingAnEmptyFolderKeepsItInTheTree() async throws {
        try FileManager.default.createDirectory(atPath: sandbox.path("repo/empty"), withIntermediateDirectories: true)
        await load()
        model.copyItem("empty", in: repo, cut: false)
        await model.paste(into: "src", in: repo)?.value
        XCTAssertEqual(model.tree.createdDirectories[repo.identity], ["src/empty"])
        XCTAssertEqual(model.tree.selected, files + "|src/empty")
    }

    func testDuplicateCopiesBesideTheItem() async {
        await load()
        XCTAssertTrue(perform(.duplicate, on: "src/main.swift"))
        await settle()
        XCTAssertTrue(exists("src/main copy.swift"))
        XCTAssertEqual(model.tree.selected, files + "|src/main copy.swift")
    }

    func testDeleteRemovesTheItemAndForgetsItsCreatedFolders() async throws {
        try FileManager.default.createDirectory(atPath: sandbox.path("repo/src/empty"), withIntermediateDirectories: true)
        model.tree.createdDirectories[repo.identity] = ["src/empty", "other"]
        await load()
        await model.delete(WorkspaceFileTarget(location: repo, path: "src", isDirectory: true)).value
        XCTAssertFalse(exists("src"))
        XCTAssertEqual(model.tree.createdDirectories[repo.identity], [])
        XCTAssertEqual(model.listing?.changes.map(\.path), ["src/main.swift"], "The listing reloads")
    }
}

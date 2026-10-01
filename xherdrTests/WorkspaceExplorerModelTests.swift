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
    private var savedTrash: ((URL) throws -> URL)?

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
        if let savedTrash { WorkspaceFiles.trashItem = savedTrash }
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

    /// Reloading the location already shown, as after a save, keeps the tree instead of a spinner.
    func testReloadingTheSameLocationKeepsTheTreeShown() async throws {
        await load()
        let task = model.loadListing(at: repo)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.listing)
        await task?.value

        try sandbox.write(["notes.md": "x\n"], in: "plain")
        let other = model.loadListing(at: sandbox.location("plain"))
        XCTAssertTrue(model.isLoading, "Another location shows a spinner")
        await other?.value
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

    func testCanPerformListsWhatAppliesToTheSelection() async {
        XCTAssertFalse(model.canPerform(.newFile), "No listing yet")
        await load()
        XCTAssertTrue(model.canPerform(.newFile))
        XCTAssertFalse(model.canPerform(.rename), "Nothing selected")
        XCTAssertFalse(model.canPerform(.undo), "Nothing to undo")
        model.tree.selected = files + "|a.txt"
        XCTAssertTrue(model.canPerform(.rename))
        XCTAssertTrue(model.canPerform(.reveal))
        model.showsChanges = true
        XCTAssertFalse(model.canPerform(.newFile), "No file operations in the Changes tree")
        XCTAssertTrue(model.canPerform(.copyPath))
        model.showsChanges = false
        XCTAssertTrue(perform(.duplicate, on: "a.txt"))
        await settle()
        XCTAssertTrue(model.canPerform(.undo))
        XCTAssertFalse(model.canPerform(.redo))
        model.startDraft(in: "", isFolder: false, at: repo)
        XCTAssertFalse(model.canPerform(.copyPath), "Not while naming an item")
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

    /// Only the question is checked: trashing for real would fill the Trash of whoever runs the tests.
    func testDeleteKeyAsksBeforeTrashing() async {
        await load()
        XCTAssertTrue(perform(.trashAsking, on: "src"))
        XCTAssertEqual(model.pendingDelete?.path, "src")
        XCTAssertEqual(model.pendingDelete?.isDirectory, true)
        XCTAssertEqual(model.pendingDelete?.permanently, false)
        XCTAssertTrue(exists("src"))
    }

    // MARK: Keyboard navigation

    /// A repository with `src/main.swift`, `src/util/x.swift`, `docs/a.md` and `b.txt`.
    private func loadNested() async throws {
        repo = try sandbox.repository("nested", files: ["src/main.swift": "1\n", "src/util/x.swift": "2\n",
                                                       "src/util/y.swift": "3\n", "docs/a.md": "4\n", "b.txt": "5\n"])
        await load()
    }

    private var selection: String? { model.tree.selectedPath(in: files) }

    func testArrowsWalkTheRowsShownFromTheRoot() async throws {
        try await loadNested()
        XCTAssertTrue(perform(.selectPrevious, on: nil))
        XCTAssertNil(selection, "Nothing is above the root")
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(selection, "docs")
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(selection, "src", "Closed folders are skipped over")
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(selection, "b.txt")
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(selection, "b.txt", "The last row stays selected")
        XCTAssertTrue(model.perform(.selectPrevious))
        XCTAssertTrue(model.perform(.selectPrevious))
        XCTAssertTrue(model.perform(.selectPrevious))
        XCTAssertNil(selection, "Up from the first row selects the root")
    }

    func testRightOpensAFolderThenEntersIt() async throws {
        try await loadNested()
        XCTAssertTrue(perform(.expand, on: "src"))
        XCTAssertTrue(model.tree.expanded.contains(files + "|src"))
        XCTAssertEqual(selection, "src")
        XCTAssertTrue(model.perform(.expand))
        XCTAssertEqual(selection, "src/util")
        XCTAssertTrue(model.perform(.expand))
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(selection, "src/util/x.swift")
        XCTAssertTrue(model.perform(.expand))
        XCTAssertEqual(selection, "src/util/x.swift", "A file has nothing to open")
    }

    func testLeftClosesAFolderThenGoesToItsParent() async throws {
        try await loadNested()
        model.tree.reveal("src/util/x.swift", in: files)
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertEqual(selection, "src/util", "A file goes to its folder")
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertFalse(model.tree.expanded.contains(files + "|src/util"))
        XCTAssertEqual(selection, "src/util")
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertEqual(selection, "src")
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertNil(selection, "A top-level row goes to the root")
        XCTAssertTrue(model.perform(.collapse))
        XCTAssertTrue(model.tree.collapsedRoots.contains(files), "The root closes last")
        XCTAssertTrue(model.perform(.expand))
        XCTAssertFalse(model.tree.collapsedRoots.contains(files))
    }

    func testCollapseAllSelectsTheTopLevelRowThatHeldTheSelection() async throws {
        try await loadNested()
        model.tree.reveal("src/util/y.swift", in: files)
        XCTAssertTrue(model.perform(.collapseAll))
        XCTAssertTrue(model.tree.expandedFolders(in: files).isEmpty)
        XCTAssertEqual(selection, "src")
    }

    func testOpeningAFileOrTogglingAFolder() async throws {
        try await loadNested()
        var opened: [(String, Bool)] = []
        XCTAssertTrue(perform(.openPreview, on: "b.txt"))
        XCTAssertTrue(model.perform(.openPreview, open: { opened.append(($1, $2)) }))
        XCTAssertTrue(model.perform(.open, open: { opened.append(($1, $2)) }))
        XCTAssertEqual(opened.map(\.0), ["b.txt", "b.txt"])
        XCTAssertEqual(opened.map(\.1), [true, false], "Space previews, Command-Down keeps it open")
        XCTAssertTrue(perform(.openPreview, on: "docs"))
        XCTAssertTrue(model.tree.expanded.contains(files + "|docs"))
        XCTAssertTrue(model.perform(.open))
        XCTAssertFalse(model.tree.expanded.contains(files + "|docs"))
    }

    func testFindInFolderSearchesTheSelectedFolderOrTheFilesFolder() async throws {
        try await loadNested()
        var searched: [String] = []
        model.tree.selected = files + "|src/main.swift"
        XCTAssertTrue(model.perform(.findInFolder, findInFolder: { searched.append($1) }))
        model.tree.selected = files + "|docs"
        XCTAssertTrue(model.perform(.findInFolder, findInFolder: { searched.append($1) }))
        model.tree.selected = nil
        XCTAssertTrue(model.perform(.findInFolder, findInFolder: { searched.append($1) }))
        XCTAssertEqual(searched, ["src", "docs", ""])
    }

    func testTheChangesTreeNavigatesAndOpensButHasNoFileOperations() async throws {
        try await loadNested()
        try "changed\n".write(toFile: sandbox.path("nested") + "/b.txt", atomically: true, encoding: .utf8)
        await load()
        model.showsChanges = true
        let changes = "\(repo.identity)|changes"
        XCTAssertTrue(model.perform(.selectNext))
        XCTAssertEqual(model.tree.selectedPath(in: changes), "b.txt")
        var opened: [String] = []
        XCTAssertTrue(model.perform(.openPreview, open: { _, path, _ in opened.append(path) }))
        XCTAssertEqual(opened, ["b.txt"])
        XCTAssertFalse(model.perform(.rename))
        XCTAssertFalse(model.perform(.trashAsking))
        XCTAssertTrue(model.perform(.deselect))
        XCTAssertNil(model.tree.selectedPath(in: changes))
    }

    // MARK: Active file

    func testTheActiveFileIsSelectedWithTheFoldersAboveIt() async throws {
        try await loadNested()
        model.tree.collapsedRoots.insert(files)
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "src/util/x.swift"))
        XCTAssertEqual(selection, "src/util/x.swift")
        XCTAssertFalse(model.tree.collapsedRoots.contains(files))
        XCTAssertEqual(Set(model.tree.expandedFolders(in: files)), ["src", "src/util"])
    }

    func testTheActiveFileIsLeftAloneWhenTheTreeDoesNotListIt() async throws {
        try await loadNested()
        let other = try sandbox.repository("other")
        model.tree.selected = files + "|b.txt"
        model.revealActiveFile(WorkspaceActiveFile(location: other, path: "a.txt"))
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "build/out.log"))
        model.modifiedOnly = true
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "docs/a.md"))
        XCTAssertEqual(selection, "b.txt", "Another Space, an unlisted file and an unmodified one")
        model.modifiedOnly = false

        model.startDraft(in: "", isFolder: false, at: repo)
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "docs/a.md"))
        XCTAssertEqual(selection, "b.txt", "Not while an item is being named")
    }

    func testTheActiveFileWaitsForItsSpacesListing() async throws {
        try await loadNested()
        let other = try sandbox.repository("other")
        let load = model.loadListing(at: other)
        model.revealActiveFile(WorkspaceActiveFile(location: other, path: "a.txt"))
        XCTAssertNil(model.tree.selected, "The previous Space's listing is still shown")
        await load?.value
        model.revealActiveFile(WorkspaceActiveFile(location: other, path: "a.txt"))
        XCTAssertEqual(model.tree.selectedPath(in: "\(other.identity)|files"), "a.txt")
    }

    func testTheChangesTreeSelectsTheActiveChangedFile() async throws {
        try await loadNested()
        try "changed\n".write(toFile: sandbox.path("nested") + "/src/main.swift", atomically: true, encoding: .utf8)
        await load()
        model.showsChanges = true
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "b.txt"))
        XCTAssertNil(model.tree.selected, "An unchanged file is not in the Changes tree")
        model.revealActiveFile(WorkspaceActiveFile(location: repo, path: "src/main.swift"))
        XCTAssertEqual(model.tree.selectedPath(in: "\(repo.identity)|changes"), "src/main.swift")
    }

    // MARK: Drag and drop

    func testDropRules() async throws {
        try await loadNested()
        XCTAssertEqual(model.dropAction(of: ["src/main.swift"], into: "docs", copy: false), .move)
        XCTAssertEqual(model.dropAction(of: ["src/main.swift"], into: "docs", copy: true), .copy)
        XCTAssertNil(model.dropAction(of: ["src/main.swift"], into: "src", copy: false), "Already there")
        XCTAssertEqual(model.dropAction(of: ["src/main.swift"], into: "src", copy: true), .copy, "Option duplicates it")
        XCTAssertNil(model.dropAction(of: ["src"], into: "src", copy: true))
        XCTAssertNil(model.dropAction(of: ["src"], into: "src/util", copy: false), "Not into itself")
        XCTAssertEqual(model.dropAction(of: ["src"], into: "", copy: false), nil, "Already at the root")
        XCTAssertEqual(model.dropAction(of: nil, into: "src", copy: false), .copy, "Files from elsewhere are copied")
        model.showsChanges = true
        XCTAssertNil(model.dropAction(of: nil, into: "src", copy: false), "Not in the Changes tree")
    }

    func testOnlyThisTreesOwnDragIsAnItemOfIt() async throws {
        try await loadNested()
        let provider = model.startDrag("src/util", in: repo)
        XCTAssertEqual(model.draggedItems([provider], location: repo), ["src/util"])
        XCTAssertNil(model.draggedItems([NSItemProvider(object: URL(fileURLWithPath: "/tmp/x") as NSURL)], location: repo),
                     "Files from Finder")
        let other = try sandbox.repository("other")
        XCTAssertNil(model.draggedItems([provider], location: other), "A drag from another Space's tree")
        XCTAssertEqual(model.draggedItems(files: [repo.absolutePath("src/util")], location: repo), ["src/util"],
                       "Dropped as a file, it is still the dragged item")
        XCTAssertNil(model.draggedItems(files: [repo.absolutePath("b.txt")], location: repo))
    }

    func testDroppingAnItemMovesItAndCarriesItsTreeState() async throws {
        try await loadNested()
        model.tree.expand("src/util", in: files)
        model.tree.selected = files + "|src/util/x.swift"
        await model.dropItems(["src/util"], into: "docs", copy: false, in: repo)?.value
        XCTAssertNil(model.operationError)
        XCTAssertFalse(exists("src/util", in: "nested"))
        XCTAssertTrue(exists("docs/util/x.swift", in: "nested"))
        XCTAssertTrue(model.tree.expanded.contains(files + "|docs/util"))
        XCTAssertEqual(selection, "docs/util")
        XCTAssertTrue(model.listing?.files.contains("docs/util/x.swift") ?? false)
    }

    func testDroppingWithOptionCopies() async throws {
        try await loadNested()
        await model.dropItems(["b.txt"], into: "docs", copy: true, in: repo)?.value
        await model.dropItems(["b.txt"], into: "", copy: true, in: repo)?.value
        XCTAssertTrue(exists("b.txt", in: "nested"))
        XCTAssertTrue(exists("docs/b.txt", in: "nested"))
        XCTAssertTrue(exists("b copy.txt", in: "nested"))
        XCTAssertNil(model.dropItems(["b.txt"], into: "", copy: false, in: repo), "A move where it is does nothing")
    }

    func testDroppedFilesFromFinderAreCopied() async throws {
        try await loadNested()
        try sandbox.write(["photo.png": "png", "kit/readme.md": "kit\n"], in: "finder")
        await model.importFiles([sandbox.path("finder/photo.png"), sandbox.path("finder/kit")], into: "docs", in: repo)?.value
        XCTAssertNil(model.operationError)
        XCTAssertTrue(exists("docs/photo.png", in: "nested"))
        XCTAssertTrue(exists("docs/kit/readme.md", in: "nested"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path("finder/photo.png")), "The original stays")
        XCTAssertEqual(selection, "docs/kit")
    }

    func testAClosedFolderOpensWhileADragHoldsOverIt() async throws {
        try await loadNested()
        model.dragEntered(row: "docs", folder: "docs", location: repo)
        XCTAssertEqual(model.dropFolder, "docs")
        model.dragEntered(row: "src", folder: "src", location: repo)
        model.dragExited(row: "docs")
        XCTAssertEqual(model.dropFolder, "src", "Leaving the previous row after entering the next keeps the next")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(model.tree.expanded.contains(files + "|src"))
        XCTAssertFalse(model.tree.expanded.contains(files + "|docs"))
        model.dragEntered(row: "b.txt", folder: "", location: repo)
        XCTAssertEqual(model.dropFolder, "", "A file's drop goes in its folder")
        model.dragEnded()
        XCTAssertNil(model.dropFolder)
    }

    // MARK: Selecting several rows

    private func mark(_ paths: String...) {
        model.tree.selected = files + "|" + paths[0]
        for path in paths.dropFirst() { model.toggleMark(path, in: repo) }
    }

    func testCommandClickAddsAndRemovesRows() async throws {
        try await loadNested()
        mark("b.txt", "docs")
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt", "docs"])
        XCTAssertEqual(selection, "docs", "The row clicked last is the selected one")
        model.toggleMark("b.txt", in: repo)
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt"])
        model.tree.selected = files + "|src"
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["src"], "A plain click selects only it")
    }

    func testShiftSelectsTheRowsBetween() async throws {
        try await loadNested()
        model.tree.selected = files + "|docs"
        model.extendSelection(to: "b.txt", in: repo)
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt", "docs", "src"])
        model.extendSelection(to: "src", in: repo)
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["docs", "src"], "The range starts at the first click")
        XCTAssertTrue(model.perform(.extendNext))
        XCTAssertTrue(model.perform(.extendNext))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt", "docs", "src"])
        XCTAssertTrue(model.perform(.extendPrevious))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["docs", "src"])
        XCTAssertTrue(model.perform(.deselect))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["src"], "Escape keeps the selected row first")
        XCTAssertTrue(model.perform(.deselect))
        XCTAssertNil(model.tree.selected)
    }

    func testAFolderAndWhatIsInItActAsTheFolder() async throws {
        try await loadNested()
        model.tree.expand("src", in: files)
        mark("src", "src/main.swift", "b.txt")
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt", "src"])
    }

    func testShortcutsActOnEverySelectedRow() async throws {
        try await loadNested()
        mark("b.txt", "docs/a.md")
        XCTAssertTrue(model.perform(.copyRelativePath))
        XCTAssertTrue(model.perform(.copyPath))
        XCTAssertEqual(copied, ["b.txt\ndocs/a.md", repo.absolutePath("b.txt") + "\n" + repo.absolutePath("docs/a.md")])
        XCTAssertTrue(model.perform(.trashAsking))
        XCTAssertEqual(model.pendingDelete?.paths, ["b.txt", "docs/a.md"])
        model.pendingDelete = nil
        XCTAssertTrue(model.perform(.rename))
        XCTAssertEqual(model.draft?.renaming, "docs/a.md", "Renaming takes the selected row only")
        model.draft = nil

        XCTAssertTrue(model.perform(.delete))
        await model.delete(model.pendingDelete!).value
        model.pendingDelete = nil
        XCTAssertFalse(exists("b.txt", in: "nested"))
        XCTAssertFalse(exists("docs/a.md", in: "nested"))
    }

    func testCopyingAndDuplicatingSeveralRows() async throws {
        try await loadNested()
        mark("b.txt", "docs")
        XCTAssertTrue(model.perform(.copy))
        XCTAssertEqual(pasteboardFiles, [repo.absolutePath("b.txt"), repo.absolutePath("docs")])
        model.tree.selected = files + "|src"
        XCTAssertTrue(model.perform(.paste))
        await settle()
        XCTAssertTrue(exists("src/b.txt", in: "nested"))
        XCTAssertTrue(exists("src/docs/a.md", in: "nested"))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["src/b.txt", "src/docs"], "What was pasted is selected")

        mark("b.txt", "src/main.swift")
        XCTAssertTrue(model.perform(.duplicate))
        await settle()
        XCTAssertTrue(exists("b copy.txt", in: "nested"))
        XCTAssertTrue(exists("src/main copy.swift", in: "nested"))
    }

    func testDraggingASelectedRowMovesTheSelection() async throws {
        try await loadNested()
        mark("b.txt", "src/util")
        let provider = model.startDrag("b.txt", in: repo)
        let dragged = try XCTUnwrap(model.draggedItems([provider], location: repo))
        XCTAssertEqual(dragged, ["b.txt", "src/util"])
        XCTAssertNil(model.dropAction(of: dragged, into: "src/util/deep", copy: false), "Not into one of them")
        await model.dropItems(dragged, into: "docs", copy: false, in: repo)?.value
        XCTAssertNil(model.operationError)
        XCTAssertTrue(exists("docs/b.txt", in: "nested"))
        XCTAssertTrue(exists("docs/util/x.swift", in: "nested"))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["docs/b.txt", "docs/util"])

        let unselected = model.startDrag("src/main.swift", in: repo)
        XCTAssertEqual(model.draggedItems([unselected], location: repo), ["src/main.swift"],
                       "A row outside the selection is dragged alone")
    }

    // MARK: Undo

    /// Trashing moves items to a folder of the sandbox instead of the Trash.
    private func useSandboxTrash() throws {
        let trash = sandbox.path("Trash")
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        savedTrash = WorkspaceFiles.trashItem
        WorkspaceFiles.trashItem = { url in
            let destination = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func undo() async { await model.undo(at: repo)?.value }
    private func redo() async { await model.redo(at: repo)?.value }

    func testUndoingANewFileTrashesItAndRedoingBringsItBack() async throws {
        try await loadNested()
        try useSandboxTrash()
        model.startDraft(in: "docs", isFolder: false, at: repo)
        await commit("new.md")
        XCTAssertEqual(model.undoName(at: repo), "New File")
        await undo()
        XCTAssertNil(model.operationError)
        XCTAssertFalse(exists("docs/new.md", in: "nested"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("Trash")).count, 1)
        XCTAssertEqual(model.redoName(at: repo), "New File")
        await redo()
        XCTAssertTrue(exists("docs/new.md", in: "nested"))
        XCTAssertEqual(selection, "docs/new.md")
        XCTAssertEqual(model.undoName(at: repo), "New File")
        XCTAssertNil(model.redoName(at: repo))
    }

    func testUndoingARenameRestoresTheNameAndTheSelection() async throws {
        try await loadNested()
        model.tree.expand("src/util", in: files)
        model.startRename("src/util", isDirectory: true, at: repo)
        await commit("tools")
        XCTAssertTrue(exists("src/tools/x.swift", in: "nested"))
        await undo()
        XCTAssertTrue(exists("src/util/x.swift", in: "nested"))
        XCTAssertFalse(exists("src/tools", in: "nested"))
        XCTAssertEqual(selection, "src/util")
        XCTAssertTrue(model.tree.expanded.contains(files + "|src/util"), "The folder stays open under its old name")
        await redo()
        XCTAssertTrue(exists("src/tools/x.swift", in: "nested"))
        XCTAssertEqual(model.undoName(at: repo), "Rename")
    }

    func testUndoingTrashPutsTheItemsBack() async throws {
        try await loadNested()
        try useSandboxTrash()
        mark("b.txt", "docs")
        XCTAssertTrue(model.perform(.trash))
        await settle()
        XCTAssertFalse(exists("docs/a.md", in: "nested"))
        XCTAssertTrue(model.perform(.undo))
        await settle()
        XCTAssertTrue(exists("b.txt", in: "nested"))
        XCTAssertTrue(exists("docs/a.md", in: "nested"))
        XCTAssertEqual(model.tree.selectedPaths(in: files), ["b.txt", "docs"])
        XCTAssertTrue(model.perform(.redo))
        await settle()
        XCTAssertFalse(exists("b.txt", in: "nested"))
    }

    func testUndoingMovesAndCopiesFromDragsAndPastes() async throws {
        try await loadNested()
        try useSandboxTrash()
        await model.dropItems(["b.txt", "src/util"], into: "docs", copy: false, in: repo)?.value
        XCTAssertEqual(model.undoName(at: repo), "Move")
        await undo()
        XCTAssertTrue(exists("b.txt", in: "nested"))
        XCTAssertTrue(exists("src/util/x.swift", in: "nested"))
        XCTAssertFalse(exists("docs/util", in: "nested"))

        model.tree.selected = files + "|b.txt"
        XCTAssertTrue(model.perform(.cut))
        model.tree.selected = files + "|src"
        XCTAssertTrue(model.perform(.paste))
        await settle()
        XCTAssertTrue(exists("src/b.txt", in: "nested"))
        await undo()
        XCTAssertTrue(exists("b.txt", in: "nested"), "A cut and paste moves back")

        model.tree.selected = files + "|b.txt"
        XCTAssertTrue(model.perform(.copy))
        XCTAssertTrue(model.perform(.paste))
        await settle()
        XCTAssertTrue(exists("b copy.txt", in: "nested"))
        XCTAssertEqual(model.undoName(at: repo), "Paste")
        await undo()
        XCTAssertFalse(exists("b copy.txt", in: "nested"))
        XCTAssertTrue(exists("b.txt", in: "nested"))
    }

    func testANewOperationClearsRedoAndAFailedUndoStays() async throws {
        try await loadNested()
        model.startRename("b.txt", isDirectory: false, at: repo)
        await commit("c.txt")
        await undo()
        XCTAssertEqual(model.redoName(at: repo), "Rename")
        model.startRename("b.txt", isDirectory: false, at: repo)
        await commit("d.txt")
        XCTAssertNil(model.redoName(at: repo), "Doing something new drops what was undone")

        try "in the way\n".write(toFile: sandbox.path("nested") + "/b.txt", atomically: true, encoding: .utf8)
        await undo()
        XCTAssertNotNil(model.operationError, "b.txt is in the way")
        XCTAssertTrue(exists("d.txt", in: "nested"))
        XCTAssertEqual(model.undoName(at: repo), "Rename", "The rename can be undone once b.txt is gone")
        model.operationError = nil
        XCTAssertFalse(model.perform(.redo), "Nothing to redo")
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
        model.copyItems(["empty"], in: repo, cut: false)
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

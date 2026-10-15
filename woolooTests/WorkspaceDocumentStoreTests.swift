import XCTest
import Combine
@testable import wooloo

/// Open document tabs against a disposable repository: preview tabs, loading, saving and closing.
@MainActor
final class WorkspaceDocumentStoreTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var store: WorkspaceDocumentStore!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: ["a.txt": "one\n", "b.txt": "bee\n", "c.txt": "sea\n"])
        store = WorkspaceDocumentStore()
    }

    override func tearDown() async throws {
        sandbox.tearDown()
    }

    /// Waits until no document is loading or saving.
    private func settle() async {
        for _ in 0..<500 where store.documents.contains(where: { $0.isLoading || $0.isSaving }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.documents.contains { $0.isLoading || $0.isSaving }, "Documents did not settle")
    }

    private func open(_ path: String, _ kind: WorkspaceDocumentKind = .file, preview: Bool = false) async -> WorkspaceDocument? {
        store.open(kind, path: path, at: repo, preview: preview)
        await settle()
        return store.documents.first { $0.path == path && $0.kind == kind }
    }

    private func edit(_ path: String, _ text: String) {
        guard let index = store.documents.firstIndex(where: { $0.path == path && $0.kind == .file }) else {
            return XCTFail("\(path) is not open")
        }
        store.documents[index].text = text
    }

    /// An editor's scroll reports name its document: closing a tab before it moves its index.
    func testScrollPositionsAreRecordedByDocumentNotByIndex() async throws {
        let openedA = await open("a.txt")
        let a = try XCTUnwrap(openedA)
        let openedB = await open("b.txt")
        let b = try XCTUnwrap(openedB)
        let openedC = await open("c.txt")
        let c = try XCTUnwrap(openedC)
        XCTAssertTrue(store.close(a.id))
        var changes = 0
        let watch = store.objectWillChange.sink { changes += 1 }
        let anchor = EditorScrollAnchor(offset: 2, dy: 1.5)
        store.recordScroll(c.id, position: CGPoint(x: 0, y: 40), anchor: anchor)
        XCTAssertEqual(changes, 1, "one change for both")
        store.recordScroll(c.id, position: CGPoint(x: 0, y: 40), anchor: anchor)
        XCTAssertEqual(changes, 1, "none when it did not move")
        store.recordScroll(a.id, position: CGPoint(x: 0, y: 80), anchor: nil)
        watch.cancel()
        XCTAssertEqual(store.document(c.id)?.scrollPosition, CGPoint(x: 0, y: 40))
        XCTAssertEqual(store.document(c.id)?.scrollAnchor, anchor)
        XCTAssertEqual(store.document(b.id)?.scrollPosition, .zero)
        XCTAssertNil(store.document(b.id)?.scrollAnchor)
    }

    func testOpeningLoadsTheFileAndActivatesIt() async throws {
        let documentOpened = await open("a.txt")
        let document = try XCTUnwrap(documentOpened)
        XCTAssertEqual(document.text, "one\n")
        XCTAssertEqual(document.savedText, "one\n")
        XCTAssertNotNil(document.version)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(store.activeID, document.id)

        store.activeID = nil
        let reveal = WorkspaceDocumentReveal(line: 1, range: nil)
        store.open(.file, path: "a.txt", at: repo, reveal: reveal)
        XCTAssertEqual(store.documents.count, 1, "An open document is activated, not opened twice")
        XCTAssertEqual(store.activeID, document.id)
        XCTAssertEqual(store.documents[0].reveal, reveal)
    }

    func testChangesAndCommitsOpenAsDiffs() async throws {
        try sandbox.write(["a.txt": "two\n"], in: "repo")
        let changeOpened = await open("a.txt", .change)
        let change = try XCTUnwrap(changeOpened)
        XCTAssertTrue(change.patch.contains("+two"), change.patch)
        XCTAssertEqual(change.diffScope, .all)

        let head = try sandbox.sh("git rev-parse HEAD", in: "repo").trimmingCharacters(in: .newlines)
        store.open(.commit, path: "b.txt", at: repo, commit: head)
        await settle()
        let commit = try XCTUnwrap(store.documents.first { $0.kind == .commit })
        XCTAssertTrue(commit.text.contains("+bee"), commit.text)
        XCTAssertEqual(store.documents.count, 2)
    }

    func testMissingFilesShowAnError() async throws {
        let documentOpened = await open("missing.txt")
        let document = try XCTUnwrap(documentOpened)
        XCTAssertNotNil(document.error)
        XCTAssertFalse(document.isLoading)
    }

    /// Only one preview tab exists: a new preview replaces it until it is kept or edited.
    func testPreviewsReplaceEachOtherUntilKeptOrEdited() async throws {
        _ = await open("a.txt", preview: true)
        _ = await open("b.txt", preview: true)
        XCTAssertEqual(store.documents.map(\.path), ["b.txt"])
        XCTAssertEqual(store.documents[0].text, "bee\n")

        store.keepOpen(store.documents[0].id)
        _ = await open("c.txt", preview: true)
        XCTAssertEqual(store.documents.map(\.path), ["b.txt", "c.txt"])
        XCTAssertEqual(store.documents.map(\.isPreview), [false, true])

        edit("c.txt", "edited\n")
        store.keepEditedPreviewsOpen()
        _ = await open("a.txt", preview: true)
        XCTAssertEqual(store.documents.map(\.path), ["b.txt", "c.txt", "a.txt"])
        XCTAssertEqual(store.documents.map(\.isPreview), [false, false, true])

        store.open(.file, path: "a.txt", at: repo)
        XCTAssertEqual(store.documents.map(\.isPreview), [false, false, false], "Opening a preview for real keeps it")
    }

    /// A preview with unsaved edits is never replaced, even before it was marked kept.
    func testEditedPreviewIsNotReplaced() async throws {
        _ = await open("a.txt", preview: true)
        edit("a.txt", "edited\n")
        _ = await open("b.txt", preview: true)
        XCTAssertEqual(store.documents.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(store.documents[0].text, "edited\n")
    }

    /// Each Space shows only the tabs opened in it, with its own preview.
    func testDocumentsStayInTheirSpace() async throws {
        _ = await open("a.txt")
        store.showSpace("one")
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["a.txt"], "Tabs opened before a Space join the first one")
        let first = try XCTUnwrap(store.activeID)
        _ = await open("b.txt", preview: true)

        store.showSpace("two")
        XCTAssertTrue(store.visibleDocuments.isEmpty)
        XCTAssertNil(store.activeID, "Another Space's document is not left active")
        _ = await open("c.txt", preview: true)
        _ = await open("a.txt")
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["c.txt", "a.txt"])

        store.showSpace("one")
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["a.txt", "b.txt"], "A Space's preview is not replaced from another")
        XCTAssertEqual(store.visibleDocuments.map(\.isPreview), [false, true])
        XCTAssertTrue(store.close(first))
        store.showSpace("two")
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["c.txt", "a.txt"])
    }

    func testSaveWritesTheFileAndReportsIt() async throws {
        _ = await open("a.txt")
        edit("a.txt", "changed\n")
        var saved = 0
        store.save(store.documents[0].id) { saved += 1 }
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "changed\n")
        XCTAssertFalse(store.documents[0].isDirty)
        XCTAssertNil(store.documents[0].error)
        XCTAssertEqual(saved, 1)

        store.save(store.documents[0].id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1, "A document without edits is not saved")
    }

    /// A file changed on disk since it was read is not overwritten.
    func testSaveRefusesAFileChangedOnDisk() async throws {
        _ = await open("a.txt")
        try sandbox.write(["a.txt": "from elsewhere\n"], in: "repo")
        edit("a.txt", "mine\n")
        var saved = false
        store.save(store.documents[0].id) { saved = true }
        await settle()
        XCTAssertFalse(saved)
        XCTAssertTrue(store.documents[0].asksToOverwrite, "Saving asks before overwriting")
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "from elsewhere\n")
    }

    // MARK: Changes on disk

    /// Waits for `condition` on the main actor, giving pending loads time to finish.
    private func wait(_ message: String, until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), message)
    }

    private func checkDisk() async {
        await store.checkDisk(at: repo.identity).value
        await settle()
    }

    /// A preview tab without edits reloads silently when its file changes on disk, and tells a
    /// shown editor to take the new text; nothing changes while the file stays the same.
    func testCleanPreviewReloadsWhenItsFileChangesOnDisk() async throws {
        let opened = await open("a.txt", preview: true)
        let document = try XCTUnwrap(opened)
        var changes = 0
        let watch = store.objectWillChange.sink { changes += 1 }
        await checkDisk()
        XCTAssertEqual(changes, 0, "An unchanged file publishes nothing")
        watch.cancel()

        try sandbox.write(["a.txt": "from elsewhere\n"], in: "repo")
        await checkDisk()
        await wait("The preview reloads") { store.documents.first?.text == "from elsewhere\n" }
        let reloaded = try XCTUnwrap(store.document(document.id))
        XCTAssertTrue(reloaded.isPreview, "Reloading keeps it a preview")
        XCTAssertFalse(reloaded.isDirty)
        XCTAssertEqual(reloaded.diskState, .current)
        XCTAssertEqual(reloaded.version, WorkspaceFiles.gitBlobHash(Data("from elsewhere\n".utf8)))
        XCTAssertNotNil(reloaded.diskReload)
    }

    /// Unsaved edits are kept when the file changes on disk; the tab is marked until the user
    /// reloads or keeps them, and saving asks before overwriting the newer file.
    func testEditedDocumentKeepsItsEditsAndAsksBeforeOverwriting() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        await checkDisk()
        let theirs = WorkspaceFiles.gitBlobHash(Data("theirs\n".utf8))
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertEqual(store.documents[0].diskState, .changed(version: theirs))

        var saved = 0
        store.save(store.documents[0].id) { saved += 1 }
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite, "Saving asks first")
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "theirs\n")

        store.overwrite(store.documents[0].id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
        XCTAssertEqual(store.documents[0].diskState, .current)
        XCTAssertFalse(store.documents[0].asksToOverwrite)
        XCTAssertFalse(store.documents[0].isDirty)
    }

    /// Keep Mine makes the next save overwrite the file without asking.
    func testKeepingEditsLetsTheNextSaveOverwrite() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        await checkDisk()
        store.keepEdits(store.documents[0].id)
        XCTAssertEqual(store.documents[0].diskState, .current)
        await checkDisk()
        XCTAssertEqual(store.documents[0].diskState, .current, "The kept version is the one on disk")
        store.save(store.documents[0].id)
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
    }

    /// Reload discards the edits and reads the newer file.
    func testRevertingReadsTheNewerFile() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        await checkDisk()
        store.revert(store.documents[0].id)
        await wait("The file is read again") { store.documents[0].text == "theirs\n" }
        XCTAssertEqual(store.documents[0].diskState, .current)
        XCTAssertFalse(store.documents[0].isDirty)
    }

    /// Undoing the edits of a marked tab reloads it, as Zed does.
    func testUndoingEditsOfAChangedFileReloadsIt() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        await checkDisk()
        edit("a.txt", "one\n")
        await checkDisk()
        await wait("The file is read again") { store.documents[0].text == "theirs\n" }
        XCTAssertEqual(store.documents[0].diskState, .current)
    }

    /// A file deleted on disk keeps its tab and buffer; Save creates it again.
    func testDeletedFileKeepsItsTabAndSaveRecreatesIt() async throws {
        _ = await open("a.txt")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        await checkDisk()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.documents[0].diskState, .deleted)
        XCTAssertEqual(store.documents[0].text, "one\n")
        XCTAssertTrue(store.documents[0].canSave, "A clean buffer can be saved to recreate the file")

        var saved = false
        store.save(store.documents[0].id) { saved = true }
        await settle()
        XCTAssertTrue(saved)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n")
        XCTAssertEqual(store.documents[0].diskState, .current)
        XCTAssertFalse(store.documents[0].canSave)
        await checkDisk()
        XCTAssertEqual(store.documents[0].diskState, .current)
    }

    /// The same file coming back after a deletion is followed again.
    func testDeletedFileThatComesBackIsFollowedAgain() async throws {
        _ = await open("a.txt")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        await checkDisk()
        try sandbox.write(["a.txt": "one\n"], in: "repo")
        await checkDisk()
        XCTAssertEqual(store.documents[0].diskState, .current)
        XCTAssertFalse(store.documents[0].isDirty)
    }

    /// Saving a file deleted under unsaved edits recreates it, and one changed under them asks.
    func testSavingFindsWhatHappenedOnDisk() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        store.save(store.documents[0].id)
        await settle()
        XCTAssertEqual(store.documents[0].diskState, .deleted, "The failed save finds the file gone")
        store.save(store.documents[0].id)
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")

        edit("a.txt", "mine again\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        store.save(store.documents[0].id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        XCTAssertEqual(store.documents[0].diskState, .changed(version: WorkspaceFiles.gitBlobHash(Data("theirs\n".utf8))))
        XCTAssertNil(store.documents[0].error)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "theirs\n")
    }

    /// Typing while a reload reads the file keeps the version the edits started from, so saving
    /// asks instead of overwriting the newer file.
    func testTypingDuringAReloadKeepsTheConflict() async throws {
        _ = await open("a.txt")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        store.load(store.documents[0].id)
        edit("a.txt", "typed\n")
        let theirs = WorkspaceFiles.gitBlobHash(Data("theirs\n".utf8))
        await wait("The read finishes") { store.documents[0].diskState == .changed(version: theirs) }
        XCTAssertEqual(store.documents[0].text, "typed\n")
        XCTAssertEqual(store.documents[0].version, WorkspaceFiles.gitBlobHash(Data("one\n".utf8)))
        store.save(store.documents[0].id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "theirs\n")
    }

    /// Overwrite writes the buffer of a deleted tab without edits whose file came back.
    func testOverwritingADeletedTabWhoseFileCameBackWritesItsBuffer() async throws {
        _ = await open("a.txt")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        await checkDisk()
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        store.save(store.documents[0].id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        await checkDisk()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.documents[0].text, "one\n", "No reload while the save asks")
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        var saved = false
        store.overwrite(store.documents[0].id) { saved = true }
        await settle()
        XCTAssertTrue(saved)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n")
        XCTAssertEqual(store.documents[0].text, "one\n")
    }

    /// A deleted file too large to save is not recreated empty.
    func testRecreatingTooLargeAFileLeavesNothingBehind() async throws {
        _ = await open("a.txt")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        await checkDisk()
        edit("a.txt", String(repeating: "x", count: WorkspaceFiles.maximumFileBytes + 1))
        store.save(store.documents[0].id)
        await settle()
        XCTAssertEqual(store.documents[0].error, "File is too large")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.absolutePath("a.txt")))
        XCTAssertEqual(store.documents[0].diskState, .deleted)
        XCTAssertFalse(store.documents[0].asksToOverwrite)
    }

    /// Another file appearing at a deleted file's path does not replace the tab's text, the only
    /// copy left of the deleted file: the tab now has unsaved edits.
    func testFileReplacingADeletedOneKeepsTheTabsText() async throws {
        _ = await open("a.txt")
        _ = try sandbox.sh("rm a.txt", in: "repo")
        await checkDisk()
        try sandbox.write(["a.txt": "another\n"], in: "repo")
        await checkDisk()
        await checkDisk()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.documents[0].text, "one\n")
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertEqual(store.documents[0].diskState, .changed(version: WorkspaceFiles.gitBlobHash(Data("another\n".utf8))))
        XCTAssertFalse(store.close(store.documents[0].id), "Closing asks first")
    }

    // MARK: The Overwrite / Reload / Cancel question

    /// Sets up a tab with unsaved edits over a file changed on disk, whose save asks.
    private func conflict(mine: String = "mine\n", theirs: String = "theirs\n") async throws -> String {
        _ = await open("a.txt")
        edit("a.txt", mine)
        try sandbox.write(["a.txt": theirs], in: "repo")
        let id = store.documents[0].id
        store.save(id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite, "Saving asks before overwriting")
        XCTAssertEqual(store.documents[0].overwriteVersion, WorkspaceFiles.gitBlobHash(Data(theirs.utf8)))
        return id
    }

    /// Cancel keeps the edits and the newer file; the next save asks again.
    func testCancellingTheOverwriteQuestionKeepsBothVersions() async throws {
        let id = try await conflict()
        store.cancelOverwrite(id)
        store.cancelOverwrite(id)
        XCTAssertFalse(store.documents[0].asksToOverwrite)
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "theirs\n")
        await checkDisk()
        XCTAssertEqual(store.documents[0].text, "mine\n", "A disk check does not drop the edits")

        store.save(id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite, "Asked again")
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "theirs\n")
    }

    /// Reload, from the question, discards the edits for the newer file.
    func testReloadingFromTheOverwriteQuestionReadsTheNewerFile() async throws {
        let id = try await conflict()
        store.revert(id)
        await wait("The newer file is read") { store.documents[0].text == "theirs\n" }
        XCTAssertFalse(store.documents[0].asksToOverwrite)
        XCTAssertNil(store.documents[0].overwriteVersion)
        XCTAssertFalse(store.documents[0].isDirty)
        XCTAssertEqual(store.documents[0].diskState, .current)
    }

    /// A change on disk while the question is shown is not overwritten unseen: Overwrite writes
    /// nothing and says why, and the next save asks about the newer file.
    func testAChangeWhileTheQuestionIsShownIsNotOverwrittenUnseen() async throws {
        let id = try await conflict()
        try sandbox.write(["a.txt": "third\n"], in: "repo")
        await checkDisk()
        let third = WorkspaceFiles.gitBlobHash(Data("third\n".utf8))
        XCTAssertEqual(store.documents[0].diskState, .changed(version: third))
        var saved = 0
        store.overwrite(id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "third\n")
        XCTAssertEqual(store.documents[0].error, WorkspaceDocumentStore.changedAgainMessage)
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertFalse(store.documents[0].asksToOverwrite)

        store.save(id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        XCTAssertEqual(store.documents[0].overwriteVersion, third)
        store.overwrite(id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
        XCTAssertNil(store.documents[0].error)
        XCTAssertFalse(store.documents[0].isDirty)
    }

    /// The same without a disk check in between: the conflict-checked write finds the newer file,
    /// writes nothing and says why. Asking the same question again would read as a missed click,
    /// and a second Overwrite would then replace a version nobody saw.
    func testAChangeBeforeAnyCheckIsFoundByTheWrite() async throws {
        let id = try await conflict()
        try sandbox.write(["a.txt": "third\n"], in: "repo")
        var saved = 0
        store.overwrite(id) { saved += 1 }
        await settle()
        let third = WorkspaceFiles.gitBlobHash(Data("third\n".utf8))
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "third\n")
        XCTAssertFalse(store.documents[0].asksToOverwrite)
        XCTAssertNil(store.documents[0].overwriteVersion)
        XCTAssertEqual(store.documents[0].error, WorkspaceDocumentStore.changedAgainMessage)
        XCTAssertEqual(store.documents[0].diskState, .changed(version: third))
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertTrue(store.documents[0].isDirty)

        // The next save asks about the newer file, and Overwrite then writes over it.
        store.save(id)
        await settle()
        XCTAssertTrue(store.documents[0].asksToOverwrite)
        XCTAssertEqual(store.documents[0].overwriteVersion, third)
        store.overwrite(id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
        XCTAssertNil(store.documents[0].error)
    }

    /// Repeated clicks save once.
    func testRepeatedSavesAndOverwritesWriteOnce() async throws {
        _ = await open("a.txt")
        edit("a.txt", "changed\n")
        var saved = 0
        let id = store.documents[0].id
        store.save(id) { saved += 1 }
        store.save(id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "changed\n")

        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        store.save(id)
        await settle()
        store.overwrite(id) { saved += 1 }
        store.overwrite(id) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 2)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
        store.keepEdits(id)
        store.revert(id)
        store.revert(id)
        await wait("Read again") { !store.documents[0].isDirty && store.documents[0].text == "mine\n" }
    }

    /// Saving a tab other than the active one writes that tab's own text and leaves the active one alone.
    func testSavingAnInactiveTabWritesItsOwnText() async throws {
        let firstOpened = await open("a.txt")
        let first = try XCTUnwrap(firstOpened)
        let secondOpened = await open("b.txt")
        let second = try XCTUnwrap(secondOpened)
        edit("a.txt", "a edited\n")
        edit("b.txt", "b edited\n")
        XCTAssertEqual(store.activeID, second.id)

        store.save(first.id)
        await settle()
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "a edited\n")
        XCTAssertEqual(try sandbox.read("b.txt", in: "repo"), "bee\n")
        XCTAssertFalse(try XCTUnwrap(store.document(first.id)).isDirty)
        XCTAssertTrue(try XCTUnwrap(store.document(second.id)).isDirty)
        XCTAssertEqual(store.activeID, second.id, "Saving does not switch tabs")

        // A conflict on the inactive tab asks about that tab.
        edit("a.txt", "a again\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        store.save(first.id)
        await settle()
        XCTAssertTrue(try XCTUnwrap(store.document(first.id)).asksToOverwrite)
        XCTAssertFalse(try XCTUnwrap(store.document(second.id)).asksToOverwrite)
    }

    /// A failed write keeps the edits and the file as it was; saving works once it can.
    func testAFailedWriteKeepsTheEdits() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        let folder = repo.root
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        var saved = false
        store.save(store.documents[0].id) { saved = true }
        await settle()
        XCTAssertFalse(saved)
        XCTAssertNotNil(store.documents[0].error)
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertFalse(store.documents[0].asksToOverwrite)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        store.save(store.documents[0].id) { saved = true }
        await settle()
        XCTAssertTrue(saved)
        XCTAssertNil(store.documents[0].error)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "mine\n")
    }

    /// A failed read, such as a reload of a file that became unreadable, keeps the edits.
    func testAFailedReloadKeepsTheEdits() async throws {
        _ = await open("a.txt")
        edit("a.txt", "mine\n")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        let file = repo.absolutePath("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file) }
        store.revert(store.documents[0].id)
        await wait("The read fails") { store.documents[0].error != nil }
        XCTAssertEqual(store.documents[0].text, "mine\n")
        XCTAssertTrue(store.documents[0].isDirty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        store.revert(store.documents[0].id)
        await wait("The read succeeds") { store.documents[0].text == "theirs\n" }
        XCTAssertNil(store.documents[0].error)
    }

    /// This Mac's files: a rewrite of the same size that puts the modification time back is
    /// still seen, through the status change time.
    func testLocalDiskVersionsSeeRewritesThatKeepTheModificationTime() throws {
        try sandbox.write(["same.txt": "aaa\n"], in: "repo")
        let before = WorkspaceFiles.diskVersions(["same.txt"], at: repo)
        _ = try sandbox.sh("touch -r same.txt ref && printf 'bbb\\n' > same.txt && touch -r ref same.txt", in: "repo")
        XCTAssertEqual(try sandbox.read("same.txt", in: "repo"), "bbb\n")
        XCTAssertNotEqual(WorkspaceFiles.diskVersions(["same.txt"], at: repo), before)
        XCTAssertEqual(WorkspaceFiles.diskVersions(["same.txt"], at: repo),
                       ["same.txt": .present(WorkspaceFiles.gitBlobHash(Data("bbb\n".utf8)))])
    }

    /// Only files at the location checked are compared.
    func testCheckingAnotherLocationLeavesDocumentsAlone() async throws {
        _ = await open("a.txt")
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        await store.checkDisk(at: sandbox.location("other").identity).value
        XCTAssertEqual(store.documents[0].diskState, .current, "Not compared")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.documents[0].text, "one\n")
        await store.checkDisk().value
        await wait("Every location is checked") { store.documents[0].text == "theirs\n" }
    }

    /// A reload replaces in the editor only the text that differs, never half a surrogate pair.
    func testReloadReplacesOnlyTheChangedText() {
        func changed(_ old: String, _ new: String) -> NSRange {
            EditorRevealCoordinator.changedRange(from: old as NSString, to: new as NSString)
        }
        XCTAssertEqual(changed("one\ntwo\nthree\n", "one\n2\nthree\n"), NSRange(location: 4, length: 3))
        XCTAssertEqual(changed("abc", "abcdef"), NSRange(location: 3, length: 0))
        XCTAssertEqual(changed("abcdef", "def"), NSRange(location: 0, length: 3))
        XCTAssertEqual(changed("aaa", "aa"), NSRange(location: 2, length: 1))
        XCTAssertEqual(changed("x😀y", "x😃y"), NSRange(location: 1, length: 2))
        XCTAssertEqual(changed("", "new"), NSRange(location: 0, length: 0))
    }

    func testClosingAskFirstForUnsavedEdits() async throws {
        let firstOpened = await open("a.txt")
        let first = try XCTUnwrap(firstOpened)
        let secondOpened = await open("b.txt")
        let second = try XCTUnwrap(secondOpened)
        edit("b.txt", "edited\n")
        XCTAssertFalse(store.close(second.id))
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.activeID, second.id)

        XCTAssertTrue(store.close(second.id, force: true))
        XCTAssertNil(store.activeID, "Closing the active tab shows the terminals")
        store.activeID = WorkspaceSearchModel.tabID
        XCTAssertTrue(store.close(first.id))
        XCTAssertEqual(store.activeID, WorkspaceSearchModel.tabID)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.close("not open"))
    }

    /// After a project replace, open files are read again unless they have unsaved edits.
    func testFilesWrittenElsewhereReloadUnlessEdited() async throws {
        _ = await open("a.txt")
        _ = await open("b.txt")
        edit("b.txt", "unsaved\n")
        XCTAssertTrue(store.hasUnsavedEdits(at: repo, path: "b.txt"))
        XCTAssertFalse(store.hasUnsavedEdits(at: repo, path: "a.txt"))
        XCTAssertFalse(store.hasUnsavedEdits(at: sandbox.location("other"), path: "b.txt"))

        try sandbox.write(["a.txt": "replaced\n", "b.txt": "replaced\n"], in: "repo")
        await store.checkDisk(at: repo.identity).value
        // A reload keeps showing the old text rather than a spinner, so wait for the new one.
        for _ in 0..<500 where store.documents[0].text != "replaced\n" { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.documents.map(\.text), ["replaced\n", "unsaved\n"])
    }

    // MARK: Untitled files

    /// New untitled tabs take the lowest free number of their Space, open as regular tabs and
    /// take the keyboard; nothing is read from disk.
    func testUntitledFilesAreNumberedPerSpaceAndFocused() throws {
        store.showSpace("one")
        let first = store.newUntitled(at: repo)
        let second = store.newUntitled(at: repo)
        XCTAssertEqual(store.visibleDocuments.map(\.title), ["Untitled-1", "Untitled-2"])
        XCTAssertEqual(store.activeID, second)
        let document = try XCTUnwrap(store.document(second))
        XCTAssertTrue(document.isUntitled)
        XCTAssertFalse(document.isLoading)
        XCTAssertFalse(document.isPreview)
        XCTAssertFalse(document.isDirty, "An empty untitled file has nothing to save")
        XCTAssertNotNil(document.focusRequest)
        XCTAssertEqual(document.displayPath, "Untitled-2")
        XCTAssertTrue(store.recentPaths(at: repo).isEmpty, "Untitled files are not recent files")

        XCTAssertTrue(store.close(first))
        store.newUntitled(at: repo)
        XCTAssertEqual(store.visibleDocuments.map(\.title), ["Untitled-2", "Untitled-1"], "The lowest free number is reused")

        store.showSpace("two")
        store.newUntitled(at: repo)
        XCTAssertEqual(store.visibleDocuments.map(\.title), ["Untitled-1"], "Each Space numbers its own")
        XCTAssertEqual(Set(store.documents.map(\.id)).count, store.documents.count)
    }

    func testClosingAnUntitledFileAsksOnlyOnceItHasText() throws {
        let id = store.newUntitled(at: repo)
        let index = try XCTUnwrap(store.documents.firstIndex { $0.id == id })
        store.documents[index].text = "draft"
        XCTAssertTrue(store.documents[index].isDirty)
        XCTAssertFalse(store.close(id))
        store.documents[index].text = ""
        XCTAssertTrue(store.close(id), "An emptied untitled file closes without asking")
        XCTAssertTrue(store.documents.isEmpty)
    }

    func testSavePathsAreRelativeToTheSpaceRoot() {
        let root = "/work/project"
        func path(_ input: String) -> String? { try? WorkspaceDocumentStore.untitledSavePath(input, root: root).get() }
        XCTAssertEqual(path(" notes.md "), "notes.md")
        XCTAssertEqual(path("./docs/notes.md"), "docs/notes.md")
        XCTAssertEqual(path("/work/project/docs/notes.md"), "docs/notes.md", "An absolute path inside the root is accepted")
        XCTAssertNil(path(""))
        XCTAssertNil(path("docs/"))
        XCTAssertNil(path("../outside.txt"))
        XCTAssertNil(path("/elsewhere/notes.md"))
        XCTAssertNil(path("docs//notes.md"))
    }

    /// Saving writes a new file, creating its folders, and the tab becomes that file's tab.
    func testSavingAnUntitledFileCreatesItAndOpensItAsAFile() async throws {
        store.showSpace("one")
        let id = store.newUntitled(at: repo)
        let index = try XCTUnwrap(store.documents.firstIndex { $0.id == id })
        store.documents[index].text = "# Notes\n"

        let error = await store.saveUntitled(id, as: "docs/notes.md")
        XCTAssertNil(error)
        XCTAssertEqual(try sandbox.read("docs/notes.md", in: "repo"), "# Notes\n")
        XCTAssertEqual(store.documents.count, 1)
        let saved = store.documents[0]
        XCTAssertFalse(saved.isUntitled)
        XCTAssertEqual(saved.path, "docs/notes.md")
        XCTAssertEqual(saved.title, "notes.md")
        XCTAssertEqual(saved.space, "one")
        XCTAssertFalse(saved.isDirty)
        XCTAssertEqual(saved.version, WorkspaceFiles.gitBlobHash(Data("# Notes\n".utf8)))
        XCTAssertEqual(saved.markdownMode, .source, "The text being written stays in view")
        XCTAssertEqual(store.activeID, saved.id)

        // The saved file is an ordinary document from then on.
        store.documents[0].text = "# Notes\nmore\n"
        store.save(saved.id)
        await settle()
        XCTAssertEqual(try sandbox.read("docs/notes.md", in: "repo"), "# Notes\nmore\n")
    }

    func testSavingAnUntitledFileRefusesExistingFilesAndBadPaths() async throws {
        let id = store.newUntitled(at: repo)
        store.documents[0].text = "mine\n"
        let existing = await store.saveUntitled(id, as: "a.txt")
        XCTAssertNotNil(existing)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "one\n", "An existing file is not overwritten")
        let outside = await store.saveUntitled(id, as: "../escape.txt")
        XCTAssertNotNil(outside)
        XCTAssertTrue(store.documents[0].isUntitled, "A failed save keeps the untitled tab")
        XCTAssertFalse(store.documents[0].isSaving)
        XCTAssertEqual(store.documents[0].text, "mine\n")
    }

    // MARK: Reordering

    /// Tabs move to a gap of the shown Space's order, as Herdr's `tab.move` takes it; other
    /// Spaces' tabs keep their places.
    func testMovingTabsReordersOnlyTheShownSpace() async throws {
        store.showSpace("one")
        _ = await open("a.txt")
        _ = await open("b.txt")
        store.showSpace("two")
        _ = await open("c.txt")
        store.showSpace("one")
        _ = await open("c.txt")
        let ids = store.visibleDocuments.map(\.id)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["a.txt", "b.txt", "c.txt"])

        store.move(ids[0], to: 2)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["b.txt", "a.txt", "c.txt"], "A tab moved right goes before the gap's tab")
        store.move(ids[0], to: 3)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["b.txt", "c.txt", "a.txt"], "The last gap is after every tab")
        store.move(ids[2], to: 0)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["c.txt", "b.txt", "a.txt"])
        store.move(ids[2], to: 1)
        store.move(ids[2], to: 9)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["c.txt", "b.txt", "a.txt"], "No move in place or out of range")

        store.showSpace("two")
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["c.txt"])
        XCTAssertEqual(store.documents.filter { $0.space == "two" }.count, 1)
    }
}

import XCTest
@testable import xherdr

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
        XCTAssertNotNil(store.documents[0].error)
        XCTAssertTrue(store.documents[0].isDirty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "from elsewhere\n")
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
        store.reloadUnedited(["a.txt", "b.txt"], at: repo)
        // A reload keeps showing the old text rather than a spinner, so wait for the new one.
        for _ in 0..<500 where store.documents[0].text != "replaced\n" { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.documents.map(\.text), ["replaced\n", "unsaved\n"])
    }
}

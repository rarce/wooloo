import CodeEditSourceEditor
import XCTest
@testable import wooloo

@MainActor
final class WorkspaceSessionPersistenceTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var location: WorkspaceFileLocation!
    private var root: URL!
    private var disk: WorkspaceSessionPersistence!
    private let space = "test|repo"

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        location = try sandbox.repository("repo", files: ["a.txt": "original\n", "b.txt": "second\n"])
        root = URL(fileURLWithPath: sandbox.path("Application Support"))
        disk = WorkspaceSessionPersistence(root: root)
    }

    override func tearDown() async throws { sandbox.tearDown() }

    private func store(using persistence: WorkspaceSessionPersistence? = nil, delay: UInt64 = 60_000_000_000) async -> WorkspaceDocumentStore {
        let result = WorkspaceDocumentStore(persistence: persistence ?? disk, backupDelay: delay)
        result.showSpace(space)
        await result.waitForRestoration()
        await settle(result)
        return result
    }

    private func settle(_ store: WorkspaceDocumentStore) async {
        for _ in 0..<500 {
            if !store.documents.contains(where: { $0.isLoading || $0.isSaving }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Documents did not settle")
    }

    private func open(_ path: String, in store: WorkspaceDocumentStore, preview: Bool = false) async {
        store.open(.file, path: path, at: location, preview: preview)
        await settle(store)
    }

    private func sessionURL() -> URL {
        root.appendingPathComponent("Sessions/\(WorkspaceSessionPersistence.key(for: space))/session.json")
    }

    private func backupURL(_ id: UUID) -> URL {
        root.appendingPathComponent("Backups/\(WorkspaceSessionPersistence.key(for: space))/\(id.uuidString).json")
    }

    /// A new persistence actor represents a fresh process; the working file is untouched.
    func testRestartRestoresDirtyFilesDraftsOrderSelectionAndEditorPosition() async throws {
        let first = await store()
        await open("a.txt", in: first, preview: true)
        first.documents[0].text = "pending 😀\n"
        first.documents[0].cursorPositions = [.init(range: NSRange(location: 3, length: 2))]
        first.documents[0].scrollPosition = CGPoint(x: 12, y: 240)
        let draftID = first.newUntitled(at: location)
        first.documents[1].text = "draft\n"
        first.documents[1].markdownMode = .split
        first.move(draftID, to: 0)
        first.activeID = first.documents[1].id
        let expectedIDs = first.documents.map(\.backupID)
        try await first.flushPersistence()

        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents.map(\.backupID), expectedIDs)
        XCTAssertEqual(restarted.documents.map(\.text), ["draft\n", "pending 😀\n"])
        XCTAssertTrue(restarted.documents.allSatisfy(\.isDirty))
        XCTAssertEqual(restarted.activeID, restarted.documents[1].id)
        XCTAssertEqual(restarted.documents[1].savedText, "original\n")
        XCTAssertEqual(restarted.documents[1].cursorPositions[0].range, NSRange(location: 3, length: 2))
        XCTAssertEqual(restarted.documents[1].scrollPosition, CGPoint(x: 12, y: 240))
        XCTAssertFalse(restarted.documents[1].isPreview, "A dirty preview becomes a regular tab")
        XCTAssertEqual(restarted.documents[0].markdownMode, .split)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "original\n")
        let metadata = try JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: Data(contentsOf: sessionURL()))
        XCTAssertTrue(metadata.documents.allSatisfy { $0.text == nil && $0.savedText == nil })
    }

    func testCleanFilesReloadCurrentDiskContentsWithoutCreatingBackups() async throws {
        let first = await store()
        await open("a.txt", in: first)
        let id = first.documents[0].backupID
        first.documents[0].cursorPositions = [.init(range: NSRange(location: 8, length: 0))]
        try await first.flushPersistence()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(id).path))
        try sandbox.write(["a.txt": "new\n"], in: "repo")
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].text, "new\n")
        XCTAssertFalse(restarted.documents[0].isDirty)
        XCTAssertEqual(restarted.documents[0].cursorPositions[0].range.location, 4, "Stale positions are clamped")
    }

    func testRestoredDirtyFilesStillRefuseToOverwriteExternalChanges() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "mine\n"
        try await first.flushPersistence()
        try sandbox.write(["a.txt": "external\n"], in: "repo")
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].text, "mine\n")
        restarted.save(restarted.documents[0].id)
        await settle(restarted)
        XCTAssertNotNil(restarted.documents[0].error)
        XCTAssertTrue(restarted.documents[0].isDirty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "external\n")
    }

    func testDeletedFileAndOfflineSSHDoNotPreventDirtyBufferRecovery() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "recover me"
        let remote = WorkspaceFileLocation(machine: HerdrMachineProfile(id: "offline", label: "Offline",
            target: "invalid.example", session: "remote", enabled: true), session: "remote",
            workspaceID: "repo", workspaceLabel: "Remote", root: "/remote/project")
        first.newUntitled(at: remote)
        first.documents[1].text = "remote draft"
        try await first.flushPersistence()
        try FileManager.default.removeItem(atPath: location.absolutePath("a.txt"))
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents.map(\.text), ["recover me", "remote draft"])
        XCTAssertTrue(restarted.documents.allSatisfy { !$0.isLoading })
        XCTAssertEqual(restarted.documents[1].location.machine?.target, "invalid.example")
        XCTAssertEqual(restarted.documents[0].version, first.documents[0].version)
    }

    func testDiscardCommitsTombstoneAndDraftNumberReuseHasNewIdentity() async throws {
        let first = await store()
        let id = first.newUntitled(at: location)
        first.documents[0].text = "discard this"
        let backupID = first.documents[0].backupID
        let staleBackup = WorkspaceDocumentSnapshot(first.documents[0])
        try await first.flushPersistence()
        XCTAssertFalse(first.close(id), "An ordinary close still asks about unsaved work")
        XCTAssertTrue(first.close(id, force: true))
        first.newUntitled(at: location)
        XCTAssertEqual(first.documents[0].title, "Untitled-1")
        XCTAssertNotEqual(first.documents[0].backupID, backupID)
        try await first.flushPersistence()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(backupID).path))
        // Simulate a crash after the index commit but before obsolete-backup removal.
        try JSONEncoder().encode(staleBackup).write(to: backupURL(backupID), options: .atomic)
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents.count, 1)
        XCTAssertEqual(restarted.documents[0].text, "")
        XCTAssertEqual(restarted.documents[0].backupID, first.documents[0].backupID)
    }

    func testSaveAsKeepsBackupIdentityAndRemovesDraftContentAfterSuccessfulSave() async throws {
        let first = await store()
        let id = first.newUntitled(at: location)
        first.documents[0].text = "notes\n"
        let backupID = first.documents[0].backupID
        try await first.flushPersistence()
        let error = await first.saveUntitled(id, as: "notes.txt")
        XCTAssertNil(error)
        XCTAssertEqual(first.documents[0].backupID, backupID)
        try await first.flushPersistence()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(backupID).path))
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].path, "notes.txt")
        XCTAssertFalse(restarted.documents[0].isUntitled)
        XCTAssertFalse(restarted.documents[0].isDirty)
        XCTAssertEqual(restarted.documents[0].text, "notes\n")
    }

    func testSavingRestoredFileRemovesBackupButLaterEditsRemainBackedUp() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "saved\n"
        let id = first.documents[0].backupID
        try await first.flushPersistence()
        first.save(first.documents[0].id)
        await settle(first)
        try await first.flushPersistence()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(id).path))
        first.documents[0].text = "later\n"
        try await first.flushPersistence()
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].text, "later\n")
        XCTAssertEqual(restarted.documents[0].savedText, "saved\n")
        XCTAssertTrue(restarted.documents[0].isDirty)
    }

    func testEachSpaceRestoresItsOwnTabsAndActiveDocument() async throws {
        let first = await store()
        await open("a.txt", in: first)
        let selected = first.activeID
        first.showSpace("test|other")
        await first.waitForRestoration()
        first.newUntitled(at: location)
        first.documents[1].text = "other space"
        first.showSpace(space)
        XCTAssertEqual(first.activeID, selected)
        first.activeID = nil
        try await first.flushPersistence()
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.visibleDocuments.map(\.path), ["a.txt"])
        XCTAssertNil(restarted.activeID, "The terminal selection is remembered")
        restarted.showSpace("test|other")
        await restarted.waitForRestoration()
        XCTAssertEqual(restarted.visibleDocuments.map(\.text), ["other space"])
        XCTAssertEqual(restarted.activeID, restarted.visibleDocuments[0].id)
    }

    func testDebouncedBackupsDoNotRequireAnOrderlyQuit() async throws {
        let first = await store(delay: 10_000_000)
        first.newUntitled(at: location)
        first.documents[0].text = "initial"
        first.documents[0].text = "latest"
        let url = backupURL(first.documents[0].backupID)
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(WorkspaceDocumentSnapshot.self, from: data),
               snapshot.text == "latest" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let restored = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertEqual(restored.session.documents.map(\.text), ["latest"])
    }

    func testUnindexedDraftIsRecoveredAndCanBeDiscarded() async throws {
        let seed = WorkspaceDocumentStore(persistence: nil)
        seed.showSpace(space)
        seed.newUntitled(at: location)
        seed.documents[0].text = "orphan draft"
        let snapshot = WorkspaceDocumentSnapshot(seed.documents[0])
        let url = backupURL(snapshot.backupID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let recovered = await store()
        XCTAssertEqual(recovered.documents.map(\.text), ["orphan draft"])
        XCTAssertTrue(recovered.close(recovered.documents[0].id, force: true))
        try await recovered.flushPersistence()
        let restored = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertTrue(restored.session.documents.isEmpty)
    }

    func testCorruptIndexRecoversDraftAndPreservesOriginalIndex() async throws {
        let first = await store()
        first.newUntitled(at: location)
        first.documents[0].text = "recoverable"
        try await first.flushPersistence()
        try Data("broken index".utf8).write(to: sessionURL(), options: .atomic)
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents.map(\.text), ["recoverable"])
        XCTAssertNotNil(restarted.persistenceError)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessionURL().deletingLastPathComponent().path)
        XCTAssertTrue(files.contains { $0.hasPrefix("session-recovery-") })
        try await restarted.flushPersistence()
        let restored = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertEqual(restored.session.documents.map(\.text), ["recoverable"])
    }

    func testCorruptBackupIsReportedKeptAndNeverRestoredAsAnEmptyDraft() async throws {
        let first = await store()
        first.newUntitled(at: location)
        first.documents[0].text = "draft"
        let url = backupURL(first.documents[0].backupID)
        try await first.flushPersistence()
        let damaged = Data("broken backup".utf8)
        try damaged.write(to: url, options: .atomic)
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertTrue(restarted.documents.isEmpty)
        XCTAssertNotNil(restarted.persistenceError)
        try await restarted.flushPersistence()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testFutureSessionFormatIsNotOverwritten() async throws {
        let url = sessionURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"formatVersion\":999}".utf8)
        try original.write(to: url)
        let restarted = await store()
        XCTAssertNotNil(restarted.persistenceError)
        do {
            try await restarted.flushPersistence()
            XCTFail("An unsupported session must block writes")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTwoWindowsCannotRemoveEachOthersBuffers() async throws {
        let first = await store()
        first.newUntitled(at: location)
        first.documents[0].text = "first window"
        try await first.flushPersistence()
        let second = await store()
        XCTAssertTrue(second.documents.isEmpty, "Another live window owns those documents")
        second.newUntitled(at: location)
        second.documents[0].text = "second window"
        try await second.flushPersistence()
        try await first.flushPersistence()
        let restored = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertEqual(Set(restored.session.documents.compactMap(\.text)), ["first window", "second window"])
        XCTAssertTrue(first.close(first.documents[0].id, force: true))
        try await first.flushPersistence()
        let remaining = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertEqual(remaining.session.documents.map(\.text), ["second window"])
    }

    func testFileOpenedWhileRestoringUsesPendingBufferInsteadOfDisk() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "pending"
        try await first.flushPersistence()
        let restarted = WorkspaceDocumentStore(persistence: WorkspaceSessionPersistence(root: root))
        restarted.showSpace(space)
        restarted.open(.file, path: "a.txt", at: location)
        await restarted.waitForRestoration()
        await settle(restarted)
        XCTAssertEqual(restarted.documents.count, 1)
        XCTAssertEqual(restarted.documents[0].text, "pending")
        XCTAssertTrue(restarted.documents[0].isDirty)
    }

    func testNewerBackupWinsWhenCrashInterruptsIndexUpdateForExistingCleanFile() async throws {
        let first = await store()
        await open("a.txt", in: first)
        try await first.flushPersistence()
        let manifest = try JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: Data(contentsOf: sessionURL()))
        first.documents[0].text = "edited before crash"
        var newer = WorkspaceDocumentSnapshot(first.documents[0])
        newer.backupRevision = manifest.revision + 1
        try JSONEncoder().encode(newer).write(to: backupURL(newer.backupID), options: .atomic)
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].text, "edited before crash")
        XCTAssertTrue(restarted.documents[0].isDirty)
    }

    func testOldBackupCannotResurrectEditsWhenCrashInterruptsCleanupAfterSave() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "saved now"
        try await first.flushPersistence()
        let url = backupURL(first.documents[0].backupID)
        let oldBackup = try Data(contentsOf: url)
        first.save(first.documents[0].id)
        await settle(first)
        try await first.flushPersistence()
        try oldBackup.write(to: url, options: .atomic)
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(restarted.documents[0].text, "saved now")
        XCTAssertFalse(restarted.documents[0].isDirty)
    }

    func testIndependentWindowsEditingSameFileRecoverBothVersions() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "first edit"
        try await first.flushPersistence()
        let second = await store()
        await open("a.txt", in: second)
        second.documents[0].text = "second edit"
        try await second.flushPersistence()
        let restarted = await store(using: WorkspaceSessionPersistence(root: root))
        XCTAssertEqual(Set(restarted.documents.map(\.text)), ["first edit", "second edit"])
        XCTAssertEqual(restarted.documents.filter(\.isUntitled).count, 1)
        XCTAssertTrue(restarted.documents.allSatisfy(\.isDirty))
        XCTAssertNotNil(restarted.persistenceError, "Explain that the second version is recovered as a draft")
    }

    func testPersistenceFailureIsPropagatedWithoutChangingTheWorkingFile() async throws {
        let first = await store()
        await open("a.txt", in: first)
        first.documents[0].text = "keep this"
        // Make the storage root unusable, simulating an I/O failure at shutdown.
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root)
        do {
            try await first.flushPersistence()
            XCTFail("A failed backup must prevent reporting a successful flush")
        } catch { }
        XCTAssertEqual(first.documents[0].text, "keep this")
        XCTAssertTrue(first.documents[0].isDirty)
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "original\n")
    }

    func testWindowCloseWaitsForBackupAndForwardsTheOriginalDelegate() async throws {
        let source = await store()
        source.newUntitled(at: location)
        source.documents[0].text = "draft before close"
        let url = backupURL(source.documents[0].backupID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let original = SessionTestWindowDelegate()
        window.delegate = original
        let guardDelegate = WorkspaceSessionWindowDelegate(store: source)
        guardDelegate.install(on: window)
        XCTAssertTrue(window.delegate === guardDelegate)
        XCTAssertFalse(guardDelegate.windowShouldClose(window), "The initial close is delayed until disk writes finish")
        for _ in 0..<500 {
            if original.closes == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(original.closeChecks, 1)
        XCTAssertEqual(original.closes, 1, "Other NSWindowDelegate callbacks still reach SwiftUI's original delegate")
        let backup = try JSONDecoder().decode(WorkspaceDocumentSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(backup.text, "draft before close")
        guardDelegate.uninstall()
    }

    func testFlushIncludesEditsMadeWhileAnOlderSnapshotWaitsForDisk() async throws {
        let source = await store()
        source.newUntitled(at: location)
        source.documents[0].text = "before disk wait"
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let persistence = try XCTUnwrap(disk)
        let blocker = Task.detached { await persistence.holdForTest(entered: entered, release: release) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let flush = Task { try await source.flushPersistence() }
        try await Task.sleep(nanoseconds: 20_000_000)
        source.documents[0].text = "edited during disk wait"
        release.signal()
        await blocker.value
        try await flush.value
        let restored = try await WorkspaceSessionPersistence(root: root).restore(space)
        XCTAssertEqual(restored.session.documents.map(\.text), ["edited during disk wait"])
    }
}

private extension WorkspaceSessionPersistence {
    func holdForTest(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }
}

@MainActor
private final class SessionTestWindowDelegate: NSObject, NSWindowDelegate {
    var closeChecks = 0
    var closes = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool { closeChecks += 1; return true }
    func windowWillClose(_ notification: Notification) { closes += 1 }
}

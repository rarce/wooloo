import AppKit
import CodeEditSourceEditor
import CryptoKit
import Foundation
import SwiftUI

/// Session metadata contains no file contents. Only dirty buffers and untitled documents
/// have backups, and each backup carries enough metadata to recover without a session index.
struct WorkspaceDocumentSnapshot: Codable {
    var backupRevision: UInt64 = 0
    var backupID: UUID
    var space: String?
    var location: WorkspaceFileLocation
    var path: String
    var kind: WorkspaceDocumentKind
    var commit: String?
    var originalPath: String?
    var untitledNumber: Int?
    var isPreview: Bool
    var markdownMode: String
    var diffScope: String
    var cursorPositions: [CursorPosition]
    var scrollPosition: CGPoint
    var hasBackup: Bool
    var text: String?
    var savedText: String?
    var version: String?

    @MainActor
    init(_ document: WorkspaceDocument) {
        backupID = document.backupID
        space = document.space
        location = document.location
        path = document.path
        kind = document.kind
        commit = document.commit
        originalPath = document.originalPath
        untitledNumber = document.untitledNumber
        isPreview = document.isPreview && !document.isDirty
        markdownMode = document.markdownMode.rawValue
        diffScope = document.diffScope.rawValue
        cursorPositions = document.cursorPositions
        scrollPosition = document.scrollPosition
        hasBackup = document.isDirty || document.isUntitled
        text = hasBackup ? document.text : nil
        savedText = hasBackup ? document.savedText : nil
        version = hasBackup ? document.version : nil
    }

    var descriptor: Self {
        var result = self
        result.text = nil
        result.savedText = nil
        return result
    }

    @MainActor
    func document() throws -> WorkspaceDocument {
        guard location.root.hasPrefix("/"), !location.root.contains("\0") else {
            throw WorkspaceFileError.message("Invalid session root")
        }
        if let number = untitledNumber {
            guard number > 0, path.isEmpty, kind == .file else {
                throw WorkspaceFileError.message("Invalid draft in session")
            }
        } else {
            try WorkspaceFiles.validateRelativePath(path)
        }
        guard !hasBackup || (text != nil && savedText != nil) else {
            throw WorkspaceFileError.message("The backup for \(path.isEmpty ? "a draft" : path) could not be read")
        }
        var result = WorkspaceDocument(space: space, location: location, path: path, kind: kind)
        result.backupID = backupID
        result.commit = commit
        result.originalPath = originalPath
        result.untitledNumber = untitledNumber
        result.isPreview = isPreview
        result.markdownMode = MarkdownDisplayMode(rawValue: markdownMode) ?? .source
        result.diffScope = WorkspaceDiffScope(rawValue: diffScope) ?? .all
        result.text = text ?? ""
        result.savedText = savedText ?? ""
        result.version = version
        result.isLoading = !hasBackup
        let length = (result.text as NSString).length
        result.cursorPositions = cursorPositions.map { position in
            // Clean files have not loaded yet; clamp their positions after reading the file.
            guard hasBackup, position.range.location != NSNotFound else { return position }
            let start = min(max(position.range.location, 0), length)
            return CursorPosition(range: NSRange(location: start, length: min(max(position.range.length, 0), length - start)))
        }
        if result.cursorPositions.isEmpty { result.cursorPositions = [CursorPosition(line: 1, column: 1)] }
        if scrollPosition.x.isFinite && scrollPosition.y.isFinite {
            result.scrollPosition = CGPoint(x: max(0, scrollPosition.x), y: max(0, scrollPosition.y))
        }
        return result
    }
}

struct WorkspaceSessionSnapshot: Codable {
    var formatVersion = 1
    var revision: UInt64 = 0
    var space: String?
    var activeDocument: UUID?
    var documents: [WorkspaceDocumentSnapshot]
    /// Committed before removing backups so a crash during discard cannot resurrect them.
    var discardedBackups: Set<UUID> = []
}

private enum WorkspaceSessionError: LocalizedError {
    case unsupported(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let url): return "Unsupported editor session at \(url.path). It has been left unchanged."
        }
    }
}

/// All disk access runs on this actor. Writes are ordered, each file is replaced atomically,
/// and the session index is committed only after all of its dirty buffers are backed up.
actor WorkspaceSessionPersistence {
    static let shared: WorkspaceSessionPersistence = {
        // A separate location lets interactive checks avoid the user's real editor sessions.
        let override = ProcessInfo.processInfo.environment["XHERDR_SESSION_STORAGE_ROOT"]
        let root = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("xherdr", isDirectory: true)
        return WorkspaceSessionPersistence(root: root)
    }()

    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Multiple app windows can visit the same Space. Each writes only the documents it
    /// restored or opened; one window's empty tab list must not delete another's backups.
    private var owners: [String: [UUID: Set<UUID>]] = [:]
    private var revisions: [String: UInt64] = [:]

    init(root: URL) { self.root = root }

    nonisolated static func key(for space: String?) -> String {
        let value = space.map { "space:\($0)" } ?? "unassigned"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func sessionURL(_ space: String?) -> URL {
        root.appendingPathComponent("Sessions/\(Self.key(for: space))/session.json")
    }

    private func backupsURL(_ space: String?) -> URL {
        root.appendingPathComponent("Backups/\(Self.key(for: space))", isDirectory: true)
    }

    private func readSession(_ space: String?) throws -> WorkspaceSessionSnapshot? {
        let url = sessionURL(space)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let formatVersion: Int }
        guard try decoder.decode(Header.self, from: data).formatVersion == 1 else {
            throw WorkspaceSessionError.unsupported(url)
        }
        let result = try decoder.decode(WorkspaceSessionSnapshot.self, from: data)
        guard result.space == space else { throw WorkspaceSessionError.unsupported(url) }
        return result
    }

    /// A corrupt index can be rebuilt from self-contained backups. Corrupt backups remain on
    /// disk and are reported; they are never treated as empty drafts or silently deleted.
    func restore(_ space: String?, owner: UUID? = nil) throws -> (session: WorkspaceSessionSnapshot, warnings: [String]) {
        var warnings: [String] = []
        var session = WorkspaceSessionSnapshot(space: space, documents: [])
        do {
            if let stored = try readSession(space) { session = stored }
        } catch let error as WorkspaceSessionError {
            throw error
        } catch {
            // Preserve the broken index before a future successful snapshot replaces it.
            let original = sessionURL(space)
            let copy = original.deletingLastPathComponent().appendingPathComponent("session-recovery-\(UUID()).json")
            try FileManager.default.moveItem(at: original, to: copy)
            warnings.append("Could not read editor session. The original is preserved at \(copy.path).")
        }
        var backups: [UUID: WorkspaceDocumentSnapshot] = [:]
        let directory = backupsURL(space)
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !session.discardedBackups.contains(id) else { continue }
                do {
                    let backup = try decoder.decode(WorkspaceDocumentSnapshot.self, from: Data(contentsOf: url))
                    guard backup.backupID == id, backup.space == space, backup.hasBackup,
                          backup.text != nil, backup.savedText != nil else {
                        throw WorkspaceFileError.message("Invalid backup")
                    }
                    backups[id] = backup
                } catch {
                    warnings.append("Could not read backup at \(url.path). It has been kept for recovery.")
                }
            }
        }
        let indexed = Set(session.documents.map(\.backupID))
        revisions[Self.key(for: space)] = max(session.revision, backups.values.map(\.backupRevision).max() ?? 0)
        session.documents = session.documents.compactMap { descriptor in
            guard descriptor.space == space else { return nil }
            // A backup newer than the index means the process ended between the buffer write
            // and the index commit. Conversely, an older backup of a now-clean file must not
            // resurrect edits after a save interrupted only the backup cleanup.
            if let backup = backups[descriptor.backupID], backup.backupRevision > descriptor.backupRevision {
                return backup
            }
            if !descriptor.hasBackup { return descriptor }
            guard let backup = backups[descriptor.backupID], backup.backupRevision == descriptor.backupRevision else {
                warnings.append("Missing or unreadable backup for \(descriptor.path.isEmpty ? "a draft" : descriptor.path).")
                return nil
            }
            return backup
        }
        // Includes a new draft backed up just before a crash interrupted the index write.
        session.documents += backups.values.filter { !indexed.contains($0.backupID) }
            .sorted { $0.backupID.uuidString < $1.backupID.uuidString }
        if let owner {
            let key = Self.key(for: space)
            let claimed = owners[key, default: [:]].filter { $0.key != owner }
                .values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
            session.documents.removeAll { claimed.contains($0.backupID) }
            owners[key, default: [:]][owner] = Set(session.documents.map(\.backupID))
        }
        return (session, warnings)
    }

    func save(_ snapshot: WorkspaceSessionSnapshot, owner: UUID? = nil) throws {
        let manager = FileManager.default
        let indexURL = sessionURL(snapshot.space)
        let directory = backupsURL(snapshot.space)
        for folder in [root, root.appendingPathComponent("Sessions"), root.appendingPathComponent("Backups"),
                       indexURL.deletingLastPathComponent(), directory] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        var manifest = snapshot
        let previous = try readSession(snapshot.space)
        let key = Self.key(for: snapshot.space)
        let revision = max(previous?.revision ?? 0, revisions[key] ?? 0) + 1
        revisions[key] = revision
        manifest.revision = revision
        let incoming = snapshot.documents.map { document in
            var result = document
            result.backupRevision = revision
            return result
        }
        let previouslyOwned = owner.flatMap { owners[key]?[$0] } ?? Set(previous?.documents.map(\.backupID) ?? [])
        let currentIDs = Set(snapshot.documents.map(\.backupID))
        if owner != nil {
            manifest.documents = (previous?.documents.filter {
                !previouslyOwned.contains($0.backupID) && !currentIDs.contains($0.backupID)
            } ?? []) + incoming
        } else {
            manifest.documents = incoming
        }
        let remainingDiscards = (previous?.discardedBackups ?? []).filter {
            manager.fileExists(atPath: directory.appendingPathComponent("\($0.uuidString).json").path)
        }
        manifest.discardedBackups = snapshot.discardedBackups.union(remainingDiscards).union(
            previouslyOwned.subtracting(currentIDs)
        )
        for document in incoming where document.hasBackup {
            let url = directory.appendingPathComponent("\(document.backupID.uuidString).json")
            try encoder.encode(document).write(to: url, options: .atomic)
        }
        manifest.documents = manifest.documents.map(\.descriptor)
        try encoder.encode(manifest).write(to: indexURL, options: .atomic)
        if let owner { owners[key, default: [:]][owner] = currentIDs }
        // Only remove known, committed obsolete backups. An unindexed or corrupt backup is
        // left alone until restoration has recovered it or reported it to the user.
        let obsolete = manifest.discardedBackups.union(Set(snapshot.documents.filter { !$0.hasBackup }.map(\.backupID)))
        for id in obsolete {
            let url = directory.appendingPathComponent("\(id.uuidString).json")
            if manager.fileExists(atPath: url.path) {
                // Malformed backups were reported as kept during restoration.
                guard let backup = try? decoder.decode(WorkspaceDocumentSnapshot.self, from: Data(contentsOf: url)),
                      backup.backupID == id else { continue }
                // The index already records this save/discard. Cleanup can be retried on
                // the next snapshot; a redundant old backup must not block window close.
                try? manager.removeItem(at: url)
            }
        }
    }

    func release(_ owner: UUID) {
        for key in Array(owners.keys) { owners[key]?.removeValue(forKey: owner) }
    }
}

/// Window stores register weakly; the quit delegate waits for their latest snapshots rather
/// than relying on a willTerminate notification, which cannot await asynchronous writes.
@MainActor
final class WorkspaceSessionRegistry {
    static let shared = WorkspaceSessionRegistry()
    private let stores = NSHashTable<WorkspaceDocumentStore>.weakObjects()

    func register(_ store: WorkspaceDocumentStore) { stores.add(store) }

    func flush() async throws {
        for store in stores.allObjects { try await store.flushPersistence() }
    }
}

@MainActor
final class XherdrAppDelegate: NSObject, NSApplicationDelegate {
    private var isFlushing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !XherdrApp.isHostingTests, RemoteAccessModel.shared.startsAtLaunch { RemoteAccessModel.shared.start() }
    }

    /// The tunnel belongs to xherdr; cloudflared would otherwise keep publishing SSH after quitting.
    func applicationWillTerminate(_ notification: Notification) {
        RemoteAccessModel.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if XherdrApp.isHostingTests { return .terminateNow }
        guard !isFlushing else { return .terminateLater }
        isFlushing = true
        Task {
            do {
                try await WorkspaceSessionRegistry.shared.flush()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not back up unsaved documents"
                alert.informativeText = "\(error.localizedDescription)\n\nKeep xherdr open to save your documents or retry quitting."
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Anyway")
                let quit = alert.runModal() == .alertSecondButtonReturn
                isFlushing = false
                sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }
}

/// SwiftUI owns the window's existing delegate. Forward its other callbacks while delaying
/// a user-initiated window close until the same backup check used by application quit finishes.
struct WorkspaceSessionWindowGuard: NSViewRepresentable {
    let store: WorkspaceDocumentStore

    func makeCoordinator() -> WorkspaceSessionWindowDelegate { WorkspaceSessionWindowDelegate(store: store) }

    func makeNSView(context: Context) -> SessionWindowView {
        let view = SessionWindowView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            DispatchQueue.main.async { [weak window] in
                if let window { coordinator?.install(on: window) }
            }
        }
        return view
    }

    func updateNSView(_ view: SessionWindowView, context: Context) { }

    static func dismantleNSView(_ view: SessionWindowView, coordinator: WorkspaceSessionWindowDelegate) {
        coordinator.uninstall()
    }
}

final class SessionWindowView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

@MainActor
final class WorkspaceSessionWindowDelegate: NSObject, NSWindowDelegate {
    private let store: WorkspaceDocumentStore
    private weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private var isFlushing = false

    init(store: WorkspaceDocumentStore) { self.store = store }

    func install(on window: NSWindow) {
        guard store.backsUpSessions, self.window !== window else { return }
        uninstall()
        self.window = window
        original = window.delegate
        window.delegate = self
    }

    func uninstall() {
        if window?.delegate === self { window?.delegate = original }
        window = nil
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isFlushing, original?.windowShouldClose?(sender) != false else { return false }
        isFlushing = true
        Task {
            do {
                try await store.flushPersistence()
                sender.close()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not back up unsaved documents"
                alert.informativeText = "\(error.localizedDescription)\n\nKeep this window open to save your documents or retry closing it."
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Close Anyway")
                alert.beginSheetModal(for: sender) { response in
                    self.isFlushing = false
                    if response == .alertSecondButtonReturn { sender.close() }
                }
            }
        }
        return false
    }
}

/// Keeps the viewport with the document, independently of the editor view's lifetime.
final class EditorSessionCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?
    private var observer: NSObjectProtocol?
    private var restoration: CGPoint?
    var onScroll: ((CGPoint) -> Void)?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    func restore(_ position: CGPoint?, onScroll: @escaping (CGPoint) -> Void) {
        restoration = position
        self.onScroll = onScroll
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard let scrollView = controller?.textView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        if let position = restoration {
            restoration = nil
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: position, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        guard observer == nil else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self, weak clip] _ in
                if let position = clip?.bounds.origin { self?.onScroll?(position) }
            }
    }

    func destroy() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        controller = nil
        onScroll = nil
    }
}

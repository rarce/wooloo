import AppKit
import Combine
import Darwin
import Foundation

private struct SnapshotResponse: Decodable {
    let result: SnapshotResult
}

private struct SnapshotResult: Decodable {
    let snapshot: HerdrSnapshot
}

private struct PaneGetResponse: Decodable {
    struct Result: Decodable { let pane: HerdrPane }
    let result: Result
}

private struct PaneReadResponse: Decodable {
    let result: PaneReadResult
}

private struct PaneReadResult: Decodable {
    let read: PaneRead
}

private struct PaneRead: Decodable {
    let text: String
}

enum HerdrSocketError: LocalizedError {
    case message(String)
    /// No server listens on the socket: it is missing, or left behind by a server that exited.
    case notRunning(path: String, reason: String)
    /// The server answered with an error carrying a code, such as `linked_worktree_source`.
    case refused(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .message(let text), .refused(_, let text): return text
        case .notRunning(let path, let reason): return "Cannot connect to \(path): \(reason)"
        }
    }
}

enum HerdrSocket {
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func open(path: String, nonBlocking: Bool = false) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrSocketError.message(String(cString: strerror(errno))) }
        var noSignal: Int32 = 1
        withUnsafePointer(to: &noSignal) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        if nonBlocking, fcntl(fd, F_SETFL, O_NONBLOCK) == -1 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw HerdrSocketError.message("Herdr socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectionResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addressLength)
            }
        }
        guard connectionResult == 0 || (nonBlocking && errno == EINPROGRESS) else {
            let code = errno
            let message = String(cString: strerror(code))
            close(fd)
            if code == ENOENT || code == ECONNREFUSED {
                throw HerdrSocketError.notRunning(path: path, reason: message)
            }
            throw HerdrSocketError.message("Cannot connect to \(path): \(message)")
        }
        return fd
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func send(fd: Int32, method: String, params: [String: Any] = [:]) throws {
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        var requestData = try JSONSerialization.data(withJSONObject: payload)
        requestData.append(0x0A)
        try requestData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { throw HerdrSocketError.message("Failed to write to Herdr socket") }
                sent += count
            }
        }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func request(path: String, method: String, params: [String: Any] = [:]) throws -> Data {
        let fd = try open(path: path)
        defer { close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        try send(fd: fd, method: method, params: params)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 8_000_000 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw HerdrSocketError.message("Herdr socket closed or timed out") }
            response.append(contentsOf: buffer.prefix(count))
            if let newline = response.firstIndex(of: 0x0A) {
                let line = Data(response[..<newline])
                if let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Herdr request failed"
                    if let code = error["code"] as? String { throw HerdrSocketError.refused(code: code, message: message) }
                    throw HerdrSocketError.message(message)
                }
                return line
            }
        }
        throw HerdrSocketError.message("Herdr response exceeded size limit")
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func snapshot(path: String) throws -> HerdrSnapshot {
        let data = try request(path: path, method: "session.snapshot")
        return try JSONDecoder().decode(SnapshotResponse.self, from: data).result.snapshot
    }

    /// A pane's directory now: the snapshot's can be older, since a `cd` alone emits no event.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func paneDirectory(path: String, paneID: String) throws -> String? {
        let data = try request(path: path, method: "pane.get", params: ["pane_id": paneID])
        return try JSONDecoder().decode(PaneGetResponse.self, from: data).result.pane.cwd
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func paneText(path: String, paneID: String) throws -> String {
        let data = try request(path: path, method: "pane.read", params: [
            "pane_id": paneID,
            "source": "visible",
            "lines": 120
        ])
        return try JSONDecoder().decode(PaneReadResponse.self, from: data).result.read.text
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func sendInput(path: String, paneID: String, text: String? = nil, keys: [String] = []) throws {
        var params: [String: Any] = ["pane_id": paneID]
        if let text { params["text"] = text }
        if !keys.isEmpty { params["keys"] = keys }
        _ = try request(path: path, method: "pane.send_input", params: params)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func createWorkspace(path: String, sourceWorkspaceID: String?,
                                cwd: String? = nil, label: String? = nil) throws -> String {
        var params: [String: Any] = ["focus": true]
        if let sourceWorkspaceID { params["source_workspace_id"] = sourceWorkspaceID }
        if let cwd { params["cwd"] = cwd }
        if let label { params["label"] = label }
        let data = try request(path: path, method: "workspace.create", params: params)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let workspace = result["workspace"] as? [String: Any],
              let id = workspace["workspace_id"] as? String else {
            throw HerdrSocketError.message("Herdr did not return the new space")
        }
        return id
    }

    /// Opens the Space of a Git worktree checkout: the one already open there, or a new one.
    /// `repository` is the repository's main checkout, from which Herdr opens its worktrees.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func openWorktree(path: String, checkout: String, repository: String) throws -> String {
        let params: [String: Any] = ["cwd": repository, "path": checkout, "focus": true]
        let data = try request(path: path, method: "worktree.open", params: params)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let workspace = result["workspace"] as? [String: Any],
              let id = workspace["workspace_id"] as? String else {
            throw HerdrSocketError.message("Herdr did not return the worktree's space")
        }
        return id
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func createTab(path: String, workspaceID: String, cwd: String? = nil) throws -> String {
        var params: [String: Any] = ["workspace_id": workspaceID, "focus": true]
        if let cwd { params["cwd"] = cwd }
        let data = try request(path: path, method: "tab.create", params: params)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tab = result["tab"] as? [String: Any],
              let id = tab["tab_id"] as? String else {
            throw HerdrSocketError.message("Herdr did not return the new tab")
        }
        return id
    }
}

final class HerdrEventStream {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    private static let eventTypes = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated",
        "workspace.renamed", "workspace.moved", "workspace.reordered", "workspace.closed",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited",
        "pane.agent_detected", "layout.updated"
    ]

    func cancel() {
        lock.lock()
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    func run(path: String, onSnapshot: (HerdrSnapshot) -> Void) throws {
        let beforeSubscription = try HerdrSocket.snapshot(path: path)
        let subscribedPaneIDs = Set(beforeSubscription.panes.map(\.paneID))
        let connectedFD = try HerdrSocket.open(path: path)
        lock.lock()
        fd = connectedFD
        let wasCancelled = cancelled
        lock.unlock()
        defer {
            close(connectedFD)
            lock.lock()
            fd = -1
            lock.unlock()
        }
        if wasCancelled { return }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(connectedFD, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        let subscriptions = Self.eventTypes.map { ["type": $0] }
            + subscribedPaneIDs.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        try HerdrSocket.send(fd: connectedFD, method: "events.subscribe", params: [
            "subscriptions": subscriptions
        ])
        guard let acknowledgement = try readLine(from: connectedFD),
              let response = try JSONSerialization.jsonObject(with: acknowledgement) as? [String: Any],
              let result = response["result"] as? [String: Any],
              result["type"] as? String == "subscription_started" else {
            throw HerdrSocketError.message("Herdr event subscription was rejected")
        }

        // The subscription is active before the initial snapshot, so events that
        // arrive during the snapshot remain queued on this connection.
        let initialSnapshot = try HerdrSocket.snapshot(path: path)
        onSnapshot(initialSnapshot)
        if Set(initialSnapshot.panes.map(\.paneID)) != subscribedPaneIDs { return }
        while !isCancelled {
            guard let line = try readLine(from: connectedFD) else { continue }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["event"] is String else { continue }
            let updated = try HerdrSocket.snapshot(path: path)
            onSnapshot(updated)
            if Set(updated.panes.map(\.paneID)) != subscribedPaneIDs { return }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func readLine(from fd: Int32) throws -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while !isCancelled {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return line }
                line.append(byte)
                if line.count > 1_000_000 {
                    throw HerdrSocketError.message("Herdr event exceeded size limit")
                }
            } else if count == 0 {
                throw HerdrSocketError.message("Herdr event stream closed")
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                if isCancelled { return nil }
                throw HerdrSocketError.message("Herdr event stream failed: \(String(cString: strerror(errno)))")
            }
        }
        return nil
    }
}

struct HerdrSurfaceLayout: Equatable {
    let bootID: String
    let paneIDs: [String]
    var popupTerminalID: String? = nil
}

/// Hands the newest surface from the stream thread to the main thread.
final class HerdrSurfaceMailbox {
    private let lock = NSLock()
    private var pending: HerdrSurface?

    /// Keeps `surface` as the newest one; returns true when the main thread must be woken.
    func put(_ surface: HerdrSurface) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wake = pending == nil
        pending = surface
        return wake
    }

    func take() -> HerdrSurface? {
        lock.lock()
        defer { lock.unlock() }
        let surface = pending
        pending = nil
        return surface
    }
}

/// Delivers each live surface to the terminal view that observes it, outside SwiftUI.
@MainActor
final class HerdrSurfaceFeed {
    private(set) var surface: HerdrSurface?
    private weak var observer: AnyObject?
    private var handler: ((HerdrSurface?, Bool) -> Void)?
    /// When typed input was last sent, until a surface answers it.
    private var answerExpectedAt: ContinuousClock.Instant?
    /// How long after typed input a surface still counts as its answer; a key that changes
    /// nothing on screen must not make a later, unrelated surface draw at once.
    static var answerWindow: Duration = .milliseconds(100)

    /// Makes `owner` the only observer, for as long as it lives. The handler also learns
    /// whether the surface answers the user, so the view can draw it at once.
    func observe(_ owner: AnyObject, _ handler: @escaping (HerdrSurface?, _ answersUser: Bool) -> Void) {
        observer = owner
        self.handler = handler
    }

    /// Marks the next surface as the answer to typed input just sent.
    func expectAnswer() { answerExpectedAt = .now }

    /// Whether the current surface answers typed input sent within `answerWindow`; asking
    /// consumes the answer. The view asks when it attaches, since no handler saw the surface.
    func takeAnswer() -> Bool {
        defer { answerExpectedAt = nil }
        guard let answerExpectedAt else { return false }
        return ContinuousClock.now - answerExpectedAt <= Self.answerWindow
    }

    /// `answersUser` marks a surface that answers the user however it came, such as a tab
    /// switched to. Without an observer the answer to typed input is kept for the next one.
    func publish(_ surface: HerdrSurface?, answersUser answers: Bool = false) {
        self.surface = surface
        // A lost connection answers nothing.
        if surface == nil { answerExpectedAt = nil }
        if observer == nil { handler = nil }
        guard let handler else { return }
        handler(surface, surface != nil && (takeAnswer() || answers))
    }
}

@MainActor
final class HerdrStore: ObservableObject {
    /// Herdr's state. Every assignment publishes, as `@Published` would, except the event
    /// stream's layout-only changes while the live surface shows the tab (see `receive`).
    private(set) var snapshot: HerdrSnapshot? {
        get { snapshotValue }
        set {
            objectWillChange.send()
            snapshotValue = newValue
            sessionCache = nil
            if let newValue { cachedSnapshot = newValue }
            publishedSnapshots.send(newValue)
        }
    }
    /// `snapshot` in the backend-neutral model (docs/proposals/herdr-core-backend.md), mapped
    /// at most once per snapshot and context: a new snapshot, session name or machine clears
    /// it. It publishes with `snapshot`. Read on hot paths, so a cached read does no work.
    var session: WoolooSession? {
        guard let snapshotValue else { return nil }
        if let sessionCache { return sessionCache }
        let mapped = snapshotValue.session(backend: backendID, capabilities: backendCapabilities)
        sessionCache = mapped
        return mapped
    }
    private var sessionCache: WoolooSession?
    /// The current session, or the last known one while disconnected (`cachedSnapshot`).
    var displaySession: WoolooSession? {
        if let session { return session }
        guard let cachedSnapshot else { return nil }
        if let cachedSessionCache { return cachedSessionCache }
        let mapped = cachedSnapshot.session(backend: backendID, capabilities: backendCapabilities)
        cachedSessionCache = mapped
        return mapped
    }
    private var cachedSessionCache: WoolooSession?
    /// Which server this store talks to: the Herdr TUI, or herdr-core behind the
    /// `HerdrCoreSupport` setting (docs/proposals/herdr-core-backend.md, Phase 3).
    @Published private(set) var backendKind: BackendKind = .tui {
        didSet { sessionCache = nil; cachedSessionCache = nil }
    }
    private var coreBackend: CoreSessionBackend?
    private var backendID: BackendID { BackendID(kind: backendKind, context: baseContextID) }
    private var backendCapabilities: BackendCapabilities {
        backendKind == .core ? CoreSessionBackend.capabilities : .herdrTUI
    }
    private(set) var cachedSnapshot: HerdrSnapshot? { didSet { cachedSessionCache = nil } }
    private var snapshotValue: HerdrSnapshot?
    private let publishedSnapshots = CurrentValueSubject<HerdrSnapshot?, Never>(nil)
    /// Each published snapshot, starting with the current one, like `@Published`'s publisher.
    /// Made once: SwiftUI's `onReceive` subscribes again to a publisher that is not the same,
    /// and this one replays its current value to every subscriber.
    let snapshotPublisher: AnyPublisher<HerdrSnapshot?, Never>
    @Published private(set) var paneText: [String: String] = [:]
    /// The live surface goes straight to the terminal view: publishing every frame would make
    /// SwiftUI update the whole window at Herdr's frame rate.
    let surfaceFeed = HerdrSurfaceFeed()
    /// What the window needs to know about the live surface; it changes only with its panes.
    /// Every assignment publishes, except when the first surface of a tab switched to arrives
    /// (see `setSurface`).
    private(set) var surfaceLayout: HerdrSurfaceLayout? {
        get { surfaceLayoutValue }
        set {
            objectWillChange.send()
            surfaceLayoutValue = newValue
        }
    }
    private var surfaceLayoutValue: HerdrSurfaceLayout?
    var surface: HerdrSurface? { surfaceFeed.surface }
    @Published private(set) var surfaceError: String?
    @Published private(set) var errorMessage: String?
    /// The last connection attempt found no server for the session, so it can be started.
    @Published private(set) var isServerStopped = false
    @Published private(set) var inputError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var sessionSelectionError: String?
    @Published private(set) var workspaceGitStatuses: [String: HerdrGitStatus] = [:]
    @Published private(set) var agentViewState: HerdrAgentViewState?
    @Published private var agentPrioritySort = false
    private var agentPresentation = HerdrAgentPresentation()
    @Published var selectedWorkspaceID: String? {
        didSet { if !repairingSelection, oldValue != selectedWorkspaceID { selectionRevision &+= 1 } }
    }
    private var selectionRevision: UInt64 = 0
    private var repairingSelection = false
    @Published private(set) var spaceMoveInFlight = false
    /// Publishes as `@Published` would, except while a tab switch waits for its first surface
    /// (see `select(tabID:)`).
    var selectedTabID: String? {
        get { selectedTabValue }
        set {
            selectionWillChange()
            let changed = selectedTabValue != newValue
            if !repairingSelection, changed { selectionRevision &+= 1 }
            selectedTabValue = newValue
            // Herdr's server shows its own active tab, but a herdr-core presentation shows only
            // the tab it is told, whoever chooses it: the user, a repaired selection or a move.
            if changed, let newValue { surfaceStream?.reconcileSelection(tabID: newValue, paneID: preferredPane(in: newValue)) }
        }
    }
    private var selectedTabValue: String?
    var selectedPaneID: String? {
        get { selectedPaneValue }
        set {
            selectionWillChange()
            if !repairingSelection, selectedPaneValue != newValue { selectionRevision &+= 1 }
            selectedPaneValue = newValue
            guard let selectedTabID, let selectedPaneID,
                  snapshot?.panes.contains(where: { $0.paneID == selectedPaneID && $0.tabID == selectedTabID }) == true
            else { return }
            surfaceStream?.reconcileSelection(tabID: selectedTabID, paneID: selectedPaneID)
            lastPaneByTab[selectedTabID] = selectedPaneID
            markShownTurnSeen()
        }
    }

    /// herdr-core keeps whether a finished turn was seen in the terminal's `herdr.seen` label,
    /// which every client reads. As labels.md asks, a turn counts as seen only when the agent
    /// is in front of someone: the window's terminal focused and the pane drawn, not hidden.
    private var seenRequests: Set<String> = []
    private var unreadHold: String?
    private func markShownTurnSeen() {
        if let unreadHold, unreadHold != selectedPaneID { self.unreadHold = nil }
        guard backendKind == .core, terminalFocused == true, let coreBackend, let paneID = selectedPaneID, paneID != unreadHold,
              let rect = surface?.paneRects[paneID], rect.width > 0, rect.height > 0,
              snapshotValue?.agents.contains(where: { $0.paneID == paneID && $0.agentStatus == "done" }) == true,
              seenRequests.insert(paneID).inserted else { return }
        let reaching = BlockingWorkMachine(machine)
        Task { [weak self] in
            _ = try? await BlockingWork.run(priority: .utility, reaching: reaching) { try coreBackend.markSeen(paneID) }
            self?.seenRequests.remove(paneID)
        }
    }
    private var selectedPaneValue: String?
    /// A tab switch changed the selection without telling SwiftUI yet: the window updates once
    /// the new tab's first surface is drawn, so that update no longer delays the draw. Input
    /// for `stalePaneID`, the pane the window still shows as selected, goes to the new pane.
    private var unpublishedSelection: (stalePaneID: String?, timeout: Task<Void, Never>)?
    /// True only while `select(tabID:)` itself changes the selection.
    private var holdsSelectionPublish = false
    /// How long a tab switch waits for Herdr's surface before the window shows the selection anyway.
    static var selectionPublishWait: Duration = .milliseconds(50)

    /// Any other change to the selection is published at once, with a switch's if one waits.
    private func selectionWillChange() {
        if holdsSelectionPublish { return }
        if unpublishedSelection != nil {
            publishSelection()
        } else {
            objectWillChange.send()
        }
    }

    /// Tells SwiftUI about a selection a tab switch has not published yet.
    private func publishSelection() {
        guard let pending = unpublishedSelection else { return }
        pending.timeout.cancel()
        unpublishedSelection = nil
        objectWillChange.send()
    }
    /// The pane last used in each tab, so returning to a tab types into the same pane.
    private var lastPaneByTab: [String: String] = [:]
    /// The tab the live surface is switching to. Until its first surface arrives, the window
    /// keeps the terminal view on the previous tab's surface rather than showing the pane text
    /// and then building a new terminal view, which made a switch take about 30 ms to draw.
    private var surfaceSwitchTabID: String?
    /// The pane last sent a pane.focus, until a surface shows it focused (see `select(paneID:)`).
    private var requestedFocusPaneID: String?
    private var terminalTheme = WoolooTheme.named(WoolooTheme.fallbackID)!
    private var terminalFocused: Bool?
    /// Tests use an isolated pasteboard, leaving the user's clipboard untouched.
    var clipboardPasteboard = NSPasteboard.general

    func updateTerminalHost(theme: WoolooTheme, focused: Bool) {
        terminalTheme = theme
        terminalFocused = focused
        surfaceStream?.updateHost(theme: theme, focused: focused)
        markShownTurnSeen()
    }

    private var surfaceSwitchTimeout: Task<Void, Never>?
    /// How long a switch keeps the previous tab's surface if Herdr sends none for the new tab.
    static var surfaceSwitchGrace: Duration = .milliseconds(500)

    static let defaultSessionName = "default"
    private static let lastSessionKey = "HerdrLastSession"

    @Published private(set) var sessionName = UserDefaults.standard.string(forKey: lastSessionKey)
        ?? defaultSessionName { didSet { sessionCache = nil; cachedSessionCache = nil } }
    private var eventTask: Task<Void, Never>?
    private var paneTask: Task<Void, Never>?
    private var surfaceTask: Task<Void, Never>?
    private var eventStream: (any SessionWatcher)?
    private(set) var surfaceStream: (any TerminalSurfaceConnection)?
    private(set) var generation = 0
    private var actionToken = HerdrRequestToken()
    private(set) var actionEpoch = UUID() {
        didSet {
            spaceMoveInFlight = false
            actionToken.cancel()
            actionToken = HerdrRequestToken()
            inputTask?.cancel()
            inputTask = nil
            pendingInput = []
        }
    }
    func invalidatePendingActions() { actionEpoch = UUID() }
    private var lastBootID: String?
    @Published private(set) var destinationEnabled = true

    func setDestinationEnabled(_ enabled: Bool, reason: String? = nil, startImmediately: Bool = true) {
        guard destinationEnabled != enabled else { return }
        destinationEnabled = enabled
        if enabled { if startImmediately { start() } }
        else {
            stop()
            snapshot = nil
            errorMessage = reason ?? "This destination was disabled or removed. Choose another destination in Connections."
        }
    }
    private var presentationEpoch = UUID()
    private(set) var presentationActive = true
    /// Multi-host windows require a fresh matching screen before accepting terminal input.
    var requiresSurfaceForInput = false
    @Published private(set) var presentationEstablished = false
    var inputReady: Bool {
        presentationActive && isConnected && (!requiresSurfaceForInput || presentationProvider == nil ||
            (presentationEstablished && surfaceStream?.isReady == true))
    }

    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else { return }
        presentationActive = active
        stopPresentation()
        if active, eventTask != nil || metadataSubscription != nil { startPresentation() }
    }

    private func stopPresentation() {
        presentationEpoch = UUID()
        presentationEstablished = false
        publishSelection()
        paneTask?.cancel()
        paneTask = nil
        surfaceStream?.cancel()
        surfaceStream = nil
        surfaceTask?.cancel()
        surfaceTask = nil
        inputTask?.cancel()
        inputTask = nil
        pendingInput = []
        setSurface(nil)
        resetAgentView()
        requestedFocusPaneID = nil
    }
    /// Worktree checkouts whose Space is being opened, so a repeated choice does not open two.
    private var openingWorktrees: Set<String> = []
    private struct PendingInput {
        let paneID: String
        let event: HerdrInputEvent
        var popup: (bootID: String, terminalID: String)? = nil
    }
    private var pendingInput: [PendingInput] = []
    /// Keep the modal guard across an endpoint interruption, until a fresh surface
    /// confirms the popup closed. The JSON pane fallback cannot address a popup.
    private var popupBlocksPaneInput = false
    private var inputTask: Task<Void, Never>?
    private var surfaceCols = 80
    private var surfaceRows = 24
    private var cellWidth = 8
    private var cellHeight = 16
    /// With metrics on, records every change notification, so a live run can count what
    /// updates the window per event.
    private var publishRecorder: AnyCancellable?

    private let endpointTimeouts: HerdrEndpointTimeouts

    init(endpointTimeouts: HerdrEndpointTimeouts = HerdrEndpointTimeouts()) {
        self.endpointTimeouts = endpointTimeouts
        snapshotPublisher = publishedSnapshots.eraseToAnyPublisher()
        reloadAgentViewSettings()
        terminalFileLinks.context = { [weak self] paneID in
            guard let self else { return TerminalFileLinks.Context(cwd: nil, machine: nil) }
            let pane = snapshot?.panes.first { $0.paneID == paneID }
            let location = snapshot.flatMap { snapshot in
                pane.flatMap { WorkspaceFiles.location(snapshot: snapshot, workspaceID: $0.workspaceID,
                                                        session: self.sessionName, machine: self.machine) }
            }
            return TerminalFileLinks.Context(cwd: pane?.cwd, machine: machine, root: location?.root)
        }
        terminalFileLinks.directory = { [weak self] paneID in
            guard let self else { throw CancellationError() }
            let backend = self.backend
            let reaching = BlockingWorkMachine(self.machine)
            return try await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                try backend.paneDirectory(paneID)
            }
        }
        if let metrics = TerminalPipelineMetrics.shared {
            publishRecorder = objectWillChange.sink { _ in metrics.published() }
        }
    }

    /// Herdr's config root. Tests point it at a temporary directory with fake servers.
    static var sessionRoot = HerdrRuntimePaths.configRoot

    /// The default session lives at the Herdr config root; named sessions live under `sessions/`.
    private static func sessionDirectory(_ name: String) -> URL {
        name == defaultSessionName ? sessionRoot : sessionRoot.appendingPathComponent("sessions/\(name)")
    }

    /// Sessions with a server socket on disk, default first.
    static func availableSessions() -> [String] {
        let fileManager = FileManager.default
        let sessionsURL = sessionDirectory(defaultSessionName).appendingPathComponent("sessions")
        let named = ((try? fileManager.contentsOfDirectory(atPath: sessionsURL.path)) ?? [])
            .filter { fileManager.fileExists(atPath: sessionDirectory($0).appendingPathComponent("herdr.sock").path) }
            .sorted()
        return [defaultSessionName] + named.filter { $0 != defaultSessionName }
    }

    var socketPath: String {
        if let metadataSource { return metadataSource.socketPath }
        if machine != nil { return remoteBridge?.apiPath ?? "/dev/null" }
        return Self.sessionDirectory(sessionName).appendingPathComponent("herdr.sock").path
    }

    var isConnected: Bool { snapshot != nil && errorMessage == nil }

    /// Checks the paths Command points at in the terminal.
    let terminalFileLinks = TerminalFileLinks()

    /// A pane's directory, asked of Herdr, else the snapshot's.
    func paneDirectory(_ paneID: String) async -> String? {
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let current = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
            try? backend.paneDirectory(paneID)
        }
        return current ?? snapshot?.panes.first { $0.paneID == paneID }?.cwd
    }

    var clientSocketPath: String {
        if let metadataSource { return metadataSource.clientSocketPath }
        if machine != nil { return remoteBridge?.clientPath ?? "/dev/null" }
        return Self.sessionDirectory(sessionName).appendingPathComponent("herdr-client.sock").path
    }

    @Published private(set) var machine: HerdrMachineProfile? { didSet { sessionCache = nil; cachedSessionCache = nil } }
    /// Keep the existing local document keys; remote IDs are scoped to their machine.
    var legacyContextID: String {
        let base = machine.map { "ssh:\($0.id)|\(sessionName)" } ?? sessionName
        return backendKind == .tui ? base : "\(backendKind.rawValue):\(base)"
    }
    /// The TUI's keys are unchanged; herdr-core connections add their own `core:` namespace.
    var contextID: String { backendID.persistentKey }
    private var baseContextID: String { machine?.contextID(session: sessionName) ?? sessionName }
    private var remoteBridge: HerdrRemoteBridge?
    /// App-wide passive API connection; terminal presentation remains owned by this window.
    var metadataSource: HerdrStore?
    private var metadataSubscription: AnyCancellable?

    func updateProfile(_ profile: HerdrMachineProfile) {
        guard let old = machine, old.id == profile.id else { return }
        if old.target == profile.target && old.session == profile.session {
            machine = profile
        } else {
            switchConnection(to: profile.session, machine: profile)
        }
    }

    func connect(to machine: HerdrMachineProfile, startImmediately: Bool = true) {
        switchConnection(to: machine.session, machine: machine, startImmediately: startImmediately)
    }

    func connect(to name: String, remember: Bool = true, startImmediately: Bool = true) {
        switchConnection(to: name, machine: nil, remember: remember, startImmediately: startImmediately)
    }

    /// Connects to a herdr-core session on this Mac, or on `machine` over SSH.
    func connect(toCore session: String, machine: HerdrMachineProfile? = nil, startImmediately: Bool = true) {
        switchConnection(to: session, machine: machine, remember: false, startImmediately: startImmediately,
                         backend: .core)
    }

    private func switchConnection(to name: String, machine: HerdrMachineProfile?, remember: Bool = true,
                                  startImmediately: Bool = true, backend kind: BackendKind = .tui) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HerdrSessionName.isValid(trimmed) else {
            sessionSelectionError = "Use 1–64 letters, numbers, dots, hyphens, or underscores"
            return
        }
        sessionSelectionError = nil
        if self.machine == machine, sessionName == trimmed, backendKind == kind,
           eventTask != nil || metadataSubscription != nil { return }
        stop()
        self.machine = machine
        sessionName = trimmed
        backendKind = kind
        coreBackend?.disconnect()
        coreBackend = nil
        if kind == .core {
            do {
                coreBackend = try Self.makeCoreBackend(trimmed, machine)
                coreError = nil
            }
            catch { coreError = error.localizedDescription }
        } else {
            coreError = nil
        }
        if machine == nil && remember { UserDefaults.standard.set(trimmed, forKey: Self.lastSessionKey) }
        snapshot = nil
        cachedSnapshot = nil
        paneText = [:]
        lastPaneByTab = [:]
        openingWorktrees = []
        workspaceGitStatuses = [:]
        setSurface(nil)
        surfaceError = nil
        selectedWorkspaceID = nil
        selectedTabID = nil
        selectedPaneID = nil
        errorMessage = nil
        isServerStopped = false
        inputError = nil
        actionError = nil
        pendingInput = []
        if startImmediately { start() }
    }

    /// Why a herdr-core connection could not be set up, such as `hc` missing on this Mac.
    private var coreError: String?
    /// Creates the backend of a herdr-core connection; tests replace it with an in-memory core.
    static var makeCoreBackend: (String, HerdrMachineProfile?) throws -> CoreSessionBackend = { session, machine in
        CoreSessionBackend(target: try HerdrCoreSupport.target(session: session, machine: machine))
    }

    func start() {
        guard destinationEnabled else { return }
        guard eventTask == nil, metadataSubscription == nil else { return }
        if backendKind == .core, coreBackend == nil {
            errorMessage = coreError ?? "herdr-core is not available for this connection."
            return
        }
        if backendKind == .tui, let source = metadataSource {
            source.start()
            let currentGeneration = generation
            metadataSubscription = source.snapshotPublisher.combineLatest(source.$errorMessage)
                .receive(on: RunLoop.main)
                .sink { [weak self] snapshot, error in
                    guard let self, generation == currentGeneration else { return }
                    self.errorMessage = error
                    self.isServerStopped = source.isServerStopped
                    if let snapshot {
                        receive(snapshot)
                        repairSelection()
                    } else {
                        if self.snapshot != nil { actionEpoch = UUID() }
                        self.snapshot = nil
                    }
                }
            if presentationActive { startPresentation() }
            return
        }
        if backendKind == .tui, let machine, remoteBridge == nil {
            do { remoteBridge = try HerdrRemoteBridge(machine: machine) }
            catch { errorMessage = error.localizedDescription; return }
        }
        let backend = self.backend
        let currentGeneration = generation
        eventTask = Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            while !Task.isCancelled {
                let stream = backend.makeWatcher()
                let stillCurrent = await MainActor.run { () -> Bool in
                    guard store.generation == currentGeneration else { return false }
                    store.eventStream = stream
                    return true
                }
                if !stillCurrent || Task.isCancelled {
                    stream.cancel()
                    break
                }
                do {
                    // The stream blocks for as long as it is connected: keep it off the cooperative
                    // threads, and out of the limit on blocking work.
                    try await BlockingWork.run(priority: .utility, limited: false) {
                        try stream.run { newSnapshot in
                            Task { @MainActor in
                                guard store.generation == currentGeneration else { return }
                                store.receive(newSnapshot)
                                if store.errorMessage != nil { store.errorMessage = nil }
                                if store.isServerStopped { store.isServerStopped = false }
                                store.repairSelection()
                            }
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    let stopped: Bool
                    if case HerdrSocketError.notRunning = error { stopped = true } else { stopped = false }
                    await MainActor.run {
                        guard store.generation == currentGeneration else { return }
                        store.actionEpoch = UUID()
                        store.snapshot = nil
                        let detail = store.remoteBridge?.lastError ?? message
                        let targetMessage = store.machine.map { "\($0.label): \(detail)" } ?? detail
                        if store.errorMessage != targetMessage { store.errorMessage = targetMessage }
                        if store.isServerStopped != stopped { store.isServerStopped = stopped }
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if presentationActive { startPresentation() }
    }

    private func startPresentation() {
        guard presentationActive, surfaceTask == nil, paneTask == nil else { return }
        #if WOOLOO_PROBES
        TerminalTypingProbe.store = self
        #endif
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let epoch = presentationEpoch
        // The fallback poll reads every second: one thread for all its reads, not one per read.
        let paneTextWorker = BlockingWorker(label: "dev.wooloo.pane-text")
        paneTask = Task {
            while !Task.isCancelled {
                if let snapshot, isConnected {
                    let paneIDs = snapshot.panes.filter { $0.tabID == selectedTabID }.map(\.paneID)
                    if surface != nil && Set(paneIDs) == Set(surface?.paneIDs ?? []) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    for paneID in paneIDs {
                        let paneResult = await BlockingWork.run(priority: .utility, reaching: reaching, on: paneTextWorker) {
                            Result { try backend.paneText(paneID) }
                        }
                        if generation == currentGeneration, presentationEpoch == epoch, case .success(let text) = paneResult,
                           paneText[paneID] != text {
                            paneText[paneID] = text
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let provider = presentationProvider else { return }
        let endpointTimeouts = self.endpointTimeouts
        surfaceTask = Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            while !Task.isCancelled {
                let stream = provider.makePresentation(timeouts: endpointTimeouts)
                let mailbox = HerdrSurfaceMailbox()
                let size = await MainActor.run { () -> (Int, Int, Int, Int)? in
                    guard store.generation == currentGeneration, store.presentationEpoch == epoch else { return nil }
                    store.surfaceStream = stream
                    store.setSurface(nil)
                    store.resetAgentView()
                    return (store.surfaceCols, store.surfaceRows, store.cellWidth, store.cellHeight)
                }
                guard let size, !Task.isCancelled else { stream.cancel(); break }
                do {
                    // A blocking `run`, on a thread of its own at user-interactive priority. The
                    // surfaces it reads are what the user is watching: in a `.utility` task, a loaded
                    // machine starved the thread for up to 0.4 s at a time. It blocks for as long as
                    // it is connected, so it takes no slot from the limit on blocking work.
                    try await BlockingWork.run(qualityOfService: .userInteractive, limited: false,
                                               name: "dev.wooloo.surface-stream") {
                        try stream.run(cols: size.0, rows: size.1,
                                       cellWidth: size.2, cellHeight: size.3) {
                            Task { @MainActor in
                                guard store.generation == currentGeneration, store.presentationEpoch == epoch, store.surfaceStream === stream else { return }
                                // Resizes during startup were retained locally while the endpoint
                                // was not ready. Reconcile them with the provisional hello size.
                                if (store.surfaceCols, store.surfaceRows, store.cellWidth, store.cellHeight) != size {
                                    stream.resize(cols: store.surfaceCols, rows: store.surfaceRows,
                                                  cellWidth: store.cellWidth, cellHeight: store.cellHeight)
                                }
                                if let focused = store.terminalFocused {
                                    stream.updateHost(theme: store.terminalTheme, focused: focused)
                                } else if store.backendKind != .core {
                                    stream.updateHost(theme: store.terminalTheme, focused: false)
                                }
                                if let tabID = store.selectedTabID {
                                    stream.focus(tabID: tabID)
                                } else if let workspaceID = store.selectedWorkspaceID {
                                    stream.focus(workspaceID: workspaceID)
                                }
                                if let paneID = store.selectedPaneID { store.sendPaneFocus(paneID) }
                            }
                        } onSurface: { newSurface in
                            // Surfaces that arrive while the main thread is busy replace each other,
                            // so it only ever shows the newest one.
                            guard mailbox.put(newSurface) else { return }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    guard let latest = mailbox.take(), store.generation == currentGeneration, store.presentationEpoch == epoch,
                                          store.surfaceStream === stream else { return }
                                    store.setSurface(latest)
                                    if store.surfaceError != nil { store.surfaceError = nil }
                                    TerminalPipelineMetrics.shared?.delivered(latest)
                                }
                            }
                        } onAgents: { projection in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    guard store.generation == currentGeneration, store.presentationEpoch == epoch, store.surfaceStream === stream else { return }
                                    store.receiveAgentProjection(projection)
                                }
                            }
                        } onClipboard: { text in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    guard store.generation == currentGeneration, store.presentationEpoch == epoch,
                                          store.surfaceStream === stream, store.presentationActive else { return }
                                    let pasteboard = store.clipboardPasteboard
                                    guard pasteboard.string(forType: .string) != text else { return }
                                    pasteboard.clearContents()
                                    pasteboard.setString(text, forType: .string)
                                }
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard store.generation == currentGeneration, store.presentationEpoch == epoch, store.surfaceStream === stream else { return }
                        // Invalidate queued callbacks before clearing the last surface and projection.
                        store.surfaceStream = nil
                        store.setSurface(nil)
                        store.resetAgentView()
                        // Retried every second while the endpoint is missing.
                        store.setIfChanged(\.surfaceError, String(describing: error))
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Whether the window shows the live surface for the selected tab: it shows the tab's panes,
    /// or the tab was just selected and its first surface has not arrived yet.
    var showsLiveSurface: Bool {
        guard let surfaceLayout else { return false }
        let panes = Set(selectedPanes.map(\.id))
        guard !panes.isEmpty else { return false }
        return Set(surfaceLayout.paneIDs) == panes || (surfaceSwitchTabID != nil && surfaceSwitchTabID == selectedTabID)
    }

    /// Keeps the terminal view while the live surface switches to the selected tab; true when
    /// it began such a switch.
    @discardableResult
    private func beginSurfaceSwitch() -> Bool {
        guard surfaceStream != nil, let surfaceLayout, let selectedTabID,
              Set(surfaceLayout.paneIDs) != Set(selectedPanes.map(\.id)) else {
            endSurfaceSwitch()
            return false
        }
        surfaceSwitchTabID = selectedTabID
        surfaceSwitchTimeout?.cancel()
        surfaceSwitchTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.surfaceSwitchGrace)
            guard !Task.isCancelled, let self, surfaceSwitchTabID != nil else { return }
            // The window falls back to the pane text until the tab's surface arrives.
            objectWillChange.send()
            endSurfaceSwitch()
        }
        return true
    }

    private func endSurfaceSwitch() {
        surfaceSwitchTabID = nil
        surfaceSwitchTimeout?.cancel()
        surfaceSwitchTimeout = nil
    }

    private func setSurface(_ surface: HerdrSurface?) {
        if let boot = surface?.bootID {
            if let lastBootID, lastBootID != boot {
                actionEpoch = UUID()
                pendingInput = []
            }
            lastBootID = boot
        }
        let showsTab = surface.map { Set($0.paneIDs) == Set(selectedPanes.map(\.id)) } ?? false
        if showsTab && !presentationEstablished { presentationEstablished = true }
        if surface == nil { presentationEstablished = false }
        let completesSwitch = showsTab && surfaceSwitchTabID != nil
        if surface == nil || showsTab { endSurfaceSwitch() }
        if let surface { popupBlocksPaneInput = surface.popup != nil }
        if surface == nil || surface?.focusedPaneID == requestedFocusPaneID { requestedFocusPaneID = nil }
        surfaceFeed.publish(surface, answersUser: completesSwitch)
        // The surface is drawn; the window shows the selection in the next turn, after this
        // turn's commit has put the surface on screen.
        if showsTab, unpublishedSelection != nil {
            DispatchQueue.main.async { [weak self] in self?.publishSelection() }
        }
        let layout = surface.map { HerdrSurfaceLayout(bootID: $0.bootID, paneIDs: $0.paneIDs, popupTerminalID: $0.popup?.terminalID) }
        guard layout != surfaceLayout else { return }
        defer { markShownTurnSeen() }
        // The first surface of a tab switched to changes nothing the window shows: it already
        // shows the live surface. Publishing would delay its draw by a SwiftUI update.
        if completesSwitch, layout?.popupTerminalID == surfaceLayout?.popupTerminalID {
            surfaceLayoutValue = layout
        } else {
            surfaceLayout = layout
        }
    }

    func visibleAgents(inSelectedSpaceOnly spaceOnly: Bool, followHerdrView: Bool = true) -> [WoolooAgent] {
        if let state = agentViewState, state.label != nil || state.view != nil {
            return state.agents(workspaceID: selectedWorkspaceID, tabID: selectedTabID,
                                spaceOnly: spaceOnly, followView: followHerdrView, prioritySort: agentPrioritySort)
                .map(\.woolooAgent)
        }
        let agents = (session?.agents ?? []).filter { !spaceOnly || $0.spaceID == selectedWorkspaceID }
        // Pinned agents first, each group in the backend's order.
        return agents.filter(\.pinned) + agents.filter { !$0.pinned }
    }

    func reloadAgentViewSettings() {
        let text = (try? HerdrConfigFile.read(at: HerdrConfigFile.url)) ?? ""
        let priority = HerdrConfigDocument(text: text).string(section: "ui", key: "agent_panel_sort", default: "spaces") == "priority"
        if agentPrioritySort != priority { agentPrioritySort = priority }
    }

    func receiveAgentProjection(_ projection: HerdrAgentProjection) {
        let statuses = Dictionary(uniqueKeysWithValues: projection.snapshot.workspaces.compactMap { workspace in
            workspace.gitStatus.map { (workspace.workspaceID, $0) }
        })
        if workspaceGitStatuses != statuses { workspaceGitStatuses = statuses }
        publishAgentView(agentPresentation.receive(projection))
    }

    /// The terminal view only calls this after drawing in the active window.
    func acknowledgeAgentSurface(_ surface: HerdrSurface) {
        if let state = agentPresentation.acknowledge(surface) { publishAgentView(state) }
    }

    private func publishAgentView(_ state: HerdrAgentViewState) {
        // Agent facts still track completions without an active query, but the JSON snapshot
        // already updates the normal sidebar. Avoid publishing the same changes twice.
        let next = state.view != nil || state.label != nil || state.unavailable ? state : nil
        if agentViewState != next { agentViewState = next }
    }

    private func resetAgentView() {
        if !workspaceGitStatuses.isEmpty { workspaceGitStatuses = [:] }
        agentPresentation = HerdrAgentPresentation()
        if agentViewState != nil { agentViewState = nil }
    }

    func stop() {
        publishSelection()
        popupBlocksPaneInput = false
        generation += 1
        actionEpoch = UUID()
        stopPresentation()
        metadataSubscription?.cancel()
        metadataSubscription = nil
        eventStream?.cancel()
        eventStream = nil
        eventTask?.cancel()
        eventTask = nil
        paneTask?.cancel()
        paneTask = nil
        surfaceStream?.cancel()
        surfaceStream = nil
        surfaceTask?.cancel()
        surfaceTask = nil
        setSurface(nil)
        resetAgentView()
        inputTask?.cancel()
        inputTask = nil
        pendingInput = []
        remoteBridge?.stop()
        remoteBridge = nil
    }

    func select(workspaceID: String, tabID: String? = nil, paneID: String? = nil) {
        selectedWorkspaceID = workspaceID
        let tabs = snapshot?.tabs.filter { $0.workspaceID == workspaceID } ?? []
        let activeTabID = snapshot?.workspaces.first { $0.workspaceID == workspaceID }?.activeTabID
        selectedTabID = tabID ?? tabs.first { $0.tabID == activeTabID }?.tabID ?? tabs.first?.tabID
        selectedPaneID = paneID ?? preferredPane(in: selectedTabID)
        beginSurfaceSwitch()
        // `tab.focus` also switches the workspace; sending `workspace.focus` first can race
        // and leave the surface on the workspace's previously active tab.
        if let selectedTabID {
            surfaceStream?.focus(tabID: selectedTabID)
        } else {
            surfaceStream?.focus(workspaceID: workspaceID)
        }
        if let selectedPaneID { sendPaneFocus(selectedPaneID) }
    }

    func clearActionError() { actionError = nil }

    func createWorkspace(cwd: String? = nil, label: String? = nil,
                         selectOnOpen: Bool = true, onCreated: @escaping @MainActor (String) -> Void = { _ in }) {
        let source = cwd == nil ? selectedWorkspaceID : nil
        openSpace(selectOnOpen: selectOnOpen, onOpened: onCreated) { backend in
            try backend.create(.space(sourceSpaceID: source, cwd: cwd, label: label))
        }
    }

    /// Focuses the Space of a Git worktree checkout, opening one there if none is, as Herdr's
    /// `worktree.open` does: each checkout has one Space, and the Spaces of other checkouts keep
    /// their terminals and agents running. `repository` is the main checkout; without one (a bare
    /// repository), or when Herdr cannot open worktrees there, a plain Space opens in the checkout.
    func openWorktree(_ checkout: String, repository: String?) {
        guard isConnected else { return }
        // Herdr also finds a Space opened in the checkout without `worktree.open`, so it is only
        // skipped when the snapshot already names the checkout's Space.
        if let open = snapshot?.workspaces.first(where: { $0.worktree?.checkoutPath == checkout }) {
            select(workspaceID: open.workspaceID)
            return
        }
        guard openingWorktrees.insert(checkout).inserted else { return }
        openSpace(finished: { [weak self] in self?.openingWorktrees.remove(checkout) }) { backend in
            try backend.create(.worktreeSpace(checkout: checkout, repository: repository))
        }
    }

    /// Runs a request that opens a Space off the main thread, then selects that Space.
    private func openSpace(finished: @escaping @MainActor () -> Void = {},
                           selectOnOpen: Bool = true,
                           onOpened: @escaping @MainActor (String) -> Void = { _ in },
                           _ open: @escaping @Sendable (any SessionBackend) throws -> String) {
        guard isConnected else { return finished() }
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> (String, HerdrSnapshot) in
                    try requestToken.check()
                    let id = try open(backend)
                    return (id, try backend.snapshot())
                }
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            finished()
            switch result {
            case .success(let (id, fresh)):
                snapshot = fresh
                if selectOnOpen { select(workspaceID: id) }
                onOpened(id)
                actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func createTab(cwd: String? = nil) {
        guard isConnected, let workspaceID = selectedWorkspaceID else { return }
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> (String, HerdrSnapshot) in
                    try requestToken.check()
                    let id = try backend.create(.tab(spaceID: workspaceID, cwd: cwd))
                    return (id, try backend.snapshot())
                }
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            switch result {
            case .success(let (id, fresh)):
                snapshot = fresh
                select(workspaceID: workspaceID, tabID: id)
                actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func focusPane(_ direction: String) {
        guard let paneID = selectedPaneID else { return }
        performAction(.focusPane(paneID: paneID, direction: direction))
    }

    func splitPane(_ direction: String) {
        guard let paneID = selectedPaneID, let workspaceID = selectedWorkspaceID else { return }
        performAction(.splitPane(spaceID: workspaceID, paneID: paneID, direction: direction))
    }

    func zoomPane() {
        guard let paneID = selectedPaneID else { return }
        performAction(.zoomPane(paneID: paneID))
    }

    func renameWorkspace(_ workspaceID: String, to label: String) {
        performAction(.renameSpace(spaceID: workspaceID, label: label))
    }

    func closeWorkspace(_ workspaceID: String) {
        performAction(.closeSpace(spaceID: workspaceID))
    }

    /// Renames the agent in a pane; a nil name restores the detected agent name.
    /// Pins or unpins an agent for every herdr-core client; the TUI has no pins.
    func setAgentPinned(_ paneID: String, _ pinned: Bool) {
        changeCoreLabels { try $0.setPinned(paneID, pinned) }
    }

    /// Shows an agent's finished turn as unread again, for every herdr-core client.
    func markAgentUnread(_ paneID: String) {
        // Showing the pane would mark it seen again at once: it stays unread until the window
        // selects another pane and comes back.
        unreadHold = paneID
        changeCoreLabels { try $0.markUnread(paneID) }
    }

    private func changeCoreLabels(_ change: @escaping @Sendable (CoreSessionBackend) throws -> Void) {
        guard isConnected, let coreBackend else { return }
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        Task {
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> HerdrSnapshot in
                    try change(coreBackend)
                    return try coreBackend.snapshot()
                }
            }
            guard generation == currentGeneration else { return }
            switch result {
            case .success(let fresh): receive(fresh); actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func renameAgent(_ paneID: String, to name: String?) {
        performAction(.renameAgent(paneID: paneID, name: name))
    }

    func renameTab(_ tabID: String, to label: String) {
        performAction(.renameTab(tabID: tabID, label: label))
    }

    func closeTab(_ tabID: String) {
        performAction(.closeTab(tabID: tabID))
    }

    /// Sidebar reorders use a stable row anchor, resolved against the server's latest order.
    @discardableResult
    func moveWorkspace(_ workspaceID: String, beside anchorID: String, after: Bool) -> Bool {
        guard isConnected, !spaceMoveInFlight, let session,
              session.spaceMoveIndex(workspaceID, beside: anchorID, after: after) != nil else { return false }
        runSpaceMove { backend, token, _ in
            try backend.moveSpace(workspaceID, beside: anchorID, after: after, checkpoint: { try token.check() })
            return nil
        }
        return true
    }

    func tabSpaceMoveRefusal(_ tabID: String, to workspaceID: String?) -> String? {
        guard isConnected, !spaceMoveInFlight, let session else { return "Wait for the Space connection or move to finish." }
        if let reason = session.tabSpaceMoveRefusal(tabID, to: workspaceID) { return reason }
        if let tab = session.tabs.first(where: { $0.id == tabID }), session.tabs(in: tab.spaceID).count == 1,
           WorkspaceSessionRegistry.shared.hasDocuments(in: session.spaceKey(tab.spaceID)) {
            return "Leave another terminal tab in the source Space, or close its document tabs in every window first."
        }
        return nil
    }

    /// Herdr moves a pane, not a whole tab. A single-pane tab can be relocated atomically.
    @discardableResult
    func moveTab(_ tabID: String, toWorkspace workspaceID: String?, shouldFollow: @escaping () -> Bool = { true },
                 onFollow: @escaping (WoolooPane) -> Void = { _ in }) -> Bool {
        guard tabSpaceMoveRefusal(tabID, to: workspaceID) == nil,
              let tab = session?.tabs.first(where: { $0.id == tabID }) else { return false }
        let space = "\(contextID)|\(tab.spaceID)"
        let revision = selectionRevision
        let follow = selectedTabID == tabID
        runSpaceMove(prepare: {
            guard await WorkspaceSessionRegistry.shared.canRemoveSpace(space) else {
                throw SessionMoveError(message: "Leave another terminal tab in the source Space, or recover and close its open or backed-up documents first.")
            }
        }, onlyPrepareIfLastTab: tabID, followRevision: follow ? revision : nil, shouldFollow: shouldFollow, onFollow: onFollow) { backend, token, lastTabWasChecked in
            try backend.moveTab(tabID, toSpace: workspaceID, lastTabWasChecked: lastTabWasChecked,
                                checkpoint: { try token.check() })
        }
        return true
    }

    /// One sidebar mutation at a time; always reconcile uncertain replies without retrying.
    private func runSpaceMove(prepare: @escaping @MainActor () async throws -> Void = {},
                              onlyPrepareIfLastTab tabID: String? = nil, followRevision: UInt64? = nil,
                              shouldFollow: @escaping () -> Bool = { true },
                              onFollow: @escaping (WoolooPane) -> Void = { _ in },
                              action: @escaping (any SessionBackend, HerdrRequestToken, Bool) throws -> WoolooPane?) {
        spaceMoveInFlight = true
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let token = actionToken
        Task {
            let preflight = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { try token.check(); return try backend.snapshot() }
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            let result: Result<WoolooPane?, Error>
            do {
                let fresh = try preflight.get()
                let lastTab = tabID.flatMap { id in fresh.tabs.first { $0.tabID == id } }.map { tab in
                    fresh.tabs.filter { $0.workspaceID == tab.workspaceID }.count == 1
                } ?? false
                if lastTab { try await prepare() }
                try token.check()
                result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                    Result { try token.check(); return try action(backend, token, lastTab) }
                }
            } catch { result = .failure(error) }
            let fresh = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                try? { try token.check(); return try backend.snapshot() }()
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            spaceMoveInFlight = false
            if let fresh {
                snapshot = fresh
                if case .success(let pane?) = result, followRevision == selectionRevision, shouldFollow(),
                   fresh.panes.contains(where: { $0.paneID == pane.id && $0.tabID == pane.tabID && $0.workspaceID == pane.spaceID }) {
                    select(workspaceID: pane.spaceID, tabID: pane.tabID, paneID: pane.id)
                    onFollow(pane)
                } else { repairSelection() }
            } else { repairSelection() }
            switch result {
            case .success: actionError = fresh == nil ? "The move was sent, but refreshing Spaces failed. Check the connection before retrying." : nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    /// Moves a tab within its Space with `tab.move`. `insertIndex` is a gap in the Space's
    /// current tab order: 0 is before the first tab and `count` after the last, so a tab moved
    /// right goes before the tab at `insertIndex`. The new order shows at once and Herdr's
    /// snapshot, read right after, replaces it.
    func moveTab(_ tabID: String, to insertIndex: Int) {
        guard isConnected, let current = snapshot, let moved = current.movingTab(tabID, to: insertIndex) else { return }
        snapshot = moved
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> Void in
                    try requestToken.check()
                    try backend.perform(.moveTab(tabID: tabID, insertIndex: insertIndex))
                }
            }
            // Read Herdr's order even when the move failed, to undo the one shown.
            let fresh = await BlockingWork.run(priority: .userInitiated, reaching: reaching) { try? { try requestToken.check(); return try backend.snapshot() }() }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            if let fresh {
                snapshot = fresh
                repairSelection()
            }
            switch result {
            case .success: actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    /// Whether the terminal tab `tabID`, dragged over the selected tab's panes, may split into them.
    func canSplit(tabID: String) -> Bool {
        isConnected && session?.paneToSplit(fromTab: tabID, into: selectedTabID) != nil
    }

    /// Moves the only pane of tab `tabID` into the selected tab next to `targetPaneID`, on its
    /// `edge`, and selects it. Herdr splits only right or down, so left and top split that way
    /// and then swap the two panes, which mirrors the new split at any depth of the layout.
    /// Herdr closes the emptied tab itself. The snapshot is read once, after both requests.
    /// Returns false, sending nothing, when the drop is not allowed.
    @discardableResult
    func splitTab(_ tabID: String, nextTo targetPaneID: String, edge: TerminalDropEdge) -> Bool {
        guard isConnected, let into = selectedTabID, let session,
              let paneID = session.paneToSplit(fromTab: tabID, into: into),
              session.panes(in: into).contains(where: { $0.id == targetPaneID }) else { return false }
        return movePane(paneID, nextTo: targetPaneID, edge: edge)
    }

    func canMovePane(_ paneID: String, nextTo targetPaneID: String) -> Bool {
        guard isConnected, paneID != targetPaneID, let snapshot,
              let source = snapshot.panes.first(where: { $0.paneID == paneID }),
              let target = snapshot.panes.first(where: { $0.paneID == targetPaneID }),
              source.workspaceID == target.workspaceID,
              target.tabID == selectedTabID else { return false }
        return snapshot.layouts.first(where: { $0.tabID == target.tabID })?.zoomed != true
    }

    @discardableResult
    func detachPane(_ paneID: String) -> Bool {
        guard isConnected, let snapshot, let source = snapshot.panes.first(where: { $0.paneID == paneID }),
              snapshot.panes.filter({ $0.tabID == source.tabID }).count > 1 else { return false }
        relocatePane(paneID, to: .newTab)
        return true
    }

    @discardableResult
    func movePane(_ paneID: String, nextTo targetPaneID: String, edge: TerminalDropEdge) -> Bool {
        guard canMovePane(paneID, nextTo: targetPaneID), let snapshot,
              let source = snapshot.panes.first(where: { $0.paneID == paneID }),
              let target = snapshot.panes.first(where: { $0.paneID == targetPaneID }) else { return false }
        relocatePane(paneID, to: .beside(targetPaneID: targetPaneID, tabID: target.tabID, split: edge.split,
                                         swapAfter: edge.swapsAfterMove, detachFirst: source.tabID == target.tabID))
        return true
    }

    /// Herdr refuses same-tab moves. Temporarily detach the pane, then insert it beside the
    /// target. Always refresh after a partial failure so the surviving terminal remains reachable.
    private func relocatePane(_ paneID: String, to destination: PaneDestination) {
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let originalTab = snapshot?.panes.first(where: { $0.paneID == paneID })?.tabID
        let originalSelection = selectedTabID
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> Void in
                    try backend.movePane(paneID, to: destination, checkpoint: { try requestToken.check() })
                }
            }
            // Read Herdr's layout even after a failure, which may follow a successful move.
            let fresh = await BlockingWork.run(priority: .userInitiated, reaching: reaching) { try? { try requestToken.check(); return try backend.snapshot() }() }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            if let fresh {
                self.snapshot = fresh
                let succeeded: Bool
                if case .success = result { succeeded = true } else { succeeded = false }
                if selectedTabID == originalSelection,
                   let moved = fresh.panes.first(where: { $0.paneID == paneID }),
                   succeeded || moved.tabID != originalTab {
                    selectedTabID = moved.tabID
                    selectedPaneID = paneID
                    sendPaneFocus(paneID)
                }
                repairSelection()
            }
            switch result {
            case .success: actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func closePane(_ paneID: String) {
        performAction(.closePane(paneID: paneID))
    }

    func reloadConfig() {
        guard isConnected else { return }
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> Void in
                    try requestToken.check()
                    try backend.perform(.reloadConfig)
                }
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            if case .failure(let error) = result { actionError = error.localizedDescription }
            else { actionError = nil }
        }
    }

    /// The backend that carries out this connection's session commands.
    var backend: any SessionBackend { coreBackend ?? tuiBackend }
    /// Makes the live terminal presentation for this connection: the TUI's binary endpoint, or
    /// a herdr-core terminal emulated in wooloo. Nil only for a Core connection that could not
    /// be set up; panes then show their text.
    var presentationProvider: (any TerminalPresentationProvider)? { backendKind == .tui ? tuiBackend : coreBackend }
    private var tuiBackend: TUISessionBackend {
        TUISessionBackend(socketPath: socketPath, surfacePath: clientSocketPath)
    }

    private func performAction(_ command: SessionCommand) {
        guard isConnected else { return }
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        Task {
            guard requestToken.isValid else { return }
            let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                Result { () throws -> HerdrSnapshot in
                    try requestToken.check()
                    try backend.perform(command)
                    return try backend.snapshot()
                }
            }
            guard generation == currentGeneration, actionEpoch == currentEpoch else { return }
            switch result {
            case .success(let fresh):
                snapshot = fresh
                if command.followsServerFocus, let workspaceID = fresh.focusedWorkspaceID {
                    select(workspaceID: workspaceID, tabID: fresh.focusedTabID,
                           paneID: fresh.focusedPaneID)
                } else {
                    repairSelection()
                }
                actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func select(tabID: String) {
        // The pane the window shows as selected, which a switch already waiting keeps.
        let stalePaneID = unpublishedSelection.map(\.stalePaneID) ?? selectedPaneID
        holdsSelectionPublish = true
        selectedTabID = tabID
        selectedPaneID = preferredPane(in: tabID)
        holdsSelectionPublish = false
        // While the live surface switches to the tab, the window keeps showing the previous
        // one until the new tab's surface comes, so publishing now would only make SwiftUI
        // update the window in between and delay drawing that surface.
        if beginSurfaceSwitch() {
            deferSelectionPublish(stalePaneID: stalePaneID)
        } else if unpublishedSelection != nil {
            publishSelection()
        } else {
            objectWillChange.send()
        }
        surfaceStream?.focus(tabID: tabID)
        if let selectedPaneID { sendPaneFocus(selectedPaneID) }
    }

    private func deferSelectionPublish(stalePaneID: String?) {
        unpublishedSelection?.timeout.cancel()
        unpublishedSelection = (stalePaneID, Task { [weak self] in
            try? await Task.sleep(for: Self.selectionPublishWait)
            guard !Task.isCancelled else { return }
            self?.publishSelection()
        })
    }

    /// The panes of a tab, in Herdr's order.
    func panes(inTab tabID: String?) -> [HerdrPane] {
        snapshot?.panes.filter { $0.tabID == tabID } ?? []
    }

    private func preferredPane(in tabID: String?) -> String? {
        guard let tabID else { return nil }
        let panes = panes(inTab: tabID)
        if let remembered = lastPaneByTab[tabID], panes.contains(where: { $0.paneID == remembered }) {
            return remembered
        }
        if let focused = snapshot?.focusedPaneID, panes.contains(where: { $0.paneID == focused }) {
            return focused
        }
        return panes.first?.paneID
    }

    func select(paneID: String) {
        guard snapshot?.panes.contains(where: { $0.paneID == paneID && $0.tabID == selectedTabID }) == true else { return }
        // Every click in a pane selects it; publishing the same pane again would update the whole window.
        if selectedPaneID != paneID { selectedPaneID = paneID }
        // Herdr answers every pane.focus with a complete surface, even for the pane it already
        // focuses, so a click there would cost a full frame (45 KB at 126x48). That pane is the
        // one last asked for until a surface shows it, then the live surface's. The snapshot's is
        // stale: a pane.focus emits no event that refreshes it.
        if (requestedFocusPaneID ?? surface?.focusedPaneID) != paneID { sendPaneFocus(paneID) }
    }

    /// Asks Herdr to focus a pane, which it answers with a surface that shows the pane focused.
    private func sendPaneFocus(_ paneID: String) {
        if surfaceStream?.focus(paneID: paneID) == true { requestedFocusPaneID = paneID }
    }

    func resizeSurface(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard cols > 0, rows > 0, cols <= 1000, rows <= 1000 else { return }
        guard (cols, rows, cellWidth, cellHeight) != (surfaceCols, surfaceRows, self.cellWidth, self.cellHeight) else { return }
        surfaceCols = cols
        surfaceRows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        surfaceStream?.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    func sendText(_ text: String, to paneID: String) {
        guard !text.isEmpty else { return }
        enqueueInput(paneID: paneID, event: .text(text))
    }

    func sendPaste(_ text: String, to paneID: String) {
        guard !text.isEmpty else { return }
        enqueueInput(paneID: paneID, event: .paste(text))
    }

    func sendKey(_ key: String, to paneID: String) {
        enqueueInput(paneID: paneID, event: .key(key))
    }

    func sendMouse(_ mouse: HerdrMouseEvent, to paneID: String) {
        enqueueInput(paneID: paneID, event: .mouse(mouse))
    }

    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String, bootID: String) {
        guard surface?.bootID == bootID, surface?.popup?.terminalID == terminalID else { return }
        enqueueInput(PendingInput(paneID: "", event: event, popup: (bootID, terminalID)))
    }

    func closePopup(terminalID: String, bootID: String) {
        guard surface?.bootID == bootID, surface?.popup?.terminalID == terminalID else { return }
        if surfaceStream?.closePopup() != true {
            setIfChanged(\.inputError, "Herdr popup close is unavailable")
        }
    }

    /// Whether the selected pane's terminal can be searched: herdr-core terminals, which
    /// wooloo emulates with their scrollback. The TUI keeps its scrollback on the server.
    /// `presentationEstablished` is published and follows the live stream, so views and menus
    /// that ask this update when the stream ends or comes back.
    var findsInTerminal: Bool { backendKind == .core && presentationEstablished && selectedPaneID != nil }

    /// Searches the selected pane's terminal and shows the next match, older or newer. It runs
    /// off the main thread, since a long scrollback takes a while.
    func findInTerminal(_ query: String, older: Bool) async -> TerminalFindResult? {
        guard findsInTerminal, let stream = surfaceStream, let paneID = selectedPaneID else { return nil }
        terminalFinds &+= 1
        let (request, ended) = (terminalFinds, terminalFindsEnded)
        let result = try? await BlockingWork.run(priority: .userInitiated) { stream.find(query, in: paneID, older: older, request: UInt64(request)) }
        guard terminalFinds == request else { return nil }
        // The search ended while this find was queued: it may have begun after `endFind`, so
        // its highlight and scroll go again.
        guard terminalFindsEnded == ended else {
            stream.endFind()
            return nil
        }
        return result
    }

    /// Finds asked for, so only the newest one reports or undoes anything.
    private var terminalFinds = 0
    /// Bumped by each `endTerminalFind`, so a find that was still queued ends too.
    private var terminalFindsEnded = 0

    func endTerminalFind() {
        terminalFindsEnded &+= 1
        surfaceStream?.endFind()
    }

    func setSplitRatio(path: [Bool], ratio: Double) {
        guard let tabID = selectedTabID, ratio.isFinite else { return }
        // Called up to 30 times a second while a split is dragged, so an unchanged error is not published again.
        if surfaceStream?.setSplitRatio(tabID: tabID, path: path, ratio: ratio) != true {
            setIfChanged(\.surfaceError, "Herdr split resize is unavailable")
        }
    }

    private func enqueueInput(paneID: String, event: HerdrInputEvent) {
        guard !popupBlocksPaneInput else { return }
        // Until the window shows a tab switch, its terminal view still names the previous pane
        // for typed input; mouse events keep the pane under the pointer.
        let redirects = event.isTyped && unpublishedSelection.map { paneID == $0.stalePaneID } == true
        let target = redirects ? selectedPaneID ?? paneID : paneID
        enqueueInput(PendingInput(paneID: target, event: event))
    }

    private func enqueueInput(_ input: PendingInput) {
        guard inputReady else { return }
        pendingInput.append(input)
        guard inputTask == nil else { return }
        let backend = self.backend
        let reaching = BlockingWorkMachine(machine)
        let currentGeneration = generation
        let currentEpoch = actionEpoch
        let requestToken = actionToken
        let inputEpoch = presentationEpoch
        inputTask = Task {
            defer {
                if generation == currentGeneration, presentationEpoch == inputEpoch, actionEpoch == currentEpoch {
                    inputTask = nil
                }
            }
            guard requestToken.isValid else { return }
            while !pendingInput.isEmpty && !Task.isCancelled && presentationEpoch == inputEpoch {
                let item = pendingInput.removeFirst()
                if let popup = item.popup {
                    guard surface?.bootID == popup.bootID, surface?.popup?.terminalID == popup.terminalID else { continue }
                    let sent = surfaceStream?.sendPopupInput(item.event, terminalID: popup.terminalID) == true
                    setIfChanged(\.inputError, sent ? nil : "Herdr popup input is unavailable; reconnecting")
                    continue
                }
                guard !popupBlocksPaneInput else { continue }
                if let stream = surfaceStream, stream.isReady {
                    if stream.sendInput(item.event, to: item.paneID) {
                        if item.event.isTyped { surfaceFeed.expectAnswer() }
                        // Publishing, even an unchanged nil, would update the whole window on every key.
                        setIfChanged(\.inputError, nil)
                    } else {
                        setIfChanged(\.inputError, "Herdr endpoint input failed; reconnecting")
                    }
                    continue
                }
                let text: String?
                let keys: [String]
                switch item.event {
                case .text(let value), .paste(let value):
                    text = value
                    keys = []
                case .key(let value):
                    text = nil
                    keys = [value]
                case .mouse:
                    continue // JSON pane.send_input has no mouse event field.
                }
                let result = await BlockingWork.run(priority: .userInitiated, reaching: reaching) {
                    Result { try requestToken.check(); return try backend.sendInput(to: item.paneID, text: text, keys: keys) }
                }
                guard generation == currentGeneration, actionEpoch == currentEpoch else { break }
                if case .failure(let error) = result {
                    setIfChanged(\.inputError, error.localizedDescription)
                } else {
                    setIfChanged(\.inputError, nil)
                }
            }
        }
    }

    /// Keeps a snapshot from the event stream. Each event fetches one, and several events often
    /// bring the same one; publishing it unchanged would update the whole window for nothing.
    /// A split drag changes only the layouts, several times a second, and the window reads
    /// them only for panes the live surface does not show, so then it is kept without a publish.
    func receive(_ newSnapshot: HerdrSnapshot) {
        guard let old = snapshotValue, old != newSnapshot else {
            if snapshotValue == nil { snapshot = newSnapshot }
            return
        }
        let onlyLayouts = old.workspaces == newSnapshot.workspaces && old.tabs == newSnapshot.tabs
            && old.panes == newSnapshot.panes && old.agents == newSnapshot.agents
            && old.focusedWorkspaceID == newSnapshot.focusedWorkspaceID && old.focusedTabID == newSnapshot.focusedTabID
            && old.focusedPaneID == newSnapshot.focusedPaneID
        let tabPanes = Set(newSnapshot.panes.filter { $0.tabID == selectedTabID }.map(\.paneID))
        // Reordering the layout's first pane can change the file root even with the same panes.
        let fileRootChanged = onlyLayouts && selectedWorkspaceID.map { workspaceID in
            WorkspaceFiles.location(snapshot: old, workspaceID: workspaceID, session: sessionName, machine: machine)?.root
                != WorkspaceFiles.location(snapshot: newSnapshot, workspaceID: workspaceID, session: sessionName, machine: machine)?.root
        } == true
        if onlyLayouts, !fileRootChanged, let surfaceLayout, !tabPanes.isEmpty, Set(surfaceLayout.paneIDs) == tabPanes {
            snapshotValue = newSnapshot
        } else {
            snapshot = newSnapshot
        }
        markShownTurnSeen()
    }

    /// Assigns a published value only when it differs: any assignment, even of the same value,
    /// makes SwiftUI update every view that observes the store.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HerdrStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func repairSelection() {
        // Move events can arrive before the reply. Reconcile once the operation knows
        // the returned IDs, avoiding an intermediate Space switch that hides documents.
        guard !spaceMoveInFlight, let snapshot else { return }
        repairingSelection = true
        defer { repairingSelection = false }
        if !snapshot.workspaces.contains(where: { $0.workspaceID == selectedWorkspaceID }) {
            selectedWorkspaceID = snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
        }
        if !snapshot.tabs.contains(where: { $0.tabID == selectedTabID && $0.workspaceID == selectedWorkspaceID }) {
            selectedTabID = snapshot.workspaces.first { $0.workspaceID == selectedWorkspaceID }?.activeTabID
                ?? snapshot.tabs.first { $0.workspaceID == selectedWorkspaceID }?.tabID
        }
        if !snapshot.panes.contains(where: { $0.paneID == selectedPaneID && $0.tabID == selectedTabID }) {
            selectedPaneID = preferredPane(in: selectedTabID)
        }
        if !presentationEstablished, let surface,
           Set(surface.paneIDs) == Set(selectedPanes.map(\.id)) {
            presentationEstablished = true
        }
    }
}

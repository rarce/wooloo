import Combine
import Darwin
import Foundation

struct HerdrSnapshot: Decodable, Equatable {
    let workspaces: [HerdrWorkspace]
    let tabs: [HerdrTab]
    let panes: [HerdrPane]
    let agents: [HerdrAgent]
    let layouts: [HerdrLayout]
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaces, tabs, panes, agents, layouts
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }
}

extension HerdrSnapshot {
    /// This snapshot with a tab moved to `insertIndex`, a gap in its Space's tab order as
    /// `tab.move` takes it; nil when the tab is unknown, the gap is out of range, or the tab
    /// would stay where it is.
    func movingTab(_ tabID: String, to insertIndex: Int) -> HerdrSnapshot? {
        guard let tab = tabs.first(where: { $0.tabID == tabID }) else { return nil }
        var spaceTabs = tabs.filter { $0.workspaceID == tab.workspaceID }
        guard let from = spaceTabs.firstIndex(of: tab), (0...spaceTabs.count).contains(insertIndex),
              insertIndex != from, insertIndex != from + 1 else { return nil }
        spaceTabs.remove(at: from)
        spaceTabs.insert(tab, at: insertIndex > from ? insertIndex - 1 : insertIndex)
        var next = spaceTabs.makeIterator()
        return HerdrSnapshot(workspaces: workspaces,
                             tabs: tabs.map { $0.workspaceID == tab.workspaceID ? next.next()! : $0 },
                             panes: panes, agents: agents, layouts: layouts, focusedWorkspaceID: focusedWorkspaceID,
                             focusedTabID: focusedTabID, focusedPaneID: focusedPaneID)
    }
}

extension HerdrSnapshot {
    /// The pane a terminal tab dropped on `targetTabID`'s panes moves there: the tab's only
    /// pane. Nil for the target tab itself, a tab with several panes (`pane.move` moves one
    /// pane, so the rest would stay behind), an unknown tab, or a zoomed target, which Herdr
    /// refuses.
    func paneToSplit(fromTab tabID: String, into targetTabID: String?) -> String? {
        guard let targetTabID, tabID != targetTabID,
              tabs.contains(where: { $0.tabID == tabID }), tabs.contains(where: { $0.tabID == targetTabID }),
              layouts.first(where: { $0.tabID == targetTabID })?.zoomed != true else { return nil }
        let moving = panes.filter { $0.tabID == tabID }
        return moving.count == 1 ? moving[0].paneID : nil
    }
}

struct HerdrWorkspace: Decodable, Equatable, Identifiable {
    let workspaceID: String
    let label: String
    let agentStatus: String?
    let activeTabID: String?
    let worktree: HerdrWorktree?

    var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label, worktree
        case agentStatus = "agent_status"
        case activeTabID = "active_tab_id"
    }
}

struct HerdrWorktree: Decodable, Equatable {
    let checkoutPath: String

    enum CodingKeys: String, CodingKey {
        case checkoutPath = "checkout_path"
    }
}

struct HerdrTab: Decodable, Equatable, Identifiable {
    let tabID: String
    let workspaceID: String
    let label: String
    let agentStatus: String?

    var id: String { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label
        case agentStatus = "agent_status"
    }
}

struct HerdrPane: Decodable, Equatable, Identifiable {
    let paneID: String
    let workspaceID: String
    let tabID: String
    let cwd: String?
    let agentStatus: String?

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case cwd
        case agentStatus = "agent_status"
    }
}

struct HerdrAgent: Decodable, Equatable, Identifiable, Sendable {
    let paneID: String
    let workspaceID: String?
    let tabID: String?
    let agent: String?
    let name: String?
    let title: String?
    let terminalTitleStripped: String?
    let displayAgent: String?
    var agentStatus: String?
    let stateLabels: [String: String]?
    let tokens: [String: String]?
    var stateChangeSeq: UInt64 = 0

    var id: String { paneID }
    var displayName: String { displayAgent ?? name ?? agent ?? title ?? paneID }
    var displayStatus: String {
        let status = agentStatus ?? "unknown"
        return stateLabels?[status] ?? status
    }
    var detail: String? {
        for value in [tokens?["summary"], title, terminalTitleStripped] {
            if let value, !value.isEmpty, value != displayName { return value }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent, name, title, tokens
        case terminalTitleStripped = "terminal_title_stripped"
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
        case stateLabels = "state_labels"
        case stateChangeSeq = "state_change_seq"
    }
}

extension HerdrAgent {
    /// The JSON API uses dictionaries, while shell.snapshot.v1 uses arrays of string pairs.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try values.decode(String.self, forKey: .paneID)
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
        tabID = try values.decodeIfPresent(String.self, forKey: .tabID)
        agent = try values.decodeIfPresent(String.self, forKey: .agent)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        terminalTitleStripped = try values.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        displayAgent = try values.decodeIfPresent(String.self, forKey: .displayAgent)
        agentStatus = try values.decodeIfPresent(String.self, forKey: .agentStatus)
        stateLabels = try values.decodeIfPresent(AgentMetadata.self, forKey: .stateLabels)?.values
        tokens = try values.decodeIfPresent(AgentMetadata.self, forKey: .tokens)?.values
        stateChangeSeq = try values.decodeIfPresent(UInt64.self, forKey: .stateChangeSeq) ?? 0
    }

    private struct AgentMetadata: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dictionary = try? container.decode([String: String].self) { values = dictionary; return }
            let pairs = try container.decode([[String]].self)
            guard pairs.allSatisfy({ $0.count == 2 }) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected metadata string pairs")
            }
            values = Dictionary(pairs.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

struct HerdrLayout: Decodable, Equatable {
    let tabID: String
    let area: HerdrRect
    let panes: [HerdrLayoutPane]
    /// Whether one pane fills the tab; Herdr refuses to move panes into a zoomed tab.
    var zoomed: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case area, panes, zoomed
    }
}

struct HerdrLayoutPane: Decodable, Equatable {
    let paneID: String
    let rect: HerdrRect

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case rect
    }
}

struct HerdrRect: Decodable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct SnapshotResponse: Decodable {
    let result: SnapshotResult
}

private struct SnapshotResult: Decodable {
    let snapshot: HerdrSnapshot
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

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum HerdrSocket {
    static func open(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrSocketError.message(String(cString: strerror(errno))) }
        var noSignal: Int32 = 1
        withUnsafePointer(to: &noSignal) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
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
        guard connectionResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw HerdrSocketError.message("Cannot connect to \(path): \(message)")
        }
        return fd
    }

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
                    throw HerdrSocketError.message(error["message"] as? String ?? "Herdr request failed")
                }
                return line
            }
        }
        throw HerdrSocketError.message("Herdr response exceeded size limit")
    }

    static func snapshot(path: String) throws -> HerdrSnapshot {
        let data = try request(path: path, method: "session.snapshot")
        return try JSONDecoder().decode(SnapshotResponse.self, from: data).result.snapshot
    }

    static func paneText(path: String, paneID: String) throws -> String {
        let data = try request(path: path, method: "pane.read", params: [
            "pane_id": paneID,
            "source": "visible",
            "lines": 120
        ])
        return try JSONDecoder().decode(PaneReadResponse.self, from: data).result.read.text
    }

    static func sendInput(path: String, paneID: String, text: String? = nil, keys: [String] = []) throws {
        var params: [String: Any] = ["pane_id": paneID]
        if let text { params["text"] = text }
        if !keys.isEmpty { params["keys"] = keys }
        _ = try request(path: path, method: "pane.send_input", params: params)
    }

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
    private var handler: ((HerdrSurface?) -> Void)?

    /// Makes `owner` the only observer, for as long as it lives.
    func observe(_ owner: AnyObject, _ handler: @escaping (HerdrSurface?) -> Void) {
        observer = owner
        self.handler = handler
    }

    func publish(_ surface: HerdrSurface?) {
        self.surface = surface
        if observer == nil { handler = nil }
        handler?(surface)
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
            publishedSnapshots.send(newValue)
        }
    }
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
    @Published private(set) var surfaceLayout: HerdrSurfaceLayout?
    var surface: HerdrSurface? { surfaceFeed.surface }
    @Published private(set) var surfaceError: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var sessionSelectionError: String?
    @Published private(set) var agentViewState: HerdrAgentViewState?
    @Published private var agentPrioritySort = false
    private var agentPresentation = HerdrAgentPresentation()
    @Published var selectedWorkspaceID: String?
    @Published var selectedTabID: String?
    @Published var selectedPaneID: String? {
        didSet {
            guard let selectedTabID, let selectedPaneID,
                  snapshot?.panes.contains(where: { $0.paneID == selectedPaneID && $0.tabID == selectedTabID }) == true
            else { return }
            lastPaneByTab[selectedTabID] = selectedPaneID
        }
    }
    /// The pane last used in each tab, so returning to a tab types into the same pane.
    private var lastPaneByTab: [String: String] = [:]

    static let defaultSessionName = "default"
    private static let lastSessionKey = "HerdrLastSession"

    @Published private(set) var sessionName = UserDefaults.standard.string(forKey: lastSessionKey)
        ?? defaultSessionName
    private var eventTask: Task<Void, Never>?
    private var paneTask: Task<Void, Never>?
    private var surfaceTask: Task<Void, Never>?
    private var eventStream: HerdrEventStream?
    private var surfaceStream: HerdrSurfaceStream?
    private var generation = 0
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

    init() {
        snapshotPublisher = publishedSnapshots.eraseToAnyPublisher()
        reloadAgentViewSettings()
        if let metrics = TerminalPipelineMetrics.shared {
            publishRecorder = objectWillChange.sink { _ in metrics.published() }
        }
        #if XHERDR_PROBES
        TerminalTypingProbe.store = self
        #endif
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
        Self.sessionDirectory(sessionName).appendingPathComponent("herdr.sock").path
    }

    var isConnected: Bool { snapshot != nil && errorMessage == nil }

    var clientSocketPath: String {
        Self.sessionDirectory(sessionName).appendingPathComponent("herdr-client.sock").path
    }

    func connect(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64,
              trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            sessionSelectionError = "Use letters, numbers, hyphens, or underscores"
            return
        }
        sessionSelectionError = nil
        stop()
        sessionName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.lastSessionKey)
        snapshot = nil
        paneText = [:]
        setSurface(nil)
        surfaceError = nil
        selectedWorkspaceID = nil
        selectedTabID = nil
        selectedPaneID = nil
        errorMessage = nil
        inputError = nil
        actionError = nil
        pendingInput = []
        start()
    }

    func start() {
        guard eventTask == nil else { return }
        let path = socketPath
        let currentGeneration = generation
        eventTask = Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            while !Task.isCancelled {
                let stream = HerdrEventStream()
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
                    try stream.run(path: path) { newSnapshot in
                        Task { @MainActor in
                            guard store.generation == currentGeneration else { return }
                            store.receive(newSnapshot)
                            if store.errorMessage != nil { store.errorMessage = nil }
                            store.repairSelection()
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        guard store.generation == currentGeneration else { return }
                        store.snapshot = nil
                        store.errorMessage = message
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        paneTask = Task {
            while !Task.isCancelled {
                if let snapshot, isConnected {
                    let paneIDs = snapshot.panes.filter { $0.tabID == selectedTabID }.map(\.paneID)
                    if surface != nil && Set(paneIDs) == Set(surface?.paneIDs ?? []) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    for paneID in paneIDs {
                        let paneResult = await Task.detached(priority: .utility) {
                            Result { try HerdrSocket.paneText(path: path, paneID: paneID) }
                        }.value
                        if generation == currentGeneration, case .success(let text) = paneResult,
                           paneText[paneID] != text {
                            paneText[paneID] = text
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        let surfacePath = clientSocketPath
        surfaceTask = Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            while !Task.isCancelled {
                let stream = HerdrSurfaceStream()
                let mailbox = HerdrSurfaceMailbox()
                let size = await MainActor.run { () -> (Int, Int, Int, Int)? in
                    guard store.generation == currentGeneration else { return nil }
                    store.surfaceStream = stream
                    store.setSurface(nil)
                    store.resetAgentView()
                    return (store.surfaceCols, store.surfaceRows, store.cellWidth, store.cellHeight)
                }
                guard let size, !Task.isCancelled else { stream.cancel(); break }
                do {
                    try stream.run(path: surfacePath, cols: size.0, rows: size.1,
                                   cellWidth: size.2, cellHeight: size.3) {
                        Task { @MainActor in
                            guard store.generation == currentGeneration, store.surfaceStream === stream else { return }
                            if let tabID = store.selectedTabID {
                                stream.focus(tabID: tabID)
                            } else if let workspaceID = store.selectedWorkspaceID {
                                stream.focus(workspaceID: workspaceID)
                            }
                            if let paneID = store.selectedPaneID { stream.focus(paneID: paneID) }
                        }
                    } onSurface: { newSurface in
                        // Surfaces that arrive while the main thread is busy replace each other,
                        // so it only ever shows the newest one.
                        guard mailbox.put(newSurface) else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let latest = mailbox.take(), store.generation == currentGeneration,
                                      store.surfaceStream === stream else { return }
                                store.setSurface(latest)
                                if store.surfaceError != nil { store.surfaceError = nil }
                                TerminalPipelineMetrics.shared?.delivered(latest)
                            }
                        }
                    } onAgents: { projection in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard store.generation == currentGeneration, store.surfaceStream === stream else { return }
                                store.receiveAgentProjection(projection)
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard store.generation == currentGeneration else { return }
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

    private func setSurface(_ surface: HerdrSurface?) {
        if let surface { popupBlocksPaneInput = surface.popup != nil }
        surfaceFeed.publish(surface)
        let layout = surface.map { HerdrSurfaceLayout(bootID: $0.bootID, paneIDs: $0.paneIDs, popupTerminalID: $0.popup?.terminalID) }
        if layout != surfaceLayout { surfaceLayout = layout }
    }

    func visibleAgents(inSelectedSpaceOnly spaceOnly: Bool, followHerdrView: Bool = true) -> [HerdrAgent] {
        if let state = agentViewState, state.label != nil || state.view != nil {
            return state.agents(workspaceID: selectedWorkspaceID, tabID: selectedTabID,
                                spaceOnly: spaceOnly, followView: followHerdrView, prioritySort: agentPrioritySort)
        }
        return (snapshot?.agents ?? []).filter { !spaceOnly || $0.workspaceID == selectedWorkspaceID }
    }

    func reloadAgentViewSettings() {
        let text = (try? HerdrConfigFile.read(at: HerdrConfigFile.url)) ?? ""
        let priority = HerdrConfigDocument(text: text).string(section: "ui", key: "agent_panel_sort", default: "spaces") == "priority"
        if agentPrioritySort != priority { agentPrioritySort = priority }
    }

    func receiveAgentProjection(_ projection: HerdrAgentProjection) {
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
        agentPresentation = HerdrAgentPresentation()
        if agentViewState != nil { agentViewState = nil }
    }

    func stop() {
        popupBlocksPaneInput = false
        generation += 1
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
    }

    func select(workspaceID: String, tabID: String? = nil, paneID: String? = nil) {
        selectedWorkspaceID = workspaceID
        let tabs = snapshot?.tabs.filter { $0.workspaceID == workspaceID } ?? []
        let activeTabID = snapshot?.workspaces.first { $0.workspaceID == workspaceID }?.activeTabID
        selectedTabID = tabID ?? tabs.first { $0.tabID == activeTabID }?.tabID ?? tabs.first?.tabID
        selectedPaneID = paneID ?? preferredPane(in: selectedTabID)
        // `tab.focus` also switches the workspace; sending `workspace.focus` first can race
        // and leave the surface on the workspace's previously active tab.
        if let selectedTabID {
            surfaceStream?.focus(tabID: selectedTabID)
        } else {
            surfaceStream?.focus(workspaceID: workspaceID)
        }
        if let selectedPaneID { surfaceStream?.focus(paneID: selectedPaneID) }
    }

    func clearActionError() { actionError = nil }

    func createWorkspace(cwd: String? = nil, label: String? = nil) {
        guard isConnected else { return }
        let path = socketPath
        let source = cwd == nil ? selectedWorkspaceID : nil
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (String, HerdrSnapshot) in
                    let id = try HerdrSocket.createWorkspace(path: path, sourceWorkspaceID: source,
                                                             cwd: cwd, label: label)
                    return (id, try HerdrSocket.snapshot(path: path))
                }
            }.value
            guard generation == currentGeneration else { return }
            switch result {
            case .success(let (id, fresh)):
                snapshot = fresh
                select(workspaceID: id)
                actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
    }

    func createTab(cwd: String? = nil) {
        guard isConnected, let workspaceID = selectedWorkspaceID else { return }
        let path = socketPath
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (String, HerdrSnapshot) in
                    let id = try HerdrSocket.createTab(path: path, workspaceID: workspaceID, cwd: cwd)
                    return (id, try HerdrSocket.snapshot(path: path))
                }
            }.value
            guard generation == currentGeneration else { return }
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
        performAction(method: "pane.focus_direction", params: [
            "pane_id": paneID, "direction": direction
        ], followServerFocus: true)
    }

    func splitPane(_ direction: String) {
        guard let paneID = selectedPaneID, let workspaceID = selectedWorkspaceID else { return }
        performAction(method: "pane.split", params: [
            "workspace_id": workspaceID, "target_pane_id": paneID,
            "direction": direction, "focus": true
        ], followServerFocus: true)
    }

    func zoomPane() {
        guard let paneID = selectedPaneID else { return }
        performAction(method: "pane.zoom", params: ["pane_id": paneID], followServerFocus: false)
    }

    func renameWorkspace(_ workspaceID: String, to label: String) {
        performAction(method: "workspace.rename", params: [
            "workspace_id": workspaceID, "label": label
        ], followServerFocus: false)
    }

    func closeWorkspace(_ workspaceID: String) {
        performAction(method: "workspace.close", params: ["workspace_id": workspaceID],
                      followServerFocus: false)
    }

    /// Renames the agent in a pane; a nil name restores the detected agent name.
    func renameAgent(_ paneID: String, to name: String?) {
        performAction(method: "agent.rename", params: ["target": paneID, "name": name ?? NSNull()],
                      followServerFocus: false)
    }

    func renameTab(_ tabID: String, to label: String) {
        performAction(method: "tab.rename", params: ["tab_id": tabID, "label": label],
                      followServerFocus: false)
    }

    func closeTab(_ tabID: String) {
        performAction(method: "tab.close", params: ["tab_id": tabID], followServerFocus: false)
    }

    /// Moves a tab within its Space with `tab.move`. `insertIndex` is a gap in the Space's
    /// current tab order: 0 is before the first tab and `count` after the last, so a tab moved
    /// right goes before the tab at `insertIndex`. The new order shows at once and Herdr's
    /// snapshot, read right after, replaces it.
    func moveTab(_ tabID: String, to insertIndex: Int) {
        guard isConnected, let current = snapshot, let moved = current.movingTab(tabID, to: insertIndex) else { return }
        snapshot = moved
        let path = socketPath
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Void in
                    _ = try HerdrSocket.request(path: path, method: "tab.move",
                                                params: ["tab_id": tabID, "insert_index": insertIndex])
                }
            }.value
            // Read Herdr's order even when the move failed, to undo the one shown.
            let fresh = await Task.detached(priority: .userInitiated) { try? HerdrSocket.snapshot(path: path) }.value
            guard generation == currentGeneration else { return }
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
        isConnected && snapshot?.paneToSplit(fromTab: tabID, into: selectedTabID) != nil
    }

    /// Moves the only pane of tab `tabID` into the selected tab next to `targetPaneID`, on its
    /// `edge`, and selects it. Herdr splits only right or down, so left and top split that way
    /// and then swap the two panes, which mirrors the new split at any depth of the layout.
    /// Herdr closes the emptied tab itself. The snapshot is read once, after both requests.
    /// Returns false, sending nothing, when the drop is not allowed.
    @discardableResult
    func splitTab(_ tabID: String, nextTo targetPaneID: String, edge: TerminalDropEdge) -> Bool {
        guard isConnected, let into = selectedTabID, let snapshot,
              let paneID = snapshot.paneToSplit(fromTab: tabID, into: into),
              snapshot.panes.contains(where: { $0.paneID == targetPaneID && $0.tabID == into }) else { return false }
        let path = socketPath
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Void in
                    let moved = try HerdrSocket.request(path: path, method: "pane.move", params: [
                        "pane_id": paneID,
                        "destination": ["type": "tab", "tab_id": into, "split": edge.split,
                                        "target_pane_id": targetPaneID] as [String: Any],
                        "focus": true
                    ])
                    try Self.requireChange(moved, in: "move_result", doing: "move the pane")
                    guard edge.swapsAfterMove else { return }
                    let swapped = try HerdrSocket.request(path: path, method: "pane.swap", params: [
                        "source_pane_id": paneID, "target_pane_id": targetPaneID
                    ])
                    try Self.requireChange(swapped, in: "swap", doing: "place the pane on that side")
                }
            }.value
            // Read Herdr's layout even after a failure, which may follow a successful move.
            let fresh = await Task.detached(priority: .userInitiated) { try? HerdrSocket.snapshot(path: path) }.value
            guard generation == currentGeneration else { return }
            if let fresh {
                self.snapshot = fresh
                if selectedTabID == into, fresh.panes.contains(where: { $0.paneID == paneID && $0.tabID == into }) {
                    selectedPaneID = paneID
                    surfaceStream?.focus(paneID: paneID)
                }
                repairSelection()
            }
            switch result {
            case .success: actionError = nil
            case .failure(let error): actionError = error.localizedDescription
            }
        }
        return true
    }

    /// Herdr answers a move or swap it did not make with `changed: false` and a reason, not an error.
    nonisolated private static func requireChange(_ response: Data, in key: String, doing action: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = (root["result"] as? [String: Any])?[key] as? [String: Any] else {
            throw HerdrSocketError.message("Unexpected response from Herdr")
        }
        guard result["changed"] as? Bool != true else { return }
        let reason = (result["reason"] as? String)?.replacingOccurrences(of: "_", with: " ")
        throw HerdrSocketError.message("Herdr could not \(action)" + (reason.map { ": \($0)" } ?? ""))
    }

    func closePane(_ paneID: String) {
        performAction(method: "pane.close", params: ["pane_id": paneID], followServerFocus: false)
    }

    func reloadConfig() {
        guard isConnected else { return }
        let path = socketPath
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Void in
                    let data = try HerdrSocket.request(path: path, method: "server.reload_config")
                    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let response = root["result"] as? [String: Any],
                          let status = response["status"] as? String else {
                        throw HerdrConfigError.validation("Unexpected response from Herdr reload")
                    }
                    if status != "applied" {
                        let details = (response["diagnostics"] as? [String] ?? []).joined(separator: "\n")
                        throw HerdrConfigError.validation("Herdr reload: \(status). \(details)")
                    }
                }
            }.value
            guard generation == currentGeneration else { return }
            if case .failure(let error) = result { actionError = error.localizedDescription }
            else { actionError = nil }
        }
    }

    private func performAction(method: String, params: [String: Any], followServerFocus: Bool) {
        guard isConnected else { return }
        let path = socketPath
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> HerdrSnapshot in
                    _ = try HerdrSocket.request(path: path, method: method, params: params)
                    return try HerdrSocket.snapshot(path: path)
                }
            }.value
            guard generation == currentGeneration else { return }
            switch result {
            case .success(let fresh):
                snapshot = fresh
                if followServerFocus, let workspaceID = fresh.focusedWorkspaceID {
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
        selectedTabID = tabID
        selectedPaneID = preferredPane(in: tabID)
        surfaceStream?.focus(tabID: tabID)
        if let selectedPaneID { surfaceStream?.focus(paneID: selectedPaneID) }
    }

    private func preferredPane(in tabID: String?) -> String? {
        guard let tabID else { return nil }
        let panes = snapshot?.panes.filter { $0.tabID == tabID } ?? []
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
        // focuses, so a click there would cost a full frame (45 KB at 126x48).
        if snapshot?.focusedPaneID != paneID { surfaceStream?.focus(paneID: paneID) }
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

    func setSplitRatio(path: [Bool], ratio: Double) {
        guard let tabID = selectedTabID, ratio.isFinite else { return }
        // Called up to 30 times a second while a split is dragged, so an unchanged error is not published again.
        if surfaceStream?.setSplitRatio(tabID: tabID, path: path, ratio: ratio) != true {
            setIfChanged(\.surfaceError, "Herdr split resize is unavailable")
        }
    }

    private func enqueueInput(paneID: String, event: HerdrInputEvent) {
        guard !popupBlocksPaneInput else { return }
        enqueueInput(PendingInput(paneID: paneID, event: event))
    }

    private func enqueueInput(_ input: PendingInput) {
        guard isConnected else { return }
        pendingInput.append(input)
        guard inputTask == nil else { return }
        let path = socketPath
        let currentGeneration = generation
        inputTask = Task {
            while !pendingInput.isEmpty && !Task.isCancelled {
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
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try HerdrSocket.sendInput(path: path, paneID: item.paneID, text: text, keys: keys) }
                }.value
                guard generation == currentGeneration else { break }
                if case .failure(let error) = result {
                    setIfChanged(\.inputError, error.localizedDescription)
                } else {
                    setIfChanged(\.inputError, nil)
                }
            }
            if generation == currentGeneration { inputTask = nil }
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
        if onlyLayouts, let surfaceLayout, !tabPanes.isEmpty, Set(surfaceLayout.paneIDs) == tabPanes {
            snapshotValue = newSnapshot
        } else {
            snapshot = newSnapshot
        }
    }

    /// Assigns a published value only when it differs: any assignment, even of the same value,
    /// makes SwiftUI update every view that observes the store.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HerdrStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func repairSelection() {
        guard let snapshot else { return }
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
    }
}

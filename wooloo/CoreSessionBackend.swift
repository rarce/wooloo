import Foundation

/// How to reach a core: the command whose stdio speaks the protocol (`hc connect --session`,
/// locally or at the end of an `ssh` command), and the line a remote script prints before it.
struct CoreTarget: Hashable, Sendable {
    let executable: String
    let arguments: [String]
    let banner: String?

    static let banner = "wooloo-core-ready"

    static func local(hc: String, session: String) -> CoreTarget {
        CoreTarget(executable: hc, arguments: ["connect", "--session", session], banner: nil)
    }
}

/// A herdr-core session (Phase 3 of docs/proposals/herdr-core-backend.md). Core keeps terminals,
/// not layout: until wooloo's structure document arrives (Phase 5), every terminal of the core
/// is a tab of one Space named after the core, with one pane. Live terminal surfaces arrive in
/// Phase 4; until then panes show `terminal.read` text, and typing goes through a short attach.
final class CoreSessionBackend: SessionBackend, @unchecked Sendable {
    static let spaceID = "core"
    static let capabilities = BackendCapabilities(
        zoomedTabsRefuseMoves: false, onlySinglePaneTabsMove: true, movesTabsBetweenSpaces: false,
        opensWorktrees: false, serverAgentViews: false, reloadsConfig: false, serverScrollback: false)

    let target: CoreTarget
    private let makeTransport: @Sendable (CoreTarget) throws -> CoreTransport
    private let lock = NSLock()
    private var shared: CoreConnection?

    init(target: CoreTarget,
         makeTransport: @escaping @Sendable (CoreTarget) throws -> CoreTransport = {
             try ProcessCoreTransport(executable: $0.executable, arguments: $0.arguments)
         }) {
        self.target = target
        self.makeTransport = makeTransport
    }

    var kind: BackendKind { .core }
    /// The core's identity, once a connection has said hello.
    var core: CoreInfo? { lock.withLock { shared?.hello?.core } }

    /// A new connection, after its handshake.
    func connect() throws -> CoreConnection {
        let connection = CoreConnection(transport: try makeTransport(target))
        do { try connection.open(banner: target.banner) } catch { connection.close(); throw error }
        return connection
    }

    /// The connection commands share, reopened after it ends.
    func connection() throws -> CoreConnection {
        if let current = lock.withLock({ shared }), !current.isClosed { return current }
        let fresh = try connect()
        lock.withLock { shared = fresh }
        return fresh
    }

    func disconnect() {
        let current = lock.withLock { () -> CoreConnection? in defer { shared = nil }; return shared }
        current?.close()
    }

    // MARK: - State

    func snapshot() throws -> HerdrSnapshot {
        let connection = try connection()
        let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
        return Self.snapshot(of: list.terminals, core: connection.hello?.core)
    }

    /// The state `HerdrStore` keeps, built from the core's live terminals.
    static func snapshot(of terminals: [CoreTerminal], core: CoreInfo?) -> HerdrSnapshot {
        let live = terminals.filter { $0.state == "live" && !$0.address.contains("/") }
        let space = spaceID
        let tabs = live.map { HerdrTab(tabID: $0.address, workspaceID: space, label: label(of: $0),
                                       agentStatus: $0.status?.state) }
        let panes = live.map { HerdrPane(paneID: $0.address, workspaceID: space, tabID: $0.address, cwd: $0.cwd,
                                         agentStatus: $0.status?.state) }
        let agents = live.compactMap { terminal -> HerdrAgent? in
            guard let status = terminal.status else { return nil }
            return HerdrAgent(paneID: terminal.address, workspaceID: space, tabID: terminal.address,
                              agent: status.app, name: terminal.name, title: status.msg ?? terminal.title,
                              terminalTitleStripped: nil, displayAgent: status.app, agentStatus: status.state,
                              stateLabels: nil, tokens: nil, stateChangeSeq: terminal.turn ?? 0)
        }
        let layouts = live.map { terminal -> HerdrLayout in
            let area = HerdrRect(x: 0, y: 0, width: max(terminal.cols, 1), height: max(terminal.rows, 1))
            return HerdrLayout(tabID: terminal.address, area: area,
                               panes: [HerdrLayoutPane(paneID: terminal.address, rect: area)], zoomed: false)
        }
        let workspace = HerdrWorkspace(workspaceID: space, label: core?.name ?? "herdr-core", agentStatus: nil,
                                       activeTabID: live.first?.address, worktree: nil)
        return HerdrSnapshot(workspaces: [workspace], tabs: tabs, panes: panes, agents: agents, layouts: layouts,
                             focusedWorkspaceID: space, focusedTabID: live.first?.address,
                             focusedPaneID: live.first?.address)
    }

    /// A tab's name: one wooloo gave it, the terminal's name, or its program.
    static func label(of terminal: CoreTerminal) -> String {
        if let label = terminal.labels["wooloo.name"], !label.isEmpty { return label }
        if let name = terminal.name, !name.isEmpty { return name }
        if let title = terminal.title, !title.isEmpty { return title }
        return terminal.argv.first.map { ($0 as NSString).lastPathComponent } ?? terminal.address
    }

    func makeWatcher() -> any SessionWatcher { CoreSessionWatcher(backend: self) }

    func paneDirectory(_ paneID: String) throws -> String? {
        let list = try connection().call("terminal.list", [:], as: CoreListResult.self)
        return list.terminals.first { $0.address == paneID }?.cwd
    }

    func paneText(_ paneID: String) throws -> String {
        try connection().call("terminal.read", ["terminal": paneID, "lines": 0], as: CoreReadResult.self).text
    }

    /// Named keys go through `terminal.keys`, which encodes them for the program's keyboard
    /// modes. Text needs a stream: a short attach at the terminal's own size, so the size stays.
    func sendInput(to paneID: String, text: String?, keys: [String]) throws {
        let connection = try connection()
        if !keys.isEmpty {
            struct Keys: Decodable { let turn: UInt64 }
            _ = try connection.call("terminal.keys", ["terminal": paneID, "keys": keys], as: Keys.self)
        }
        guard let text, !text.isEmpty else { return }
        let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
        guard let terminal = list.terminals.first(where: { $0.address == paneID }) else {
            throw CoreProtocolError.remote(kind: "not_found", message: "The terminal \(paneID) is gone.")
        }
        let attached = try connection.call("terminal.attach", [
            "terminal": paneID, "cols": max(terminal.cols, 1), "rows": max(terminal.rows, 1), "history": 0,
        ], as: CoreAttachResult.self)
        connection.route(channel: attached.channel, onData: { _ in }, onClose: {})
        try connection.send(CoreFrame(channel: attached.channel, kind: .data, payload: Data(text.utf8)))
        try connection.send(CoreFrame(channel: attached.channel, kind: .close, payload: Data()))
    }

    // MARK: - Commands

    func perform(_ command: SessionCommand) throws {
        let connection = try connection()
        switch command {
        case .closePane(let id), .closeTab(let id):
            _ = try connection.callRaw("terminal.kill", ["terminal": id])
        case let .renameTab(id, label):
            _ = try connection.callRaw("terminal.label", ["terminal": id, "labels": ["wooloo.name": label]])
        case let .renameAgent(paneID, name):
            _ = try connection.callRaw("terminal.label", ["terminal": paneID, "labels": ["wooloo.name": name ?? ""]])
        case .focusPane: return
        case .splitPane: throw CoreProtocolError.unsupported("split panes")
        case .zoomPane: throw CoreProtocolError.unsupported("zoom panes")
        case .renameSpace: throw CoreProtocolError.unsupported("rename Spaces")
        case .closeSpace: throw CoreProtocolError.unsupported("close Spaces")
        case .moveTab: throw CoreProtocolError.unsupported("reorder tabs")
        case .reloadConfig: throw CoreProtocolError.unsupported("reload the configuration")
        }
    }

    /// Every new Space, worktree Space or tab is a new shell terminal; it shows as a tab of the
    /// core's Space, which answers for Spaces.
    func create(_ item: SessionCreation) throws -> String {
        let cwd: String?
        switch item {
        case let .space(_, folder, _): cwd = folder
        case let .worktreeSpace(checkout, _): cwd = checkout
        case let .tab(_, folder): cwd = folder
        }
        var params: [String: Any] = ["no_parent": true, "labels": ["wooloo.space": Self.spaceID]]
        if let cwd { params["cwd"] = cwd }
        let terminal = try connection().call("terminal.run", params, as: CoreTerminal.self)
        if case .tab = item { return terminal.address }
        return Self.spaceID
    }

    func moveSpace(_ spaceID: String, beside anchorID: String, after: Bool,
                   checkpoint: @Sendable () throws -> Void) throws {
        throw CoreProtocolError.unsupported("reorder Spaces")
    }

    func moveTab(_ tabID: String, toSpace spaceID: String?, lastTabWasChecked: Bool,
                 checkpoint: @Sendable () throws -> Void) throws -> WoolooPane {
        throw CoreProtocolError.unsupported("move tabs between Spaces")
    }

    func movePane(_ paneID: String, to destination: PaneDestination,
                  checkpoint: @Sendable () throws -> Void) throws {
        throw CoreProtocolError.unsupported("move panes")
    }
}

/// Follows a core on a connection of its own: an unfiltered `events.subscribe`, then a fresh
/// terminal list after each change. A heartbeat arrives every 15 s when nothing changes, so
/// 45 s of silence means the connection is gone even if the transport has not noticed.
final class CoreSessionWatcher: SessionWatcher, @unchecked Sendable {
    static let silenceLimit: TimeInterval = 45

    private let backend: CoreSessionBackend
    private let lock = NSLock()
    private var connection: CoreConnection?
    private var cancelled = false

    init(backend: CoreSessionBackend) { self.backend = backend }

    func run(onChange: @escaping @Sendable (HerdrSnapshot) -> Void) throws {
        let connection = try backend.connect()
        let proceed = lock.withLock { () -> Bool in
            self.connection = connection
            return !cancelled
        }
        guard proceed else { connection.close(); return }
        defer { connection.close() }
        let changes = DispatchSemaphore(value: 0)
        let pending = PendingFlag()
        let subscribed = try connection.call("events.subscribe", [:], as: CoreSubscribeResult.self)
        if let channel = subscribed.channel {
            var lines = CoreEventLines()
            connection.route(channel: channel, onData: { data in
                // Heartbeats and document events need no new terminal list.
                if lines.append(data).contains(where: { $0.type != nil && $0.type != "doc" }) {
                    pending.set()
                }
                changes.signal()
            }, onClose: { changes.signal() })
        }
        onChange(CoreSessionBackend.snapshot(of: subscribed.terminals, core: connection.hello?.core))
        while true {
            _ = changes.wait(timeout: .now() + 5)
            if lock.withLock({ cancelled }) { return }
            if connection.isClosed { throw CoreProtocolError.closed }
            if Date().timeIntervalSince(connection.lastActivity) > Self.silenceLimit {
                throw CoreProtocolError.timedOut("events.subscribe")
            }
            if pending.take() {
                let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
                onChange(CoreSessionBackend.snapshot(of: list.terminals, core: connection.hello?.core))
            }
        }
    }

    func cancel() {
        let connection = lock.withLock { () -> CoreConnection? in
            cancelled = true
            return self.connection
        }
        connection?.close()
    }
}

private final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func take() -> Bool { lock.withLock { defer { value = false }; return value } }
}

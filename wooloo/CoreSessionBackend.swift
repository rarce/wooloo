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

/// A herdr-core session (docs/proposals/herdr-core-backend.md, Phases 3 and 5). Core keeps
/// terminals, not layout: wooloo arranges them in Spaces, tabs and splits in its own `wooloo`
/// document in the core (`CoreStructure`), and every change to that arrangement is a
/// compare-and-set write. Terminals no tab holds appear in the Space their label names, or in
/// Unfiled. Live terminals are drawn by `CoreTerminalPresentation`; `paneText` and
/// `sendInput` are the fallback while no live surface is up.
final class CoreSessionBackend: SessionBackend, @unchecked Sendable {
    static let capabilities = BackendCapabilities(
        zoomedTabsRefuseMoves: false, onlySinglePaneTabsMove: false, movesTabsBetweenSpaces: true,
        opensWorktrees: true, serverAgentViews: false, reloadsConfig: false, serverScrollback: false)

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

    /// The core's terminals with wooloo's arrangement of them, read on `connection`.
    struct Arrangement {
        let terminals: [CoreTerminal]
        let structure: CoreStructure
        let document: Any?
        let version: Int
    }

    func arrangement(on connection: CoreConnection) throws -> Arrangement {
        // The document first: every terminal it names was started before the list is taken,
        // so a Space another window just wrote is not dropped as having no live terminal.
        let (document, version) = try Self.document(on: connection)
        let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
        // The official app's structure, read only; a core without it, or a broken one, adds nothing.
        let app = try? Self.document(HerdrAppStructure.documentName, on: connection).0
        let structure = (CoreStructure.decode(document) ?? CoreStructure()).reconciled(with: list.terminals, app: app)
        return Arrangement(terminals: list.terminals, structure: structure, document: document, version: version)
    }

    static func document(_ name: String = CoreStructure.documentName, on connection: CoreConnection) throws -> (Any?, Int) {
        let reply = try connection.callRaw("doc.get", ["name": name])
        _ = try CoreConnection.result(DocVersion.self, from: reply)
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let value = result?["value"]
        return (value is NSNull ? nil : value, result?["version"] as? Int ?? 0)
    }

    private struct DocVersion: Decodable { let version: Int }

    /// Changes the arrangement with compare-and-set on the document's version: a write that
    /// lost to another client reads the document again and applies `change` to it, at most
    /// three times. `change` sees the reconciled arrangement and the live terminals.
    @discardableResult
    func mutate<Result>(_ change: (inout CoreStructure, [CoreTerminal]) throws -> Result) throws -> Result {
        let connection = try connection()
        for attempt in 0..<3 {
            let current = try arrangement(on: connection)
            var structure = current.structure
            let result = try change(&structure, current.terminals)
            // The app's Spaces stay the app's until a change touches one; then wooloo keeps it.
            structure.spaces.removeAll { space in
                space.id.hasPrefix(HerdrAppStructure.idPrefix) && current.structure.spaces.contains(space)
            }
            let value = structure.encoded(over: current.document)
            // A change that leaves the document as it is writes nothing, so other windows are
            // not sent a `doc` event or made to retry their own writes.
            if (current.document as? NSDictionary)?.isEqual(to: value) == true { return result }
            do {
                _ = try connection.call("doc.set", ["name": CoreStructure.documentName, "value": value,
                                                    "version": current.version], as: DocVersion.self)
                return result
            } catch CoreProtocolError.remote(kind: "conflict", _) where attempt < 2 {
                continue
            }
        }
        throw CoreProtocolError.remote(kind: "conflict", message: "Another client kept changing the layout. Try again.")
    }

    /// Where the window should go after the last split or new tab, shown once.
    private var pendingFocus: (space: String, tab: String, pane: String)?

    /// The pane each tab shows alone. Zoom is this window's own view (one backend per store),
    /// so it is not written to the shared document.
    private var zoomed: [String: String] = [:]

    func zoomedPane(in tabID: String) -> String? { lock.withLock { zoomed[tabID] } }

    /// The state after a command: it carries the focus a split asks for, once.
    func snapshot() throws -> HerdrSnapshot {
        let connection = try connection()
        let focus = lock.withLock { () -> (space: String, tab: String, pane: String)? in
            defer { pendingFocus = nil }
            return pendingFocus
        }
        return try snapshot(on: connection, focus: focus)
    }

    /// The state the watcher reports, which never moves the window's focus.
    func snapshot(on connection: CoreConnection,
                  focus: (space: String, tab: String, pane: String)? = nil) throws -> HerdrSnapshot {
        let current = try arrangement(on: connection)
        let zoom = lock.withLock { () -> [String: String] in
            // A zoomed pane that left its tab ends the zoom.
            zoomed = zoomed.filter { tab, pane in
                current.structure.tab(tab).map { current.structure.spaces[$0.space].tabs[$0.tab].root.terminals.contains(pane) } == true
            }
            return zoomed
        }
        return Self.snapshot(of: current.structure, terminals: current.terminals, core: connection.hello?.core,
                             focus: focus, zoomed: zoom)
    }

    /// The state `HerdrStore` keeps, from wooloo's arrangement of the core's live terminals.
    static func snapshot(of structure: CoreStructure, terminals: [CoreTerminal], core: CoreInfo?,
                         focus: (space: String, tab: String, pane: String)? = nil,
                         zoomed: [String: String] = [:]) -> HerdrSnapshot {
        let byAddress = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var workspaces: [HerdrWorkspace] = [], tabs: [HerdrTab] = [], panes: [HerdrPane] = []
        var agents: [HerdrAgent] = [], layouts: [HerdrLayout] = []
        for space in structure.spaces {
            workspaces.append(HerdrWorkspace(workspaceID: space.id, label: space.name, agentStatus: nil,
                                             activeTabID: space.tabs.first?.id,
                                             worktree: structure.worktrees[space.id].map { HerdrWorktree(checkoutPath: $0) }))
            for tab in space.tabs {
                let addresses = tab.root.terminals
                let first = addresses.first.flatMap { byAddress[$0] }
                tabs.append(HerdrTab(tabID: tab.id, workspaceID: space.id,
                                     label: tab.name ?? first.map(label(of:)) ?? "Terminal", agentStatus: nil))
                let area = HerdrRect(x: 0, y: 0, width: max(first?.cols ?? 80, 1), height: max(first?.rows ?? 24, 1))
                let zoom = zoomed[tab.id]
                let placed = Dictionary(CoreLayout.panes(CoreLayout.visible(tab.root, zoomed: zoom), in: area)
                    .map { ($0.terminal, $0.rect) }, uniquingKeysWith: { first, _ in first })
                let hidden = HerdrRect(x: 0, y: 0, width: 0, height: 0)
                layouts.append(HerdrLayout(tabID: tab.id, area: area,
                                           panes: addresses.map { HerdrLayoutPane(paneID: $0, rect: placed[$0] ?? hidden) },
                                           zoomed: zoom != nil))
                for address in addresses {
                    let terminal = byAddress[address]
                    let state = terminal.flatMap(agentState)
                    panes.append(HerdrPane(paneID: address, workspaceID: space.id, tabID: tab.id,
                                           cwd: terminal?.cwd, agentStatus: state))
                    if let terminal, let status = terminal.status {
                        agents.append(HerdrAgent(paneID: address, workspaceID: space.id, tabID: tab.id,
                                                 agent: status.app, name: terminal.name, title: status.msg ?? terminal.title,
                                                 terminalTitleStripped: nil,
                                                 displayAgent: terminal.labels["wooloo.name"].flatMap { $0.isEmpty ? nil : $0 } ?? status.app,
                                                 agentStatus: state, stateLabels: nil, tokens: nil,
                                                 stateChangeSeq: terminal.turn ?? 0,
                                                 pinned: terminal.labels["herdr.pinned"] == "1"))
                    }
                }
            }
        }
        _ = core
        return HerdrSnapshot(workspaces: workspaces, tabs: tabs, panes: panes, agents: agents, layouts: layouts,
                             focusedWorkspaceID: focus?.space, focusedTabID: focus?.tab, focusedPaneID: focus?.pane)
    }

    /// An agent's state as wooloo shows it: blocked and working as reported; otherwise done
    /// while a finished turn has not been seen (`herdr.seen`, as herdr-app's labels document
    /// says), else idle. Without the label, the report stands.
    static func agentState(_ terminal: CoreTerminal) -> String? {
        guard let state = terminal.status?.state else { return nil }
        switch state {
        case "blocked", "working", "error": return state
        default:
            guard let seen = terminal.labels["herdr.seen"].flatMap(UInt64.init) else { return state }
            return (terminal.turn ?? 0) > seen ? "done" : "idle"
        }
    }

    /// Records that a person looked at a terminal's last finished turn, for every client that
    /// reads `herdr.seen`. Only raises it, as the labels document asks.
    func markSeen(_ terminal: String) throws {
        let connection = try connection()
        let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
        guard let record = list.terminals.first(where: { $0.address == terminal }), let turn = record.turn else { return }
        if let seen = record.labels["herdr.seen"].flatMap(UInt64.init), seen >= turn { return }
        _ = try connection.callRaw("terminal.label", ["terminal": terminal, "labels": ["herdr.seen": String(turn)]])
    }

    /// Shows a terminal's last finished turn as unread again, for every client: labels.md's
    /// "a lower write means mark unread" (`herdr.seen` = turn − 1).
    func markUnread(_ terminal: String) throws {
        let connection = try connection()
        let list = try connection.call("terminal.list", [:], as: CoreListResult.self)
        guard let turn = list.terminals.first(where: { $0.address == terminal })?.turn, turn > 0 else { return }
        _ = try connection.callRaw("terminal.label", ["terminal": terminal, "labels": ["herdr.seen": String(turn - 1)]])
    }

    /// Pins or unpins an agent with labels.md's `herdr.pinned=1`; an empty value removes a label.
    func setPinned(_ terminal: String, _ pinned: Bool) throws {
        _ = try connection().callRaw("terminal.label", ["terminal": terminal, "labels": ["herdr.pinned": pinned ? "1" : ""]])
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

    /// Starts a shell terminal filed under `space`. `keep` has the core put a fresh shell at
    /// the same address when the program is lost, so a pane comes back after the core restarts.
    private func run(in space: String, cwd: String?) throws -> String {
        var params: [String: Any] = ["no_parent": true, "keep": true, "labels": [CoreStructure.spaceLabel: space]]
        if let cwd { params["cwd"] = cwd }
        return try connection().call("terminal.run", params, as: CoreTerminal.self).address
    }

    private func kill(_ terminals: [String]) throws {
        let connection = try connection()
        for terminal in terminals { _ = try connection.callRaw("terminal.kill", ["terminal": terminal]) }
    }

    private func folder(of space: String) throws -> String? {
        let current = try arrangement(on: try connection())
        guard let found = current.structure.spaces.first(where: { $0.id == space }) else { return nil }
        if let folder = found.folder { return folder }
        let first = found.tabs.first?.root.terminals.first
        return current.terminals.first { $0.address == first }?.cwd
    }

    func perform(_ command: SessionCommand) throws {
        switch command {
        case .closePane(let id):
            try kill([id])
        case .closeTab(let id):
            let terminals = try mutate { structure, _ -> [String] in
                guard let (s, t) = structure.tab(id) else { return [] }
                return structure.spaces[s].tabs.remove(at: t).root.terminals
            }
            try kill(terminals)
        case .closeSpace(let id):
            let terminals = try mutate { structure, _ -> [String] in
                guard let index = structure.spaces.firstIndex(where: { $0.id == id }) else { return [] }
                return structure.spaces.remove(at: index).tabs.flatMap(\.root.terminals)
            }
            try kill(terminals)
        case let .renameTab(id, label):
            try mutate { structure, _ in
                if let (s, t) = structure.tab(id) { structure.spaces[s].tabs[t].name = label }
            }
        case let .renameSpace(id, label):
            try mutate { structure, _ in
                if let index = structure.spaces.firstIndex(where: { $0.id == id }) { structure.spaces[index].name = label }
            }
        case let .renameAgent(paneID, name):
            _ = try connection().callRaw("terminal.label", ["terminal": paneID, "labels": ["wooloo.name": name ?? ""]])
        case let .splitPane(spaceID, paneID, direction):
            let cwd = try arrangement(on: try connection()).terminals.first { $0.address == paneID }?.cwd
            let new = try run(in: spaceID, cwd: cwd)
            let tab = try mutate { structure, _ -> String? in
                // Reconciliation files the new terminal as a loose tab until this write places it.
                for index in structure.spaces.indices {
                    structure.spaces[index].tabs.removeAll { $0.root.terminals == [new] }
                }
                guard let (s, t) = structure.tab(of: paneID) else { return nil }
                structure.spaces[s].tabs[t].root = structure.spaces[s].tabs[t].root
                    .splitting(paneID, with: new, direction: direction == "down" ? .down : .right)
                return structure.spaces[s].tabs[t].id
            }
            if let tab { lock.withLock { pendingFocus = (spaceID, tab, new) } }
        case let .moveTab(tabID, insertIndex):
            try mutate { structure, _ in
                guard let (s, from) = structure.tab(tabID), (0...structure.spaces[s].tabs.count).contains(insertIndex),
                      insertIndex != from, insertIndex != from + 1 else { return }
                let tab = structure.spaces[s].tabs.remove(at: from)
                structure.spaces[s].tabs.insert(tab, at: insertIndex > from ? insertIndex - 1 : insertIndex)
            }
        case .focusPane: return
        case .zoomPane(let paneID):
            let structure = try arrangement(on: try connection()).structure
            guard let (s, t) = structure.tab(of: paneID) else { return }
            let tab = structure.spaces[s].tabs[t]
            guard tab.root.terminals.count > 1 else { return }
            lock.withLock { zoomed[tab.id] = zoomed[tab.id] == paneID ? nil : paneID }
        case .reloadConfig: throw CoreProtocolError.unsupported("reload the configuration")
        }
    }

    /// New Spaces and tabs start a shell terminal and record it in the arrangement.
    func create(_ item: SessionCreation) throws -> String {
        switch item {
        case let .space(source, cwd, label):
            let start = try cwd ?? source.flatMap { try self.folder(of: $0) }
            return try newSpace(folder: start, name: label)
        case let .worktreeSpace(checkout, _):
            // Each checkout has one Space, as with Herdr's `worktree.open`: the checkout's Space,
            // even one another window opened since this window's last snapshot, or else a
            // Space of wooloo's already open on that folder, which becomes the checkout's.
            let structure = try arrangement(on: connection()).structure
            if let open = Self.worktreeSpace(of: checkout, in: structure) { return open }
            if structure.spaces.contains(where: { Self.adoptable($0, checkout: checkout, in: structure) }) {
                let adopted = try mutate { structure, _ -> String? in
                    if let open = Self.worktreeSpace(of: checkout, in: structure) { return open }
                    guard let space = structure.spaces.first(where: { Self.adoptable($0, checkout: checkout, in: structure) })
                    else { return nil }
                    structure.worktrees[space.id] = checkout
                    return space.id
                }
                if let adopted { return adopted }
            }
            return try newSpace(folder: checkout, name: (checkout as NSString).lastPathComponent, worktree: true)
        case let .tab(spaceID, cwd):
            let address = try run(in: spaceID, cwd: try cwd ?? self.folder(of: spaceID))
            let tabID = CoreStructure.newID()
            try mutate { structure, _ in
                if let index = structure.spaces.firstIndex(where: { $0.id == spaceID }) {
                    structure.spaces[index].tabs.removeAll { $0.root.terminals == [address] }
                    structure.spaces[index].tabs.append(.init(id: tabID, name: nil, root: .terminal(address)))
                }
            }
            return tabID
        }
    }

    /// The Space of a Git worktree checkout, if one is recorded.
    static func worktreeSpace(of checkout: String, in structure: CoreStructure) -> String? {
        structure.spaces.first { structure.worktrees[$0.id] == checkout }?.id
    }

    /// Whether `space` may become `checkout`'s Space: one of wooloo's own, open on that folder,
    /// with no checkout recorded. The app's Spaces stay the app's, and Unfiled is no folder's.
    static func adoptable(_ space: CoreStructure.Space, checkout: String, in structure: CoreStructure) -> Bool {
        space.folder == checkout && structure.worktrees[space.id] == nil
            && space.id != CoreStructure.unfiledID && !space.id.hasPrefix(HerdrAppStructure.idPrefix)
    }

    /// Starts a Space with one shell. For a worktree, a Space another window recorded for the
    /// checkout while this shell started wins, also on a retried write, and the shell is closed.
    private func newSpace(folder: String?, name: String?, worktree: Bool = false) throws -> String {
        let spaceID = CoreStructure.newID()
        let address = try run(in: spaceID, cwd: folder)
        let fallback = folder.map { ($0 as NSString).lastPathComponent } ?? "Space"
        let placed = try mutate { structure, _ -> String in
            for index in structure.spaces.indices { structure.spaces[index].tabs.removeAll { $0.root.terminals == [address] } }
            structure.spaces.removeAll { $0.tabs.isEmpty }
            if worktree, let folder, let open = Self.worktreeSpace(of: folder, in: structure) { return open }
            structure.spaces.append(.init(id: spaceID, name: name ?? fallback, folder: folder,
                                          tabs: [.init(id: CoreStructure.newID(), name: nil, root: .terminal(address))]))
            if worktree, let folder { structure.worktrees[spaceID] = folder }
            return spaceID
        }
        // The Space is open either way; a shell that failed to close shows in Unfiled.
        if placed != spaceID { _ = try? kill([address]) }
        return placed
    }

    func moveSpace(_ spaceID: String, beside anchorID: String, after: Bool,
                   checkpoint: @Sendable () throws -> Void) throws {
        try checkpoint()
        try mutate { structure, _ in
            guard let from = structure.spaces.firstIndex(where: { $0.id == spaceID }),
                  let anchor = structure.spaces.firstIndex(where: { $0.id == anchorID }) else { return }
            let gap = anchor + (after ? 1 : 0)
            guard gap != from, gap != from + 1 else { return }
            let space = structure.spaces.remove(at: from)
            structure.spaces.insert(space, at: gap > from ? gap - 1 : gap)
        }
    }

    func moveTab(_ tabID: String, toSpace spaceID: String?, lastTabWasChecked: Bool,
                 checkpoint: @Sendable () throws -> Void) throws -> WoolooPane {
        try checkpoint()
        return try mutate { structure, terminals -> WoolooPane in
            guard let (s, t) = structure.tab(tabID) else { throw SessionMoveError(message: "The source tab disappeared.") }
            if structure.spaces[s].tabs.count == 1, !lastTabWasChecked {
                throw SessionMoveError(message: "The source Space changed. Try the drag again.")
            }
            let source = structure.spaces[s]
            let tab = structure.spaces[s].tabs.remove(at: t)
            let destination: String
            if let spaceID {
                guard let index = structure.spaces.firstIndex(where: { $0.id == spaceID }) else {
                    throw SessionMoveError(message: "The destination Space disappeared.")
                }
                structure.spaces[index].tabs.append(tab)
                destination = spaceID
            } else {
                destination = CoreStructure.newID()
                let name = tab.name ?? tab.root.terminals.first.flatMap { address in
                    terminals.first { $0.address == address }.map(Self.label(of:))
                } ?? source.name
                structure.spaces.append(.init(id: destination, name: name, folder: source.folder, tabs: [tab]))
                // A worktree Space's only tab takes the checkout to its new Space.
                if source.tabs.count == 1, let checkout = structure.worktrees.removeValue(forKey: source.id) {
                    structure.worktrees[destination] = checkout
                }
            }
            structure.spaces.removeAll { $0.tabs.isEmpty }
            let pane = tab.root.terminals.first ?? ""
            return WoolooPane(id: pane, spaceID: destination, tabID: tab.id,
                              cwd: terminals.first { $0.address == pane }?.cwd, state: nil)
        }
    }

    func movePane(_ paneID: String, to destination: PaneDestination,
                  checkpoint: @Sendable () throws -> Void) throws {
        try checkpoint()
        try mutate { structure, _ in
            guard let (s, t) = structure.tab(of: paneID) else { return }
            let remaining = structure.spaces[s].tabs[t].root.filtered { $0 != paneID }
            switch destination {
            case .newTab:
                guard let remaining else { return }
                structure.spaces[s].tabs[t].root = remaining
                structure.spaces[s].tabs.insert(.init(id: CoreStructure.newID(), name: nil, root: .terminal(paneID)), at: t + 1)
            case let .beside(target, _, split, swapAfter, _):
                if let remaining { structure.spaces[s].tabs[t].root = remaining } else { structure.spaces[s].tabs.remove(at: t) }
                guard let (ts, tt) = structure.tab(of: target) else { return }
                structure.spaces[ts].tabs[tt].root = structure.spaces[ts].tabs[tt].root
                    .splitting(target, with: paneID, direction: split == "down" ? .down : .right, newFirst: swapAfter)
                structure.spaces.removeAll { $0.tabs.isEmpty }
            }
        }
    }

    /// Records a split's new ratio, once a drag ends.
    func setSplitRatio(tabID: String, path: [Bool], ratio: Double) throws {
        try mutate { structure, _ in
            guard let (s, t) = structure.tab(tabID) else { return }
            structure.spaces[s].tabs[t].root = structure.spaces[s].tabs[t].root.settingRatio(ratio, at: path[...])
        }
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
        let subscriptionClosed = PendingFlag()
        let subscribed = try connection.call("events.subscribe", [:], as: CoreSubscribeResult.self)
        if let channel = subscribed.channel {
            var lines = CoreEventLines()
            connection.route(channel: channel, onData: { data in
                // Heartbeats need nothing; terminal and document events need a fresh arrangement.
                // A `size` alone changes nothing the snapshot shows.
                if lines.append(data).contains(where: { $0.type != nil && $0.type != "size" }) {
                    pending.set()
                }
                changes.signal()
            }, onClose: { subscriptionClosed.set(); changes.signal() })
        }
        _ = subscribed
        onChange(try backend.snapshot(on: connection))
        while true {
            _ = changes.wait(timeout: .now() + 5)
            if lock.withLock({ cancelled }) { return }
            if subscriptionClosed.take() || connection.isClosed { throw CoreProtocolError.closed }
            if Date().timeIntervalSince(connection.lastActivity) > Self.silenceLimit {
                throw CoreProtocolError.timedOut("events.subscribe")
            }
            if pending.take() { onChange(try backend.snapshot(on: connection)) }
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

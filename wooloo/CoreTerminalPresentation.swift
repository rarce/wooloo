import Foundation
import WoolooTerminalEngine

/// Live terminals for a herdr-core connection (docs/proposals/herdr-core-backend.md, Phases 4
/// and 5). Core streams each terminal's raw output, so this attaches to every terminal of the
/// tab the window shows, emulates each with libghostty-vt (`VTTerminal`) and composes them,
/// laid out by wooloo's pane tree (`CoreStructure`), into the same `HerdrSurface` values the
/// Herdr TUI sends, with borders and draggable splits, which `TerminalPaneView` draws
/// unchanged. Keys, pastes and text are encoded here for each program's modes.
///
/// One thread runs `run`: it reads the tab's tree, attaches, feeds the emulators and builds
/// surfaces. Input and split drags arrive from the main thread under the same lock. A dragged
/// ratio shows at once and is written to the `wooloo` document once the drag rests. The tree
/// is read again when Core reports a terminal or document event on this connection's own
/// subscription, so other windows' and clients' changes show without polling. A zoomed pane
/// (this window's own, kept by the backend) is shown alone, and the others are detached.
final class CoreTerminalPresentation: TerminalPresentation, @unchecked Sendable {
    private let backend: CoreSessionBackend
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    /// How often the tab's tree is read again while no event asks for it: a safety net for a
    /// lost event, since events already report every change.
    static let refreshInterval: TimeInterval = 30
    static let ratioWriteDelay: TimeInterval = 0.4
    /// Lines of a terminal's scrollback Core replays on attach (main screen only); older
    /// output stays in the core.
    static let attachHistory = 2000
    /// At most this many wheel reports or arrow keys for one wheel event.
    static let maxWheelRepeat = 10
    /// The largest terminal size taken from Core for an observer, as `HerdrStore.resizeSurface`
    /// caps the window's: another viewer can set any size a RESIZE frame holds.
    static let maxTerminalSide = 1000

    // Guarded by `lock`.
    private var connection: CoreConnection?
    private var cancelled = false
    private var wantedTab: String?
    private var tab: (id: String, root: CoreStructure.Node)?
    private var needsTree = false
    private var lastTreeRead = Date.distantPast
    private var attachments: [String: Attachment] = [:]
    private var focusedPane: String?
    private var pendingRatio: (tab: String, path: [Bool], ratio: Double, due: Date)?
    private var bootID = "core-\(UUID().uuidString)"
    private var revision: UInt64 = 0
    private var dirty = false
    private var cols = 80
    private var rows = 24
    private var cellWidth = 8
    private var cellHeight = 16
    private var theme: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB, ansi: [TerminalRGB])?
    /// Nil until the window says whether it is active: nothing attaches before then, so a window
    /// restored behind others never takes the terminal's size, even for a moment.
    private var windowFocused: Bool?
    /// Sizes Core reported in `size` events since the last arrangement: one that differs from an
    /// active stream's means another viewer took the terminal.
    private var reportedSizes: [String: (cols: Int, rows: Int)] = [:]
    /// Set when the window becomes active: its streams send their sizes again, since a window
    /// that was in the background may have left the terminal at another window's size.
    private var reassertSize = false
    private var shownZoom: String?
    private var shownMouseReporting: Set<String> = []
    /// Bumped by each find and by ending one, so an older find that is still searching stops
    /// before it moves the viewport or the highlight.
    private var findGeneration: UInt64 = 0
    /// The newest find request begun: an older one that begins later does nothing.
    private var newestFindRequest: UInt64 = 0
    /// Keys typed into an observed terminal after the window became active, sent once the
    /// active attach replaces the observer.
    private var heldInput: [String: [Data]] = [:]

    private struct Attachment {
        let terminal: String
        let channel: UInt32
        let emulator: VTTerminal
        var rect: HerdrRect
        /// Watching only: Core keeps the size another viewer set, and takes no input from here.
        var observing = false
        /// A watching stream whose core sends no RESIZE frames: it takes the size from `size`
        /// events instead.
        var followsSizeEvents = false
        /// The sizes this stream last asked for: a `size` event that reports one of them, late, is
        /// this window's own, not another viewer's.
        var sizesSent: [(cols: Int, rows: Int)] = []
        /// Keys held for this stream are still being sent: newer ones wait behind them.
        var draining = false
        /// A press only returned to the live screen: its drags and release stay here too.
        var swallowsClick = false

        func sent(_ size: (cols: Int, rows: Int)) -> Bool {
            sizesSent.contains { $0.cols == size.cols && $0.rows == size.rows }
        }

        mutating func recordSent(_ rect: HerdrRect) {
            sizesSent = Array((sizesSent + [(rect.width, rect.height)]).suffix(4))
        }
        var grid: [[HerdrCell]]
        var cursor: TerminalCursor?
        var images: [TerminalImage] = []
        /// The search match shown, in viewport cells (both ends included).
        var highlight: (start: (column: Int, row: Int), end: (column: Int, row: Int))?
        var inbox = Data()
    }

    init(backend: CoreSessionBackend) { self.backend = backend }

    // MARK: TerminalPresentation

    func run(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int,
             onReady: () -> Void, onSurface: (HerdrSurface) -> Void,
             onAgents: ((HerdrAgentProjection) -> Void)?,
             onClipboard: ((String) -> Void)?) throws {
        let connection = try backend.connect()
        let proceed = lock.withLock { () -> Bool in
            self.connection = connection
            self.cols = max(cols, 1)
            self.rows = max(rows, 1)
            self.cellWidth = max(cellWidth, 1)
            self.cellHeight = max(cellHeight, 1)
            return !cancelled
        }
        guard proceed else { connection.close(); return }
        defer {
            connection.close()
            lock.withLock { self.connection = nil; attachments = [:]; tab = nil }
        }
        try subscribe(on: connection)
        onReady()
        while true {
            _ = wake.wait(timeout: .now() + 0.25)
            if lock.withLock({ cancelled }) { return }
            if connection.isClosed { throw CoreProtocolError.closed }
            try readTreeIfNeeded(on: connection)
            writeRatioIfDue()
            try arrange(on: connection)
            if let surface = drain() { onSurface(surface) }
        }
    }

    var isReady: Bool { lock.withLock { connection?.isClosed == false && !attachments.isEmpty } }

    func cancel() {
        let current = lock.withLock { () -> CoreConnection? in
            cancelled = true
            return connection
        }
        current?.close()
        wake.signal()
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        lock.withLock {
            self.cols = max(cols, 1)
            self.rows = max(rows, 1)
            self.cellWidth = max(cellWidth, 1)
            self.cellHeight = max(cellHeight, 1)
            dirty = true
        }
        wake.signal()
    }

    func updateHost(theme: WoolooTheme, focused: Bool) {
        let colors = (foreground: TerminalRGB(theme.foreground), background: TerminalRGB(theme.background),
                      cursor: TerminalRGB(theme.cursor), ansi: theme.ansi.map(TerminalRGB.init))
        lock.withLock {
            self.theme = colors
            if focused && windowFocused == false { reassertSize = true }
            windowFocused = focused
            for attachment in attachments.values { Self.apply(colors, to: attachment.emulator) }
            dirty = true
        }
        sendFocusAndFacts()
        wake.signal()
    }

    func focus(tabID: String) {
        lock.withLock {
            if wantedTab != tabID { focusedPane = nil }
            wantedTab = tabID
            needsTree = true
        }
        wake.signal()
    }

    @discardableResult
    func focus(paneID: String) -> Bool {
        let known = lock.withLock { () -> Bool in
            guard tab?.root.terminals.contains(paneID) == true else {
                // A pane this tab does not show yet, such as one just split off: read the tree,
                // which focuses it if it is there.
                needsTree = true
                focusedPane = paneID
                return false
            }
            if focusedPane != paneID { focusedPane = paneID; dirty = true }
            return true
        }
        if known { sendFocusAndFacts() } else { wake.signal() }
        return known
    }

    func focus(workspaceID: String) {}

    /// Shows a dragged ratio at once; the `wooloo` document gets it once the drag rests.
    @discardableResult
    func setSplitRatio(tabID: String, path: [Bool], ratio: Double) -> Bool {
        let shown = lock.withLock { () -> Bool in
            guard let current = tab, current.id == tabID else { return false }
            tab = (current.id, current.root.settingRatio(ratio, at: path[...]))
            pendingRatio = (tabID, path, ratio, Date().addingTimeInterval(Self.ratioWriteDelay))
            dirty = true
            return true
        }
        wake.signal()
        return shown
    }

    func sendInput(_ event: HerdrInputEvent, to paneID: String) -> Bool {
        // `accepted`: the pane is attached and took the event, even when it has nothing to send,
        // such as a drag the program's mouse mode does not report.
        let (connection, channel, bytes, accepted, redraw) = lock.withLock { () -> (CoreConnection?, UInt32?, Data?, Bool, Bool) in
            guard let attachment = attachments[paneID] else { return (nil, nil, nil, false, false) }
            let emulator = attachment.emulator
            let bytes: Data?
            switch event {
            case .mouse(let mouse):
                switch mouse.kind {
                case .drag, .up:
                    if attachment.swallowsClick {
                        if case .up = mouse.kind { attachments[paneID]?.swallowsClick = false }
                        return (nil, nil, nil, true, false)
                    }
                case .down:
                    attachments[paneID]?.swallowsClick = false
                default:
                    break
                }
                let input = Self.mouseInput(mouse, to: emulator)
                // A press that returned to the live screen is not reported, nor is the rest of it.
                if case .down = mouse.kind, input.scrolled { attachments[paneID]?.swallowsClick = true }
                if input.scrolled { dirty = true }
                if attachment.observing {
                    // Core takes no input from an observer. A click can come before the window's
                    // activation: it waits for the active attach, which it starts, as keys do.
                    // Wheel reports reach windows in the background too, so they never do.
                    switch mouse.kind {
                    case .down, .up, .drag:
                        if let bytes = input.bytes, !bytes.isEmpty { heldInput[paneID, default: []].append(bytes) }
                    case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
                        break
                    }
                    return (nil, nil, nil, true, true)
                }
                if attachment.draining {
                    if let bytes = input.bytes, !bytes.isEmpty { heldInput[paneID, default: []].append(bytes) }
                    return (nil, nil, nil, true, input.scrolled)
                }
                return (self.connection, attachment.channel, input.bytes, true, input.scrolled)
            case .text(let text): bytes = Data(text.utf8)
            case .paste(let text): bytes = emulator.encodePaste(text)
            case .key(let name): bytes = emulator.encodeKey(name)
            }
            if attachment.observing {
                // The window attaches actively once it is active; keys typed meanwhile wait for
                // that. Keys can come before the window's activation reaches here, and typing
                // into a pane makes it active anyway, so held keys also start the active attach.
                if let bytes, !bytes.isEmpty { heldInput[paneID, default: []].append(bytes) }
                return (nil, nil, nil, true, true)
            }
            // Typing returns to the live screen, as in other terminals, at once even when the
            // program echoes nothing.
            var moved = false
            if !emulator.isAtBottom { emulator.scrollToBottom(); moved = true }
            if attachment.highlight != nil { attachments[paneID]?.highlight = nil; moved = true }
            if moved { dirty = true }
            if attachment.draining {
                if let bytes, !bytes.isEmpty { heldInput[paneID, default: []].append(bytes) }
                return (nil, nil, nil, true, moved)
            }
            return (self.connection, attachment.channel, bytes, false, moved)
        }
        if redraw { wake.signal() }
        guard let connection, let channel, let bytes, !bytes.isEmpty else { return accepted }
        do {
            try connection.send(CoreFrame(channel: channel, kind: .data, payload: bytes))
            return true
        } catch { return false }
    }

    /// Searches in bounded steps, letting go of the lock between them so output, drawing and
    /// input go on during a long scrollback search. A newer find or `endFind` stops it.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    func find(_ query: String, in paneID: String, older: Bool, request: UInt64) -> TerminalFindResult? {
        let begun = lock.withLock { () -> (UInt64, Bool)? in
            // Finds run on worker threads, which may begin them out of order.
            guard request >= newestFindRequest else { return nil }
            newestFindRequest = request
            findGeneration &+= 1
            // One search at a time: another pane's would go on following every write.
            for terminal in attachments.keys where terminal != paneID {
                attachments[terminal]?.emulator.endSearch()
                if attachments[terminal]?.highlight != nil {
                    attachments[terminal]?.highlight = nil
                    dirty = true
                }
            }
            return (findGeneration, attachments[paneID]?.emulator.beginFind(query) == true)
        }
        guard let (generation, started) = begun else { return nil }
        guard started else { return clearHighlight(of: paneID, generation: generation) }
        while true {
            let step = lock.withLock { () -> Bool? in
                guard findGeneration == generation, let emulator = attachments[paneID]?.emulator else { return nil }
                return emulator.continueFind()
            }
            guard let step else { return nil }
            if step { break }
            // Give input and rendering threads a turn between bounded searches.
            Thread.sleep(forTimeInterval: 0.001)
        }
        let result = lock.withLock { () -> TerminalFindResult? in
            guard findGeneration == generation, let attachment = attachments[paneID] else { return nil }
            dirty = true
            guard let match = attachment.emulator.selectMatch(older: older) else {
                attachments[paneID]?.highlight = nil
                return nil
            }
            if let start = match.start, let end = match.end {
                attachments[paneID]?.highlight = (start, end)
            } else {
                attachments[paneID]?.highlight = nil
            }
            return TerminalFindResult(index: match.index, total: match.total)
        }
        wake.signal()
        return result
    }

    private func clearHighlight(of paneID: String, generation: UInt64) -> TerminalFindResult? {
        lock.withLock {
            if findGeneration == generation, attachments[paneID]?.highlight != nil {
                attachments[paneID]?.highlight = nil
                dirty = true
            }
        }
        wake.signal()
        return nil
    }

    /// Whether `paneID`'s emulator has a search open.
    func isSearching(in paneID: String) -> Bool {
        lock.withLock { attachments[paneID]?.emulator.isSearching == true }
    }

    func endFind() {
        lock.withLock {
            findGeneration &+= 1
            for terminal in attachments.keys {
                attachments[terminal]?.emulator.endSearch()
                attachments[terminal]?.highlight = nil
            }
            dirty = true
        }
        wake.signal()
    }

    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool { false }
    func closePopup() -> Bool { false }

    // MARK: Tree, attaching and drawing

    /// Terminal and document events mean the tab's tree or its terminals may have changed.
    private func subscribe(on connection: CoreConnection) throws {
        let subscribed = try connection.call("events.subscribe", [:], as: CoreSubscribeResult.self)
        guard let channel = subscribed.channel else { return }
        var lines = CoreEventLines()
        connection.route(channel: channel, onData: { [weak self] data in
            guard let self else { return }
            let events = lines.append(data).filter { $0.type != nil }
            guard !events.isEmpty else { return }
            self.lock.withLock {
                for event in events where event.type == "size" {
                    if let terminal = event.terminal, let cols = event.data?.cols, let rows = event.data?.rows {
                        self.reportedSizes[terminal] = (cols, rows)
                    }
                }
                // A size alone changes no tree.
                if events.contains(where: { $0.type != "size" }) { self.needsTree = true }
            }
            self.wake.signal()
        }, onClose: { [weak self] in self?.wake.signal() })
    }

    private func readTreeIfNeeded(on connection: CoreConnection) throws {
        let (wanted, due) = lock.withLock { () -> (String?, Bool) in
            let due = needsTree || Date().timeIntervalSince(lastTreeRead) >= Self.refreshInterval
            return (wantedTab, due && pendingRatio == nil)
        }
        guard let wanted, due else { return }
        let arrangement = try backend.arrangement(on: connection)
        let found = arrangement.structure.tab(wanted).map { arrangement.structure.spaces[$0.space].tabs[$0.tab].root }
        lock.withLock {
            needsTree = false
            lastTreeRead = Date()
            // The tree changed while it was read: a drag that started meanwhile wins.
            guard wantedTab == wanted, pendingRatio == nil else { return }
            if let found {
                if tab?.id != wanted { bootID = "core-\(wanted)-\(UUID().uuidString)" }
                if tab?.id != wanted || tab?.root != found { dirty = true }
                tab = (wanted, found)
            } else {
                tab = nil
            }
        }
    }

    private func writeRatioIfDue() {
        let due = lock.withLock { () -> (tab: String, path: [Bool], ratio: Double)? in
            guard let pending = pendingRatio, pending.due <= Date() else { return nil }
            pendingRatio = nil
            return (pending.tab, pending.path, pending.ratio)
        }
        guard let due else { return }
        try? backend.setSplitRatio(tabID: due.tab, path: due.path, ratio: due.ratio)
        lock.withLock { needsTree = true }
    }

    /// Attaches to the tab's terminals that have no stream, closes the streams of terminals it
    /// no longer shows and resizes the rest to their places in the layout.
    private func arrange(on connection: CoreConnection) throws {
        // Until the window says whether it is active, nothing attaches.
        guard lock.withLock({ windowFocused != nil }) else { return }
        let zoom = lock.withLock { tab?.id }.flatMap(backend.zoomedPane(in:))
        let (placed, current, size, colors) = lock.withLock { () -> ([(terminal: String, rect: HerdrRect)], [String: Attachment], (Int, Int), _) in
            let area = HerdrRect(x: 0, y: 0, width: cols, height: rows)
            if zoom != shownZoom { shownZoom = zoom; dirty = true }
            let visible = tab.map { CoreLayout.visible($0.root, zoomed: zoom) }
            return (visible.map { CoreLayout.panes($0, in: area) } ?? [], attachments, (cellWidth, cellHeight), theme)
        }
        let wanted = Set(placed.map(\.terminal))
        for (terminal, attachment) in current where !wanted.contains(terminal) {
            try? connection.send(CoreFrame(channel: attachment.channel, kind: .close, payload: Data()))
            lock.withLock { attachments[terminal] = nil; heldInput[terminal] = nil; dirty = true }
        }
        // A window that becomes active types and sizes its terminals again: attach afresh.
        let (focused, typedInto, reported) = lock.withLock { () -> (Bool, Set<String>, [String: (cols: Int, rows: Int)]) in
            defer { reportedSizes = [:] }
            return (windowFocused == true, Set(heldInput.keys), reportedSizes)
        }
        /// Attaches `terminal` afresh and closes the stream it replaces. The new attachment
        /// replaces the old one in one step, so keys typed meanwhile are held by an observer and
        /// sent on the new stream, never dropped for want of an attachment.
        func replace(_ terminal: String, _ attachment: Attachment, observe: Bool) throws {
            guard let rect = placed.first(where: { $0.terminal == terminal })?.rect else { return }
            try attach(terminal, rect: rect, cell: size, colors: colors, observe: observe, on: connection)
            if lock.withLock({ attachments[terminal]?.channel != attachment.channel }) {
                try? connection.send(CoreFrame(channel: attachment.channel, kind: .close, payload: Data()))
            }
        }
        for (terminal, attachment) in current where attachment.observing && (focused || typedInto.contains(terminal)) {
            try replace(terminal, attachment, observe: false)
        }
        // A background window's stream watches instead once Core reports that another viewer
        // resized the terminal: a stream that is not watching hears of no other size, and only
        // the window someone is using sizes the terminal. Without such a report this window may
        // be the only viewer, so it keeps sizing the terminal to its layout.
        for (terminal, attachment) in current where !attachment.observing && !focused && !typedInto.contains(terminal) {
            guard let other = reported[terminal], !attachment.sent(other) else { continue }
            try replace(terminal, attachment, observe: true)
        }
        // Observers whose core sends no RESIZE frames follow the size events instead.
        for (terminal, size) in reported {
            lock.withLock {
                guard let attachment = attachments[terminal], attachment.followsSizeEvents else { return }
                Self.resize(attachment, in: &attachments, to: size, cell: (cellWidth, cellHeight))
                dirty = true
            }
        }
        let (refreshed, reassert) = lock.withLock { () -> ([String: Attachment], Bool) in
            defer { if windowFocused == true { reassertSize = false } }
            return (attachments, reassertSize && windowFocused == true)
        }
        for (terminal, rect) in placed {
            if let attachment = refreshed[terminal] {
                if attachment.rect == rect {
                    if reassert && !attachment.observing {
                        try? connection.send(Self.resizeFrame(rect, channel: attachment.channel))
                    }
                    continue
                }
                if attachment.observing || (attachment.rect.width == rect.width && attachment.rect.height == rect.height) {
                    // An observer keeps Core's size, and a pane that only moved keeps its own:
                    // only its place in the tab changes.
                    lock.withLock { attachments[terminal]?.rect = rect; dirty = true }
                    if reassert && !attachment.observing {
                        try? connection.send(Self.resizeFrame(rect, channel: attachment.channel))
                    }
                    continue
                }
                lock.withLock {
                    // Output that came before the resize was laid out at the old size: it goes in first.
                    if let inbox = attachments[terminal]?.inbox, !inbox.isEmpty {
                        attachments[terminal]?.emulator.write(inbox)
                        attachments[terminal]?.inbox = Data()
                    }
                    try? attachments[terminal]?.emulator.resize(cols: rect.width, rows: rect.height,
                                                                cellWidth: size.0, cellHeight: size.1)
                    attachments[terminal]?.rect = rect
                    attachments[terminal]?.recordSent(rect)
                    attachments[terminal]?.grid = Self.blankGrid(cols: rect.width, rows: rect.height)
                    dirty = true
                }
                try? connection.send(Self.resizeFrame(rect, channel: attachment.channel))
                continue
            }
            try attach(terminal, rect: rect, cell: size, colors: colors, observe: !focused, on: connection)
        }
    }

    /// Resizes an observer's emulator to the size Core reports. Output that came before the
    /// resize was laid out at the old size, so it goes in first. Called under `lock`.
    private static func resize(_ attachment: Attachment, in attachments: inout [String: Attachment],
                               to size: (cols: Int, rows: Int), cell: (Int, Int)) {
        let terminal = attachment.terminal
        guard size.cols > 0, size.rows > 0 else { return }
        let size = (cols: min(size.cols, maxTerminalSide), rows: min(size.rows, maxTerminalSide))
        // Same size: nothing to lay out again, and a blank grid would stay blank until the
        // program draws.
        if attachment.grid.count == size.rows && attachment.grid.first?.count == size.cols { return }
        if !attachment.inbox.isEmpty {
            attachment.emulator.write(attachment.inbox)
            attachments[terminal]?.inbox = Data()
        }
        try? attachment.emulator.resize(cols: size.cols, rows: size.rows, cellWidth: cell.0, cellHeight: cell.1)
        attachments[terminal]?.grid = blankGrid(cols: size.cols, rows: size.rows)
    }

    private static func resizeFrame(_ rect: HerdrRect, channel: UInt32) -> CoreFrame {
        var payload = Data()
        withUnsafeBytes(of: UInt16(clamping: rect.width).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: rect.height).littleEndian) { payload.append(contentsOf: $0) }
        return CoreFrame(channel: channel, kind: .resize, payload: payload)
    }

    /// Attaches to a terminal. A window that is not active when it attaches, such as one
    /// restored behind others at launch, only watches (`observe`): it does not take the
    /// terminal's size from the window someone is typing in, and follows the size Core reports.
    private func attach(_ terminal: String, rect: HerdrRect, cell: (Int, Int),
                        colors: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB, ansi: [TerminalRGB])?,
                        observe: Bool, on connection: CoreConnection) throws {
        var params: [String: Any] = ["terminal": terminal, "cols": rect.width, "rows": rect.height,
                                     "history": Self.attachHistory]
        let offersResizes = connection.hello?.features.contains("resize_notifications") == true
        if observe {
            params["observe"] = true
            if offersResizes { params["resize_notifications"] = true }
        }
        // Only the active viewer sets the colours and cell size programs read.
        if let colors, !observe {
            params["display"] = ["fg": colors.foreground.hex, "bg": colors.background.hex,
                                 "cursor": colors.cursor.hex, "cell": [cell.0, cell.1]]
        }
        let result: CoreAttachResult
        do {
            result = try connection.call("terminal.attach", params, as: CoreAttachResult.self)
        } catch CoreProtocolError.remote {
            // The terminal is gone; the next read of the tree drops it.
            lock.withLock { needsTree = true }
            return
        }
        // An observer starts at the terminal's own size, which Core reports in the attach.
        let cols = observe ? min(max(result.terminal.cols, 1), Self.maxTerminalSide) : rect.width
        let rows = observe ? min(max(result.terminal.rows, 1), Self.maxTerminalSide) : rect.height
        let emulator: VTTerminal
        do {
            emulator = try VTTerminal(cols: cols, rows: rows)
        } catch {
            // Core opened the stream already; nothing would ever read it.
            connection.discard(channel: result.channel)
            throw error
        }
        try? emulator.resize(cols: cols, rows: rows, cellWidth: cell.0, cellHeight: cell.1)
        if let colors { Self.apply(colors, to: emulator) }
        // Both the core's `hello` and this attach must confirm it: old cores drop unknown kinds.
        let automatic = connection.hello?.features.contains("automatic_input") == true && result.automaticInput == true
        let channel = result.channel
        // Answers to queries Core forwards (kitty graphics, XTGETTCAP) go back as automatic
        // input, which does not count as typing or take the terminal's size.
        // An observer sends nothing: the active viewer answers.
        if !observe {
            emulator.onReply = { [weak connection] reply in
                try? connection?.send(CoreFrame(channel: channel, kind: automatic ? .automaticInput : .data, payload: reply))
            }
        }
        // Without RESIZE frames confirmed by both sides, an observer follows `size` events.
        let followsSizeEvents = observe && !(offersResizes && result.resizeNotifications == true)
        lock.withLock {
            attachments[terminal] = Attachment(terminal: terminal, channel: channel, emulator: emulator, rect: rect,
                                               observing: observe, followsSizeEvents: followsSizeEvents,
                                               grid: Self.blankGrid(cols: cols, rows: rows))
            if !observe {
                attachments[terminal]?.recordSent(rect)
                // Keys typed from now on wait behind the held ones.
                attachments[terminal]?.draining = heldInput[terminal]?.isEmpty == false
            }
            dirty = true
        }
        if !observe { sendHeldInput(terminal, channel: channel, on: connection) }
        connection.route(channel: channel, onData: { [weak self] data in
            guard let self else { return }
            // A stream this presentation closed may still deliver; only the current one counts.
            self.lock.withLock {
                if self.attachments[terminal]?.channel == channel { self.attachments[terminal]?.inbox.append(data) }
            }
            self.wake.signal()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.attachments[terminal]?.channel == channel { self.attachments[terminal] = nil }
                self.needsTree = true
            }
            self.wake.signal()
        }, onResize: { [weak self] cols, rows in
            guard let self else { return }
            self.lock.withLock {
                guard let attachment = self.attachments[terminal], attachment.channel == channel, attachment.observing else { return }
                Self.resize(attachment, in: &self.attachments, to: (cols, rows), cell: (self.cellWidth, self.cellHeight))
                self.dirty = true
            }
            self.wake.signal()
        })
        sendFocusAndFacts()
    }

    /// Sends the keys held for a new active stream, outside the lock, since a write can block,
    /// and then lets newer keys go straight to it. Keys typed meanwhile join the queue.
    private func sendHeldInput(_ terminal: String, channel: UInt32, on connection: CoreConnection) {
        while true {
            let batch = lock.withLock { () -> [Data]? in
                guard attachments[terminal]?.channel == channel, attachments[terminal]?.draining == true else { return nil }
                guard let held = heldInput.removeValue(forKey: terminal), !held.isEmpty else {
                    attachments[terminal]?.draining = false
                    return nil
                }
                return held
            }
            guard let batch else { return }
            for bytes in batch {
                try? connection.send(CoreFrame(channel: channel, kind: .data, payload: bytes))
            }
        }
    }

    /// Feeds what arrived to each emulator and composes the next surface, when anything changed.
    private func drain() -> HerdrSurface? {
        lock.withLock { () -> HerdrSurface? in
            guard let tab else { return nil }
            var changed = dirty
            for terminal in Array(attachments.keys) {
                guard var attachment = attachments[terminal] else { continue }
                let data = attachment.inbox
                attachment.inbox = Data()
                if !data.isEmpty { attachment.emulator.write(data) }
                if let frame = attachment.emulator.frame(), frame.full || !frame.rows.isEmpty || data.count > 0 {
                    if attachment.grid.count != frame.rowCount || attachment.grid.first?.count != frame.cols {
                        attachment.grid = Self.blankGrid(cols: frame.cols, rows: frame.rowCount)
                    }
                    for (y, cells) in frame.rows where y < attachment.grid.count {
                        attachment.grid[y] = Self.row(cells, width: frame.cols)
                    }
                    // Older lines on screen hide the live cursor.
                    attachment.cursor = attachment.emulator.isAtBottom ? frame.cursor : nil
                    // A match highlight is in viewport cells: it follows the text that output,
                    // a scroll or a resize moved, and goes once the match is out of view.
                    if attachment.emulator.isSearching { attachment.highlight = attachment.emulator.followMatch() }
                    changed = true
                }
                if let images = attachment.emulator.imagesIfChanged() {
                    attachment.images = images
                    changed = true
                }
                attachments[terminal] = attachment
            }
            let reporting = Set(attachments.filter { $0.value.emulator.reportsMouse }.keys)
            if reporting != shownMouseReporting { shownMouseReporting = reporting; changed = true }
            guard changed, !attachments.isEmpty else { return nil }
            dirty = false
            revision += 1
            let area = HerdrRect(x: 0, y: 0, width: cols, height: rows)
            let visible = CoreLayout.visible(tab.root, zoomed: shownZoom)
            let panes = CoreLayout.panes(visible, in: area)
            if focusedPane.map({ id in !panes.contains { $0.terminal == id } }) ?? true { focusedPane = panes.first?.terminal }
            return Self.compose(panes: panes, all: tab.root.terminals, splits: CoreLayout.splits(visible, in: area),
                                attachments: attachments, mouseReporting: reporting,
                                focused: focusedPane, area: area, bootID: bootID, revision: revision,
                                border: theme.map { Self.encode($0.ansi.count > 8 ? $0.ansi[8] : $0.foreground) } ?? 0)
        }
    }

    private func sendFocusAndFacts() {
        let (connection, targets, facts) = lock.withLock { () -> (CoreConnection?, [(UInt32, Bool)], [String: Any]) in
            var facts: [String: Any] = ["cell": [cellWidth, cellHeight]]
            if let theme {
                facts["fg"] = theme.foreground.hex
                facts["bg"] = theme.background.hex
                facts["cursor"] = theme.cursor.hex
            }
            let targets = attachments.values.filter { !$0.observing }
                .map { ($0.channel, windowFocused == true && $0.terminal == focusedPane) }
            return (self.connection, targets, facts)
        }
        guard let connection, let payload = try? JSONSerialization.data(withJSONObject: facts) else { return }
        for (channel, focused) in targets {
            try? connection.send(CoreFrame(channel: channel, kind: .focus, payload: Data([focused ? 1 : 0])))
            try? connection.send(CoreFrame(channel: channel, kind: .facts, payload: payload))
        }
    }

    private static func apply(_ colors: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB,
                                         ansi: [TerminalRGB]), to emulator: VTTerminal) {
        emulator.setColors(foreground: colors.foreground, background: colors.background, cursor: colors.cursor)
        emulator.setPalette(colors.ansi)
    }

    /// One surface for a tab: each pane's grid at its place, a line on each split's border,
    /// and Herdr's split records so the window can drag them.
    private static func compose(panes: [(terminal: String, rect: HerdrRect)], all: [String], splits: [CoreLayout.Split],
                                attachments: [String: Attachment], mouseReporting: Set<String>, focused: String?, area: HerdrRect,
                                bootID: String, revision: UInt64, border: UInt32) -> HerdrSurface {
        var grid = blankGrid(cols: area.width, rows: area.height)
        // Panes a zoom hides keep an empty place, so the surface still names every pane of the tab.
        var rects = Dictionary(all.map { ($0, HerdrRect(x: 0, y: 0, width: 0, height: 0)) }, uniquingKeysWith: { a, _ in a })
        for (terminal, rect) in panes {
            rects[terminal] = rect
            guard let pane = attachments[terminal]?.grid else { continue }
            let highlight = attachments[terminal]?.highlight
            for (dy, row) in pane.prefix(rect.height).enumerated() where rect.y + dy < grid.count {
                for (dx, cell) in row.prefix(rect.width).enumerated() where rect.x + dx < area.width {
                    grid[rect.y + dy][rect.x + dx] = highlight.map { Self.contains($0, column: dx, row: dy) } == true
                        ? Self.highlighted(cell) : cell
                }
            }
        }
        var records: [HerdrSplit] = []
        for split in splits {
            let line = HerdrCell(symbol: split.direction == .right ? "│" : "─", foreground: border, background: 0,
                                 modifier: 0, skip: false)
            let hit: HerdrRect
            if split.direction == .right {
                for y in split.area.y..<min(split.area.y + split.area.height, grid.count) where split.position < area.width {
                    grid[y][split.position] = line
                }
                hit = HerdrRect(x: split.position, y: split.area.y, width: 1, height: split.area.height)
            } else {
                if split.position < grid.count {
                    for x in split.area.x..<min(split.area.x + split.area.width, area.width) { grid[split.position][x] = line }
                }
                hit = HerdrRect(x: split.area.x, y: split.position, width: split.area.width, height: 1)
            }
            records.append(HerdrSplit(direction: split.direction == .right ? .horizontal : .vertical,
                                      pos: split.position, area: split.area, hitRect: hit, path: split.path))
        }
        let graphics = panes.flatMap { terminal, rect in
            guard let attachment = attachments[terminal] else { return [HerdrGraphic]() }
            return attachment.images.compactMap { graphic($0, of: terminal, stream: attachment.channel, in: rect) }
        }
        let cursor = focused.flatMap { id -> HerdrCursor? in
            // An observer's terminal can be larger than its pane, which cuts it: a cursor past
            // the pane's edge is not drawn on a neighbour.
            guard let rect = rects[id], let at = attachments[id]?.cursor,
                  at.x < rect.width, at.y < rect.height else { return nil }
            return HerdrCursor(x: rect.x + at.x, y: rect.y + at.y, visible: at.visible, shape: 0)
        }
        return HerdrSurface(bootID: bootID, projectionRevision: 0, revision: revision,
                            width: area.width, height: area.height,
                            cells: HerdrCellRows(rows: grid, width: area.width), cursor: cursor,
                            paneIDs: all, paneRects: rects, paneInnerRects: rects,
                            mouseReportingPaneIDs: mouseReporting, splits: records, graphics: graphics, focusedPaneID: focused)
    }

    /// What a mouse event in a pane does. A program that asked for mouse reports gets them,
    /// clicks, drags and the wheel alike, encoded for its mode. Otherwise the window keeps
    /// clicks for selecting text, and the wheel moves the scrollback; on the alternate screen,
    /// which has none, it sends arrow keys when the program asked for that (mode 1007), as
    /// pagers expect.
    static func mouseInput(_ mouse: HerdrMouseEvent, to emulator: VTTerminal) -> (bytes: Data?, scrolled: Bool) {
        let column = Int(mouse.column), row = Int(mouse.row), modifiers = UInt16(mouse.modifiers)
        let repeats = min(max(Int(mouse.lines), 1), maxWheelRepeat)
        // wooloo numbers buttons as Herdr does: 0 left, 1 right, 2 middle.
        func button(_ code: UInt64) -> Int { code == 1 ? 2 : code == 2 ? 3 : 1 }
        let wheel: Int?
        switch mouse.kind {
        case .scrollUp: wheel = 4
        case .scrollDown: wheel = 5
        case .scrollLeft: wheel = 6
        case .scrollRight: wheel = 7
        default: wheel = nil
        }
        // Older lines on screen: the wheel moves through them, and a click first returns to the
        // live screen, whose rows the program's reports name, without reaching the program.
        let scrolledBack = !emulator.isAtBottom
        if emulator.reportsMouse && scrolledBack && wheel == nil {
            emulator.scrollToBottom()
            return (nil, true)
        }
        if emulator.reportsMouse && !scrolledBack {
            switch mouse.kind {
            case .down(let code):
                return (emulator.encodeMouse(.press, button: button(code), column: column, row: row, modifiers: modifiers), false)
            case .up(let code):
                return (emulator.encodeMouse(.release, button: button(code), column: column, row: row, modifiers: modifiers), false)
            case .drag(let code):
                return (emulator.encodeMouse(.motion, button: button(code), column: column, row: row, modifiers: modifiers,
                                             anyButtonPressed: true), false)
            default:
                guard let wheel, let report = emulator.encodeMouse(.press, button: wheel, column: column, row: row,
                                                                    modifiers: modifiers) else { return (nil, false) }
                return (Data(Array(repeating: report, count: repeats).joined()), false)
            }
        }
        guard wheel == 4 || wheel == 5 else { return (nil, false) }
        let up = wheel == 4
        if emulator.isAlternateScreen {
            guard emulator.mode(1007), let key = emulator.encodeKey(up ? "up" : "down") else { return (nil, false) }
            return (Data(Array(repeating: key, count: repeats).joined()), false)
        }
        emulator.scroll(by: up ? -Int(max(mouse.lines, 1)) : Int(max(mouse.lines, 1)))
        return (nil, true)
    }

    /// A kitty graphics image of a pane as the surface image `TerminalPaneView` draws: at the
    /// pane's place, and cut to the pane where it runs past an edge, with the matching part
    /// of the source.
    /// `stream` is part of the image's identity: a new attachment has a new emulator, whose image
    /// ids and generations start over, so the view must not take its images for cached ones.
    static func graphic(_ image: TerminalImage, of terminal: String, stream: UInt32 = 0, in rect: HerdrRect) -> HerdrGraphic? {
        guard image.cols > 0, image.rows > 0, image.sourceWidth > 0, image.sourceHeight > 0 else { return nil }
        var column = image.column, row = image.row, cols = image.cols, rows = image.rows
        var sourceX = image.sourceX, sourceY = image.sourceY
        var sourceWidth = image.sourceWidth, sourceHeight = image.sourceHeight
        var offsetX = image.offsetX, offsetY = image.offsetY
        if column < 0 {
            let cut = -column
            guard cut < cols else { return nil }
            sourceX += sourceWidth * cut / cols; sourceWidth -= sourceWidth * cut / cols
            cols -= cut; column = 0; offsetX = 0
        }
        if row < 0 {
            let cut = -row
            guard cut < rows else { return nil }
            sourceY += sourceHeight * cut / rows; sourceHeight -= sourceHeight * cut / rows
            rows -= cut; row = 0; offsetY = 0
        }
        if column + cols > rect.width {
            let keep = rect.width - column
            guard keep > 0 else { return nil }
            sourceWidth = sourceWidth * keep / cols; cols = keep
        }
        if row + rows > rect.height {
            let keep = rect.height - row
            guard keep > 0 else { return nil }
            sourceHeight = sourceHeight * keep / rows; rows = keep
        }
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let key = HerdrGraphicKey(identity: Data("core|\(terminal)|\(stream)|\(image.identity)".utf8), width: image.width,
                                  height: image.height, format: image.format == .rgba ? .rgba : .rgb,
                                  isPopup: false, dataLength: image.pixels.count)
        // The view draws negative z below the text.
        let z = image.belowText ? min(image.z, -1) : max(image.z, 0)
        return HerdrGraphic(key: key, data: image.pixels, x: rect.x + column, y: rect.y + row, cols: cols, rows: rows,
                            sourceX: sourceX, sourceY: sourceY, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            xOffset: offsetX, yOffset: offsetY, z: z)
    }

    /// Whether a cell is inside a match that runs from `start` to `end` in reading order.
    static func contains(_ match: (start: (column: Int, row: Int), end: (column: Int, row: Int)), column: Int, row: Int) -> Bool {
        guard row >= match.start.row, row <= match.end.row else { return false }
        if row == match.start.row, column < match.start.column { return false }
        if row == match.end.row, column > match.end.column { return false }
        return true
    }

    /// A cell of a search match: reverse video, and, where the text already is reversed (such
    /// as a pager's own match highlight), bold and underlined too, so it never looks plain.
    static func highlighted(_ cell: HerdrCell) -> HerdrCell {
        let reverse: UInt16 = 64
        let modifier = cell.modifier & reverse == 0 ? cell.modifier | reverse : cell.modifier | 1 | 8
        return HerdrCell(symbol: cell.symbol, foreground: cell.foreground, background: cell.background,
                         modifier: modifier, skip: cell.skip, hyperlink: cell.hyperlink)
    }

    static func encode(_ rgb: TerminalRGB) -> UInt32 {
        0x0200_0000 | UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b)
    }

    // MARK: Surfaces

    static func blankGrid(cols: Int, rows: Int) -> [[HerdrCell]] {
        Array(repeating: Array(repeating: blank, count: max(cols, 1)), count: max(rows, 1))
    }

    static let blank = HerdrCell(symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false)

    /// One row of emulator cells as Herdr cells, padded or cut to `width`.
    static func row(_ cells: [TerminalCell], width: Int) -> [HerdrCell] {
        var row = cells.prefix(width).map(cell)
        if row.count < width { row += Array(repeating: blank, count: width - row.count) }
        return row
    }

    /// The same encoding Herdr's surfaces use: colour kind 2 is RGB, 0 the default; modifier
    /// bits follow ratatui (bold 1, dim 2, italic 4, underline 8, blink 16, reverse 64, hidden
    /// 128, crossed out 256); a wide character's second column is `skip`.
    static func cell(_ cell: TerminalCell) -> HerdrCell {
        func color(_ rgb: TerminalRGB?) -> UInt32 {
            guard let rgb else { return 0 }
            return 0x0200_0000 | UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b)
        }
        var modifier: UInt16 = 0
        if cell.style.contains(.bold) { modifier |= 1 }
        if cell.style.contains(.faint) { modifier |= 2 }
        if cell.style.contains(.italic) { modifier |= 4 }
        if cell.style.contains(.underline) { modifier |= 8 }
        if cell.style.contains(.blink) { modifier |= 16 }
        if cell.style.contains(.inverse) { modifier |= 64 }
        if cell.style.contains(.invisible) { modifier |= 128 }
        if cell.style.contains(.strikethrough) { modifier |= 256 }
        return HerdrCell(symbol: cell.text.isEmpty ? " " : cell.text, foreground: color(cell.foreground),
                         background: color(cell.background), modifier: modifier, skip: cell.width == .spacer)
    }
}

extension CoreSessionBackend: TerminalPresentationProvider {
    func makePresentation(timeouts: HerdrEndpointTimeouts) -> any TerminalPresentation {
        CoreTerminalPresentation(backend: self)
    }
}

private extension TerminalRGB {
    init(_ color: UInt32) { self.init(UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), UInt8(color & 255)) }
}

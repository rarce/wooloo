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
    private var windowFocused = true
    private var shownZoom: String?
    private var shownMouseReporting: Set<String> = []

    private struct Attachment {
        let terminal: String
        let channel: UInt32
        let emulator: VTTerminal
        var rect: HerdrRect
        /// Watching only: Core keeps the size another viewer set, and takes no input from here.
        var observing = false
        var grid: [[HerdrCell]]
        var cursor: TerminalCursor?
        var images: [TerminalImage] = []
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
        let (connection, channel, bytes, handled) = lock.withLock { () -> (CoreConnection?, UInt32?, Data?, Bool) in
            guard let attachment = attachments[paneID] else { return (nil, nil, nil, false) }
            let emulator = attachment.emulator
            // Core takes no input from an observer; the window attaches actively once it is active.
            if attachment.observing, case .mouse(let mouse) = event {
                let input = Self.mouseInput(mouse, to: emulator)
                if input.scrolled { dirty = true }
                return (nil, nil, nil, input.scrolled)
            }
            if attachment.observing { return (nil, nil, nil, false) }
            let bytes: Data?
            switch event {
            case .mouse(let mouse):
                let input = Self.mouseInput(mouse, to: emulator)
                if input.scrolled { dirty = true }
                return (self.connection, attachment.channel, input.bytes, input.scrolled)
            case .text(let text): bytes = Data(text.utf8)
            case .paste(let text): bytes = emulator.encodePaste(text)
            case .key(let name): bytes = emulator.encodeKey(name)
            }
            // Typing returns to the live screen, as in other terminals.
            if !emulator.isAtBottom { emulator.scrollToBottom(); dirty = true }
            return (self.connection, attachment.channel, bytes, false)
        }
        if handled { wake.signal() }
        guard let connection, let channel, let bytes, !bytes.isEmpty else { return handled }
        do {
            try connection.send(CoreFrame(channel: channel, kind: .data, payload: bytes))
            return true
        } catch { return false }
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
            guard let self, lines.append(data).contains(where: { $0.type != nil }) else { return }
            self.lock.withLock { self.needsTree = true }
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
            lock.withLock { attachments[terminal] = nil; dirty = true }
        }
        // A window that becomes active types and sizes its terminals again: attach afresh.
        let focused = lock.withLock { windowFocused }
        for (terminal, attachment) in current where attachment.observing && focused && wanted.contains(terminal) {
            try? connection.send(CoreFrame(channel: attachment.channel, kind: .close, payload: Data()))
            lock.withLock { attachments[terminal] = nil }
        }
        let refreshed = lock.withLock { attachments }
        for (terminal, rect) in placed {
            if let attachment = refreshed[terminal] {
                guard attachment.rect != rect else { continue }
                if attachment.observing {
                    // An observer keeps Core's size; only its place in the tab moves.
                    lock.withLock { attachments[terminal]?.rect = rect; dirty = true }
                    continue
                }
                lock.withLock {
                    try? attachments[terminal]?.emulator.resize(cols: rect.width, rows: rect.height,
                                                                cellWidth: size.0, cellHeight: size.1)
                    attachments[terminal]?.rect = rect
                    attachments[terminal]?.grid = Self.blankGrid(cols: rect.width, rows: rect.height)
                    dirty = true
                }
                var payload = Data()
                withUnsafeBytes(of: UInt16(clamping: rect.width).littleEndian) { payload.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt16(clamping: rect.height).littleEndian) { payload.append(contentsOf: $0) }
                try? connection.send(CoreFrame(channel: attachment.channel, kind: .resize, payload: payload))
                continue
            }
            try attach(terminal, rect: rect, cell: size, colors: colors, observe: !focused, on: connection)
        }
    }

    /// Attaches to a terminal. A window that is not active when it attaches, such as one
    /// restored behind others at launch, only watches (`observe`): it does not take the
    /// terminal's size from the window someone is typing in, and follows the size Core reports.
    private func attach(_ terminal: String, rect: HerdrRect, cell: (Int, Int),
                        colors: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB, ansi: [TerminalRGB])?,
                        observe: Bool, on connection: CoreConnection) throws {
        var params: [String: Any] = ["terminal": terminal, "cols": rect.width, "rows": rect.height,
                                     "history": Self.attachHistory]
        if observe {
            params["observe"] = true
            params["resize_notifications"] = true
        }
        if let colors {
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
        let cols = observe ? max(result.terminal.cols, 1) : rect.width
        let rows = observe ? max(result.terminal.rows, 1) : rect.height
        let emulator = try VTTerminal(cols: cols, rows: rows)
        try? emulator.resize(cols: cols, rows: rows, cellWidth: cell.0, cellHeight: cell.1)
        if let colors { Self.apply(colors, to: emulator) }
        // Both the core's `hello` and this attach must confirm it: old cores drop unknown kinds.
        let automatic = connection.hello?.features.contains("automatic_input") == true && result.automaticInput == true
        let channel = result.channel
        // Answers to queries Core forwards (kitty graphics, XTGETTCAP) go back as automatic
        // input, which does not count as typing or take the terminal's size.
        emulator.onReply = { [weak connection] reply in
            try? connection?.send(CoreFrame(channel: channel, kind: automatic ? .automaticInput : .data, payload: reply))
        }
        lock.withLock {
            attachments[terminal] = Attachment(terminal: terminal, channel: channel, emulator: emulator, rect: rect,
                                               observing: observe, grid: Self.blankGrid(cols: cols, rows: rows))
            dirty = true
        }
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
                try? attachment.emulator.resize(cols: cols, rows: rows, cellWidth: self.cellWidth, cellHeight: self.cellHeight)
                self.attachments[terminal]?.grid = Self.blankGrid(cols: cols, rows: rows)
                self.dirty = true
            }
            self.wake.signal()
        })
        sendFocusAndFacts()
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
                .map { ($0.channel, windowFocused && $0.terminal == focusedPane) }
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
            for (dy, row) in pane.prefix(rect.height).enumerated() where rect.y + dy < grid.count {
                for (dx, cell) in row.prefix(rect.width).enumerated() where rect.x + dx < area.width {
                    grid[rect.y + dy][rect.x + dx] = cell
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
            (attachments[terminal]?.images ?? []).compactMap { graphic($0, of: terminal, in: rect) }
        }
        let cursor = focused.flatMap { id -> HerdrCursor? in
            guard let rect = rects[id], let at = attachments[id]?.cursor else { return nil }
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
        if emulator.reportsMouse {
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
    static func graphic(_ image: TerminalImage, of terminal: String, in rect: HerdrRect) -> HerdrGraphic? {
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
        let key = HerdrGraphicKey(identity: Data("core|\(terminal)|\(image.identity)".utf8), width: image.width,
                                  height: image.height, format: image.format == .rgba ? .rgba : .rgb,
                                  isPopup: false, dataLength: image.pixels.count)
        // The view draws negative z below the text.
        let z = image.belowText ? min(image.z, -1) : max(image.z, 0)
        return HerdrGraphic(key: key, data: image.pixels, x: rect.x + column, y: rect.y + row, cols: cols, rows: rows,
                            sourceX: sourceX, sourceY: sourceY, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            xOffset: offsetX, yOffset: offsetY, z: z)
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

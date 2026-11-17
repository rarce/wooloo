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
/// ratio shows at once and is written to the `wooloo` document once the drag rests.
final class CoreTerminalPresentation: TerminalPresentation, @unchecked Sendable {
    private let backend: CoreSessionBackend
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    /// How often the tab's tree is read again while nothing asks for it, to follow changes
    /// other windows and clients make.
    static let refreshInterval: TimeInterval = 1.5
    static let ratioWriteDelay: TimeInterval = 0.4

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

    private struct Attachment {
        let terminal: String
        let channel: UInt32
        let emulator: VTTerminal
        var rect: HerdrRect
        var grid: [[HerdrCell]]
        var cursor: TerminalCursor?
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
        let (connection, channel, bytes) = lock.withLock { () -> (CoreConnection?, UInt32?, Data?) in
            guard let attachment = attachments[paneID] else { return (nil, nil, nil) }
            let bytes: Data?
            switch event {
            case .text(let text): bytes = Data(text.utf8)
            case .paste(let text): bytes = attachment.emulator.encodePaste(text)
            case .key(let name): bytes = attachment.emulator.encodeKey(name)
            case .mouse: bytes = nil // Mouse reporting arrives with the mouse encoder.
            }
            return (self.connection, attachment.channel, bytes)
        }
        guard let connection, let channel, let bytes, !bytes.isEmpty else { return false }
        do {
            try connection.send(CoreFrame(channel: channel, kind: .data, payload: bytes))
            return true
        } catch { return false }
    }

    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool { false }
    func closePopup() -> Bool { false }

    // MARK: Tree, attaching and drawing

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
        let (placed, current, size, colors) = lock.withLock { () -> ([(terminal: String, rect: HerdrRect)], [String: Attachment], (Int, Int), _) in
            let area = HerdrRect(x: 0, y: 0, width: cols, height: rows)
            return (tab.map { CoreLayout.panes($0.root, in: area) } ?? [], attachments, (cellWidth, cellHeight), theme)
        }
        let wanted = Set(placed.map(\.terminal))
        for (terminal, attachment) in current where !wanted.contains(terminal) {
            try? connection.send(CoreFrame(channel: attachment.channel, kind: .close, payload: Data()))
            lock.withLock { attachments[terminal] = nil; dirty = true }
        }
        for (terminal, rect) in placed {
            if let attachment = current[terminal] {
                guard attachment.rect != rect else { continue }
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
            try attach(terminal, rect: rect, cell: size, colors: colors, on: connection)
        }
    }

    private func attach(_ terminal: String, rect: HerdrRect, cell: (Int, Int),
                        colors: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB, ansi: [TerminalRGB])?,
                        on connection: CoreConnection) throws {
        var params: [String: Any] = ["terminal": terminal, "cols": rect.width, "rows": rect.height, "history": 0]
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
        let emulator = try VTTerminal(cols: rect.width, rows: rect.height)
        try? emulator.resize(cols: rect.width, rows: rect.height, cellWidth: cell.0, cellHeight: cell.1)
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
                                               grid: Self.blankGrid(cols: rect.width, rows: rect.height))
            dirty = true
        }
        connection.route(channel: channel, onData: { [weak self] data in
            guard let self else { return }
            self.lock.withLock { self.attachments[terminal]?.inbox.append(data) }
            self.wake.signal()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.attachments[terminal]?.channel == channel { self.attachments[terminal] = nil }
                self.needsTree = true
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
                    attachment.cursor = frame.cursor
                    changed = true
                }
                attachments[terminal] = attachment
            }
            guard changed, !attachments.isEmpty else { return nil }
            dirty = false
            revision += 1
            let area = HerdrRect(x: 0, y: 0, width: cols, height: rows)
            let panes = CoreLayout.panes(tab.root, in: area)
            if focusedPane.map({ id in !panes.contains { $0.terminal == id } }) ?? true { focusedPane = panes.first?.terminal }
            return Self.compose(panes: panes, splits: CoreLayout.splits(tab.root, in: area), attachments: attachments,
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
            let targets = attachments.values.map { ($0.channel, windowFocused && $0.terminal == focusedPane) }
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
    private static func compose(panes: [(terminal: String, rect: HerdrRect)], splits: [CoreLayout.Split],
                                attachments: [String: Attachment], focused: String?, area: HerdrRect,
                                bootID: String, revision: UInt64, border: UInt32) -> HerdrSurface {
        var grid = blankGrid(cols: area.width, rows: area.height)
        var rects: [String: HerdrRect] = [:]
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
        let cursor = focused.flatMap { id -> HerdrCursor? in
            guard let rect = rects[id], let at = attachments[id]?.cursor else { return nil }
            return HerdrCursor(x: rect.x + at.x, y: rect.y + at.y, visible: at.visible, shape: 0)
        }
        return HerdrSurface(bootID: bootID, projectionRevision: 0, revision: revision,
                            width: area.width, height: area.height,
                            cells: HerdrCellRows(rows: grid, width: area.width), cursor: cursor,
                            paneIDs: panes.map(\.terminal), paneRects: rects, paneInnerRects: rects,
                            mouseReportingPaneIDs: [], splits: records, graphics: [], focusedPaneID: focused)
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

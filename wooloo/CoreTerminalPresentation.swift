import Foundation
import WoolooTerminalEngine

/// Live terminals for a herdr-core connection (docs/proposals/herdr-core-backend.md, Phase 4).
/// Core streams a terminal's raw output, so this attaches to the terminal the window shows,
/// emulates it with libghostty-vt (`VTTerminal`) and hands `HerdrStore` the same `HerdrSurface`
/// values the Herdr TUI sends, which `TerminalPaneView` draws unchanged. Keys, pastes and text
/// are encoded here for the program's modes; Core sends no keys of its own.
///
/// Until wooloo's structure arrives (Phase 5), a Core tab is one terminal, so the surface is
/// that terminal's grid with no borders. One thread runs `run`: it attaches, feeds the emulator
/// and builds surfaces. Input arrives from the main thread and is encoded under the same lock.
final class CoreTerminalPresentation: TerminalPresentation, @unchecked Sendable {
    private let backend: CoreSessionBackend
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)

    // Guarded by `lock`.
    private var connection: CoreConnection?
    private var cancelled = false
    private var wanted: String?
    private var attached: Attachment?
    private var inbox = Data()
    private var cols = 80
    private var rows = 24
    private var cellWidth = 8
    private var cellHeight = 16
    private var theme: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB, ansi: [TerminalRGB])?
    private var focused = true

    private struct Attachment {
        let terminal: String
        let channel: UInt32
        let automaticInput: Bool
        let emulator: VTTerminal
        let bootID: String
        var grid: [[HerdrCell]]
        var revision: UInt64 = 0
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
            lock.withLock { self.connection = nil; attached = nil }
        }
        onReady()
        while true {
            _ = wake.wait(timeout: .now() + 1)
            if lock.withLock({ cancelled }) { return }
            if connection.isClosed { throw CoreProtocolError.closed }
            try attachIfNeeded(on: connection)
            if let surface = drain() { onSurface(surface) }
        }
    }

    var isReady: Bool { lock.withLock { connection?.isClosed == false && attached != nil } }

    func cancel() {
        let current = lock.withLock { () -> CoreConnection? in
            cancelled = true
            return connection
        }
        current?.close()
        wake.signal()
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let (connection, attachment) = lock.withLock { () -> (CoreConnection?, Attachment?) in
            self.cols = max(cols, 1)
            self.rows = max(rows, 1)
            self.cellWidth = max(cellWidth, 1)
            self.cellHeight = max(cellHeight, 1)
            if let attachment = attached {
                try? attachment.emulator.resize(cols: self.cols, rows: self.rows,
                                                cellWidth: self.cellWidth, cellHeight: self.cellHeight)
                attached?.grid = Self.blankGrid(cols: self.cols, rows: self.rows)
            }
            return (connection, attached)
        }
        guard let connection, let attachment else { return }
        var size = Data()
        withUnsafeBytes(of: UInt16(clamping: cols).littleEndian) { size.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: rows).littleEndian) { size.append(contentsOf: $0) }
        try? connection.send(CoreFrame(channel: attachment.channel, kind: .resize, payload: size))
        sendFacts()
        wake.signal()
    }

    func updateHost(theme: WoolooTheme, focused: Bool) {
        let colors = (foreground: TerminalRGB(theme.foreground), background: TerminalRGB(theme.background),
                      cursor: TerminalRGB(theme.cursor), ansi: theme.ansi.map(TerminalRGB.init))
        let (connection, attachment) = lock.withLock { () -> (CoreConnection?, Attachment?) in
            self.theme = colors
            self.focused = focused
            if let attachment = attached { Self.apply(colors, to: attachment.emulator) }
            return (connection, attached)
        }
        guard let connection, let attachment else { return }
        try? connection.send(CoreFrame(channel: attachment.channel, kind: .focus, payload: Data([focused ? 1 : 0])))
        sendFacts()
        wake.signal()
    }

    func focus(tabID: String) {
        lock.withLock { wanted = tabID }
        wake.signal()
    }

    @discardableResult
    func focus(paneID: String) -> Bool { lock.withLock { attached?.terminal == paneID } }

    func focus(workspaceID: String) {}

    @discardableResult
    func setSplitRatio(tabID: String, path: [Bool], ratio: Double) -> Bool { false }

    func sendInput(_ event: HerdrInputEvent, to paneID: String) -> Bool {
        let (connection, channel, bytes) = lock.withLock { () -> (CoreConnection?, UInt32?, Data?) in
            guard let attachment = attached, attachment.terminal == paneID else { return (nil, nil, nil) }
            let bytes: Data?
            switch event {
            case .text(let text): bytes = Data(text.utf8)
            case .paste(let text): bytes = attachment.emulator.encodePaste(text)
            case .key(let name): bytes = attachment.emulator.encodeKey(name)
            case .mouse: bytes = nil // Mouse reporting arrives with the mouse encoder (later in Phase 4).
            }
            return (connection, attachment.channel, bytes)
        }
        guard let connection, let channel, let bytes, !bytes.isEmpty else { return false }
        do {
            try connection.send(CoreFrame(channel: channel, kind: .data, payload: bytes))
            return true
        } catch { return false }
    }

    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool { false }
    func closePopup() -> Bool { false }

    // MARK: Attaching and drawing

    private func attachIfNeeded(on connection: CoreConnection) throws {
        let (wanted, current, size, colors) = lock.withLock {
            (self.wanted, attached, (cols, rows, cellWidth, cellHeight), theme)
        }
        guard let wanted, wanted != current?.terminal else { return }
        if let current {
            try? connection.send(CoreFrame(channel: current.channel, kind: .close, payload: Data()))
            lock.withLock { attached = nil; inbox = Data() }
        }
        var params: [String: Any] = ["terminal": wanted, "cols": size.0, "rows": size.1, "history": 0]
        if let colors {
            params["display"] = ["fg": colors.foreground.hex, "bg": colors.background.hex,
                                 "cursor": colors.cursor.hex, "cell": [size.2, size.3]]
        }
        let result: CoreAttachResult
        do {
            result = try connection.call("terminal.attach", params, as: CoreAttachResult.self)
        } catch CoreProtocolError.remote {
            // The terminal is gone; stay detached until the window shows another one.
            lock.withLock { if self.wanted == wanted { self.wanted = nil } }
            return
        }
        let emulator = try VTTerminal(cols: size.0, rows: size.1)
        try? emulator.resize(cols: size.0, rows: size.1, cellWidth: size.2, cellHeight: size.3)
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
            attached = Attachment(terminal: wanted, channel: channel, automaticInput: automatic, emulator: emulator,
                                  bootID: "core-\(wanted)-\(UUID().uuidString)",
                                  grid: Self.blankGrid(cols: size.0, rows: size.1))
        }
        connection.route(channel: channel, onData: { [weak self] data in
            guard let self else { return }
            self.lock.withLock { self.inbox.append(data) }
            self.wake.signal()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.lock.withLock { if self.attached?.channel == channel { self.attached = nil } }
            self.wake.signal()
        })
        sendFacts()
    }

    /// Feeds what arrived to the emulator and builds the next surface, when anything changed.
    private func drain() -> HerdrSurface? {
        lock.withLock { () -> HerdrSurface? in
            guard var attachment = attached else { return nil }
            let data = inbox
            inbox = Data()
            if !data.isEmpty { attachment.emulator.write(data) }
            guard let frame = attachment.emulator.frame(), frame.full || !frame.rows.isEmpty || attachment.revision == 0
            else { return nil }
            if attachment.grid.count != frame.rowCount || attachment.grid.first?.count != frame.cols {
                attachment.grid = Self.blankGrid(cols: frame.cols, rows: frame.rowCount)
            }
            for (y, cells) in frame.rows where y < attachment.grid.count {
                attachment.grid[y] = Self.row(cells, width: frame.cols)
            }
            attachment.revision += 1
            attached = attachment
            return Self.surface(of: attachment, frame: frame)
        }
    }

    private func sendFacts() {
        let (connection, channel, facts) = lock.withLock { () -> (CoreConnection?, UInt32?, [String: Any]) in
            var facts: [String: Any] = ["cell": [cellWidth, cellHeight]]
            if let theme {
                facts["fg"] = theme.foreground.hex
                facts["bg"] = theme.background.hex
                facts["cursor"] = theme.cursor.hex
            }
            return (connection, attached?.channel, facts)
        }
        guard let connection, let channel, let payload = try? JSONSerialization.data(withJSONObject: facts) else { return }
        try? connection.send(CoreFrame(channel: channel, kind: .facts, payload: payload))
    }

    private static func apply(_ colors: (foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB,
                                         ansi: [TerminalRGB]), to emulator: VTTerminal) {
        emulator.setColors(foreground: colors.foreground, background: colors.background, cursor: colors.cursor)
        emulator.setPalette(colors.ansi)
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

    private static func surface(of attachment: Attachment, frame: TerminalFrame) -> HerdrSurface {
        let width = attachment.grid.first?.count ?? frame.cols
        let height = attachment.grid.count
        let rect = HerdrRect(x: 0, y: 0, width: width, height: height)
        let cursor = frame.cursor.map { HerdrCursor(x: $0.x, y: $0.y, visible: $0.visible, shape: 0) }
        return HerdrSurface(bootID: attachment.bootID, projectionRevision: 0, revision: attachment.revision,
                            width: width, height: height,
                            cells: HerdrCellRows(rows: attachment.grid, width: width), cursor: cursor,
                            paneIDs: [attachment.terminal], paneRects: [attachment.terminal: rect],
                            paneInnerRects: [attachment.terminal: rect], mouseReportingPaneIDs: [],
                            splits: [], graphics: [], focusedPaneID: attachment.terminal)
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

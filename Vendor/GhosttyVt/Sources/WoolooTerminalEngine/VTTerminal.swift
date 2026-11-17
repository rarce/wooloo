import Foundation
import GhosttyVt

// A terminal emulator for herdr-core's raw terminal output (docs/proposals/herdr-core-backend.md,
// Phase 4): bytes in, a grid of cells with dirty rows out, plus the bytes the terminal must send
// back to the program (query answers) and encoders for keys, pastes and focus that follow the
// program's modes. It wraps libghostty-vt; nothing here depends on wooloo's own types.

public struct TerminalRGB: Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#rrggbb`, the form herdr-core's display facts take.
    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

public struct TerminalCellStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = TerminalCellStyle(rawValue: 1 << 0)
    public static let italic = TerminalCellStyle(rawValue: 1 << 1)
    public static let faint = TerminalCellStyle(rawValue: 1 << 2)
    public static let blink = TerminalCellStyle(rawValue: 1 << 3)
    public static let inverse = TerminalCellStyle(rawValue: 1 << 4)
    public static let invisible = TerminalCellStyle(rawValue: 1 << 5)
    public static let strikethrough = TerminalCellStyle(rawValue: 1 << 6)
    public static let overline = TerminalCellStyle(rawValue: 1 << 7)
    /// Any underline style (single, double, curly, dotted or dashed).
    public static let underline = TerminalCellStyle(rawValue: 1 << 8)
}

public struct TerminalCell: Hashable, Sendable {
    public enum Width: UInt8, Sendable {
        case narrow = 1
        case wide = 2
        /// The second column of a wide character, drawn by the cell before it.
        case spacer = 0
    }

    /// The cell's grapheme, empty for a blank cell.
    public var text: String
    /// Resolved colours; nil means the terminal's default.
    public var foreground: TerminalRGB?
    public var background: TerminalRGB?
    public var style: TerminalCellStyle
    public var width: Width

    public init(text: String = "", foreground: TerminalRGB? = nil, background: TerminalRGB? = nil,
                style: TerminalCellStyle = [], width: Width = .narrow) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.style = style
        self.width = width
    }
}

public struct TerminalCursor: Hashable, Sendable {
    public enum Shape: Sendable { case block, bar, underline, hollowBlock }

    public var x: Int
    public var y: Int
    public var visible: Bool
    public var shape: Shape
}

/// What changed since the previous frame. `rows` holds only the rows that need drawing again,
/// every row when `full` is true.
public struct TerminalFrame: Sendable {
    public let cols: Int
    public let rowCount: Int
    public let full: Bool
    public let rows: [Int: [TerminalCell]]
    public let cursor: TerminalCursor?
    public let foreground: TerminalRGB
    public let background: TerminalRGB
}

public enum VTTerminalError: Error, Equatable {
    case failed(String, Int32)
}

/// One terminal emulator. Not thread-safe: use it from one thread or queue at a time.
public final class VTTerminal {
    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var cellWidth = 8
    private var cellHeight = 16

    /// Bytes the terminal answers the program with, such as replies to queries herdr-core
    /// forwards to the viewer. Send them as `AUTOMATIC_INPUT` when the attach allows it.
    public var onReply: ((Data) -> Void)?
    /// The title the program set.
    public var onTitle: ((String) -> Void)?

    public private(set) var cols: Int
    public private(set) var rows: Int

    public init(cols: Int, rows: Int) throws {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        try check(ghostty_terminal_new(nil, &terminal, UInt16(clamping: self.cols), UInt16(clamping: self.rows)),
                  "terminal_new")
        try check(ghostty_render_state_new(nil, &renderState), "render_state_new")
        try check(ghostty_render_state_row_iterator_new(nil, &rowIterator), "row_iterator_new")
        try check(ghostty_render_state_row_cells_new(nil, &rowCells), "row_cells_new")
        try check(ghostty_key_encoder_new(nil, &keyEncoder), "key_encoder_new")
        try check(ghostty_key_event_new(nil, &keyEvent), "key_event_new")
        try check(ghostty_mouse_encoder_new(nil, &mouseEncoder), "mouse_encoder_new")
        try check(ghostty_mouse_event_new(nil, &mouseEvent), "mouse_event_new")
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            let owner = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            owner.onReply?(Data(bytes: data, count: length))
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata else { return }
            let owner = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            var title = GhosttyString()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS else { return }
            owner.onTitle?(title.string)
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                                 unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))
    }

    deinit {
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    private func check(_ result: GhosttyResult, _ call: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw VTTerminalError.failed(call, Int32(result.rawValue)) }
    }

    // MARK: Input from the program

    /// Feeds the program's output.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, buffer.count)
        }
    }

    public func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.cellWidth = max(cellWidth, 1)
        self.cellHeight = max(cellHeight, 1)
        try check(ghostty_terminal_resize(terminal, UInt16(clamping: self.cols), UInt16(clamping: self.rows),
                                          UInt32(clamping: max(cellWidth, 1)), UInt32(clamping: max(cellHeight, 1))),
                  "terminal_resize")
    }

    /// The window's colours, which the terminal uses for its defaults and colour queries.
    public func setColors(foreground: TerminalRGB, background: TerminalRGB, cursor: TerminalRGB?) {
        var fg = GhosttyColorRgb(r: foreground.r, g: foreground.g, b: foreground.b)
        var bg = GhosttyColorRgb(r: background.r, g: background.g, b: background.b)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var color = GhosttyColorRgb(r: cursor.r, g: cursor.g, b: cursor.b)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &color)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
    }

    /// The first colours of the 256-colour palette (the window theme's ANSI colours); the rest
    /// keep the standard colour cube and grey ramp.
    public func setPalette(_ ansi: [TerminalRGB]) {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for index in 16..<232 {
            let n = index - 16
            palette[index] = GhosttyColorRgb(r: levels[n / 36], g: levels[(n / 6) % 6], b: levels[n % 6])
        }
        for index in 232..<256 {
            let level = UInt8(8 + (index - 232) * 10)
            palette[index] = GhosttyColorRgb(r: level, g: level, b: level)
        }
        let defaults: [TerminalRGB] = [
            .init(0, 0, 0), .init(205, 49, 49), .init(13, 188, 121), .init(229, 229, 16), .init(36, 114, 200),
            .init(188, 63, 188), .init(17, 168, 205), .init(229, 229, 229), .init(102, 102, 102),
            .init(241, 76, 76), .init(35, 209, 139), .init(245, 245, 67), .init(59, 142, 234),
            .init(214, 112, 214), .init(41, 184, 219), .init(255, 255, 255),
        ]
        for index in 0..<16 {
            let color = index < ansi.count ? ansi[index] : defaults[index]
            palette[index] = GhosttyColorRgb(r: color.r, g: color.g, b: color.b)
        }
        palette.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
        }
    }

    /// Whether the program asked for a terminal mode, such as 2004 (bracketed paste).
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    /// Whether the program asked for mouse reports (any of modes 9, 1000, 1002 and 1003).
    public var reportsMouse: Bool {
        var value = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &value)
        return value
    }

    /// Whether the program switched to the alternate screen, which keeps no scrollback.
    public var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    // MARK: Scrollback

    /// Where the viewport is in the scrollback, in rows: `offset` is its first row out of
    /// `total`, and it shows `length` rows. At the bottom, `offset + length == total`.
    public var scrollPosition: (total: Int, offset: Int, length: Int) {
        var bar = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return (Int(clamping: bar.total), Int(clamping: bar.offset), Int(clamping: bar.len))
    }

    /// Whether the viewport shows the live screen rather than older lines.
    public var isAtBottom: Bool {
        let position = scrollPosition
        return position.offset + position.length >= position.total
    }

    /// Moves the viewport through the scrollback; negative `lines` go back in time.
    public func scroll(by lines: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = lines
        _ = ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Returns the viewport to the live screen.
    public func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        _ = ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    // MARK: Output to draw

    /// The rows that changed since the last frame; marks them drawn.
    public func frame() -> TerminalFrame? {
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return nil }
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var cursorState = GhosttyRenderStateCursor()
        cursorState.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursorState)
        let full = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        var changed: [Int: [TerminalCell]] = [:]
        if dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE,
           ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS {
            var y: UInt16 = 0
            if full {
                while ghostty_render_state_row_iterator_next(rowIterator) {
                    changed[Int(y)] = readRow()
                    y += 1
                }
            } else {
                while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
                    changed[Int(y)] = readRow()
                }
            }
        }
        _ = ghostty_render_state_clean(renderState)
        let cursor = cursorState.viewport_has_value
            ? TerminalCursor(x: Int(cursorState.viewport_x), y: Int(cursorState.viewport_y),
                             visible: cursorState.visible, shape: Self.shape(cursorState.visual_style))
            : nil
        return TerminalFrame(cols: cols, rowCount: rows, full: full, rows: changed, cursor: cursor,
                             foreground: TerminalRGB(colors.foreground), background: TerminalRGB(colors.background))
    }

    private func readRow() -> [TerminalCell] {
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS
        else { return [] }
        var cells: [TerminalCell] = []
        cells.reserveCapacity(cols)
        var codepoints = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_cells_next(rowCells) {
            var cell = TerminalCell()
            var raw: GhosttyCell = 0
            if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
                var wide = GHOSTTY_CELL_WIDE_NARROW
                if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                    switch wide {
                    case GHOSTTY_CELL_WIDE_WIDE: cell.width = .wide
                    case GHOSTTY_CELL_WIDE_SPACER_TAIL, GHOSTTY_CELL_WIDE_SPACER_HEAD: cell.width = .spacer
                    default: cell.width = .narrow
                    }
                }
            }
            var length: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            if length > 0 {
                let count = codepoints.withUnsafeMutableBufferPointer { buffer -> Int in
                    var graphemes = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                    _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                                                           &graphemes)
                    return min(graphemes.len, graphemes.cap)
                }
                var scalars = String.UnicodeScalarView()
                for value in codepoints.prefix(count) { if let scalar = Unicode.Scalar(value) { scalars.append(scalar) } }
                cell.text = String(scalars)
            }
            var style = GhosttyStyle()
            if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
                var flags = TerminalCellStyle(rawValue: style.flags & 0xff)
                if style.flags & 0x0700 != 0 { flags.insert(.underline) }
                cell.style = flags
            }
            var color = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS {
                cell.foreground = TerminalRGB(color)
            }
            if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == GHOSTTY_SUCCESS {
                cell.background = TerminalRGB(color)
            }
            cells.append(cell)
        }
        return cells
    }

    private static func shape(_ style: GhosttyCursorStyle) -> TerminalCursor.Shape {
        switch style {
        case GHOSTTY_CURSOR_STYLE_BAR: return .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: return .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: return .hollowBlock
        default: return .block
        }
    }

    // MARK: Encoding the user's input

    /// Encodes a key named like wooloo's semantic input (`enter`, `ctrl+c`, `alt+left`, `a`) for
    /// the program's current keyboard modes, or nil when the name is unknown.
    public func encodeKey(_ name: String) -> Data? {
        guard let (key, mods, text) = Self.parseKey(name) else { return nil }
        _ = ghostty_key_encoder_set_from_terminal(keyEncoder, terminal)
        _ = ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
        _ = ghostty_key_event_set_key(keyEvent, key)
        _ = ghostty_key_event_set_mods(keyEvent, mods)
        let utf8 = Array((text ?? "").utf8)
        return utf8.withUnsafeBufferPointer { buffer -> Data? in
            _ = ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: buffer.baseAddress, len: buffer.count))
            var written = 0
            var output = [UInt8](repeating: 0, count: 128)
            let result = output.withUnsafeMutableBufferPointer { out in
                ghostty_key_encoder_encode(keyEncoder, keyEvent, out.baseAddress, out.count, &written)
            }
            guard result == GHOSTTY_SUCCESS else { return nil }
            return Data(output.prefix(written))
        }
    }

    /// Text as the program should receive a paste: bracketed when it asked for mode 2004.
    public func encodePaste(_ text: String) -> Data {
        var bytes = Array(text.utf8)
        let bracketed = mode(2004)
        var written = 0
        var output = [UInt8](repeating: 0, count: bytes.count + 16)
        let result = bytes.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                input.baseAddress!.withMemoryRebound(to: CChar.self, capacity: input.count) { characters in
                    ghostty_paste_encode(characters, input.count, bracketed, out.baseAddress, out.count, &written)
                }
            }
        }
        guard result == GHOSTTY_SUCCESS else { return Data(text.utf8) }
        return Data(output.prefix(written))
    }

    public enum MouseAction: Sendable { case press, release, motion }

    /// A mouse report for the program's mouse mode and format, at a cell of the screen, or nil
    /// when the program takes no such report. Buttons: 1 left, 2 right, 3 middle, 4 and 5 the
    /// wheel up and down, 6 and 7 left and right; nil for motion with no button. Modifiers use
    /// the same bits as keys: shift 1, control 2, option 4.
    public func encodeMouse(_ action: MouseAction, button: Int?, column: Int, row: Int,
                            modifiers: UInt16 = 0, anyButtonPressed: Bool = false) -> Data? {
        _ = ghostty_mouse_encoder_set_from_terminal(mouseEncoder, terminal)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(clamping: cols * cellWidth)
        size.screen_height = UInt32(clamping: rows * cellHeight)
        size.cell_width = UInt32(clamping: cellWidth)
        size.cell_height = UInt32(clamping: cellHeight)
        _ = withUnsafePointer(to: &size) { ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, $0) }
        var pressed = anyButtonPressed
        _ = withUnsafePointer(to: &pressed) {
            ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, $0)
        }
        switch action {
        case .press: _ = ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_PRESS)
        case .release: _ = ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_RELEASE)
        case .motion: _ = ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_MOTION)
        }
        let buttons = [GHOSTTY_MOUSE_BUTTON_LEFT, GHOSTTY_MOUSE_BUTTON_RIGHT, GHOSTTY_MOUSE_BUTTON_MIDDLE,
                       GHOSTTY_MOUSE_BUTTON_FOUR, GHOSTTY_MOUSE_BUTTON_FIVE, GHOSTTY_MOUSE_BUTTON_SIX,
                       GHOSTTY_MOUSE_BUTTON_SEVEN]
        if let button, (1...buttons.count).contains(button) {
            _ = ghostty_mouse_event_set_button(mouseEvent, buttons[button - 1])
        } else {
            _ = ghostty_mouse_event_clear_button(mouseEvent)
        }
        _ = ghostty_mouse_event_set_mods(mouseEvent, modifiers)
        // The middle of the cell, in the surface pixels the encoder converts back to cells.
        let x = (Float(max(0, min(column, cols - 1))) + 0.5) * Float(cellWidth)
        let y = (Float(max(0, min(row, rows - 1))) + 0.5) * Float(cellHeight)
        _ = ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: x, y: y))
        var written = 0
        var output = [UInt8](repeating: 0, count: 128)
        let result = output.withUnsafeMutableBufferPointer { out in
            ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, out.baseAddress, out.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return Data(output.prefix(written))
    }

    /// The focus report for programs that asked for mode 1004; empty otherwise.
    public func encodeFocus(_ gained: Bool) -> Data {
        guard mode(1004) else { return Data() }
        var written = 0
        var output = [UInt8](repeating: 0, count: 8)
        let result = output.withUnsafeMutableBufferPointer { out in
            ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, out.baseAddress, out.count, &written)
        }
        return result == GHOSTTY_SUCCESS ? Data(output.prefix(written)) : Data()
    }

    /// Splits `ctrl+alt+x` into a key, modifiers and the text the key types.
    static func parseKey(_ name: String) -> (GhosttyKey, GhosttyMods, String?)? {
        var parts = name.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: GhosttyMods = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "shift": mods |= 1 << 0
            case "ctrl", "control": mods |= 1 << 1
            case "alt", "option", "meta": mods |= 1 << 2
            case "super", "cmd": mods |= 1 << 3
            default: return nil
            }
        }
        let named: [String: GhosttyKey] = [
            "enter": GHOSTTY_KEY_ENTER, "return": GHOSTTY_KEY_ENTER, "tab": GHOSTTY_KEY_TAB,
            "backspace": GHOSTTY_KEY_BACKSPACE, "esc": GHOSTTY_KEY_ESCAPE, "escape": GHOSTTY_KEY_ESCAPE,
            "space": GHOSTTY_KEY_SPACE, "delete": GHOSTTY_KEY_DELETE, "insert": GHOSTTY_KEY_INSERT,
            "home": GHOSTTY_KEY_HOME, "end": GHOSTTY_KEY_END, "pageup": GHOSTTY_KEY_PAGE_UP,
            "pagedown": GHOSTTY_KEY_PAGE_DOWN, "up": GHOSTTY_KEY_ARROW_UP, "down": GHOSTTY_KEY_ARROW_DOWN,
            "left": GHOSTTY_KEY_ARROW_LEFT, "right": GHOSTTY_KEY_ARROW_RIGHT,
            "f1": GHOSTTY_KEY_F1, "f2": GHOSTTY_KEY_F2, "f3": GHOSTTY_KEY_F3, "f4": GHOSTTY_KEY_F4,
            "f5": GHOSTTY_KEY_F5, "f6": GHOSTTY_KEY_F6, "f7": GHOSTTY_KEY_F7, "f8": GHOSTTY_KEY_F8,
            "f9": GHOSTTY_KEY_F9, "f10": GHOSTTY_KEY_F10, "f11": GHOSTTY_KEY_F11, "f12": GHOSTTY_KEY_F12,
        ]
        if let key = named[last] {
            let text: String? = switch last {
            case "space": " "
            case "enter", "return": "\r"
            case "tab": "\t"
            default: nil
            }
            return (key, mods, mods & (1 << 1 | 1 << 2) == 0 ? text : nil)
        }
        guard last.unicodeScalars.count == 1, let scalar = last.unicodeScalars.first else { return nil }
        let punctuation: [Character: GhosttyKey] = [
            "`": GHOSTTY_KEY_BACKQUOTE, "\\": GHOSTTY_KEY_BACKSLASH, "[": GHOSTTY_KEY_BRACKET_LEFT,
            "]": GHOSTTY_KEY_BRACKET_RIGHT, ",": GHOSTTY_KEY_COMMA, "=": GHOSTTY_KEY_EQUAL, "-": GHOSTTY_KEY_MINUS,
            ".": GHOSTTY_KEY_PERIOD, "'": GHOSTTY_KEY_QUOTE, ";": GHOSTTY_KEY_SEMICOLON, "/": GHOSTTY_KEY_SLASH,
        ]
        let key: GhosttyKey
        if ("a"..."z").contains(last) {
            key = GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + (scalar.value - 97))
        } else if ("0"..."9").contains(last) {
            key = GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_0.rawValue + (scalar.value - 48))
        } else if let punctuationKey = punctuation[Character(last)] {
            key = punctuationKey
        } else {
            key = GHOSTTY_KEY_UNIDENTIFIED
        }
        let typed = mods & (1 << 0) != 0 ? last.uppercased() : last
        return (key, mods, typed)
    }
}

private extension TerminalRGB {
    init(_ color: GhosttyColorRgb) { self.init(color.r, color.g, color.b) }
}

private extension GhosttyString {
    var string: String {
        guard let ptr, len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}

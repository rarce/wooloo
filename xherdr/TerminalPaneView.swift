import AppKit
import SwiftUI

/// A Herdr surface laid out for Core Text. Every glyph is placed at its cell's origin, so
/// fallback fonts with other metrics can never change a row's height or a column's width.
struct TerminalGrid {
    struct Fill {
        let rect: CGRect
        let color: CGColor
    }

    struct GlyphRun {
        let font: CTFont
        let color: CGColor
        var glyphs: [CGGlyph] = []
        /// Baseline-relative positions, x measured from the grid's left edge.
        var positions: [CGPoint] = []
        var columns: [Int] = []
    }

    /// One laid-out row in coordinates relative to its top edge, so a line that scrolls to
    /// another row is drawn from the same layout.
    struct Row {
        /// Cell symbols; a wide character's continuation cell holds "".
        let symbols: [String]
        let backgrounds: [Fill]
        let runs: [GlyphRun]
        let underlines: [Fill]
    }

    /// Everything a row's layout depends on besides the theme and font.
    struct RowKey: Equatable {
        let cells: ArraySlice<HerdrCell>
        let cursorColumn: Int?
        /// Column ranges covered by images drawn behind the text.
        let imageColumns: [Range<Int>]
    }

    let width: Int
    let height: Int
    let rows: [Row]
    let keys: [RowKey]
    let selectionFill: CGColor
    let selectionText: CGColor

    /// The index of a row laid out for `key`, checking `hint` first, then every other row.
    func row(matching key: RowKey, near hint: Int) -> Int? {
        if hint >= 0, hint < height, keys[hint] == key { return hint }
        return keys.indices.first { $0 != hint && keys[$0] == key }
    }

    /// Runs of rows that show something different from `previous`, which has the same size.
    func changedRows(since previous: TerminalGrid) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for row in 0..<height where previous.keys[row] != keys[row] {
            if let last = ranges.last, last.upperBound == row {
                ranges[ranges.count - 1] = last.lowerBound..<(row + 1)
            } else {
                ranges.append(row..<(row + 1))
            }
        }
        return ranges
    }
}

/// A caret position between cells: `column` ranges over 0...width.
private struct GridPoint: Comparable {
    var row: Int
    var column: Int

    static func < (lhs: GridPoint, rhs: GridPoint) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A small AppKit input surface for Herdr's rendered pane snapshot. Herdr still
/// owns the PTY; this view only displays its text and forwards keyboard input.
struct TerminalPaneView: NSViewRepresentable {
    static let terminalFont = NSFont(name: "FiraCodeNFM-Reg", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let cellWidth = ("M" as NSString).size(withAttributes: [.font: terminalFont]).width
    static let cellHeight = NSLayoutManager().defaultLineHeight(for: terminalFont)
    static let boldFont = NSFontManager.shared.convert(terminalFont, toHaveTrait: .boldFontMask)
    static let italicFont = NSFontManager.shared.convert(terminalFont, toHaveTrait: .italicFontMask)
    static let boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
    /// Distance from a row's top to its baseline, matching where TextKit placed the text.
    static let baseline = cellHeight - ceil(-terminalFont.descender)

    let text: String
    let paneID: String
    var surfaceFeed: HerdrSurfaceFeed? = nil
    let shortcutMap: HerdrShortcutMap
    let onShortcut: (String) -> Void
    let onPrefixChanged: (Bool) -> Void
    var selectPane: ((String) -> Void)? = nil
    let sendText: (String, String) -> Void
    let sendPaste: (String, String) -> Void
    let sendKey: (String, String) -> Void
    let sendMouse: (HerdrMouseEvent, String) -> Void
    let setSplitRatio: ([Bool], Double) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = context.environment.xherdrTheme.terminalBackground
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Full screen reveals the title bar as an overlay; automatic insets would shift
        // the grid away from the rows Herdr's mouse coordinates assume.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        // The live grid is drawn with Core Text; TextKit only lays out the fallback text,
        // and its drawing is only overridden reliably under TextKit 1.
        let view = HerdrTerminalTextView(usingTextLayoutManager: false)
        view.paneID = paneID
        view.shortcutMap = shortcutMap
        view.onShortcut = onShortcut
        view.onPrefixChanged = onPrefixChanged
        view.sendText = sendText
        view.sendPaste = sendPaste
        view.sendKey = sendKey
        view.sendMouse = sendMouse
        view.setSplitRatio = setSplitRatio
        view.selectPane = selectPane
        view.isRichText = false
        view.isEditable = true
        view.registerForDraggedTypes([.fileURL, .string])
        view.isSelectable = true
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        view.drawsBackground = false
        view.textColor = context.environment.xherdrTheme.terminalForeground
        view.font = Self.terminalFont
        view.textContainerInset = NSSize(width: 10, height: 9)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? HerdrTerminalTextView else { return }
        let updateStart = TerminalPipelineMetrics.now()
        defer { TerminalPipelineMetrics.shared?.updated(revision: nil, start: updateStart, layoutNanos: nil) }
        if view.paneID != paneID {
            view.paneID = paneID
            view.claimKeyboardFocusIfIdle()
        }
        if view.shortcutMap.prefixLabel != shortcutMap.prefixLabel { view.clearShortcutPrefix() }
        view.shortcutMap = shortcutMap
        view.onShortcut = onShortcut
        view.onPrefixChanged = onPrefixChanged
        view.sendText = sendText
        view.sendPaste = sendPaste
        view.sendKey = sendKey
        view.sendMouse = sendMouse
        view.setSplitRatio = setSplitRatio
        view.selectPane = selectPane
        let theme = context.environment.xherdrTheme
        if view.themeID != theme.id {
            view.themeID = theme.id
            view.theme = theme
            view.terminalGrid = nil
            scrollView.backgroundColor = theme.terminalBackground
            view.textColor = theme.terminalForeground
            view.insertionPointColor = XherdrTheme.nsColor(theme.cursor)
            view.selectedTextAttributes = [.backgroundColor: XherdrTheme.nsColor(theme.selectionBackground)]
            view.surfaceRevision = nil
        }
        Self.configureScrolling(scrollView, view: view, live: surfaceFeed != nil)
        if let surfaceFeed {
            // Frames reach the view straight from the feed; SwiftUI only connects them once.
            if view.surfaceFeed !== surfaceFeed {
                view.surfaceFeed = surfaceFeed
                surfaceFeed.observe(view) { [weak view] surface in view?.show(surface) }
            }
            view.show(surfaceFeed.surface)
            return
        }
        view.surface = nil
        view.surfaceRevision = nil
        view.terminalGrid = nil
        guard view.string != text else { return }
        let visible = scrollView.contentView.bounds
        let wasAtBottom = visible.maxY >= view.bounds.maxY - 20
        view.applyFallbackText(text)
        if wasAtBottom {
            view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    /// A live surface is a fixed cols × rows grid sized to the view, so it never scrolls:
    /// glyphs from fallback fonts that overflow a cell are clipped instead of adding
    /// scrollers, which would shrink the grid and cascade into both scrollbars. The text
    /// storage is empty then, so the view keeps the clip view's size instead of fitting it.
    private static func configureScrolling(_ scrollView: NSScrollView, view: NSTextView, live: Bool) {
        guard scrollView.hasVerticalScroller == live else { return }
        scrollView.hasVerticalScroller = !live
        scrollView.hasHorizontalScroller = !live
        scrollView.verticalScrollElasticity = live ? .none : .automatic
        scrollView.horizontalScrollElasticity = live ? .none : .automatic
        view.isHorizontallyResizable = !live
        view.isVerticallyResizable = !live
        view.autoresizingMask = live ? [.width, .height] : []
        if live {
            view.setFrameSize(scrollView.contentSize)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Lays out every row. A row showing the same cells, cursor and images as a row of
    /// `previous` (laid out with the same theme) reuses that layout, so scrolled output only
    /// lays out its new lines.
    static func layoutGrid(_ surface: HerdrSurface, theme: XherdrTheme, previous: TerminalGrid? = nil) -> TerminalGrid {
        let behindImages = surface.graphics.filter { $0.z < 0 }
        let reusable = previous?.width == surface.width ? previous : nil
        var palette = TerminalPalette(theme: theme)
        var rows: [TerminalGrid.Row] = []
        var keys: [TerminalGrid.RowKey] = []
        rows.reserveCapacity(surface.height)
        keys.reserveCapacity(surface.height)
        /// How far the previous grid's rows moved; scrolled output shifts every row alike.
        var shift = 0
        for y in 0..<surface.height {
            let cursor = surface.cursor
            let key = TerminalGrid.RowKey(
                cells: surface.cells[(y * surface.width)..<((y + 1) * surface.width)],
                cursorColumn: cursor?.visible == true && cursor?.y == y ? cursor?.x : nil,
                imageColumns: behindImages.filter { y >= $0.y && y < $0.y + $0.rows }.map { $0.x..<($0.x + $0.cols) })
            if let reusable, let match = reusable.row(matching: key, near: y + shift) {
                shift = match - y
                rows.append(reusable.rows[match])
            } else {
                rows.append(layoutRow(key, theme: theme, palette: &palette))
            }
            keys.append(key)
        }
        let selectionFill = XherdrTheme.nsColor(theme.selectionBackground)
        return TerminalGrid(width: surface.width, height: surface.height, rows: rows, keys: keys,
                            selectionFill: selectionFill.cgColor,
                            selectionText: readableText(on: selectionFill, theme: theme).cgColor)
    }

    /// Places each cell's glyphs at the cell origin. Core Text still shapes a whole row, so
    /// font fallback and ligatures work, but its advances never move the next column.
    private static func layoutRow(_ key: TerminalGrid.RowKey, theme: XherdrTheme,
                                  palette: inout TerminalPalette) -> TerminalGrid.Row {
        let regularFont = terminalFont
        let underlineY = -terminalFont.underlinePosition
        let underlineHeight = max(1, terminalFont.underlineThickness)
        let cells = key.cells
        let width = cells.count
        var backgrounds: [TerminalGrid.Fill] = []
        var underlines: [TerminalGrid.Fill] = []
        var text = ""
        text.reserveCapacity(width)
        var fontRanges: [(range: NSRange, font: NSFont)] = []
        var rowSymbols: [String] = []
        rowSymbols.reserveCapacity(width)
        var foregrounds: [CGColor] = []
        foregrounds.reserveCapacity(width)
        /// The cell column of every UTF-16 unit in `text`.
        var columnAt: [Int] = []
        columnAt.reserveCapacity(width)
        var fill: (start: Int, color: CGColor)?

        func closeFill(at end: Int) {
            guard let current = fill else { return }
            backgrounds.append(TerminalGrid.Fill(
                rect: CGRect(x: CGFloat(current.start) * cellWidth, y: 0,
                             width: CGFloat(end - current.start) * cellWidth, height: cellHeight),
                color: current.color))
            fill = nil
        }

        for x in 0..<width {
            let cell = cells[cells.startIndex + x]
            let isCursor = key.cursorColumn == x
            // Herdr sends Ratatui modifiers: bold 1, dim 2, italic 4, underlined 8, reversed 64,
            // hidden 128, crossed out 256.
            let modifier = cell.modifier
            let reversed = modifier & 64 != 0
            var foreground = palette.foreground(reversed ? cell.background : cell.foreground, reversed: reversed)
            let background = palette.background(reversed ? cell.foreground : cell.background, reversed: reversed)
            if modifier & 128 != 0 {
                foreground = background
            } else if modifier & 2 != 0 {
                foreground = palette.dimmed(foreground, on: background)
            }
            let imageBehind = !key.imageColumns.isEmpty && key.imageColumns.contains { $0.contains(x) }
            // Default backgrounds come from the scroll view; the cursor is drawn inverted.
            let cellFill: CGColor? = isCursor ? foreground
                : ((cell.background == 0 && !reversed) || imageBehind ? nil : background)
            if fill?.color !== cellFill {
                closeFill(at: x)
                if let cellFill { fill = (x, cellFill) }
            }
            let textColor = isCursor ? background : foreground
            foregrounds.append(textColor)
            if cell.skip {
                rowSymbols.append("")
                continue
            }
            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            rowSymbols.append(symbol)
            let length = symbol.utf16.count
            let styledFont: NSFont? = switch modifier & 5 {
            case 1: boldFont
            case 4: italicFont
            case 5: boldItalicFont
            default: nil
            }
            if let styledFont {
                if let last = fontRanges.last, last.font === styledFont,
                   NSMaxRange(last.range) == columnAt.count {
                    fontRanges[fontRanges.count - 1].range.length += length
                } else {
                    fontRanges.append((NSRange(location: columnAt.count, length: length), styledFont))
                }
            }
            text += symbol
            columnAt.append(contentsOf: repeatElement(x, count: length))
            // Underlines and strikethroughs share the row's line fills.
            for (flag, lineY) in [(UInt16(8), baseline + underlineY), (256, cellHeight / 2)] where modifier & flag != 0 {
                let span = x + 1 < width && cells[cells.startIndex + x + 1].skip ? 2 : 1
                underlines.append(TerminalGrid.Fill(
                    rect: CGRect(x: CGFloat(x) * cellWidth, y: lineY - underlineHeight / 2,
                                 width: CGFloat(span) * cellWidth, height: underlineHeight),
                    color: textColor))
            }
        }
        closeFill(at: width)
        let line = NSMutableAttributedString(string: text, attributes: [.font: regularFont])
        for (range, font) in fontRanges { line.addAttribute(.font, value: font, range: range) }

        var runs: [TerminalGrid.GlyphRun] = []
        let ctLine = CTLineCreateWithAttributedString(line)
        for ctRun in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(ctRun)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(ctRun) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(ctRun, CFRange(), &glyphs)
            CTRunGetPositions(ctRun, CFRange(), &positions)
            CTRunGetStringIndices(ctRun, CFRange(), &indices)
            // Glyphs sharing a cell (combining marks, clusters) keep their offsets from
            // the cell's first glyph.
            var cellStart: (column: Int, x: CGFloat)?
            for index in 0..<count {
                let column = columnAt[min(max(0, indices[index]), columnAt.count - 1)]
                if rowSymbols[column] == " " { continue }
                if cellStart?.column != column { cellStart = (column, positions[index].x) }
                let position = CGPoint(x: CGFloat(column) * cellWidth + positions[index].x - (cellStart?.x ?? 0),
                                       y: positions[index].y)
                let textColor = foregrounds[column]
                if let last = runs.last, last.font == font, last.color === textColor {
                    runs[runs.count - 1].glyphs.append(glyphs[index])
                    runs[runs.count - 1].positions.append(position)
                    runs[runs.count - 1].columns.append(column)
                } else {
                    runs.append(TerminalGrid.GlyphRun(font: font, color: textColor, glyphs: [glyphs[index]],
                                                      positions: [position], columns: [column]))
                }
            }
        }
        return TerminalGrid.Row(symbols: rowSymbols, backgrounds: backgrounds, runs: runs, underlines: underlines)
    }

    /// The theme's foreground or background, whichever contrasts more with `fill`.
    private static func readableText(on fill: NSColor, theme: XherdrTheme) -> NSColor {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        }
        let target = luminance(fill)
        return abs(luminance(theme.terminalForeground) - target) >= abs(luminance(theme.terminalBackground) - target)
            ? theme.terminalForeground : theme.terminalBackground
    }

    /// Theme colors resolved once per grid instead of once per cell.
    struct TerminalPalette {
        let theme: XherdrTheme
        private var foregrounds: [UInt32: CGColor] = [:]
        private var backgrounds: [UInt32: CGColor] = [:]
        private var dims: [ObjectIdentifier: [ObjectIdentifier: CGColor]] = [:]

        init(theme: XherdrTheme) { self.theme = theme }

        /// A cell's text color; `reversed` means `value` is a background whose default is the
        /// theme background.
        mutating func foreground(_ value: UInt32, reversed: Bool = false) -> CGColor {
            reversed ? background(value) : resolve(value, cache: &foregrounds, default: theme.terminalForeground)
        }

        /// A cell's fill color; `reversed` means `value` is a foreground whose default is the
        /// theme foreground.
        mutating func background(_ value: UInt32, reversed: Bool = false) -> CGColor {
            reversed ? foreground(value) : resolve(value, cache: &backgrounds, default: theme.terminalBackground)
        }

        /// Faint text: the text color mixed halfway toward the cell's background, as iTerm2 draws it.
        mutating func dimmed(_ color: CGColor, on background: CGColor) -> CGColor {
            if let cached = dims[ObjectIdentifier(color)]?[ObjectIdentifier(background)] { return cached }
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            let mixed: CGColor
            if let text = color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
               let fill = background.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
               text.count == 4, fill.count == 4 {
                mixed = CGColor(srgbRed: (text[0] + fill[0]) / 2, green: (text[1] + fill[1]) / 2,
                                blue: (text[2] + fill[2]) / 2, alpha: text[3])
            } else {
                mixed = color.copy(alpha: 0.5) ?? color
            }
            dims[ObjectIdentifier(color), default: [:]][ObjectIdentifier(background)] = mixed
            return mixed
        }

        private func resolve(_ value: UInt32, cache: inout [UInt32: CGColor], default fallback: NSColor) -> CGColor {
            if let color = cache[value] { return color }
            let color = TerminalPaneView.color(value, default: fallback, ansi: theme.ansi).cgColor
            cache[value] = color
            return color
        }
    }

    /// Resolves a Herdr cell color: kind 0 is the default (0) or ANSI 1–16, kind 1 the 256-color
    /// palette, kind 2 RGB. ANSI colors come from the theme; Herdr's own chrome arrives as RGB.
    private static func color(_ value: UInt32, default fallback: NSColor, ansi: [UInt32]) -> NSColor {
        let kind = value >> 24
        if kind == 2 {
            return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        if kind == 0 {
            let index = Int(value & 255)
            if index == 0 { return fallback }
            if index <= ansi.count { return rgb(ansi[index - 1]) }
        }
        if kind == 1 {
            let index = Int(value & 255)
            if index < ansi.count { return rgb(ansi[index]) }
            if index < 232 {
                let n = index - 16
                let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
                return rgb((levels[n / 36] << 16) | (levels[(n / 6) % 6] << 8) | levels[n % 6])
            }
            let gray = UInt32(8 + (index - 232) * 10)
            return rgb((gray << 16) | (gray << 8) | gray)
        }
        return fallback
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Maps surface cells under the pointer to panes, splits and mouse reports.
enum TerminalPointer {
    /// The pane whose rectangle holds a surface cell.
    static func paneID(atColumn x: Int, row y: Int, in surface: HerdrSurface) -> String? {
        surface.paneIDs.first { id in
            guard let rect = surface.paneRects[id] else { return false }
            return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        }
    }

    /// The pane under a surface cell and the cell's position inside its content, for mouse reports.
    static func pane(atColumn x: Int, row y: Int, in surface: HerdrSurface) -> (id: String, column: UInt16, row: UInt16)? {
        guard let id = paneID(atColumn: x, row: y, in: surface),
              let inner = surface.paneInnerRects[id], let cell = cell(column: x, row: y, inside: inner) else { return nil }
        return (id, cell.column, cell.row)
    }

    /// A surface cell relative to a pane's content, clamped to it; nil for an empty pane.
    static func cell(column x: Int, row y: Int, inside inner: HerdrRect) -> (column: UInt16, row: UInt16)? {
        guard inner.width > 0, inner.height > 0 else { return nil }
        return (UInt16(clamping: max(0, min(x - inner.x, inner.width - 1))),
                UInt16(clamping: max(0, min(y - inner.y, inner.height - 1))))
    }

    /// The split whose divider holds a surface cell.
    static func split(atColumn x: Int, row y: Int, in surface: HerdrSurface) -> HerdrSplit? {
        surface.splits.first { split in
            let rect = split.hitRect
            return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        }
    }

    /// The split ratio for a divider dragged to `pointer`, kept between 10% and 90%.
    static func splitRatio(_ split: HerdrSplit, pointer: Int, grabOffset: Int) -> Double {
        let origin = split.direction == .horizontal ? split.area.x : split.area.y
        let length = max(1, split.direction == .horizontal ? split.area.width : split.area.height)
        return min(0.9, max(0.1, Double(pointer + grabOffset - origin) / Double(length)))
    }

    /// Herdr's mouse modifier bits: Shift 1, Control 2, Option 4.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var value: UInt8 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.option) { value |= 4 }
        return value
    }

    /// The run of non-blank cells around `column`, for double-click selection; nil on a blank.
    static func wordRange(in symbols: [String], at column: Int) -> Range<Int>? {
        guard symbols.indices.contains(column), symbols[column] != " " else { return nil }
        var lower = column
        var upper = column + 1
        while lower > 0, symbols[lower - 1] != " " { lower -= 1 }
        while upper < symbols.count, symbols[upper] != " " { upper += 1 }
        return lower..<upper
    }
}

/// A link in a pane: where it goes and the surface cells showing it, which may wrap across rows.
struct TerminalLink: Equatable {
    struct Span: Equatable {
        let row: Int
        let columns: Range<Int>
    }

    let url: URL
    let spans: [Span]
}

/// Finds the link under a surface cell for Command-click: an OSC 8 hyperlink, as Claude Code
/// prints, or a URL in plain text, as iTerm2 detects. Only web links open.
enum TerminalLinks {
    static func link(atColumn x: Int, row y: Int, in surface: HerdrSurface) -> TerminalLink? {
        guard let id = TerminalPointer.paneID(atColumn: x, row: y, in: surface),
              let inner = surface.paneInnerRects[id],
              x >= inner.x, x < inner.x + inner.width, y >= inner.y, y < inner.y + inner.height,
              inner.x + inner.width <= surface.width, inner.y + inner.height <= surface.height else { return nil }
        let clicked = (y - inner.y) * inner.width + (x - inner.x)
        return explicitLink(at: clicked, inside: inner, in: surface)
            ?? plainLink(at: clicked, inside: inner, in: surface)
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The cell at `index`, counted row by row across the pane's content.
    private static func cell(_ index: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> HerdrCell {
        surface.cells[(inner.y + index / inner.width) * surface.width + inner.x + index % inner.width]
    }

    private static func hyperlink(_ index: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> UInt32? {
        let current = cell(index, inside: inner, in: surface)
        if let hyperlink = current.hyperlink { return hyperlink }
        // A wide character's continuation cell may not carry the link itself.
        guard current.skip, index % inner.width > 0 else { return nil }
        return cell(index - 1, inside: inner, in: surface).hyperlink
    }

    /// Adjacent cells with the clicked cell's OSC 8 destination, across wrapped rows too.
    private static func explicitLink(at clicked: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> TerminalLink? {
        guard let id = hyperlink(clicked, inside: inner, in: surface), Int(id) < surface.hyperlinks.count,
              let url = webURL(surface.hyperlinks[Int(id)]) else { return nil }
        var start = clicked
        var end = clicked
        while start > 0, hyperlink(start - 1, inside: inner, in: surface) == id { start -= 1 }
        while end + 1 < inner.width * inner.height, hyperlink(end + 1, inside: inner, in: surface) == id { end += 1 }
        return TerminalLink(url: url, spans: spans(start...end, inside: inner))
    }

    private static let plainURL = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

    /// A URL in the text around the clicked cell. Rows whose last cell is filled continue on
    /// the next row, so a long URL the terminal wrapped is found whole.
    private static func plainLink(at clicked: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> TerminalLink? {
        let width = inner.width
        func wraps(_ row: Int) -> Bool {
            let last = cell(row * width + width - 1, inside: inner, in: surface)
            return last.skip || !(last.symbol.isEmpty || last.symbol == " ")
        }
        var first = clicked / width
        var last = first
        while first > 0, wraps(first - 1) { first -= 1 }
        while last < inner.height - 1, wraps(last) { last += 1 }
        var text = ""
        /// The pane cell of every UTF-16 unit in `text`.
        var cellAt: [Int] = []
        for index in (first * width)..<((last + 1) * width) {
            let current = cell(index, inside: inner, in: surface)
            guard !current.skip else { continue }
            let symbol = current.symbol.isEmpty ? " " : current.symbol
            text += symbol
            cellAt.append(contentsOf: repeatElement(index, count: symbol.utf16.count))
        }
        let string = text as NSString
        for match in plainURL.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var range = match.range
            // Punctuation after a URL ends the sentence around it, and closers belong to the
            // URL only when it opened them, as in Wikipedia links.
            while range.length > 0 {
                let candidate = string.substring(with: range)
                let lastCharacter = candidate.last!
                let openers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
                if ".,:;!?".contains(lastCharacter)
                    || openers[lastCharacter].map({ opener in
                        candidate.filter { $0 == lastCharacter }.count > candidate.filter { $0 == opener }.count
                    }) == true {
                    range.length -= 1
                } else {
                    break
                }
            }
            guard range.length > 0 else { continue }
            let start = cellAt[range.location]
            var end = cellAt[NSMaxRange(range) - 1]
            // A wide last character also covers its continuation cell.
            if end + 1 < inner.width * inner.height, end % width < width - 1,
               cell(end + 1, inside: inner, in: surface).skip { end += 1 }
            guard (start...end).contains(clicked), let url = webURL(string.substring(with: range)) else { continue }
            return TerminalLink(url: url, spans: spans(start...end, inside: inner))
        }
        return nil
    }

    /// Surface rows and columns covering pane cells `indices`.
    private static func spans(_ indices: ClosedRange<Int>, inside inner: HerdrRect) -> [TerminalLink.Span] {
        let width = inner.width
        return (indices.lowerBound / width...indices.upperBound / width).map { row in
            let lower = row == indices.lowerBound / width ? indices.lowerBound % width : 0
            let upper = row == indices.upperBound / width ? indices.upperBound % width + 1 : width
            return TerminalLink.Span(row: inner.y + row, columns: (inner.x + lower)..<(inner.x + upper))
        }
    }
}

/// Turns scroll deltas into whole lines for mouse-reporting programs. Trackpads report small
/// precise deltas that add up across events; wheels report lines.
struct TerminalScrollAccumulator {
    private(set) var remainder: CGFloat = 0

    mutating func reset() { remainder = 0 }

    /// Lines to scroll for one event, at most 20; nil while a trackpad has not moved a whole line.
    mutating func lines(for delta: CGFloat, precise: Bool, lineHeight: CGFloat) -> UInt16? {
        guard precise else { return UInt16(max(1, min(Int(abs(delta).rounded()), 20))) }
        remainder += delta
        let count = Int(abs(remainder) / lineHeight)
        guard count > 0 else { return nil }
        let lines = UInt16(min(count, 20))
        remainder -= CGFloat(lines) * lineHeight * (remainder > 0 ? 1 : -1)
        return lines
    }
}

final class HerdrTerminalTextView: NSTextView {
    var surfaceRevision: UInt64?
    var themeID: String?
    var theme = XherdrTheme.named(XherdrTheme.fallbackID)!
    var surfaceFeed: HerdrSurfaceFeed?
    var surfaceBootID: String?
    var surface: HerdrSurface?
    var selectPane: ((String) -> Void)?
    var paneID = ""
    var shortcutMap = HerdrShortcutMap(document: HerdrConfigDocument(text: ""))
    var onShortcut: ((String) -> Void)?
    var onPrefixChanged: ((Bool) -> Void)?
    private var shortcutPrefixPending = false
    var sendText: ((String, String) -> Void)?
    var sendPaste: ((String, String) -> Void)?
    var sendKey: ((String, String) -> Void)?
    var sendMouse: ((HerdrMouseEvent, String) -> Void)?
    var setSplitRatio: (([Bool], Double) -> Void)?
    private var heldMouse: (paneID: String, button: UInt64)?
    private var scroll = TerminalScrollAccumulator()
    private var splitDrag: (split: HerdrSplit, grabOffset: Int, bootID: String,
                            lastSentAt: Double, lastRatio: Double?)?
    /// The live surface drawn in `draw(_:)`; nil while showing fallback `pane.read` text.
    var terminalGrid: TerminalGrid?
    private var selectedSnapshot: String?
    private var selectionAtSnapshot: NSRange?
    /// The live selection lives in cell coordinates, so screen updates never move it.
    private var selectionAnchor: GridPoint?
    private var selectionHead: GridPoint?
    private var isSelectingCells = false
    /// The link under the pointer while Command is held, underlined until either changes.
    private var hoveredLink: TerminalLink?
    private var linkTrackingArea: NSTrackingArea?

    /// Herdr's cursor is drawn in the grid; a caret at the end of the text would be a second one.
    override var shouldDrawInsertionPoint: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Switching tabs rebuilds this view; give it the keyboard like a terminal would.
        DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocusIfIdle() }
    }

    /// Takes keyboard focus unless another text input in this window is being used.
    func claimKeyboardFocusIfIdle() {
        guard let window, window.firstResponder !== self else { return }
        if let view = window.firstResponder as? NSView, view.window === window,
           view is NSTextInputClient, !(view is HerdrTerminalTextView) { return }
        window.makeFirstResponder(self)
    }

    func clearShortcutPrefix() {
        shortcutPrefixPending = false
        onPrefixChanged?(false)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        switch shortcutMap.match(event, prefixPending: shortcutPrefixPending) {
        case .pass: return false
        case .prefix:
            shortcutPrefixPending = true
            onPrefixChanged?(true)
        case .action(let action):
            clearShortcutPrefix()
            onShortcut?(action)
        case .consumed:
            clearShortcutPrefix()
        }
        return true
    }
    private var decodedGraphics: [Data: NSImage] = [:]

    /// Decodes new images; the view redraws only when an image or its placement changed.
    func prepareGraphics(_ graphics: [HerdrGraphic]) {
        let placements = graphics.map(GraphicPlacement.init)
        guard placements != graphicPlacements else { return }
        graphicPlacements = placements
        let keys = Set(graphics.map { $0.key.identity })
        decodedGraphics = decodedGraphics.filter { keys.contains($0.key) }
        for graphic in graphics where decodedGraphics[graphic.key.identity] == nil {
            guard let image = Self.decodeGraphic(graphic) else { continue }
            decodedGraphics[graphic.key.identity] = image
        }
        needsDisplay = true
    }

    private struct GraphicPlacement: Equatable {
        let key: HerdrGraphicKey
        let frame: [Int]

        init(_ graphic: HerdrGraphic) {
            key = graphic.key
            frame = [graphic.x, graphic.y, graphic.cols, graphic.rows, graphic.sourceX, graphic.sourceY,
                     graphic.sourceWidth, graphic.sourceHeight, graphic.xOffset, graphic.yOffset, graphic.z]
        }
    }

    private var graphicPlacements: [GraphicPlacement] = []

    static func decodeGraphic(_ graphic: HerdrGraphic) -> NSImage? {
        if graphic.key.format == .png { return NSImage(data: graphic.data) }
        let channels = graphic.key.format == .rgba ? 4 : 3
        let (rowBytes, overflow) = graphic.key.width.multipliedReportingOverflow(by: channels)
        guard !overflow, rowBytes <= Int.max / graphic.key.height,
              graphic.data.count == rowBytes * graphic.key.height,
              let provider = CGDataProvider(data: graphic.data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = channels == 4 ? .last : .none
        guard let cgImage = CGImage(width: graphic.key.width, height: graphic.key.height,
                                    bitsPerComponent: 8, bitsPerPixel: channels * 8,
                                    bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: graphic.key.width, height: graphic.key.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid = terminalGrid, let context = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }
        let drawStart = TerminalPipelineMetrics.now()
        let signpost = TerminalPipelineMetrics.signposter.beginInterval("draw")
        defer {
            TerminalPipelineMetrics.signposter.endInterval("draw", signpost)
            if let surface { TerminalPipelineMetrics.shared?.drawn(surface, start: drawStart) }
        }
        let cellWidth = TerminalPaneView.cellWidth
        let cellHeight = TerminalPaneView.cellHeight
        let origin = CGPoint(x: textContainerInset.width, y: textContainerInset.height)
        // Fallback glyphs may overhang their row, so rows beside the dirty area redraw too.
        let visibleRows = grid.rows.indices.filter { row in
            let top = origin.y + CGFloat(row) * cellHeight
            return top + 2 * cellHeight >= dirtyRect.minY && top - cellHeight <= dirtyRect.maxY
        }
        drawGraphics(in: dirtyRect, behindText: true)
        for row in visibleRows {
            let top = origin.y + CGFloat(row) * cellHeight
            for fill in grid.rows[row].backgrounds {
                context.setFillColor(fill.color)
                context.fill(fill.rect.offsetBy(dx: origin.x, dy: top))
            }
        }
        let selection = orderedSelection(in: grid)
        if let selection {
            context.setFillColor(grid.selectionFill)
            for row in selection.start.row...selection.end.row {
                let columns = selectedColumns(row: row, selection: selection, width: grid.width)
                guard !columns.isEmpty else { continue }
                context.fill(CGRect(x: origin.x + CGFloat(columns.lowerBound) * cellWidth,
                                    y: origin.y + CGFloat(row) * cellHeight,
                                    width: CGFloat(columns.count) * cellWidth, height: cellHeight))
            }
        }
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelPositioning(true)
        for row in visibleRows {
            let top = origin.y + CGFloat(row) * cellHeight
            let selected = selection.map { selectedColumns(row: row, selection: $0, width: grid.width) } ?? 0..<0
            context.saveGState()
            context.translateBy(x: origin.x, y: top + TerminalPaneView.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            for run in grid.rows[row].runs {
                if selected.isEmpty || !run.columns.contains(where: selected.contains) {
                    context.setFillColor(run.color)
                    CTFontDrawGlyphs(run.font, run.glyphs, run.positions, run.glyphs.count, context)
                    continue
                }
                for index in run.glyphs.indices {
                    context.setFillColor(selected.contains(run.columns[index]) ? grid.selectionText : run.color)
                    CTFontDrawGlyphs(run.font, [run.glyphs[index]], [run.positions[index]], 1, context)
                }
            }
            context.restoreGState()
        }
        for row in visibleRows {
            let top = origin.y + CGFloat(row) * cellHeight
            for fill in grid.rows[row].underlines {
                context.setFillColor(fill.color)
                context.fill(fill.rect.offsetBy(dx: origin.x, dy: top))
            }
        }
        if let hoveredLink {
            let thickness = max(1, TerminalPaneView.terminalFont.underlineThickness)
            let lineY = TerminalPaneView.baseline - TerminalPaneView.terminalFont.underlinePosition - thickness / 2
            context.setFillColor(theme.terminalForeground.cgColor)
            for span in hoveredLink.spans where span.row < grid.height {
                context.fill(CGRect(x: origin.x + CGFloat(span.columns.lowerBound) * cellWidth,
                                    y: origin.y + CGFloat(span.row) * cellHeight + lineY,
                                    width: CGFloat(span.columns.count) * cellWidth, height: thickness))
            }
        }
        drawGraphics(in: dirtyRect, behindText: false)
    }

    private func drawGraphics(in dirtyRect: NSRect, behindText: Bool) {
        guard let surface else { return }
        let viewport = NSRect(x: textContainerInset.width, y: textContainerInset.height,
                              width: CGFloat(surface.width) * TerminalPaneView.cellWidth,
                              height: CGFloat(surface.height) * TerminalPaneView.cellHeight)
        NSGraphicsContext.current?.saveGraphicsState()
        viewport.intersection(dirtyRect).clip()
        for graphic in surface.graphics.sorted(by: { $0.z < $1.z }) where (graphic.z < 0) == behindText {
            guard let image = decodedGraphics[graphic.key.identity],
                  graphic.cols > 0, graphic.rows > 0,
                  graphic.sourceWidth > 0, graphic.sourceHeight > 0 else { continue }
            let destination = NSRect(x: viewport.minX + CGFloat(graphic.x) * TerminalPaneView.cellWidth + CGFloat(graphic.xOffset),
                                     y: viewport.minY + CGFloat(graphic.y) * TerminalPaneView.cellHeight + CGFloat(graphic.yOffset),
                                     width: CGFloat(graphic.cols) * TerminalPaneView.cellWidth,
                                     height: CGFloat(graphic.rows) * TerminalPaneView.cellHeight)
            guard destination.intersects(dirtyRect) else { continue }
            let source = NSRect(x: graphic.sourceX,
                                y: graphic.key.height - graphic.sourceY - graphic.sourceHeight,
                                width: graphic.sourceWidth, height: graphic.sourceHeight)
            image.draw(in: destination, from: source, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    func clearTerminalSelection() {
        selectedSnapshot = nil
        selectionAtSnapshot = nil
        selectionAnchor = nil
        selectionHead = nil
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
    }

    /// Shows a live surface, laying the grid out again only when its content changed.
    func show(_ surface: HerdrSurface?) {
        guard let surface else { return }
        TerminalTypingProbe.target = self
        let start = TerminalPipelineMetrics.now()
        let splitsChanged = self.surface?.splits != surface.splits
        self.surface = surface
        prepareGraphics(surface.graphics)
        if splitsChanged { window?.invalidateCursorRects(for: self) }
        guard surfaceRevision != surface.revision || surfaceBootID != surface.bootID else { return }
        if surfaceBootID != nil && surfaceBootID != surface.bootID { clearTerminalSelection() }
        surfaceRevision = surface.revision
        surfaceBootID = surface.bootID
        let layoutStart = TerminalPipelineMetrics.now()
        let grid = TerminalPipelineMetrics.signposter.withIntervalSignpost("layout") {
            TerminalPaneView.layoutGrid(surface, theme: theme, previous: terminalGrid)
        }
        let layoutNanos = TerminalPipelineMetrics.now() - layoutStart
        applySurfaceGrid(grid)
        if hoveredLink != nil { updateHoveredLink() }
        TerminalPipelineMetrics.shared?.updated(revision: surface.revision, start: start, layoutNanos: layoutNanos)
    }

    func applySurfaceGrid(_ grid: TerminalGrid) {
        // The grid is drawn directly; leftover fallback text would only feed TextKit.
        if !string.isEmpty { string = "" }
        let previous = terminalGrid
        terminalGrid = grid
        guard let previous, previous.width == grid.width, previous.height == grid.height else {
            needsDisplay = true
            return
        }
        // Redraw only the rows whose content changed, with a row of margin for overhanging glyphs.
        let cellHeight = TerminalPaneView.cellHeight
        for range in grid.changedRows(since: previous) {
            let top = textContainerInset.height + CGFloat(range.lowerBound - 1) * cellHeight
            setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: CGFloat(range.count + 2) * cellHeight))
        }
    }

    private var hasCellSelection: Bool {
        guard let terminalGrid else { return false }
        return orderedSelection(in: terminalGrid) != nil
    }

    private func orderedSelection(in grid: TerminalGrid) -> (start: GridPoint, end: GridPoint)? {
        guard let selectionAnchor, let selectionHead, selectionAnchor != selectionHead,
              grid.width > 0, grid.height > 0 else { return nil }
        func clamped(_ point: GridPoint) -> GridPoint {
            GridPoint(row: min(max(0, point.row), grid.height - 1), column: min(max(0, point.column), grid.width))
        }
        let start = clamped(min(selectionAnchor, selectionHead))
        let end = clamped(max(selectionAnchor, selectionHead))
        return start < end ? (start, end) : nil
    }

    private func selectedColumns(row: Int, selection: (start: GridPoint, end: GridPoint), width: Int) -> Range<Int> {
        guard row >= selection.start.row, row <= selection.end.row else { return 0..<0 }
        let lower = row == selection.start.row ? selection.start.column : 0
        let upper = row == selection.end.row ? selection.end.column : width
        return lower < upper ? lower..<upper : 0..<0
    }

    /// The text of the cells selected in the live grid.
    func selectedCellText() -> String? {
        guard let grid = terminalGrid, let selection = orderedSelection(in: grid) else { return nil }
        return (selection.start.row...selection.end.row).map { row in
            grid.rows[row].symbols[selectedColumns(row: row, selection: selection, width: grid.width)].joined()
        }.joined(separator: "\n")
    }

    /// The caret position nearest to the pointer, clamped to the grid.
    private func gridPoint(_ event: NSEvent, in grid: TerminalGrid) -> GridPoint {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
        let column = Int(((point.x - textContainerInset.width) / TerminalPaneView.cellWidth).rounded())
        return GridPoint(row: min(max(0, row), grid.height - 1), column: min(max(0, column), grid.width))
    }

    private func beginCellSelection(with event: NSEvent, in grid: TerminalGrid) {
        window?.makeFirstResponder(self)
        guard grid.width > 0, grid.height > 0 else { return }
        let point = gridPoint(event, in: grid)
        selectedSnapshot = nil
        let cell = min(max(0, surfacePoint(event).0), grid.width - 1)
        let word = TerminalPointer.wordRange(in: grid.rows[point.row].symbols, at: cell)
        switch event.clickCount {
        case 2 where word != nil:
            selectionAnchor = GridPoint(row: point.row, column: word!.lowerBound)
            selectionHead = GridPoint(row: point.row, column: word!.upperBound)
        case 3...:
            selectionAnchor = GridPoint(row: point.row, column: 0)
            selectionHead = GridPoint(row: point.row, column: grid.width)
        default:
            if !event.modifierFlags.contains(.shift) || selectionAnchor == nil { selectionAnchor = point }
            selectionHead = point
        }
        isSelectingCells = event.clickCount < 2
        selectedSnapshot = selectedCellText()
        needsDisplay = true
    }

    func applyFallbackText(_ text: String) {
        let selection = selectedRange()
        if selection.length > 0 { captureSelectionIfChanged() }
        string = text
        if selection.location != NSNotFound && selection.length > 0 {
            let start = min(selection.location, (text as NSString).length)
            let end = min(NSMaxRange(selection), (text as NSString).length)
            let restored = NSRange(location: start, length: max(0, end - start))
            setSelectedRange(restored)
            selectionAtSnapshot = restored
        }
    }

    private func captureSelectionIfChanged() {
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= (string as NSString).length else {
            selectedSnapshot = nil
            selectionAtSnapshot = nil
            return
        }
        guard selectionAtSnapshot != selection || selectedSnapshot == nil else { return }
        selectedSnapshot = (string as NSString).substring(with: selection)
        selectionAtSnapshot = selection
    }

    override func copy(_ sender: Any?) {
        if terminalGrid != nil {
            // The text captured when the selection was made, not what the screen shows now.
            selectedSnapshot = selectedSnapshot ?? selectedCellText()
        } else {
            captureSelectionIfChanged()
        }
        guard let selectedSnapshot, !selectedSnapshot.isEmpty else { return }
        let lines = selectedSnapshot.components(separatedBy: "\n")
        let copyText = lines.map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    /// The grid selection is not a TextKit range, so NSTextView alone would disable Copy.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), terminalGrid != nil { return hasCellSelection }
        return super.validateUserInterfaceItem(item)
    }

    override func selectAll(_ sender: Any?) {
        if let grid = terminalGrid {
            selectionAnchor = GridPoint(row: 0, column: 0)
            selectionHead = GridPoint(row: grid.height - 1, column: grid.width)
            selectedSnapshot = selectedCellText()
            needsDisplay = true
            return
        }
        super.selectAll(sender)
        selectedSnapshot = nil
        captureSelectionIfChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredLink(at: event.locationInWindow, modifiers: event.modifierFlags)
        if hoveredLink != nil {
            NSCursor.pointingHand.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoveredLink(modifiers: event.modifierFlags)
    }

    /// The live surface's link at a window location.
    private func link(at windowPoint: NSPoint) -> TerminalLink? {
        guard let surface, terminalGrid != nil else { return nil }
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let x = Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth))
        let y = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
        guard x >= 0, y >= 0, x < surface.width, y < surface.height else { return nil }
        return TerminalLinks.link(atColumn: x, row: y, in: surface)
    }

    /// Underlines the link under the pointer while Command is held, as iTerm2 does.
    private func updateHoveredLink(at windowPoint: NSPoint? = nil, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard modifiers.contains(.command), let window else { return setHoveredLink(nil) }
        setHoveredLink(link(at: windowPoint ?? window.mouseLocationOutsideOfEventStream))
    }

    private func setHoveredLink(_ link: TerminalLink?) {
        guard link != hoveredLink else { return }
        for span in (hoveredLink?.spans ?? []) + (link?.spans ?? []) {
            setNeedsDisplay(NSRect(x: 0, y: textContainerInset.height + CGFloat(span.row) * TerminalPaneView.cellHeight,
                                   width: bounds.width, height: TerminalPaneView.cellHeight))
        }
        hoveredLink = link
        (link == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let surface else { return }
        for split in surface.splits {
            let rect = split.hitRect
            guard rect.width > 0, rect.height > 0 else { continue }
            addCursorRect(NSRect(x: textContainerInset.width + CGFloat(rect.x) * TerminalPaneView.cellWidth,
                                 y: textContainerInset.height + CGFloat(rect.y) * TerminalPaneView.cellHeight,
                                 width: CGFloat(rect.width) * TerminalPaneView.cellWidth,
                                 height: CGFloat(rect.height) * TerminalPaneView.cellHeight),
                          cursor: split.direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let link = link(at: event.locationInWindow) {
            NSWorkspace.shared.open(link.url)
            return
        }
        if let surface {
            if let split = splitHit(event, in: surface) {
                let (x, y) = surfacePoint(event)
                let pointer = split.direction == .horizontal ? x : y
                splitDrag = (split, split.pos - pointer, surface.bootID, 0, nil)
                window?.makeFirstResponder(self)
                return
            }
            if let (id, _, _) = mouseHit(event, in: surface) {
                selectPane?(id)
            }
        }
        if !event.modifierFlags.contains(.shift),
           forwardMouse(.down(0), event: event, hold: true) { return }
        if let terminalGrid {
            beginCellSelection(with: event, in: terminalGrid)
            return
        }
        selectedSnapshot = nil
        selectionAtSnapshot = nil
        super.mouseDown(with: event)
        captureSelectionIfChanged()
    }

    override func mouseUp(with event: NSEvent) {
        if splitDrag != nil {
            updateSplitDrag(with: event, finished: true)
            splitDrag = nil
            return
        }
        if releaseMouse(button: 0, event: event) { return }
        if terminalGrid != nil {
            isSelectingCells = false
            selectedSnapshot = selectedCellText()
            return
        }
        super.mouseUp(with: event)
        captureSelectionIfChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        if splitDrag != nil {
            updateSplitDrag(with: event, finished: false)
            return
        }
        if dragMouse(button: 0, event: event) { return }
        if let terminalGrid {
            guard isSelectingCells else { return }
            selectionHead = gridPoint(event, in: terminalGrid)
            needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
        captureSelectionIfChanged()
    }

    private func surfacePoint(_ event: NSEvent) -> (Int, Int) {
        let point = convert(event.locationInWindow, from: nil)
        return (Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth)),
                Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight)))
    }

    private func splitHit(_ event: NSEvent, in surface: HerdrSurface) -> HerdrSplit? {
        let (x, y) = surfacePoint(event)
        return TerminalPointer.split(atColumn: x, row: y, in: surface)
    }

    private func updateSplitDrag(with event: NSEvent, finished: Bool) {
        guard var drag = splitDrag, let surface,
              surface.bootID == drag.bootID,
              surface.splits.contains(where: {
                  $0.path == drag.split.path && $0.direction == drag.split.direction && $0.area == drag.split.area
              }) else {
            splitDrag = nil
            return
        }
        let (x, y) = surfacePoint(event)
        let split = drag.split
        let pointer = split.direction == .horizontal ? x : y
        let ratio = TerminalPointer.splitRatio(split, pointer: pointer, grabOffset: drag.grabOffset)
        let now = ProcessInfo.processInfo.systemUptime
        if finished || now - drag.lastSentAt >= 0.033 {
            if drag.lastRatio != ratio {
                setSplitRatio?(split.path, ratio)
                drag.lastRatio = ratio
            }
            drag.lastSentAt = now
        }
        splitDrag = drag
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click opens the pane menu; Option-right-click still reaches mouse-aware programs.
        if event.modifierFlags.contains(.option),
           forwardMouse(.down(1), event: event, hold: true) { return }
        if let surface, let (id, _, _) = mouseHit(event, in: surface) { selectPane?(id) }
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(standardItem("Copy", #selector(copy(_:)), enabled: hasCellSelection || selectedRange().length > 0))
        menu.addItem(standardItem("Paste", #selector(paste(_:)),
                                  enabled: NSPasteboard.general.string(forType: .string) != nil))
        menu.addItem(standardItem("Select All", #selector(selectAll(_:)), enabled: true))
        menu.addItem(.separator())
        menu.addItem(herdrItem("Split Right", "split_vertical", symbol: "rectangle.split.2x1"))
        menu.addItem(herdrItem("Split Down", "split_horizontal", symbol: "rectangle.split.1x2"))
        menu.addItem(herdrItem("Zoom Pane", "zoom", symbol: "arrow.up.left.and.arrow.down.right"))
        let focus = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        focus.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
        focus.submenu = NSMenu()
        focus.submenu?.addItem(herdrItem("Left", "focus_pane_left", symbol: "arrow.left"))
        focus.submenu?.addItem(herdrItem("Right", "focus_pane_right", symbol: "arrow.right"))
        focus.submenu?.addItem(herdrItem("Up", "focus_pane_up", symbol: "arrow.up"))
        focus.submenu?.addItem(herdrItem("Down", "focus_pane_down", symbol: "arrow.down"))
        menu.addItem(focus)
        menu.addItem(.separator())
        menu.addItem(herdrItem("Copy Working Directory", "copy_pane_cwd", symbol: "doc.on.doc"))
        menu.addItem(herdrItem("Reveal in Finder", "reveal_pane_cwd", symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(herdrItem("Find in Project…", "project_search", symbol: "magnifyingglass"))
        menu.addItem(herdrItem("Replace in Project…", "project_replace", symbol: "text.magnifyingglass"))
        menu.addItem(.separator())
        menu.addItem(herdrItem("New Tab", "new_tab", symbol: "plus"))
        menu.addItem(herdrItem("Previous Tab", "previous_tab", symbol: "chevron.left"))
        menu.addItem(herdrItem("Next Tab", "next_tab", symbol: "chevron.right"))
        menu.addItem(herdrItem("New Space", "new_workspace", symbol: "plus.square"))
        menu.addItem(.separator())
        menu.addItem(herdrItem("Toggle Sidebar", "toggle_sidebar", symbol: "sidebar.left"))
        menu.addItem(herdrItem("Shortcut Help", "help", symbol: "keyboard"))
        menu.addItem(.separator())
        menu.addItem(herdrItem("Close Pane…", "close_pane", symbol: "xmark.square"))
        return menu
    }

    private func standardItem(_ title: String, _ selector: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A menu item that runs a Herdr action and shows its binding from config.toml.
    private func herdrItem(_ title: String, _ action: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performHerdrAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let shortcut = shortcutMap.displayLabel(for: action) {
            let font = NSFont.menuFont(ofSize: 0)
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            let label = NSMutableAttributedString(string: title + "\t",
                                                  attributes: [.font: font, .paragraphStyle: style])
            label.append(NSAttributedString(string: shortcut, attributes: [
                .font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor
            ]))
            item.attributedTitle = label
            item.toolTip = "Herdr shortcut: \(shortcut)"
        }
        return item
    }

    @objc private func performHerdrAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        onShortcut?(action)
    }

    override func rightMouseUp(with event: NSEvent) {
        if releaseMouse(button: 1, event: event) { return }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if dragMouse(button: 1, event: event) { return }
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, forwardMouse(.down(2), event: event, hold: true) { return }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, releaseMouse(button: 2, event: event) { return }
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, dragMouse(button: 2, event: event) { return }
        super.otherMouseDragged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface, let (id, column, row) = mouseHit(event, in: surface),
              surface.mouseReportingPaneIDs.contains(id) else {
            scroll.reset()
            super.scrollWheel(with: event)
            return
        }
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        guard let lines = scroll.lines(for: delta, precise: event.hasPreciseScrollingDeltas,
                                       lineHeight: TerminalPaneView.cellHeight) else { return }
        let kind: HerdrMouseEvent.Kind = vertical
            ? (delta > 0 ? .scrollUp : .scrollDown)
            : (delta > 0 ? .scrollLeft : .scrollRight)
        sendMouse?(HerdrMouseEvent(kind: kind, column: column, row: row,
                                   modifiers: mouseModifiers(event), lines: lines), id)
    }

    private func mouseHit(_ event: NSEvent, in surface: HerdrSurface) -> (String, UInt16, UInt16)? {
        let (x, y) = surfacePoint(event)
        return TerminalPointer.pane(atColumn: x, row: y, in: surface).map { ($0.id, $0.column, $0.row) }
    }

    private func mouseModifiers(_ event: NSEvent) -> UInt8 {
        TerminalPointer.modifiers(event.modifierFlags)
    }

    private func forwardMouse(_ kind: HerdrMouseEvent.Kind, event: NSEvent, hold: Bool) -> Bool {
        guard let surface, let (id, column, row) = mouseHit(event, in: surface),
              surface.mouseReportingPaneIDs.contains(id) else { return false }
        window?.makeFirstResponder(self)
        if hold, case .down(let button) = kind { heldMouse = (id, button) }
        sendMouse?(HerdrMouseEvent(kind: kind, column: column, row: row,
                                   modifiers: mouseModifiers(event), lines: 1), id)
        return true
    }

    private func dragMouse(button: UInt64, event: NSEvent) -> Bool {
        guard let heldMouse, heldMouse.button == button else { return false }
        return forwardHeldMouse(.drag(button), event: event, to: heldMouse.paneID)
    }

    private func releaseMouse(button: UInt64, event: NSEvent) -> Bool {
        guard let heldMouse, heldMouse.button == button else { return false }
        self.heldMouse = nil
        return forwardHeldMouse(.up(button), event: event, to: heldMouse.paneID)
    }

    private func forwardHeldMouse(_ kind: HerdrMouseEvent.Kind, event: NSEvent, to id: String) -> Bool {
        let (x, y) = surfacePoint(event)
        guard let inner = surface?.paneInnerRects[id], let cell = TerminalPointer.cell(column: x, row: y, inside: inner) else {
            return true
        }
        sendMouse?(HerdrMouseEvent(kind: kind, column: cell.column, row: cell.row,
                                   modifiers: mouseModifiers(event), lines: 1), id)
        return true
    }

    override func keyDown(with event: NSEvent) {
        TerminalPipelineMetrics.shared?.keyPressed(event, cursor: surface?.cursor)
        if handleShortcut(event) { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            super.keyDown(with: event) // Copy, select all, and other Mac commands.
            return
        }

        let special: [UInt16: String] = [
            36: "enter", 76: "enter", 48: "tab", 53: "esc", 51: "backspace",
            117: "delete", 123: "left", 124: "right", 125: "down", 126: "up",
            115: "home", 119: "end", 116: "pageup", 121: "pagedown"
        ]
        if let key = special[event.keyCode] {
            // Shift reaches Herdr so programs can tell Shift-Enter from Enter, as Claude Code does.
            let prefix = modifiers.contains(.shift) ? "shift+" : ""
            sendKey?(prefix + key, paneID)
            return
        }
        if modifiers.contains(.control),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           character.count == 1 {
            sendKey?("ctrl+\(character)", paneID)
            return
        }
        if modifiers.contains(.option),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           character.count == 1 {
            sendKey?("alt+\(character)", paneID)
            return
        }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if !value.isEmpty { sendText?(value, paneID) }
    }

    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string), !value.isEmpty {
            sendPaste?(value, paneID)
        }
    }

    // Dropped files paste their shell-escaped paths into the pane under the pointer,
    // as Terminal and iTerm do; dropped text pastes as is.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(sender.draggingPasteboard) else { return false }
        var target = paneID
        if let surface {
            let point = convert(sender.draggingLocation, from: nil)
            let x = Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth))
            let y = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
            if let id = TerminalPointer.paneID(atColumn: x, row: y, in: surface) {
                target = id
                if id != paneID { selectPane?(id) }
            }
        }
        window?.makeFirstResponder(self)
        sendPaste?(text, target)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    /// What a drop pastes: shell-escaped file paths, or text as is.
    func droppedText(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { Self.shellEscaped($0.path) }.joined(separator: " ") + " "
        }
        if let value = pasteboard.string(forType: .string), !value.isEmpty { return value }
        return nil
    }

    /// Backslash-escapes shell metacharacters, matching how Terminal inserts dropped paths.
    static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        var result = ""
        for scalar in path.unicodeScalars {
            if !scalar.isASCII || safe.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\" + String(scalar)
            }
        }
        return result
    }
}

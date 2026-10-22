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
        /// A hash of the cells, so finding a row compares whole rows only when it matches.
        /// Equal rows have equal fingerprints except where a symbol is a long string stored
        /// apart, which at worst lays that row out again.
        let fingerprint: UInt64

        init(cells: ArraySlice<HerdrCell>, cursorColumn: Int?, imageColumns: [Range<Int>]) {
            self.cells = cells
            self.cursorColumn = cursorColumn
            self.imageColumns = imageColumns
            fingerprint = Self.fingerprint(of: cells)
        }

        /// A multiplicative hash of each cell's bytes, read in place: the symbol's two words (a
        /// short symbol is stored inline, so equal ones have equal words) and its attributes,
        /// folded into one word so the chain costs one multiplication per cell.
        private static func fingerprint(of cells: ArraySlice<HerdrCell>) -> UInt64 {
            let symbol = MemoryLayout<HerdrCell>.offset(of: \HerdrCell.symbol)!
            let foreground = MemoryLayout<HerdrCell>.offset(of: \HerdrCell.foreground)!
            let background = MemoryLayout<HerdrCell>.offset(of: \HerdrCell.background)!
            let modifier = MemoryLayout<HerdrCell>.offset(of: \HerdrCell.modifier)!
            return cells.withUnsafeBytes { bytes in
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for start in stride(from: 0, to: bytes.count, by: MemoryLayout<HerdrCell>.stride) {
                    let colors = UInt64(bytes.loadUnaligned(fromByteOffset: start + foreground, as: UInt32.self)) << 32
                        | UInt64(bytes.loadUnaligned(fromByteOffset: start + background, as: UInt32.self))
                    let attributes = (colors ^ UInt64(bytes.loadUnaligned(fromByteOffset: start + modifier, as: UInt16.self)))
                        &* 0x9e37_79b9_7f4a_7c15
                    let high = bytes.loadUnaligned(fromByteOffset: start + symbol + 8, as: UInt64.self)
                    let word = bytes.loadUnaligned(fromByteOffset: start + symbol, as: UInt64.self)
                        ^ (high << 23 | high >> 41) ^ attributes
                    hash = (hash ^ word) &* 0x0000_0100_0000_01b3
                }
                return hash ^ hash >> 29
            }
        }

        /// Compares cells field by field in place: the synthesized comparison copies every cell,
        /// retaining and releasing its symbol, which made matching scrolled rows the main cost
        /// of a layout.
        static func == (lhs: RowKey, rhs: RowKey) -> Bool {
            guard lhs.cursorColumn == rhs.cursorColumn, lhs.imageColumns == rhs.imageColumns,
                  lhs.cells.count == rhs.cells.count else { return false }
            return lhs.cells.withUnsafeBufferPointer { left in
                rhs.cells.withUnsafeBufferPointer { right in
                    for index in left.indices {
                        guard left[index].foreground == right[index].foreground,
                              left[index].background == right[index].background,
                              left[index].modifier == right[index].modifier,
                              left[index].skip == right[index].skip,
                              left[index].hyperlink == right[index].hyperlink,
                              left[index].symbol == right[index].symbol else { return false }
                    }
                    return true
                }
            }
        }

        /// Whether `other` shows the same thing, compared whole only if the fingerprints match.
        func matches(_ other: RowKey) -> Bool {
            fingerprint == other.fingerprint && self == other
        }
    }

    let width: Int
    let height: Int
    let rows: [Row]
    let keys: [RowKey]
    let selectionFill: CGColor
    let selectionText: CGColor

    /// The index of a row laid out for `key`, checking `hint` first, then every other row.
    /// Fingerprints rule out other rows first, so a new row sharing a long prefix with every
    /// row of the previous screen (beside an empty pane, in a table) is not compared whole.
    func row(matching key: RowKey, near hint: Int) -> Int? {
        if hint >= 0, hint < height, keys[hint].matches(key) { return hint }
        return keys.indices.first { $0 != hint && keys[$0].matches(key) }
    }

    /// Runs of rows that show something different from `previous`, which has the same size.
    func changedRows(since previous: TerminalGrid) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for row in 0..<height where !previous.keys[row].matches(keys[row]) {
            if let last = ranges.last, last.upperBound == row {
                ranges[ranges.count - 1] = last.lowerBound..<(row + 1)
            } else {
                ranges.append(row..<(row + 1))
            }
        }
        return ranges
    }
}

/// Core Text's glyphs for pieces of row text, so text shown before (after a tab switch, a
/// resize or a split drag) is not shaped again. Shaping depends only on the text and its bold
/// and italic ranges, never on colors or the theme.
final class TerminalShapeCache {
    struct Key: Hashable {
        /// UTF-16, as Core Text indexes it.
        let units: [UInt16]
        /// Location, length and Ratatui bold/italic bits (1, 4 or 5) of each styled range.
        let styles: [Int]
    }

    struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        /// Positions from Core Text's layout of the piece, and UTF-16 offsets into it.
        let positions: [CGPoint]
        let indices: [Int]
    }

    static let shared = TerminalShapeCache()
    /// About 20 screens of text; the cache starts over once it holds more pieces.
    static let capacity = 2048

    private let lock = NSLock()
    private var pieces: [Key: [Run]] = [:]

    func runs(for key: Key) -> [Run] {
        lock.lock()
        let cached = pieces[key]
        lock.unlock()
        if let cached { return cached }
        let shaped = Self.shape(key)
        lock.lock()
        if pieces.count >= Self.capacity { pieces.removeAll(keepingCapacity: true) }
        pieces[key] = shaped
        lock.unlock()
        return shaped
    }

    func removeAll() {
        lock.lock()
        pieces.removeAll()
        lock.unlock()
    }

    private static func shape(_ key: Key) -> [Run] {
        let line = NSMutableAttributedString(string: String(decoding: key.units, as: UTF16.self),
                                             attributes: [.font: TerminalPaneView.terminalFont])
        for index in stride(from: 0, to: key.styles.count - 2, by: 3) {
            let font = switch key.styles[index + 2] {
            case 1: TerminalPaneView.boldFont
            case 4: TerminalPaneView.italicFont
            default: TerminalPaneView.boldItalicFont
            }
            line.addAttribute(.font, value: font, range: NSRange(location: key.styles[index], length: key.styles[index + 1]))
        }
        return (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(line)) as? [CTRun] ?? []).compactMap { ctRun in
            let count = CTRunGetGlyphCount(ctRun)
            guard count > 0 else { return nil }
            let attributes = CTRunGetAttributes(ctRun) as NSDictionary
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(ctRun, CFRange(), &glyphs)
            CTRunGetPositions(ctRun, CFRange(), &positions)
            CTRunGetStringIndices(ctRun, CFRange(), &indices)
            return Run(font: attributes[kCTFontAttributeName] as! CTFont, glyphs: glyphs,
                       positions: positions, indices: indices)
        }
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
    var onPresentSurface: ((HerdrSurface) -> Void)? = nil
    var sendPopupInput: ((HerdrInputEvent, String, String) -> Void)? = nil
    var closePopup: ((String, String) -> Void)? = nil
    let shortcutMap: HerdrShortcutMap
    let onShortcut: (String) -> Void
    let onPrefixChanged: (Bool) -> Void
    var selectPane: ((String) -> Void)? = nil
    let sendText: (String, String) -> Void
    let sendPaste: (String, String) -> Void
    let sendKey: (String, String) -> Void
    let sendMouse: (HerdrMouseEvent, String) -> Void
    let setSplitRatio: ([Bool], Double) -> Void
    /// Splits a terminal tab dragged from the tab bar into these panes; nil ignores tab drags.
    var tabDrop: TerminalTabDropHandler? = nil
    /// Checks the paths Command points at; nil leaves paths unlinked.
    var fileLinks: TerminalFileLinks? = nil
    /// Opens a path Command-clicked in a pane.
    var openFileLink: ((TerminalFileReference, String, WorkspaceTerminalPath) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = context.environment.woolooTheme.terminalBackground
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
        view.tabDrop = tabDrop
        view.fileLinks = fileLinks
        view.openFileLink = openFileLink
        view.onPresentSurface = onPresentSurface
        view.sendPopupInput = sendPopupInput
        view.closePopup = closePopup
        view.isRichText = false
        view.isEditable = true
        view.registerForDraggedTypes([.fileURL, .string, TerminalTabDrop.pasteboardType, TerminalTabDrop.panePasteboardType])
        view.isSelectable = true
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        view.drawsBackground = false
        view.textColor = context.environment.woolooTheme.terminalForeground
        view.font = Self.terminalFont
        view.textContainerInset = NSSize(width: 10, height: 9)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = view
        // Above the clip view, so the highlight stays put over the visible panes.
        let overlay = TerminalDropOverlayView(frame: scrollView.bounds)
        overlay.autoresizingMask = [.width, .height]
        scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
        view.dropOverlay = overlay
        overlay.pointerMoved = { [weak view] point in view?.updateMoveHandle(at: point) }
        overlay.moveHandle.makeMenu = { [weak view] pane in view?.paneMoveMenu(pane) ?? NSMenu() }
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
        view.tabDrop = tabDrop
        view.fileLinks = fileLinks
        view.openFileLink = openFileLink
        view.onPresentSurface = onPresentSurface
        view.sendPopupInput = sendPopupInput
        view.closePopup = closePopup
        let theme = context.environment.woolooTheme
        if view.themeID != theme.id {
            view.themeID = theme.id
            view.theme = theme
            view.terminalGrid = nil
            scrollView.backgroundColor = theme.terminalBackground
            view.textColor = theme.terminalForeground
            view.insertionPointColor = WoolooTheme.nsColor(theme.cursor)
            view.selectedTextAttributes = [.backgroundColor: WoolooTheme.nsColor(theme.selectionBackground)]
            view.surfaceRevision = nil
        }
        Self.configureScrolling(scrollView, view: view, live: surfaceFeed != nil)
        if let surfaceFeed {
            // Frames reach the view straight from the feed; SwiftUI only connects them once.
            if view.surfaceFeed !== surfaceFeed {
                view.surfaceFeed = surfaceFeed
                surfaceFeed.observe(view) { [weak view] surface, answersUser in
                    view?.show(surface)
                    // A key's echo or a new tab's first surface is drawn now rather than at the
                    // next display pass, which may wait for other work on the main thread.
                    if answersUser { view?.displayIfNeeded() }
                }
                view.show(surfaceFeed.surface)
                // The feed had no view to answer the user with while this one was missing.
                if surfaceFeed.takeAnswer() { view.displayIfNeeded() }
                return
            }
            view.show(surfaceFeed.surface)
            return
        }
        view.surface = nil
        view.displaySurface = nil
        view.popupCloseButton.isHidden = true
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
    static func layoutGrid(_ surface: HerdrSurface, theme: WoolooTheme, previous: TerminalGrid? = nil) -> TerminalGrid {
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
                cells: surface.cells.row(y),
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
        let selectionFill = WoolooTheme.nsColor(theme.selectionBackground)
        return TerminalGrid(width: surface.width, height: surface.height, rows: rows, keys: keys,
                            selectionFill: selectionFill.cgColor,
                            selectionText: readableText(on: selectionFill, theme: theme).cgColor)
    }

    /// Blank cells kept around the text Core Text shapes. No substitution in Fira Code looks
    /// further than 6 glyphs, and none starts at or replaces a space, so text separated by at
    /// least this many blanks shapes alike apart; `TerminalRenderingTests` checks it.
    static let shapingContext = 8

    /// Places each cell's glyphs at the cell origin. Core Text shapes the row's text, so font
    /// fallback and ligatures work, but its advances never move the next column. Runs of blanks
    /// longer than `shapingContext` split the text, so padding and blank rows cost no shaping.
    private static func layoutRow(_ key: TerminalGrid.RowKey, theme: WoolooTheme,
                                  palette: inout TerminalPalette) -> TerminalGrid.Row {
        let underlineY = -terminalFont.underlinePosition
        let underlineHeight = max(1, terminalFont.underlineThickness)
        let cells = key.cells
        let width = cells.count
        var backgrounds: [TerminalGrid.Fill] = []
        var underlines: [TerminalGrid.Fill] = []
        /// The row's text in UTF-16, as Core Text indexes it.
        var units: [UInt16] = []
        units.reserveCapacity(width)
        var fontRanges: [(range: NSRange, font: NSFont)] = []
        var rowSymbols: [String] = []
        rowSymbols.reserveCapacity(width)
        var foregrounds: [CGColor] = []
        foregrounds.reserveCapacity(width)
        /// The cell column of every unit in `units`.
        var columnAt: [Int] = []
        columnAt.reserveCapacity(width)
        /// The first unit in `units` of every column.
        var unitAt: [Int] = []
        unitAt.reserveCapacity(width)
        /// Columns from the first to the last non-blank cell of each piece of text to shape.
        var segments: [Range<Int>] = []
        var lastText = -1
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
            unitAt.append(columnAt.count)
            if cell.skip {
                rowSymbols.append("")
                continue
            }
            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            rowSymbols.append(symbol)
            // Herdr's scrollbar uses right-side block elements. Draw them to the cell's
            // full height; font glyphs leave gaps between rows at our line spacing.
            let blockWidth: CGFloat? = symbol == "▕" ? cellWidth / 8 : symbol == "▐" ? cellWidth / 2 : nil
            if let blockWidth {
                underlines.append(TerminalGrid.Fill(
                    rect: CGRect(x: CGFloat(x + 1) * cellWidth - blockWidth, y: 0,
                                 width: blockWidth, height: cellHeight), color: textColor))
            }
            if symbol != " " && blockWidth == nil {
                if let last = segments.last, x - lastText <= shapingContext {
                    segments[segments.count - 1] = last.lowerBound..<(x + 1)
                } else {
                    segments.append(x..<(x + 1))
                }
                lastText = x
            }
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
            units.append(contentsOf: (blockWidth == nil ? symbol : " ").utf16)
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
        var runs: [TerminalGrid.GlyphRun] = []
        guard !segments.isEmpty else {
            return TerminalGrid.Row(symbols: rowSymbols, backgrounds: backgrounds, runs: runs, underlines: underlines)
        }
        /// Adds the glyphs of a shaped piece of the row that starts at `units[offset]`.
        func appendGlyphRuns(_ shaped: [TerminalShapeCache.Run], offset: Int) {
            for run in shaped {
                // Glyphs sharing a cell (combining marks, clusters) keep their offsets from
                // the cell's first glyph.
                var cellStart: (column: Int, x: CGFloat)?
                for index in run.glyphs.indices {
                    let column = columnAt[min(max(0, offset + run.indices[index]), columnAt.count - 1)]
                    if rowSymbols[column] == " " { continue }
                    if cellStart?.column != column { cellStart = (column, run.positions[index].x) }
                    let position = CGPoint(x: CGFloat(column) * cellWidth + (run.positions[index].x - (cellStart?.x ?? 0)),
                                           y: run.positions[index].y)
                    let textColor = foregrounds[column]
                    // Indexing instead of binding `runs.last` keeps the arrays uniquely referenced,
                    // so appending never copies them.
                    let last = runs.count - 1
                    if last >= 0, runs[last].color === textColor, runs[last].font == run.font {
                        runs[last].glyphs.append(run.glyphs[index])
                        runs[last].positions.append(position)
                        runs[last].columns.append(column)
                    } else {
                        var glyphRun = TerminalGrid.GlyphRun(font: run.font, color: textColor)
                        let remaining = run.glyphs.count - index
                        glyphRun.glyphs.reserveCapacity(remaining)
                        glyphRun.positions.reserveCapacity(remaining)
                        glyphRun.columns.reserveCapacity(remaining)
                        glyphRun.glyphs.append(run.glyphs[index])
                        glyphRun.positions.append(position)
                        glyphRun.columns.append(column)
                        runs.append(glyphRun)
                    }
                }
            }
        }

        for segment in segments {
            // The blanks around the text stay, since spaces are context for some ligatures.
            let lower = max(0, segment.lowerBound - shapingContext)
            let upper = min(width, segment.upperBound + shapingContext)
            let first = unitAt[lower]
            let end = upper < width ? unitAt[upper] : columnAt.count
            var styles: [Int] = []
            for (range, font) in fontRanges where range.location < end && NSMaxRange(range) > first {
                let start = max(range.location, first)
                styles += [start - first, min(NSMaxRange(range), end) - start,
                           font === boldFont ? 1 : font === italicFont ? 4 : 5]
            }
            let key = TerminalShapeCache.Key(units: Array(units[first..<end]), styles: styles)
            appendGlyphRuns(TerminalShapeCache.shared.runs(for: key), offset: first)
        }
        return TerminalGrid.Row(symbols: rowSymbols, backgrounds: backgrounds, runs: runs, underlines: underlines)
    }

    /// The theme's foreground or background, whichever contrasts more with `fill`.
    private static func readableText(on fill: NSColor, theme: WoolooTheme) -> NSColor {
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
        let theme: WoolooTheme
        private var foregrounds: [UInt32: CGColor] = [:]
        private var backgrounds: [UInt32: CGColor] = [:]
        /// The last lookups, since neighboring cells mostly share their colors.
        private var lastForeground: (value: UInt32, color: CGColor)?
        private var lastBackground: (value: UInt32, color: CGColor)?
        private var dims: [ObjectIdentifier: [ObjectIdentifier: CGColor]] = [:]

        init(theme: WoolooTheme) { self.theme = theme }

        /// A cell's text color; `reversed` means `value` is a background whose default is the
        /// theme background.
        mutating func foreground(_ value: UInt32, reversed: Bool = false) -> CGColor {
            if reversed { return background(value) }
            if let last = lastForeground, last.value == value { return last.color }
            let color: CGColor
            if let cached = foregrounds[value] {
                color = cached
            } else {
                color = Self.resolve(value, default: theme.terminalForeground, ansi: theme.ansi)
                foregrounds[value] = color
            }
            lastForeground = (value, color)
            return color
        }

        /// A cell's fill color; `reversed` means `value` is a foreground whose default is the
        /// theme foreground.
        mutating func background(_ value: UInt32, reversed: Bool = false) -> CGColor {
            if reversed { return foreground(value) }
            if let last = lastBackground, last.value == value { return last.color }
            let color: CGColor
            if let cached = backgrounds[value] {
                color = cached
            } else {
                color = Self.resolve(value, default: theme.terminalBackground, ansi: theme.ansi)
                backgrounds[value] = color
            }
            lastBackground = (value, color)
            return color
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

        /// Static, so a lookup never copies the palette and its theme, as a method on `self`
        /// taking one of its own caches `inout` would.
        private static func resolve(_ value: UInt32, default fallback: NSColor, ansi: [UInt32]) -> CGColor {
            TerminalPaneView.color(value, default: fallback, ansi: ansi).cgColor
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

    enum Target: Equatable {
        case web(URL)
        /// A path as printed, which may be relative to the pane's directory, with the line and
        /// column after it.
        case file(TerminalFileReference)
    }

    let target: Target
    /// The pane showing the link, whose directory relative paths start from.
    let paneID: String
    let spans: [Span]

    var url: URL? {
        if case .web(let url) = target { return url }
        return nil
    }

    var file: TerminalFileReference? {
        if case .file(let file) = target { return file }
        return nil
    }
}

struct TerminalFileReference: Hashable, Sendable {
    let path: String
    var line: Int? = nil
    var column: Int? = nil
}

/// Finds the link under a surface cell for Command-click: an OSC 8 hyperlink, as Claude Code
/// prints, or a URL or path in plain text, as iTerm2 and VS Code detect. Web links open in the
/// browser; paths only name a candidate, which `TerminalFileLinks` checks on disk.
enum TerminalLinks {
    static func link(atColumn x: Int, row y: Int, in surface: HerdrSurface) -> TerminalLink? {
        guard let id = TerminalPointer.paneID(atColumn: x, row: y, in: surface),
              let inner = surface.paneInnerRects[id],
              x >= inner.x, x < inner.x + inner.width, y >= inner.y, y < inner.y + inner.height,
              inner.x + inner.width <= surface.width, inner.y + inner.height <= surface.height else { return nil }
        let clicked = (y - inner.y) * inner.width + (x - inner.x)
        return explicitLink(at: clicked, inside: inner, in: surface, paneID: id)
            ?? plainLink(at: clicked, inside: inner, in: surface, paneID: id)
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// An OSC 8 destination: a web URL, or a `file:` URL's path, which never runs or opens
    /// anything by itself.
    static func target(_ text: String) -> TerminalLink.Target? {
        if let url = webURL(text) { return .web(url) }
        guard let url = URL(string: text), url.scheme?.lowercased() == "file", url.path.hasPrefix("/") else { return nil }
        return .file(TerminalFileReference(path: url.path))
    }

    /// The cell at `index`, counted row by row across the pane's content.
    private static func cell(_ index: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> HerdrCell {
        surface.cells[inner.x + index % inner.width, inner.y + index / inner.width]
    }

    private static func hyperlink(_ index: Int, inside inner: HerdrRect, in surface: HerdrSurface) -> UInt32? {
        let current = cell(index, inside: inner, in: surface)
        if let hyperlink = current.hyperlink { return hyperlink }
        // A wide character's continuation cell may not carry the link itself.
        guard current.skip, index % inner.width > 0 else { return nil }
        return cell(index - 1, inside: inner, in: surface).hyperlink
    }

    /// Adjacent cells with the clicked cell's OSC 8 destination, across wrapped rows too.
    private static func explicitLink(at clicked: Int, inside inner: HerdrRect, in surface: HerdrSurface,
                                     paneID: String) -> TerminalLink? {
        guard let id = hyperlink(clicked, inside: inner, in: surface), Int(id) < surface.hyperlinks.count,
              let target = target(surface.hyperlinks[Int(id)]) else { return nil }
        var start = clicked
        var end = clicked
        while start > 0, hyperlink(start - 1, inside: inner, in: surface) == id { start -= 1 }
        while end + 1 < inner.width * inner.height, hyperlink(end + 1, inside: inner, in: surface) == id { end += 1 }
        return TerminalLink(target: target, paneID: paneID, spans: spans(start...end, inside: inner))
    }

    private static let plainURL = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

    /// Paths as compilers, test runners, `grep -n` and Python print them: `src/a.swift:12:5`,
    /// `a.ts(12,5)`, `File "a.py", line 12`. No spaces, as in Zed; a path in quotes may have them.
    private static let plainPath = try! NSRegularExpression(pattern:
        #"File "(?<quoted>[^"]+)", line (?<quotedLine>\d+)"#
        + #"|(?<path>(?:~|\.{1,2})?/?(?:[\w.@+\-]+/)*[\w.@+\-][\w.@+\-]*)"#
        + #"(?::(?<line>\d+)(?::(?<column>\d+))?|\((?<parenLine>\d+)(?:,\s*(?<parenColumn>\d+))?\))?"#)

    /// The text of the rows around the clicked cell, with the pane cell of every UTF-16 unit.
    /// Rows whose last cell is filled continue on the next row, so a long URL or path the
    /// terminal wrapped is found whole.
    private static func logicalLine(around clicked: Int, inside inner: HerdrRect,
                                    in surface: HerdrSurface) -> (text: String, cellAt: [Int]) {
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
        var cellAt: [Int] = []
        for index in (first * width)..<((last + 1) * width) {
            let current = cell(index, inside: inner, in: surface)
            guard !current.skip else { continue }
            let symbol = current.symbol.isEmpty ? " " : current.symbol
            text += symbol
            cellAt.append(contentsOf: repeatElement(index, count: symbol.utf16.count))
        }
        return (text, cellAt)
    }

    private static func plainLink(at clicked: Int, inside inner: HerdrRect, in surface: HerdrSurface,
                                  paneID: String) -> TerminalLink? {
        let (text, cellAt) = logicalLine(around: clicked, inside: inner, in: surface)
        let string = text as NSString
        let all = NSRange(location: 0, length: string.length)
        /// The link's cells when `range` of `text` covers the clicked cell.
        func cells(_ range: NSRange) -> ClosedRange<Int>? {
            guard range.length > 0 else { return nil }
            let start = cellAt[range.location]
            var end = cellAt[NSMaxRange(range) - 1]
            // A wide last character also covers its continuation cell.
            if end + 1 < inner.width * inner.height, end % inner.width < inner.width - 1,
               cell(end + 1, inside: inner, in: surface).skip { end += 1 }
            return (start...end).contains(clicked) ? start...end : nil
        }
        var urls: [NSRange] = []
        for match in plainURL.matches(in: text, range: all) {
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
            urls.append(match.range)
            guard let indices = cells(range), let url = webURL(string.substring(with: range)) else { continue }
            return TerminalLink(target: .web(url), paneID: paneID, spans: spans(indices, inside: inner))
        }
        // Only the matches around the clicked cell are looked at, and none inside a URL.
        let clickedUnit = cellAt.firstIndex { $0 >= clicked } ?? string.length
        let lowerBound = max(0, clickedUnit - 512)
        let nearby = NSRange(location: lowerBound, length: min(string.length, clickedUnit + 512) - lowerBound)
        for match in plainPath.matches(in: text, range: nearby) {
            guard !urls.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            func group(_ name: String) -> NSRange? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : range
            }
            func number(_ name: String) -> Int? { group(name).flatMap { Int(string.substring(with: $0)) } }
            if let quoted = group("quoted") {
                guard let indices = cells(match.range) else { continue }
                let file = TerminalFileReference(path: string.substring(with: quoted), line: number("quotedLine"))
                return TerminalLink(target: .file(file), paneID: paneID, spans: spans(indices, inside: inner))
            }
            guard var pathRange = group("path") else { continue }
            var linkRange = match.range
            // A sentence's full stop is not part of the path before it.
            if linkRange == pathRange {
                while pathRange.length > 0, string.substring(with: pathRange).hasSuffix("."),
                      !["", ".", ".."].contains(string.substring(with: pathRange).split(separator: "/").last.map(String.init) ?? "") {
                    pathRange.length -= 1
                }
                linkRange = pathRange
            }
            let path = string.substring(with: pathRange)
            guard isLikelyPath(path), let indices = cells(linkRange) else { continue }
            let line = number("line") ?? number("parenLine")
            let column = number("column") ?? number("parenColumn")
            return TerminalLink(target: .file(TerminalFileReference(path: path, line: line, column: column)),
                                paneID: paneID, spans: spans(indices, inside: inner))
        }
        return nil
    }

    /// Words with a folder or an extension, so ordinary words, numbers and versions such as
    /// `1.2` are not checked on disk.
    static func isLikelyPath(_ path: String) -> Bool {
        if path.contains("/") { return path != "/" && path != "//" }
        if path.hasPrefix("."), path.contains(where: \.isLetter) { return true }
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return false }
        let name = path[..<dot]
        let suffix = path[path.index(after: dot)...]
        return !suffix.isEmpty && suffix.contains(where: \.isLetter) && name.contains(where: \.isLetter)
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

/// Whether the paths under the pointer exist, so Command underlines only real files, as in
/// VS Code. A check runs off the main thread, one at a time per window, and only while Command
/// is held: moving along a line asks for the newest path only, and answers last a few seconds.
@MainActor
final class TerminalFileLinks {
    struct Context: Sendable {
        let cwd: String?
        let machine: HerdrMachineProfile?
        var root: String? = nil
    }

    var context: (String) -> Context = { _ in Context(cwd: nil, machine: nil) }
    var directory: (String) async throws -> String? = { _ in nil }
    var check: @Sendable (TerminalFileReference, Context) async throws -> WorkspaceTerminalPath? = { file, context in
        try await WorkspaceFiles.blocking(on: context.machine, priority: .userInitiated) {
            try WorkspaceFiles.terminalPath(file.path, cwd: context.cwd, root: context.root, machine: context.machine)
        }
    }
    static let lifetime: TimeInterval = 3
    var now: () -> Date = Date.init

    private struct Key: Hashable {
        let path: String
        let paneID: String
        let cwd: String?
        let machine: String?
        let root: String?
    }
    private struct Answer {
        let path: WorkspaceTerminalPath?
        let at: Date
    }
    private var answers: [Key: Answer] = [:]
    private var running: Key?
    private var waiting: (key: Key, context: Context, then: () -> Void)?
    private var clicks: [(key: Key, context: Context)] = []
    private var callbacks: [Key: [(WorkspaceTerminalPath?) -> Void]] = [:]

    private func key(_ file: TerminalFileReference, _ paneID: String) -> Key {
        let context = context(paneID)
        return Key(path: file.path, paneID: paneID, cwd: context.cwd, machine: context.machine?.id, root: context.root)
    }

    func exists(_ file: TerminalFileReference, paneID: String, then: @escaping () -> Void) -> Bool? {
        let key = key(file, paneID)
        if answers[key].map({ now().timeIntervalSince($0.at) < Self.lifetime }) != true {
            if running != key, !clicks.contains(where: { $0.key == key }) {
                waiting = (key, context(paneID), then)
                startWaiting()
            }
        }
        return answers[key].map { $0.path != nil }
    }

    func known(_ file: TerminalFileReference, paneID: String) -> Bool? {
        answers[key(file, paneID)].map { $0.path != nil }
    }

    /// Clicks share the hover's resolved result, including an in-flight check.
    func open(_ file: TerminalFileReference, paneID: String,
              then: @escaping (WorkspaceTerminalPath) -> Void) -> Bool {
        let key = key(file, paneID)
        if let answer = answers[key] {
            guard let path = answer.path else { return false }
            then(path)
        } else {
            callbacks[key, default: []].append { if let path = $0 { then(path) } }
            if running != key, !clicks.contains(where: { $0.key == key }) {
                clicks.append((key, context(paneID)))
                if waiting?.key == key { waiting = nil }
                startWaiting()
            }
        }
        return true
    }

    func cancelPending() {
        if let waiting, callbacks[waiting.key] == nil { self.waiting = nil }
    }

    private func startWaiting() {
        guard running == nil else { return }
        let next: (key: Key, context: Context, then: () -> Void)
        if !clicks.isEmpty {
            let click = clicks.removeFirst()
            next = (click.key, click.context, {})
        } else if let pending = waiting {
            next = pending
            waiting = nil
        } else { return }
        running = next.key
        let check = check
        Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                let cwd = try await directory(next.key.paneID) ?? next.context.cwd
                let path = try await check(TerminalFileReference(path: next.key.path),
                                           Context(cwd: cwd, machine: next.context.machine, root: next.context.root))
                if answers.count > 512 { answers.removeAll() }
                answers[next.key] = Answer(path: path, at: now())
                succeeded = true
                callbacks.removeValue(forKey: next.key)?.forEach { $0(path) }
            } catch {
                callbacks.removeValue(forKey: next.key)?.forEach { $0(nil) }
            }
            running = nil
            // Errors are retried on the next pointer/surface event, not in a busy loop.
            if succeeded { next.then() }
            startWaiting()
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

/// The key-name subset supported by Herdr's semantic input codec. Command shortcuts and
/// text/IME commits stay with AppKit; Ctrl/Option chords retain every supported modifier.
enum TerminalKeyInput {
    private static let special: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 53: "esc", 51: "backspace",
        117: "delete", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown"
    ]

    static func name(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return nil }
        let key: String
        if let special = special[event.keyCode] {
            key = special
        } else {
            // Option participates in the keyboard layout's text input (accents,
            // dead keys and symbols). Only Control turns printable keys into
            // terminal chords; Option still modifies special keys above.
            guard modifiers.contains(.control),
                  event.characters?.isEmpty == false,
                  let characters = event.charactersIgnoringModifiers?.lowercased(),
                  characters.unicodeScalars.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
            // AppKit's ignoring-modifiers text retains the layout's Shift-produced symbol
            // (e.g. ? or +). Do not replace it with a US key-code lookup or Option's glyph.
            key = characters
        }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }
}

final class HerdrTerminalTextView: NSTextView {
    var surfaceRevision: UInt64?
    var themeID: String?
    var theme = WoolooTheme.named(WoolooTheme.fallbackID)!
    var surfaceFeed: HerdrSurfaceFeed?
    var onPresentSurface: ((HerdrSurface) -> Void)?
    private var keyWindowObserver: NSObjectProtocol?
    /// With metrics on, records the screen's refreshes so a draw's time on screen can be estimated.
    private let vsyncRecorder = TerminalVsyncRecorder()
    private var lastPresentedAgentRevision: (bootID: String, revision: UInt64)?
    var surfaceBootID: String?
    var surface: HerdrSurface?
    fileprivate(set) var displaySurface: HerdrSurface?
    var sendPopupInput: ((HerdrInputEvent, String, String) -> Void)?
    var closePopup: ((String, String) -> Void)?
    fileprivate lazy var popupCloseButton: NSButton = {
        let button = NSButton(title: "×", target: self, action: #selector(closeActivePopup))
        button.isBordered = false
        button.font = TerminalPaneView.terminalFont
        button.toolTip = "Close Popup"
        button.setAccessibilityLabel("Close Popup")
        button.setAccessibilityIdentifier("herdr-popup-close")
        button.isHidden = true
        return button
    }()

    @objc private func closeActivePopup() {
        guard let surface, let popup = surface.popup else { return }
        closePopup?(popup.terminalID, surface.bootID)
    }

    private func popupInput(_ event: HerdrInputEvent) -> Bool {
        guard let surface, let popup = surface.popup else { return false }
        sendPopupInput?(event, popup.terminalID, surface.bootID)
        return true
    }
    var selectPane: ((String) -> Void)?
    var paneID = ""
    /// Where Copy writes and Paste reads; tests use their own so they leave the clipboard alone.
    var pasteboard = NSPasteboard.general
    var shortcutMap = HerdrShortcutMap(document: HerdrConfigDocument(text: ""))
    var onShortcut: ((String) -> Void)?
    var onPrefixChanged: ((Bool) -> Void)?
    private var shortcutPrefixPending = false
    var sendText: ((String, String) -> Void)?
    var sendPaste: ((String, String) -> Void)?
    var sendKey: ((String, String) -> Void)?
    var sendMouse: ((HerdrMouseEvent, String) -> Void)?
    var setSplitRatio: (([Bool], Double) -> Void)?
    var tabDrop: TerminalTabDropHandler?
    var fileLinks: TerminalFileLinks?
    var openFileLink: ((TerminalFileReference, String, WorkspaceTerminalPath) -> Void)?
    weak var dropOverlay: TerminalDropOverlayView?
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
    /// The pane a selection began in; it stays inside that pane's content, as with split panes in
    /// Ghostty or iTerm2. Nil without panes, or while a popup holds the selection.
    private var selectionPaneID: String?
    private var isSelectingCells = false
    /// The link under the pointer while Command is held, underlined until either changes.
    private var hoveredLink: TerminalLink?
    private var linkTrackingArea: NSTrackingArea?

    /// Herdr's cursor is drawn in the grid; a caret at the end of the text would be a second one.
    override var shouldDrawInsertionPoint: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        vsyncRecorder.follow(window == nil ? nil : self)
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastPresentedAgentRevision = nil
                    self?.needsDisplay = true
                }
            }
        }
        // Switching tabs rebuilds this view; give it the keyboard like a terminal would.
        DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocusIfIdle() }
    }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
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
        guard surface?.popup == nil else { return false }
        switch shortcutMap.match(event, prefixPending: shortcutPrefixPending) {
        case .pass:
            if shortcutPrefixPending { clearShortcutPrefix() }
            return false
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
            if let surface, let metrics = TerminalPipelineMetrics.shared {
                metrics.drawn(surface, start: drawStart)
                metrics.drawCommitted()
            }
            if let surface, let callback = onPresentSurface, NSApp.isActive,
               window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor,
               lastPresentedAgentRevision?.bootID != surface.bootID || lastPresentedAgentRevision?.revision != surface.projectionRevision {
                // Publishing seen state during AppKit drawing can reenter SwiftUI layout.
                lastPresentedAgentRevision = (surface.bootID, surface.projectionRevision)
                DispatchQueue.main.async { [weak self] in
                    guard let self, NSApp.isActive, self.window?.isKeyWindow == true,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    callback(surface)
                }
            }
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
        let selectionLimits = selection == nil ? nil : selectionBounds
        if let selection {
            context.setFillColor(grid.selectionFill)
            for row in selection.start.row...selection.end.row {
                let columns = selectedColumns(row: row, selection: selection, width: grid.width, bounds: selectionLimits)
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
            let selected = selection.map { selectedColumns(row: row, selection: $0, width: grid.width, bounds: selectionLimits) } ?? 0..<0
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
        if let surface, let popup = surface.popup, let geometry = popup.geometry(cols: surface.width, rows: surface.height) {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(pixelRect(geometry.outer))
            context.clip(using: .evenOdd)
            context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            context.fill(bounds)
            context.restoreGState()
        }
    }

    private func pixelRect(_ rect: HerdrRect) -> NSRect {
        NSRect(x: textContainerInset.width + CGFloat(rect.x) * TerminalPaneView.cellWidth,
               y: textContainerInset.height + CGFloat(rect.y) * TerminalPaneView.cellHeight,
               width: CGFloat(rect.width) * TerminalPaneView.cellWidth,
               height: CGFloat(rect.height) * TerminalPaneView.cellHeight)
    }

    private func drawGraphics(in dirtyRect: NSRect, behindText: Bool) {
        guard let surface else { return }
        let popupGeometry = surface.popup?.geometry(cols: surface.width, rows: surface.height)
        for graphic in surface.graphics.sorted(by: { $0.z < $1.z }) where (graphic.z < 0) == behindText {
            let viewport: NSRect
            if graphic.key.isPopup {
                guard graphic.key.popupTerminalID == surface.popup?.terminalID, let popupGeometry else { continue }
                viewport = pixelRect(popupGeometry.inner)
            } else {
                viewport = pixelRect(HerdrRect(x: 0, y: 0, width: surface.width, height: surface.height))
            }
            guard let image = decodedGraphics[graphic.key.identity],
                  graphic.cols > 0, graphic.rows > 0,
                  graphic.sourceWidth > 0, graphic.sourceHeight > 0 else { continue }
            let destination = NSRect(x: viewport.minX + CGFloat(graphic.x) * TerminalPaneView.cellWidth + CGFloat(graphic.xOffset),
                                     y: viewport.minY + CGFloat(graphic.y) * TerminalPaneView.cellHeight + CGFloat(graphic.yOffset),
                                     width: CGFloat(graphic.cols) * TerminalPaneView.cellWidth,
                                     height: CGFloat(graphic.rows) * TerminalPaneView.cellHeight)
            guard destination.intersects(dirtyRect) else { continue }
            NSGraphicsContext.current?.saveGraphicsState()
            viewport.intersection(dirtyRect).clip()
            if !graphic.key.isPopup, let popupGeometry,
               let context = NSGraphicsContext.current?.cgContext {
                context.addRect(viewport)
                context.addRect(pixelRect(popupGeometry.outer))
                context.clip(using: .evenOdd)
            }
            let source = NSRect(x: graphic.sourceX,
                                y: graphic.key.height - graphic.sourceY - graphic.sourceHeight,
                                width: graphic.sourceWidth, height: graphic.sourceHeight)
            image.draw(in: destination, from: source, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    func clearTerminalSelection() {
        selectedSnapshot = nil
        selectionAtSnapshot = nil
        selectionAnchor = nil
        selectionHead = nil
        selectionPaneID = nil
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
    }

    /// Shows a live surface, laying the grid out again only when its content changed.
    func show(_ surface: HerdrSurface?) {
        guard let surface else {
            self.surface = nil
            displaySurface = nil
            terminalGrid = nil
            surfaceRevision = nil
            popupCloseButton.isHidden = true
            needsDisplay = true
            return
        }
        TerminalTypingProbe.target = self
        let start = TerminalPipelineMetrics.now()
        let splitsChanged = self.surface?.splits != surface.splits
        let popupChanged = self.surface?.popup?.terminalID != surface.popup?.terminalID
        if let selectionPaneID, surface.paneInnerRects[selectionPaneID] != self.surface?.paneInnerRects[selectionPaneID] {
            // The pane closed or moved, so the selection no longer covers the text it was made on.
            clearTerminalSelection()
        }
        if popupChanged {
            clearTerminalSelection()
            clearShortcutPrefix()
            splitDrag = nil
            heldMouse = nil
            scroll = TerminalScrollAccumulator()
            showTabDrop(nil)
            claimKeyboardFocusIfIdle()
        }
        self.surface = surface
        displaySurface = surface.displayingPopup(theme: theme)
        if popupCloseButton.superview == nil { addSubview(popupCloseButton) }
        if let geometry = surface.popup?.geometry(cols: surface.width, rows: surface.height) {
            popupCloseButton.frame = pixelRect(HerdrRect(x: geometry.outer.x + geometry.outer.width - 2,
                                                        y: geometry.outer.y, width: 1, height: 1))
            popupCloseButton.contentTintColor = WoolooTheme.nsColor(theme.herdr.accent)
            popupCloseButton.isHidden = false
        } else { popupCloseButton.isHidden = true }
        prepareGraphics(surface.graphics)
        if splitsChanged || popupChanged { window?.invalidateCursorRects(for: self) }
        guard surfaceRevision != surface.revision || surfaceBootID != surface.bootID else { return }
        if surfaceBootID != nil && surfaceBootID != surface.bootID { clearTerminalSelection() }
        surfaceRevision = surface.revision
        surfaceBootID = surface.bootID
        let layoutStart = TerminalPipelineMetrics.now()
        let grid = TerminalPipelineMetrics.signposter.withIntervalSignpost("layout") {
            TerminalPaneView.layoutGrid(displaySurface!, theme: theme, previous: terminalGrid)
        }
        let layoutNanos = TerminalPipelineMetrics.now() - layoutStart
        applySurfaceGrid(grid)
        if popupChanged { needsDisplay = true }
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

    /// The cells a selection stays inside: the popup's content, or that of the pane it began in,
    /// clipped to the surface; nil when that leaves nothing.
    private var selectionBounds: HerdrRect? {
        guard let surface else { return nil }
        let inner = surface.popup != nil
            ? surface.popup?.geometry(cols: surface.width, rows: surface.height)?.inner
            : selectionPaneID.flatMap { surface.paneInnerRects[$0] }
        guard let inner else { return nil }
        let left = max(0, inner.x), top = max(0, inner.y)
        let right = min(surface.width, inner.x + inner.width), bottom = min(surface.height, inner.y + inner.height)
        return right > left && bottom > top ? HerdrRect(x: left, y: top, width: right - left, height: bottom - top) : nil
    }

    private func selectedColumns(row: Int, selection: (start: GridPoint, end: GridPoint), width: Int,
                                 bounds: HerdrRect?) -> Range<Int> {
        guard row >= selection.start.row, row <= selection.end.row else { return 0..<0 }
        let lower = row == selection.start.row ? selection.start.column : 0
        let upper = row == selection.end.row ? selection.end.column : width
        if let inner = bounds {
            guard row >= inner.y, row < inner.y + inner.height else { return 0..<0 }
            let start = max(lower, inner.x), end = min(upper, inner.x + inner.width)
            return start < end ? start..<end : 0..<0
        }
        return lower < upper ? lower..<upper : 0..<0
    }

    /// The text of the cells selected in the live grid.
    func selectedCellText() -> String? {
        guard let grid = terminalGrid, let selection = orderedSelection(in: grid) else { return nil }
        let bounds = selectionBounds
        return (selection.start.row...selection.end.row).map { row in
            grid.rows[row].symbols[selectedColumns(row: row, selection: selection, width: grid.width, bounds: bounds)].joined()
        }.joined(separator: "\n")
    }

    /// The caret position nearest to the pointer, clamped to the grid.
    private func gridPoint(_ event: NSEvent, in grid: TerminalGrid) -> GridPoint {
        let point = convert(event.locationInWindow, from: nil)
        var row = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
        var column = Int(((point.x - textContainerInset.width) / TerminalPaneView.cellWidth).rounded())
        if let inner = selectionBounds {
            row = min(max(inner.y, row), inner.y + inner.height - 1)
            column = min(max(inner.x, column), inner.x + inner.width)
        }
        return GridPoint(row: min(max(0, row), grid.height - 1), column: min(max(0, column), grid.width))
    }

    private func beginCellSelection(with event: NSEvent, in grid: TerminalGrid) {
        window?.makeFirstResponder(self)
        guard grid.width > 0, grid.height > 0 else { return }
        let (x, y) = surfacePoint(event)
        // A press outside every pane, such as in a gap of the layout, selects in the focused one.
        let pane = surface.flatMap { surface in
            surface.popup != nil ? nil : TerminalPointer.paneID(atColumn: x, row: y, in: surface)
                ?? (surface.paneInnerRects[paneID] != nil ? paneID : nil)
        }
        // Shift extends a selection in the same pane; in a program that takes the mouse, Shift
        // is what selects at all, so it starts a new selection there.
        let extending = event.modifierFlags.contains(.shift) && selectionAnchor != nil
            && pane == selectionPaneID && !reportsMouse(at: event)
        selectionPaneID = pane
        selectedSnapshot = nil
        let bounds = selectionBounds
        if pane != nil && bounds == nil {
            // A pane without content cells has nothing to select.
            selectionAnchor = nil
            selectionHead = nil
            needsDisplay = true
            return
        }
        let point = gridPoint(event, in: grid)
        let line = bounds.map { $0.x..<($0.x + $0.width) } ?? 0..<grid.width
        // Double- and triple-click act on the content under the pointer, not on a border or title.
        let onContent = bounds?.contains(column: x, row: y) ?? true
        let cell = min(max(0, x), grid.width - 1)
        let word = onContent ? TerminalPointer.wordRange(in: grid.rows[point.row].symbols, at: cell) : nil
        switch event.clickCount {
        case 2 where word != nil:
            selectionAnchor = GridPoint(row: point.row, column: word!.lowerBound)
            selectionHead = GridPoint(row: point.row, column: word!.upperBound)
        case 3... where onContent:
            selectionAnchor = GridPoint(row: point.row, column: line.lowerBound)
            selectionHead = GridPoint(row: point.row, column: line.upperBound)
        default:
            if !extending { selectionAnchor = point }
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
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
    }

    /// The grid selection is not a TextKit range, so NSTextView alone would disable Copy.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), terminalGrid != nil { return hasCellSelection }
        // NSTextView would check the general pasteboard, not the one Paste reads.
        if item.action == #selector(paste(_:)) { return pasteboard.string(forType: .string) != nil }
        return super.validateUserInterfaceItem(item)
    }

    override func selectAll(_ sender: Any?) {
        if let grid = terminalGrid {
            // The popup's content, or the focused pane's when the tab is split.
            selectionPaneID = surface?.popup == nil && surface?.paneInnerRects[paneID] != nil ? paneID : nil
            if let inner = selectionBounds {
                selectionAnchor = GridPoint(row: inner.y, column: inner.x)
                selectionHead = GridPoint(row: inner.y + inner.height - 1, column: inner.x + inner.width)
            } else {
                selectionAnchor = GridPoint(row: 0, column: 0)
                selectionHead = GridPoint(row: grid.height - 1, column: grid.width)
            }
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
        // The tracking area also fires under views drawn over this one, such as a sidebar's resize
        // handle; leave the cursor to them.
        guard ownsPointer(at: event.locationInWindow) else { return }
        updateMoveHandle(at: event.locationInWindow)
        updateHoveredLink(at: event.locationInWindow, modifiers: event.modifierFlags)
        // NSTextView's own handling would set the I-beam, also over a divider.
        if let cursor = cursor(at: event.locationInWindow) {
            cursor.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard ownsPointer(at: event.locationInWindow) else { return }
        if let cursor = cursor(at: event.locationInWindow) {
            cursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// False where a view drawn over this one, such as a sidebar's resize handle, takes the pointer.
    private func ownsPointer(at windowPoint: NSPoint) -> Bool {
        guard let contentView = window?.contentView,
              let hit = contentView.hitTest(contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint)
        else { return true }
        return hit === self || hit.isDescendant(of: self)
    }

    /// The cursor this view shows itself: a divider's resize cursor while it is dragged or under
    /// the pointer, or the hand over a link; nil leaves NSTextView's I-beam.
    private func cursor(at windowPoint: NSPoint) -> NSCursor? {
        if let splitDrag { return Self.resizeCursor(for: splitDrag.split) }
        if let surface, let split = splitHit(at: windowPoint, in: surface) { return Self.resizeCursor(for: split) }
        return hoveredLink == nil ? nil : .pointingHand
    }

    /// Sets the cursor outside mouse moves, as a divider drag starts or ends: the arrow once the
    /// pointer is off this view, for the view there to replace.
    private func showCursor(for event: NSEvent) {
        let point = event.locationInWindow
        guard splitDrag != nil || ownsPointer(at: point) && visibleRect.contains(convert(point, from: nil)) else {
            return NSCursor.arrow.set()
        }
        updateHoveredLink(at: point, modifiers: event.modifierFlags)
        (cursor(at: point) ?? .iBeam).set()
    }

    static func resizeCursor(for split: HerdrSplit) -> NSCursor {
        if #available(macOS 15.0, *) {
            return split.direction == .horizontal ? .columnResize : .rowResize
        }
        return split.direction == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        fileLinks?.cancelPending()
        setHoveredLink(nil)
        if let overlay = dropOverlay,
           !overlay.moveHandle.frame.contains(overlay.convert(event.locationInWindow, from: nil)) {
            overlay.showHandle(for: nil, rect: nil)
        }
    }

    fileprivate func updateMoveHandle(at point: NSPoint) {
        guard let overlay = dropOverlay, surface?.popup == nil, let tabDrop else {
            dropOverlay?.showHandle(for: nil, rect: nil)
            return
        }
        let panes = surface.map {
            TerminalTabDrop.paneRects(of: $0, inset: textContainerInset,
                                      cell: CGSize(width: TerminalPaneView.cellWidth, height: TerminalPaneView.cellHeight))
        } ?? [(id: paneID, rect: visibleRect)]
        let local = convert(point, from: nil)
        guard let pane = panes.first(where: { $0.rect.contains(local) }),
              tabDrop.canDetach(pane.id) || !tabDrop.targets(pane.id).isEmpty else {
            overlay.showHandle(for: nil, rect: nil)
            return
        }
        overlay.showHandle(for: pane.id, rect: overlay.convert(pane.rect.intersection(visibleRect), from: self))
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoveredLink(modifiers: event.modifierFlags)
    }

    /// The live surface's link at a window location.
    private func link(at windowPoint: NSPoint) -> TerminalLink? {
        guard let surface = displaySurface, terminalGrid != nil else { return nil }
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let x = Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth))
        let y = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
        guard x >= 0, y >= 0, x < surface.width, y < surface.height else { return nil }
        if let popup = surface.popup {
            guard let inner = popup.geometry(cols: surface.width, rows: surface.height)?.inner,
                  inner.contains(column: x, row: y) else { return nil }
        }
        return TerminalLinks.link(atColumn: x, row: y, in: surface)
    }

    /// Underlines the link under the pointer while Command is held, as iTerm2 does; a path once
    /// it is found on disk.
    private func updateHoveredLink(at windowPoint: NSPoint? = nil, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard modifiers.contains(.command), let window else {
            fileLinks?.cancelPending()
            return setHoveredLink(nil)
        }
        var link = link(at: windowPoint ?? window.mouseLocationOutsideOfEventStream)
        if let found = link, let file = found.file {
            let exists = fileLinks?.exists(file, paneID: found.paneID) { [weak self] in self?.updateHoveredLink() }
            if exists != true { link = nil }
        } else {
            fileLinks?.cancelPending()
        }
        setHoveredLink(link)
    }

    /// Opens a Command-clicked link; false for a path not found on disk, which the click then
    /// handles as any other. A pending path opens only after its shared check succeeds.
    private func open(_ link: TerminalLink) -> Bool {
        switch link.target {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .file(let file):
            guard let openFileLink, let fileLinks else { return false }
            return fileLinks.open(file, paneID: link.paneID) { openFileLink(file, link.paneID, $0) }
        }
        return true
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
        guard let surface, surface.popup == nil else { return }
        for split in surface.splits {
            let rect = split.hitRect
            guard rect.width > 0, rect.height > 0 else { continue }
            addCursorRect(NSRect(x: textContainerInset.width + CGFloat(rect.x) * TerminalPaneView.cellWidth,
                                 y: textContainerInset.height + CGFloat(rect.y) * TerminalPaneView.cellHeight,
                                 width: CGFloat(rect.width) * TerminalPaneView.cellWidth,
                                 height: CGFloat(rect.height) * TerminalPaneView.cellHeight),
                          cursor: Self.resizeCursor(for: split))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let surface, let popup = surface.popup {
            window?.makeFirstResponder(self)
            let (x, y) = surfacePoint(event)
            guard let geometry = popup.geometry(cols: surface.width, rows: surface.height) else { return }
            if y == geometry.outer.y, x == geometry.outer.x + geometry.outer.width - 2 {
                closeActivePopup()
                return
            }
            guard geometry.inner.contains(column: x, row: y) else { return }
            if event.modifierFlags.contains(.command), let link = link(at: event.locationInWindow), open(link) {
                return
            }
            if !event.modifierFlags.contains(.shift), forwardMouse(.down(0), event: event, hold: true) { return }
            if let terminalGrid { beginCellSelection(with: event, in: terminalGrid) }
            return
        }
        if event.modifierFlags.contains(.command), let link = link(at: event.locationInWindow), open(link) {
            return
        }
        if let surface {
            if let split = splitHit(at: event.locationInWindow, in: surface) {
                let (x, y) = surfacePoint(event)
                let pointer = split.direction == .horizontal ? x : y
                splitDrag = (split, split.pos - pointer, surface.bootID, 0, nil)
                showCursor(for: event)
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
            // The pointer may have left the divider, or this view, during the drag.
            showCursor(for: event)
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
            // Off the divider the view would show its I-beam, though the drag goes on; a drag
            // whose split is gone shows the cursor under the pointer.
            showCursor(for: event)
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
        surfacePoint(at: event.locationInWindow)
    }

    private func surfacePoint(at location: NSPoint) -> (Int, Int) {
        let point = convert(location, from: nil)
        return (Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth)),
                Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight)))
    }

    /// The divider a press at a window location drags; none while a popup is shown.
    private func splitHit(at windowPoint: NSPoint, in surface: HerdrSurface) -> HerdrSplit? {
        guard surface.popup == nil else { return nil }
        let (x, y) = surfacePoint(at: windowPoint)
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
        if surface?.popup != nil {
            if !forwardMouse(.down(1), event: event, hold: true) { super.rightMouseDown(with: event) }
            return
        }
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
                                  enabled: pasteboard.string(forType: .string) != nil))
        menu.addItem(standardItem("Select All", #selector(selectAll(_:)), enabled: true))
        if surface?.popup != nil {
            menu.addItem(.separator())
            menu.addItem(standardItem("Close Popup", #selector(closeActivePopup), enabled: true))
            return menu
        }
        menu.addItem(.separator())
        menu.addItem(herdrItem("Split Right", "split_vertical", symbol: "rectangle.split.2x1"))
        menu.addItem(herdrItem("Split Down", "split_horizontal", symbol: "rectangle.split.1x2"))
        let source = surface.flatMap { mouseHit(event, in: $0)?.0 } ?? paneID
        let move = NSMenuItem(title: "Move Terminal", action: nil, keyEquivalent: "")
        move.submenu = paneMoveMenu(source)
        menu.addItem(move)
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

    func paneMoveMenu(_ source: String) -> NSMenu {
        let menu = NSMenu()
        guard let tabDrop else { return menu }
        for target in tabDrop.targets(source) {
            let item = NSMenuItem(title: "Next to \(target.title)", action: nil, keyEquivalent: "")
            let sides = NSMenu()
            for edge in TerminalDropEdge.allCases {
                let side = NSMenuItem(title: edge.title, action: #selector(moveTerminal(_:)), keyEquivalent: "")
                side.target = self
                side.representedObject = [source, target.id, edge.title]
                sides.addItem(side)
            }
            item.submenu = sides
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let detach = NSMenuItem(title: "Move to Own Tab", action: #selector(detachTerminal(_:)), keyEquivalent: "")
        detach.target = self
        detach.representedObject = source
        detach.isEnabled = tabDrop.canDetach(source)
        menu.autoenablesItems = false
        menu.addItem(detach)
        return menu
    }

    @objc private func moveTerminal(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 3,
              let edge = TerminalDropEdge.allCases.first(where: { $0.title == values[2] }) else { return }
        _ = tabDrop?.movePane(values[0], values[1], edge)
    }

    @objc private func detachTerminal(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        tabDrop?.detach(source)
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
        if surface?.popup != nil { return }
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
        guard scrollPane(at: event.locationInWindow, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                         precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags) else {
            scroll.reset()
            super.scrollWheel(with: event)
            return
        }
    }

    /// Sends a wheel event to the pane under `location` (in the window). Herdr decides
    /// whether the program receives it or its scrollback moves. The mouse probe calls it too, since AppKit
    /// cannot make a scroll `NSEvent` at a window location.
    func scrollPane(at location: NSPoint, deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                    modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let surface else { return false }
        guard let (id, column, row) = mouseHit(at: location, in: surface) else {
            return surface.popup != nil
        }
        let vertical = abs(deltaY) >= abs(deltaX)
        let delta = vertical ? deltaY : deltaX
        guard let lines = scroll.lines(for: delta, precise: precise, lineHeight: TerminalPaneView.cellHeight) else { return true }
        let kind: HerdrMouseEvent.Kind = vertical
            ? (delta > 0 ? .scrollUp : .scrollDown)
            : (delta > 0 ? .scrollLeft : .scrollRight)
        emitMouse(HerdrMouseEvent(kind: kind, column: column, row: row,
                                 modifiers: TerminalPointer.modifiers(modifiers), lines: lines), id: id)
        return true
    }

    private func mouseHit(_ event: NSEvent, in surface: HerdrSurface) -> (String, UInt16, UInt16)? {
        mouseHit(at: event.locationInWindow, in: surface)
    }

    private func mouseHit(at location: NSPoint, in surface: HerdrSurface) -> (String, UInt16, UInt16)? {
        let (x, y) = surfacePoint(at: location)
        if let popup = surface.popup {
            guard let geometry = popup.geometry(cols: surface.width, rows: surface.height),
                  geometry.inner.contains(column: x, row: y),
                  let cell = TerminalPointer.cell(column: x, row: y, inside: geometry.inner) else { return nil }
            return (popup.terminalID, cell.column, cell.row)
        }
        return TerminalPointer.pane(atColumn: x, row: y, in: surface).map { ($0.id, $0.column, $0.row) }
    }

    /// Whether the program under the pointer takes the mouse.
    private func reportsMouse(at event: NSEvent) -> Bool {
        guard let surface, let (id, _, _) = mouseHit(event, in: surface) else { return false }
        return reportsMouse(id, in: surface)
    }

    private func reportsMouse(_ id: String, in surface: HerdrSurface) -> Bool {
        surface.popup.map { $0.terminalID == id && $0.mouseReporting } ?? surface.mouseReportingPaneIDs.contains(id)
    }

    private func emitMouse(_ event: HerdrMouseEvent, id: String) {
        if popupInput(.mouse(event)) { return }
        sendMouse?(event, id)
    }

    private func mouseModifiers(_ event: NSEvent) -> UInt8 {
        TerminalPointer.modifiers(event.modifierFlags)
    }

    private func forwardMouse(_ kind: HerdrMouseEvent.Kind, event: NSEvent, hold: Bool) -> Bool {
        guard let surface, let (id, column, row) = mouseHit(event, in: surface),
              reportsMouse(id, in: surface) else { return false }
        window?.makeFirstResponder(self)
        if hold, case .down(let button) = kind { heldMouse = (id, button) }
        emitMouse(HerdrMouseEvent(kind: kind, column: column, row: row,
                                 modifiers: mouseModifiers(event), lines: 1), id: id)
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
        let inner = surface.flatMap { surface in
            if let popup = surface.popup {
                return popup.terminalID == id ? popup.geometry(cols: surface.width, rows: surface.height)?.inner : nil
            }
            return surface.paneInnerRects[id]
        }
        guard let inner, let cell = TerminalPointer.cell(column: x, row: y, inside: inner) else {
            return true
        }
        emitMouse(HerdrMouseEvent(kind: kind, column: cell.column, row: cell.row,
                                 modifiers: mouseModifiers(event), lines: 1), id: id)
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

        // During composition, arrows, Enter and Backspace belong to the input method.
        if !hasMarkedText(), let key = TerminalKeyInput.name(for: event) {
            if !popupInput(.key(key)) { sendKey?(key, paneID) }
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
        // This view forwards commits instead of calling NSTextView.insertText, so clear the
        // inherited composition state explicitly before routing the next physical key.
        if hasMarkedText() { super.unmarkText() }
        if !value.isEmpty, !popupInput(.text(value)) { sendText?(value, paneID) }
    }

    override func paste(_ sender: Any?) {
        if let value = pasteboard.string(forType: .string), !value.isEmpty {
            if !popupInput(.paste(value)) { sendPaste?(value, paneID) }
        }
    }

    // Dropped files paste their shell-escaped paths into the pane under the pointer,
    // as Terminal and iTerm do; dropped text pastes as is. A terminal tab dragged from the
    // tab bar splits next to the pane under the pointer instead, and never pastes.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if surface?.popup != nil {
            return TerminalTabDrop.carriesTab(sender.draggingPasteboard) || droppedText(sender.draggingPasteboard) == nil ? [] : .copy
        }
        if TerminalTabDrop.carriesTab(sender.draggingPasteboard) {
            let target = tabDropTarget(sender)
            showTabDrop(target)
            guard target != nil else { return [] }
            let allowed = sender.draggingSourceOperationMask
            return allowed.contains(.move) ? .move : allowed.contains(.generic) ? .generic : .copy
        }
        return droppedText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showTabDrop(nil)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        showTabDrop(nil)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(TerminalTabDrop.panePasteboardType) == true {
            return tabDropTarget(sender) != nil
        }
        return true
    }

    /// NSTextView registers these again whenever it updates its drag types; keep tab drags in.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [TerminalTabDrop.pasteboardType, TerminalTabDrop.panePasteboardType]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if surface?.popup != nil {
            guard !TerminalTabDrop.carriesTab(sender.draggingPasteboard), let text = droppedText(sender.draggingPasteboard) else { return false }
            return popupInput(.paste(text))
        }
        if TerminalTabDrop.carriesTab(sender.draggingPasteboard) {
            let target = tabDropTarget(sender)
            showTabDrop(nil)
            guard let target, let tabDrop else { return false }
            if let source = sender.draggingPasteboard.string(forType: TerminalTabDrop.panePasteboardType) {
                return tabDrop.movePane(source, target.paneID, target.edge)
            }
            return tabDrop.drop(target.paneID, target.edge)
        }
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

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        showTabDrop(nil)
    }

    /// Where a dragged terminal tab would drop, when the window accepts it here: in a live
    /// surface's pane under the pointer, or in this view's only pane while showing `pane.read` text.
    private func tabDropTarget(_ sender: NSDraggingInfo) -> TerminalTabDropTarget? {
        guard let tabDrop else { return nil }
        let source = sender.draggingPasteboard.string(forType: TerminalTabDrop.panePasteboardType)
        if source != nil {
            // Pane IDs are only unique inside a Herdr session. A foreign window may
            // have the same IDs while referring to entirely different terminals.
            guard let handle = sender.draggingSource as? TerminalMoveHandle,
                  let window, handle.window === window else { return nil }
        }
        guard source != nil || tabDrop.accepts() else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let panes = surface.map {
            TerminalTabDrop.paneRects(of: $0, inset: textContainerInset,
                                      cell: CGSize(width: TerminalPaneView.cellWidth, height: TerminalPaneView.cellHeight))
        } ?? [(paneID, visibleRect)]
        guard let target = TerminalTabDrop.target(at: point, panes: panes) else { return nil }
        if let source, !tabDrop.targets(source).contains(where: { $0.id == target.paneID }) { return nil }
        return target
    }

    private func showTabDrop(_ target: TerminalTabDropTarget?) {
        guard let dropOverlay else { return }
        dropOverlay.show(target.map { dropOverlay.convert($0.highlight, from: self) }, accent: theme.herdr.accent)
    }

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

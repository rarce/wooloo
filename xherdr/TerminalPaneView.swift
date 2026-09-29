import AppKit
import SwiftUI

private struct RenderedTerminalSurface {
    let text: NSAttributedString
    /// UTF-16 offsets for every cell boundary, including the end of each row.
    let cellOffsets: [Int]
    let width: Int
    let height: Int
}

/// A small AppKit input surface for Herdr's rendered pane snapshot. Herdr still
/// owns the PTY; this view only displays its text and forwards keyboard input.
struct TerminalPaneView: NSViewRepresentable {
    static let terminalFont = NSFont(name: "FiraCodeNFM-Reg", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let cellWidth = ("M" as NSString).size(withAttributes: [.font: terminalFont]).width
    static let cellHeight = NSLayoutManager().defaultLineHeight(for: terminalFont)

    let text: String
    let paneID: String
    var surface: HerdrSurface? = nil
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
        scrollView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.091, alpha: 1)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Full screen reveals the title bar as an overlay; automatic insets would shift
        // the grid away from the rows Herdr's mouse coordinates assume.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        let view = HerdrTerminalTextView(frame: .zero)
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
        view.isSelectable = true
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        view.drawsBackground = false
        view.textColor = NSColor(red: 0.88, green: 0.91, blue: 0.93, alpha: 1)
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
        let splitsChanged = view.surface?.splits != surface?.splits
        Self.configureScrolling(scrollView, view: view, live: surface != nil)
        view.surface = surface
        if let surface { view.prepareGraphics(surface.graphics) }
        if splitsChanged { scrollView.window?.invalidateCursorRects(for: view) }
        if let surface {
            guard view.surfaceRevision != surface.revision || view.surfaceBootID != surface.bootID else { return }
            if view.surfaceBootID != nil && view.surfaceBootID != surface.bootID {
                view.clearTerminalSelection()
            }
            view.surfaceRevision = surface.revision
            view.surfaceBootID = surface.bootID
            view.applySurfaceText(Self.render(surface))
            return
        }
        view.surfaceRevision = nil
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
    /// scrollers, which would shrink the grid and cascade into both scrollbars.
    private static func configureScrolling(_ scrollView: NSScrollView, view: NSTextView, live: Bool) {
        guard scrollView.hasVerticalScroller == live else { return }
        scrollView.hasVerticalScroller = !live
        scrollView.hasHorizontalScroller = !live
        scrollView.verticalScrollElasticity = live ? .none : .automatic
        scrollView.horizontalScrollElasticity = live ? .none : .automatic
        view.isHorizontallyResizable = !live
        view.autoresizingMask = live ? [.width] : []
        if live {
            view.setFrameSize(NSSize(width: scrollView.contentSize.width, height: view.frame.height))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Pins every row to the grid's cell height, even when a fallback font is taller.
    private static let cellParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = cellHeight
        style.maximumLineHeight = cellHeight
        style.lineBreakMode = .byClipping
        return style
    }()

    /// Natural advance of a symbol, including any fallback font it renders with.
    private static var advanceCache: [String: CGFloat] = [:]

    private static func advance(of symbol: String, font: NSFont, bold: Bool) -> CGFloat {
        let key = bold ? "b" + symbol : "r" + symbol
        if let cached = advanceCache[key] { return cached }
        let width = NSAttributedString(string: symbol, attributes: [.font: font]).size().width
        if advanceCache.count > 4_096 { advanceCache.removeAll() }
        advanceCache[key] = width
        return width
    }

    private static func render(_ surface: HerdrSurface) -> RenderedTerminalSurface {
        let output = NSMutableAttributedString(string: "")
        var cellOffsets: [Int] = []
        cellOffsets.reserveCapacity(surface.height * (surface.width + 1))
        let font = terminalFont
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let behindImages = surface.graphics.filter { $0.z < 0 }
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                cellOffsets.append(output.length)
                let cell = surface.cells[y * surface.width + x]
                if cell.skip { continue }
                let isCursor = surface.cursor?.visible == true && surface.cursor?.x == x && surface.cursor?.y == y
                let foreground = color(cell.foreground, default: NSColor(red: 0.88, green: 0.91, blue: 0.93, alpha: 1))
                let background = color(cell.background, default: NSColor(red: 0.075, green: 0.082, blue: 0.091, alpha: 1))
                let imageBehind = behindImages.contains {
                    x >= $0.x && x < $0.x + $0.cols && y >= $0.y && y < $0.y + $0.rows
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .paragraphStyle: cellParagraphStyle,
                    .font: cell.modifier & 1 != 0 ? boldFont : font,
                    .foregroundColor: isCursor ? background : foreground,
                    .backgroundColor: isCursor ? foreground : (imageBehind ? NSColor.clear : background)
                ]
                if cell.modifier & 8 != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                // Snap each glyph to its cells so the drawn columns match Herdr's grid.
                let symbol = cell.symbol.isEmpty ? " " : cell.symbol
                let isBold = cell.modifier & 1 != 0
                let span = x + 1 < surface.width && surface.cells[y * surface.width + x + 1].skip ? 2 : 1
                let kern = CGFloat(span) * cellWidth
                    - advance(of: symbol, font: isBold ? boldFont : font, bold: isBold)
                if abs(kern) > 0.01 { attributes[.kern] = kern }
                output.append(NSAttributedString(string: symbol, attributes: attributes))
            }
            cellOffsets.append(output.length)
            if y + 1 < surface.height {
                output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: cellParagraphStyle]))
            }
        }
        return RenderedTerminalSurface(text: output, cellOffsets: cellOffsets,
                                       width: surface.width, height: surface.height)
    }

    private static func color(_ value: UInt32, default fallback: NSColor) -> NSColor {
        let kind = value >> 24
        if kind == 2 {
            return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let palette: [UInt32] = [
            0x000000, 0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8,
            0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b,
            0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff
        ]
        if kind == 0 {
            let index = Int(value & 255)
            if index == 0 { return fallback }
            if index < palette.count { return rgb(palette[index]) }
        }
        if kind == 1 {
            let index = Int(value & 255)
            if index < 16 { return rgb(palette[index + 1]) }
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

private final class HerdrTerminalTextView: NSTextView {
    var surfaceRevision: UInt64?
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
    private var scrollRemainder: CGFloat = 0
    private var splitDrag: (split: HerdrSplit, grabOffset: Int, bootID: String,
                            lastSentAt: Double, lastRatio: Double?)?
    private var cellOffsets: [Int] = []
    private var renderedWidth = 0
    private var renderedHeight = 0
    private var selectedSnapshot: String?
    private var selectionAtSnapshot: NSRange?
    /// NSTextView tracks a selection drag inside mouseDown; replacing the text meanwhile
    /// (a busy TUI redraws constantly) would move its anchor, so frames wait until release.
    private var isTrackingSelection = false
    private var pendingSurfaceText: RenderedTerminalSurface?

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

    func prepareGraphics(_ graphics: [HerdrGraphic]) {
        let keys = Set(graphics.map { $0.key.identity })
        decodedGraphics = decodedGraphics.filter { keys.contains($0.key) }
        for graphic in graphics where decodedGraphics[graphic.key.identity] == nil {
            guard let image = Self.decodeGraphic(graphic) else { continue }
            decodedGraphics[graphic.key.identity] = image
        }
        needsDisplay = true
    }

    private static func decodeGraphic(_ graphic: HerdrGraphic) -> NSImage? {
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
        drawGraphics(in: dirtyRect, behindText: true)
        super.draw(dirtyRect)
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
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    func applySurfaceText(_ rendered: RenderedTerminalSurface) {
        if isTrackingSelection {
            pendingSurfaceText = rendered
            return
        }
        let selection = selectedRange()
        let hasSelection = selection.location != NSNotFound && selection.length > 0
        let oldStart = hasSelection ? cellAnchor(for: selection.location) : nil
        let oldEnd = hasSelection ? cellAnchor(for: NSMaxRange(selection)) : nil
        if hasSelection { captureSelectionIfChanged() }
        textStorage?.setAttributedString(rendered.text)
        cellOffsets = rendered.cellOffsets
        renderedWidth = rendered.width
        renderedHeight = rendered.height
        if let oldStart, let oldEnd {
            let start = offset(for: oldStart)
            let end = offset(for: oldEnd)
            let restored = NSRange(location: min(start, end), length: abs(end - start))
            setSelectedRange(restored)
            selectionAtSnapshot = restored
        }
    }

    func applyFallbackText(_ text: String) {
        let selection = selectedRange()
        if selection.length > 0 { captureSelectionIfChanged() }
        string = text
        cellOffsets = []
        renderedWidth = 0
        renderedHeight = 0
        if selection.location != NSNotFound && selection.length > 0 {
            let start = min(selection.location, (text as NSString).length)
            let end = min(NSMaxRange(selection), (text as NSString).length)
            let restored = NSRange(location: start, length: max(0, end - start))
            setSelectedRange(restored)
            selectionAtSnapshot = restored
        }
    }

    private func cellAnchor(for offset: Int) -> (row: Int, column: Int)? {
        guard renderedWidth > 0, renderedHeight > 0, !cellOffsets.isEmpty else { return nil }
        var low = 0
        var high = cellOffsets.count
        while low < high {
            let middle = (low + high) / 2
            if cellOffsets[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let index = max(0, low - 1)
        return (index / (renderedWidth + 1), index % (renderedWidth + 1))
    }

    private func offset(for anchor: (row: Int, column: Int)) -> Int {
        guard renderedWidth > 0, renderedHeight > 0 else { return 0 }
        let row = min(anchor.row, renderedHeight - 1)
        let column = min(anchor.column, renderedWidth)
        return cellOffsets[row * (renderedWidth + 1) + column]
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
        captureSelectionIfChanged()
        guard let selectedSnapshot, !selectedSnapshot.isEmpty else { return }
        let lines = selectedSnapshot.components(separatedBy: "\n")
        let copyText = lines.map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        selectedSnapshot = nil
        captureSelectionIfChanged()
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
        selectedSnapshot = nil
        selectionAtSnapshot = nil
        isTrackingSelection = true
        super.mouseDown(with: event)
        isTrackingSelection = false
        captureSelectionIfChanged()
        if let pending = pendingSurfaceText {
            pendingSurfaceText = nil
            applySurfaceText(pending)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if splitDrag != nil {
            updateSplitDrag(with: event, finished: true)
            splitDrag = nil
            return
        }
        if releaseMouse(button: 0, event: event) { return }
        super.mouseUp(with: event)
        captureSelectionIfChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        if splitDrag != nil {
            updateSplitDrag(with: event, finished: false)
            return
        }
        if dragMouse(button: 0, event: event) { return }
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
        return surface.splits.first { split in
            let rect = split.hitRect
            return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        }
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
        let origin = split.direction == .horizontal ? split.area.x : split.area.y
        let length = max(1, split.direction == .horizontal ? split.area.width : split.area.height)
        let ratio = min(0.9, max(0.1, Double(pointer + drag.grabOffset - origin) / Double(length)))
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
        if forwardMouse(.down(1), event: event, hold: true) { return }
        super.rightMouseDown(with: event)
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
            scrollRemainder = 0
            super.scrollWheel(with: event)
            return
        }
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        let lines: UInt16
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta
            let count = Int(abs(scrollRemainder) / TerminalPaneView.cellHeight)
            guard count > 0 else { return }
            lines = UInt16(min(count, 20))
            scrollRemainder -= CGFloat(lines) * TerminalPaneView.cellHeight * (scrollRemainder > 0 ? 1 : -1)
        } else {
            lines = UInt16(max(1, min(Int(abs(delta).rounded()), 20)))
        }
        let kind: HerdrMouseEvent.Kind = vertical
            ? (delta > 0 ? .scrollUp : .scrollDown)
            : (delta > 0 ? .scrollLeft : .scrollRight)
        sendMouse?(HerdrMouseEvent(kind: kind, column: column, row: row,
                                   modifiers: mouseModifiers(event), lines: lines), id)
    }

    private func mouseHit(_ event: NSEvent, in surface: HerdrSurface) -> (String, UInt16, UInt16)? {
        let (x, y) = surfacePoint(event)
        guard let id = surface.paneIDs.first(where: { id in
            guard let rect = surface.paneRects[id] else { return false }
            return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        }), let inner = surface.paneInnerRects[id], inner.width > 0, inner.height > 0 else { return nil }
        let column = UInt16(clamping: max(0, min(x - inner.x, inner.width - 1)))
        let row = UInt16(clamping: max(0, min(y - inner.y, inner.height - 1)))
        return (id, column, row)
    }

    private func mouseModifiers(_ event: NSEvent) -> UInt8 {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var value: UInt8 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.option) { value |= 4 }
        return value
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
        guard let surface, let inner = surface.paneInnerRects[id], inner.width > 0, inner.height > 0 else { return true }
        let point = convert(event.locationInWindow, from: nil)
        let x = Int(floor((point.x - textContainerInset.width) / TerminalPaneView.cellWidth))
        let y = Int(floor((point.y - textContainerInset.height) / TerminalPaneView.cellHeight))
        sendMouse?(HerdrMouseEvent(kind: kind,
                                   column: UInt16(clamping: max(0, min(x - inner.x, inner.width - 1))),
                                   row: UInt16(clamping: max(0, min(y - inner.y, inner.height - 1))),
                                   modifiers: mouseModifiers(event), lines: 1), id)
        return true
    }

    override func keyDown(with event: NSEvent) {
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
            let prefix = modifiers.contains(.shift) && key == "tab" ? "shift+" : ""
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
}

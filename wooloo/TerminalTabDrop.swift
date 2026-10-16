import AppKit
import QuartzCore
import SwiftUI

// MARK: Dropping a terminal tab on the panes

/// The side of a pane a dropped terminal tab splits onto.
enum TerminalDropEdge: Equatable, CaseIterable {
    case left, right, top, bottom

    var title: String { String(describing: self).capitalized }

    /// The direction `pane.move` splits the target in, which Herdr allows only right and down.
    var split: String {
        switch self {
        case .left, .right: return "right"
        case .top, .bottom: return "down"
        }
    }

    /// Left and top need the moved pane swapped with the target after the split.
    var swapsAfterMove: Bool { self == .left || self == .top }
}

/// Where a dragged terminal tab would drop: the pane under the pointer, its nearest side, and
/// the half of the pane that side highlights, in the terminal view's (flipped) coordinates.
struct TerminalTabDropTarget: Equatable {
    let paneID: String
    let edge: TerminalDropEdge
    let highlight: CGRect
}

/// What the window decides about terminal tabs dragged onto the panes. Only tab drags reach it.
struct TerminalTabDropHandler {
    /// Whether the terminal tab being dragged may split into the panes shown.
    let accepts: () -> Bool
    /// Moves the dragged tab's pane next to a pane; false when the drop is refused.
    let drop: (_ paneID: String, _ edge: TerminalDropEdge) -> Bool
    var targets: (_ source: String) -> [(id: String, title: String)] = { _ in [] }
    var movePane: (_ source: String, _ target: String, _ edge: TerminalDropEdge) -> Bool = { _, _, _ in false }
    var canDetach: (_ source: String) -> Bool = { _ in false }
    var detach: (_ source: String) -> Void = { _ in }
}

enum TerminalTabDrop {
    /// Pane handles use a separate type so a layout drag cannot become terminal input.
    static let panePasteboardType = NSPasteboard.PasteboardType("com.wooloo.terminal-pane")

    /// The pasteboard type of tab drags, `TabDragModel.type`.
    static let pasteboardType = NSPasteboard.PasteboardType(TabDragModel.type.identifier)

    static func carriesTab(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(pasteboardType) == true || pasteboard.types?.contains(panePasteboardType) == true
    }

    /// The side of `rect` nearest to `point`, measured relative to the pane's size, so the
    /// pane is cut along its diagonals into four zones and a wide pane still has side zones.
    static func edge(in rect: CGRect, at point: CGPoint) -> TerminalDropEdge {
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let distances: [(TerminalDropEdge, CGFloat)] = [
            (.left, (x - rect.minX) / width), (.right, (rect.maxX - x) / width),
            (.top, (y - rect.minY) / height), (.bottom, (rect.maxY - y) / height)
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The half of `rect` on `edge`, in flipped coordinates (top is `minY`).
    static func highlight(of rect: CGRect, edge: TerminalDropEdge) -> CGRect {
        switch edge {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    /// The pane under `point`, or the nearest one when the point falls between panes.
    static func target(at point: CGPoint, panes: [(id: String, rect: CGRect)]) -> TerminalTabDropTarget? {
        let pane = panes.first { $0.rect.contains(point) }
            ?? panes.min { distance(point, $0.rect) < distance(point, $1.rect) }
        guard let pane, pane.rect.width > 0, pane.rect.height > 0 else { return nil }
        let edge = edge(in: pane.rect, at: point)
        return TerminalTabDropTarget(paneID: pane.id, edge: edge, highlight: highlight(of: pane.rect, edge: edge))
    }

    /// The panes of a live surface in a view whose grid starts at `inset`.
    static func paneRects(of surface: HerdrSurface, inset: CGSize, cell: CGSize) -> [(id: String, rect: CGRect)] {
        surface.paneIDs.compactMap { id in
            guard let rect = surface.paneRects[id] else { return nil }
            return (id, CGRect(x: inset.width + CGFloat(rect.x) * cell.width,
                               y: inset.height + CGFloat(rect.y) * cell.height,
                               width: CGFloat(rect.width) * cell.width, height: CGFloat(rect.height) * cell.height))
        }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Draws the drop highlight and hover handle over a terminal view. Only the handle takes
/// mouse events; selection, scrolling and split resizing reach the terminal underneath.
final class TerminalDropOverlayView: NSView {
    private let highlight = CALayer()
    let moveHandle = TerminalMoveHandle(frame: .zero)
    var pointerMoved: ((NSPoint) -> Void)?
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved?(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { pointerMoved?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { showHandle(for: nil, rect: nil) }

    func showHandle(for pane: String?, rect: CGRect?) {
        guard let pane, let rect else { moveHandle.isHidden = true; return }
        moveHandle.paneID = pane
        moveHandle.frame = CGRect(x: max(rect.minX, rect.maxX - 36), y: rect.minY + 4, width: 28, height: 26)
        moveHandle.isHidden = false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.isHidden = true
        highlight.borderWidth = 1.5
        highlight.cornerRadius = 3
        layer?.addSublayer(highlight)
        moveHandle.isHidden = true
        addSubview(moveHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !moveHandle.isHidden && moveHandle.frame.contains(local) ? moveHandle : nil
    }

    /// Highlights `rect` (in this view's coordinates) in the theme's accent, or hides it for nil.
    /// The highlight slides between halves; it appears in place.
    func show(_ rect: CGRect?, accent: UInt32) {
        CATransaction.begin()
        defer { CATransaction.commit() }
        guard let rect else {
            CATransaction.setDisableActions(true)
            highlight.isHidden = true
            return
        }
        let appearing = highlight.isHidden
        CATransaction.setDisableActions(appearing)
        CATransaction.setAnimationDuration(0.12)
        highlight.backgroundColor = WoolooTheme.nsColor(accent, alpha: 0.18).cgColor
        highlight.borderColor = WoolooTheme.nsColor(accent, alpha: 0.85).cgColor
        highlight.frame = rect.insetBy(dx: 1, dy: 1)
        highlight.isHidden = false
    }
}

/// A small native drag source; dragging this control never sends mouse input to the shell.
final class TerminalMoveHandle: NSView, NSDraggingSource {
    static weak var activeHandle: TerminalMoveHandle?
    var paneID = ""
    var makeMenu: ((String) -> NSMenu)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to move terminal; click for layout options"
        setAccessibilityLabel("Move Terminal")
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 5
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
            .draw(in: bounds.insetBy(dx: 5, dy: 4))
    }

    override func mouseDown(with event: NSEvent) {
        guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
        guard next.type == .leftMouseDragged else {
            if let menu = makeMenu?(paneID) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let item = NSPasteboardItem()
        item.setString(paneID, forType: TerminalTabDrop.panePasteboardType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil))
        Self.activeHandle = self
        beginDraggingSession(with: [drag], event: next, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.activeHandle = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// A native destination avoids converting the handle's private pasteboard type through
/// SwiftUI's item-provider bridge. It only takes pointer events during this window's pane drag.
struct TerminalPaneTabDropView: NSViewRepresentable {
    let accent: NSColor
    let canDetach: (String) -> Bool
    let detach: (String) -> Bool

    func makeNSView(context: Context) -> TerminalPaneTabDropTargetView {
        let view = TerminalPaneTabDropTargetView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TerminalPaneTabDropTargetView, context: Context) {
        view.accent = accent
        view.canDetach = canDetach
        view.detach = detach
    }
}

final class TerminalPaneTabDropTargetView: NSView {
    var accent = NSColor.controlAccentColor
    var canDetach: (String) -> Bool = { _ in false }
    var detach: (String) -> Bool = { _ in false }
    private let label = NSTextField(labelWithString: "Move to Own Tab")
    private(set) var isTargeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([TerminalTabDrop.panePasteboardType])
        wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.drawsBackground = true
        label.backgroundColor = .windowBackgroundColor
        label.isHidden = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = CGPoint(x: max(8, bounds.width - label.frame.width - 12),
                                     y: (bounds.height - label.frame.height) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let source = TerminalMoveHandle.activeHandle, source.window === window,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    private func source(_ sender: NSDraggingInfo) -> String? {
        guard let pane = sender.draggingPasteboard.string(forType: TerminalTabDrop.panePasteboardType),
              canDetach(pane) else { return nil }
        return pane
    }

    private func highlight(_ targeted: Bool) {
        isTargeted = targeted
        label.isHidden = !targeted
        layer?.borderColor = accent.cgColor
        layer?.borderWidth = targeted ? 2 : 0
        layer?.backgroundColor = targeted ? accent.withAlphaComponent(0.12).cgColor : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = source(sender) != nil
        highlight(accepted)
        return accepted ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { source(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard let pane = source(sender) else { return false }
        return detach(pane)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight(false) }
}

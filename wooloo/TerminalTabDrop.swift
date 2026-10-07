import AppKit
import QuartzCore

// MARK: Dropping a terminal tab on the panes

/// The side of a pane a dropped terminal tab splits onto.
enum TerminalDropEdge: Equatable, CaseIterable {
    case left, right, top, bottom

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
}

enum TerminalTabDrop {
    /// The pasteboard type of tab drags, `TabDragModel.type`.
    static let pasteboardType = NSPasteboard.PasteboardType(TabDragModel.type.identifier)

    static func carriesTab(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(pasteboardType) == true
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

/// Draws the drop highlight over a terminal view. It never takes mouse events or drags, so
/// clicks, selection, scrolling and split drags reach the terminal under it.
final class TerminalDropOverlayView: NSView {
    private let highlight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.isHidden = true
        highlight.borderWidth = 1.5
        highlight.cornerRadius = 3
        layer?.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

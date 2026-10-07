import AppKit
import SwiftUI

// MARK: Panels of the main area

/// What a panel of the main area shows. Every tab type follows the same rules:
/// - Terminal tabs only ever show in the main panel, which is always there, so Herdr's terminal
///   surface stays unique. Dragged onto the terminals they split inside Herdr instead.
/// - Document tabs (files, previews, PDFs, images, changes, commits, untitled files) and the
///   Search tab show in the main panel when selected there, or in a panel of their own beside
///   it. Each shows in one place at a time: placing it somewhere moves it there.
enum PanelContent: Hashable {
    /// The tab bar's selection: the selected terminal tab, or the active document or Search.
    case main
    /// A document tab, by its backup ID, which Save As keeps.
    case document(UUID)
    case search
}

/// How a split arranges its two panels.
enum PanelSplitAxis: Equatable {
    /// Side by side.
    case horizontal
    /// One above the other.
    case vertical
}

/// Where a dragged tab drops on a panel: in place of what the panel shows, or on one side,
/// splitting the panel in two.
enum PanelDropZone: Equatable {
    case center
    case edge(TerminalDropEdge)
}

/// A split's divider, in the layout's coordinates (top is `minY`).
struct PanelDivider: Equatable {
    /// The split's place in the tree: false is a split's first child, true its second.
    let path: [Bool]
    let axis: PanelSplitAxis
    /// The line between the two panels.
    let frame: CGRect
    /// The whole split, which the ratio divides.
    let container: CGRect
}

/// The main area's panels: the main panel, alone or split with panels of documents or Search.
indirect enum PanelLayout: Equatable {
    case panel(PanelContent)
    case split(PanelSplitAxis, ratio: Double, PanelLayout, PanelLayout)

    static let single = PanelLayout.panel(.main)
    /// The divider's thickness.
    static let dividerWidth: CGFloat = 1

    /// The panels' contents, first to last.
    var contents: [PanelContent] {
        switch self {
        case .panel(let content): return [content]
        case .split(_, _, let first, let second): return first.contents + second.contents
        }
    }

    var isSplit: Bool {
        if case .split = self { return true }
        return false
    }

    func contains(_ content: PanelContent) -> Bool { contents.contains(content) }

    /// Without `content`'s panel: the other half of its split takes the split's place. The main
    /// panel is never removed.
    func removing(_ content: PanelContent) -> PanelLayout {
        guard content != .main else { return self }
        return keeping { $0 != content }
    }

    /// Only the panels whose content passes `keep`, and the main panel.
    func keeping(_ keep: (PanelContent) -> Bool) -> PanelLayout {
        kept(keep) ?? .single
    }

    private func kept(_ keep: (PanelContent) -> Bool) -> PanelLayout? {
        switch self {
        case .panel(let content):
            return content == .main || keep(content) ? self : nil
        case .split(let axis, let ratio, let first, let second):
            switch (first.kept(keep), second.kept(keep)) {
            case let (first?, second?): return .split(axis, ratio: ratio, first, second)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }

    /// Shows `content` in a new panel on `edge` of `target`'s panel, which keeps the other
    /// half. `content` leaves the panel it was in.
    func placing(_ content: PanelContent, beside target: PanelContent, edge: TerminalDropEdge) -> PanelLayout {
        guard content != .main, content != target, contains(target) else { return self }
        let added = PanelLayout.panel(content)
        return removing(content).replacingPanel(target) { existing in
            switch edge {
            case .left: return .split(.horizontal, ratio: 0.5, added, existing)
            case .right: return .split(.horizontal, ratio: 0.5, existing, added)
            case .top: return .split(.vertical, ratio: 0.5, added, existing)
            case .bottom: return .split(.vertical, ratio: 0.5, existing, added)
            }
        }
    }

    /// Shows `content` in place of what a side panel shows; that tab stays open in the tab bar.
    /// `content` leaves the panel it was in.
    func replacing(_ target: PanelContent, with content: PanelContent) -> PanelLayout {
        guard target != .main, content != .main, content != target, contains(target) else { return self }
        return removing(content).replacingPanel(target) { _ in .panel(content) }
    }

    private func replacingPanel(_ target: PanelContent, with transform: (PanelLayout) -> PanelLayout) -> PanelLayout {
        switch self {
        case .panel(let content):
            return content == target ? transform(self) : self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio, first.replacingPanel(target, with: transform),
                          second.replacingPanel(target, with: transform))
        }
    }

    /// The split at `path` with the share `ratio` for its first child.
    func settingRatio(_ ratio: Double, at path: [Bool]) -> PanelLayout {
        guard case .split(let axis, let current, let first, let second) = self else { return self }
        guard let step = path.first else { return .split(axis, ratio: ratio, first, second) }
        let rest = Array(path.dropFirst())
        return step ? .split(axis, ratio: current, first, second.settingRatio(ratio, at: rest))
                    : .split(axis, ratio: current, first.settingRatio(ratio, at: rest), second)
    }

    /// Each panel's frame and each split's divider within `rect`, in whole points.
    func arranged(in rect: CGRect) -> (panels: [(content: PanelContent, frame: CGRect)], dividers: [PanelDivider]) {
        var panels: [(content: PanelContent, frame: CGRect)] = []
        var dividers: [PanelDivider] = []
        arrange(in: rect, path: [], panels: &panels, dividers: &dividers)
        return (panels, dividers)
    }

    private func arrange(in rect: CGRect, path: [Bool], panels: inout [(content: PanelContent, frame: CGRect)],
                         dividers: inout [PanelDivider]) {
        switch self {
        case .panel(let content):
            panels.append((content, rect))
        case .split(let axis, let ratio, let first, let second):
            let width = Self.dividerWidth
            let length = axis == .horizontal ? rect.width : rect.height
            let firstLength = max(((length - width) * CGFloat(ratio)).rounded(), 0)
            let secondLength = max(length - width - firstLength, 0)
            let firstRect, line, secondRect: CGRect
            if axis == .horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                line = CGRect(x: rect.minX + firstLength, y: rect.minY, width: width, height: rect.height)
                secondRect = CGRect(x: line.maxX, y: rect.minY, width: secondLength, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                line = CGRect(x: rect.minX, y: rect.minY + firstLength, width: rect.width, height: width)
                secondRect = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: secondLength)
            }
            dividers.append(PanelDivider(path: path, axis: axis, frame: line, container: rect))
            first.arrange(in: firstRect, path: path + [false], panels: &panels, dividers: &dividers)
            second.arrange(in: secondRect, path: path + [true], panels: &panels, dividers: &dividers)
        }
    }
}

enum PanelDrop {
    /// The share of a panel's width and height, on each side, whose drops split the panel; the
    /// middle replaces what it shows.
    static let edgeShare: CGFloat = 0.25

    static func zone(in rect: CGRect, at point: CGPoint) -> PanelDropZone {
        let middle = rect.insetBy(dx: rect.width * edgeShare, dy: rect.height * edgeShare)
        return middle.contains(point) ? .center : .edge(TerminalTabDrop.edge(in: rect, at: point))
    }

    /// Where the tab would show: the half of the panel on that side, or the whole panel.
    static func highlight(of rect: CGRect, zone: PanelDropZone) -> CGRect {
        switch zone {
        case .center: return rect
        case .edge(let edge): return TerminalTabDrop.highlight(of: rect, edge: edge)
        }
    }

    /// Whether dropping `content` there changes anything. A panel never splits beside or
    /// replaces itself, and the main panel's middle takes only a tab it does not show already.
    /// `mainShows` is the document or Search the main panel shows, nil for the terminals.
    static func accepts(_ content: PanelContent, on target: PanelContent, zone: PanelDropZone,
                        mainShows: PanelContent?) -> Bool {
        guard content != .main, content != target else { return false }
        if target == .main && zone == .center { return mainShows != content }
        return true
    }

    /// The new share of a split's first child after dragging its divider by `translation` from
    /// `startRatio`, leaving each child at least a quarter of the split or 160 points.
    static func ratio(_ startRatio: Double, dragged translation: CGFloat, in length: CGFloat) -> Double {
        let usable = max(length - PanelLayout.dividerWidth, 1)
        let minimum = min(160, usable / 4)
        let first = min(max(CGFloat(startRatio) * usable + translation, minimum), usable - minimum)
        return Double(first / usable)
    }
}

// MARK: Showing the panels

/// What the window does with tabs dragged onto the panels and with clicks in them.
struct PanelDropHandler {
    /// What the tab being dragged would show; nil for a terminal tab or no drag.
    let dragged: () -> PanelContent?
    let accepts: (_ content: PanelContent, _ target: PanelContent, _ zone: PanelDropZone) -> Bool
    /// Places the dragged tab; false when the drop is refused.
    let drop: (_ target: PanelContent, _ zone: PanelDropZone) -> Bool
    /// A click in a panel focuses it.
    let focus: (PanelContent) -> Void
}

/// Lays the panels out with draggable dividers. Panels keep their identity while the layout
/// changes around them, so the terminals and editors are not rebuilt when a split opens.
struct PanelLayoutView<Panel: View>: View {
    @Environment(\.xherdrTheme) private var theme
    let layout: PanelLayout
    let drop: PanelDropHandler
    let setRatio: (_ path: [Bool], _ ratio: Double) -> Void
    @ViewBuilder let panel: (PanelContent) -> Panel

    var body: some View {
        GeometryReader { geometry in
            let arranged = layout.arranged(in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(arranged.panels, id: \.content) { item in
                    panel(item.content)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .clipped()
                        .position(x: item.frame.midX, y: item.frame.midY)
                }
                ForEach(arranged.dividers, id: \.path) { divider in
                    PanelDividerView(divider: divider, ratio: ratio(at: divider.path), setRatio: setRatio)
                }
                PanelDropOverlay(panels: arranged.panels, handler: drop, accent: theme.herdr.accent)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func ratio(at path: [Bool]) -> Double {
        var node = layout
        for step in path {
            guard case .split(_, _, let first, let second) = node else { break }
            node = step ? second : first
        }
        if case .split(_, let ratio, _, _) = node { return ratio }
        return 0.5
    }
}

/// A split's divider, with a wider handle that drags it and double-clicks back to half.
private struct PanelDividerView: View {
    let divider: PanelDivider
    let ratio: Double
    let setRatio: ([Bool], Double) -> Void
    @State private var startRatio: Double?

    var body: some View {
        let horizontal = divider.axis == .horizontal
        let length = horizontal ? divider.container.width : divider.container.height
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                ResizeHandleArea(vertical: !horizontal, tooltip: "Drag to resize · double-click to split evenly",
                                 onDrag: { translation in
                                     let start = startRatio ?? ratio
                                     startRatio = start
                                     setRatio(divider.path, PanelDrop.ratio(start, dragged: translation, in: length))
                                 },
                                 onDragEnd: { startRatio = nil },
                                 onReset: { setRatio(divider.path, 0.5) })
                    .frame(width: horizontal ? 7 : divider.frame.width, height: horizontal ? divider.frame.height : 7)
            }
            .position(x: divider.frame.midX, y: divider.frame.midY)
    }
}

/// Takes tab drags onto the panels and shows where the tab would go. Only drags of document
/// and Search tabs carry `TabDragModel.panelType`, so terminal tabs still reach the terminal
/// view under it, which splits them inside Herdr. It takes no mouse events; it only watches
/// clicks to focus the panel under them.
private struct PanelDropOverlay: NSViewRepresentable {
    let panels: [(content: PanelContent, frame: CGRect)]
    let handler: PanelDropHandler
    let accent: UInt32

    func makeNSView(context: Context) -> PanelDropOverlayView { PanelDropOverlayView() }

    func updateNSView(_ view: PanelDropOverlayView, context: Context) {
        view.panels = panels
        view.handler = handler
        view.accent = accent
    }
}

final class PanelDropOverlayView: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType(TabDragModel.panelType.identifier)

    var panels: [(content: PanelContent, frame: CGRect)] = []
    var handler: PanelDropHandler?
    var accent: UInt32 = 0
    private let highlight = TerminalDropOverlayView()
    private var clickMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
        registerForDraggedTypes([Self.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // Drag destinations are found by their registered types, not by hit testing, so drags
    // still arrive while clicks, scrolling and text selection reach the panels under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.window, let panel = self.panel(at: event.locationInWindow) {
                self.handler?.focus(panel.content)
            }
            return event
        }
    }

    private func panel(at windowPoint: NSPoint) -> (content: PanelContent, frame: CGRect)? {
        let point = convert(windowPoint, from: nil)
        return panels.first { $0.frame.contains(point) }
    }

    private func target(_ sender: NSDraggingInfo) -> (content: PanelContent, zone: PanelDropZone, highlight: CGRect)? {
        guard let handler, let dragged = handler.dragged(),
              let panel = panel(at: sender.draggingLocation) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let zone = PanelDrop.zone(in: panel.frame, at: point)
        guard handler.accepts(dragged, panel.content, zone) else { return nil }
        return (panel.content, zone, PanelDrop.highlight(of: panel.frame, zone: zone))
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = target(sender)
        highlight.show(target?.highlight, accent: accent)
        return target == nil ? [] : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight.show(nil, accent: accent)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlight.show(nil, accent: accent)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = target(sender)
        highlight.show(nil, accent: accent)
        guard let target, let handler else { return false }
        return handler.drop(target.content, target.zone)
    }
}

// MARK: Panel commands

extension ContentCommands {
    /// The Space's panels.
    var panelLayout: PanelLayout {
        window.panelLayouts[WorkspaceSessionPersistence.key(for: documents.space)] ?? .single
    }

    private func setPanelLayout(_ layout: PanelLayout) {
        let key = WorkspaceSessionPersistence.key(for: documents.space)
        guard (window.panelLayouts[key] ?? .single) != layout else { return }
        window.panelLayouts[key] = layout.isSplit ? layout : nil
    }

    /// What a tab of the tab bar shows in a panel: a document's or Search's; nil for others.
    func panelContent(forTab id: String) -> PanelContent? {
        if id == WorkspaceSearchModel.tabID { return .search }
        return documents.document(id).map { .document($0.backupID) }
    }

    /// The tab ID of a side panel's document or Search.
    func tabID(of content: PanelContent) -> String? {
        switch content {
        case .main: return documents.activeID
        case .search: return WorkspaceSearchModel.tabID
        case .document(let backupID): return documents.visibleDocuments.first { $0.backupID == backupID }?.id
        }
    }

    /// What the main panel shows instead of the terminals, if anything.
    var mainPanelContent: PanelContent? {
        documents.activeID.flatMap(panelContent(forTab:))
    }

    /// The focused panel, or the main one when that panel is gone.
    var focusedPanel: PanelContent {
        panelLayout.contains(window.focusedPanel) ? window.focusedPanel : .main
    }

    /// The tab of the focused panel's document or Search, which the editor commands, closing
    /// the current tab and the explorer follow; nil when the terminals have focus.
    var focusedDocumentID: String? {
        tabID(of: focusedPanel)
    }

    func focusPanel(_ content: PanelContent) {
        let content = panelLayout.contains(content) ? content : .main
        if window.focusedPanel != content { window.focusedPanel = content }
    }

    /// Shows a document or Search tab clicked in the tab bar: focuses its side panel when it has
    /// one, otherwise shows it in the main panel.
    func selectTab(_ id: String) {
        if let content = panelContent(forTab: id), panelLayout.contains(content) {
            focusPanel(content)
            if let index = documents.documents.firstIndex(where: { $0.id == id }) {
                documents.documents[index].focusRequest = UUID()
            }
        } else {
            documents.activeID = id
            focusPanel(.main)
        }
    }

    /// Keeps the rule that a tab shows in one place: a document or Search made active (opened
    /// from the explorer, Go to File, search results…) while it has a side panel focuses that
    /// panel, and the main panel keeps what it showed.
    func activeDocumentChanged(from old: String?, to new: String?) {
        guard let new else { return }
        guard let content = panelContent(forTab: new), panelLayout.contains(content) else {
            focusPanel(.main)
            return
        }
        focusPanel(content)
        let previous = old.flatMap { old -> String? in
            guard let shown = panelContent(forTab: old), !panelLayout.contains(shown) else { return nil }
            return old == WorkspaceSearchModel.tabID || documents.document(old)?.space == documents.space ? old : nil
        }
        documents.activeID = previous
    }

    /// Drops a document or Search tab on a panel: in its middle it replaces what the panel
    /// shows, on a side it splits the panel. A tab leaving the main panel leaves the terminals
    /// there. Returns false when the drop changes nothing.
    @discardableResult
    func dropTab(_ id: String, on target: PanelContent, zone: PanelDropZone) -> Bool {
        guard let content = panelContent(forTab: id) else { return false }
        let mainShows = mainPanelContent
        guard PanelDrop.accepts(content, on: target, zone: zone, mainShows: mainShows) else { return false }
        // A panel's document stays: a later preview must not replace it.
        documents.keepOpen(id)
        switch zone {
        case .center where target == .main:
            setPanelLayout(panelLayout.removing(content))
            documents.activeID = id
            focusPanel(.main)
            return true
        case .center:
            setPanelLayout(panelLayout.replacing(target, with: content))
        case .edge(let edge):
            setPanelLayout(panelLayout.placing(content, beside: target, edge: edge))
        }
        if mainShows == content { documents.activeID = nil }
        focusPanel(content)
        return true
    }

    /// Opens a tab in a new panel beside the focused one, or beside the main panel.
    func splitTab(_ id: String, edge: TerminalDropEdge) {
        let content = panelContent(forTab: id)
        let target = focusedPanel == content ? PanelContent.main : focusedPanel
        dropTab(id, on: target, zone: .edge(edge))
    }

    /// Closes a side panel; its tab stays open in the tab bar.
    func closePanel(_ content: PanelContent) {
        setPanelLayout(panelLayout.removing(content))
        if window.focusedPanel == content { window.focusedPanel = .main }
    }

    /// Drops the panels of closed tabs from every Space's layout.
    func prunePanels() {
        let open = Set(documents.documents.map(\.backupID))
        for (key, layout) in window.panelLayouts {
            let kept = layout.keeping { content in
                switch content {
                case .main: return true
                case .search: return window.showsSearchTab
                case .document(let backupID): return open.contains(backupID)
                }
            }
            if kept != layout { window.panelLayouts[key] = kept.isSplit ? kept : nil }
        }
        if !panelLayout.contains(window.focusedPanel) { window.focusedPanel = .main }
    }
}

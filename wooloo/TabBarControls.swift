import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: New tab buttons

/// A tab bar button's icon with a small "+" at its top-left corner, cut out of the bar's
/// background so it stays legible over the symbol.
struct TabBarAddIcon: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: typography.secondary))
            .padding(.top, 4)
            .padding(.leading, 5)
            .overlay(alignment: .topLeading) {
                Image(systemName: "plus")
                    .font(.system(size: max(6, typography.tiny - 1), weight: .black))
                    .foregroundStyle(theme.accent)
                    .padding(1.5)
                    .background(theme.barBackground, in: Circle())
            }
    }
}

// MARK: Middle click

extension View {
    /// Runs `action` when the middle mouse button is clicked on the view. Other clicks, drags,
    /// context menus and scrolling reach the view as usual.
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(action: action))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.action = action
    }
}

/// Takes only middle button events: for any other event its hit test finds nothing, so the
/// SwiftUI content under it gets the event.
final class MiddleClickView: NSView {
    var action: () -> Void = {}
    private var pressed = false

    private static func isMiddle(_ event: NSEvent?) -> Bool {
        guard let event, [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type) else { return false }
        return event.buttonNumber == 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.isMiddle(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        pressed = true
    }

    /// Acts on release over the view, as browsers and VS Code close tabs.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed && inside { action() }
        pressed = false
    }
}

// MARK: Reordering tabs

/// The tab bar's groups; a tab moves only within its own. Search is a group of one: it only
/// moves into a panel.
enum TabDragGroup {
    case terminal, document, search
}

/// The tab being dragged and where it would drop. Tab drags carry only types private to
/// wooloo, so the explorer and Finder ignore them, and the tab bar ignores theirs: terminal
/// tabs `type`, which the terminal view takes to split inside Herdr, and document and Search
/// tabs `panelType`, which the main area's panels take.
@MainActor
final class TabDragModel: ObservableObject {
    static let type = UTType(exportedAs: "dev.wooloo.tab")
    static let panelType = UTType(exportedAs: "dev.wooloo.panel-tab")
    static let types = [type, panelType]

    static func type(of group: TabDragGroup) -> UTType {
        group == .terminal ? type : panelType
    }

    /// A drop place: before or after the tab at `index` of `group`.
    struct Target: Equatable {
        let group: TabDragGroup
        let index: Int
        let after: Bool

        /// The gap the tab goes into, 0 before the first tab, as `tab.move` takes it.
        var insertIndex: Int { index + (after ? 1 : 0) }
    }

    private(set) var dragged: (group: TabDragGroup, id: String)?
    /// Published only when it changes, to move the insertion line.
    @Published private(set) var target: Target?

    func begin(_ group: TabDragGroup, id: String) -> NSItemProvider {
        dragged = (group, id)
        target = nil
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.type(of: group).identifier,
                                            visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }

    func accepts(_ group: TabDragGroup, _ info: DropInfo) -> Bool {
        dragged?.group == group && info.hasItemsConforming(to: [Self.type(of: group)])
    }

    func hover(_ target: Target?) {
        if self.target != target { self.target = target }
    }

    func leave(_ group: TabDragGroup, index: Int) {
        if target?.group == group && target?.index == index { target = nil }
    }

    /// The terminal tab being dragged, which the panes can also take to split.
    var draggedTerminalTab: String? {
        dragged?.group == .terminal ? dragged?.id : nil
    }

    /// The dragged terminal tab, ending the drag, for a drop outside the tab bar.
    func dropTerminalTab() -> String? {
        defer { endDrag() }
        return draggedTerminalTab
    }

    /// The document or Search tab being dragged, which the main area's panels take.
    var draggedPanelTab: String? {
        dragged?.group == .terminal ? nil : dragged?.id
    }

    /// The dragged document or Search tab, ending the drag, for a drop on the panels.
    func dropPanelTab() -> String? {
        defer { endDrag() }
        return draggedPanelTab
    }

    private func endDrag() {
        dragged = nil
        if target != nil { target = nil }
    }

    /// The dragged tab's ID and the gap it drops into, ending the drag.
    func drop() -> (id: String, insertIndex: Int)? {
        defer {
            dragged = nil
            target = nil
        }
        guard let dragged, let target, target.group == dragged.group else { return nil }
        return (dragged.id, target.insertIndex)
    }
}

extension View {
    /// Makes a tab draggable within its group, showing where a dragged tab of the group would
    /// go: on the side of the tab under the pointer. `onMove` gets the dragged tab's ID and its
    /// gap, as `TabDragModel.Target.insertIndex`.
    func tabReorder(_ group: TabDragGroup, id: String, index: Int, drag: TabDragModel,
                    onMove: @escaping (String, Int) -> Void) -> some View {
        modifier(TabReorderModifier(group: group, id: id, index: index, drag: drag, onMove: onMove))
    }

    /// Drops on the bar's space after a group's tabs, which put the dragged tab last in its
    /// group: after the tab at the group's `lastIndex`.
    func tabDropAtEnd(drag: TabDragModel, _ ends: [TabDragGroup: TabDropEnd]) -> some View {
        onDrop(of: TabDragModel.types, delegate: TabEndDropDelegate(drag: drag, ends: ends))
    }
}

/// Where a group's tabs end, and how one of them moves.
struct TabDropEnd {
    let lastIndex: Int
    let onMove: (String, Int) -> Void
}

private struct TabReorderModifier: ViewModifier {
    @Environment(\.woolooTheme) private var theme
    let group: TabDragGroup
    let id: String
    let index: Int
    @ObservedObject var drag: TabDragModel
    let onMove: (String, Int) -> Void
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrag { drag.begin(group, id: id) }
            .onDrop(of: TabDragModel.types, delegate: TabDropDelegate(group: group, index: index, width: width,
                                                                       drag: drag, onMove: onMove))
            .overlay(alignment: drag.target?.after == true ? .trailing : .leading) {
                if let target = drag.target, target.group == group, target.index == index {
                    // In the 2-point gap between tabs.
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 2)
                        .offset(x: target.after ? 2 : -2)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct TabDropDelegate: DropDelegate {
    let group: TabDragGroup
    let index: Int
    /// The tab's width, to tell its halves apart; nil drops after it wherever the pointer is.
    let width: CGFloat?
    let drag: TabDragModel
    let onMove: (String, Int) -> Void

    private func target(_ info: DropInfo) -> TabDragModel.Target {
        TabDragModel.Target(group: group, index: index, after: width.map { info.location.x >= $0 / 2 } ?? true)
    }

    func validateDrop(info: DropInfo) -> Bool { drag.accepts(group, info) }

    func dropEntered(info: DropInfo) {
        if drag.accepts(group, info) { drag.hover(target(info)) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard drag.accepts(group, info) else { return nil }
        drag.hover(target(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag.leave(group, index: index)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard drag.accepts(group, info) else { return false }
        drag.hover(target(info))
        guard let move = drag.drop() else { return false }
        onMove(move.id, move.insertIndex)
        return true
    }
}

private struct TabEndDropDelegate: DropDelegate {
    let drag: TabDragModel
    let ends: [TabDragGroup: TabDropEnd]

    /// The dragged tab's group, when it ends here.
    private func end(_ info: DropInfo) -> (TabDragGroup, TabDropEnd)? {
        guard let group = drag.dragged?.group, let end = ends[group], drag.accepts(group, info) else { return nil }
        return (group, end)
    }

    func validateDrop(info: DropInfo) -> Bool { end(info) != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let (group, end) = end(info) else { return nil }
        drag.hover(TabDragModel.Target(group: group, index: end.lastIndex, after: true))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if let (group, end) = end(info) { drag.leave(group, index: end.lastIndex) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let (group, end) = end(info) else { return false }
        drag.hover(TabDragModel.Target(group: group, index: end.lastIndex, after: true))
        guard let move = drag.drop() else { return false }
        end.onMove(move.id, move.insertIndex)
        return true
    }
}

// MARK: Saving untitled files

/// Asks where to save an untitled document: a path relative to the Space root, the same for
/// a Space on this Mac or over SSH. Missing folders are created; an existing file is refused.
struct UntitledSaveSheet: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let title: String
    let location: WorkspaceFileLocation
    let save: (String) async -> String?
    let cancel: () -> Void
    @State private var path: String
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var fieldFocused: Bool

    init(title: String, location: WorkspaceFileLocation, save: @escaping (String) async -> String?,
         cancel: @escaping () -> Void) {
        self.title = title
        self.location = location
        self.save = save
        self.cancel = cancel
        _path = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save “\(title)”")
                .font(.system(size: typography.heading, weight: .semibold))
            Text("Path relative to the Space root. Missing folders are created.")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: location.isLocal ? "desktopcomputer" : "network")
                    .foregroundStyle(.secondary)
                Text("\(location.machineLabel) · \(location.root)/")
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            TextField("File name", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: typography.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit(commit)
                .disabled(isSaving)
            if let error {
                Text(error)
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            error = await save(path)
            isSaving = false
        }
    }
}

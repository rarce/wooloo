import SwiftUI

/// Find in the selected terminal pane of a herdr-core connection: wooloo searches the screen
/// and scrollback it emulates, scrolls to the match and highlights it. Return goes to the
/// next older match and Shift-Return to the next newer one, as in other terminals; Escape
/// closes the bar and removes the highlight.
struct TerminalFindBar: View {
    /// Not observed: the bar reads none of the store's published state, and would redraw on each change.
    let store: HerdrStore
    /// Bumped each time Find in Terminal runs, to put the keyboard back in the field.
    let request: Int
    /// The selected pane, which the bar searches: when it changes, the query runs again there.
    let paneID: String?
    /// The terminal that had the keyboard when the bar opened, which gets it back on close.
    let returnFocus: WeakView
    let onClose: () -> Void

    @Environment(\.woolooTheme) private var theme
    @State private var query = ""
    @State private var result: TerminalFindResult?
    @State private var searched = false
    @State private var searching: Task<Void, Never>?
    @FocusState private var focused: Bool

    final class WeakView {
        weak var view: NSView?
    }

    /// Takes the keyboard from `window`'s terminal, if it has it, and returns that terminal,
    /// which does not take it back on its own until it is made first responder again.
    static func releaseKeyboard(in window: NSWindow?) -> NSView? {
        guard let window, let terminal = window.firstResponder as? HerdrTerminalTextView else { return nil }
        terminal.yieldsKeyboard = true
        window.makeFirstResponder(nil)
        return terminal
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Terminal", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { find(older: !Self.shiftHeld(NSApp.currentEvent)) }
                .onChange(of: query) { _, _ in find(older: true) }
                .accessibilityIdentifier("terminal-find-field")
            Text(status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button { find(older: true) } label: { Image(systemName: "chevron.up") }
                .help("Older Match (Return)")
                .disabled(query.isEmpty)
            Button { find(older: false) } label: { Image(systemName: "chevron.down") }
                .help("Newer Match (Shift-Return)")
                .disabled(query.isEmpty)
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Close (Escape)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .onExitCommand { close() }
        .onAppear {
            focused = true
        }
        .onChange(of: request) { _, _ in focused = true }
        .onChange(of: paneID) { _, _ in find(older: true) }
        .onDisappear {
            searching?.cancel()
            store.endTerminalFind()
        }
    }

    /// Shift on the Return that submitted the field: read from that key event, since the
    /// keyboard's state by the time SwiftUI calls `onSubmit` may already be another.
    static func shiftHeld(_ event: NSEvent?) -> Bool {
        (event?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
    }

    private var status: String {
        guard searched, !query.isEmpty else { return "" }
        guard let result else { return "No results" }
        return "\(result.index) of \(result.total)"
    }

    private func find(older: Bool) {
        searching?.cancel()
        let text = query
        guard !text.isEmpty else {
            result = nil
            searched = false
            store.endTerminalFind()
            return
        }
        searching = Task {
            let found = await store.findInTerminal(text, older: older)
            guard !Task.isCancelled, text == query else { return }
            result = found
            searched = true
        }
    }

    private func close() {
        searching?.cancel()
        store.endTerminalFind()
        onClose()
        // The field goes away with the bar: without this, keys reach no pane until a click.
        if let view = returnFocus.view, let window = view.window {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }
}

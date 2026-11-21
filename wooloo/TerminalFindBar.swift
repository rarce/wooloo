import SwiftUI

/// Find in the selected terminal pane of a herdr-core connection: wooloo searches the screen
/// and scrollback it emulates, scrolls to the match and highlights it. Return goes to the
/// next older match and Shift-Return to the next newer one, as in other terminals; Escape
/// closes the bar and removes the highlight.
struct TerminalFindBar: View {
    /// Not observed: the bar reads none of the store's published state, and would redraw on each change.
    let store: HerdrStore
    /// Keep the field mounted so the shortcut can give it the next key event synchronously.
    let isPresented: Bool
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

    final class WeakView {
        weak var view: NSView?
        weak var field: NSTextField?
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
            PickerField(text: $query, placeholder: "Find in Terminal", font: .systemFont(ofSize: NSFont.systemFontSize),
                        onMove: { find(older: $0 < 0) },
                        onSubmit: { find(older: !Self.shiftHeld(NSApp.currentEvent)) }, onCancel: close,
                        prepareField: { field in
                            field.setAccessibilityIdentifier("terminal-find-field")
                            returnFocus.field = field
                        })
                .frame(width: 180)
                .onChange(of: query) { _, _ in find(older: true) }
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
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .onChange(of: paneID) { _, _ in
            if isPresented { find(older: true) }
        }
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
        query = ""
        result = nil
        searched = false
        onClose()
        // Return subsequent keystrokes to the terminal that opened Find.
        if let view = returnFocus.view, let window = view.window {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }
}

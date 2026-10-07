//
//  SourceActionsModifier.swift
//  MarkdownView
//
//  wooloo patch: lets the host edit or reveal the source from the rendered document.
//

import SwiftUI

/// Actions that map rendered elements back to their source lines (wooloo patch).
/// Lines are 1-based, in the text given to `MarkdownView`.
struct MarkdownSourceActions {
    /// Called when a task list checkbox is clicked, with the item's line and its new state.
    var toggleTask: (@MainActor (_ line: Int, _ checked: Bool) -> Void)?
    /// Called when a top-level block is double-clicked, with the block's first line.
    var revealLine: (@MainActor (_ line: Int) -> Void)?
}

struct MarkdownSourceActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue = MarkdownSourceActions()
}

extension EnvironmentValues {
    var markdownSourceActions: MarkdownSourceActions {
        get { self[MarkdownSourceActionsEnvironmentKey.self] }
        set { self[MarkdownSourceActionsEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Makes task list checkboxes clickable; nil keeps them read-only (wooloo patch).
    nonisolated public func markdownTaskToggle(
        _ action: (@MainActor (_ line: Int, _ checked: Bool) -> Void)?
    ) -> some View {
        transformEnvironment(\.markdownSourceActions) { $0.toggleTask = action }
    }

    /// Reports double-clicks on top-level blocks with the block's first source line (wooloo patch).
    nonisolated public func markdownRevealSource(_ action: (@MainActor (_ line: Int) -> Void)?) -> some View {
        transformEnvironment(\.markdownSourceActions) { $0.revealLine = action }
    }
}

/// Double-click on a top-level block reveals its source line (wooloo patch).
struct MarkdownRevealSourceGesture: ViewModifier {
    let line: Int?
    @Environment(\.markdownSourceActions.revealLine) private var revealLine

    func body(content: Content) -> some View {
        #if os(macOS)
        if let line, let revealLine {
            // Selectable text takes mouse events before SwiftUI gestures, so an AppKit monitor
            // watches double-clicks over the block and lets them through to select the word.
            content.background(DoubleClickMonitor { revealLine(line) })
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
private struct DoubleClickMonitor: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: (@MainActor () -> Void)?
        private var monitor: Any?

        /// Leaving the window, as before the view goes away, removes the monitor.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.clickCount == 2, event.window === self.window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
                    self.action?()
                }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

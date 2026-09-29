import SwiftUI

@main
struct XherdrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands { XherdrCommands() }
    }
}

struct XherdrCommandContext {
    let isConnected: Bool
    let hasSpace: Bool
    let tabCount: Int
    let hasPane: Bool
    let showsSidebar: Bool
    let showsFilesSidebar: Bool
    let perform: (String) -> Void
}

private struct XherdrCommandsKey: FocusedValueKey {
    typealias Value = XherdrCommandContext
}

extension FocusedValues {
    var xherdrCommands: XherdrCommandContext? {
        get { self[XherdrCommandsKey.self] }
        set { self[XherdrCommandsKey.self] = newValue }
    }
}

/// Menu bar commands; each item dispatches a shortcut action to the focused window.
private struct XherdrCommands: Commands {
    @FocusedValue(\.xherdrCommands) private var context

    private var connected: Bool { context?.isConnected == true }
    private var hasSpace: Bool { connected && context?.hasSpace == true }
    private var hasPane: Bool { connected && context?.hasPane == true }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            item("Herdr Settings…", "settings", enabled: context != nil)
                .keyboardShortcut(",", modifiers: .command)
            item("Reload Herdr Config", "reload_config", enabled: connected)
            item("Switch Session…", "switch_session", enabled: context != nil)
        }

        CommandGroup(after: .newItem) {
            item("New Space", "new_workspace", enabled: connected)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            item("New Tab", "new_tab", enabled: hasSpace)
                .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            item(context?.showsSidebar == false ? "Show Sidebar" : "Hide Sidebar",
                 "toggle_sidebar", enabled: context != nil)
                .keyboardShortcut("s", modifiers: [.command, .control])
            item(context?.showsFilesSidebar == false ? "Show Files and Changes" : "Hide Files and Changes",
                 "toggle_files_sidebar", enabled: context != nil)
                .keyboardShortcut("e", modifiers: [.command, .control])
            item("Refresh Files and Repository", "refresh_files", enabled: context != nil)
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }

        CommandMenu("Space") {
            item("Rename Space…", "rename_workspace", enabled: hasSpace)
            item("Close Space…", "close_workspace", enabled: hasSpace)
            Divider()
            item("Previous Tab", "previous_tab", enabled: hasSpace && (context?.tabCount ?? 0) > 1)
                .keyboardShortcut("[", modifiers: [.command, .shift])
            item("Next Tab", "next_tab", enabled: hasSpace && (context?.tabCount ?? 0) > 1)
                .keyboardShortcut("]", modifiers: [.command, .shift])
            item("Rename Tab…", "rename_tab", enabled: hasSpace && (context?.tabCount ?? 0) > 0)
            item("Close Tab…", "close_tab", enabled: hasSpace && (context?.tabCount ?? 0) > 1)
        }

        CommandMenu("Pane") {
            item("Split Right", "split_vertical", enabled: hasPane)
                .keyboardShortcut("d", modifiers: .command)
            item("Split Down", "split_horizontal", enabled: hasPane)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            item("Zoom Pane", "zoom", enabled: hasPane)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            item("Focus Pane Left", "focus_pane_left", enabled: hasPane)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            item("Focus Pane Right", "focus_pane_right", enabled: hasPane)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            item("Focus Pane Up", "focus_pane_up", enabled: hasPane)
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            item("Focus Pane Down", "focus_pane_down", enabled: hasPane)
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            item("Close Pane…", "close_pane", enabled: hasPane)
        }

        CommandGroup(before: .help) {
            item("Keyboard Shortcuts", "help", enabled: context != nil)
            Divider()
        }
    }

    private func item(_ title: String, _ action: String, enabled: Bool) -> some View {
        Button(title) { context?.perform(action) }
            .disabled(!enabled)
    }
}

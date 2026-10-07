import SwiftUI

@main
struct XherdrApp: App {
    @NSApplicationDelegateAdaptor(XherdrAppDelegate.self) private var appDelegate
    /// Unit tests run inside the app; they must not connect to a Herdr session.
    nonisolated static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Opens the metrics file at launch, so a run that never shows a surface still records its start.
        _ = TerminalPipelineMetrics.shared
        TerminalTypingProbe.start()
    }

    var body: some Scene {
        WindowGroup {
            if Self.isHostingTests {
                Text("Running tests")
            } else {
                ContentView()
            }
        }
        .commands { XherdrCommands() }
    }
}

struct XherdrCommandContext {
    let availability: XherdrCommandAvailability
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

/// Menu bar commands; each item dispatches a shortcut action to the focused window. Titles,
/// shortcuts and when they apply come from `XherdrCommandItem`, shared with the command palette.
private struct XherdrCommands: Commands {
    @FocusedValue(\.xherdrCommands) private var context

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Third-Party Notices") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            item("settings", title: "Herdr Settings…")
            item("reload_config", title: "Reload Herdr Config")
            item("switch_session")
            item("remote_access")
        }

        CommandGroup(after: .newItem) {
            item("new_workspace")
            item("new_tab")
            item("new_untitled_file")
        }

        // Command-P goes to a file, as in Zed and VS Code, rather than printing.
        CommandGroup(replacing: .printItem) {
            item("quick_open")
        }

        // Command-W closes the tab in the main panel rather than the window.
        CommandGroup(replacing: .saveItem) {
            item("close_current_tab")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Divider()
            item("project_search")
            item("project_replace")
        }

        CommandGroup(after: .sidebar) {
            item("command_palette")
            Divider()
            item("toggle_sidebar", title: context?.showsSidebar == false ? "Show Sidebar" : "Hide Sidebar")
            item("toggle_files_sidebar",
                 title: context?.showsFilesSidebar == false ? "Show Files and Changes" : "Hide Files and Changes")
            item("refresh_files")
            Divider()
        }

        CommandMenu("Space") {
            item("rename_workspace")
            item("close_workspace")
            Divider()
            item("previous_tab")
            item("next_tab")
            item("rename_tab")
            item("close_tab")
        }

        CommandMenu("Pane") {
            item("split_vertical")
            item("split_horizontal")
            item("zoom")
            Divider()
            item("focus_pane_left")
            item("focus_pane_right")
            item("focus_pane_up")
            item("focus_pane_down")
            Divider()
            item("close_pane")
        }

        CommandGroup(before: .help) {
            item("help")
            Divider()
        }
    }

    private func item(_ action: String, title: String? = nil) -> some View {
        let command = XherdrCommandItem.named(action)
        return Button(title ?? command?.title ?? action) { context?.perform(action) }
            .keyboardShortcut(command?.shortcut)
            .disabled(context.map { command?.isAvailable($0.availability) != true } ?? true)
    }
}

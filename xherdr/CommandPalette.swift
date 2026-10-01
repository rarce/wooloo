import AppKit
import SwiftUI

/// What the window offers commands for; decides which menu items and palette commands apply.
struct XherdrCommandAvailability: Equatable {
    var isConnected = false
    var hasSpace = false
    var tabCount = 0
    var hasPane = false
    /// The explorer shows a location, which Go to File and project search use.
    var hasFiles = false
}

/// An app command the menu bar and the command palette both offer, by its shortcut action.
struct XherdrCommandItem: Identifiable, Equatable {
    enum Requirement: Equatable {
        case window, connected, space, pane, files
        /// A Space with at least this many tabs.
        case tabs(Int)
    }

    let action: String
    let category: String
    let title: String
    let shortcut: KeyboardShortcut?
    let requirement: Requirement

    var id: String { action }
    /// How the palette lists it, for example "Pane: Split Right".
    var label: String { "\(category): \(title)" }

    init(_ action: String, _ category: String, _ title: String, _ shortcut: KeyboardShortcut? = nil,
         requires requirement: Requirement = .window) {
        self.action = action
        self.category = category
        self.title = title
        self.shortcut = shortcut
        self.requirement = requirement
    }

    func isAvailable(_ availability: XherdrCommandAvailability) -> Bool {
        switch requirement {
        case .window: return true
        case .connected: return availability.isConnected
        case .space: return availability.isConnected && availability.hasSpace
        case .pane: return availability.isConnected && availability.hasPane
        case .files: return availability.hasFiles
        case .tabs(let count): return availability.isConnected && availability.hasSpace && availability.tabCount >= count
        }
    }

    /// The menu shortcut in Mac notation, for example "⇧⌘F".
    var shortcutLabel: String? {
        guard let shortcut else { return nil }
        var label = ""
        if shortcut.modifiers.contains(.control) { label += "⌃" }
        if shortcut.modifiers.contains(.option) { label += "⌥" }
        if shortcut.modifiers.contains(.shift) { label += "⇧" }
        if shortcut.modifiers.contains(.command) { label += "⌘" }
        let names: [Character: String] = [
            KeyEquivalent.return.character: "↩", KeyEquivalent.leftArrow.character: "←",
            KeyEquivalent.rightArrow.character: "→", KeyEquivalent.upArrow.character: "↑",
            KeyEquivalent.downArrow.character: "↓", KeyEquivalent.escape.character: "⎋"
        ]
        let key = shortcut.key.character
        return label + (names[key] ?? String(key).uppercased())
    }

    static func named(_ action: String) -> Self? { all.first { $0.action == action } }

    /// Every command, in menu order.
    static let all: [Self] = [
        .init("settings", "Herdr", "Settings…", KeyboardShortcut(",", modifiers: .command)),
        .init("reload_config", "Herdr", "Reload Config", requires: .connected),
        .init("switch_session", "Herdr", "Switch Session…"),
        .init("help", "Help", "Keyboard Shortcuts"),
        .init("command_palette", "View", "Command Palette…", KeyboardShortcut("p", modifiers: [.command, .shift])),
        .init("quick_open", "File", "Go to File…", KeyboardShortcut("p", modifiers: .command), requires: .files),
        .init("new_workspace", "Space", "New Space", KeyboardShortcut("n", modifiers: [.command, .shift]),
              requires: .connected),
        .init("new_tab", "Space", "New Tab", KeyboardShortcut("t", modifiers: .command), requires: .space),
        .init("close_current_tab", "File", "Close Tab", KeyboardShortcut("w", modifiers: .command)),
        .init("project_search", "Edit", "Find in Project…", KeyboardShortcut("f", modifiers: [.command, .shift])),
        .init("project_replace", "Edit", "Replace in Project…", KeyboardShortcut("h", modifiers: [.command, .shift])),
        .init("toggle_sidebar", "View", "Toggle Sidebar", KeyboardShortcut("s", modifiers: [.command, .control])),
        .init("toggle_files_sidebar", "View", "Toggle Files and Changes",
              KeyboardShortcut("e", modifiers: [.command, .control])),
        .init("refresh_files", "View", "Refresh Files and Repository", KeyboardShortcut("r", modifiers: .command)),
        .init("rename_workspace", "Space", "Rename Space…", requires: .space),
        .init("close_workspace", "Space", "Close Space…", requires: .space),
        .init("previous_tab", "Space", "Previous Tab", KeyboardShortcut("[", modifiers: [.command, .shift]),
              requires: .tabs(2)),
        .init("next_tab", "Space", "Next Tab", KeyboardShortcut("]", modifiers: [.command, .shift]), requires: .tabs(2)),
        .init("rename_tab", "Space", "Rename Tab…", requires: .tabs(1)),
        .init("close_tab", "Space", "Close Tab…", requires: .tabs(2)),
        .init("split_vertical", "Pane", "Split Right", KeyboardShortcut("d", modifiers: .command), requires: .pane),
        .init("split_horizontal", "Pane", "Split Down", KeyboardShortcut("d", modifiers: [.command, .shift]),
              requires: .pane),
        .init("zoom", "Pane", "Zoom Pane", KeyboardShortcut(.return, modifiers: [.command, .shift]), requires: .pane),
        .init("focus_pane_left", "Pane", "Focus Pane Left", KeyboardShortcut(.leftArrow, modifiers: [.command, .option]),
              requires: .pane),
        .init("focus_pane_right", "Pane", "Focus Pane Right",
              KeyboardShortcut(.rightArrow, modifiers: [.command, .option]), requires: .pane),
        .init("focus_pane_up", "Pane", "Focus Pane Up", KeyboardShortcut(.upArrow, modifiers: [.command, .option]),
              requires: .pane),
        .init("focus_pane_down", "Pane", "Focus Pane Down", KeyboardShortcut(.downArrow, modifiers: [.command, .option]),
              requires: .pane),
        .init("close_pane", "Pane", "Close Pane…", requires: .pane),
        .init("copy_pane_cwd", "Pane", "Copy Working Directory", requires: .pane),
        .init("reveal_pane_cwd", "Pane", "Reveal Working Directory in Finder", requires: .pane)
    ]
}

struct CommandPaletteMatch: Equatable {
    let item: XherdrCommandItem
    /// UTF-8 offsets in `item.label` of the matched characters.
    let positions: [Int]
    let isRecent: Bool
    /// The Herdr key binding, when there is one.
    let binding: String?
}

/// The command palette (⇧⌘P): the commands that apply now, recently used first, filtered by the
/// same fuzzy matching as Go to File.
@MainActor
final class CommandPaletteModel: ObservableObject {
    static let recentKey = "CommandPaletteRecent"
    static let maximumRecent = 20

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var results: [CommandPaletteMatch] = []
    @Published var selection = 0

    private let defaults: UserDefaults
    private var items: [XherdrCommandItem] = []
    private var bindings: [String: String] = [:]
    private weak var previousResponder: NSResponder?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedMatch: CommandPaletteMatch? { results.indices.contains(selection) ? results[selection] : nil }

    /// Recently run actions, newest first.
    var recentActions: [String] { defaults.stringArray(forKey: Self.recentKey) ?? [] }

    /// Opens on `items`, the commands that apply now; `bindings` are their Herdr key bindings.
    func present(_ items: [XherdrCommandItem], bindings: [String: String]) {
        previousResponder = NSApp?.keyWindow?.firstResponder
        self.items = items.filter { $0.action != "command_palette" }
        self.bindings = bindings
        isPresented = true
        if query.isEmpty { refresh() } else { query = "" }
    }

    /// Closes, giving the keyboard back to what had it, where a command then runs.
    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        if let view = previousResponder as? NSView, let window = view.window {
            window.makeFirstResponder(view)
        }
        previousResponder = nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = ((selection + delta) % results.count + results.count) % results.count
    }

    func record(_ action: String) {
        let recent = [action] + recentActions.filter { $0 != action }
        defaults.set(Array(recent.prefix(Self.maximumRecent)), forKey: Self.recentKey)
    }

    /// Lists recent commands first, then the rest alphabetically; a query matches labels such as
    /// "Pane: Split Right".
    private func refresh() {
        let recent = recentActions.compactMap { action in items.first { $0.action == action } }
        let others = items.filter { !recent.contains($0) }.sorted { $0.label < $1.label }
        let ordered = recent + others
        let byLabel = Dictionary(ordered.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let query = QuickOpenQuery(self.query)
        let matches: [(XherdrCommandItem, [Int], Bool)]
        if query.terms.isEmpty {
            matches = ordered.map { ($0, [], recent.contains($0)) }
        } else {
            let found = QuickOpenMatcher.match(query, in: QuickOpenIndex(ordered.map(\.label)),
                                               recents: recent.map(\.label), limit: ordered.count) ?? []
            matches = found.compactMap { match in byLabel[match.path].map { ($0, match.positions, match.isRecent) } }
        }
        results = matches.map {
            CommandPaletteMatch(item: $0.0, positions: $0.1, isRecent: $0.2, binding: bindings[$0.0.action])
        }
        selection = 0
    }
}

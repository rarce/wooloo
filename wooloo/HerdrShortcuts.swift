import AppKit
import Foundation

struct HerdrShortcutDefinition: Identifiable {
    let key: String
    let title: String
    let defaultBindings: [String]
    var id: String { key }

    static let supported: [Self] = [
        .init(key: "help", title: "Shortcut help", defaultBindings: ["prefix+?"]),
        .init(key: "settings", title: "Settings", defaultBindings: ["prefix+s"]),
        .init(key: "new_workspace", title: "New Space", defaultBindings: ["prefix+shift+n"]),
        .init(key: "new_tab", title: "New Tab", defaultBindings: ["prefix+c"]),
        .init(key: "previous_tab", title: "Previous Tab", defaultBindings: ["prefix+p"]),
        .init(key: "next_tab", title: "Next Tab", defaultBindings: ["prefix+n"]),
        .init(key: "switch_tab", title: "Switch to Tab 1–9", defaultBindings: ["prefix+1..9"]),
        .init(key: "toggle_sidebar", title: "Toggle Sidebar", defaultBindings: ["prefix+b"]),
        .init(key: "focus_pane_left", title: "Focus Pane Left", defaultBindings: ["prefix+h"]),
        .init(key: "focus_pane_down", title: "Focus Pane Down", defaultBindings: ["prefix+j"]),
        .init(key: "focus_pane_up", title: "Focus Pane Up", defaultBindings: ["prefix+k"]),
        .init(key: "focus_pane_right", title: "Focus Pane Right", defaultBindings: ["prefix+l"]),
        .init(key: "split_vertical", title: "Split Right", defaultBindings: ["prefix+v"]),
        .init(key: "split_horizontal", title: "Split Down", defaultBindings: ["prefix+minus"]),
        .init(key: "zoom", title: "Zoom Pane", defaultBindings: ["prefix+z"]),
        .init(key: "reload_config", title: "Reload Herdr Config", defaultBindings: ["prefix+shift+r"])
    ]
}

/// What a shortcut or menu item asks wooloo to do, from Herdr's action names plus wooloo's own.
enum HerdrCommand: Equatable {
    case help, settings, reloadConfig, switchSession
    /// The Remote Access settings, which publish this Mac's SSH through a Cloudflare Tunnel.
    case remoteAccess
    /// Asks Sparkle for a newer wooloo release.
    case checkForUpdates
    case newWorkspace, renameWorkspace, closeWorkspace
    case newTab, renameTab, closeTab
    /// A new empty editor tab, "Untitled-N", saved later wherever the user chooses.
    case newUntitledFile
    /// The tab `delta` places away within the Space, wrapping around.
    case cycleTab(Int)
    /// The Space's tab at a 1-based position.
    case switchTab(Int)
    /// Closes whatever the main panel shows: search, a document, or else the terminal tab.
    case closeCurrentTab
    case focusPane(String), splitPane(String), zoom, closePane
    case toggleSidebar, toggleFilesSidebar, refreshFiles
    case projectSearch(replace: Bool)
    /// Go to File; while it is open, selects the next file.
    case quickOpen
    /// The command palette; while it is open, selects the next command.
    case commandPalette
    /// An action of the open file's editor, from the command palette.
    case editor(EditorCommand)
    /// A file command of the focused explorer tree, from the command palette.
    case explorer(ExplorerFileCommand)
    case copyPaneDirectory, revealPaneDirectory

    init?(action: String) {
        switch action {
        case "help": self = .help
        case "settings": self = .settings
        case "reload_config": self = .reloadConfig
        case "switch_session": self = .switchSession
        case "remote_access": self = .remoteAccess
        case "check_for_updates": self = .checkForUpdates
        case "new_workspace": self = .newWorkspace
        case "rename_workspace": self = .renameWorkspace
        case "close_workspace": self = .closeWorkspace
        case "new_tab": self = .newTab
        case "new_untitled_file": self = .newUntitledFile
        case "rename_tab": self = .renameTab
        case "close_tab": self = .closeTab
        case "previous_tab": self = .cycleTab(-1)
        case "next_tab": self = .cycleTab(1)
        case "close_current_tab": self = .closeCurrentTab
        case "focus_pane_left": self = .focusPane("left")
        case "focus_pane_down": self = .focusPane("down")
        case "focus_pane_up": self = .focusPane("up")
        case "focus_pane_right": self = .focusPane("right")
        case "split_vertical": self = .splitPane("right")
        case "split_horizontal": self = .splitPane("down")
        case "zoom": self = .zoom
        case "close_pane": self = .closePane
        case "toggle_sidebar": self = .toggleSidebar
        case "toggle_files_sidebar": self = .toggleFilesSidebar
        case "refresh_files": self = .refreshFiles
        case "project_search": self = .projectSearch(replace: false)
        case "project_replace": self = .projectSearch(replace: true)
        case "quick_open": self = .quickOpen
        case "command_palette": self = .commandPalette
        case "copy_pane_cwd": self = .copyPaneDirectory
        case "reveal_pane_cwd": self = .revealPaneDirectory
        default:
            if let command = EditorCommand(rawValue: action) {
                self = .editor(command)
                return
            }
            if let command = ExplorerFileCommand(paletteAction: action) {
                self = .explorer(command)
                return
            }
            guard action.hasPrefix("switch_tab_"), let number = Int(action.dropFirst("switch_tab_".count)),
                  number >= 1 else { return nil }
            self = .switchTab(number)
        }
    }

    /// The tab `delta` places from `current` in `tabs`, wrapping around; nil when `current`
    /// is not one of them.
    static func tab(_ delta: Int, from current: String?, in tabs: [String]) -> String? {
        guard let index = tabs.firstIndex(where: { $0 == current }) else { return nil }
        let count = tabs.count
        return tabs[((index + delta) % count + count) % count]
    }
}

private struct HerdrKeyChord: Hashable {
    let key: String
    let modifiers: Int

    init?(_ raw: String) {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var flags = 0
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": flags |= 1
            case "alt", "option", "meta": flags |= 2
            case "shift": flags |= 4
            case "cmd", "command", "super": flags |= 8
            default: return nil
            }
        }
        let aliases = ["minus": "-", "comma": ",", "period": ".", "slash": "/",
                       "backslash": "\\", "semicolon": ";", "quote": "'", "space": " ",
                       "backtick": "`", "plus": "+", "return": "enter", "escape": "esc"]
        let normalized = aliases[last] ?? last
        guard normalized.count == 1 || ["enter", "esc", "tab", "backspace", "delete", "left", "right",
                                           "up", "down", "home", "end", "pageup", "pagedown"].contains(normalized)
              || normalized.range(of: "^f([1-9]|1[0-9]|2[0-4])$", options: .regularExpression) != nil else { return nil }
        if last.count == 1, let first = raw.split(separator: "+").last?.first,
           first.isASCII && first.isUppercase { flags |= 4 }
        key = normalized
        modifiers = flags
    }

    init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }

    static func candidates(for event: NSEvent) -> [Self] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = (flags.contains(.control) ? 1 : 0)
            | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.shift) ? 4 : 0)
            | (flags.contains(.command) ? 8 : 0)
        let specials: [UInt16: String] = [
            36: "enter", 76: "enter", 48: "tab", 53: "esc", 51: "backspace", 117: "delete",
            123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end",
            116: "pageup", 121: "pagedown"
        ]
        if let special = specials[event.keyCode] {
            return [Self(key: special, modifiers: modifiers)]
        }
        guard var base = event.charactersIgnoringModifiers?.lowercased(), base.count == 1 else { return [] }
        if flags.contains(.control), let scalar = base.unicodeScalars.first?.value,
           scalar >= 1, scalar <= 26 {
            base = String(UnicodeScalar(scalar + 96)!)
        }
        var candidates = [Self(key: base, modifiers: modifiers)]
        if flags.contains(.shift), let shifted = event.characters?.lowercased(), shifted.count == 1,
           shifted != base, !shifted.first!.isLetter {
            candidates.append(Self(key: shifted, modifiers: modifiers & ~4))
        }
        return candidates
    }
}

struct HerdrShortcutMap {
    enum Match {
        case pass
        case prefix
        case action(String)
        case consumed
    }

    let prefixLabel: String
    let labels: [String: [String]]
    private let prefix: HerdrKeyChord
    private let direct: [HerdrKeyChord: String]
    private let prefixed: [HerdrKeyChord: String]

    init(document: HerdrConfigDocument) {
        let requestedPrefix = document.string(section: "keys", key: "prefix", default: "ctrl+b")
        prefixLabel = requestedPrefix
        prefix = HerdrKeyChord(requestedPrefix) ?? HerdrKeyChord("ctrl+b")!
        var direct: [HerdrKeyChord: String] = [:]
        var prefixed: [HerdrKeyChord: String] = [:]
        var labels: [String: [String]] = [:]
        for definition in HerdrShortcutDefinition.supported {
            let bindings = document.bindings(definition.key, default: definition.defaultBindings)
            labels[definition.key] = bindings
            for raw in bindings where !raw.isEmpty {
                let isPrefix = raw.lowercased().hasPrefix("prefix+")
                let body = isPrefix ? String(raw.dropFirst(7)) : raw
                let target = isPrefix ? "prefix" : "direct"
                if definition.key == "switch_tab", body.hasSuffix("1..9") {
                    let stem = String(body.dropLast(4))
                    for number in 1...9 {
                        guard let chord = HerdrKeyChord(stem + String(number)) else { continue }
                        if target == "prefix" { prefixed[chord] = "switch_tab_\(number)" }
                        else { direct[chord] = "switch_tab_\(number)" }
                    }
                } else if let chord = HerdrKeyChord(body) {
                    if target == "prefix" { prefixed[chord] = definition.key }
                    else { direct[chord] = definition.key }
                }
            }
        }
        self.labels = labels
        self.direct = direct
        self.prefixed = prefixed
    }

    static func load() -> Self {
        let content = (try? HerdrConfigFile.read(at: HerdrConfigFile.url)) ?? ""
        return Self(document: HerdrConfigDocument(text: content))
    }

    /// The first binding for an action in Mac notation, for example "⌃B V" for prefix+v.
    func displayLabel(for action: String) -> String? {
        guard let raw = labels[action]?.first(where: { !$0.isEmpty }) else { return nil }
        if raw.lowercased().hasPrefix("prefix+") {
            return Self.displayChord(prefixLabel) + " " + Self.displayChord(String(raw.dropFirst(7)))
        }
        return Self.displayChord(raw)
    }

    private static func displayChord(_ raw: String) -> String {
        var parts = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if raw.hasSuffix("++") { parts = parts.dropLast(2) + ["+"] }
        guard let key = parts.last, !key.isEmpty else { return raw }
        let modifiers = Set(parts.dropLast().map { $0.lowercased() })
        var symbols = ""
        if modifiers.contains("ctrl") || modifiers.contains("control") { symbols += "⌃" }
        if modifiers.contains("alt") || modifiers.contains("option") || modifiers.contains("meta") { symbols += "⌥" }
        if modifiers.contains("shift") || (key.count == 1 && key.first!.isUppercase) { symbols += "⇧" }
        if modifiers.contains("cmd") || modifiers.contains("command") || modifiers.contains("super") { symbols += "⌘" }
        let names = ["minus": "-", "plus": "+", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
                     "semicolon": ";", "quote": "'", "backtick": "`", "space": "Space", "enter": "↩",
                     "return": "↩", "esc": "⎋", "escape": "⎋", "tab": "⇥", "backspace": "⌫", "delete": "⌦",
                     "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
                     "pageup": "⇞", "pagedown": "⇟"]
        return symbols + (names[key.lowercased()] ?? key.uppercased())
    }

    func match(_ event: NSEvent, prefixPending: Bool) -> Match {
        let candidates = HerdrKeyChord.candidates(for: event)
        if prefixPending {
            if candidates.contains(where: { $0.key == "esc" }) { return .consumed }
            for chord in candidates {
                if let action = prefixed[chord] { return .action(action) }
            }
            return .consumed
        }
        if candidates.contains(prefix) { return .prefix }
        for chord in candidates {
            if let action = direct[chord] { return .action(action) }
        }
        return .pass
    }
}

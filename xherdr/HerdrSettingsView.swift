import AppKit
import SwiftUI

struct HerdrSettingsView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    let socketPath: String
    let sessionName: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .terminal
    @State private var document = HerdrConfigDocument(text: "")
    @State private var original = ""
    @State private var message: String?
    @State private var isSaving = false
    @State private var previewSound: NSSound?
    @AppStorage(HerdrNotifier.dockBadgeKey) private var showsDockBadge = true
    @AppStorage(HerdrNotifier.bounceDockKey) private var bouncesDock = true
    @AppStorage(XherdrTypography.baseKey) private var interfaceTextSize = XherdrTypography.defaultBase
    @AppStorage(XherdrTypography.codeKey) private var codeTextSize = XherdrTypography.defaultCode

    private enum Category: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case shortcuts = "Shortcuts"
        case worktrees = "Worktrees"
        case notifications = "Notifications"
        case appearance = "Appearance"
        case server = "Server"
        case advanced = "Advanced TOML"

        var id: Self { self }
        var icon: String {
            switch self {
            case .terminal: "terminal"
            case .shortcuts: "keyboard"
            case .worktrees: "point.topleft.down.curvedto.point.bottomright.up"
            case .notifications: "bell.badge"
            case .appearance: "paintpalette"
            case .server: "server.rack"
            case .advanced: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    init(socketPath: String, sessionName: String, showShortcuts: Bool = false,
         onSaved: @escaping () -> Void = {}) {
        self.socketPath = socketPath
        self.sessionName = sessionName
        self.onSaved = onSaved
        _category = State(initialValue: showShortcuts ? .shortcuts : .terminal)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HERDR SETTINGS")
                    .font(.system(size: typography.secondary, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ForEach(Category.allCases) { item in
                    Button {
                        category = item
                        message = nil
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: typography.emphasis))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(category == item ? Color.primary.opacity(0.09) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 170)
            .background(theme.sidebarBackground)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(category.rawValue)
                        .font(.system(size: typography.title, weight: .semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                Divider()

                Group {
                    if category == .advanced {
                        advancedEditor
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 19) {
                                Text(category == .notifications
                                     ? "xherdr settings apply to this app. Herdr settings live in the local config.toml, shared by all Herdr sessions; reload applies to \(sessionName)."
                                     : "Local config.toml · shared by all Herdr sessions. Reload applies to \(sessionName).")
                                    .font(.system(size: typography.body))
                                    .foregroundStyle(.secondary)
                                categoryFields
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                HStack(spacing: 10) {
                    if let message {
                        Text(message)
                            .font(.system(size: typography.body))
                            .foregroundStyle(message.hasPrefix("Saved") ? theme.success : theme.warning)
                            .lineLimit(2)
                    } else {
                        Text(document.text == original ? "No changes" : "Unsaved changes")
                            .font(.system(size: typography.body))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(document.text == original ? "Reload file" : "Discard & reload") { load() }
                        .disabled(isSaving)
                    Button("Save & reload Herdr") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || document.text == original)
                }
                .padding(.horizontal, 20)
                .frame(height: 54)
            }
        }
        .frame(width: 800, height: 540)
        .preferredColorScheme(theme.colorScheme)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var categoryFields: some View {
        switch category {
        case .terminal:
            description("Defaults for new panes. Existing shells keep running with their current settings.")
            field("Default shell", hint: "Executable name or path; blank uses $SHELL") {
                TextField("Use $SHELL", text: string("terminal", "default_shell", default: ""))
                    .textFieldStyle(.roundedBorder)
            }
            field("Shell startup", hint: "Auto starts login shells on macOS") {
                Picker("", selection: string("terminal", "shell_mode", default: "auto")) {
                    Text("Auto").tag("auto")
                    Text("Login").tag("login")
                    Text("Non-login").tag("non_login")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            field("New pane directory", hint: "Follow, home, current, or an explicit path") {
                TextField("follow", text: string("terminal", "new_cwd", default: "follow"))
                    .textFieldStyle(.roundedBorder)
            }
        case .shortcuts:
            description("Press the prefix, release it, then press the action key. These bindings follow Herdr's [keys] format and apply in the xherdr terminal. Separate alternatives with commas.")
            field("Prefix", hint: "Default: ctrl+b. One direct chord, such as ctrl+a.") {
                TextField("ctrl+b", text: string("keys", "prefix", default: "ctrl+b"))
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(HerdrShortcutDefinition.supported) { definition in
                field(definition.title, hint: "Default: \(definition.defaultBindings.joined(separator: ", "))") {
                    TextField(definition.defaultBindings.joined(separator: ", "),
                              text: shortcutBindings(definition))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .worktrees:
            description("Where Herdr creates Git worktree checkouts from the sidebar.")
            field("Worktree directory", hint: "A path such as ~/Projects/herdr-worktrees") {
                TextField("~/.herdr/worktrees", text: string("worktrees", "directory", default: "~/.herdr/worktrees"))
                    .textFieldStyle(.roundedBorder)
            }
        case .notifications:
            description("Alerts fire when an agent finishes (done) or needs input (request). Unread marks stay on agents, Spaces, and tabs until you open the pane.")
            settingsGroup("xherdr", subtitle: "This app only · applies immediately · not written to config.toml") {
                field("macOS permission", hint: "Needed for System delivery. Herdr does not use this permission.") {
                    NotificationPermissionView()
                }
                field("Dock", hint: "xherdr's Dock icon") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show unread count on the Dock icon", isOn: $showsDockBadge)
                        Toggle("Bounce the Dock icon when an agent needs input", isOn: $bouncesDock)
                    }
                }
            }
            groupHeader("Herdr", subtitle: "Saved to config.toml · shared with Herdr's terminal client · Save & reload to apply")
            description("Sounds play for agents outside the pane you are viewing, or when xherdr is in the background.")
            Toggle("Play sounds", isOn: bool("ui.sound", "enabled", default: true))
            field("Sound file", hint: "Optional mp3 for all alerts. Relative paths resolve from config.toml's folder. Blank uses the system sound.") {
                soundField("path", placeholder: "sounds/notification.mp3", kind: nil)
            }
            field("Done sound", hint: "Overrides only finished alerts") {
                soundField("done_path", placeholder: "sounds/done.mp3", kind: .done)
            }
            field("Request sound", hint: "Overrides only needs-input alerts") {
                soundField("request_path", placeholder: "sounds/request.mp3", kind: .request)
            }
            field("Per-agent sounds", hint: "Default follows Play sounds; droid is muted by default.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(HerdrNotificationSettings.knownAgents, id: \.self) { agent in
                        HStack(spacing: 6) {
                            Text(agent).font(.system(size: typography.body, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            Picker("", selection: agentSound(agent)) {
                                Text("Default").tag("default")
                                Text("On").tag("on")
                                Text("Off").tag("off")
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }
                    }
                }
            }
            Divider()
            field("Pop-up notifications", hint: "Herdr's [ui.toast] delivery. Unset, xherdr uses System (Herdr itself defaults to Off). xherdr has no outer terminal, so Terminal uses system notifications.") {
                Picker("", selection: string("ui.toast", "delivery",
                                             default: HerdrNotificationSettings.defaultDelivery.rawValue)) {
                    Text("Off").tag("off")
                    Text("In xherdr").tag("herdr")
                    Text("Terminal").tag("terminal")
                    Text("System").tag("system")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            field("Delay", hint: "Seconds to wait before showing a pop-up; alerts you handle meanwhile are skipped") {
                TextField("1", value: integer("ui.toast", "delay_seconds", default: 1), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            field("In-app position", hint: "Corner for In xherdr pop-ups") {
                Picker("", selection: string("ui.toast.herdr", "position", default: "bottom-right")) {
                    Text("Top left").tag("top-left")
                    Text("Top right").tag("top-right")
                    Text("Bottom left").tag("bottom-left")
                    Text("Bottom right").tag("bottom-right")
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case .appearance:
            settingsGroup("xherdr", subtitle: "This app only · applies immediately · not written to config.toml") {
                field("Interface text size", hint: "Sidebar, tabs, History, Files, and settings. Default: \(Int(XherdrTypography.defaultBase)) pt") {
                    textSizeControl($interfaceTextSize, range: XherdrTypography.baseRange,
                                    default: XherdrTypography.defaultBase)
                }
                field("Code text size", hint: "Editor, diffs, commit messages, and search results. Default: \(Int(XherdrTypography.defaultCode)) pt. The terminal keeps Herdr's cell size.") {
                    textSizeControl($codeTextSize, range: XherdrTypography.codeRange,
                                    default: XherdrTypography.defaultCode)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Update package-lock.json").font(.system(size: typography.body))
                    Text("a2679a6 · Jane Doe · 3 days ago")
                        .font(.system(size: typography.caption))
                        .foregroundStyle(.secondary)
                    Text("+  let total = items.count")
                        .font(.system(size: typography.code, design: .monospaced))
                        .foregroundStyle(theme.diffAdded)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6))
            }
            groupHeader("Herdr", subtitle: "Saved to config.toml · Save & reload to apply")
            ThemeSettingsView(name: string("theme", "name", default: XherdrTheme.fallbackID),
                              autoSwitch: bool("theme", "auto_switch", default: false),
                              lightName: optionalString("theme", "light_name"),
                              darkName: optionalString("theme", "dark_name"))
        case .server:
            description("Headless size applies when no client is attached. These values must be positive.")
            field("Headless columns", hint: "Default: 120") {
                TextField("120", value: integer("server", "headless_cols", default: 120), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            field("Headless rows", hint: "Default: 40") {
                TextField("40", value: integer("server", "headless_rows", default: 40), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        case .advanced:
            EmptyView()
        }
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full local config.toml. Other Herdr settings and comments stay here when guided fields change.")
                .font(.system(size: typography.body))
                .foregroundStyle(.secondary)
            Text(HerdrConfigFile.url.path)
                .font(.system(size: typography.secondary, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            TextEditor(text: $document.text)
                .font(.system(size: typography.emphasis, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(Color.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 5))
            Link("Herdr configuration reference", destination: URL(string: "https://herdr.dev/docs/config-reference/")!)
                .font(.system(size: typography.body))
        }
        .padding(20)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.system(size: typography.emphasis))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ title: String, hint: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: typography.emphasis, weight: .medium))
            content()
            Text(hint).font(.system(size: typography.secondary)).foregroundStyle(.tertiary)
        }
    }

    private func string(_ section: String, _ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { document.string(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.string(section: section, key: key, default: fallback) else { return }
                    document.setString($0, section: section, key: key)
                })
    }

    /// Empty removes the key, so Herdr falls back to its own default instead of an unknown value.
    private func optionalString(_ section: String, _ key: String) -> Binding<String> {
        Binding(get: { document.string(section: section, key: key, default: "") },
                set: {
                    guard $0 != document.string(section: section, key: key, default: "") else { return }
                    if $0.isEmpty { document.remove(section: section, key: key) }
                    else { document.setString($0, section: section, key: key) }
                })
    }

    private func bool(_ section: String, _ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { document.bool(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.bool(section: section, key: key, default: fallback) else { return }
                    document.setBool($0, section: section, key: key)
                })
    }

    private func integer(_ section: String, _ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { document.integer(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.integer(section: section, key: key, default: fallback) else { return }
                    document.setInteger($0, section: section, key: key)
                })
    }

    private func groupHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: typography.heading, weight: .semibold))
            Text(subtitle).font(.system(size: typography.secondary)).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// A boxed group for settings that belong to xherdr rather than Herdr's config.toml.
    private func settingsGroup<Content: View>(_ title: String, subtitle: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(title, subtitle: subtitle)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent.opacity(0.25)))
    }

    private func textSizeControl(_ value: Binding<Double>, range: ClosedRange<Double>,
                                 default fallback: Double) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: 1)
                .frame(width: 220)
            Text("\(Int(value.wrappedValue)) pt")
                .font(.system(size: typography.body, design: .monospaced))
                .frame(width: 44, alignment: .leading)
            Button("Default") { value.wrappedValue = fallback }
                .disabled(value.wrappedValue == fallback)
        }
    }

    private func soundField(_ key: String, placeholder: String, kind: HerdrAlertKind?) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: optionalString("ui.sound", key))
                .textFieldStyle(.roundedBorder)
            Button {
                playPreview(key: key, kind: kind ?? .done)
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Preview")
        }
    }

    private func playPreview(key: String, kind: HerdrAlertKind) {
        var settings = HerdrNotificationSettings()
        settings.soundPath = document.string(section: "ui.sound", key: "path", default: "")
        settings.donePath = key == "path" ? nil : document.string(section: "ui.sound", key: "done_path", default: "")
        settings.requestPath = key == "path" ? nil : document.string(section: "ui.sound", key: "request_path", default: "")
        previewSound?.stop()
        previewSound = settings.soundURL(for: kind).flatMap { NSSound(contentsOf: $0, byReference: true) }
            ?? NSSound(named: kind == .done ? "Glass" : "Ping")
        previewSound?.play()
    }

    /// "Default" removes the override so Herdr's own default applies.
    private func agentSound(_ agent: String) -> Binding<String> {
        Binding(get: { document.string(section: "ui.sound.agents", key: agent, default: "default") },
                set: {
                    guard $0 != document.string(section: "ui.sound.agents", key: agent, default: "default") else { return }
                    if $0 == "default" { document.remove(section: "ui.sound.agents", key: agent) }
                    else { document.setString($0, section: "ui.sound.agents", key: agent) }
                })
    }

    private func shortcutBindings(_ definition: HerdrShortcutDefinition) -> Binding<String> {
        Binding(get: {
            document.bindings(definition.key, default: definition.defaultBindings).joined(separator: ", ")
        }, set: { value in
            let current = document.bindings(definition.key, default: definition.defaultBindings)
                .joined(separator: ", ")
            guard value != current else { return }
            let values = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            document.setBindings(values, key: definition.key)
        })
    }

    private func load() {
        do {
            original = try HerdrConfigFile.read(at: HerdrConfigFile.url)
            document = HerdrConfigDocument(text: original)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() {
        let text = document.text
        let old = original
        let url = HerdrConfigFile.url
        let path = socketPath
        let session = sessionName
        isSaving = true
        message = "Validating with Herdr…"
        Task.detached(priority: .userInitiated) {
            do {
                try HerdrConfigFile.save(text, original: old, at: url)
                let result: String
                do {
                    result = try HerdrConfigFile.reloadServer(socketPath: path)
                } catch {
                    result = "Saved config.toml, but \(session) could not reload: \(error.localizedDescription)"
                }
                await MainActor.run {
                    original = text
                    message = result
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}

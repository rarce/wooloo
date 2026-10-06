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
    @StateObject private var model = HerdrSettingsModel()
    @AppStorage(HerdrNotifier.dockBadgeKey) private var showsDockBadge = true
    @AppStorage(HerdrNotifier.bounceDockKey) private var bouncesDock = true
    @AppStorage(XherdrTypography.baseKey) private var interfaceTextSize = XherdrTypography.defaultBase
    @AppStorage(XherdrTypography.codeKey) private var codeTextSize = XherdrTypography.defaultCode
    @AppStorage(MarkdownPreviewStyle.storageKey) private var markdownPreviewStyle = MarkdownPreviewStyle.theme

    private enum Category: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case shortcuts = "Shortcuts"
        case worktrees = "Worktrees"
        case notifications = "Notifications"
        case appearance = "Appearance"
        case server = "Server"
        case advanced = "Advanced TOML"

        var id: Self { self }
        var subtitle: String {
            switch self {
            case .terminal: "Shell and working directory for new panes"
            case .shortcuts: "Keyboard bindings for your terminal workflow"
            case .worktrees: "Choose where new Git checkouts live"
            case .notifications: "Sounds, alerts, and Dock activity"
            case .appearance: "Text sizes, previews, and color themes"
            case .server: "Terminal dimensions when no client is attached"
            case .advanced: "Edit the complete Herdr configuration"
            }
        }

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
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                Group {
                    if category == .advanced {
                        advancedEditor
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                categoryFields
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                        }
                        .id(category)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
            .background(theme.contentBackground)
        }
        .frame(width: 880, height: 620)
        .font(.system(size: typography.body))
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .onAppear(perform: model.load)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: typography.title))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preferences")
                        .font(.system(size: typography.heading, weight: .semibold))
                    Text("xherdr & Herdr")
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(theme.subtext)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            VStack(spacing: 5) {
                ForEach(Category.allCases) { item in
                    Button {
                        category = item
                        model.message = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: typography.body, weight: .medium))
                                .frame(width: 20)
                                .foregroundStyle(category == item ? theme.accent : theme.subtext)
                            Text(item.rawValue)
                                .font(.system(size: typography.body,
                                              weight: category == item ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(category == item ? theme.accent.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? [.isSelected] : [])
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Label("Herdr configuration", systemImage: "doc.text")
                    .font(.system(size: typography.secondary, weight: .medium))
                Text("Shared across local sessions.\nReload applies to \(sessionName).")
                    .font(.system(size: typography.caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme.subtext)
            .padding(10)
        }
        .padding(12)
        .frame(width: 196)
        .background(theme.sidebarBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.rawValue)
                    .font(.system(size: typography.title, weight: .semibold))
                Text(category.subtitle)
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Label(message, systemImage: model.isSaving ? "arrow.triangle.2.circlepath"
                      : model.messageIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(model.isSaving ? theme.subtext
                                     : model.messageIsSuccess ? theme.success : theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Label(model.hasChanges ? "Unsaved changes" : "Up to date",
                      systemImage: model.hasChanges ? "circle.fill" : "checkmark.circle")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(model.hasChanges ? theme.warning : theme.subtext)
                Spacer(minLength: 0)
                Button(model.hasChanges ? "Discard & reload" : "Reload file") { model.load() }
                    .disabled(model.isSaving)
                Button("Save & reload Herdr") {
                    model.save(socketPath: socketPath, session: sessionName, onSaved: onSaved)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSaving || !model.hasChanges)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.sidebarBackground)
    }

    @ViewBuilder
    private var categoryFields: some View {
        switch category {
        case .terminal:
            description("Defaults for new panes. Existing shells keep running with their current settings.")
            settingsGroup("New panes") {
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
                    .frame(width: 220, alignment: .leading)
                }
                field("New pane directory", hint: "Follow, home, current, or an explicit path") {
                    TextField("follow", text: string("terminal", "new_cwd", default: "follow"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .shortcuts:
            description("Press the prefix, release it, then press the action key. These bindings follow Herdr's [keys] format and apply in the xherdr terminal. Separate alternatives with commas.")
            settingsGroup("Key bindings") {
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
            }
        case .worktrees:
            description("Where Herdr creates Git worktree checkouts from the sidebar.")
            settingsGroup("Git worktrees") {
                field("Worktree directory", hint: "A path such as ~/Projects/herdr-worktrees") {
                    TextField("~/.herdr/worktrees", text: string("worktrees", "directory", default: "~/.herdr/worktrees"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .notifications:
            description("Alerts fire when an agent finishes (done) or needs input (request). Unread marks stay on agents, Spaces, and tabs until you open the pane.")
            settingsGroup("xherdr", subtitle: "This app only · applies immediately") {
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
            settingsGroup("Sounds", subtitle: "Herdr · Save & reload to apply") {
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
            }
            settingsGroup("Pop-up notifications", subtitle: "Herdr · Save & reload to apply") {
                field("Delivery", hint: "Herdr's [ui.toast] delivery. Unset, xherdr uses System (Herdr itself defaults to Off). xherdr has no outer terminal, so Terminal uses system notifications.") {
                    Picker("", selection: string("ui.toast", "delivery",
                                                 default: HerdrNotificationSettings.defaultDelivery.rawValue)) {
                        Text("Off").tag("off")
                        Text("In xherdr").tag("herdr")
                        Text("Terminal").tag("terminal")
                        Text("System").tag("system")
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
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
                    .frame(width: 220, alignment: .leading)
                }
            }
        case .appearance:
            settingsGroup("xherdr", subtitle: "This app only · applies immediately") {
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
                .background(theme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
                field("Markdown preview", hint: "Document shows a white page with GitHub's README typography whatever the theme. Also switchable from the preview's toolbar.") {
                    Picker("", selection: $markdownPreviewStyle) {
                        ForEach(MarkdownPreviewStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            settingsGroup("Color theme", subtitle: "Herdr & xherdr · Save & reload to apply") {
                ThemeSettingsView(name: string("theme", "name", default: XherdrTheme.fallbackID),
                                  autoSwitch: bool("theme", "auto_switch", default: false),
                                  lightName: optionalString("theme", "light_name"),
                                  darkName: optionalString("theme", "dark_name"))
            }
        case .server:
            description("Headless size applies when no client is attached. These values must be positive.")
            settingsGroup("Headless terminal") {
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
                .foregroundStyle(theme.subtext)
                .textSelection(.enabled)
            TextEditor(text: $model.document.text)
                .font(.system(size: typography.emphasis, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.text.opacity(0.1)))
            Link("Herdr configuration reference", destination: URL(string: "https://herdr.dev/docs/config-reference/")!)
                .font(.system(size: typography.body))
        }
        .padding(24)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.system(size: typography.body))
            .foregroundStyle(theme.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ title: String, hint: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: typography.body, weight: .medium))
            content()
            Text(hint)
                .font(.system(size: typography.secondary))
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func string(_ section: String, _ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { model.string(section, key, default: fallback) },
                set: { model.setString($0, section, key, default: fallback) })
    }

    private func optionalString(_ section: String, _ key: String) -> Binding<String> {
        Binding(get: { model.string(section, key, default: "") },
                set: { model.setOptionalString($0, section, key) })
    }

    private func bool(_ section: String, _ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { model.bool(section, key, default: fallback) },
                set: { model.setBool($0, section, key, default: fallback) })
    }

    private func integer(_ section: String, _ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { model.integer(section, key, default: fallback) },
                set: { model.setInteger($0, section, key, default: fallback) })
    }

    private func groupHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: typography.heading, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shared visual grouping for app preferences and Herdr configuration.
    private func settingsGroup<Content: View>(_ title: String, subtitle: String? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            groupHeader(title, subtitle: subtitle)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.text.opacity(0.1)))
    }

    private func textSizeControl(_ value: Binding<Double>, range: ClosedRange<Double>,
                                 default fallback: Double) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: 1)
                .frame(width: 220, alignment: .leading)
            Text("\(Int(value.wrappedValue)) pt")
                .font(.system(size: typography.body, design: .monospaced))
                .fixedSize()
                .frame(width: 60, alignment: .leading)
            Button("Default") { value.wrappedValue = fallback }
                .disabled(value.wrappedValue == fallback)
        }
    }

    private func soundField(_ key: String, placeholder: String, kind: HerdrAlertKind?) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: optionalString("ui.sound", key))
                .textFieldStyle(.roundedBorder)
            Button {
                model.playPreview(key: key, kind: kind ?? .done)
            } label: {
                Image(systemName: "play.fill")
            }
            .accessibilityLabel("Preview sound")
            .help("Preview")
        }
    }

    private func agentSound(_ agent: String) -> Binding<String> {
        Binding(get: { model.agentSound(agent) }, set: { model.setAgentSound($0, agent) })
    }

    private func shortcutBindings(_ definition: HerdrShortcutDefinition) -> Binding<String> {
        Binding(get: { model.shortcutBindings(definition) },
                set: { model.setShortcutBindings($0, definition) })
    }
}

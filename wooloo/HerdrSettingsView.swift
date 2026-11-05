import AppKit
import SwiftUI

struct HerdrSettingsView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    private var sessionName: String { hostModel.destination.session }
    private var machine: HerdrMachineProfile? { hostModel.destination.machine }
    private var remoteHost: String? { machine?.label }
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .terminal
    @StateObject private var localModel: HerdrSettingsModel
    @StateObject private var hostModel: HerdrSettingsModel
    private var model: HerdrSettingsModel { category.isLocal ? localModel : hostModel }
    private var hasUnsavedChanges: Bool { localModel.hasChanges || hostModel.hasChanges }
    private var isBusy: Bool { localModel.isBusy || hostModel.isBusy }
    @State private var confirmsDiscard = false
    @State private var pendingCategory: Category?
    @State private var closesAfterDiscard = false
    @ObservedObject private var remoteAccess = RemoteAccessModel.shared
    @State private var tunnelToken = ""
    @State private var authorizingMobile = false
    @AppStorage(HerdrNotifier.dockBadgeKey) private var showsDockBadge = true
    @AppStorage(HerdrNotifier.bounceDockKey) private var bouncesDock = true
    @AppStorage(WoolooTypography.baseKey) private var interfaceTextSize = WoolooTypography.defaultBase
    @AppStorage(WoolooTypography.codeKey) private var codeTextSize = WoolooTypography.defaultCode
    @AppStorage(HerdrShortcutMap.previousContextKey) private var previousContextShortcut = "prefix+backspace"
    @AppStorage("DimInactiveWindows") private var dimsInactiveWindows = true
    @AppStorage(MarkdownPreviewStyle.storageKey) private var markdownPreviewStyle = MarkdownPreviewStyle.theme

    enum Category: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case shortcuts = "Shortcuts"
        case worktrees = "Worktrees"
        case notifications = "Notifications"
        case appearance = "Appearance"
        case server = "Server"
        case remoteAccess = "Remote Access"
        case advanced = "Advanced TOML"

        var id: Self { self }
        var isLocal: Bool { [.shortcuts, .notifications, .appearance].contains(self) }
        var subtitle: String {
            switch self {
            case .terminal: "Shell and working directory for new panes"
            case .shortcuts: "Keyboard bindings for your terminal workflow"
            case .worktrees: "Choose where new Git checkouts live"
            case .notifications: "Sounds, alerts, and Dock activity"
            case .appearance: "Text sizes, previews, and color themes"
            case .server: "Terminal dimensions when no client is attached"
            case .remoteAccess: "Connect your phone and authorize its SSH public key"
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
            case .remoteAccess: "antenna.radiowaves.left.and.right"
            case .advanced: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    init(socketPath: String, sessionName: String, machine: HerdrMachineProfile? = nil, showShortcuts: Bool = false,
         showRemoteAccess: Bool = false, initialCategory: Category? = nil, onSaved: @escaping () -> Void = {}) {
        let local = HerdrSettingsModel(destination: HerdrSettingsDestination(
            socketPath: machine == nil ? socketPath : nil, session: sessionName))
        _localModel = StateObject(wrappedValue: local)
        _hostModel = StateObject(wrappedValue: machine == nil ? local : HerdrSettingsModel(
            destination: HerdrSettingsDestination(machine: machine, socketPath: socketPath, session: sessionName)))
        self.onSaved = onSaved
        _category = State(initialValue: initialCategory ?? (showShortcuts ? .shortcuts : showRemoteAccess ? .remoteAccess : .terminal))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .disabled(authorizingMobile || isBusy)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if category != .remoteAccess { scopeSummary }
                Group {
                    if category == .advanced {
                        advancedEditor
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                categoryFields
                                    .disabled(model.isSaving || (!category.isLocal && category != .remoteAccess && !model.canEditConfig))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                        }
                        .id(category)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Remote access is wooloo's own and applies immediately; it has nothing to save.
                if category != .remoteAccess {
                    Divider()
                    footer
                }
            }
            .background(theme.contentBackground)
        }
        .frame(width: 880, height: 620)
        .font(.system(size: typography.body))
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        // Like Done, which is disabled while the configuration is written.
        .allowsQuitWhileShown(!isBusy && !hasUnsavedChanges && !authorizingMobile)
        .interactiveDismissDisabled(isBusy || hasUnsavedChanges || authorizingMobile)
        .onAppear {
            localModel.load()
            loadHostIfNeeded()
        }
        .onChange(of: category) { _, _ in loadHostIfNeeded() }
        .alert("Discard unsaved configuration changes?", isPresented: $confirmsDiscard) {
            Button("Keep editing", role: .cancel) { pendingCategory = nil; closesAfterDiscard = false }
            Button("Discard changes", role: .destructive) {
                if localModel.hasChanges { localModel.load() }
                if hostModel !== localModel && hostModel.hasChanges { hostModel.load() }
                if closesAfterDiscard { dismiss() }
                else if let pendingCategory { category = pendingCategory }
                pendingCategory = nil
                closesAfterDiscard = false
            }
        } message: {
            Text("Your edits to \(model.configPath) have not been saved.")
        }
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
                    Text("wooloo & Herdr")
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(theme.subtext)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 5) {
                sidebarGroup("Wooloo · This Mac", items: [.appearance, .shortcuts, .notifications])
                sidebarGroup("Herdr · " + (remoteHost ?? "This Mac"), items: [.terminal, .worktrees, .server, .advanced])
                sidebarGroup("Connection", items: [.remoteAccess])
            }
            Spacer(minLength: 0)
            Text("The editing destination stays fixed until you close Preferences.")
                .font(.system(size: typography.caption))
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
        }
        .padding(12)
        .frame(width: 196)
        .background(theme.sidebarBackground)
    }

    private func loadHostIfNeeded() {
        if !category.isLocal && category != .remoteAccess && !hostModel.hasLoaded && !hostModel.isBusy {
            hostModel.load()
        }
    }

    private func selectCategory(_ item: Category) {
        if item.isLocal != category.isLocal && model.hasChanges {
            pendingCategory = item
            confirmsDiscard = true
        } else { category = item }
    }

    private func sidebarGroup(_ title: String, items: [Category]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: typography.caption, weight: .semibold))
                .foregroundStyle(theme.subtext)
                .lineLimit(2)
                .padding(.top, 8)
                .padding(.horizontal, 8)
            ForEach(items) { item in
                Button { selectCategory(item) } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: typography.body, weight: category == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(category == item ? theme.accent.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("preferences-" + item.rawValue)
                .accessibilityAddTraits(category == item ? [.isSelected] : [])
            }
        }
    }

    private var scopeSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if category.isLocal {
                Text("Wooloo · This Mac · All windows and connections")
                    .fontWeight(.semibold)
                Text("TOML preferences also share this Mac’s Herdr configuration. Other Herdr clients apply them on reload.")
            } else {
                Text("Herdr · \(remoteHost ?? "This Mac") · Session: \(sessionName)")
                    .fontWeight(.semibold)
                if let machine {
                    Text(model.remoteConfig.map { "\($0.user)@\($0.host) · SSH: \(machine.target)" } ?? "SSH: \(machine.target)")
                }
                Text("Shared by sessions in this account using this file. Only \(sessionName) receives a reload request.")
                if machine != nil {
                    Text("SSH discovers the file path; Herdr’s API cannot verify that this session uses it.")
                        .foregroundStyle(theme.warning)
                }
            }
            Text(model.configPath.isEmpty ? "Loading configuration path…" : model.configPath)
                .font(.system(size: typography.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .font(.system(size: typography.caption))
        .foregroundStyle(theme.subtext)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(theme.sidebarBackground.opacity(0.5))
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
            Button("Done") {
                if hasUnsavedChanges { closesAfterDiscard = true; confirmsDiscard = true }
                else { dismiss() }
            }
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy || authorizingMobile)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Label(message, systemImage: model.isBusy ? "arrow.triangle.2.circlepath"
                      : model.messageIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(model.isBusy ? theme.subtext
                                     : model.messageIsSuccess ? theme.success : theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if model.hasChanges && !model.canEditConfig && !model.isBusy {
                Button("Copy unsaved edits") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.document.text, forType: .string)
                }
            }
            HStack(spacing: 10) {
                Label(model.isLoading ? "Loading…" : !model.hasLoaded ? "Configuration unavailable"
                      : model.hasChanges ? "Unsaved changes" : "Up to date",
                      systemImage: !model.hasLoaded || model.hasChanges ? "circle.fill" : "checkmark.circle")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(model.hasChanges ? theme.warning : theme.subtext)
                Spacer(minLength: 0)
                Button(model.hasChanges ? "Discard & reload" : "Reload file") { model.load() }
                    .disabled(model.isBusy)
                if !category.isLocal && model.canRetryReload {
                    Button("Retry session reload") { model.retryReload() }
                }
                Button(category.isLocal ? "Save on this Mac" : "Save & reload") {
                    model.save(reload: !category.isLocal, onSaved: onSaved)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canEditConfig || !model.hasChanges)
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
            description("Press the prefix, release it, then press the action key. These bindings follow Herdr's [keys] format and apply in the wooloo terminal. Separate alternatives with commas. Wooloo defaults to ⌃⌘B to leave agent Control shortcuts available. Press a non-Command prefix twice to send it to the terminal.")
            settingsGroup("Key bindings") {
                field("Prefix", hint: "Wooloo default: cmd+ctrl+b. Explicit Herdr prefixes are preserved.") {
                    TextField(HerdrShortcutMap.defaultPrefix,
                              text: string("keys", "prefix", default: HerdrShortcutMap.defaultPrefix))
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
            .disabled(!model.canEditConfig)
            settingsGroup("wooloo", subtitle: "This app only · applies immediately") {
                field("Back to Previous Context", hint: "Default: prefix+backspace. Separate alternatives with commas.") {
                    TextField("prefix+backspace", text: $previousContextShortcut).textFieldStyle(.roundedBorder)
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
            settingsGroup("wooloo", subtitle: "This app only · applies immediately") {
                field("macOS permission", hint: "Needed for System delivery. Herdr does not use this permission.") {
                    NotificationPermissionView()
                }
                field("Dock", hint: "wooloo's Dock icon") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show unread count on the Dock icon", isOn: $showsDockBadge)
                        Toggle("Bounce the Dock icon when an agent needs input", isOn: $bouncesDock)
                    }
                }
            }
            settingsGroup("Sounds", subtitle: "This Mac · shared with local Herdr · Save to apply in wooloo") {
                description("Sounds play for agents outside the pane you are viewing, or when wooloo is in the background.")
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
            .disabled(!model.canEditConfig)
            settingsGroup("Pop-up notifications", subtitle: "This Mac · shared with local Herdr · Save to apply in wooloo") {
                field("Delivery", hint: "Herdr's [ui.toast] delivery. Unset, wooloo uses System (Herdr itself defaults to Off). wooloo has no outer terminal, so Terminal uses system notifications.") {
                    Picker("", selection: string("ui.toast", "delivery",
                                                 default: HerdrNotificationSettings.defaultDelivery.rawValue)) {
                        Text("Off").tag("off")
                        Text("In wooloo").tag("herdr")
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
                field("In-app position", hint: "Corner for In wooloo pop-ups") {
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
            .disabled(!model.canEditConfig)
        case .appearance:
            settingsGroup("wooloo", subtitle: "This app only · applies immediately") {
                field("Window focus", hint: "Reduce the brightness of inactive windows when another window or app has focus.") {
                    Toggle("Dim inactive windows", isOn: $dimsInactiveWindows)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("dim-inactive-windows")
                }
                field("Interface text size", hint: "Sidebar, tabs, History, Files, and settings. Default: \(Int(WoolooTypography.defaultBase)) pt") {
                    textSizeControl($interfaceTextSize, range: WoolooTypography.baseRange,
                                    default: WoolooTypography.defaultBase)
                }
                field("Code text size", hint: "Editor, diffs, commit messages, and search results. Default: \(Int(WoolooTypography.defaultCode)) pt. The terminal keeps Herdr's cell size.") {
                    textSizeControl($codeTextSize, range: WoolooTypography.codeRange,
                                    default: WoolooTypography.defaultCode)
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
            settingsGroup("Color theme", subtitle: "This Mac · shared with local Herdr · Save to apply in wooloo") {
                ThemeSettingsView(name: string("theme", "name", default: WoolooTheme.fallbackID),
                                  autoSwitch: bool("theme", "auto_switch", default: false),
                                  lightName: optionalString("theme", "light_name"),
                                  darkName: optionalString("theme", "dark_name"))
            }
            .disabled(!model.canEditConfig)
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
        case .remoteAccess:
            remoteAccessFields
        case .advanced:
            EmptyView()
        }
    }

    @ViewBuilder
    private var remoteAccessFields: some View {
        if machine == nil { localTunnelFields }
        MobileSSHAccessView(machine: machine, session: sessionName, tunnelHostname: remoteAccess.runningHostname,
                            authorizing: $authorizingMobile)
            .id("\(machine?.id ?? "local")|\(sessionName)")
        if machine != nil && remoteAccess.isActive {
            HStack {
                description("This Mac also has a local tunnel active, separate from the selected remote server.")
                Button("Stop Local Tunnel") { remoteAccess.stop() }
            }
        }
    }

    @ViewBuilder
    private var localTunnelFields: some View {
        description("Publishes this Mac's SSH server (Remote Login, localhost:22) through a Cloudflare Tunnel. Anyone who reaches the tunnel's address can try to sign in to any account allowed to use SSH, not only Herdr. No port opens on your network, and clients still sign in with SSH, then run Herdr's own commands.")
        description("Before starting, wooloo asks sshd which sign-in methods it offers and starts at once only when that is keys alone. It does not change sshd's sign-in methods, firewall or sharing settings. Turn passwords off yourself, as the README explains.")
        if remoteAccess.cloudflaredPath == nil {
            warning("cloudflared is not installed. Install it with `brew install cloudflared`, then come back here.")
        }
        if remoteAccess.acceptsSSH == false {
            HStack(spacing: 10) {
                warning("Remote Login is off, so the tunnel has no SSH server to reach. Turn it on in System Settings → General → Sharing.")
                Button("Open Sharing") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                }
            }
        }
        if remoteAccess.acceptsSSH == true, let check = remoteAccess.sshCheck {
            if check.isVerifiedKeysOnly {
                Label(check.summary, systemImage: "checkmark.shield")
                    .font(.system(size: typography.body))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                warning(check.summary)
            }
        }
        settingsGroup("Tunnel", subtitle: "wooloo only · applies immediately · stops when wooloo quits") {
            RemoteAccessStatusView(model: remoteAccess)
            field("Type", hint: remoteAccess.mode == .quick
                  ? "No Cloudflare account needed. The address changes every time the tunnel starts, so scan the new QR code each time. Anyone who learns it can reach your SSH login: use key authentication."
                  : "A tunnel you created in Cloudflare, with a hostname of your own that stays the same. Protect it with Cloudflare Access to stop others from reaching your SSH login; wooloo cannot check whether Access is set up.") {
                Picker("", selection: $remoteAccess.mode) {
                    ForEach(RemoteAccessMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(remoteAccess.isActive)
            }
            if remoteAccess.mode == .named {
                field("Public hostname", hint: "The hostname you added to the tunnel, with ssh://localhost:22 as its service") {
                    TextField("ssh.example.com", text: $remoteAccess.hostname)
                        .textFieldStyle(.roundedBorder)
                        .disabled(remoteAccess.isActive)
                }
                field("Tunnel token", hint: (remoteAccess.hasToken
                      ? "Saved in this Mac's Keychain. Paste a new one to replace it."
                      : "From Cloudflare Zero Trust → Networks → Tunnels: the token in the tunnel's install command. Saved in this Mac's Keychain.")
                      + " wooloo is signed ad hoc for now, so after an update macOS may ask again to let it read the token.") {
                    HStack(spacing: 6) {
                        SecureField(remoteAccess.hasToken ? "Saved" : "eyJ…", text: $tunnelToken)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            remoteAccess.setToken(tunnelToken)
                            tunnelToken = ""
                        }
                        .disabled(tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if remoteAccess.hasToken {
                            Button("Remove") { remoteAccess.setToken("") }
                        }
                    }
                    .disabled(remoteAccess.isActive)
                }
            }
            field("At launch", hint: "Starts only if the check finds key-only SSH, since nobody is there to confirm anything else."
                  + (remoteAccess.mode == .named
                     ? " After a wooloo update, macOS may first ask for Keychain access to the token; until someone answers, an unattended Mac keeps the tunnel down."
                     : "")) {
                Toggle("Start the tunnel when wooloo opens", isOn: $remoteAccess.startsAtLaunch)
            }
        }
        .onAppear { remoteAccess.checkSSH() }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: typography.body))
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Herdr config.toml for this destination. Guided fields preserve other settings and comments.")
                .font(.system(size: typography.body))
                .foregroundStyle(.secondary)
            Text(model.configPath.isEmpty ? "Loading configuration path…" : model.configPath)
                .font(.system(size: typography.secondary, design: .monospaced))
                .foregroundStyle(theme.subtext)
                .textSelection(.enabled)
            TextEditor(text: configText)
                .font(.system(size: typography.emphasis, design: .monospaced))
                .disabled(!model.canEditConfig)
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

    private var configText: Binding<String> {
        let model = model
        return Binding(get: { model.document.text }, set: { if model.canEditConfig { model.document.text = $0 } })
    }

    private func string(_ section: String, _ key: String, default fallback: String) -> Binding<String> {
        let model = model
        return Binding(get: { model.string(section, key, default: fallback) },
                set: { if model.canEditConfig { model.setString($0, section, key, default: fallback) } })
    }

    private func optionalString(_ section: String, _ key: String) -> Binding<String> {
        let model = model
        return Binding(get: { model.string(section, key, default: "") },
                set: { if model.canEditConfig { model.setOptionalString($0, section, key) } })
    }

    private func bool(_ section: String, _ key: String, default fallback: Bool) -> Binding<Bool> {
        let model = model
        return Binding(get: { model.bool(section, key, default: fallback) },
                set: { if model.canEditConfig { model.setBool($0, section, key, default: fallback) } })
    }

    private func integer(_ section: String, _ key: String, default fallback: Int) -> Binding<Int> {
        let model = model
        return Binding(get: { model.integer(section, key, default: fallback) },
                set: { if model.canEditConfig { model.setInteger($0, section, key, default: fallback) } })
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
        let model = model
        return Binding(get: { model.agentSound(agent) }, set: { if model.canEditConfig { model.setAgentSound($0, agent) } })
    }

    private func shortcutBindings(_ definition: HerdrShortcutDefinition) -> Binding<String> {
        let model = model
        return Binding(get: { model.shortcutBindings(definition) },
                set: { if model.canEditConfig { model.setShortcutBindings($0, definition) } })
    }
}

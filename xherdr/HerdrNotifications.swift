import AppKit
import SwiftUI
import UserNotifications

/// The two alerts Herdr defines: an agent finished, or an agent needs input.
enum HerdrAlertKind: String {
    case done
    case request

    var icon: String { self == .done ? "checkmark.circle.fill" : "bell.badge.fill" }
    var label: String { self == .done ? "Done" : "Needs input" }
}

struct HerdrToast: Identifiable, Equatable {
    let id = UUID()
    let kind: HerdrAlertKind
    let paneID: String
    let title: String
    let body: String
}

/// Herdr's `[ui.sound]` and `[ui.toast]` settings from config.toml.
struct HerdrNotificationSettings {
    enum Delivery: String, CaseIterable {
        case off, herdr, terminal, system
    }

    var soundEnabled = true
    var soundPath: String?
    var donePath: String?
    var requestPath: String?
    /// Per-agent override: "default", "on", or "off".
    var agentSounds: [String: String] = [:]
    /// Herdr defaults to off; xherdr shows system notifications unless config.toml says otherwise.
    static let defaultDelivery = Delivery.system
    var delivery = defaultDelivery
    var delaySeconds = 1
    var toastPosition = "bottom-right"

    /// Agents Herdr detects, for per-agent sound overrides.
    static let knownAgents = ["claude", "codex", "gemini", "cursor", "copilot", "opencode", "amp", "cline",
                              "devin", "droid", "grok", "hermes", "kilo", "kimi", "kiro", "letta", "maki",
                              "pi", "qodercli", "qwen"]
    /// Herdr mutes these unless configured otherwise.
    static let mutedByDefault: Set<String> = ["droid"]

    static func load() -> HerdrNotificationSettings {
        let document = HerdrConfigDocument(text: (try? HerdrConfigFile.read(at: HerdrConfigFile.url)) ?? "")
        var settings = HerdrNotificationSettings()
        settings.soundEnabled = document.bool(section: "ui.sound", key: "enabled", default: true)
        settings.soundPath = document.string(section: "ui.sound", key: "path", default: "")
        settings.donePath = document.string(section: "ui.sound", key: "done_path", default: "")
        settings.requestPath = document.string(section: "ui.sound", key: "request_path", default: "")
        for agent in knownAgents {
            let value = document.string(section: "ui.sound.agents", key: agent, default: "default")
            if value != "default" { settings.agentSounds[agent] = value }
        }
        settings.delivery = Delivery(rawValue: document.string(section: "ui.toast", key: "delivery",
                                                                default: defaultDelivery.rawValue)) ?? defaultDelivery
        settings.delaySeconds = max(0, document.integer(section: "ui.toast", key: "delay_seconds", default: 1))
        settings.toastPosition = document.string(section: "ui.toast.herdr", key: "position", default: "bottom-right")
        return settings
    }

    func playsSound(for agent: String?) -> Bool {
        guard ProcessInfo.processInfo.environment["HERDR_DISABLE_SOUND"] == nil else { return false }
        let name = agent?.lowercased() ?? ""
        switch agentSounds[name] {
        case "on": return true
        case "off": return false
        default: return soundEnabled && !Self.mutedByDefault.contains(name)
        }
    }

    func soundURL(for kind: HerdrAlertKind) -> URL? {
        let specific = kind == .done ? donePath : requestPath
        guard let path = [specific, soundPath].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return HerdrConfigFile.url.deletingLastPathComponent().appendingPathComponent(expanded)
    }
}

/// Watches agent status changes, plays Herdr's alert sounds, shows toasts, and keeps
/// unread attention marks until the user looks at the pane.
@MainActor
final class HerdrNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Unacknowledged alerts by pane.
    @Published private(set) var attention: [String: HerdrAlertKind] = [:]
    @Published private(set) var toasts: [HerdrToast] = []
    @Published private(set) var settings = HerdrNotificationSettings.load()

    /// xherdr-only preferences, stored in UserDefaults rather than config.toml.
    static let dockBadgeKey = "NotificationDockBadge"
    static let bounceDockKey = "NotificationBounceDock"
    private var showsDockBadge: Bool { UserDefaults.standard.object(forKey: Self.dockBadgeKey) as? Bool ?? true }
    private var bouncesDock: Bool { UserDefaults.standard.object(forKey: Self.bounceDockKey) as? Bool ?? true }

    /// Focuses a pane when a toast or system notification is clicked.
    var onOpenPane: (String) -> Void = { _ in }

    /// System notifications and sounds; tests replace them.
    var notificationStatus: () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    var addNotification: (UNNotificationRequest) async throws -> Void = {
        try await UNUserNotificationCenter.current().add($0)
    }
    var play: (NSSound) -> Void = { sound in
        sound.stop()
        sound.play()
    }
    var requestAuthorization: () -> Void = {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    /// Whether xherdr is the frontmost app; tests replace it.
    var isAppActive: () -> Bool = { NSApp.isActive }

    private var statuses: [String: String] = [:]
    private var hasBaseline = false
    private var sounds: [String: NSSound] = [:]

    override init() {
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        // The Dock badge toggle lives in UserDefaults; apply it as soon as it changes.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockBadge() }
        }
    }

    func reloadSettings() {
        settings = HerdrNotificationSettings.load()
        sounds = [:]
        if settings.delivery == .system || settings.delivery == .terminal { requestAuthorization() }
    }

    /// Clears everything, e.g. when switching sessions.
    func reset() {
        statuses = [:]
        hasBaseline = false
        attention = [:]
        toasts = []
        updateDockBadge()
    }

    /// Compares agent statuses with the previous snapshot and raises alerts on transitions.
    func process(_ snapshot: HerdrSnapshot?, selectedPaneID: String?) {
        guard let snapshot else { reset(); return }
        var next: [String: String] = [:]
        for agent in snapshot.agents { next[agent.paneID] = agent.agentStatus ?? "unknown" }
        defer {
            statuses = next
            hasBaseline = true
            // Drop marks for panes that closed or went back to work.
            let stale = attention.keys.filter { pane in
                guard let status = next[pane] else { return true }
                return status == "working" || (attention[pane] == .request && status != "blocked")
            }
            if !stale.isEmpty {
                for pane in stale { attention[pane] = nil }
                updateDockBadge()
            }
        }
        guard hasBaseline else { return }
        for agent in snapshot.agents {
            let status = next[agent.paneID] ?? "unknown"
            guard let previous = statuses[agent.paneID], previous != status else { continue }
            let kind: HerdrAlertKind
            switch status {
            case "blocked": kind = .request
            case "done": kind = .done
            // Herdr reports idle instead of done when a client was watching the pane.
            case "idle" where previous == "working": kind = .done
            default: continue
            }
            raise(kind, agent: agent, snapshot: snapshot, selectedPaneID: selectedPaneID)
        }
    }

    /// The user is looking at this pane, so its alert has been seen.
    func acknowledge(paneID: String?) {
        guard let paneID, isAppActive(), attention[paneID] != nil else { return }
        attention[paneID] = nil
        updateDockBadge()
    }

    func dismiss(_ toast: HerdrToast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func open(_ toast: HerdrToast) {
        dismiss(toast)
        onOpenPane(toast.paneID)
    }

    func attentionCount(inWorkspace workspaceID: String, snapshot: HerdrSnapshot?) -> (requests: Int, done: Int) {
        let panes = Set(snapshot?.panes.filter { $0.workspaceID == workspaceID }.map(\.paneID) ?? [])
        return count(attention.filter { panes.contains($0.key) })
    }

    func attentionCount(inTab tabID: String, snapshot: HerdrSnapshot?) -> (requests: Int, done: Int) {
        let panes = Set(snapshot?.panes.filter { $0.tabID == tabID }.map(\.paneID) ?? [])
        return count(attention.filter { panes.contains($0.key) })
    }

    private func count(_ marks: [String: HerdrAlertKind]) -> (requests: Int, done: Int) {
        (marks.values.filter { $0 == .request }.count, marks.values.filter { $0 == .done }.count)
    }

    private func raise(_ kind: HerdrAlertKind, agent: HerdrAgent, snapshot: HerdrSnapshot,
                       selectedPaneID: String?) {
        // Herdr's terminal UI shows one workspace at a time, so it sounds only for background
        // workspaces. xherdr shows one pane, so any pane out of view counts as background.
        let isWatched = isAppActive() && agent.paneID == selectedPaneID
        if !isWatched {
            attention[agent.paneID] = kind
            updateDockBadge()
            if settings.playsSound(for: agent.agent) { playSound(kind) }
        }
        if kind == .request, !isAppActive(), bouncesDock {
            NSApp.requestUserAttention(.informationalRequest)
        }
        guard !isWatched, settings.delivery != .off else { return }

        let workspace = snapshot.workspaces.first { $0.workspaceID == agent.workspaceID }?.label
        let tab = snapshot.tabs.first { $0.tabID == agent.tabID }?.label
        let toast = HerdrToast(kind: kind, paneID: agent.paneID,
                               title: kind == .done ? "\(agent.displayName) finished" : "\(agent.displayName) needs input",
                               body: [workspace, tab.map { "Tab \($0)" }].compactMap { $0 }.joined(separator: " · "))
        let delay = settings.delaySeconds
        let paneID = agent.paneID
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            // Skip alerts the user already handled during the delay.
            guard attention[paneID] == kind || !self.isAppActive() else { return }
            deliver(toast)
        }
    }

    private func deliver(_ toast: HerdrToast) {
        switch settings.delivery {
        case .off: return
        case .herdr: showToast(toast)
        case .system, .terminal:
            // xherdr has no outer terminal, so terminal delivery goes to the OS as well.
            guard Bundle.main.bundleIdentifier != nil else { showToast(toast); return }
            let content = UNMutableNotificationContent()
            content.title = toast.title
            content.body = toast.body
            content.userInfo = ["paneID": toast.paneID]
            let request = UNNotificationRequest(identifier: toast.id.uuidString, content: content, trigger: nil)
            Task {
                // Without permission macOS drops the alert silently, so show it in the app instead.
                let status = await notificationStatus()
                guard status == .authorized || status == .provisional else { showToast(toast); return }
                do { try await addNotification(request) } catch { showToast(toast) }
            }
        }
    }

    private func showToast(_ toast: HerdrToast) {
        toasts.removeAll { $0.paneID == toast.paneID }
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            dismiss(toast)
        }
    }

    private func playSound(_ kind: HerdrAlertKind) {
        let key = kind.rawValue
        if sounds[key] == nil {
            sounds[key] = settings.soundURL(for: kind).flatMap { NSSound(contentsOf: $0, byReference: true) }
                ?? NSSound(named: kind == .done ? "Glass" : "Ping")
        }
        guard let sound = sounds[key] else { return }
        play(sound)
    }

    private func updateDockBadge() {
        let count = attention.count
        NSApp.dockTile.badgeLabel = showsDockBadge && count > 0 ? String(count) : nil
    }

    func refreshDockBadge() { updateDockBadge() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        openNotification(userInfo: response.notification.request.content.userInfo,
                         completionHandler: completionHandler)
    }

    /// Opens the pane named in a clicked notification's userInfo, then reports back to macOS.
    nonisolated func openNotification(userInfo: [AnyHashable: Any],
                                      completionHandler: @escaping () -> Void) {
        let paneID = userInfo["paneID"] as? String
        Task { @MainActor in
            self.openNotification(paneID: paneID)
            completionHandler()
        }
    }

    /// Brings xherdr forward on the pane a clicked system notification is about.
    func openNotification(paneID: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let paneID { onOpenPane(paneID) }
    }
}

/// In-app toasts for `delivery = "herdr"`, stacked in Herdr's configured corner.
struct HerdrToastStack: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @ObservedObject var notifier: HerdrNotifier

    private var alignment: Alignment {
        switch notifier.settings.toastPosition {
        case "top-left": return .topLeading
        case "top-right": return .topTrailing
        case "bottom-left": return .bottomLeading
        default: return .bottomTrailing
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(notifier.toasts) { toast in
                Button { notifier.open(toast) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: toast.kind.icon)
                            .font(.system(size: typography.heading))
                            .foregroundStyle(toast.kind == .request ? theme.warning : theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toast.title).font(.system(size: typography.emphasis, weight: .semibold)).lineLimit(1)
                            if !toast.body.isEmpty {
                                Text(toast.body).font(.system(size: typography.body)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Button { notifier.dismiss(toast) } label: {
                            Image(systemName: "xmark").font(.system(size: typography.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .frame(width: 280, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this pane")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(.easeOut(duration: 0.2), value: notifier.toasts)
    }
}

/// A small count badge for sidebar and tab rows.
struct HerdrAttentionBadge: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    let requests: Int
    let done: Int

    var body: some View {
        HStack(spacing: 3) {
            if requests > 0 { pill(requests, icon: "bell.fill", color: theme.warning) }
            if done > 0 { pill(done, icon: "checkmark", color: theme.success) }
        }
    }

    private func pill(_ count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: typography.tiny, weight: .bold))
            if count > 1 { Text("\(count)").font(.system(size: typography.caption, weight: .semibold)) }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .frame(height: 14)
        .background(color.opacity(0.16), in: Capsule())
    }
}

/// xherdr's macOS notification permission: shows the current state and lets the user
/// request it, open System Settings, or send a test notification.
struct NotificationPermissionView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @State private var status: UNAuthorizationStatus?
    @State private var testResult: String?

    private var settingsURL: URL? {
        let id = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.system(size: typography.emphasis, weight: .medium))
                Spacer()
                switch status {
                case .notDetermined?:
                    Button("Request Permission") { request() }
                        .buttonStyle(.borderedProminent)
                case .denied?:
                    Button("Open System Settings") { settingsURL.map { _ = NSWorkspace.shared.open($0) } }
                default:
                    EmptyView()
                }
                Button("Send Test") { sendTest() }
                    .disabled(!isAllowed)
                    .help("Post a sample notification")
            }
            Text(statusDetail)
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let testResult {
                Text(testResult).font(.system(size: typography.secondary)).foregroundStyle(.secondary)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var isAllowed: Bool { status == .authorized || status == .provisional }

    private var statusText: String {
        switch status {
        case .authorized?, .provisional?: return "Notifications allowed"
        case .denied?: return "Notifications blocked"
        case .notDetermined?: return "Permission not requested"
        default: return "Checking permission…"
        }
    }

    private var statusDetail: String {
        switch status {
        case .denied?:
            return "macOS blocks xherdr's notifications. Allow them in System Settings > Notifications > xherdr. Until then, alerts appear inside xherdr."
        case .notDetermined?:
            return "macOS asks once. Until xherdr is allowed, System delivery falls back to pop-ups inside xherdr."
        case .authorized?, .provisional?:
            return "Banner style and sounds for xherdr are managed in System Settings > Notifications."
        default:
            return ""
        }
    }

    private var statusIcon: String {
        switch status {
        case .authorized?, .provisional?: return "checkmark.circle.fill"
        case .denied?: return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized?, .provisional?: return theme.success
        case .denied?: return theme.warning
        default: return .secondary
        }
    }

    private func refresh() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            await refresh()
        }
    }

    private func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "xherdr notifications work"
        content.body = "Agents that finish or need input will appear like this."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                testResult = "Test notification sent."
            } catch {
                testResult = "macOS rejected the notification: \(error.localizedDescription)"
            }
        }
    }
}

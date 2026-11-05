import AppKit

/// The sound a preview button plays: a configured file, or the system sound Herdr falls back to.
struct HerdrSoundPreview: Equatable {
    let url: URL?
    let systemName: String

    /// A file that cannot be read falls back to the system sound.
    func sound() -> NSSound? {
        url.flatMap { NSSound(contentsOf: $0, byReference: true) } ?? NSSound(named: systemName)
    }
}

/// Effects of the settings form beyond config.toml, replaceable in tests.
struct HerdrSettingsEffects {
    var play: (NSSound) -> Void = { $0.play() }
}

/// One immutable destination owns the file and the session receiving reloads.
struct HerdrSettingsDestination: Sendable {
    let machine: HerdrMachineProfile?
    let socketPath: String?
    let session: String
    let localURL: URL

    init(machine: HerdrMachineProfile? = nil, socketPath: String? = nil, session: String = "default",
         localURL: URL = HerdrConfigFile.url) {
        self.machine = machine
        self.socketPath = socketPath
        self.session = session
        self.localURL = localURL
    }
}

enum HerdrSettingsOutcome: Equatable {
    case saved, reloaded, partial, reloadFailed, uncertain
}

extension Notification.Name {
    /// Only local file saves post this: SSH edits must never change local preferences.
    static let woolooLocalConfigSaved = Notification.Name("woolooLocalConfigSaved")
}

/// The config.toml being edited in settings: the guided fields' reads and writes, loading,
/// saving with Herdr's validation and reload, and sound previews. `HerdrSettingsView` renders it.
@MainActor
final class HerdrSettingsModel: ObservableObject {
    @Published var document = HerdrConfigDocument(text: "")
    /// The file as last loaded or saved, to detect edits and changes made on disk meanwhile.
    @Published private(set) var original = ""
    @Published var message: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var configPath: String
    @Published private(set) var remoteConfig: HerdrRemoteConfig?
    @Published private(set) var outcome: HerdrSettingsOutcome?
    let destination: HerdrSettingsDestination
    private(set) var lastLoad: Task<Void, Never>?
    /// The last save started, for tests to wait on.
    private(set) var lastSave: Task<Void, Never>?
    private var previewSound: NSSound?
    var effects = HerdrSettingsEffects()

    init(destination: HerdrSettingsDestination = HerdrSettingsDestination()) {
        self.destination = destination
        configPath = destination.machine == nil ? destination.localURL.path : ""
    }

    var isBusy: Bool { isLoading || isSaving }
    var canEditConfig: Bool { hasLoaded && !isBusy && outcome != .uncertain }
    var canRetryReload: Bool { !isBusy && !hasChanges && (outcome == .partial || outcome == .reloadFailed) }
    var hasChanges: Bool { document.text != original }
    var messageIsSuccess: Bool { outcome == .saved || outcome == .reloaded }

    // MARK: Fields

    func string(_ section: String, _ key: String, default fallback: String) -> String {
        document.string(section: section, key: key, default: fallback)
    }

    /// Writes only a changed value, so viewing a field never edits the file.
    func setString(_ value: String, _ section: String, _ key: String, default fallback: String) {
        guard value != string(section, key, default: fallback) else { return }
        document.setString(value, section: section, key: key)
    }

    /// Empty removes the key, so Herdr falls back to its own default instead of an unknown value.
    func setOptionalString(_ value: String, _ section: String, _ key: String) {
        guard value != string(section, key, default: "") else { return }
        if value.isEmpty { document.remove(section: section, key: key) }
        else { document.setString(value, section: section, key: key) }
    }

    func bool(_ section: String, _ key: String, default fallback: Bool) -> Bool {
        document.bool(section: section, key: key, default: fallback)
    }

    func setBool(_ value: Bool, _ section: String, _ key: String, default fallback: Bool) {
        guard value != bool(section, key, default: fallback) else { return }
        document.setBool(value, section: section, key: key)
    }

    func integer(_ section: String, _ key: String, default fallback: Int) -> Int {
        document.integer(section: section, key: key, default: fallback)
    }

    func setInteger(_ value: Int, _ section: String, _ key: String, default fallback: Int) {
        guard value != integer(section, key, default: fallback) else { return }
        document.setInteger(value, section: section, key: key)
    }

    func agentSound(_ agent: String) -> String {
        string("ui.sound.agents", agent, default: "default")
    }

    /// "Default" removes the override so Herdr's own default applies.
    func setAgentSound(_ value: String, _ agent: String) {
        guard value != agentSound(agent) else { return }
        if value == "default" { document.remove(section: "ui.sound.agents", key: agent) }
        else { document.setString(value, section: "ui.sound.agents", key: agent) }
    }

    func shortcutBindings(_ definition: HerdrShortcutDefinition) -> String {
        document.bindings(definition.key, default: definition.defaultBindings).joined(separator: ", ")
    }

    /// Alternatives are separated by commas; one binding is written as a string, several as an array.
    func setShortcutBindings(_ value: String, _ definition: HerdrShortcutDefinition) {
        guard value != shortcutBindings(definition) else { return }
        let values = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        document.setBindings(values, key: definition.key)
    }

    // MARK: Sound preview

    /// What the preview button next to `key` plays: the general sound file previews on its own,
    /// the done and request fields preview with their override applied.
    func soundPreview(key: String, kind: HerdrAlertKind) -> HerdrSoundPreview {
        var settings = HerdrNotificationSettings()
        settings.soundPath = document.string(section: "ui.sound", key: "path", default: "")
        settings.donePath = key == "path" ? nil : document.string(section: "ui.sound", key: "done_path", default: "")
        settings.requestPath = key == "path" ? nil : document.string(section: "ui.sound", key: "request_path", default: "")
        return HerdrSoundPreview(url: settings.soundURL(for: kind), systemName: kind == .done ? "Glass" : "Ping")
    }

    /// Stops the previous preview and plays the one for `key`.
    func playPreview(key: String, kind: HerdrAlertKind) {
        previewSound?.stop()
        previewSound = soundPreview(key: key, kind: kind).sound()
        if let previewSound { effects.play(previewSound) }
    }

    // MARK: File

    func load() {
        guard !isBusy else { return }
        outcome = nil
        if let machine = destination.machine {
            isLoading = true
            hasLoaded = false
            message = "Loading configuration from \(machine.label)…"
            lastLoad = Task {
                defer { isLoading = false }
                do {
                    let config = try await WorkspaceFiles.blocking(on: machine, priority: .userInitiated) {
                        try HerdrRemoteConfig.read(on: machine)
                    }
                    remoteConfig = config
                    configPath = config.path
                    didLoad(config.text)
                } catch { message = error.localizedDescription }
            }
        } else {
            do { didLoad(try HerdrConfigFile.read(at: destination.localURL)) }
            catch { hasLoaded = false; message = error.localizedDescription }
        }
    }

    private func didLoad(_ text: String) {
        original = text
        document = HerdrConfigDocument(text: text)
        hasLoaded = true
        message = nil
    }

    /// Persistence and reload are separate: a saved file stays saved even if reload fails.
    @discardableResult
    func save(reload: Bool = true, onSaved: @escaping () -> Void = {}) -> Task<Void, Never> {
        guard canEditConfig else { return Task {} }
        let text = document.text
        let old = original
        let destination = destination
        let remote = remoteConfig
        isSaving = true
        outcome = nil
        message = destination.machine.map { "Validating with Herdr on \($0.label)…" } ?? "Validating with Herdr…"
        let task = Task {
            defer { isSaving = false }
            let result = await WorkspaceFiles.blocking(on: destination.machine, priority: .userInitiated) {
                Result<HerdrRemoteConfig?, Error> {
                    if let machine = destination.machine {
                        guard let remote else { throw HerdrConfigError.validation("Load the remote file before saving.") }
                        do {
                            try remote.save(text, on: machine)
                            return remote.replacingText(text)
                        } catch {
                            // A connection can drop after replacement but before its acknowledgement.
                            // Re-read before treating it as a failed write or permitting another save.
                            let current: HerdrRemoteConfig
                            do { current = try HerdrRemoteConfig.read(on: machine) }
                            catch { throw RemoteSaveUncertain() }
                            if current.path == remote.path, current.resolvedPath == remote.resolvedPath,
                               current.user == remote.user, current.host == remote.host,
                               current.exists, current.text == text {
                                return current
                            }
                            throw error
                        }
                    }
                    try HerdrConfigFile.save(text, original: old, at: destination.localURL)
                    return nil
                }
            }
            switch result {
            case .success(let remote):
                original = text
                remoteConfig = remote
                outcome = .saved
                message = "Saved config.toml."
                if destination.machine == nil {
                    NotificationCenter.default.post(name: .woolooLocalConfigSaved, object: nil)
                }
                onSaved()
                if reload { await performReload() }
            case .failure(let error):
                if error is RemoteSaveUncertain {
                    outcome = .uncertain
                    message = "The SSH connection failed and the save outcome is unknown. Reload the file before saving again; copy your edits first if needed."
                } else { message = error.localizedDescription }
            }
        }
        lastSave = task
        return task
    }

    @discardableResult
    func retryReload() -> Task<Void, Never> {
        guard canRetryReload else { return Task {} }
        isSaving = true
        let task = Task {
            await performReload()
            isSaving = false
        }
        lastSave = task
        return task
    }

    private func performReload() async {
        guard let path = destination.socketPath else {
            outcome = .reloadFailed
            message = "Saved config.toml. No Herdr session was captured for reload."
            return
        }
        let result = await WorkspaceFiles.blocking(on: destination.machine, priority: .userInitiated) {
            Result { try HerdrConfigFile.reloadResult(socketPath: path) }
        }
        let label = destination.machine.map { "\($0.label) / \(destination.session)" } ?? destination.session
        switch result {
        case .success(let result):
            let details = result.diagnostics.joined(separator: "\n")
            switch result.status {
            case .applied:
                outcome = .reloaded
                message = destination.machine == nil ? "Saved and reloaded the selected Herdr session."
                    : "Saved config.toml. \(label) confirmed its configuration reload; the session’s config path cannot be verified."
            case .partial:
                outcome = .partial
                message = "Saved config.toml. \(label) reloaded only part of its configuration; some settings need a restart. \(details)"
            case .failed:
                outcome = .reloadFailed
                message = "Saved config.toml, but \(label) could not apply its configuration. \(details)"
            }
        case .failure(let error):
            outcome = .reloadFailed
            message = "Saved config.toml, but \(label) could not reload: \(error.localizedDescription)"
        }
    }
}

private struct RemoteSaveUncertain: Error {}

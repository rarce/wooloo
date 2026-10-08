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

/// The config.toml being edited in settings: the guided fields' reads and writes, loading,
/// saving with Herdr's validation and reload, and sound previews. `HerdrSettingsView` renders it.
@MainActor
final class HerdrSettingsModel: ObservableObject {
    @Published var document = HerdrConfigDocument(text: "")
    /// The file as last loaded or saved, to detect edits and changes made on disk meanwhile.
    @Published private(set) var original = ""
    @Published var message: String?
    @Published private(set) var isSaving = false
    /// The last save started, for tests to wait on.
    private(set) var lastSave: Task<Void, Never>?
    private var previewSound: NSSound?
    var effects = HerdrSettingsEffects()

    var hasChanges: Bool { document.text != original }
    /// Success messages all start with "Saved"; anything else is a warning.
    var messageIsSuccess: Bool { message?.hasPrefix("Saved") == true }

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
        do {
            original = try HerdrConfigFile.read(at: HerdrConfigFile.url)
            document = HerdrConfigDocument(text: original)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Validates and writes the edited config, then asks the session to reload it. A file changed
    /// on disk since it was loaded, or one Herdr rejects, is not written and the error is shown.
    @discardableResult
    func save(socketPath: String, session: String, onSaved: @escaping () -> Void) -> Task<Void, Never> {
        let text = document.text
        let old = original
        let url = HerdrConfigFile.url
        isSaving = true
        message = "Validating with Herdr…"
        let task = Task {
            let result = await BlockingWork.run(priority: .userInitiated) {
                Result {
                    try HerdrConfigFile.saveAndReload(text, original: old, at: url,
                                                      socketPath: socketPath, session: session)
                }
            }
            switch result {
            case .success(let status):
                original = text
                message = status
                isSaving = false
                onSaved()
            case .failure(let error):
                message = error.localizedDescription
                isSaving = false
            }
        }
        lastSave = task
        return task
    }
}

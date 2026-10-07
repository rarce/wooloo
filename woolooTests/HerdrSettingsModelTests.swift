import AppKit
import XCTest
@testable import wooloo

/// The settings form: what its fields write to config.toml, saving and reloading, and previews.
@MainActor
final class HerdrSettingsModelTests: XCTestCase {
    private static let initial = """
        # My Herdr config
        [terminal]
        default_shell = "/bin/zsh" # login shell

        [ui.sound]
        enabled = false
        path = "sounds/all.mp3"

        [ui.sound.agents]
        droid = "on"

        [ui.toast]
        delivery = "herdr"

        [keys]
        prefix = "ctrl+a"
        new_tab = ["prefix+c", "prefix+t"]

        [server]
        headless_cols = 100

        """

    private var config: TemporaryHerdrConfig!
    private var model: HerdrSettingsModel!
    private var played: [NSSound] = []
    private var restoreCandidates: (() -> Void)?

    override func setUp() async throws {
        config = try TemporaryHerdrConfig(Self.initial)
        model = HerdrSettingsModel()
        model.effects.play = { [unowned self] in played.append($0) }
        model.load()
    }

    override func tearDown() async throws {
        restoreCandidates?()
        config.restore()
    }

    private var fileText: String { (try? String(contentsOfFile: config.path, encoding: .utf8)) ?? "" }

    /// Replaces Herdr with a script whose `config check` rejects configs containing "invalid".
    private func useFakeHerdr() throws {
        let script = config.directory + "/bin/herdr"
        try FileManager.default.createDirectory(atPath: config.directory + "/bin", withIntermediateDirectories: true)
        try """
            #!/bin/sh
            [ "$1 $2" = "config check" ] || exit 2
            if grep -q invalid "$HERDR_CONFIG_PATH"; then echo "error: invalid key on line 1" >&2; exit 1; fi
            """.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let saved = WorkspaceFiles.herdrCandidates
        WorkspaceFiles.herdrCandidates = [config.directory + "/missing/herdr", script]
        restoreCandidates = { WorkspaceFiles.herdrCandidates = saved }
    }

    private var socket: String { config.directory + "/herdr.sock" }

    /// Saves and waits; returns how many times the saved callback ran.
    private func save() async -> Int {
        var saved = 0
        await model.save(socketPath: socket, session: "work", onSaved: { saved += 1 }).value
        return saved
    }

    // MARK: Fields

    func testLoadReadsTheFileWithoutChanges() {
        XCTAssertEqual(model.original, Self.initial)
        XCTAssertEqual(model.document.text, Self.initial)
        XCTAssertFalse(model.hasChanges)
        XCTAssertNil(model.message)
    }

    /// Fields write back what they show when a view refreshes; that must not edit the file,
    /// whether the key is set or absent and showing its default.
    func testSettingEveryFieldToItsShownValueWritesNothing() {
        let strings: [(String, String, String)] = [
            ("terminal", "default_shell", ""), ("terminal", "shell_mode", "auto"), ("terminal", "new_cwd", "follow"),
            ("keys", "prefix", "ctrl+b"), ("worktrees", "directory", "~/.herdr/worktrees"),
            ("ui.toast", "delivery", HerdrNotificationSettings.defaultDelivery.rawValue),
            ("ui.toast.herdr", "position", "bottom-right"), ("theme", "name", WoolooTheme.fallbackID),
        ]
        for (section, key, fallback) in strings {
            model.setString(model.string(section, key, default: fallback), section, key, default: fallback)
        }
        for key in ["path", "done_path", "request_path"] {
            model.setOptionalString(model.string("ui.sound", key, default: ""), "ui.sound", key)
        }
        for (section, key) in [("theme", "light_name"), ("theme", "dark_name")] {
            model.setOptionalString(model.string(section, key, default: ""), section, key)
        }
        for (section, key, fallback) in [("ui.sound", "enabled", true), ("theme", "auto_switch", false)] {
            model.setBool(model.bool(section, key, default: fallback), section, key, default: fallback)
        }
        for (section, key, fallback) in [("ui.toast", "delay_seconds", 1), ("server", "headless_cols", 120),
                                         ("server", "headless_rows", 40)] {
            model.setInteger(model.integer(section, key, default: fallback), section, key, default: fallback)
        }
        for agent in HerdrNotificationSettings.knownAgents {
            model.setAgentSound(model.agentSound(agent), agent)
        }
        for definition in HerdrShortcutDefinition.supported {
            model.setShortcutBindings(model.shortcutBindings(definition), definition)
        }
        XCTAssertEqual(model.document.text, Self.initial)
        XCTAssertFalse(model.hasChanges)
    }

    func testStringsAreWrittenKeepingComments() {
        XCTAssertEqual(model.string("terminal", "default_shell", default: ""), "/bin/zsh")
        model.setString("fish", "terminal", "default_shell", default: "")
        XCTAssertTrue(model.document.text.contains("default_shell = \"fish\" # login shell\n"))
        model.setString("login", "terminal", "shell_mode", default: "auto")
        XCTAssertEqual(model.string("terminal", "shell_mode", default: "auto"), "login")
        XCTAssertTrue(model.document.text.hasPrefix("# My Herdr config\n"))
        XCTAssertTrue(model.hasChanges)
    }

    /// Writing the default of an absent key is no change, but a different value then back is kept.
    func testStringEqualToAnAbsentDefaultIsNotWritten() {
        model.setString("follow", "terminal", "new_cwd", default: "follow")
        XCTAssertFalse(model.hasChanges)
        model.setString("home", "terminal", "new_cwd", default: "follow")
        model.setString("follow", "terminal", "new_cwd", default: "follow")
        XCTAssertTrue(model.document.text.contains("new_cwd = \"follow\""))
    }

    /// An emptied optional field removes its key, so Herdr uses its own default.
    func testEmptyOptionalStringRemovesTheKey() {
        model.setOptionalString("sounds/done.mp3", "ui.sound", "done_path")
        XCTAssertTrue(model.document.text.contains("done_path = \"sounds/done.mp3\""))
        model.setOptionalString("", "ui.sound", "path")
        model.setOptionalString("", "ui.sound", "done_path")
        XCTAssertFalse(model.document.text.contains("path ="))
        XCTAssertEqual(model.string("ui.sound", "path", default: ""), "")
        XCTAssertTrue(model.document.text.contains("[ui.sound]\nenabled = false\n"))

        model.setOptionalString("", "theme", "light_name")
        XCTAssertFalse(model.document.text.contains("[theme]"), "Removing an absent key adds nothing")
    }

    func testIntegersAreWrittenUnlessUnchanged() {
        XCTAssertEqual(model.integer("server", "headless_cols", default: 120), 100)
        model.setInteger(120, "server", "headless_cols", default: 120)
        XCTAssertTrue(model.document.text.contains("headless_cols = 120\n"))
        model.setInteger(40, "server", "headless_rows", default: 40)
        XCTAssertFalse(model.document.text.contains("headless_rows"))
        model.setInteger(50, "server", "headless_rows", default: 40)
        XCTAssertTrue(model.document.text.contains("headless_rows = 50"))
        model.setInteger(3, "ui.toast", "delay_seconds", default: 1)
        XCTAssertEqual(model.integer("ui.toast", "delay_seconds", default: 1), 3)
    }

    /// Booleans are compared with what is shown: the file's value, or the default when absent.
    func testBoolsAreWrittenAgainstTheirDefault() {
        XCTAssertFalse(model.bool("ui.sound", "enabled", default: true))
        model.setBool(false, "ui.sound", "enabled", default: true)
        XCTAssertFalse(model.hasChanges)
        model.setBool(true, "ui.sound", "enabled", default: true)
        XCTAssertTrue(model.document.text.contains("enabled = true"), "Back to the default is written, not removed")

        model.setBool(false, "theme", "auto_switch", default: false)
        XCTAssertFalse(model.document.text.contains("auto_switch"))
        model.setBool(true, "theme", "auto_switch", default: false)
        XCTAssertTrue(model.document.text.hasSuffix("[theme]\nauto_switch = true\n"))
    }

    /// "Default" removes a per-agent override; "on" and "off" are written.
    func testAgentSoundDefaultRemovesTheOverride() {
        XCTAssertEqual(model.agentSound("droid"), "on")
        XCTAssertEqual(model.agentSound("claude"), "default")
        model.setAgentSound("off", "claude")
        XCTAssertEqual(model.agentSound("claude"), "off")
        model.setAgentSound("default", "droid")
        XCTAssertFalse(model.document.text.contains("droid"))
        XCTAssertTrue(model.document.text.contains("claude = \"off\"\n"))
        XCTAssertEqual(HerdrConfigDocument(text: model.document.text).string(section: "ui.sound.agents", key: "claude", default: ""), "off")
    }

    func testShortcutBindingsAreSplitOnCommas() throws {
        let newTab = try XCTUnwrap(HerdrShortcutDefinition.supported.first { $0.key == "new_tab" })
        let help = try XCTUnwrap(HerdrShortcutDefinition.supported.first { $0.key == "help" })
        XCTAssertEqual(model.shortcutBindings(newTab), "prefix+c, prefix+t")
        XCTAssertEqual(model.shortcutBindings(help), "prefix+?")
        model.setShortcutBindings("prefix+c", newTab)
        XCTAssertTrue(model.document.text.contains("new_tab = \"prefix+c\"\n"))
        model.setShortcutBindings(" prefix+h ,ctrl+h", help)
        XCTAssertTrue(model.document.text.contains("help = [\"prefix+h\",\"ctrl+h\"]"))
        XCTAssertEqual(model.shortcutBindings(help), "prefix+h, ctrl+h")
    }

    func testLoadDiscardsEditsAndReportsReadErrors() throws {
        model.setString("fish", "terminal", "default_shell", default: "")
        model.message = "old"
        model.load()
        XCTAssertFalse(model.hasChanges)
        XCTAssertNil(model.message)

        try FileManager.default.removeItem(atPath: config.path)
        try FileManager.default.createDirectory(atPath: config.path, withIntermediateDirectories: true)
        model.load()
        XCTAssertNotNil(model.message, "A config.toml that cannot be read is reported")
        XCTAssertEqual(model.original, Self.initial, "The last loaded file is kept")
    }

    // MARK: Saving

    func testSaveWritesReloadsAndReportsSuccess() async throws {
        try useFakeHerdr()
        let server = try FakeHerdrServer(path: socket) { method, _ in
            method == "server.reload_config" ? ["result": ["status": "applied"]] : ["error": ["message": "unexpected"]]
        }
        defer { server.stop() }
        model.setInteger(80, "server", "headless_rows", default: 40)
        let edited = model.document.text

        var saved = 0
        let task = model.save(socketPath: socket, session: "work", onSaved: { saved += 1 })
        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.message, "Validating with Herdr…")
        XCTAssertFalse(model.messageIsSuccess)
        await task.value

        XCTAssertEqual(saved, 1)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.message, "Saved and reloaded the selected Herdr session.")
        XCTAssertTrue(model.messageIsSuccess)
        XCTAssertEqual(model.original, edited)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(fileText, edited)
        XCTAssertEqual(server.requests.map(\.method), ["server.reload_config"])
    }

    /// A session that cannot reload does not undo the save; it is still reported as saved.
    func testSaveWithoutASessionReportsTheReloadFailure() async throws {
        try useFakeHerdr()
        model.setBool(true, "ui.sound", "enabled", default: true)
        let edited = model.document.text

        let saved = await save()
        XCTAssertEqual(saved, 1)
        XCTAssertTrue(model.message?.hasPrefix("Saved config.toml, but work could not reload: ") == true,
                      model.message ?? "")
        XCTAssertTrue(model.messageIsSuccess)
        XCTAssertEqual(fileText, edited)
        XCTAssertFalse(model.hasChanges)
    }

    func testSaveRefusesAFileChangedOnDisk() async throws {
        try useFakeHerdr()
        try config.write("[ui.sound]\nenabled = true\n")
        model.setInteger(80, "server", "headless_rows", default: 40)

        let saved = await save()
        XCTAssertEqual(saved, 0)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.message, HerdrConfigError.changedOnDisk.localizedDescription)
        XCTAssertFalse(model.messageIsSuccess)
        XCTAssertEqual(fileText, "[ui.sound]\nenabled = true\n", "The other change is kept")
        XCTAssertEqual(model.original, Self.initial)
        XCTAssertTrue(model.hasChanges, "The edits stay to copy or discard")
    }

    func testSaveRefusesAConfigHerdrRejects() async throws {
        try useFakeHerdr()
        model.setString("invalid", "terminal", "shell_mode", default: "auto")

        let saved = await save()
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(model.message, "error: invalid key on line 1")
        XCTAssertEqual(fileText, Self.initial)
        XCTAssertTrue(model.hasChanges)
    }

    func testSaveWithoutHerdrCannotValidate() async throws {
        try useFakeHerdr()
        WorkspaceFiles.herdrCandidates = [config.directory + "/missing/herdr"]
        model.setInteger(80, "server", "headless_rows", default: 40)

        let saved = await save()
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(model.message, HerdrConfigError.herdrUnavailable.localizedDescription)
        XCTAssertEqual(fileText, Self.initial)
    }

    // MARK: Sound preview

    /// The general file previews alone; done and request preview with their override applied,
    /// relative to config.toml's folder.
    func testPreviewPicksTheFieldsSound() {
        let all = HerdrConfigFile.url.deletingLastPathComponent().appendingPathComponent("sounds/all.mp3")
        XCTAssertEqual(HerdrConfigFile.url.resolvingSymlinksInPath(), URL(fileURLWithPath: config.path).resolvingSymlinksInPath())
        model.setOptionalString("/tmp/done.mp3", "ui.sound", "done_path")

        XCTAssertEqual(model.soundPreview(key: "path", kind: .done).url, all)
        XCTAssertEqual(model.soundPreview(key: "path", kind: .done).systemName, "Glass")
        XCTAssertEqual(model.soundPreview(key: "done_path", kind: .done).url, URL(fileURLWithPath: "/tmp/done.mp3"))
        XCTAssertEqual(model.soundPreview(key: "request_path", kind: .request).url, all,
                       "No request override falls back to the general file")
        XCTAssertEqual(model.soundPreview(key: "request_path", kind: .request).systemName, "Ping")

        model.setOptionalString("", "ui.sound", "path")
        XCTAssertEqual(model.soundPreview(key: "path", kind: .done), HerdrSoundPreview(url: nil, systemName: "Glass"))
        XCTAssertEqual(model.soundPreview(key: "request_path", kind: .request),
                       HerdrSoundPreview(url: nil, systemName: "Ping"))
    }

    /// A readable file is played; a missing one, or none, plays the system sound.
    func testPlayPreviewPlaysTheFileOrTheSystemSound() throws {
        let sounds = config.directory + "/sounds"
        try FileManager.default.createDirectory(atPath: sounds, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/System/Library/Sounds/Tink.aiff", toPath: sounds + "/tink.aiff")
        model.setOptionalString("sounds/tink.aiff", "ui.sound", "done_path")

        model.playPreview(key: "done_path", kind: .done)
        XCTAssertEqual(played.count, 1)
        XCTAssertNil(played.last?.name, "A file sound has no system name")

        model.playPreview(key: "path", kind: .done)
        XCTAssertEqual(played.count, 2)
        XCTAssertEqual(played.last?.name, "Glass", "sounds/all.mp3 does not exist")

        model.setOptionalString("", "ui.sound", "path")
        model.playPreview(key: "request_path", kind: .request)
        XCTAssertEqual(played.last?.name, "Ping")
        XCTAssertNil(HerdrSoundPreview(url: nil, systemName: "no-such-sound").sound(),
                     "Nothing is played without a sound")
    }
}

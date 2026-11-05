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
        model = HerdrSettingsModel(destination: HerdrSettingsDestination(socketPath: socket, session: "work"))
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
        await model.save(onSaved: { saved += 1 }).value
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
        let task = model.save(onSaved: { saved += 1 })
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
        XCTAssertFalse(model.messageIsSuccess)
        XCTAssertTrue(model.canRetryReload)
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

    func testLocalSaveUpdatesThemeAndShortcutStoresInEveryWindowWithoutReloadingServer() async throws {
        try useFakeHerdr()
        let server = try FakeHerdrServer(path: socket) { _, _ in ["result": ["status": "applied"]] }
        defer { server.stop() }
        let firstTheme = ThemeStore()
        let secondTheme = ThemeStore()
        let firstKeys = HerdrShortcutStore()
        let secondKeys = HerdrShortcutStore()
        model.setString("rose-pine", "theme", "name", default: WoolooTheme.fallbackID)
        model.setString("ctrl+z", "keys", "prefix", default: HerdrShortcutMap.defaultPrefix)
        await model.save(reload: false).value
        XCTAssertEqual(firstTheme.theme.id, "rose-pine")
        XCTAssertEqual(secondTheme.theme.id, "rose-pine")
        XCTAssertEqual(firstKeys.map.prefixLabel, "ctrl+z")
        XCTAssertEqual(secondKeys.map.prefixLabel, "ctrl+z")
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertEqual(server.requests.count, 0)
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

/// Real POSIX scripts behind a fake SSH transport, with separate local and remote config files.
@MainActor
final class HerdrRemoteSettingsTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var local: TemporaryHerdrConfig!
    private var previousSSH = ""
    private let machine = HerdrMachineProfile(id: "dev", label: "Development", target: "ssh://dev@example.test:2222",
                                              session: "wooloo-ui-test", enabled: true)
    private let initial = "# remote\n[ui]\npane_gaps = true\n"
    private var configPath: String { sandbox.path("remote/config.toml") }
    private var socketPath: String { sandbox.path("session.sock") }

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        local = try TemporaryHerdrConfig("# local must stay untouched\n")
        previousSSH = WorkspaceFiles.sshExecutable
        let q = WorkspaceFiles.quote
        try sandbox.write(["bin/hostname": "#!/bin/sh\nprintf '%s\\n' dev-server\n",
                           "bin/id": "#!/bin/sh\nprintf '%s\\n' dev\n",
                           "remote/config.toml": initial, "bin/herdr": """
            #!/bin/sh
            if [ "$1" = --session ]; then
                [ "$3 $4" = 'remote-api-bridge --check' ] || exit 2
                printf 'herdr-api-bridge-v1\\n'
            elif [ "$1 $2" = 'config check' ]; then
                printf 'validate\\n' >> \(q(sandbox.path("validation.log")))
                if grep -q invalid "$HERDR_CONFIG_PATH"; then echo 'invalid config' >&2; exit 1; fi
                if [ -e \(q(sandbox.path("conflict"))) ]; then printf external > \(q(configPath)); fi
            else exit 3; fi
            """, "bin/ssh": """
            #!/bin/sh
            printf '%s\\0' "$@" >> \(q(sandbox.path("ssh.log")))
            [ ! -e \(q(sandbox.path("offline"))) ] || { echo offline >&2; exit 255; }
            for task_command; do :; done
            export HERDR_CONFIG_PATH=\(q(configPath))
            if [ -s \(q(sandbox.path("remote-path"))) ]; then
                HERDR_CONFIG_PATH=$(cat \(q(sandbox.path("remote-path"))))
                export HERDR_CONFIG_PATH
            fi
            export PATH=\(q(sandbox.path("bin"))):/usr/bin:/bin
            echo 'SSH warning' >&2
            case "$task_command" in
                *task_check_original*)
                    if [ -e \(q(sandbox.path("lose-ack"))) ] || [ -e \(q(sandbox.path("lose-and-offline"))) ]; then
                        /bin/sh -c "$task_command" >/dev/null || exit $?
                        if [ -e \(q(sandbox.path("lose-and-offline"))) ]; then : > \(q(sandbox.path("offline"))); fi
                        echo 'connection lost after save' >&2
                        exit 255
                    fi ;;
            esac
            exec /bin/sh -c "$task_command"
            """], in: ".")
        try sandbox.sh("chmod 755 bin/ssh bin/herdr bin/hostname bin/id; chmod 640 remote/config.toml")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
    }

    override func tearDown() async throws {
        WorkspaceFiles.sshExecutable = previousSSH
        local.restore()
        sandbox.tearDown()
    }

    private func loadedModel() async -> HerdrSettingsModel {
        let model = HerdrSettingsModel(destination: HerdrSettingsDestination(machine: machine, socketPath: socketPath,
                                                                            session: machine.session))
        model.load()
        XCTAssertTrue(model.isLoading)
        await model.lastLoad?.value
        XCTAssertTrue(model.hasLoaded, model.message ?? "")
        return model
    }

    private func readRemote() throws -> String { try String(contentsOfFile: configPath, encoding: .utf8) }

    func testRemoteSaveValidatesOnHostPreservesPermissionsAndReloadsCapturedSession() async throws {
        let server = try FakeHerdrServer(path: socketPath) { _, _ in ["result": ["status": "applied"]] }
        defer { server.stop() }
        let model = await loadedModel()
        XCTAssertEqual(model.configPath, configPath)
        XCTAssertEqual(model.document.text, initial)
        XCTAssertFalse(model.remoteConfig?.user.isEmpty ?? true)
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save().value
        XCTAssertEqual(model.outcome, .reloaded)
        XCTAssertTrue(try readRemote().contains("pane_gaps = false"))
        XCTAssertEqual(try String(contentsOfFile: local.path, encoding: .utf8), "# local must stay untouched\n")
        XCTAssertEqual(server.requests.map(\.method), ["server.reload_config"])
        XCTAssertEqual(try String(contentsOfFile: sandbox.path("validation.log"), encoding: .utf8), "validate\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertTrue(model.message?.contains("cannot be verified") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("remote")), ["config.toml"])
    }

    /// Use the bundled validator rather than the stub: Herdr checks relative sound paths
    /// against HERDR_CONFIG_PATH's parent directory, including when that path is a symlink.
    private func useBundledHerdrForValidation() throws {
        let executable = HerdrRuntimePaths.bundledExecutable.path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable), "The app must bundle Herdr for these tests")
        try sandbox.write(["bin/herdr": """
            #!/bin/sh
            if [ "$1" = --session ]; then
                [ "$3 $4" = 'remote-api-bridge --check' ] || exit 2
                printf 'herdr-api-bridge-v1\\n'
            else
                exec \(WorkspaceFiles.quote(executable)) "$@"
            fi
            """], in: ".")
    }

    func testBundledHerdrAcceptsRelativeSoundsWhenSavingUnrelatedRemoteSettings() async throws {
        try useBundledHerdrForValidation()
        let sounds = ["path", "done_path", "request_path"]
        let text = initial + "\n[ui.sound]\n" + sounds.map { "\($0) = \"sounds/\($0).mp3\"\n" }.joined()
        try sandbox.write(["remote/config.toml": text], in: ".")
        // config check verifies file presence; these fixtures are not played.
        try sandbox.write(Dictionary(uniqueKeysWithValues: sounds.map { ("remote/sounds/\($0).mp3", "sound fixture") }), in: ".")
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved, model.message ?? "")
        XCTAssertEqual(try readRemote(), text.replacingOccurrences(of: "pane_gaps = true", with: "pane_gaps = false"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("remote"))), ["config.toml", "sounds"])
    }

    func testBundledHerdrResolvesRelativeSoundsBesideConfiguredSymlink() async throws {
        try useBundledHerdrForValidation()
        let text = initial + "\n[ui.sound]\npath = \"sounds/notify.mp3\"\n"
        try sandbox.write(["remote/config.toml": text, "remote/sounds/notify.mp3": "sound fixture"], in: ".")
        try sandbox.sh("mkdir dotfiles; mv remote/config.toml dotfiles/herdr.toml; ln -s ../dotfiles/herdr.toml remote/config.toml")
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved, model.message ?? "")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: configPath), "../dotfiles/herdr.toml")
        XCTAssertTrue(try readRemote().contains("pane_gaps = false"))
        XCTAssertTrue(try readRemote().contains("path = \"sounds/notify.mp3\""))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("remote"))), ["config.toml", "sounds"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("dotfiles")), ["herdr.toml"])
    }

    func testBundledHerdrStillRejectsMissingRelativeSoundsWithoutChangingRemoteConfig() async throws {
        try useBundledHerdrForValidation()
        let text = initial + "\n[ui.sound]\npath = \"sounds/missing.mp3\"\n"
        try sandbox.write(["remote/config.toml": text], in: ".")
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertFalse(model.messageIsSuccess)
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.message?.contains("missing sound file") == true, model.message ?? "")
        XCTAssertEqual(try readRemote(), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path("remote")), ["config.toml"])
    }

    func testExternalEditDuringValidationIsKept() async throws {
        let model = await loadedModel()
        try sandbox.write(["conflict": ""], in: ".")
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save().value
        XCTAssertEqual(try readRemote(), "external")
        XCTAssertTrue(model.hasChanges)
        XCTAssertFalse(model.messageIsSuccess)
        XCTAssertTrue(model.message?.contains("changed outside wooloo") == true, model.message ?? "")
    }

    func testInvalidRemoteConfigDoesNotChangeEitherFile() async throws {
        let model = await loadedModel()
        model.document.text = "invalid"
        await model.save().value
        XCTAssertEqual(try readRemote(), initial)
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.message?.contains("invalid config") == true)
    }

    func testSavePreservesDotfilesSymlinkAndRejectsRetargeting() async throws {
        try sandbox.sh("mkdir dotfiles; mv remote/config.toml dotfiles/herdr.toml; ln -s ../dotfiles/herdr.toml remote/config.toml")
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: configPath), "../dotfiles/herdr.toml")
        XCTAssertTrue(try readRemote().contains("pane_gaps = false"))
        try sandbox.write(["dotfiles/other.toml": "other"], in: ".")
        try sandbox.sh("rm remote/config.toml; ln -s ../dotfiles/other.toml remote/config.toml")
        model.setBool(true, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(try readRemote(), "other")
        XCTAssertTrue(model.hasChanges)
    }

    func testMissingFileIsDifferentFromAnEmptyFileCreatedOutside() async throws {
        try FileManager.default.removeItem(atPath: configPath)
        let model = await loadedModel()
        XCTAssertEqual(model.remoteConfig?.exists, false)
        try sandbox.write(["remote/config.toml": ""], in: ".")
        model.document.text = initial
        await model.save(reload: false).value
        XCTAssertEqual(try readRemote(), "")
        XCTAssertTrue(model.hasChanges)
        model.load()
        await model.lastLoad?.value
        model.document.text = initial
        await model.save(reload: false).value
        XCTAssertEqual(try readRemote(), initial)
    }

    func testMissingConfigIsCreatedPrivately() async throws {
        try sandbox.sh("rm -rf remote")
        let model = await loadedModel()
        model.document.text = initial
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertEqual(try readRemote(), initial)
        let attributes = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingConfigUnderLinkedDirectoryKeepsStableIdentityAcrossSaves() async throws {
        try sandbox.sh("rm -rf remote; mkdir dotfiles; ln -s dotfiles remote")
        let model = await loadedModel()
        XCTAssertEqual(model.remoteConfig?.resolvedPath, sandbox.path("dotfiles/config.toml"))
        try sandbox.write(["lose-ack": ""], in: ".")
        model.document.text = initial
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved)
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertTrue(try readRemote().contains("pane_gaps = false"))
    }

    func testLostAcknowledgementReconcilesSavedFile() async throws {
        let model = await loadedModel()
        try sandbox.write(["lose-ack": ""], in: ".")
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(reload: false).value
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(try String(contentsOfFile: sandbox.path("validation.log"), encoding: .utf8), "validate\n")
    }

    func testDisconnectedSaveRequiresReloadBeforeAnotherSave() async throws {
        let model = await loadedModel()
        try sandbox.write(["offline": ""], in: ".")
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save().value
        XCTAssertEqual(model.outcome, .uncertain)
        XCTAssertFalse(model.canEditConfig)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(try readRemote(), initial)
        try FileManager.default.removeItem(atPath: sandbox.path("offline"))
        model.load()
        await model.lastLoad?.value
        XCTAssertTrue(model.canEditConfig)
        XCTAssertFalse(model.hasChanges)
    }

    func testLostAcknowledgementAndOfflineReadKeepsUnknownOutcomeWithoutReload() async throws {
        let server = try FakeHerdrServer(path: socketPath) { _, _ in ["result": ["status": "applied"]] }
        defer { server.stop() }
        let model = await loadedModel()
        try sandbox.write(["lose-and-offline": ""], in: ".")
        model.setBool(false, "ui", "pane_gaps", default: true)
        let edited = model.document.text
        await model.save().value
        XCTAssertEqual(try readRemote(), edited)
        XCTAssertEqual(model.document.text, edited)
        XCTAssertEqual(model.outcome, .uncertain)
        XCTAssertFalse(model.canEditConfig)
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testChangedRemotePathIsRejectedBeforeWriting() async throws {
        let model = await loadedModel()
        let otherPath = sandbox.path("other.toml")
        try sandbox.write(["other.toml": "other", "remote-path": otherPath], in: ".")
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save().value
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(try readRemote(), initial)
        XCTAssertEqual(try String(contentsOfFile: otherPath, encoding: .utf8), "other")
        XCTAssertTrue(model.message?.contains("path changed") == true, model.message ?? "")
    }

    func testSelectionChangeAfterSaveCannotRedirectSessionReload() async throws {
        let first = try FakeHerdrServer(path: socketPath) { _, _ in ["result": ["status": "applied"]] }
        let other = try FakeHerdrServer(path: sandbox.path("other.sock")) { _, _ in ["result": ["status": "applied"]] }
        defer { first.stop(); other.stop() }
        var selectedSocket = socketPath
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save(onSaved: { selectedSocket = other.path }).value
        XCTAssertEqual(selectedSocket, other.path)
        XCTAssertEqual(model.destination.socketPath, first.path)
        XCTAssertEqual(first.requests.map(\.method), ["server.reload_config"])
        XCTAssertTrue(other.requests.isEmpty)
    }

    func testFailedAndPartialReloadCanBeRetriedWithoutRewriting() async throws {
        let server = try FakeHerdrServer(path: socketPath) { _, _ in ["result": ["status": "failed", "diagnostics": ["rejected"]]] }
        defer { server.stop() }
        let model = await loadedModel()
        model.setBool(false, "ui", "pane_gaps", default: true)
        await model.save().value
        XCTAssertEqual(model.outcome, .reloadFailed)
        XCTAssertTrue(model.canRetryReload)
        XCTAssertFalse(model.messageIsSuccess)
        server.setResponder { _, _ in ["result": ["status": "partial", "diagnostics": ["restart needed"]]] }
        await model.retryReload().value
        XCTAssertEqual(model.outcome, .partial)
        XCTAssertTrue(model.canRetryReload)
        XCTAssertFalse(model.messageIsSuccess)
        server.setResponder { _, _ in ["result": ["status": "applied"]] }
        await model.retryReload().value
        XCTAssertEqual(model.outcome, .reloaded)
        XCTAssertFalse(model.canRetryReload)
        XCTAssertEqual(server.requests.count, 3)
        XCTAssertEqual(try String(contentsOfFile: sandbox.path("validation.log"), encoding: .utf8), "validate\n")
    }

    func testTwoOpenPreferenceWindowsDetectConflictingRemoteEdits() async throws {
        let first = await loadedModel()
        let second = await loadedModel()
        first.setBool(false, "ui", "pane_gaps", default: true)
        await first.save(reload: false).value
        second.document.text = "[ui]\npane_borders = \"off\"\n"
        await second.save(reload: false).value
        XCTAssertTrue(second.hasChanges)
        XCTAssertEqual(try readRemote(), first.original)
    }
}

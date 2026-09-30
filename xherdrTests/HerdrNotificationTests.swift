import AppKit
import UserNotifications
import XCTest
@testable import xherdr

/// Points `HERDR_CONFIG_PATH` at a temporary config.toml and silences alert sounds.
final class TemporaryHerdrConfig {
    let directory = "/private/tmp/xherdr-tests/\(UUID().uuidString)"
    var path: String { directory + "/config.toml" }
    private let saved: [String: String?]

    init(_ text: String = "") throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let keys = ["HERDR_CONFIG_PATH", "HERDR_DISABLE_SOUND"]
        saved = keys.reduce(into: [:]) { $0.updateValue(ProcessInfo.processInfo.environment[$1], forKey: $1) }
        setenv("HERDR_CONFIG_PATH", path, 1)
        setenv("HERDR_DISABLE_SOUND", "1", 1)
        try write(text)
    }

    func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func restore() {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(atPath: directory)
    }
}

/// Herdr's `[ui.sound]` and `[ui.toast]` settings.
final class HerdrNotificationSettingsTests: XCTestCase {
    private var config: TemporaryHerdrConfig!

    override func setUpWithError() throws { config = try TemporaryHerdrConfig() }
    override func tearDown() { config.restore() }

    func testDefaultsWithoutConfig() {
        let settings = HerdrNotificationSettings.load()
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertEqual(settings.delivery, HerdrNotificationSettings.defaultDelivery)
        XCTAssertEqual(settings.delaySeconds, 1)
        XCTAssertEqual(settings.toastPosition, "bottom-right")
        XCTAssertTrue(settings.agentSounds.isEmpty)
    }

    func testReadsEverySetting() throws {
        try config.write("""
        [ui.sound]
        enabled = false
        path = "~/sounds/any.aiff"
        done_path = "/System/Library/Sounds/Glass.aiff"
        request_path = "request.aiff"

        [ui.sound.agents]
        claude = "on"
        codex = "off"

        [ui.toast]
        delivery = "herdr"
        delay_seconds = -3

        [ui.toast.herdr]
        position = "top-left"
        """)
        let settings = HerdrNotificationSettings.load()
        XCTAssertFalse(settings.soundEnabled)
        XCTAssertEqual(settings.agentSounds, ["claude": "on", "codex": "off"])
        XCTAssertEqual(settings.delivery, .herdr)
        XCTAssertEqual(settings.delaySeconds, 0, "Negative delays are clamped")
        XCTAssertEqual(settings.toastPosition, "top-left")

        XCTAssertEqual(settings.soundURL(for: .done)?.path, "/System/Library/Sounds/Glass.aiff")
        // Relative paths are relative to config.toml's folder.
        let request = try XCTUnwrap(settings.soundURL(for: .request))
        XCTAssertEqual(request.lastPathComponent, "request.aiff")
        XCTAssertEqual(request.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: config.directory).resolvingSymlinksInPath().path)
        var general = settings
        general.donePath = ""
        XCTAssertEqual(general.soundURL(for: .done)?.path, NSString("~/sounds/any.aiff").expandingTildeInPath)
    }

    func testUnknownDeliveryFallsBackToTheDefault() throws {
        try config.write("[ui.toast]\ndelivery = \"carrier-pigeon\"\n")
        XCTAssertEqual(HerdrNotificationSettings.load().delivery, HerdrNotificationSettings.defaultDelivery)
    }

    func testPerAgentSoundOverrides() {
        unsetenv("HERDR_DISABLE_SOUND")
        var settings = HerdrNotificationSettings()
        settings.agentSounds = ["codex": "off", "droid": "on"]
        XCTAssertTrue(settings.playsSound(for: "Claude"))
        XCTAssertFalse(settings.playsSound(for: "codex"))
        XCTAssertTrue(settings.playsSound(for: "droid"), "An override unmutes an agent Herdr mutes by default")
        settings.agentSounds = [:]
        XCTAssertFalse(settings.playsSound(for: "droid"))
        settings.soundEnabled = false
        XCTAssertFalse(settings.playsSound(for: "claude"))
        settings.agentSounds = ["claude": "on"]
        XCTAssertTrue(settings.playsSound(for: "claude"))

        setenv("HERDR_DISABLE_SOUND", "1", 1)
        XCTAssertFalse(settings.playsSound(for: "claude"))
    }
}

/// `HerdrNotifier` turns agent status changes into attention marks and toasts.
@MainActor
final class HerdrNotifierTests: XCTestCase {
    private var config: TemporaryHerdrConfig!

    override func setUpWithError() throws {
        config = try TemporaryHerdrConfig("[ui.toast]\ndelivery = \"herdr\"\ndelay_seconds = 0\n")
    }

    override func tearDown() {
        config.restore()
    }

    private func snapshot(_ statuses: [String: String]) throws -> HerdrSnapshot {
        let panes = statuses.keys.sorted()
        let object: [String: Any] = [
            "workspaces": [["workspace_id": "w1", "label": "project"], ["workspace_id": "w2", "label": "other"]],
            "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "label": "1"], ["tab_id": "w2:t1", "workspace_id": "w2", "label": "1"]],
            "panes": panes.map { ["pane_id": $0, "workspace_id": String($0.prefix(2)), "tab_id": String($0.prefix(2)) + ":t1"] },
            "agents": panes.map { ["pane_id": $0, "workspace_id": String($0.prefix(2)), "tab_id": String($0.prefix(2)) + ":t1",
                                   "agent": "claude", "display_agent": "Claude", "agent_status": statuses[$0]!] },
            "layouts": []
        ]
        return try JSONDecoder().decode(HerdrSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testTransitionsRaiseAlertsAfterTheFirstSnapshot() throws {
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        // The first snapshot is only a baseline: agents already blocked do not alert again.
        notifier.process(try snapshot(["w1:p1": "working", "w1:p2": "working", "w1:p3": "blocked"]), selectedPaneID: nil)
        XCTAssertTrue(notifier.attention.isEmpty)

        notifier.process(try snapshot(["w1:p1": "blocked", "w1:p2": "done", "w1:p3": "blocked"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention, ["w1:p1": .request, "w1:p2": .done])
        XCTAssertEqual(notifier.attentionCount(inWorkspace: "w1", snapshot: try snapshot(["w1:p1": "blocked", "w1:p2": "done"])).requests, 1)
    }

    /// Herdr reports idle rather than done when a client watched the pane finish.
    func testIdleAfterWorkingCountsAsDone() throws {
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        notifier.process(try snapshot(["w2:p1": "working", "w2:p2": "done"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w2:p1": "idle", "w2:p2": "idle"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention, ["w2:p1": .done])
        let counts = notifier.attentionCount(inTab: "w2:t1", snapshot: try snapshot(["w2:p1": "idle"]))
        XCTAssertEqual(counts.done, 1)
        XCTAssertEqual(counts.requests, 0)
    }

    func testMarksClearWhenTheAgentMovesOnOrClosed() throws {
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        notifier.process(try snapshot(["w1:p1": "working", "w1:p2": "working", "w1:p3": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "blocked", "w1:p2": "done", "w1:p3": "blocked"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention.count, 3)

        // Answered (no longer blocked), back to work, and closed.
        notifier.process(try snapshot(["w1:p1": "idle", "w1:p2": "working"]), selectedPaneID: nil)
        XCTAssertTrue(notifier.attention.isEmpty)

        notifier.process(nil, selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "blocked"]), selectedPaneID: nil)
        XCTAssertTrue(notifier.attention.isEmpty, "After a reset the next snapshot is a new baseline")
    }

    func testToastsNameTheAgentAndItsPlace() async throws {
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        var opened: [String] = []
        notifier.onOpenPane = { opened.append($0) }
        notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "blocked"]), selectedPaneID: nil)
        await waitUntil { notifier.toasts.count == 1 }
        let toast = try XCTUnwrap(notifier.toasts.first)
        XCTAssertEqual(toast.title, "Claude needs input")
        XCTAssertEqual(toast.body, "project · Tab 1")
        XCTAssertEqual(toast.kind, .request)

        notifier.open(toast)
        XCTAssertEqual(opened, ["w1:p1"])
        XCTAssertTrue(notifier.toasts.isEmpty)
    }

    func testDeliveryOffKeepsMarksWithoutToasts() async throws {
        try config.write("[ui.toast]\ndelivery = \"off\"\n")
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "done"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention, ["w1:p1": .done])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(notifier.toasts.isEmpty)
    }

    /// A notifier whose system notifications are recorded instead of shown.
    private func systemNotifier(status: UNAuthorizationStatus, fails: Bool = false)
        -> (HerdrNotifier, () -> [UNNotificationRequest]) {
        let notifier = HerdrNotifier()
        var requests: [UNNotificationRequest] = []
        notifier.notificationStatus = { status }
        notifier.addNotification = { request in
            if fails { throw CocoaError(.featureUnsupported) }
            requests.append(request)
        }
        return (notifier, { requests })
    }

    func testSystemDeliveryPostsANotificationForThePane() async throws {
        for delivery in ["system", "terminal"] {
            try config.write("[ui.toast]\ndelivery = \"\(delivery)\"\ndelay_seconds = 0\n")
            let (notifier, requests) = systemNotifier(status: .authorized)
            defer { notifier.reset() }
            notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
            notifier.process(try snapshot(["w1:p1": "done"]), selectedPaneID: nil)
            await waitUntil { requests().count == 1 }
            let content = try XCTUnwrap(requests().first?.content)
            XCTAssertEqual(content.title, "Claude finished", delivery)
            XCTAssertEqual(content.body, "project · Tab 1", delivery)
            XCTAssertEqual(content.userInfo["paneID"] as? String, "w1:p1", delivery)
            XCTAssertTrue(notifier.toasts.isEmpty, delivery)
        }
    }

    /// macOS drops notifications it may not show, so they become toasts instead.
    func testSystemDeliveryFallsBackToToasts() async throws {
        try config.write("[ui.toast]\ndelivery = \"system\"\ndelay_seconds = 0\n")
        for (status, fails) in [(UNAuthorizationStatus.denied, false), (.notDetermined, false), (.authorized, true)] {
            let (notifier, requests) = systemNotifier(status: status, fails: fails)
            defer { notifier.reset() }
            notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
            notifier.process(try snapshot(["w1:p1": "blocked"]), selectedPaneID: nil)
            await waitUntil { notifier.toasts.count == 1 }
            XCTAssertTrue(requests().isEmpty)
        }
    }

    /// Alerts from panes out of view play Herdr's sounds, loaded once per kind.
    func testBackgroundAlertsPlayTheirSound() throws {
        unsetenv("HERDR_DISABLE_SOUND")
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        var played: [NSSound] = []
        notifier.play = { played.append($0) }
        notifier.process(try snapshot(["w1:p1": "working", "w1:p2": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "done", "w1:p2": "blocked"]), selectedPaneID: nil)
        XCTAssertEqual(played.map(\.name), ["Glass", "Ping"])
        notifier.process(try snapshot(["w1:p1": "working", "w1:p2": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "done", "w1:p2": "working"]), selectedPaneID: nil)
        XCTAssertEqual(played.count, 3)
        XCTAssertTrue(played[2] === played[0], "The sound is reused")
    }

    func testSoundsFollowTheConfig() throws {
        unsetenv("HERDR_DISABLE_SOUND")
        try config.write("[ui.sound]\nenabled = false\n[ui.toast]\ndelivery = \"off\"\n")
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        var played: [NSSound] = []
        notifier.play = { played.append($0) }
        notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "done"]), selectedPaneID: nil)
        XCTAssertTrue(played.isEmpty)
        XCTAssertEqual(notifier.attention, ["w1:p1": .done], "The mark stays without a sound")
    }

    func testClickingANotificationOpensItsPane() {
        let notifier = HerdrNotifier()
        var opened: [String] = []
        notifier.onOpenPane = { opened.append($0) }
        notifier.openNotification(paneID: "w1:p2")
        notifier.openNotification(paneID: nil)
        XCTAssertEqual(opened, ["w1:p2"])
    }

    /// A clicked system notification opens the pane in its userInfo, then tells macOS it is handled.
    func testClickedNotificationResponseOpensItsPaneAndCompletes() async {
        let notifier = HerdrNotifier()
        var opened: [String] = []
        var completed = 0
        notifier.onOpenPane = { opened.append($0) }
        notifier.openNotification(userInfo: ["paneID": "w1:p2"]) { completed += 1 }
        await waitUntil { completed == 1 }
        XCTAssertEqual(opened, ["w1:p2"])

        // Without a pane the app still comes forward and the handler still runs.
        notifier.openNotification(userInfo: [:]) { completed += 1 }
        notifier.openNotification(userInfo: ["paneID": 42]) { completed += 1 }
        await waitUntil { completed == 3 }
        XCTAssertEqual(opened, ["w1:p2"])
    }

    /// Sets xherdr's UserDefaults preferences and returns a closure that restores them.
    private func setDefaults(_ values: [String: Bool]) -> () -> Void {
        let defaults = UserDefaults.standard
        let saved = values.keys.map { ($0, defaults.object(forKey: $0)) }
        for (key, value) in values { defaults.set(value, forKey: key) }
        return {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    func testReloadSettingsRereadsTheConfig() throws {
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        var authorizations = 0
        notifier.requestAuthorization = { authorizations += 1 }
        XCTAssertEqual(notifier.settings.delivery, .herdr)

        try config.write("[ui.sound]\nenabled = false\n[ui.toast]\ndelivery = \"system\"\ndelay_seconds = 4\n[ui.toast.herdr]\nposition = \"top-left\"\n")
        XCTAssertEqual(notifier.settings.delivery, .herdr, "Settings change only on reload")
        notifier.reloadSettings()
        XCTAssertEqual(notifier.settings.delivery, .system)
        XCTAssertFalse(notifier.settings.soundEnabled)
        XCTAssertEqual(notifier.settings.delaySeconds, 4)
        XCTAssertEqual(notifier.settings.toastPosition, "top-left")
        XCTAssertEqual(authorizations, 1, "System delivery asks macOS for permission")

        // Terminal delivery also goes to macOS; in-app and off do not need permission.
        for (delivery, expected) in [("terminal", 2), ("herdr", 2), ("off", 2)] {
            try config.write("[ui.toast]\ndelivery = \"\(delivery)\"\n")
            notifier.reloadSettings()
            XCTAssertEqual(notifier.settings.delivery.rawValue, delivery)
            XCTAssertEqual(authorizations, expected, delivery)
        }
    }

    /// Reloading drops cached sounds so a new sound path takes effect.
    func testReloadSettingsReloadsTheSounds() throws {
        unsetenv("HERDR_DISABLE_SOUND")
        try config.write("[ui.toast]\ndelivery = \"off\"\n")
        let restore = setDefaults([HerdrNotifier.bounceDockKey: false])
        defer { restore() }
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        notifier.isAppActive = { false }
        var played: [NSSound] = []
        notifier.play = { played.append($0) }
        func finish() throws {
            notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
            notifier.process(try snapshot(["w1:p1": "done"]), selectedPaneID: nil)
        }
        try finish()
        XCTAssertEqual(played.map(\.name), ["Glass"])

        try config.write("[ui.sound]\ndone_path = \"/System/Library/Sounds/Hero.aiff\"\n[ui.toast]\ndelivery = \"off\"\n")
        try finish()
        XCTAssertEqual(played.count, 2)
        XCTAssertTrue(played[1] === played[0], "Before a reload the cached sound plays")

        notifier.reloadSettings()
        try finish()
        XCTAssertEqual(played.count, 3)
        XCTAssertFalse(played[2] === played[0], "The reload loads the configured sound")
        XCTAssertNotEqual(played[2].name, "Glass")
    }

    /// Looking at a pane while xherdr is active clears its mark and the Dock badge count.
    func testAcknowledgeClearsTheMarkWhileActive() throws {
        let restore = setDefaults([HerdrNotifier.dockBadgeKey: true, HerdrNotifier.bounceDockKey: false])
        defer { restore() }
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        var active = false
        notifier.isAppActive = { active }
        notifier.process(try snapshot(["w1:p1": "working", "w1:p2": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "blocked", "w1:p2": "done"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention, ["w1:p1": .request, "w1:p2": .done])
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")

        notifier.acknowledge(paneID: "w1:p1")
        XCTAssertEqual(notifier.attention.count, 2, "In the background the user has not seen the pane")

        active = true
        notifier.acknowledge(paneID: nil)
        notifier.acknowledge(paneID: "w1:p9")
        XCTAssertEqual(notifier.attention.count, 2)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")

        notifier.acknowledge(paneID: "w1:p1")
        XCTAssertEqual(notifier.attention, ["w1:p2": .done])
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        notifier.acknowledge(paneID: "w1:p2")
        XCTAssertTrue(notifier.attention.isEmpty)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    func testDockBadgeFollowsItsPreference() throws {
        let restore = setDefaults([HerdrNotifier.dockBadgeKey: false, HerdrNotifier.bounceDockKey: false])
        defer { restore() }
        let notifier = HerdrNotifier()
        defer { notifier.reset() }
        notifier.isAppActive = { false }
        notifier.process(try snapshot(["w1:p1": "working"]), selectedPaneID: nil)
        notifier.process(try snapshot(["w1:p1": "done"]), selectedPaneID: nil)
        XCTAssertEqual(notifier.attention, ["w1:p1": .done])
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        UserDefaults.standard.set(true, forKey: HerdrNotifier.dockBadgeKey)
        notifier.refreshDockBadge()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
    }
}

/// Reading, validating and saving config.toml.
final class HerdrConfigFileTests: XCTestCase {
    private var config: TemporaryHerdrConfig!

    override func setUpWithError() throws { config = try TemporaryHerdrConfig("[ui]\nsound = true\n") }
    override func tearDown() { config.restore() }

    private var herdrInstalled: Bool {
        WorkspaceFiles.herdrCandidates.contains(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Replaces Herdr with a script whose `config check` rejects configs containing "invalid".
    private func useFakeHerdr() throws -> () -> Void {
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
        return { WorkspaceFiles.herdrCandidates = saved }
    }

    func testPathFollowsTheEnvironment() throws {
        XCTAssertEqual(HerdrConfigFile.url.resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: config.path).resolvingSymlinksInPath().path)
        XCTAssertEqual(try HerdrConfigFile.read(at: URL(fileURLWithPath: config.directory + "/missing.toml")), "")
    }

    func testSaveRefusesAFileChangedOnDisk() throws {
        let url = HerdrConfigFile.url
        XCTAssertThrowsError(try HerdrConfigFile.save("[ui]\n", original: "something else", at: url)) {
            XCTAssertEqual($0.localizedDescription, HerdrConfigError.changedOnDisk.localizedDescription)
        }
        XCTAssertEqual(try HerdrConfigFile.read(at: url), "[ui]\nsound = true\n")
    }

    /// Herdr checks a copy of the new config; a rejected one leaves the file as it was.
    func testSaveIsValidatedByHerdr() throws {
        let restore = try useFakeHerdr()
        defer { restore() }
        let url = HerdrConfigFile.url
        XCTAssertThrowsError(try HerdrConfigFile.save("[ui]\ninvalid = 1\n", original: "[ui]\nsound = true\n", at: url)) {
            XCTAssertEqual($0.localizedDescription, "error: invalid key on line 1")
        }
        XCTAssertEqual(try HerdrConfigFile.read(at: url), "[ui]\nsound = true\n")

        try HerdrConfigFile.save("[ui]\nsound = false\n", original: "[ui]\nsound = true\n", at: url)
        XCTAssertEqual(try HerdrConfigFile.read(at: url), "[ui]\nsound = false\n")

        WorkspaceFiles.herdrCandidates = [config.directory + "/missing/herdr"]
        XCTAssertThrowsError(try HerdrConfigFile.save("[ui]\n", original: "[ui]\nsound = false\n", at: url)) {
            XCTAssertEqual($0.localizedDescription, HerdrConfigError.herdrUnavailable.localizedDescription)
        }
    }

    /// After saving, the session reloads the config; its answer, or its absence, is reported.
    func testSaveAndReloadReportsTheSessionsAnswer() throws {
        let restore = try useFakeHerdr()
        defer { restore() }
        let url = HerdrConfigFile.url
        let socket = "/private/tmp/xherdr-tests/\(UUID().uuidString.prefix(8)).sock"
        var original = try HerdrConfigFile.read(at: url)
        func save(_ text: String) throws -> String {
            defer { original = text }
            return try HerdrConfigFile.saveAndReload(text, original: original, at: url, socketPath: socket, session: "work")
        }

        XCTAssertTrue(try save("[ui]\nsound = false\n").hasPrefix("Saved config.toml, but work could not reload: "),
                      "No session is running")

        var reply: [String: Any] = ["status": "applied"]
        let lock = NSLock()
        let server = try FakeHerdrServer(path: socket) { method, _ in
            lock.lock(); defer { lock.unlock() }
            return method == "server.reload_config" ? ["result": reply] : ["error": ["message": "unexpected"]]
        }
        defer { server.stop() }
        XCTAssertEqual(try save("[ui]\nsound = true\n"), "Saved and reloaded the selected Herdr session.")
        lock.withLock { reply = ["status": "partial", "diagnostics": ["theme needs a restart"]] }
        XCTAssertEqual(try save("[ui]\nsound = false\n"), "Saved; some settings need a restart. theme needs a restart")
        lock.withLock { reply = ["status": "failed", "diagnostics": ["a", "b"]] }
        XCTAssertEqual(try save("[ui]\nsound = true\n"), "Saved, but Herdr could not apply the config. a\nb")
        XCTAssertEqual(server.requests.filter { $0.method == "server.reload_config" }.count, 3)

        XCTAssertThrowsError(try save("[ui]\ninvalid = 1\n"), "A rejected config is neither saved nor reloaded")
        XCTAssertEqual(server.requests.count, 3)
    }

    /// Validation runs the installed `herdr config check`; skipped where Herdr is not installed.
    func testSaveValidatesWithHerdr() throws {
        guard herdrInstalled else { throw XCTSkip("Herdr is not installed") }
        let url = HerdrConfigFile.url
        let original = try HerdrConfigFile.read(at: url)
        XCTAssertThrowsError(try HerdrConfigFile.save("[keys]\nzoom = \"prefix+\\/\"\n", original: original, at: url)) {
            XCTAssertTrue($0.localizedDescription.contains("invalid escape"), $0.localizedDescription)
        }
        XCTAssertEqual(try HerdrConfigFile.read(at: url), original)

        let nested = URL(fileURLWithPath: config.directory + "/new/config.toml")
        try HerdrConfigFile.save("[keys]\nzoom = \"prefix+/\"\n", original: "", at: nested)
        XCTAssertEqual(try HerdrConfigFile.read(at: nested), "[keys]\nzoom = \"prefix+/\"\n")
    }
}

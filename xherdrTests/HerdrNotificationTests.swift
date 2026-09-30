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
}

/// Reading, validating and saving config.toml.
final class HerdrConfigFileTests: XCTestCase {
    private var config: TemporaryHerdrConfig!

    override func setUpWithError() throws { config = try TemporaryHerdrConfig("[ui]\nsound = true\n") }
    override func tearDown() { config.restore() }

    private var herdrInstalled: Bool {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
         "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].contains(where: FileManager.default.isExecutableFile(atPath:))
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

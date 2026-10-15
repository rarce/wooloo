import XCTest
@testable import wooloo

final class AgentQuotaTests: XCTestCase {
    func testClaudeUsageMapsSessionWeeklyAndScopedLimits() {
        let json = """
            {"five_hour": {"utilization": 40.0, "resets_at": "2026-09-30T21:30:00.226707+00:00"},
             "seven_day": {"utilization": 30, "resets_at": "2026-10-06T13:00:00+00:00"},
             "seven_day_opus": null, "tangelo": {"utilization": 99},
             "limits": [
               {"kind": "weekly_all", "group": "weekly", "percent": 30, "scope": null},
               {"kind": "weekly_scoped", "group": "weekly", "percent": 12.5,
                "resets_at": "2026-10-06T13:00:00+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}}},
               {"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"display_name": "All models"}}}
             ],
             "extra_usage": {"is_enabled": false, "utilization": null}}
            """
        let windows = AgentQuotaParser.claudeUsage(Data(json.utf8))
        XCTAssertEqual(windows.map(\.label), ["5H", "7D", "FABLE 7D"])
        XCTAssertEqual(windows[0].usedFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_790_803_800.2267, accuracy: 0.01)
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1_791_291_600))
        XCTAssertEqual(windows[2].usedFraction, 0.125, accuracy: 0.0001)
    }

    func testClaudeUsageIncludesEnabledExtraUsage() {
        let json = #"{"extra_usage": {"is_enabled": true, "utilization": 150}}"#
        let windows = AgentQuotaParser.claudeUsage(Data(json.utf8))
        XCTAssertEqual(windows.map(\.label), ["EXTRA"])
        XCTAssertEqual(windows[0].usedFraction, 1)
    }

    func testClaudeCredentialReadsTokenExpiryAndPlan() throws {
        let json = #"{"mcpOAuth": {}, "claudeAiOauth": {"accessToken": "abc", "expiresAt": 1790831706368, "subscriptionType": "max"}}"#
        let credential = try XCTUnwrap(AgentQuotaParser.claudeCredential(Data(json.utf8)))
        XCTAssertEqual(credential.token, "abc")
        XCTAssertEqual(credential.plan, "max")
        XCTAssertEqual(credential.expiresAt?.timeIntervalSince1970 ?? 0, 1_790_831_706.368, accuracy: 0.001)
        XCTAssertTrue(credential.isExpired(at: Date(timeIntervalSince1970: 1_790_831_700)))
        XCTAssertFalse(credential.isExpired(at: Date(timeIntervalSince1970: 1_790_831_000)))
        XCTAssertNil(AgentQuotaParser.claudeCredential(Data(#"{"mcpOAuth": {}}"#.utf8)))
    }

    func testCodexUsageLabelsWindowsByTheirLength() {
        let json = """
            {"plan_type": "plus",
             "rate_limit": {"primary_window": {"used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1735401600},
                            "secondary_window": {"used_percent": 5, "limit_window_seconds": 604800, "reset_at": 1735920000}},
             "additional_rate_limits": [{"limit_name": "GPT-5.3-Codex-Spark",
                "rate_limit": {"primary_window": {"used_percent": 50, "limit_window_seconds": 18000}, "secondary_window": null}}]}
            """
        let usage = AgentQuotaParser.codexUsage(Data(json.utf8))
        XCTAssertEqual(usage.plan, "plus")
        XCTAssertEqual(usage.windows.map(\.label), ["5H", "7D", "SPARK 5H"])
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_735_920_000))
        XCTAssertEqual(usage.windows[2].usedFraction, 0.5)
    }

    func testCodexUsageWithOnlyAWeeklyPrimaryWindow() {
        let json = #"{"rate_limit": {"primary_window": {"used_percent": 74, "limit_window_seconds": 604800}, "secondary_window": null}}"#
        XCTAssertEqual(AgentQuotaParser.codexUsage(Data(json.utf8)).windows.map(\.label), ["7D"])
    }

    func testCodexLogLineReadsRateLimitsInMinutes() throws {
        let line = #"{"timestamp":"2026-09-30T20:07:22.462Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":74.0,"window_minutes":10080,"resets_at":1791181422},"secondary":null,"plan_type":"prolite"}}}"#
        let quota = try XCTUnwrap(AgentQuotaParser.codexLogLine(Substring(line)))
        XCTAssertTrue(quota.fromLog)
        XCTAssertEqual(quota.plan, "prolite")
        XCTAssertEqual(quota.windows.map(\.label), ["7D"])
        XCTAssertEqual(quota.capturedAt.timeIntervalSince1970, 1_790_798_842.462, accuracy: 0.001)
        XCTAssertNil(AgentQuotaParser.codexLogLine(#"{"payload":{"rate_limits":null}}"#))
        XCTAssertNil(AgentQuotaParser.codexLogLine(#"{"payload":{"type":"message"}}"#))
    }

    /// A home with both agents signed in and two days of Codex rollouts.
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-quota-\(UUID())").path
        let manager = FileManager.default
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: home + "/" + path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func rollout(_ day: String, used: Int) -> String {
            #"{"timestamp":"2026-09-\#(day)T10:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":300}}}}"#
                + "\n" + #"{"payload":{"type":"token_count","rate_limits":null}}"# + "\n"
        }
        try write(".claude/.credentials.json", "{\n  \"claudeAiOauth\": {\"accessToken\": \"claude-token\"}\n}\n")
        try write(".codex/auth.json", #"{"tokens": {"access_token": "codex-token", "account_id": "acct"}}"#)
        try write(".codex/sessions/2026/09/29/rollout-a.jsonl", rollout("29", used: 10))
        try write(".codex/sessions/2026/09/30/rollout-b.jsonl", rollout("30", used: 20))
        try manager.createDirectory(atPath: home + "/.codex/sessions/2026/10/01", withIntermediateDirectories: true)
        return home
    }

    private func assertSignedIn(_ files: AgentQuotaFiles, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(files.claudeInstalled, file: file, line: line)
        XCTAssertEqual(files.claudeCredentials.flatMap(AgentQuotaParser.claudeCredential)?.token, "claude-token",
                       file: file, line: line)
        XCTAssertFalse(files.claudeKeychainFailed, file: file, line: line)
        XCTAssertTrue(files.codexInstalled, file: file, line: line)
        let codex = try XCTUnwrap(files.codexAuth.flatMap(AgentQuotaParser.codexCredential), file: file, line: line)
        XCTAssertEqual(codex.token, "codex-token", file: file, line: line)
        XCTAssertEqual(codex.accountID, "acct", file: file, line: line)
        let logged = try XCTUnwrap(files.codexLogLine.flatMap { AgentQuotaParser.codexLogLine(Substring($0)) },
                                   file: file, line: line)
        XCTAssertEqual(logged.windows.first?.label, "5H", file: file, line: line)
        XCTAssertEqual(logged.windows.first?.usedFraction, 0.2, file: file, line: line)
    }

    func testProbeReadsThisMacsCredentialsAndNewestRollout() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try assertSignedIn(AgentQuotaProbe.read(machine: nil, keychain: false,
                                                environment: ["HOME": home, "CODEX_HOME": ""]))
    }

    func testProbeReadsTheRemoteMachineOverSSH() throws {
        let home = try makeHome()
        defer {
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            try? FileManager.default.removeItem(atPath: home)
        }
        // Runs the remote command locally, as if the remote user's home were `home`.
        let ssh = home + "/ssh"
        try """
            #!/bin/sh
            for command; do :; done
            HOME='\(home)' CODEX_HOME= exec /bin/sh -c "$command"
            """.write(toFile: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
        WorkspaceFiles.sshExecutable = ssh
        let machine = HerdrMachineProfile(id: "dev", label: "Dev", target: "dev.example.test",
                                          session: "default", enabled: true)
        try assertSignedIn(AgentQuotaProbe.read(machine: machine, keychain: false))
    }

    func testProbeWithoutAgents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-quota-\(UUID())").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let files = try AgentQuotaProbe.read(machine: nil, keychain: false,
                                             environment: ["HOME": home, "CODEX_HOME": ""])
        XCTAssertEqual(files, AgentQuotaFiles())
    }

    func testProbeReadsThisMacsKeychainInProcessWithoutACredentialsFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-quota-\(UUID())").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = ["HOME": home, "CODEX_HOME": ""]
        let item = Data(#"{"claudeAiOauth": {"accessToken": "keychain-token"}}"#.utf8)

        let found = try AgentQuotaProbe.read(machine: nil, keychain: true, environment: environment,
                                             readKeychain: { .some(item) })
        XCTAssertEqual(found.claudeCredentials, item)
        XCTAssertFalse(found.claudeKeychainFailed)

        let denied = try AgentQuotaProbe.read(machine: nil, keychain: true, environment: environment,
                                              readKeychain: { .some(nil) })
        XCTAssertNil(denied.claudeCredentials)
        XCTAssertTrue(denied.claudeKeychainFailed)

        let missing = try AgentQuotaProbe.read(machine: nil, keychain: true, environment: environment,
                                               readKeychain: { nil })
        XCTAssertNil(missing.claudeCredentials)
        XCTAssertFalse(missing.claudeKeychainFailed)

        let skipped = try AgentQuotaProbe.read(machine: nil, keychain: false, environment: environment,
                                               readKeychain: { XCTFail("Keychain read without asking"); return nil })
        XCTAssertTrue(skipped.claudeInstalled)
    }

    func testProbeErrorsNeverCarrySignIns() {
        XCTAssertEqual(AgentQuotaProbe.redacted("claude=1\nclaude_credentials=eyJzZWNyZXQiOiAx"),
                       "Could not read the agents' sign-ins")
        XCTAssertEqual(AgentQuotaProbe.redacted("codex=1\ncodex_auth=e30="), "Could not read the agents' sign-ins")
        XCTAssertEqual(AgentQuotaProbe.redacted("ssh: connect to host dev port 22: Connection refused"),
                       "ssh: connect to host dev port 22: Connection refused")
    }

    func testProbeParsesAFailedKeychainRead() {
        let files = AgentQuotaProbe.parse("claude=1\nclaude_keychain=failed\ncodex=1\n")
        XCTAssertTrue(files.claudeInstalled)
        XCTAssertTrue(files.claudeKeychainFailed)
        XCTAssertNil(files.claudeCredentials)
        XCTAssertTrue(files.codexInstalled)
        XCTAssertNil(files.codexAuth)
    }

    func testFailedKeychainReadIsReportedUntilTheNextRead() async {
        // Each read that asks for the Keychain fails; the ones in between do not ask.
        let reader = AgentQuotaReader(probe: { _, keychain, _ in
            AgentQuotaFiles(claudeInstalled: true, claudeKeychainFailed: keychain)
        })
        func claudeError(at date: Date) async -> String? {
            guard case .failure(let error) = await reader.read(now: date)[.claude] else { return nil }
            return error.localizedDescription
        }
        let start = Date()
        var errors: [String?] = []
        for minutes in [0.0, 1, 14] { errors.append(await claudeError(at: start.addingTimeInterval(minutes * 60))) }
        XCTAssertEqual(errors, Array(repeating: "Claude Code's Keychain item is not readable", count: 3))

        let signedOut = AgentQuotaReader(probe: { _, _, _ in AgentQuotaFiles(claudeInstalled: true) })
        guard case .failure(let error) = await signedOut.read()[.claude] else { return XCTFail("Expected a failure") }
        XCTAssertEqual(error.localizedDescription, "Not signed in to Claude Code")
    }

    func testJWTExpiry() {
        func base64URL(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = "\(base64URL("{}")).\(base64URL(#"{"exp":1790831706,"sub":"x"}"#)).signature"
        XCTAssertEqual(AgentQuotaParser.jwtExpiry(token), Date(timeIntervalSince1970: 1_790_831_706))
        XCTAssertNil(AgentQuotaParser.jwtExpiry("opaque-token"))
        XCTAssertNil(AgentQuotaParser.jwtExpiry("a.\(base64URL(#"{"exp":true}"#)).c"))
    }

    func testWindowResetPassedCountsAsUnused() {
        let window = QuotaWindow(id: "w", label: "5H", usedFraction: 0.8, resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.usedFraction(at: Date(timeIntervalSince1970: 99)), 0.8)
        XCTAssertEqual(window.usedFraction(at: Date(timeIntervalSince1970: 100)), 0)
        XCTAssertEqual(AgentQuotaParser.spanLabel(18_000), "5H")
        XCTAssertEqual(AgentQuotaParser.spanLabel(604_800), "7D")
        XCTAssertEqual(AgentQuotaParser.spanLabel(90_000), "25H")
    }

    @MainActor
    func testMonitorKeepsTheLastQuotaWhenASourceFails() {
        let monitor = AgentQuotaMonitor()
        let quota = AgentQuota(windows: [QuotaWindow(id: "w", label: "5H", usedFraction: 0.5, resetsAt: nil)],
                               plan: "max", capturedAt: Date(timeIntervalSince1970: 0))
        monitor.apply(.claude, .success(quota))
        monitor.apply(.claude, .failure(WorkspaceFileError.message("offline")))
        XCTAssertEqual(monitor.states[.claude], AgentQuotaMonitor.State(quota: quota, failure: "offline"))
        monitor.apply(.claude, .success(nil))
        XCTAssertNil(monitor.states[.claude])
    }

    // MARK: Consent

    private let devMachine = HerdrMachineProfile(id: "dev", label: "Dev", target: "dev.example.test",
                                                 session: "default", enabled: true)

    /// Defaults of their own, removed after the test.
    private func consentDefaults() -> UserDefaults {
        let name = "AgentQuotaConsentTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// Monitors handed out by machine, recording each machine asked for. Polling is off, so a
    /// monitor never reads anything: holding one is what would make it read.
    @MainActor
    private final class Monitors {
        private(set) var asked: [HerdrMachineProfile?] = []
        private var monitors: [String: AgentQuotaMonitor] = [:]

        func monitor(for machine: HerdrMachineProfile?) -> AgentQuotaMonitor {
            asked.append(machine)
            let key = AgentQuotaConsent.key(for: machine)
            if let monitor = monitors[key] { return monitor }
            let monitor = AgentQuotaMonitor(machine: machine)
            monitors[key] = monitor
            return monitor
        }

        func inUse(_ machine: HerdrMachineProfile?) -> Bool {
            monitors[AgentQuotaConsent.key(for: machine)]?.isInUse ?? false
        }
    }

    @MainActor
    private func makeActivation(_ defaults: UserDefaults, _ monitors: Monitors) -> AgentQuotaActivation {
        AgentQuotaMonitor.isPollingEnabled = false
        addTeardownBlock { await MainActor.run { AgentQuotaMonitor.isPollingEnabled = true } }
        return AgentQuotaActivation(defaults: defaults, monitorFor: monitors.monitor(for:))
    }

    /// The dialog says what is read where, where it is sent from and to, and that the endpoints
    /// are unofficial.
    func testConsentExplainsWhatIsReadAndWhereItIsSent() {
        let local = AgentQuotaConsent.explanation(for: nil)
        for part in ["on this Mac", "~/.claude/.credentials.json", "Claude Code-credentials", "~/.codex/auth.json",
                     "$CODEX_HOME", "session logs", "api.anthropic.com", "chatgpt.com", "every two minutes",
                     "unofficial", "change or stop working", "never refreshes, saves or logs"] {
            XCTAssertTrue(local.localizedCaseInsensitiveContains(part), "Missing “\(part)”")
        }
        XCTAssertFalse(local.contains("leave from this Mac"))

        let remote = AgentQuotaConsent.explanation(for: devMachine)
        for part in ["on Dev (dev.example.test), over SSH", "`security`", "The requests leave from this Mac",
                     "unofficial"] {
            XCTAssertTrue(remote.contains(part), "Missing “\(part)”")
        }
        XCTAssertEqual(AgentQuotaConsent.title(for: nil), "Turn on Quotas for this Mac?")
        XCTAssertEqual(AgentQuotaConsent.title(for: devMachine), "Turn on Quotas for “Dev”?")
    }

    /// Nothing is polled before the user agrees; agreeing polls this machine and is remembered.
    @MainActor
    func testAcceptingTurnsQuotasOnAndOnlyThenPolls() {
        let defaults = consentDefaults()
        let monitors = Monitors()
        let activation = makeActivation(defaults, monitors)
        activation.show(machine: nil, windowActive: true)
        XCTAssertFalse(activation.isEnabled)
        XCTAssertTrue(monitors.asked.isEmpty, "Off asks for no monitor")

        activation.requestEnable()
        let request = activation.request
        XCTAssertNotNil(request)
        XCTAssertNil(request?.machine)
        XCTAssertFalse(activation.isEnabled, "Asking turns nothing on")
        XCTAssertTrue(monitors.asked.isEmpty, "The dialog reads nothing")

        activation.accept(request!)
        XCTAssertNil(activation.request)
        XCTAssertTrue(activation.isEnabled)
        XCTAssertTrue(monitors.inUse(nil))
        XCTAssertEqual(AgentQuotaConsent(stored: defaults.string(forKey: AgentQuotaConsent.storageKey)),
                       AgentQuotaConsent(machines: ["local"]))

        let reopened = makeActivation(defaults, Monitors())
        reopened.show(machine: nil, windowActive: true)
        XCTAssertTrue(reopened.isEnabled, "The agreement is remembered")
        reopened.disappear()
        activation.disappear()
        XCTAssertFalse(monitors.inUse(nil), "Leaving the window stops polling")
    }

    /// Cancel, also Escape, closes the dialog and leaves QUOTAS off without reading anything.
    @MainActor
    func testCancellingLeavesQuotasOffWithoutReading() {
        let defaults = consentDefaults()
        let monitors = Monitors()
        let activation = makeActivation(defaults, monitors)
        activation.show(machine: nil, windowActive: true)
        activation.requestEnable()
        activation.cancel()
        XCTAssertNil(activation.request)
        XCTAssertFalse(activation.isEnabled)
        XCTAssertTrue(monitors.asked.isEmpty)
        XCTAssertNil(defaults.string(forKey: AgentQuotaConsent.storageKey), "Nothing is saved")

        activation.show(machine: nil, windowActive: false)
        activation.show(machine: nil, windowActive: true)
        XCTAssertTrue(monitors.asked.isEmpty, "Reactivating the window does not turn it on")
    }

    /// The section's button and its context menu both ask through `requestEnable`, which shows
    /// one dialog however often it is asked; accepting twice holds the monitor once. The switch
    /// that 0.3.1's context menu turned on without any explanation is not consent.
    @MainActor
    func testContextMenuAndRepeatedRequestsShowOneDialog() {
        let defaults = consentDefaults()
        defaults.set(true, forKey: AgentQuotaConsent.legacyEnabledKey)
        let monitors = Monitors()
        let activation = makeActivation(defaults, monitors)
        activation.show(machine: nil, windowActive: true)
        XCTAssertFalse(activation.isEnabled, "The old switch is asked about again")
        XCTAssertNil(defaults.object(forKey: AgentQuotaConsent.legacyEnabledKey))

        activation.requestEnable() // the button
        let first = activation.request
        activation.requestEnable() // the context menu
        XCTAssertEqual(activation.request, first, "A second request does not stack another dialog")

        activation.accept(first!)
        activation.accept(first!)
        activation.requestEnable()
        XCTAssertNil(activation.request, "Nothing to ask once on")
        activation.show(machine: nil, windowActive: true)
        activation.disappear()
        XCTAssertFalse(monitors.inUse(nil), "The monitor was held once")
    }

    /// Agreeing is per machine: moving the explorer to an SSH machine reads nothing there until
    /// the user agrees for it, and a dialog answered after the explorer moved turns QUOTAS on only
    /// for the machine it named.
    @MainActor
    func testConsentFollowsTheExplorersMachine() {
        let defaults = consentDefaults()
        let monitors = Monitors()
        let activation = makeActivation(defaults, monitors)
        activation.show(machine: nil, windowActive: true)
        activation.requestEnable()
        activation.accept(activation.request!)
        XCTAssertTrue(monitors.inUse(nil))

        activation.show(machine: devMachine, windowActive: true)
        XCTAssertFalse(activation.isEnabled, "This Mac's agreement does not cover Dev")
        XCTAssertFalse(monitors.inUse(nil), "This Mac is no longer polled")
        XCTAssertFalse(monitors.asked.contains(devMachine), "Dev is not read")

        activation.requestEnable()
        let devRequest = activation.request!
        XCTAssertEqual(devRequest.machine, devMachine)
        activation.show(machine: nil, windowActive: true)
        XCTAssertTrue(monitors.inUse(nil))
        activation.accept(devRequest)
        XCTAssertTrue(activation.consent.allows(devMachine), "Dev, which the dialog named, is on")
        XCTAssertFalse(monitors.asked.contains(devMachine), "Dev is read only once the explorer shows it")
        activation.show(machine: devMachine, windowActive: true)
        XCTAssertTrue(monitors.inUse(devMachine))

        // A dialog for this Mac answered once the explorer is on another machine.
        activation.turnOff()
        XCTAssertFalse(monitors.inUse(devMachine))
        activation.show(machine: nil, windowActive: true)
        activation.requestEnable()
        let localRequest = activation.request!
        let other = HerdrMachineProfile(id: "other", label: "Other", target: "other.example.test",
                                        session: "default", enabled: true)
        activation.show(machine: other, windowActive: true)
        activation.accept(localRequest)
        XCTAssertFalse(activation.isEnabled, "Other was never agreed to")
        XCTAssertFalse(monitors.asked.contains(other))
        XCTAssertTrue(activation.consent.allows(nil))
        activation.disappear()
    }

    /// A machine profile whose SSH target changed, or a saved agreement of another version,
    /// asks again.
    func testChangedTargetsAndOlderAgreementsAskAgain() {
        var consent = AgentQuotaConsent()
        consent.grant(devMachine)
        XCTAssertTrue(consent.allows(devMachine))
        XCTAssertFalse(consent.allows(HerdrMachineProfile(id: "dev", label: "Dev", target: "elsewhere.example.test",
                                                          session: "default", enabled: true)))
        XCTAssertFalse(consent.allows(nil))
        XCTAssertEqual(AgentQuotaConsent(stored: consent.stored), consent)
        XCTAssertEqual(AgentQuotaConsent(stored: #"{"machines":["local"],"version":0}"#), AgentQuotaConsent())
        XCTAssertEqual(AgentQuotaConsent(stored: "not json"), AgentQuotaConsent())
        XCTAssertEqual(AgentQuotaConsent(stored: nil), AgentQuotaConsent())
    }

    /// Turning QUOTAS off in one window stops every window's polling, on every machine.
    @MainActor
    func testTurningOffInOneWindowStopsTheOthers() async {
        let defaults = consentDefaults()
        let monitors = Monitors()
        let first = makeActivation(defaults, monitors)
        let second = makeActivation(defaults, monitors)
        first.show(machine: nil, windowActive: true)
        second.show(machine: nil, windowActive: true)
        first.requestEnable()
        first.accept(first.request!)
        for _ in 0..<100 where !second.isEnabled { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(second.isEnabled, "The other window follows")

        second.turnOff()
        for _ in 0..<100 where first.isEnabled { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(monitors.inUse(nil), "No window polls")
        XCTAssertEqual(AgentQuotaConsent(stored: defaults.string(forKey: AgentQuotaConsent.storageKey)),
                       AgentQuotaConsent())
    }

    /// An inactive window holds no monitor even when QUOTAS is on.
    @MainActor
    func testInactiveWindowsDoNotPoll() {
        let defaults = consentDefaults()
        let monitors = Monitors()
        let activation = makeActivation(defaults, monitors)
        activation.show(machine: nil, windowActive: false)
        activation.requestEnable()
        activation.accept(activation.request!)
        XCTAssertTrue(activation.isEnabled)
        XCTAssertFalse(monitors.inUse(nil))
        activation.show(machine: nil, windowActive: true)
        XCTAssertTrue(monitors.inUse(nil))
        activation.show(machine: nil, windowActive: false)
        XCTAssertFalse(monitors.inUse(nil))
    }
}

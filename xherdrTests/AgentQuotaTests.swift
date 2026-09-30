import XCTest
@testable import xherdr

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
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xherdr-quota-\(UUID())").path
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
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xherdr-quota-\(UUID())").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let files = try AgentQuotaProbe.read(machine: nil, keychain: false,
                                             environment: ["HOME": home, "CODEX_HOME": ""])
        XCTAssertEqual(files, AgentQuotaFiles())
    }

    func testProbeParsesAFailedKeychainRead() {
        let files = AgentQuotaProbe.parse("claude=1\nclaude_keychain=failed\ncodex=1\n")
        XCTAssertTrue(files.claudeInstalled)
        XCTAssertTrue(files.claudeKeychainFailed)
        XCTAssertNil(files.claudeCredentials)
        XCTAssertTrue(files.codexInstalled)
        XCTAssertNil(files.codexAuth)
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
}

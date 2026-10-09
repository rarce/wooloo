import Foundation
import Security

/// A coding agent whose subscription limits the sidebar shows.
enum AgentProvider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}

/// One usage limit of a subscription, for example Claude's five-hour session.
struct QuotaWindow: Equatable, Identifiable {
    let id: String
    /// Short sidebar label, such as `5H` or `OPUS 7D`.
    let label: String
    let usedFraction: Double
    let resetsAt: Date?

    /// The share used at `now`: a window whose reset has passed starts again from zero.
    func usedFraction(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return usedFraction
    }
}

struct AgentQuota: Equatable {
    var windows: [QuotaWindow]
    var plan: String?
    /// When the numbers were current. Readings from Codex's session log can be older than the fetch.
    var capturedAt: Date
    var fromLog = false
}

/// Pure parsing of the agents' credentials, usage responses and session logs. The endpoints are
/// the ones Claude Code (`/usage`) and the Codex CLI use; neither is documented, so every field is
/// optional and unknown keys are ignored.
enum AgentQuotaParser {
    struct ClaudeCredential: Equatable {
        let token: String
        let expiresAt: Date?
        let plan: String?

        func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now.addingTimeInterval(60) } ?? false }
    }

    struct CodexCredential: Equatable {
        let token: String
        let accountID: String?
        let expiresAt: Date?
    }

    /// Claude Code's credentials, from `~/.claude/.credentials.json` or its Keychain item.
    static func claudeCredential(_ data: Data) -> ClaudeCredential? {
        guard let json = object(data), let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return ClaudeCredential(token: token,
                                expiresAt: number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
                                plan: oauth["subscriptionType"] as? String)
    }

    /// The ChatGPT sign-in in Codex's `auth.json`; nil for an API-key login.
    static func codexCredential(_ data: Data) -> CodexCredential? {
        guard let tokens = object(data)?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return CodexCredential(token: token, accountID: tokens["account_id"] as? String, expiresAt: jwtExpiry(token))
    }

    /// The `exp` claim of a JWT, without verifying it: it only decides whether to try the request.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let exp = object(data).flatMap({ number($0["exp"]) }) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    /// `GET api.anthropic.com/api/oauth/usage`: `utilization` is a percentage, `resets_at` ISO 8601.
    static func claudeUsage(_ data: Data) -> [QuotaWindow] {
        guard let json = object(data) else { return [] }
        var windows: [QuotaWindow] = []
        for (key, label) in [("five_hour", "5H"), ("seven_day", "7D"), ("seven_day_opus", "OPUS 7D"),
                             ("seven_day_sonnet", "SONNET 7D")] {
            guard let window = json[key] as? [String: Any], let used = number(window["utilization"]) else { continue }
            windows.append(QuotaWindow(id: key, label: label, usedFraction: fraction(used),
                                       resetsAt: isoDate(window["resets_at"])))
        }
        // Model-scoped weekly limits; the account-wide ones repeat `five_hour` and `seven_day`.
        for limit in json["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty,
                  model.lowercased() != "all models", let used = number(limit["percent"]) else { continue }
            let label = model.uppercased() + " 7D"
            guard !windows.contains(where: { $0.label == label }) else { continue }
            windows.append(QuotaWindow(id: "scoped-\(model.lowercased())", label: label, usedFraction: fraction(used),
                                       resetsAt: isoDate(limit["resets_at"])))
        }
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = number(extra["utilization"]) {
            windows.append(QuotaWindow(id: "extra_usage", label: "EXTRA", usedFraction: fraction(used), resetsAt: nil))
        }
        return windows
    }

    /// `GET chatgpt.com/backend-api/wham/usage`: windows carry `used_percent`,
    /// `limit_window_seconds` and `reset_at` (Unix seconds).
    static func codexUsage(_ data: Data) -> (windows: [QuotaWindow], plan: String?) {
        guard let json = object(data) else { return ([], nil) }
        var windows = codexWindows(json["rate_limit"] as? [String: Any], prefix: "", id: "codex")
        for extra in json["additional_rate_limits"] as? [[String: Any]] ?? [] {
            // `GPT-5.3-Codex-Spark` → `SPARK`.
            guard let name = (extra["limit_name"] as? String)?.split(separator: "-").last.map(String.init),
                  !name.isEmpty else { continue }
            windows += codexWindows(extra["rate_limit"] as? [String: Any], prefix: name.uppercased() + " ",
                                    id: "codex-\(name.lowercased())")
        }
        return (windows, json["plan_type"] as? String)
    }

    /// A `token_count` event of a Codex rollout log, whose `payload.rate_limits` uses
    /// `window_minutes` and `resets_at` instead of the API's names.
    static func codexLogLine(_ line: Substring) -> AgentQuota? {
        guard line.contains("\"rate_limits\""), let json = object(Data(line.utf8)),
              let limits = (json["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }
        let windows = codexWindows(limits, prefix: "", id: "codex", span: ("window_minutes", 60), reset: "resets_at")
        guard !windows.isEmpty else { return nil }
        return AgentQuota(windows: windows, plan: limits["plan_type"] as? String,
                          capturedAt: isoDate(json["timestamp"]) ?? .distantPast, fromLog: true)
    }

    private static func codexWindows(_ limits: [String: Any]?, prefix: String, id: String,
                                     span: (key: String, seconds: Double) = ("limit_window_seconds", 1),
                                     reset: String = "reset_at") -> [QuotaWindow] {
        guard let limits else { return [] }
        return [("primary", ["primary_window", "primary"]), ("secondary", ["secondary_window", "secondary"])]
            .compactMap { name, keys in
                guard let window = keys.lazy.compactMap({ limits[$0] as? [String: Any] }).first,
                      let used = number(window["used_percent"]) else { return nil }
                let seconds = number(window[span.key]).map { $0 * span.seconds }
                return QuotaWindow(id: "\(id)-\(name)", label: prefix + (seconds.map(spanLabel) ?? name.uppercased()),
                                   usedFraction: fraction(used),
                                   resetsAt: number(window[reset]).map { Date(timeIntervalSince1970: $0) })
            }
    }

    /// `18000` → `5H`, `604800` → `7D`.
    static func spanLabel(_ seconds: Double) -> String {
        let hours = Int((seconds / 3600).rounded())
        return hours >= 24 && hours % 24 == 0 ? "\(hours / 24)D" : "\(max(1, hours))H"
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func fraction(_ percent: Double) -> Double { min(1, max(0, percent / 100)) }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// What a machine holds about its agents' sign-ins. Gathered by one read-only shell script, so
/// this Mac and an SSH machine are read the same way; the usage requests then leave from here.
struct AgentQuotaFiles: Equatable {
    var claudeInstalled = false
    /// `~/.claude/.credentials.json`, or else Claude Code's Keychain item when it was asked for.
    var claudeCredentials: Data?
    var claudeKeychainFailed = false
    var codexInstalled = false
    var codexAuth: Data?
    /// The last `token_count` event with rate limits in the newest Codex rollouts.
    var codexLogLine: String?
}

enum AgentQuotaProbe {
    /// A POSIX sh script printing `key=value` lines, file contents in base64. `keychain` also reads
    /// Claude Code's Keychain item through `security` when there is no credentials file; only an SSH
    /// machine asks for it, since wooloo reads this Mac's Keychain itself.
    static func script(keychain: Bool) -> String {
        """
        LC_ALL=C; export LC_ALL
        b64() { base64 | tr -d '\\n'; echo; }
        if [ -d "$HOME/.claude" ]; then
          echo "claude=1"
          if [ -r "$HOME/.claude/.credentials.json" ]; then
            printf 'claude_credentials='; b64 < "$HOME/.claude/.credentials.json"
          elif \(keychain ? "true" : "false") && command -v security >/dev/null 2>&1; then
            if item=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null); then
              printf 'claude_credentials='; printf '%s' "$item" | b64
            else
              echo "claude_keychain=failed"
            fi
          fi
        fi
        codex="${CODEX_HOME:-$HOME/.codex}"
        if [ -d "$codex" ]; then
          echo "codex=1"
          if [ -r "$codex/auth.json" ]; then printf 'codex_auth='; b64 < "$codex/auth.json"; fi
          for day in $(ls -d "$codex"/sessions/*/*/* 2>/dev/null | sort -r | head -n 3); do
            for file in $(ls -t "$day"/rollout-*.jsonl 2>/dev/null | head -n 3); do
              line=$(tail -c 1048576 "$file" | grep -F '"rate_limits":{' | tail -n 1)
              if [ -n "$line" ]; then printf 'codex_log='; printf '%s\\n' "$line" | b64; break 2; fi
            done
          done
        fi
        exit 0
        """
    }

    static func parse(_ output: String) -> AgentQuotaFiles {
        var files = AgentQuotaFiles()
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let data = Data(base64Encoded: value)
            switch line[..<equals] {
            case "claude": files.claudeInstalled = true
            case "claude_credentials": files.claudeCredentials = data
            case "claude_keychain": files.claudeKeychainFailed = true
            case "codex": files.codexInstalled = true
            case "codex_auth": files.codexAuth = data
            case "codex_log": files.codexLogLine = data.map { String(decoding: $0, as: UTF8.self) }
            default: break
            }
        }
        return files
    }

    /// Reads `machine`, or this Mac when nil; `environment` overrides this Mac's, for tests. On this
    /// Mac the Keychain is read by wooloo itself, so macOS names wooloo when it asks for permission
    /// and "Always Allow" does not open the item to every process that can run `security`.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func read(machine: HerdrMachineProfile?, keychain: Bool,
                     environment: [String: String] = [:],
                     readKeychain: () -> Data?? = AgentQuotaKeychain.claudeCredentials) throws -> AgentQuotaFiles {
        let script = script(keychain: keychain && machine != nil)
        let data: Data
        do {
            data = if let machine {
                try WorkspaceFiles.remoteOutput(machine, script: script, label: "agent-quotas", limit: 256_000)
            } else {
                try WorkspaceFiles.run("/bin/sh", ["-c", script], environment: environment, limit: 256_000,
                                       timeout: 30, label: "agent-quotas")
            }
        } catch let error as WorkspaceFileError {
            throw WorkspaceFileError.message(redacted(error.localizedDescription))
        }
        var files = parse(String(decoding: data, as: UTF8.self))
        if machine == nil, keychain, files.claudeInstalled, files.claudeCredentials == nil {
            switch readKeychain() {
            case .some(.some(let credentials)): files.claudeCredentials = credentials
            case .some(.none): files.claudeKeychainFailed = true
            case .none: break
            }
        }
        return files
    }

    /// A failed run reports its output when stderr is empty, and the script prints sign-ins as it
    /// goes, so such a message never reaches the sidebar.
    static func redacted(_ message: String) -> String {
        let secretKeys = ["claude_credentials=", "codex_auth=", "codex_log="]
        return secretKeys.contains { message.contains($0) } ? "Could not read the agents' sign-ins" : message
    }
}

/// Claude Code's sign-in in this Mac's Keychain, read in-process.
enum AgentQuotaKeychain {
    /// The item's data; `.some(nil)` when it exists but cannot be read, nil when there is none.
    static func claudeCredentials() -> Data?? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .some(result as? Data)
        case errSecItemNotFound: return .none
        default: return .some(nil)
        }
    }
}

/// Reads the quotas of one machine's Claude Code and Codex sign-ins. It only reads their
/// credentials and never refreshes them: a refresh rotates the refresh token and would sign the
/// agent out, so an expired token waits until the agent itself renews it.
actor AgentQuotaReader {
    private let machine: HerdrMachineProfile?
    private let environment: [String: String]
    private var claudeCredential: AgentQuotaParser.ClaudeCredential?
    /// A token the usage endpoint rejected; it is not sent again.
    private var rejectedClaudeToken: String?
    /// Keychain reads are spaced out, since a changed item ACL can make each one ask for permission.
    private var nextKeychainRead = Date.distantPast

    private static let session = URLSession(configuration: .ephemeral)

    init(machine: HerdrMachineProfile? = nil, environment: [String: String] = [:]) {
        self.machine = machine
        self.environment = environment
    }

    /// A nil quota means the agent is not set up on the machine.
    func read(now: Date = Date()) async -> [AgentProvider: Result<AgentQuota?, Error>] {
        let needsCredential = claudeCredential.map { $0.isExpired(at: now) || $0.token == rejectedClaudeToken } ?? true
        let keychain = needsCredential && now >= nextKeychainRead
        if keychain { nextKeychainRead = now.addingTimeInterval(5 * 60) }
        let files: AgentQuotaFiles
        do {
            files = try await WorkspaceFiles.blocking(on: machine) { [machine, environment] in
                try AgentQuotaProbe.read(machine: machine, keychain: keychain, environment: environment)
            }
        } catch {
            return [.claude: .failure(error), .codex: .failure(error)]
        }
        if files.claudeKeychainFailed { nextKeychainRead = now.addingTimeInterval(15 * 60) }
        async let claude = Self.outcome { try await self.claude(files, now: now) }
        async let codex = Self.outcome { try await self.codex(files, now: now) }
        return [.claude: await claude, .codex: await codex]
    }

    private static func outcome(_ body: @Sendable () async throws -> AgentQuota?) async -> Result<AgentQuota?, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func claude(_ files: AgentQuotaFiles, now: Date) async throws -> AgentQuota? {
        guard files.claudeInstalled else { return nil }
        if let credential = files.claudeCredentials.flatMap(AgentQuotaParser.claudeCredential) {
            claudeCredential = credential
        }
        guard let credential = claudeCredential else {
            throw quotaError(files.claudeKeychainFailed ? "Claude Code's Keychain item is not readable"
                                                        : "Not signed in to Claude Code")
        }
        guard !credential.isExpired(at: now), credential.token != rejectedClaudeToken else {
            throw quotaError("Claude Code's sign-in has expired; it renews when Claude Code runs")
        }
        let data: Data
        do {
            data = try await Self.get("https://api.anthropic.com/api/oauth/usage", headers: [
                "Authorization": "Bearer \(credential.token)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        } catch QuotaFetchError.unauthorized {
            rejectedClaudeToken = credential.token
            throw quotaError("Claude Code's sign-in was rejected; it renews when Claude Code runs")
        }
        let windows = AgentQuotaParser.claudeUsage(data)
        guard !windows.isEmpty else { throw quotaError("Unreadable Claude usage") }
        return AgentQuota(windows: windows, plan: credential.plan, capturedAt: now)
    }

    /// Falls back to the newest session log when the usage endpoint cannot be reached or the
    /// sign-in has expired.
    private func codex(_ files: AgentQuotaFiles, now: Date) async throws -> AgentQuota? {
        guard files.codexInstalled else { return nil }
        var failure = quotaError("Not signed in to Codex with ChatGPT")
        if let credential = files.codexAuth.flatMap(AgentQuotaParser.codexCredential) {
            if let expiry = credential.expiresAt, expiry <= now.addingTimeInterval(60) {
                failure = quotaError("Codex's sign-in has expired; it renews when Codex runs")
            } else {
                do {
                    var headers = ["Authorization": "Bearer \(credential.token)", "User-Agent": "codex-cli"]
                    headers["ChatGPT-Account-Id"] = credential.accountID
                    let usage = AgentQuotaParser.codexUsage(
                        try await Self.get("https://chatgpt.com/backend-api/wham/usage", headers: headers))
                    guard !usage.windows.isEmpty else { throw quotaError("Unreadable Codex usage") }
                    return AgentQuota(windows: usage.windows, plan: usage.plan, capturedAt: now)
                } catch {
                    failure = error
                }
            }
        }
        if let logged = files.codexLogLine.flatMap({ AgentQuotaParser.codexLogLine(Substring($0)) }) {
            return logged
        }
        throw failure
    }

    private enum QuotaFetchError: Error { case unauthorized }

    private static func get(_ url: String, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw QuotaFetchError.unauthorized
        case 429: throw WorkspaceFileError.message("Usage requests are rate limited; retrying later")
        case let status: throw WorkspaceFileError.message("Usage request failed (HTTP \(status))")
        }
    }

    private func quotaError(_ message: String) -> Error { WorkspaceFileError.message(message) }
}

/// Polls one machine's agents while at least one sidebar section shows them. There is one per
/// machine, shared by every window so several windows do not multiply the requests, and it is
/// kept out of `HerdrStore` so an update only redraws the section.
@MainActor
final class AgentQuotaMonitor: ObservableObject {
    struct State: Equatable {
        var quota: AgentQuota?
        var failure: String?
    }

    private static var monitors: [String: AgentQuotaMonitor] = [:]
    /// Tests turn it off and fill `states` themselves, so views never read real sign-ins.
    static var isPollingEnabled = true

    /// The monitor of `machine`, or of this Mac when nil.
    static func shared(for machine: HerdrMachineProfile?) -> AgentQuotaMonitor {
        let key = machine?.id ?? ""
        if let monitor = monitors[key], monitor.machine == machine { return monitor }
        let monitor = AgentQuotaMonitor(machine: machine)
        monitors[key]?.stop()
        monitors[key] = monitor
        return monitor
    }

    let machine: HerdrMachineProfile?
    /// Agents without an entry are not set up on the machine.
    @Published private(set) var states: [AgentProvider: State] = [:]
    @Published private(set) var loaded = false
    private let reader: AgentQuotaReader
    private let interval: Duration
    private var users = 0
    private var task: Task<Void, Never>?
    private var lastFetch: ContinuousClock.Instant?

    init(machine: HerdrMachineProfile? = nil, reader: AgentQuotaReader? = nil, interval: Duration = .seconds(120)) {
        self.machine = machine
        self.reader = reader ?? AgentQuotaReader(machine: machine)
        self.interval = interval
    }

    func acquire() {
        users += 1
        guard task == nil, Self.isPollingEnabled else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Reopening the section does not fetch again before the interval has passed.
                if let self, let last = self.lastFetch {
                    let wait = self.interval - (ContinuousClock.now - last)
                    if wait > .zero { try? await Task.sleep(for: wait) }
                }
                guard !Task.isCancelled, let self else { return }
                self.lastFetch = .now
                await self.refresh()
            }
        }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { stop() }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh() async {
        let results = await reader.read()
        guard !Task.isCancelled else { return }
        for provider in AgentProvider.allCases { apply(provider, results[provider] ?? .success(nil)) }
        if !loaded { loaded = true }
    }

    func apply(_ provider: AgentProvider, _ result: Result<AgentQuota?, Error>) {
        let next: State?
        switch result {
        case .success(let quota): next = quota.map { State(quota: $0) }
        // Keeps the last reading visible, marked as old, while the source fails.
        case .failure(let error): next = State(quota: states[provider]?.quota, failure: error.localizedDescription)
        }
        if states[provider] != next { states[provider] = next }
    }
}

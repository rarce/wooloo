import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Darwin
import Foundation
import Security

/// How this Mac's SSH is published through Cloudflare. A quick tunnel needs no account and gets a
/// new `trycloudflare.com` address on every start; a named tunnel keeps the hostname set up in
/// Cloudflare and can sit behind Cloudflare Access.
enum RemoteAccessMode: String, CaseIterable, Identifiable {
    case quick, named

    var id: Self { self }
    var title: String {
        switch self {
        case .quick: "Quick tunnel"
        case .named: "Named tunnel"
        }
    }
}

/// What `cloudflared` writes to stderr while a tunnel starts.
enum RemoteAccessTunnelLog {
    /// The quick tunnel's address, printed once in a banner.
    static func quickHostname(in line: String) -> String? {
        guard let range = line.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression)
        else { return nil }
        return String(line[range].dropFirst("https://".count))
    }

    /// Cloudflare's edge accepted a connection, so the hostname now reaches this Mac.
    static func isConnected(_ line: String) -> Bool {
        line.contains("Registered tunnel connection")
    }

    /// An error line, without its timestamp and level.
    static func error(in line: String) -> String? {
        guard let range = line.range(of: " ERR ") else { return nil }
        let message = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : message
    }
}

/// Connection links shared with another device, over direct SSH or the local Mac's tunnel.
enum RemoteAccessLink {
    enum Transport: String {
        case ssh, cloudflare
    }

    /// Opens the Android app's host editor prefilled; the Android camera opens it from the QR code.
    static func herdroid(hostname: String, user: String, session: String, label: String,
                         herdrPath: String?, fingerprints: [String],
                         transport: Transport = .cloudflare, port: Int = 22) -> URL? {
        var components = URLComponents()
        components.scheme = "herdroid"
        components.host = "add-host"
        var items = [URLQueryItem(name: "transport", value: transport.rawValue),
                     URLQueryItem(name: "host", value: hostname),
                     URLQueryItem(name: "user", value: user),
                     URLQueryItem(name: "session", value: session),
                     URLQueryItem(name: "label", value: label)]
        if transport == .ssh { items.append(URLQueryItem(name: "port", value: String(port))) }
        if let herdrPath { items.append(URLQueryItem(name: "herdr", value: herdrPath)) }
        items += fingerprints.map { URLQueryItem(name: "fp", value: $0) }
        components.queryItems = items
        // URLComponents leaves "+" and "/" of base64 fingerprints unescaped in queries.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// OpenSSH from another computer, through `cloudflared access`.
    static func sshCommand(hostname: String, user: String) -> String {
        "ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" \(user)@\(hostname)"
    }

    /// The hostname alone from a pasted URL such as `https://ssh.example.com/`.
    static func normalizedHostname(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        return host.lowercased()
    }

    static func qrImage(for url: URL, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}

/// This Mac's SSH host keys, so a client can trust the server it reaches through the tunnel.
enum RemoteAccessHostKeys {
    /// `SHA256:` fingerprints, as OpenSSH prints them, of the public host keys in `directory`.
    static func fingerprints(in directory: URL = URL(fileURLWithPath: "/etc/ssh")) -> [String] {
        let names = ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub", "ssh_host_rsa_key.pub"]
        return names.compactMap { name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            return fingerprint(ofPublicKeyLine: text)
        }
    }

    static func fingerprint(ofPublicKeyLine line: String) -> String? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Which sign-in methods this Mac's SSH server offers a client that arrives the way tunnel
/// clients do: `cloudflared` connects to `localhost:22`, so sshd sees every tunnel client as a
/// connection from this Mac, and a probe from here meets the same `Match Address` rules.
enum RemoteAccessSSHCheck: Equatable {
    /// Only key-based methods, such as `publickey`, for `user`.
    case keysOnly(user: String, methods: [String])
    /// `password` or `keyboard-interactive`, which on macOS asks for the account password.
    case acceptsPasswords(user: String, methods: [String])
    /// sshd let `user` in without any password or key.
    case acceptsNoCredential(user: String)
    /// The methods could not be learned, so nothing is known about passwords.
    case unknown(reason: String)

    static let passwordMethods: Set<String> = ["password", "keyboard-interactive"]

    /// Only a verified key-only server starts without asking.
    var isVerifiedKeysOnly: Bool {
        if case .keysOnly = self { true } else { false }
    }

    /// A server that lets anyone in is never published.
    var refusesStart: Bool {
        if case .acceptsNoCredential = self { true } else { false }
    }

    /// What the check found, for the settings and the confirmation.
    var summary: String {
        switch self {
        case .keysOnly(let user, let methods):
            "Checked: this Mac's SSH server offers \(user) only key sign-in (\(methods.joined(separator: ", "))) "
                + "to connections like the tunnel's. Other accounts on this Mac were not checked."
        case .acceptsPasswords(let user, let methods):
            "Checked: this Mac's SSH server accepts a password for \(user) (\(methods.joined(separator: ", "))). "
                + "Anyone who reaches the tunnel's address can try to guess it."
        case .acceptsNoCredential(let user):
            "This Mac's SSH server let \(user) in without a password or key, so wooloo will not publish it."
        case .unknown(let reason):
            "Could not check which sign-in methods this Mac's SSH server accepts (\(reason)), "
                + "so wooloo cannot tell whether it accepts passwords."
        }
    }
}

/// Asks this Mac's SSH server which methods it offers, without sending any credential: `ssh`
/// offers only the `none` method, which sshd refuses with the list of methods it would accept.
/// sshd may log the attempt as a failed sign-in.
enum RemoteAccessSSHProbe {
    static func arguments(user: String, port: UInt16 = 22) -> [String] {
        // No user configuration, agent, key, known_hosts file or prompt is used.
        ["-F", "/dev/null", "-p", String(port),
         "-o", "BatchMode=yes", "-o", "PreferredAuthentications=none", "-o", "PubkeyAuthentication=no",
         "-o", "GSSAPIAuthentication=no", "-o", "IdentityAgent=none", "-o", "NumberOfPasswordPrompts=0",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
         "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5",
         "-T", "\(user)@127.0.0.1", "true"]
    }

    /// The check from `ssh`'s outcome: nil `failure` when it signed in.
    static func result(user: String, failure: String?) -> RemoteAccessSSHCheck {
        guard let failure else { return .acceptsNoCredential(user: user) }
        guard let range = failure.range(of: #"Permission denied \(([^)]*)\)"#, options: .regularExpression) else {
            let line = failure.split(separator: "\n").last.map(String.init) ?? failure
            return .unknown(reason: line.trimmingCharacters(in: .whitespaces).isEmpty ? "no answer" : line)
        }
        let list = failure[range].dropFirst("Permission denied (".count).dropLast()
        let methods = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !methods.isEmpty else { return .unknown(reason: "sshd listed no sign-in methods") }
        return methods.contains(where: RemoteAccessSSHCheck.passwordMethods.contains)
            ? .acceptsPasswords(user: user, methods: methods)
            : .keysOnly(user: user, methods: methods)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func check(user: String = NSUserName(), ssh: String = "/usr/bin/ssh") -> RemoteAccessSSHCheck {
        guard FileManager.default.isExecutableFile(atPath: ssh) else { return .unknown(reason: "\(ssh) is missing") }
        do {
            _ = try WorkspaceFiles.run(ssh, arguments(user: user), limit: 16_000, timeout: 15,
                                       label: "remote-access-ssh-check")
            return result(user: user, failure: nil)
        } catch {
            return result(user: user, failure: error.localizedDescription)
        }
    }
}

/// The named tunnel's token in this Mac's Keychain. It is a credential for the tunnel, so it is
/// neither stored in defaults nor passed on the command line.
struct RemoteAccessTokenStore {
    var load: () -> String?
    var save: (String?) -> Void

    static let keychain = RemoteAccessTokenStore(load: {
        var result: CFTypeRef?
        let request = query(with: [kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true])
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }, save: { token in
        SecItemDelete(query() as CFDictionary)
        guard let token, !token.isEmpty else { return }
        let item = query(with: [kSecValueData as String: Data(token.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly])
        SecItemAdd(item as CFDictionary, nil)
    })

    private static func query(with extra: [String: Any] = [:]) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.wooloo.remote-access",
         kSecAttrAccount as String: "cloudflare-tunnel-token"].merging(extra) { $1 }
    }
}

enum RemoteAccessSystem {
    static var cloudflaredCandidates: [String] {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cloudflared").path]
    }

    static func cloudflared() -> String? {
        cloudflaredCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Whether something accepts connections on this Mac's SSH port, which Remote Login opens.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    nonisolated static func acceptsSSH(port: UInt16 = 22) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Whether Cloudflare's own nameservers already answer for a new quick tunnel hostname. Asking
    /// them directly caches nothing: a resolver asked too early caches the miss for a minute
    /// (the zone's negative TTL), and a phone scanning the QR code then cannot connect.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    nonisolated static func isPublished(_ hostname: String) -> Bool {
        guard let zone = hostname.split(separator: ".", maxSplits: 1).last.map(String.init),
              let servers = try? WorkspaceFiles.run("/usr/bin/dig", ["+short", "NS", zone], limit: 16_000),
              let server = String(decoding: servers, as: UTF8.self).split(separator: "\n").first,
              let answer = try? WorkspaceFiles.run("/usr/bin/dig", ["+short", "+time=2", "@" + server, hostname, "A"],
                                                   limit: 16_000)
        else { return false }
        return !String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var herdrExecutable: String? {
        HerdrRuntimePaths.executableCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// Runs `cloudflared` to publish this Mac's SSH, which remote SSH clients use to
/// run Herdr's own commands. The tunnel belongs to wooloo: it stops when wooloo quits.
/// Before publishing, it checks which sign-in methods sshd offers (`RemoteAccessSSHCheck`):
/// a verified key-only server starts at once; otherwise the user must confirm, and a start at
/// launch, which nobody is there to confirm, does not happen. It never changes sshd's settings.
@MainActor
final class RemoteAccessModel: ObservableObject {
    static let shared = RemoteAccessModel()
    static let modeKey = "RemoteAccessMode"
    static let hostnameKey = "RemoteAccessHostname"
    static let startsAtLaunchKey = "RemoteAccessStartsAtLaunch"

    enum State: Equatable {
        case stopped
        /// Asking sshd which sign-in methods it offers, before anything is published.
        case checking
        /// The check did not find key-only SSH; nothing is published until the user confirms.
        case needsConfirmation(RemoteAccessSSHCheck)
        case starting
        case running(hostname: String)
        case failed(String)
    }

    @Published private(set) var state = State.stopped
    @Published var mode: RemoteAccessMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// The named tunnel's public hostname, whose service in Cloudflare is `ssh://localhost:22`.
    @Published var hostname: String {
        didSet { defaults.set(hostname, forKey: Self.hostnameKey) }
    }
    @Published var startsAtLaunch: Bool {
        didSet { defaults.set(startsAtLaunch, forKey: Self.startsAtLaunchKey) }
    }
    @Published private(set) var hasToken: Bool
    /// nil until checked.
    @Published private(set) var acceptsSSH: Bool?
    /// The last check of sshd's sign-in methods; nil until checked.
    @Published private(set) var sshCheck: RemoteAccessSSHCheck?
    /// Whether the running tunnel was started on the user's word rather than a key-only check.
    @Published private(set) var startedWithoutVerifiedKeys = false

    private let defaults: UserDefaults
    private let tokens: RemoteAccessTokenStore
    private let executable: () -> String?
    private let isPublished: @Sendable (String) -> Bool
    private let checkSSHSignIn: @Sendable () -> RemoteAccessSSHCheck
    private var process: Process?
    /// Callbacks from an earlier process are ignored.
    private var generation = 0
    private var quickHostname: String?
    private var isRegistered = false
    private var isWaitingForDNS = false
    private var lastError: String?
    /// The process's output and, once known, its exit: the exit is reported after the output has
    /// ended, so its last error line, such as a quick tunnel refused with 429, comes first.
    private var output: FileHandle?
    private var exitStatus: Int32?
    private var outputEnded = false

    init(defaults: UserDefaults = .standard, tokens: RemoteAccessTokenStore = .keychain,
         executable: @escaping () -> String? = RemoteAccessSystem.cloudflared,
         isPublished: @escaping @Sendable (String) -> Bool = RemoteAccessSystem.isPublished,
         checkSSHSignIn: @escaping @Sendable () -> RemoteAccessSSHCheck = { RemoteAccessSSHProbe.check() }) {
        self.defaults = defaults
        self.tokens = tokens
        self.executable = executable
        self.isPublished = isPublished
        self.checkSSHSignIn = checkSSHSignIn
        mode = defaults.string(forKey: Self.modeKey).flatMap(RemoteAccessMode.init) ?? .quick
        hostname = defaults.string(forKey: Self.hostnameKey) ?? ""
        startsAtLaunch = defaults.bool(forKey: Self.startsAtLaunchKey)
        hasToken = tokens.load() != nil
    }

    var isActive: Bool {
        switch state {
        case .checking, .starting, .running: true
        case .stopped, .needsConfirmation, .failed: false
        }
    }

    var cloudflaredPath: String? { executable() }

    var runningHostname: String? {
        if case .running(let hostname) = state { hostname } else { nil }
    }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens.save(trimmed.isEmpty ? nil : trimmed)
        hasToken = !trimmed.isEmpty
    }

    /// Whether Remote Login is on and, if so, which sign-in methods sshd offers.
    func checkSSH() {
        let checkSSHSignIn = checkSSHSignIn
        Task {
            // nil when cancelled.
            guard let accepts = await BlockingWork.run({ Optional(RemoteAccessSystem.acceptsSSH()) }) else { return }
            if acceptsSSH != accepts { acceptsSSH = accepts }
            guard accepts, let check = await BlockingWork.run({ Optional(checkSSHSignIn()) }) else { return }
            if sshCheck != check { sshCheck = check }
        }
    }

    /// The arguments and extra environment for the current mode.
    static func command(mode: RemoteAccessMode, token: String?) -> (arguments: [String], environment: [String: String]) {
        // A short grace period, so quitting wooloo does not leave cloudflared draining for 30 s.
        let common = ["tunnel", "--no-autoupdate", "--grace-period", "2s"]
        switch mode {
        case .quick: return (common + ["--url", "ssh://localhost:22"], [:])
        case .named: return (common + ["run"], ["TUNNEL_TOKEN": token ?? ""])
        }
    }

    /// Checks sshd, then publishes it if it offers only key sign-in; otherwise waits in
    /// `.needsConfirmation` for `startDespiteCheck` or `cancelStart`.
    func start() {
        start(unattended: false)
    }

    /// Starts the tunnel as wooloo opens: only after a key-only check, since nobody is there to
    /// confirm anything else.
    func startAtLaunch() {
        start(unattended: true)
    }

    /// Publishes sshd although the check did not find it key-only, because the user said so.
    /// That is the user's decision, not a check: the status keeps saying so.
    func startDespiteCheck() {
        guard case .needsConfirmation(let check) = state, !check.refusesStart else { return }
        guard let prepared = prepare() else { return }
        launch(path: prepared.path, token: prepared.token, verified: false)
    }

    /// Leaves the tunnel off after a check that asked for confirmation.
    func cancelStart() {
        guard case .needsConfirmation = state else { return }
        state = .stopped
    }

    private func start(unattended: Bool) {
        guard !isActive else { return }
        guard prepare() != nil else { return }
        generation += 1
        let generation = generation
        state = .checking
        let checkSSHSignIn = checkSSHSignIn
        Task {
            let check = await BlockingWork.run({ Optional(checkSSHSignIn()) })
                ?? .unknown(reason: "the check was cancelled")
            guard self.generation == generation, state == .checking else { return }
            sshCheck = check
            if check.isVerifiedKeysOnly {
                // The settings may have changed while checking.
                guard let prepared = prepare() else { return }
                launch(path: prepared.path, token: prepared.token, verified: true)
            } else if check.refusesStart {
                state = .failed(check.summary)
            } else if unattended {
                // Shown in Settings and in the sidebar mark that opens them, so it names no way there.
                state = .failed("Not started when wooloo opened: \(check.summary)")
            } else {
                state = .needsConfirmation(check)
            }
        }
    }

    /// The executable and the named tunnel's token, or nil after reporting what is missing.
    private func prepare() -> (path: String, token: String?)? {
        guard let path = executable() else {
            state = .failed("cloudflared was not found. Install it with `brew install cloudflared`.")
            return nil
        }
        let token = mode == .named ? tokens.load() : nil
        if mode == .named {
            guard token != nil else { state = .failed("Paste the tunnel token from Cloudflare first."); return nil }
            guard !RemoteAccessLink.normalizedHostname(hostname).isEmpty else {
                state = .failed("Enter the tunnel's public hostname first.")
                return nil
            }
        }
        return (path, token)
    }

    private func launch(path: String, token: String?, verified: Bool) {
        let command = Self.command(mode: mode, token: token)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TUNNEL_TOKEN")
        environment.merge(command.environment) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        generation += 1
        let generation = generation
        quickHostname = nil
        isRegistered = false
        isWaitingForDNS = false
        lastError = nil
        exitStatus = nil
        outputEnded = false
        self.output?.readabilityHandler = nil
        self.output = output.fileHandleForReading
        let lines = RemoteAccessLineBuffer()
        // Lines, the end of the output and the exit go through the main queue, in order, rather
        // than tasks, which may run out of order.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let complete: [String]
            if data.isEmpty {
                handle.readabilityHandler = nil
                guard let rest = lines.finish() else { return }
                complete = rest
            } else {
                complete = lines.append(data)
                guard !complete.isEmpty else { return }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    complete.forEach(self.handle)
                    if data.isEmpty {
                        self.outputEnded = true
                        self.reportExit()
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.exitStatus = status
                    self.reportExit()
                }
            }
            // A child that inherited the pipe can keep it open: give up on the rest a second
            // after the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, !self.outputEnded else { return }
                    self.output?.readabilityHandler = nil
                    self.outputEnded = true
                    self.reportExit()
                }
            }
        }
        do {
            try process.run()
            self.process = process
            startedWithoutVerifiedKeys = !verified
            state = .starting
            checkSSH()
        } catch {
            state = .failed("Could not start cloudflared: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        startedWithoutVerifiedKeys = false
        process?.terminate()
        process = nil
        output?.readabilityHandler = nil
        output = nil
        state = .stopped
    }

    /// Reports the exit once the output has ended too.
    private func reportExit() {
        guard let exitStatus, outputEnded, process != nil else { return }
        process = nil
        output = nil
        state = .failed(lastError ?? "cloudflared exited with status \(exitStatus).")
    }

    private func handle(_ line: String) {
        if let hostname = RemoteAccessTunnelLog.quickHostname(in: line) { quickHostname = hostname }
        if let error = RemoteAccessTunnelLog.error(in: line) { lastError = error }
        if RemoteAccessTunnelLog.isConnected(line) { isRegistered = true }
        guard isRegistered, state == .starting, !isWaitingForDNS else { return }
        switch mode {
        case .quick:
            guard let quickHostname else { return }
            isWaitingForDNS = true
            let generation = generation
            Task {
                await waitUntilPublished(quickHostname)
                guard self.generation == generation, state == .starting else { return }
                state = .running(hostname: quickHostname)
            }
        case .named:
            state = .running(hostname: RemoteAccessLink.normalizedHostname(hostname))
        }
    }

    /// Up to a minute; after that the tunnel is shown anyway.
    private func waitUntilPublished(_ hostname: String) async {
        let isPublished = isPublished
        for _ in 0..<30 {
            // nil, and stops waiting, when cancelled.
            if await BlockingWork.run({ Optional(isPublished(hostname)) }) ?? true { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

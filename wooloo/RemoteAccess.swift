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

/// The addresses another device uses to reach this Mac's Herdr through the tunnel.
enum RemoteAccessLink {
    /// Opens the Android app's host editor prefilled; the Android camera opens it from the QR code.
    static func herdroid(hostname: String, user: String, session: String, label: String,
                         herdrPath: String?, fingerprints: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "herdroid"
        components.host = "add-host"
        var items = [URLQueryItem(name: "transport", value: "cloudflare"),
                     URLQueryItem(name: "host", value: hostname),
                     URLQueryItem(name: "user", value: user),
                     URLQueryItem(name: "session", value: session),
                     URLQueryItem(name: "label", value: label)]
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
@MainActor
final class RemoteAccessModel: ObservableObject {
    static let shared = RemoteAccessModel()
    static let modeKey = "RemoteAccessMode"
    static let hostnameKey = "RemoteAccessHostname"
    static let startsAtLaunchKey = "RemoteAccessStartsAtLaunch"

    enum State: Equatable {
        case stopped
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

    private let defaults: UserDefaults
    private let tokens: RemoteAccessTokenStore
    private let executable: () -> String?
    private let isPublished: @Sendable (String) -> Bool
    private var process: Process?
    /// Callbacks from an earlier process are ignored.
    private var generation = 0
    private var quickHostname: String?
    private var isRegistered = false
    private var isWaitingForDNS = false
    private var lastError: String?

    init(defaults: UserDefaults = .standard, tokens: RemoteAccessTokenStore = .keychain,
         executable: @escaping () -> String? = RemoteAccessSystem.cloudflared,
         isPublished: @escaping @Sendable (String) -> Bool = RemoteAccessSystem.isPublished) {
        self.defaults = defaults
        self.tokens = tokens
        self.executable = executable
        self.isPublished = isPublished
        mode = defaults.string(forKey: Self.modeKey).flatMap(RemoteAccessMode.init) ?? .quick
        hostname = defaults.string(forKey: Self.hostnameKey) ?? ""
        startsAtLaunch = defaults.bool(forKey: Self.startsAtLaunchKey)
        hasToken = tokens.load() != nil
    }

    var isActive: Bool {
        switch state {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    var cloudflaredPath: String? { executable() }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens.save(trimmed.isEmpty ? nil : trimmed)
        hasToken = !trimmed.isEmpty
    }

    func checkSSH() {
        Task {
            let accepts = await BlockingWork.run { RemoteAccessSystem.acceptsSSH() }
            if acceptsSSH != accepts { acceptsSSH = accepts }
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

    func start() {
        guard !isActive else { return }
        guard let path = executable() else {
            state = .failed("cloudflared was not found. Install it with `brew install cloudflared`.")
            return
        }
        let token = mode == .named ? tokens.load() : nil
        if mode == .named {
            guard token != nil else { state = .failed("Paste the tunnel token from Cloudflare first."); return }
            guard !RemoteAccessLink.normalizedHostname(hostname).isEmpty else {
                state = .failed("Enter the tunnel's public hostname first.")
                return
            }
        }
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
        let lines = RemoteAccessLineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let complete = lines.append(data)
            guard !complete.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                complete.forEach(self.handle)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.process = nil
                self.state = .failed(self.lastError ?? "cloudflared exited with status \(status).")
            }
        }
        do {
            try process.run()
            self.process = process
            state = .starting
            checkSSH()
        } catch {
            state = .failed("Could not start cloudflared: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        process?.terminate()
        process = nil
        state = .stopped
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
            if await BlockingWork.run({ isPublished(hostname) }) { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Splits a process's output into lines across reads.
private final class RemoteAccessLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[..<last]
        pending = Data(pending[(last + 1)...])
        return String(decoding: complete, as: UTF8.self).components(separatedBy: "\n")
    }
}

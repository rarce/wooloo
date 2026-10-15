import XCTest
@testable import wooloo

@MainActor
final class RemoteAccessTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var token: String?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "RemoteAccessTests-\(UUID().uuidString)")
        token = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: cloudflared's output

    func testReadsTheQuickTunnelHostnameFromTheBanner() {
        let line = "2026-10-07T14:09:27Z INF |  https://wanna-cricket-jay-losing.trycloudflare.com                                 |"
        XCTAssertEqual(RemoteAccessTunnelLog.quickHostname(in: line), "wanna-cricket-jay-losing.trycloudflare.com")
        XCTAssertNil(RemoteAccessTunnelLog.quickHostname(in: "2026-10-07T14:09:27Z INF Requesting new quick Tunnel on trycloudflare.com..."))
    }

    func testRecognizesRegisteredConnectionsAndErrors() {
        XCTAssertTrue(RemoteAccessTunnelLog.isConnected(
            "2026-10-07T14:09:29Z INF Registered tunnel connection connIndex=0 connection=54fc event=0 location=scl04 protocol=quic"))
        XCTAssertEqual(RemoteAccessTunnelLog.error(in: "2026-10-07T14:09:29Z ERR failed to request quick Tunnel: 429 Too Many Requests"),
                       "failed to request quick Tunnel: 429 Too Many Requests")
        XCTAssertNil(RemoteAccessTunnelLog.error(in: "2026-10-07T14:09:29Z INF Starting tunnel"))
    }

    // MARK: Links

    func testHerdroidLinkCarriesTheConnectionAndEscapesFingerprints() throws {
        let url = try XCTUnwrap(RemoteAccessLink.herdroid(
            hostname: "a-b.trycloudflare.com", user: "me", session: "default", label: "Ada's Mac",
            herdrPath: "/Users/me/.local/bin/herdr", fingerprints: ["SHA256:ab+c/d", "SHA256:xyz"]))
        XCTAssertTrue(url.absoluteString.hasPrefix("herdroid://add-host?transport=cloudflare&host=a-b.trycloudflare.com"))
        XCTAssertTrue(url.absoluteString.contains("fp=SHA256:ab%2Bc/d&fp=SHA256:xyz"), url.absoluteString)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "label" }?.value, "Ada's Mac")
        XCTAssertEqual(items.first { $0.name == "herdr" }?.value, "/Users/me/.local/bin/herdr")
        XCTAssertEqual(items.filter { $0.name == "fp" }.map(\.value), ["SHA256:ab+c/d", "SHA256:xyz"])
    }

    func testNormalizesPastedHostnames() {
        XCTAssertEqual(RemoteAccessLink.normalizedHostname(" https://SSH.example.com/path \n"), "ssh.example.com")
        XCTAssertEqual(RemoteAccessLink.normalizedHostname("ssh.example.com"), "ssh.example.com")
    }

    func testFingerprintsMatchOpenSSH() throws {
        // `ssh-keygen -lf` prints SHA256:lfPaKzZw8nfzEEUg5v3/z//Ygs88PEFWZsjdzwAM2MI for this key.
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPL0n3RNg08SCe1ezkGWADmJUd0dqkjBMG/0hF2rKRlT test\n"
        try line.write(to: directory.appendingPathComponent("ssh_host_ed25519_key.pub"), atomically: true, encoding: .utf8)
        try "not a key".write(to: directory.appendingPathComponent("ssh_host_rsa_key.pub"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RemoteAccessHostKeys.fingerprints(in: directory),
                       ["SHA256:lfPaKzZw8nfzEEUg5v3/z//Ygs88PEFWZsjdzwAM2MI"])
    }

    func testNamedTunnelTokenStaysOffTheCommandLine() {
        let named = RemoteAccessModel.command(mode: .named, token: "secret-token")
        XCTAssertFalse(named.arguments.contains("secret-token"))
        XCTAssertEqual(named.environment["TUNNEL_TOKEN"], "secret-token")
        XCTAssertEqual(named.arguments.last, "run")
        XCTAssertEqual(RemoteAccessModel.command(mode: .quick, token: nil).arguments.suffix(2), ["--url", "ssh://localhost:22"])
    }

    // MARK: The tunnel process

    func testQuickTunnelRunsOnceCloudflareRegistersItAndStops() async throws {
        let model = makeModel(script: """
            echo "2026-10-07T14:09:27Z INF |  https://fake-host.trycloudflare.com  |" >&2
            echo "2026-10-07T14:09:28Z INF Registered tunnel connection connIndex=0" >&2
            exec sleep 30
            """)
        model.start()
        XCTAssertEqual(model.state, .checking, "sshd is checked before anything is published")
        try await waitFor { model.state == .running(hostname: "fake-host.trycloudflare.com") }
        XCTAssertFalse(model.startedWithoutVerifiedKeys)
        XCTAssertEqual(model.sshCheck, keysOnly)
        model.stop()
        XCTAssertEqual(model.state, .stopped)
        XCTAssertFalse(model.isActive)
    }

    func testAnExitedTunnelReportsCloudflaredsLastError() async throws {
        let model = makeModel(script: """
            echo "2026-10-07T14:09:27Z ERR failed to request quick Tunnel: 429 Too Many Requests" >&2
            exit 1
            """)
        model.start()
        try await waitFor { model.state == .failed("failed to request quick Tunnel: 429 Too Many Requests") }
    }

    func testAnExitedTunnelReportsALastErrorWithoutANewline() async throws {
        let model = makeModel(script: """
            printf '2026-10-07T14:09:27Z ERR failed to request quick Tunnel: 429 Too Many Requests' >&2
            exit 1
            """)
        model.start()
        try await waitFor { model.state == .failed("failed to request quick Tunnel: 429 Too Many Requests") }
    }

    func testAnExitedTunnelReportsItsErrorWhileAChildKeepsItsOutputOpen() async throws {
        let model = makeModel(script: """
            sleep 30 &
            echo "2026-10-07T14:09:27Z ERR failed to request quick Tunnel: 429 Too Many Requests" >&2
            exit 1
            """)
        model.start()
        try await waitFor { model.state == .failed("failed to request quick Tunnel: 429 Too Many Requests") }
    }

    func testNamedTunnelPassesItsTokenAndReportsItsHostname() async throws {
        let model = makeModel(script: """
            [ "$TUNNEL_TOKEN" = "token-123" ] || exit 3
            echo "2026-10-07T14:09:28Z INF Registered tunnel connection connIndex=0" >&2
            exec sleep 30
            """)
        model.mode = .named
        model.start()
        XCTAssertEqual(model.state, .failed("Paste the tunnel token from Cloudflare first."))
        model.setToken("  token-123\n")
        XCTAssertEqual(token, "token-123")
        model.hostname = "https://ssh.example.com/"
        model.start()
        try await waitFor { model.state == .running(hostname: "ssh.example.com") }
        model.stop()
        model.setToken("")
        XCTAssertNil(token)
        XCTAssertFalse(model.hasToken)
    }

    func testSettingsPersistInDefaults() {
        let model = makeModel(script: "exit 0")
        model.mode = .named
        model.hostname = "ssh.example.com"
        model.startsAtLaunch = true
        let reloaded = makeModel(script: "exit 0")
        XCTAssertEqual(reloaded.mode, .named)
        XCTAssertEqual(reloaded.hostname, "ssh.example.com")
        XCTAssertTrue(reloaded.startsAtLaunch)
    }

    func testMissingCloudflaredExplainsHowToInstallIt() {
        let model = RemoteAccessModel(defaults: defaults, tokens: memoryTokens, executable: { nil })
        model.start()
        guard case .failed(let message) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertTrue(message.contains("brew install cloudflared"))
    }

    /// A real quick tunnel through Cloudflare to this Mac's SSH; set WOOLOO_CLOUDFLARE_TUNNEL_TEST=1 to run it.
    func testRealQuickTunnelReachesThisMacsSSH() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WOOLOO_CLOUDFLARE_TUNNEL_TEST"] == "1")
        try XCTSkipUnless(RemoteAccessSystem.cloudflared() != nil && RemoteAccessSystem.acceptsSSH())
        let model = RemoteAccessModel(defaults: defaults, tokens: memoryTokens)
        model.start()
        defer { model.stop() }
        try await waitFor({ model.state != .checking }, timeout: 30)
        // Running this test is the developer's confirmation for a server that accepts passwords.
        if case .needsConfirmation = model.state { model.startDespiteCheck() }
        try await waitFor({ if case .running = model.state { true } else { false } }, timeout: 120)
        guard case .running(let hostname) = model.state else { return XCTFail("\(model.state)") }
        // A client speaks SSH inside binary WebSocket messages, as `cloudflared access ssh` and the Android app do.
        var banner = ""
        for _ in 0..<5 where banner.isEmpty {
            let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://\(hostname)/")!)
            socket.resume()
            if case .data(let data) = try? await socket.receive() { banner = String(decoding: data, as: UTF8.self) }
            socket.cancel()
            if banner.isEmpty { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-"), banner)
    }

    // MARK: Checking sshd before publishing it

    func testSSHCheckReadsTheMethodsSSHDOffers() {
        XCTAssertEqual(RemoteAccessSSHProbe.result(user: "me", failure: "me@127.0.0.1: Permission denied (publickey)."),
                       .keysOnly(user: "me", methods: ["publickey"]))
        XCTAssertEqual(RemoteAccessSSHProbe.result(
            user: "me", failure: "Warning: something\nme@127.0.0.1: Permission denied (publickey,password,keyboard-interactive)."),
            .acceptsPasswords(user: "me", methods: ["publickey", "password", "keyboard-interactive"]))
        XCTAssertEqual(RemoteAccessSSHProbe.result(user: "me", failure: "me@127.0.0.1: Permission denied (keyboard-interactive)."),
                       .acceptsPasswords(user: "me", methods: ["keyboard-interactive"]))
        XCTAssertEqual(RemoteAccessSSHProbe.result(user: "me", failure: nil), .acceptsNoCredential(user: "me"))
        XCTAssertEqual(RemoteAccessSSHProbe.result(user: "me", failure: "ssh: connect to host 127.0.0.1 port 22: Connection refused"),
                       .unknown(reason: "ssh: connect to host 127.0.0.1 port 22: Connection refused"))
        XCTAssertEqual(RemoteAccessSSHProbe.result(user: "me", failure: "me@127.0.0.1: Permission denied ()."),
                       .unknown(reason: "sshd listed no sign-in methods"))
        XCTAssertTrue(RemoteAccessSSHCheck.keysOnly(user: "me", methods: ["publickey"]).isVerifiedKeysOnly)
        XCTAssertFalse(RemoteAccessSSHCheck.unknown(reason: "x").isVerifiedKeysOnly)
        XCTAssertTrue(RemoteAccessSSHCheck.acceptsNoCredential(user: "me").refusesStart)
    }

    /// The probe offers no credential and touches no user configuration or known_hosts file.
    func testSSHProbeSendsNoCredential() {
        let arguments = RemoteAccessSSHProbe.arguments(user: "me")
        let options = stride(from: 0, to: arguments.count - 1, by: 1)
            .filter { arguments[$0] == "-o" }.map { arguments[$0 + 1] }
        for option in ["BatchMode=yes", "PreferredAuthentications=none", "PubkeyAuthentication=no",
                       "IdentityAgent=none", "NumberOfPasswordPrompts=0", "UserKnownHostsFile=/dev/null"] {
            XCTAssertTrue(options.contains(option), option)
        }
        XCTAssertEqual(Array(arguments.prefix(2)), ["-F", "/dev/null"])
        XCTAssertEqual(Array(arguments.suffix(2)), ["me@127.0.0.1", "true"])
    }

    /// The probe runs `ssh` and reads its refusal; a missing `ssh` is reported, not guessed.
    func testSSHProbeRunsSSH() throws {
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\necho \"me@127.0.0.1: Permission denied (publickey,password).\" >&2\nexit 255\n"
            .write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        XCTAssertEqual(RemoteAccessSSHProbe.check(user: "me", ssh: ssh.path),
                       .acceptsPasswords(user: "me", methods: ["publickey", "password"]))
        guard case .unknown = RemoteAccessSSHProbe.check(user: "me", ssh: directory.appendingPathComponent("none").path)
        else { return XCTFail("A missing ssh is unknown") }
    }

    /// sshd accepting passwords publishes nothing until the user confirms; Cancel leaves it off,
    /// and a tunnel started on the user's word says so.
    func testPasswordsWaitForConfirmation() async throws {
        let marker = directory.appendingPathComponent("ran")
        let passwords = RemoteAccessSSHCheck.acceptsPasswords(user: "me", methods: ["publickey", "password"])
        let model = makeModel(script: markedTunnel(marker), check: { passwords })
        model.start()
        try await waitFor { model.state == .needsConfirmation(passwords) }
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Nothing runs before confirming")

        model.cancelStart()
        XCTAssertEqual(model.state, .stopped)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        model.start()
        try await waitFor { model.state == .needsConfirmation(passwords) }
        model.startDespiteCheck()
        try await waitFor { model.state == .running(hostname: "fake-host.trycloudflare.com") }
        XCTAssertTrue(model.startedWithoutVerifiedKeys, "Confirmed, not verified")
        model.stop()
        XCTAssertFalse(model.startedWithoutVerifiedKeys)
    }

    /// A check that could not learn the methods asks too.
    func testAnUnknownCheckAsksBeforePublishing() async throws {
        let marker = directory.appendingPathComponent("ran")
        let unknown = RemoteAccessSSHCheck.unknown(reason: "timed out")
        let model = makeModel(script: markedTunnel(marker), check: { unknown })
        model.start()
        try await waitFor { model.state == .needsConfirmation(unknown) }
        XCTAssertTrue(unknown.summary.contains("cannot tell whether it accepts passwords"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        model.cancelStart()
    }

    /// sshd letting anyone in is never published, even on the user's word.
    func testAServerWithoutCredentialsIsNeverPublished() async throws {
        let marker = directory.appendingPathComponent("ran")
        let open = RemoteAccessSSHCheck.acceptsNoCredential(user: "me")
        let model = makeModel(script: markedTunnel(marker), check: { open })
        model.start()
        try await waitFor { model.state == .failed(open.summary) }
        model.startDespiteCheck()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.state, .failed(open.summary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Starting as wooloo opens needs a key-only check: nobody is there to confirm.
    func testStartAtLaunchNeedsKeyOnlySSH() async throws {
        let marker = directory.appendingPathComponent("ran")
        let passwords = makeModel(script: markedTunnel(marker),
                                  check: { .acceptsPasswords(user: "me", methods: ["password"]) })
        passwords.startAtLaunch()
        try await waitFor { if case .failed = passwords.state { true } else { false } }
        guard case .failed(let message) = passwords.state else { return XCTFail("\(passwords.state)") }
        XCTAssertTrue(message.hasPrefix("Not started when wooloo opened"), message)
        XCTAssertFalse(message.contains("Open Settings"), "The message is shown in Settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let keys = makeModel(script: markedTunnel(marker))
        keys.startAtLaunch()
        try await waitFor { keys.state == .running(hostname: "fake-host.trycloudflare.com") }
        keys.stop()
    }

    /// Stopping while sshd is being checked publishes nothing.
    func testStoppingDuringTheCheckPublishesNothing() async throws {
        let marker = directory.appendingPathComponent("ran")
        let model = makeModel(script: markedTunnel(marker), check: {
            Thread.sleep(forTimeInterval: 0.3)
            return .keysOnly(user: "me", methods: ["publickey"])
        })
        model.start()
        XCTAssertTrue(model.isActive)
        model.stop()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: Helpers

    private var memoryTokens: RemoteAccessTokenStore {
        RemoteAccessTokenStore(load: { [unowned self] in token }, save: { [unowned self] in token = $0 })
    }

    private let keysOnly = RemoteAccessSSHCheck.keysOnly(user: "me", methods: ["publickey"])

    /// A fake `cloudflared` running `script`, and an SSH check answering `check`.
    private func makeModel(script: String,
                           check: @escaping @Sendable () -> RemoteAccessSSHCheck = {
                               .keysOnly(user: "me", methods: ["publickey"])
                           }) -> RemoteAccessModel {
        let url = directory.appendingPathComponent("cloudflared-\(UUID().uuidString)")
        try? ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return RemoteAccessModel(defaults: defaults, tokens: memoryTokens, executable: { url.path },
                                 isPublished: { _ in true }, checkSSHSignIn: check)
    }

    /// A fake `cloudflared` that leaves `marker` behind once it runs, then registers a quick tunnel.
    private func markedTunnel(_ marker: URL) -> String {
        """
        touch '\(marker.path)'
        echo "2026-10-07T14:09:27Z INF |  https://fake-host.trycloudflare.com  |" >&2
        echo "2026-10-07T14:09:28Z INF Registered tunnel connection connIndex=0" >&2
        exec sleep 30
        """
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

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
        XCTAssertEqual(model.state, .starting)
        try await waitFor { model.state == .running(hostname: "fake-host.trycloudflare.com") }
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
        try await waitFor({ if case .running = model.state { true } else { false } }, timeout: 120)
        guard case .running(let hostname) = model.state else { return XCTFail("\(model.state)") }
        // A client speaks SSH inside binary WebSocket messages, as `cloudflared access ssh` and herdroid do.
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

    // MARK: Helpers

    private var memoryTokens: RemoteAccessTokenStore {
        RemoteAccessTokenStore(load: { [unowned self] in token }, save: { [unowned self] in token = $0 })
    }

    private func makeModel(script: String) -> RemoteAccessModel {
        let url = directory.appendingPathComponent("cloudflared-\(UUID().uuidString)")
        try? ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return RemoteAccessModel(defaults: defaults, tokens: memoryTokens, executable: { url.path },
                                 isPublished: { _ in true })
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

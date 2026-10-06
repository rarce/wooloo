import XCTest
import CryptoKit
@testable import xherdr

final class HerdrRuntimeTests: XCTestCase {
    private var root: URL!
    private var helper: URL!
    private var servers: [FakeHerdrServer] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/xh-runtime-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent("bundled-herdr")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    override func tearDownWithError() throws {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    private func service(launcher: @escaping HerdrRuntimeService.Launcher = { _, _, _, _, _ in
        XCTFail("A live server must not be launched again")
    }) -> HerdrRuntimeService {
        HerdrRuntimeService(supportRoot: root.appendingPathComponent("support"), configRoot: root.appendingPathComponent("config"),
                            bundledExecutable: helper, environment: ["PATH": "", "SHELL": "/bin/sh"], launcher: launcher)
    }

    private var socketPath: String { HerdrRuntimePaths.socket(in: root.appendingPathComponent("config"), session: "xherdr-ui-test") }

    private func server(generation: Int = 1, snapshot: [String: Any] = fakeSnapshot()) throws -> FakeHerdrServer {
        let server = try FakeHerdrServer(path: socketPath) { method, _ in
            if method == "ping" { return self.health(generation: generation) }
            if method == "session.snapshot" { return snapshot }
            return ["error": ["message": "Unexpected request: \(method)"]]
        }
        servers.append(server)
        return server
    }

    private func health(generation: Int = 1) -> [String: Any] {
        ["result": ["type": "pong", "capabilities": ["endpoint_protocol_generation": generation]]]
    }

    func testInstallRepairsModifiedBinaryAndPreservesExecutablePermissions() async throws {
        let runtime = service()
        let installed = try await runtime.installBundledExecutable()
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: helper))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        let before = try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date
        _ = try await runtime.installBundledExecutable()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date, before)
        try Data("corrupt".utf8).write(to: installed)
        _ = try await runtime.installBundledExecutable()
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: helper))
    }

    func testMissingBundledBinaryReportsRepairInsteadOfInstallingAnExternalBinary() async throws {
        try FileManager.default.removeItem(at: helper)
        do {
            _ = try await service().installBundledExecutable()
            XCTFail("Missing binary should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing its bundled Herdr"))
        }
    }

    func testHealthyExistingServerIsReusedWithoutDuplicatingItsWorkspace() async throws {
        let running = try server()
        try await service().ensureServer(executable: helper, session: "xherdr-ui-test", folder: root)
        XCTAssertEqual(running.requests.map(\.method), ["ping", "session.snapshot"])
    }

    func testIncompatibleServerIsNeverReplaced() async throws {
        let running = try server(generation: 2)
        do {
            try await service().ensureServer(executable: helper, session: "xherdr-ui-test", folder: root)
            XCTFail("Incompatible endpoint should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("terminal endpoint"))
        }
        XCTAssertEqual(running.requests.map(\.method), ["ping"])
    }

    func testExistingModeDoesNotLaunchAnAbsentServer() async throws {
        do {
            try await service().ensureServer(executable: helper, session: "xherdr-ui-test", mayStart: false)
            XCTFail("Absent server should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not running"))
        }
    }

    func testColdStartCreatesFirstWorkspaceAndPreservesExistingConfiguration() async throws {
        let config = root.appendingPathComponent("config/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "[terminal]\ndefault_shell = '/bin/sh'\n"
        try Data(original.utf8).write(to: config)
        let box = RuntimeLaunchBox()
        defer { box.server?.stop() }
        let path = socketPath
        let runtime = service { executable, name, environment, _, _ in
            box.launches += 1
            XCTAssertEqual(name, "xherdr-ui-test")
            XCTAssertTrue(environment["PATH"]?.hasPrefix(executable.deletingLastPathComponent().path) == true)
            box.server = try FakeHerdrServer(path: path) { method, params in
                switch method {
                case "ping": return ["result": ["type": "pong", "capabilities": ["endpoint_protocol_generation": 1]]]
                case "session.snapshot":
                    var snapshot = fakeSnapshot()
                    if !box.created {
                        var result = snapshot["result"] as! [String: Any]
                        var body = result["snapshot"] as! [String: Any]
                        body["workspaces"] = []
                        result["snapshot"] = body
                        snapshot["result"] = result
                    }
                    return snapshot
                case "workspace.create":
                    box.created = true
                    XCTAssertEqual(params["cwd"] as? String, self.root.resolvingSymlinksInPath().path)
                    return ["result": ["workspace": ["workspace_id": "w1"]]]
                default: return nil
                }
            }
        }
        try await runtime.ensureServer(executable: helper, session: "xherdr-ui-test", folder: root)
        try await runtime.ensureServer(executable: helper, session: "xherdr-ui-test", folder: root)
        XCTAssertEqual(box.launches, 1)
        XCTAssertEqual(box.server?.requests.filter { $0.method == "workspace.create" }.count, 1)
        XCTAssertEqual(try String(contentsOf: config), original)
    }

    func testInvalidFolderAndSessionFailBeforeStartingServer() async throws {
        for name in ["", "../default", "two words", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try HerdrRuntimePaths.validateSession(name))
        }
        XCTAssertNoThrow(try HerdrRuntimePaths.validateSession("xherdr-ui-test"))
        do {
            try await service().ensureServer(executable: helper, session: "xherdr-ui-test", folder: helper)
            XCTFail("A file is not a workspace folder")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("readable folder"))
        }
    }

    /// Opt-in check of the packaged binary and a real launchd job, always in temporary roots.
    func testBundledRuntimeLaunchesWithoutExternalToolsAndReconnects() async throws {
        guard ProcessInfo.processInfo.environment["XHERDR_RUNTIME_E2E"] == "1" else {
            throw XCTSkip("Set XHERDR_RUNTIME_E2E=1 to check the bundled runtime with launchd")
        }
        let configRoot = root.appendingPathComponent("herdr")
        let support = root.appendingPathComponent("support")
        let session = "xherdr-ui-test"
        let socket = HerdrRuntimePaths.socket(in: configRoot, session: session)
        let identity = SHA256.hash(data: Data((configRoot.path + "|" + session).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let job = "gui/\(getuid())/dev.xherdr.herdr.\(identity)"
        defer {
            _ = try? HerdrSocket.request(path: socket, method: "server.stop")
            _ = try? WorkspaceFiles.run("/bin/launchctl", ["bootout", job], limit: 16_000)
        }
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try Data("onboarding = false\n[terminal]\ndefault_shell = '/bin/sh'\nshell_mode = 'non_login'\n[update]\nversion_check = false\n".utf8)
            .write(to: configRoot.appendingPathComponent("config.toml"))
        let runtime = HerdrRuntimeService(supportRoot: support, configRoot: configRoot,
                                         environment: ["XDG_CONFIG_HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                                                       "PATH": "", "SHELL": "/bin/sh"])
        let installed = try await runtime.installBundledExecutable()
        try await runtime.ensureServer(executable: installed, session: session, folder: root)
        let snapshot = try HerdrSocket.snapshot(path: socket)
        let pane = try XCTUnwrap(snapshot.panes.first?.paneID)
        try HerdrSocket.sendInput(path: socket, paneID: pane, text: "printf 'XHERDR_RUNTIME_%s\\n' OK\n")
        var output = ""
        for _ in 0..<30 {
            output = try HerdrSocket.paneText(path: socket, paneID: pane)
            if output.contains("XHERDR_RUNTIME_OK") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(output.contains("XHERDR_RUNTIME_OK"))
        // All client sockets above have closed. A new service attaches to the same pane.
        let reopened = HerdrRuntimeService(supportRoot: support, configRoot: configRoot)
        try await reopened.ensureServer(executable: installed, session: session)
        XCTAssertEqual(try HerdrSocket.snapshot(path: socket).panes.first?.paneID, pane)
        let jobInfo = try WorkspaceFiles.run("/bin/launchctl", ["print", job], limit: 64_000)
        XCTAssertTrue(String(decoding: jobInfo, as: UTF8.self).contains("state = running"))
        // An explicit stop leaves an exited launchd job loaded. Opening xherdr again must
        // start a fresh server instead of leaving that job stuck on its previous binary.
        _ = try HerdrSocket.request(path: socket, method: "server.stop")
        for _ in 0..<50 {
            if (try? HerdrSocket.request(path: socket, method: "ping")) == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await runtime.ensureServer(executable: installed, session: session)
        XCTAssertFalse(try HerdrSocket.snapshot(path: socket).workspaces.isEmpty)
    }

    @MainActor
    func testFreshInstallShowsWizardAndExistingInstallPreservesSession() throws {
        let suite = "xherdr-setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(HerdrRuntimeModel(defaults: defaults, service: service()).showsSetup)
        defaults.set("my-existing-session", forKey: "HerdrLastSession")
        XCTAssertFalse(HerdrRuntimeModel(defaults: defaults, service: service()).showsSetup)
        XCTAssertEqual(defaults.string(forKey: "HerdrLastSession"), "my-existing-session")
    }

    @MainActor
    func testFailedSetupIsRetryableAndDoesNotRecordCompletion() async throws {
        let suite = "xherdr-setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrRuntimeModel(defaults: defaults, service: service())
        await model.finish(useBundled: true, executable: nil, session: "xherdr-ui-test", folder: nil)
        XCTAssertTrue(model.showsSetup)
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(defaults.bool(forKey: HerdrRuntimePaths.completedKey))
        _ = try server()
        await model.finish(useBundled: true, executable: nil, session: "xherdr-ui-test", folder: root)
        XCTAssertFalse(model.showsSetup)
        XCTAssertTrue(defaults.bool(forKey: HerdrRuntimePaths.completedKey))
        XCTAssertEqual(defaults.string(forKey: HerdrRuntimePaths.managedSessionKey), "xherdr-ui-test")
        XCTAssertEqual(model.connectedSession, "xherdr-ui-test")
    }
}

private final class RuntimeLaunchBox: @unchecked Sendable {
    var server: FakeHerdrServer?
    var launches = 0
    var created = false
}

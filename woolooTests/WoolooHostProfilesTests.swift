import XCTest
@testable import wooloo

/// Hosts wooloo keeps for herdr-core, and the settings file used on a Mac without the Herdr TUI.
final class WoolooHostProfilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/wooloo-tests/hosts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testHostsAreSavedPrivatelyAndDeduplicated() throws {
        let url = directory.appendingPathComponent("hosts.json")
        let host = try WoolooHostProfiles.add(target: "ssh://dev@box.example:2222", label: nil, session: "agents", at: url)
        XCTAssertTrue(WoolooHostProfiles.isOwned(host))
        XCTAssertEqual(host.label, "dev@box.example")
        XCTAssertTrue(host.enabled)
        XCTAssertEqual(try WoolooHostProfiles.add(target: "ssh://dev@box.example:2222", label: "Box", session: "agents", at: url), host)
        XCTAssertEqual(WoolooHostProfiles.load(at: url), [host])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try WoolooHostProfiles.remove(id: host.id, at: url)
        XCTAssertEqual(WoolooHostProfiles.load(at: url), [])
    }

    func testUnsafeTargetsAndSessionsAreRefused() {
        let url = directory.appendingPathComponent("hosts.json")
        XCTAssertThrowsError(try WoolooHostProfiles.add(target: "-oProxyCommand=x", label: nil, session: "a", at: url))
        XCTAssertThrowsError(try WoolooHostProfiles.add(target: "box\nother", label: nil, session: "a", at: url))
        XCTAssertThrowsError(try WoolooHostProfiles.add(target: "box", label: nil, session: "a b", at: url))
        XCTAssertThrowsError(try WoolooHostProfiles.add(target: "box", label: nil, session: "a;rm", at: url))
    }

    func testHerdrProfilesInTheFileAreIgnored() throws {
        let url = directory.appendingPathComponent("hosts.json")
        let foreign = HerdrMachineProfile(id: "box", label: "Box", target: "box", session: "agents", enabled: true)
        try WoolooHostProfiles.save([foreign], at: url)
        XCTAssertEqual(WoolooHostProfiles.load(at: url), [])
    }

    func testCoreSSHArgumentsReuseAMasterWithoutBecomingOne() {
        let host = HerdrMachineProfile(id: "wooloo-1", label: "Box", target: "ssh://dev@box:2222", session: "agents", enabled: true)
        let args = HerdrRemoteBridge.coreArguments(host, session: "agents")
        XCTAssertFalse(args.contains("ControlMaster=auto"))
        if WorkspaceFiles.sshControlDirectory != nil { XCTAssertTrue(args.contains("ControlMaster=no")) }
        XCTAssertTrue(args.contains("ServerAliveInterval=10"))
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(args[args.count - 2], "dev@box")
        let script = args.last!
        XCTAssertTrue(script.hasPrefix("/bin/sh -c "))
        XCTAssertTrue(script.contains(CoreTarget.banner))
        XCTAssertTrue(script.contains("connect --session"))
        XCTAssertTrue(script.contains("exit 127"))
    }

    func testCoreTargetsValidateSessions() throws {
        XCTAssertThrowsError(try HerdrCoreSupport.target(session: "a b", machine: nil))
        let host = HerdrMachineProfile(id: "wooloo-1", label: "Box", target: "box", session: "agents", enabled: true)
        let target = try HerdrCoreSupport.target(session: "agents", machine: host)
        XCTAssertEqual(target.executable, WorkspaceFiles.sshExecutable)
        XCTAssertEqual(target.banner, CoreTarget.banner)
    }

    func testSettingsLiveInWoolooWithoutAHerdrTUI() throws {
        let saved = WorkspaceFiles.herdrCandidates
        let environment = ["HERDR_CONFIG_PATH", "XDG_CONFIG_HOME", "WOOLOO_RUNTIME_ROOT"]
        let previous = environment.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            WorkspaceFiles.herdrCandidates = saved
            for (key, value) in zip(environment, previous) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        unsetenv("HERDR_CONFIG_PATH")
        setenv("XDG_CONFIG_HOME", directory.appendingPathComponent("config").path, 1)
        setenv("WOOLOO_RUNTIME_ROOT", directory.appendingPathComponent("support").path, 1)
        WorkspaceFiles.herdrCandidates = [directory.appendingPathComponent("missing/herdr").path]
        let url = HerdrConfigFile.url
        XCTAssertEqual(url, HerdrConfigFile.woolooURL)
        XCTAssertTrue(HerdrConfigFile.isWoolooOwned(url))
        let message = try HerdrConfigFile.saveAndReload("[theme]\nname = \"tokyo-night\"\n", original: "", at: url,
                                                        socketPath: "", session: "default")
        XCTAssertTrue(message.hasPrefix("Saved wooloo's settings"), message)
        XCTAssertEqual(try HerdrConfigFile.read(at: url), "[theme]\nname = \"tokyo-night\"\n")
        WorkspaceFiles.herdrCandidates = ["/bin/sh"]
        XCTAssertEqual(HerdrConfigFile.url, HerdrConfigFile.herdrURL, "An installed Herdr TUI owns the settings")
    }
}

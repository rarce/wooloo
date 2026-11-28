import XCTest
@testable import wooloo

/// The user-initiated herdr-core install on a remote host or this Mac: pinned builds, an
/// existing core kept, and a download that fails its checksum installing nothing. The remote
/// command runs locally through a fake `ssh`, and the local one directly, in a temporary home,
/// with a fake `curl`.
final class HerdrCoreInstallTests: XCTestCase {
    private var home: String!
    private let machine = HerdrMachineProfile(id: "dev", label: "Dev", target: "dev.example.test",
                                              session: "default", enabled: true)

    override func setUpWithError() throws {
        home = "/private/tmp/wooloo-tests/core-install-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/fakebin", withIntermediateDirectories: true)
        let ssh = home + "/ssh"
        // Runs the remote command locally, as if the remote user's home were `home`, with only
        // the fake tools and the system's own on PATH.
        try write("""
            #!/bin/sh
            for command; do :; done
            HOME='\(home!)' PATH='\(home!)/fakebin:/usr/bin:/bin' exec /bin/sh -c "$command"
            """, to: ssh)
        // A download that is not the pinned build.
        try write("""
            #!/bin/sh
            while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'not herdr-core' > "$2"; exit 0; }; shift; done
            exit 1
            """, to: home + "/fakebin/curl")
        WorkspaceFiles.sshExecutable = ssh
    }

    override func tearDown() {
        WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
        try? FileManager.default.removeItem(atPath: home)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Discovery also looks in fixed folders outside the test's home; a core installed there
    /// (Homebrew, nix) would be found before the one each test sets up.
    private func skipIfACoreIsInstalledOutsideHome() throws {
        for path in ["/opt/homebrew/bin/hc", "/usr/local/bin/hc", "/home/linuxbrew/.linuxbrew/bin/hc",
                     "/etc/profiles/per-user/\(NSUserName())/bin/hc", "/run/current-system/sw/bin/hc"]
        where FileManager.default.isExecutableFile(atPath: path) {
            throw XCTSkip("herdr-core at \(path) would be found before the test's own")
        }
    }

    private func install() async throws -> HerdrCoreInstall.Outcome {
        let machine = self.machine
        return try await WorkspaceFiles.blocking(on: machine) { try HerdrCoreInstall.install(on: machine) }
    }

    func testEveryPlatformIsPinned() {
        XCTAssertEqual(Set(HerdrCoreInstall.builds.keys), ["linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64"])
        for (target, build) in HerdrCoreInstall.builds {
            XCTAssertEqual(build.sha256.count, 64, target)
            XCTAssertTrue(build.url.hasPrefix("https://releases.herdr.dev/core/\(HerdrCoreInstall.version)/"), target)
            XCTAssertTrue(HerdrCoreInstall.script.contains("want=\(build.sha256)"), target)
        }
        XCTAssertFalse(HerdrCoreInstall.script.contains("exit 127"), "Finding no core is where the install starts")
        XCTAssertTrue(HerdrCoreInstall.script.contains("codesign --verify --strict -R "
                                                       + WorkspaceFiles.quote(HerdrCoreInstall.macRequirement)),
                      "A Mac gets Herdr Core.app only when Herdr signed it")
        XCTAssertTrue(HerdrCoreInstall.script.contains("--hc-install-bundle"))
    }

    private var localEnvironment: [String: String] { ["HOME": home, "PATH": home + "/fakebin:/usr/bin:/bin"] }

    private func installLocally() async throws -> HerdrCoreInstall.Outcome {
        let environment = localEnvironment
        return try await WorkspaceFiles.blocking(on: nil) { try HerdrCoreInstall.installLocally(environment: environment) }
    }

    func testThisMacKeepsItsCoreOrInstallsNothingOnABadDownload() async throws {
        try skipIfACoreIsInstalledOutsideHome()
        // Another program named hc is not herdr-core.
        try write("#!/bin/sh\necho 'herbstclient 0.9.5'\n", to: home + "/fakebin/hc")
        do {
            _ = try await installLocally()
            XCTFail("The install should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local/bin/herdr-core"))
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try write("#!/bin/sh\necho 'hc 0.0.1'\n", to: home + "/.local/bin/hc")
        let outcome = try await installLocally()
        XCTAssertEqual(outcome, .present(home + "/.local/bin/hc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local/bin/herdr-core"))
    }

    func testOutcomesAreReadFromTheLastLine() {
        XCTAssertEqual(HerdrCoreInstall.outcome(of: "noise\nwooloo-core-installed /home/u/.local/bin/herdr-core\n"),
                       .installed("/home/u/.local/bin/herdr-core"))
        XCTAssertEqual(HerdrCoreInstall.outcome(of: "wooloo-core-present /usr/bin/hc"), .present("/usr/bin/hc"))
        XCTAssertNil(HerdrCoreInstall.outcome(of: "wooloo-core-installed"))
        XCTAssertNil(HerdrCoreInstall.outcome(of: ""))
    }

    func testAnExistingCoreIsKept() async throws {
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try write("#!/bin/sh\necho 'hc 0.0.1'\n", to: home + "/.local/bin/hc")
        let outcome = try await install()
        XCTAssertEqual(outcome, .present(home + "/.local/bin/hc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local/bin/herdr-core"))
    }

    func testADownloadThatFailsItsChecksumInstallsNothing() async throws {
        try skipIfACoreIsInstalledOutsideHome()
        do {
            _ = try await install()
            XCTFail("The install should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local/bin/herdr-core"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local/bin/hc"))
    }
}

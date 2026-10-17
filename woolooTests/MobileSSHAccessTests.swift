import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import wooloo

final class MobileSSHAccessTests: XCTestCase {
    private var directory: URL!
    private let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPL0n3RNg08SCe1ezkGWADmJUd0dqkjBMG/0hF2rKRlT wooloo-mobile"
    private let machine = HerdrMachineProfile(id: "remote", label: "Remote server", target: "work-alias",
                                               session: "remote-work", enabled: true)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("wooloo-mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
        try FileManager.default.removeItem(at: directory)
    }

    func testPublicKeyFingerprintMatchesOpenSSHAndKeepsCommentAsData() throws {
        let key = try MobileSSHPublicKey(publicLine + " ' $(touch /tmp/never-run) \";")
        XCTAssertEqual(key.fingerprint, "SHA256:lfPaKzZw8nfzEEUg5v3/z//Ygs88PEFWZsjdzwAM2MI")
        XCTAssertEqual(key.line, publicLine + " ' $(touch /tmp/never-run) \";")
        XCTAssertEqual(try MobileSSHPublicKey(" \n" + publicLine + "\n ").line, publicLine)
    }

    func testRejectsCommandsPrivateKeysOptionsMultipleKeysAndMalformedBlobs() throws {
        for text in ["", "-----BEGIN OPENSSH PRIVATE KEY-----", "mkdir -p ~/.ssh && echo '\(publicLine)'",
                     "restrict " + publicLine, publicLine + "\n" + publicLine, publicLine + "\r\nother",
                     publicLine.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa"),
                     "ssh-ed25519 AAAA", publicLine + "\0bad", "ssh-ed25519 !!!!"] {
            XCTAssertThrowsError(try MobileSSHPublicKey(text), text)
        }
        let fields = publicLine.split(separator: " ")
        var blob = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
        blob.append(0)
        XCTAssertThrowsError(try MobileSSHPublicKey("ssh-ed25519 " + blob.base64EncodedString()))
    }

    func testAcceptsImportedRSAAndECDSAPublicKeys() throws {
        for kind in ["rsa", "ecdsa"] {
            let path = directory.appendingPathComponent(kind).path
            _ = try WorkspaceFiles.run("/usr/bin/ssh-keygen", ["-q", "-t", kind, "-N", "", "-f", path], limit: 4096)
            let line = try String(contentsOfFile: path + ".pub", encoding: .utf8)
            let key = try MobileSSHPublicKey(line)
            let output = try WorkspaceFiles.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", path + ".pub"], limit: 4096)
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(key.fingerprint))
        }
    }

    func testSSHConfigurationResolvesAliasPortAndProxyWithoutGuessingPublicReachability() throws {
        let endpoint = try MobileSSHAccess.ResolvedEndpoint(configuration:
            "host work-alias\nuser remote-user\nhostname server.example.test\nport 2222\nproxyjump bastion\n")
        XCTAssertEqual(endpoint.hostname, "server.example.test")
        XCTAssertEqual(endpoint.port, 2222)
        XCTAssertTrue(endpoint.usesProxy)
        let ipv6 = try MobileSSHAccess.ResolvedEndpoint(configuration: "hostname 2001:db8::1\nport 22\nproxycommand none\n")
        XCTAssertEqual(ipv6.hostname, "[2001:db8::1]")
        XCTAssertFalse(ipv6.usesProxy)
        XCTAssertThrowsError(try MobileSSHAccess.ResolvedEndpoint(configuration: "hostname x\nport 0\n"))
    }

    func testDirectQRUsesTheRemoteAccountSessionBinaryPortAndHostKeys() throws {
        let connection = try remoteConnection(user: "remote-user", home: "/home/remote-user", key: publicLine)
        let url = try XCTUnwrap(connection.link(hostname: "server.example.test", port: "2222"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.scheme, "herdroid")
        XCTAssertEqual(url.host, "add-host")
        XCTAssertEqual(value("transport"), "ssh")
        XCTAssertEqual(value("host"), "server.example.test")
        XCTAssertEqual(value("user"), "remote-user")
        XCTAssertEqual(value("port"), "2222")
        XCTAssertEqual(value("session"), "remote-work")
        XCTAssertEqual(value("herdr"), "/home/remote-user/.local/bin/herdr")
        XCTAssertEqual(value("fp"), try MobileSSHPublicKey(publicLine).fingerprint)
        XCTAssertEqual(connection.authorizedKeysPath, "/home/remote-user/.ssh/authorized_keys")
        XCTAssertEqual(connection.machine, machine)
        XCTAssertNil(connection.link(hostname: "user@server", port: "22"))
        XCTAssertNil(connection.link(hostname: "server", port: "65536"))
    }

    func testMissingRemoteHostKeysDoNotSubstituteThisMacsKeys() throws {
        let connection = try remoteConnection(user: "remote-user", home: "/home/remote-user", key: "")
        XCTAssertTrue(connection.fingerprints.isEmpty)
        XCTAssertNil(connection.link(hostname: "", port: "22"))
        let endpoint = try MobileSSHAccess.ResolvedEndpoint(configuration: "hostname server\nport 22\n")
        XCTAssertThrowsError(try MobileSSHAccess.connection(machine: machine, session: "work", endpoint: endpoint,
                                                           metadata: Data("broken".utf8)))
    }

    func testDirectQRCodeDecodesToTheConnectionLink() throws {
        let connection = try remoteConnection(user: "remote-user", home: "/home/remote-user", key: publicLine)
        let link = try XCTUnwrap(connection.link(hostname: "server.example.test", port: "2222"))
        let image = try XCTUnwrap(RemoteAccessLink.qrImage(for: link))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
        XCTAssertEqual(feature.messageString, link.absoluteString)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/mobile-direct-qr.png")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: output)
    }

    func testInstallsPublicKeyWithPrivatePermissionsWithoutExecutingItsComment() throws {
        let marker = directory.appendingPathComponent("should-not-exist").path
        let key = try MobileSSHPublicKey(publicLine + " ' $(touch " + marker + ")")
        let connection = localConnection()
        XCTAssertTrue(try MobileSSHAccess.authorize(key, on: connection))
        XCTAssertEqual(try String(contentsOfFile: connection.authorizedKeysPath, encoding: .utf8), key.line + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        let ssh = directory.appendingPathComponent(".ssh").path
        XCTAssertEqual(try permissions(ssh), 0o700)
        XCTAssertEqual(try permissions(connection.authorizedKeysPath), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ssh + "/.wooloo-authorized-keys.lock"))
    }

    func testPreservesOtherEntriesAndAddsAfterAFileWithoutATrailingNewline() throws {
        let connection = localConnection()
        let existing = "# Preserve comment\nrestrict ssh-ed25519 different-key existing"
        try makeAuthorizedKeys(existing)
        XCTAssertTrue(try MobileSSHAccess.authorize(MobileSSHPublicKey(publicLine), on: connection))
        XCTAssertEqual(try String(contentsOfFile: connection.authorizedKeysPath, encoding: .utf8),
                       existing + "\n" + publicLine + "\n")
    }

    func testDoesNotDuplicateKeysWithDifferentCommentsOrWeakenRestrictedKeys() throws {
        let fields = publicLine.split(separator: " ").prefix(2).joined(separator: " ")
        for prefix in ["", "restrict ", "command=\"echo limited access\",no-pty ",
                       "command=\"echo \(fields) do not widen\",no-pty "] {
            let existing = "# Existing entries\n" + prefix + fields + " original-comment\n"
            try makeAuthorizedKeys(existing)
            XCTAssertFalse(try MobileSSHAccess.authorize(MobileSSHPublicKey(publicLine), on: localConnection()))
            XCTAssertEqual(try String(contentsOfFile: localConnection().authorizedKeysPath, encoding: .utf8), existing)
        }
    }

    func testAKeyMentionedInAnotherKeysCommentDoesNotCountAsAuthorized() throws {
        let existing = "ssh-ed25519 other-key comment mentioning " + publicLine + "\n"
        try makeAuthorizedKeys(existing)
        XCTAssertTrue(try MobileSSHAccess.authorize(MobileSSHPublicKey(publicLine), on: localConnection()))
        XCTAssertTrue(try String(contentsOfFile: localConnection().authorizedKeysPath, encoding: .utf8).hasSuffix(publicLine + "\n"))
    }

    func testCRLFTerminatedRestrictedKeysWithoutCommentsAreNotDuplicated() throws {
        let fields = publicLine.split(separator: " ").prefix(2).joined(separator: " ")
        for options in ["from=\"192.0.2.1\"", "expiry-time=\"20300101\"", "restrict"] {
            let existing = Data((options + " " + fields + "\r\n").utf8)
            try makeAuthorizedKeys(existing)
            XCTAssertFalse(try MobileSSHAccess.authorize(MobileSSHPublicKey(publicLine), on: localConnection()))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localConnection().authorizedKeysPath)), existing)
        }
    }

    func testNonUTF8RestrictedKeysAreRecognizedUnderAUTF8Locale() throws {
        let fields = publicLine.split(separator: " ").prefix(2).joined(separator: " ")
        var existing = Data("command=\"echo ".utf8)
        existing.append(0xFF)
        existing.append(Data(("\" " + fields + "\r\n").utf8))
        try makeAuthorizedKeys(existing)
        XCTAssertEqual(try runInstaller(environment: ["LC_ALL": "en_US.UTF-8"]), "exists")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localConnection().authorizedKeysPath)), existing)
    }

    func testScannerErrorsAbortWithoutAppendingOrLeavingAnAuthorizationLock() throws {
        let existing = Data(("from=\"192.0.2.1\" " + publicLine + "\n").utf8)
        for status in [1, 2, 127] {
            try makeAuthorizedKeys(existing)
            let environment = try scannerEnvironment(script: "printf 'missing\\n'\nexit \(status)\n")
            XCTAssertThrowsError(try runInstaller(environment: environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Could not inspect existing authorized_keys"))
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localConnection().authorizedKeysPath)), existing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".ssh/.wooloo-authorized-keys.lock").path))
        }
    }

    func testUnexpectedScannerOutputDoesNotAuthorizeAKey() throws {
        let existing = Data(("restrict " + publicLine + "\n").utf8)
        try makeAuthorizedKeys(existing)
        let environment = try scannerEnvironment(script: "printf 'undecidable\\n'\n")
        XCTAssertThrowsError(try runInstaller(environment: environment))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localConnection().authorizedKeysPath)), existing)
    }

    func testRefusesSymlinksAndAnAccountChangeWithoutOverwritingExistingFiles() throws {
        let key = try MobileSSHPublicKey(publicLine)
        let target = directory.appendingPathComponent("untouched")
        try "unchanged".write(to: target, atomically: true, encoding: .utf8)
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createSymbolicLink(at: ssh, withDestinationURL: directory)
        XCTAssertThrowsError(try MobileSSHAccess.authorize(key, on: localConnection()))
        try FileManager.default.removeItem(at: ssh)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let file = ssh.appendingPathComponent("authorized_keys")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try MobileSSHAccess.authorize(key, on: localConnection()))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        try FileManager.default.removeItem(at: file)
        let wrongAccount = try remoteConnection(user: "not-the-current-user", home: directory.path, key: "")
        let script = MobileSSHAccess.installationScript(homeDirectory: wrongAccount.homeDirectory, user: wrongAccount.user)
        XCTAssertThrowsError(try WorkspaceFiles.run("/bin/sh", ["-c", script], input: Data((key.line + "\n").utf8), limit: 4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnExistingAuthorizationLockLeavesTheFileUntouched() throws {
        try makeAuthorizedKeys("# unchanged\n")
        let lock = directory.appendingPathComponent(".ssh/.wooloo-authorized-keys.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MobileSSHAccess.authorize(MobileSSHPublicKey(publicLine), on: localConnection()))
        XCTAssertEqual(try String(contentsOfFile: localConnection().authorizedKeysPath, encoding: .utf8), "# unchanged\n")
    }

    func testPreparationAndAuthorizationUseTheSavedRemoteConnectionAndStdin() async throws {
        let metadata = Data("\(NSUserName())\0\(directory.path)\0/remote/herdr\0\(publicLine)\n".utf8)
        try metadata.write(to: directory.appendingPathComponent("metadata"))
        let ssh = directory.appendingPathComponent("ssh")
        let log = directory.appendingPathComponent("arguments").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> \(WorkspaceFiles.quote(log))
        if [ "$1" = '-G' ]; then
            printf 'hostname remote.example.test\\nport 2222\\nproxyjump bastion\\n'
            exit 0
        fi
        for task_command; do :; done
        case "$task_command" in
            *task_herdr*) cat \(WorkspaceFiles.quote(directory.appendingPathComponent("metadata").path));;
            *) exec /bin/sh -c "$task_command";;
        esac
        """
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        WorkspaceFiles.sshExecutable = ssh.path
        let connection = try await WorkspaceFiles.blocking(on: machine) { [self] in
            try MobileSSHAccess.prepare(machine: machine, session: machine.session)
        }
        XCTAssertEqual(connection.hostname, "remote.example.test")
        XCTAssertEqual(connection.herdrPath, "/remote/herdr")
        XCTAssertEqual(connection.session, "remote-work")
        let key = try MobileSSHPublicKey(publicLine)
        let added = try await WorkspaceFiles.blocking(on: machine) {
            try MobileSSHAccess.authorize(key, on: connection)
        }
        XCTAssertTrue(added)
        let arguments = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(arguments.contains("work-alias"))
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertFalse(arguments.contains(publicLine), "The key travels as stdin data, never as a shell command")
        XCTAssertEqual(try String(contentsOfFile: connection.authorizedKeysPath, encoding: .utf8), publicLine + "\n")
        WorkspaceFiles.sshExecutable = "/usr/bin/false"
        do {
            _ = try await WorkspaceFiles.blocking(on: machine) { try MobileSSHAccess.authorize(key, on: connection) }
            XCTFail("A failed SSH connection must fail authorization")
        } catch { }
    }

    private func remoteConnection(user: String, home: String, key: String) throws -> MobileSSHConnection {
        let endpoint = try MobileSSHAccess.ResolvedEndpoint(configuration: "hostname server.example.test\nport 2222\n")
        return try MobileSSHAccess.connection(machine: machine, session: machine.session, endpoint: endpoint,
                                              metadata: Data("\(user)\0\(home)\0/home/remote-user/.local/bin/herdr\0\(key)\n".utf8))
    }

    private func localConnection() -> MobileSSHConnection {
        MobileSSHConnection(machine: nil, hostname: "localhost", port: 22, user: NSUserName(), homeDirectory: directory.path,
                            session: "test", label: "Test", herdrPath: nil, fingerprints: [], usesProxy: false)
    }

    private func makeAuthorizedKeys(_ text: String) throws {
        try makeAuthorizedKeys(Data(text.utf8))
    }

    private func makeAuthorizedKeys(_ data: Data) throws {
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try data.write(to: ssh.appendingPathComponent("authorized_keys"), options: .atomic)
    }

    private func scannerEnvironment(script: String) throws -> [String: String] {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let awk = bin.appendingPathComponent("awk")
        try ("#!/bin/sh\n" + script).write(to: awk, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: awk.path)
        return ["PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    private func runInstaller(environment: [String: String]) throws -> String {
        let script = MobileSSHAccess.installationScript(homeDirectory: directory.path, user: NSUserName())
        let output = try WorkspaceFiles.run("/bin/sh", ["-c", script], environment: environment,
                                             input: Data((publicLine + "\n").utf8), limit: 4096)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }
}

import Darwin
import Foundation
import XCTest
@testable import wooloo

/// Real local listeners and child processes, with a fake SSH executable and no remote host.
@MainActor
final class HerdrRemoteBridgeTests: XCTestCase {
    private var root: URL!
    private let machine = HerdrMachineProfile(id: "fixture", label: "Fixture", target: "unused.test",
                                             session: "agents", enabled: true)

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/private/tmp/wooloo-bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBothRoutesPreserveBinaryBytesAndKeepBoundedDiagnosticsOffTheWire() async throws {
        let bridge = try HerdrRemoteBridge(machine: machine, sshExecutable: fakeSSH(diagnostics: true))
        defer { bridge.stop() }
        let api = try Client(path: bridge.apiPath)
        let terminal = try Client(path: bridge.clientPath)
        XCTAssertEqual(try api.read(count: 1), Data("A".utf8))
        XCTAssertEqual(try terminal.read(count: 1), Data("C".utf8))
        let payload = Data((0...255).map { UInt8($0) })
        try api.write(payload)
        XCTAssertEqual(try api.read(count: payload.count), payload, bridge.lastError ?? "No SSH diagnostics")
        try terminal.write(payload)
        XCTAssertEqual(try terminal.read(count: payload.count), payload, bridge.lastError ?? "No SSH diagnostics")
        try await waitUntil { bridge.lastError?.hasSuffix("DIAGNOSTIC-END") == true }
        let diagnostic = try XCTUnwrap(bridge.lastError)
        XCTAssertEqual(diagnostic.count, 2_000)
        XCTAssertTrue(diagnostic.hasSuffix("DIAGNOSTIC-END"))
        bridge.stop()
        XCTAssertTrue(try api.readToEOF().isEmpty, "stderr must not leak into the API stream")
        XCTAssertTrue(try terminal.readToEOF().isEmpty, "stderr must not leak into the terminal stream")
    }

    func testConcurrentRepeatedStopClosesActiveClientsAndRemovesSocketDirectory() throws {
        let bridge = try HerdrRemoteBridge(machine: machine, sshExecutable: fakeSSH(diagnostics: true))
        defer { bridge.stop() }
        let api = try Client(path: bridge.apiPath)
        let terminal = try Client(path: bridge.clientPath)
        XCTAssertEqual(try api.read(count: 1), Data("A".utf8))
        XCTAssertEqual(try terminal.read(count: 1), Data("C".utf8))
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index.isMultiple(of: 2) { bridge.stop() }
            else { _ = bridge.lastError }
        }
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.directory.path))
        XCTAssertTrue(try api.readToEOF().isEmpty)
        XCTAssertTrue(try terminal.readToEOF().isEmpty)
    }

    func testDeinitClosesAnActiveClientAndRemovesItsDirectory() async throws {
        var bridge: HerdrRemoteBridge? = try HerdrRemoteBridge(machine: machine, sshExecutable: fakeSSH())
        defer { bridge?.stop() }
        let isReleased = { [weak bridge] in bridge == nil }
        let directory = try XCTUnwrap(bridge?.directory)
        let client = try Client(path: XCTUnwrap(bridge?.apiPath))
        XCTAssertEqual(try client.read(count: 1), Data("A".utf8))
        bridge = nil
        try await waitUntil {
            isReleased() && !FileManager.default.fileExists(atPath: directory.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try client.readToEOF().isEmpty)
    }

    func testImmediateChildExitReleasesEveryAcceptedConnection() throws {
        let bridge = try HerdrRemoteBridge(machine: machine, sshExecutable: "/usr/bin/true")
        defer { bridge.stop() }
        for path in [bridge.apiPath, bridge.clientPath, bridge.apiPath, bridge.clientPath] {
            let client = try Client(path: path)
            XCTAssertTrue(try client.readToEOF().isEmpty)
        }
    }

    func testMissingExecutableClosesEveryAcceptedConnection() throws {
        let bridge = try HerdrRemoteBridge(machine: machine, sshExecutable: root.appendingPathComponent("absent").path)
        defer { bridge.stop() }
        for path in [bridge.apiPath, bridge.clientPath, bridge.apiPath, bridge.clientPath] {
            let client = try Client(path: path)
            XCTAssertTrue(try client.readToEOF().isEmpty)
        }
    }

    /// The real bridge still creates a Process per accepted socket and supplies its SSH arguments.
    /// Store integration tests separately exercise the remote shell and capability discovery.
    private func fakeSSH(diagnostics: Bool = false) throws -> String {
        let executable = root.appendingPathComponent("ssh-\(UUID().uuidString).py")
        let script = """
        #!/usr/bin/python3
        import os, sys
        # Darwin accept inherits the listener's O_NONBLOCK. This fake child uses blocking stdio.
        os.set_blocking(0, True)
        os.set_blocking(1, True)
        def write_all(fd, data):
            while data:
                count = os.write(fd, data)
                if count <= 0: raise RuntimeError('short write')
                data = data[count:]
        if \(diagnostics ? "True" : "False"):
            write_all(2, b'x' * 6000 + b'\\nDIAGNOSTIC-END\\n')
        write_all(1, b'C' if 'remote-client-bridge' in sys.argv[-1] else b'A')
        while True:
            data = os.read(0, 65536)
            if not data: break
            write_all(1, data)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable.path
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum TestError: Error {
        case timeout
        case unexpectedEOF
    }

    /// Owns its fd even when a test assertion throws. Every I/O loop has one monotonic deadline,
    /// tolerates short transfers/EINTR and leaves no blocking read on XCTest's thread.
    private final class Client {
        private let fd: Int32

        init(path: String) throws {
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                close(socketFD)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                let code = errno
                close(socketFD)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var noSignal: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            guard fcntl(socketFD, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
                let code = errno
                close(socketFD)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            fd = socketFD
        }

        deinit { close(fd) }

        func write(_ data: Data) throws {
            let deadline = ContinuousClock.now + .seconds(5)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try ready(POLLOUT, until: deadline)
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
                    else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
            }
        }

        func read(count: Int) throws -> Data {
            try receive(count: count)
        }

        func readToEOF() throws -> Data {
            try receive(count: nil)
        }

        private func receive(count expected: Int?) throws -> Data {
            let deadline = ContinuousClock.now + .seconds(5)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while expected == nil || result.count < expected! {
                try ready(POLLIN, until: deadline)
                let capacity = expected.map { min(buffer.count, $0 - result.count) } ?? buffer.count
                let count = Darwin.read(fd, &buffer, capacity)
                if count > 0 { result.append(contentsOf: buffer.prefix(count)) }
                else if count == 0 {
                    if expected != nil { throw TestError.unexpectedEOF }
                    return result
                } else if [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
                else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            return result
        }

        private func ready(_ events: Int32, until deadline: ContinuousClock.Instant) throws {
            while ContinuousClock.now < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
                let count = poll(&descriptor, 1, 100)
                if count > 0 { return } // HUP/ERR are resolved by the next read/write.
                if count < 0 && errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            throw TestError.timeout
        }
    }
}

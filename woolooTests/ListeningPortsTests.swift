import Darwin
import XCTest
@testable import wooloo

final class ListeningPortsTests: XCTestCase {
    /// The script's output on Linux (`ss`), from a Herdr session `work` and the `default` one.
    private static let ssOutput = """
        L|221887|127.0.0.1:18765|python3
        L|300|0.0.0.0:3000|node
        L|300|[::]:3000|node
        L|301|[::1]:5173|node
        L|302|192.168.1.20:8080|java
        L|303|[fe80::1]%eth0:9000|server
        L|128564|127.0.0.1:45733|claude
        L|200949|127.0.0.1:36523|2.1.325
        L|400|127.0.0.53%lo:53|systemd-resolve
        L|bad|127.0.0.1:1|x
        L|500|127.0.0.1:99999|x
        E|221887|w1|work|python3 -m http.server 18765 --bind 127.0.0.1
        E|300|w2|work|node server.js
        E|301|w2|work|node vite
        E|302|w2|work|java -jar app.jar
        E|303|w3|other|server
        E|128564|w1|work|claude
        E|200949|w1|work|/home/me/.local/share/claude/versions/2.1.325 --session-id x
        """

    /// The script's output on macOS (`lsof`), in the `default` session, whose panes have an
    /// empty `HERDR_SESSION`.
    private static let lsofOutput = """
        L|900|*:4000|ruby
        L|901|127.0.0.1:8000|Python
        E|900|w5||ruby bin/rails server
        E|901|w5||/usr/bin/python3 -m http.server
        """

    func testParsesSSOutputBySpaceForItsSession() throws {
        let scan = try ListeningPortScanner.parse(Self.ssOutput, session: "work")
        XCTAssertEqual(scan.spaces["w1"]?.map(\.port), [18765])
        XCTAssertEqual(scan.spaces["w1"]?.first?.bind, .loopback)
        XCTAssertEqual(scan.spaces["w1"]?.first?.process, "python3")
        XCTAssertEqual(scan.spaces["w2"]?.map(\.port), [3000, 5173, 8080])
        // IPv4 and IPv6 listeners on one port count once.
        XCTAssertEqual(scan.spaces["w2"]?.first?.bind, .any)
        XCTAssertEqual(scan.spaces["w2"]?[1].bind, .loopback)
        XCTAssertEqual(scan.spaces["w2"]?[2].bind, .address("192.168.1.20"))
        // Another session's Space is left out.
        XCTAssertNil(scan.spaces["w3"])
        // Every listener of the machine is known, for forwards, including other sessions' and
        // processes outside Herdr; malformed lines are skipped.
        XCTAssertEqual(scan.machinePorts, [18765, 3000, 5173, 8080, 9000, 45733, 36523, 53])
    }

    func testDefaultSessionMatchesPanesWithoutASessionName() throws {
        let scan = try ListeningPortScanner.parse(Self.lsofOutput, session: "default")
        XCTAssertEqual(scan.spaces["w5"]?.map(\.port), [4000, 8000])
        XCTAssertEqual(try ListeningPortScanner.parse(Self.lsofOutput, session: "work").spaces, [:])
    }

    func testAgentListenersAreNotServices() throws {
        let scan = try ListeningPortScanner.parse(Self.ssOutput, session: "work")
        XCTAssertFalse(scan.spaces["w1", default: []].contains { $0.port == 45733 || $0.port == 36523 })
        XCTAssertTrue(ListeningPortScanner.isAgent(process: "node", command: "node /usr/lib/node_modules/@openai/codex/bin/codex.js"))
        XCTAssertTrue(ListeningPortScanner.isAgent(process: "codex", command: ""))
        XCTAssertFalse(ListeningPortScanner.isAgent(process: "node", command: "node server.js"))
    }

    func testMissingToolsAreAnError() {
        XCTAssertThrowsError(try ListeningPortScanner.parse("N\n", session: "work"))
        XCTAssertEqual(try ListeningPortScanner.parse("", session: "work"), ListeningPortScan())
    }

    func testPortsPerSpaceAreCapped() throws {
        let lines = (1...40).map { "L|7|127.0.0.1:\(10_000 + $0)|node" } + ["E|7|w1|work|node"]
        let scan = try ListeningPortScanner.parse(lines.joined(separator: "\n"), session: "work")
        XCTAssertEqual(scan.spaces["w1"]?.count, ListeningPortScanner.portsPerSpace)
        XCTAssertEqual(scan.spaces["w1"]?.first?.port, 10_001)
    }

    func testAddresses() {
        func parsed(_ text: String) -> String? {
            ListeningPortScanner.address(text).map { "\($0.0.text) \($0.1)" }
        }
        XCTAssertEqual(parsed("*:3000"), "* 3000")
        XCTAssertEqual(parsed("0.0.0.0:80"), "* 80")
        XCTAssertEqual(parsed("[::]:5173"), "* 5173")
        XCTAssertEqual(parsed("127.0.0.1:8000"), "localhost 8000")
        XCTAssertEqual(parsed("[::1]:8000"), "localhost 8000")
        XCTAssertEqual(parsed("127.0.0.53%lo:53"), "localhost 53")
        XCTAssertEqual(parsed("[fe80::1]%eth0:9000"), "fe80::1 9000")
        XCTAssertEqual(parsed("10.0.0.2:22"), "10.0.0.2 22")
        XCTAssertNil(parsed("127.0.0.1:0"))
        XCTAssertNil(parsed("127.0.0.1:http"))
        XCTAssertEqual(ListeningPort.Bind.address("fe80::1").host, "[fe80::1]")
        XCTAssertEqual(ListeningPort.Bind.any.host, "localhost")
    }

    /// The script finds a real listener on this Mac, started with a Herdr pane's environment,
    /// both directly and over a fake ssh. This checks `lsof` and `ps -E` on the running macOS.
    func testScriptFindsAListenerStartedInAPane() throws {
        let port = try XCTUnwrap(LocalPorts.ephemeral())
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "127.0.0.1", String(port)]
        listener.environment = ["PATH": "/usr/bin:/bin", "HERDR_WORKSPACE_ID": "w9", "HERDR_SESSION": "wooloo-ports-test"]
        listener.standardInput = Pipe()
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { listener.terminate() }

        var found: [ListeningPort] = []
        for _ in 0..<20 where found.isEmpty {
            found = try ListeningPortScanner.scan(machine: nil, session: "wooloo-ports-test").spaces["w9"] ?? []
            if found.isEmpty { usleep(100_000) }
        }
        XCTAssertEqual(found.map(\.port), [port])
        XCTAssertEqual(found.first?.pid, listener.processIdentifier)

        let sandbox = try WorkspaceGitSandbox()
        defer {
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            for command; do :; done
            exec /bin/sh -c "$command"
            """], in: ".")
        try sandbox.sh("chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
        let machine = HerdrMachineProfile(id: "dev", label: "Dev", target: "dev.example.test",
                                          session: "wooloo-ports-test", enabled: true)
        let remote = try ListeningPortScanner.scan(machine: machine, session: "wooloo-ports-test")
        XCTAssertEqual(remote.spaces["w9"]?.map(\.port), [port])
        XCTAssertTrue(remote.machinePorts.contains(port))
    }

    @MainActor
    func testMonitorKeepsTheLastPortsWhenAScanFails() throws {
        let monitor = ListeningPortsMonitor()
        let scan = try ListeningPortScanner.parse(Self.ssOutput, session: "work")
        monitor.apply(.success(scan))
        monitor.apply(.failure(WorkspaceFileError.message("ssh failed")))
        XCTAssertEqual(monitor.ports(inSpace: "w2").map(\.port), [3000, 5173, 8080])
        XCTAssertEqual(monitor.failure, "ssh failed")
        monitor.apply(.success(scan))
        XCTAssertNil(monitor.failure)
    }

    // MARK: Forwards

    private let machine = HerdrMachineProfile(id: "box", label: "Box", target: "ssh://dev@box.example.test:2222",
                                              session: "work", enabled: true)

    func testForwardArgumentsUseAConnectionOfTheirOwn() {
        let key = PortForwards.Key(machineID: "box", remoteHost: "localhost", remotePort: 3000)
        let arguments = PortForwards.arguments(machine: machine, key: key, localPort: 13000)
        XCTAssertEqual(Array(arguments.suffix(4)), ["-L", "127.0.0.1:13000:localhost:3000", "--", "dev@box.example.test"])
        XCTAssertTrue(arguments.contains("ControlPath=none"))
        XCTAssertTrue(arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("LocalCommand=echo \(PortForwards.readyMarker)"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(arguments.first, "-N")
    }

    func testLocalPortsPreferTheRemoteNumberWhenFree() throws {
        let free = try XCTUnwrap(LocalPorts.ephemeral())
        XCTAssertEqual(LocalPorts.choose(preferred: free), free)

        // A port in use gets another one.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let busy = Int(UInt16(bigEndian: actual.sin_port))
        XCTAssertFalse(LocalPorts.isFree(busy))
        let chosen = LocalPorts.choose(preferred: busy)
        XCTAssertNotEqual(chosen, busy)
        XCTAssertGreaterThan(chosen, 0)
    }

    @MainActor
    func testForwardStartsOnceAndEndsWhenThePortGoesAway() async throws {
        let forwards = PortForwards()
        let launched = LaunchLog()
        forwards.launcher = { arguments in
            launched.append(arguments)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            do { try process.run() } catch { return .failure(error) }
            return .success(ForwardProcess(process: process))
        }
        let port = ListeningPort(port: 3000, bind: .any, pid: 1, process: "node")
        let key = PortForwards.key(machine: machine, port: port)

        let local = try XCTUnwrap(await forwards.forward(port, on: machine))
        XCTAssertEqual(forwards.state(key), .active(localPort: local))
        XCTAssertEqual(launched.count, 1)
        // A second click reuses the running forward.
        let again = await forwards.forward(port, on: machine)
        XCTAssertEqual(again, local)
        XCTAssertEqual(launched.count, 1)

        forwards.retain(machineID: machine.id, livePorts: [3000])
        XCTAssertEqual(forwards.state(key), .active(localPort: local))
        forwards.retain(machineID: machine.id, livePorts: [4000])
        XCTAssertNil(forwards.state(key))
    }

    @MainActor
    func testFailedForwardRetriesOnceAndReportsWhy() async {
        let forwards = PortForwards()
        let launched = LaunchLog()
        forwards.launcher = { arguments in
            launched.append(arguments)
            return .failure(WorkspaceFileError.message("unreachable"))
        }
        let port = ListeningPort(port: 8080, bind: .address("10.0.0.2"), pid: 1, process: "java")
        let result = await forwards.forward(port, on: machine)
        XCTAssertNil(result)
        XCTAssertEqual(launched.count, 2)
        XCTAssertTrue(launched.all.allSatisfy { $0.contains { $0.hasSuffix(":10.0.0.2:8080") } })
        XCTAssertEqual(forwards.state(PortForwards.key(machine: machine, port: port)), .failed("unreachable"))
    }

    @MainActor
    func testStopAllEndsEveryForward() async throws {
        let forwards = PortForwards()
        let launched = LaunchLog()
        forwards.launcher = { arguments in
            launched.append(arguments)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            do { try process.run() } catch { return .failure(error) }
            return .success(ForwardProcess(process: process))
        }
        for number in [3000, 3001] {
            let port = ListeningPort(port: number, bind: .loopback, pid: 1, process: "node")
            _ = try XCTUnwrap(await forwards.forward(port, on: machine))
        }
        XCTAssertEqual(launched.count, 2)
        XCTAssertEqual(forwards.states.count, 2)
        forwards.stopAll()
        XCTAssertTrue(forwards.states.isEmpty)
    }
}

/// Arguments of each launched forward, recorded from the launcher's thread.
private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = []
    func append(_ arguments: [String]) { lock.lock(); entries.append(arguments); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return entries }
}

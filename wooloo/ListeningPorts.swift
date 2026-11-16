import Darwin
import Foundation

/// A TCP port a process in a Space listens on.
struct ListeningPort: Hashable, Identifiable, Sendable {
    enum Bind: Hashable, Sendable {
        /// Every interface (`*`, `0.0.0.0`, `[::]`).
        case any
        /// Loopback only (`127.0.0.1`, `::1`, `localhost`).
        case loopback
        /// One address, such as a LAN or link-local one (zone removed).
        case address(String)

        /// Wider binds win when one port listens twice, on IPv4 and IPv6.
        var reach: Int {
            switch self {
            case .any: 2
            case .address: 1
            case .loopback: 0
            }
        }

        /// The host part of a URL or forward that reaches this bind from the machine itself.
        var host: String {
            switch self {
            case .any, .loopback: "localhost"
            case .address(let address): address.contains(":") ? "[\(address)]" : address
            }
        }

        var text: String {
            switch self {
            case .any: "*"
            case .loopback: "localhost"
            case .address(let address): address
            }
        }
    }

    let port: Int
    let bind: Bind
    let pid: Int32
    /// The listening process's name, as `ss` or `lsof` reports it.
    let process: String

    var id: Int { port }
}

/// What one scan of a machine found.
struct ListeningPortScan: Equatable, Sendable {
    /// Ports per Herdr Space (`HERDR_WORKSPACE_ID`) of the scanned session, sorted by port.
    var spaces: [String: [ListeningPort]] = [:]
    /// Every TCP port listening on the machine, from any process the user can see. A forward
    /// stays open while its port is here, whichever session started it.
    var machinePorts: Set<Int> = []
}

enum ListeningPortScanner {
    /// Ports shown per Space; a dev server rarely opens more.
    static let portsPerSpace = 32

    /// A read-only POSIX sh script. It lists TCP listeners with `ss` (Linux) or `lsof` (macOS),
    /// one `L|pid|address:port|process` line each, then one `E|pid|space|session|command` line for
    /// each listening process started in a Herdr pane, read from its environment
    /// (`/proc/<pid>/environ` on Linux, `ps -E` on macOS). It prints `N` when neither tool exists.
    /// Only the user's own processes are visible, which is enough for what runs in its panes.
    static let script = #"""
        LC_ALL=C; export LC_ALL
        PATH="$PATH:/usr/sbin:/sbin"; export PATH
        if command -v ss >/dev/null 2>&1; then
          listeners=$(ss -ltnp 2>/dev/null | awk 'NR > 1 && /pid=/ {
            pid = $0; sub(/.*pid=/, "", pid); sub(/[^0-9].*/, "", pid)
            cmd = ""; if (match($0, /\(\("[^"]*"/)) cmd = substr($0, RSTART + 3, RLENGTH - 4)
            print "L|" pid "|" $4 "|" cmd }' | head -n 1024)
        elif command -v lsof >/dev/null 2>&1; then
          listeners=$(lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '
            /^p/ { pid = substr($0, 2) } /^c/ { cmd = substr($0, 2) }
            /^n/ { print "L|" pid "|" substr($0, 2) "|" cmd }' | head -n 1024)
        else
          echo N
          exit 0
        fi
        [ -n "$listeners" ] || exit 0
        printf '%s\n' "$listeners"
        printf '%s\n' "$listeners" | cut -d '|' -f 2 | sort -un | head -n 128 | while read -r pid; do
          [ -n "$pid" ] || continue
          if [ -r "/proc/$pid/environ" ]; then
            env=$(tr '\000' '\n' < "/proc/$pid/environ" 2>/dev/null)
          else
            env=$(ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n')
          fi
          space=$(printf '%s\n' "$env" | sed -n 's/^HERDR_WORKSPACE_ID=//p' | head -n 1)
          [ -n "$space" ] || continue
          session=$(printf '%s\n' "$env" | sed -n 's/^HERDR_SESSION=//p' | head -n 1)
          args=$(ps -o args= -p "$pid" 2>/dev/null | head -n 1 | cut -c 1-300)
          echo "E|$pid|$space|$session|$args"
        done
        """#

    /// Scans `machine`, or this Mac when nil.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func scan(machine: HerdrMachineProfile?, session: String) throws -> ListeningPortScan {
        let data: Data
        if let machine {
            data = try WorkspaceFiles.remoteOutput(machine, script: script, label: "listening-ports", limit: 256_000)
        } else {
            data = try WorkspaceFiles.run("/bin/sh", ["-c", script], limit: 256_000, timeout: 10, label: "listening-ports")
        }
        return try parse(String(decoding: data, as: UTF8.self), session: session)
    }

    /// Parses the script's output, keeping the Spaces of `session`. Herdr leaves
    /// `HERDR_SESSION` empty in the `default` session's panes.
    static func parse(_ output: String, session: String) throws -> ListeningPortScan {
        struct Listener { let pid: Int32; let port: Int; let bind: ListeningPort.Bind; let process: String }
        struct Owner { let space: String; let session: String; let command: String }
        var listeners: [Listener] = []
        var owners: [Int32: Owner] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            if line == "N" { throw WorkspaceFileError.message("Neither ss nor lsof is available to list ports") }
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch fields[0] {
            case "L" where fields.count >= 4:
                guard let pid = Int32(fields[1]), let parsed = address(fields[2]) else { continue }
                listeners.append(Listener(pid: pid, port: parsed.port, bind: parsed.bind, process: fields[3]))
            case "E" where fields.count >= 4:
                guard let pid = Int32(fields[1]), !fields[2].isEmpty else { continue }
                owners[pid] = Owner(space: fields[2], session: fields[3], command: fields.count > 4 ? fields[4] : "")
            default:
                continue
            }
        }
        var scan = ListeningPortScan(machinePorts: Set(listeners.map(\.port)))
        var spaces: [String: [Int: ListeningPort]] = [:]
        for listener in listeners {
            guard let owner = owners[listener.pid],
                  owner.session == session || (owner.session.isEmpty && session == "default"),
                  !isAgent(process: listener.process, command: owner.command) else { continue }
            let port = ListeningPort(port: listener.port, bind: listener.bind, pid: listener.pid, process: listener.process)
            if let existing = spaces[owner.space]?[listener.port], existing.bind.reach >= port.bind.reach { continue }
            spaces[owner.space, default: [:]][listener.port] = port
        }
        scan.spaces = spaces.mapValues { Array($0.values.sorted { $0.port < $1.port }.prefix(portsPerSpace)) }
        return scan
    }

    /// Splits `ss`/`lsof` addresses such as `127.0.0.1:8000`, `*:3000`, `[::]:5173`,
    /// `[fe80::1]%eth0:80` or `127.0.0.53%lo:53`.
    static func address(_ text: String) -> (bind: ListeningPort.Bind, port: Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
              (1...65_535).contains(port) else { return nil }
        var host = String(text[..<colon])
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch host {
        case "*", "", "0.0.0.0", "::", "::0":
            return (.any, port)
        case "localhost", "::1", "::ffff:127.0.0.1":
            return (.loopback, port)
        default:
            if host.hasPrefix("127.") { return (.loopback, port) }
            return (.address(host), port)
        }
    }

    /// Agent CLIs listen on loopback ports of their own (IDE and MCP bridges); those are not the
    /// Space's services. Claude Code's binary is named after its version, so the command decides.
    static func isAgent(process: String, command: String) -> Bool {
        let names: Set<String> = ["claude", "codex", "opencode", "gemini", "cursor-agent", "amp", "droid",
                                  "goose", "aider", "crush", "qwen", "kilo", "kiro", "copilot", "grok", "hermes"]
        let executable = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? $0) } ?? ""
        if names.contains(process.lowercased()) || names.contains(executable.lowercased()) { return true }
        return ["/claude/versions/", "@anthropic-ai/claude-code", "@openai/codex", "/codex/bin/"]
            .contains { command.contains($0) }
    }
}

/// Scans a Herdr connection's machine every few seconds while its sidebar section is visible.
/// Publishes only when the result changes, so an unchanged scan redraws nothing.
@MainActor
final class ListeningPortsMonitor: ObservableObject {
    struct Target: Equatable {
        var machine: HerdrMachineProfile?
        var session: String
    }

    @Published private(set) var scan = ListeningPortScan()
    @Published private(set) var failure: String?
    private(set) var target: Target?
    private var task: Task<Void, Never>?
    let interval: Duration
    let retryInterval: Duration

    init(interval: Duration = .seconds(5), retryInterval: Duration = .seconds(30)) {
        self.interval = interval
        self.retryInterval = retryInterval
    }

    func ports(inSpace workspaceID: String) -> [ListeningPort] { scan.spaces[workspaceID] ?? [] }

    func start(_ target: Target) {
        if task != nil, target == self.target { return }
        stop()
        if target != self.target {
            scan = ListeningPortScan()
            failure = nil
        }
        self.target = target
        let worker = BlockingWorker(label: "dev.wooloo.listening-ports")
        task = Task { [weak self, interval, retryInterval] in
            while !Task.isCancelled {
                let result = await WorkspaceFiles.blocking(on: target.machine, worker: worker) {
                    Result { try ListeningPortScanner.scan(machine: target.machine, session: target.session) }
                }
                guard !Task.isCancelled, let self else { return }
                self.apply(result)
                var failed = false
                if case .failure = result { failed = true }
                try? await Task.sleep(for: failed ? retryInterval : interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func apply(_ result: Result<ListeningPortScan, Error>) {
        switch result {
        case .success(let next):
            if next != scan { scan = next }
            if failure != nil { failure = nil }
            if let machine = target?.machine {
                PortForwards.shared.retain(machineID: machine.id, livePorts: next.machinePorts)
            }
        case .failure(let error):
            // The last good ports stay on screen.
            if failure != error.localizedDescription { failure = error.localizedDescription }
        }
    }
}

/// SSH local forwards that bring a remote Space's ports to this Mac, one `ssh -N -L` process
/// each. A forward of its own, rather than one added to the shared ControlMaster
/// (`ssh -O forward`): the master would keep the forward after wooloo stops wanting it, and
/// `ControlPersist` would close it once no command uses the connection. Forwards never
/// reconnect; one that ends shows as not forwarded.
@MainActor
final class PortForwards: ObservableObject {
    static let shared = PortForwards()

    struct Key: Hashable, Sendable {
        let machineID: String
        let remoteHost: String
        let remotePort: Int
    }

    enum State: Equatable {
        case starting
        case active(localPort: Int)
        case failed(String)
    }

    static let maximumForwards = 32
    static let readyMarker = "wooloo-forward-ready"

    @Published private(set) var states: [Key: State] = [:]
    private var processes: [Key: Process] = [:]
    /// The local port each remote port used last, so a page keeps its address between forwards.
    private var lastLocalPorts: [Key: Int] = [:]

    /// Tests replace how a forward starts: given ssh's arguments, it returns the running
    /// process once the forward is ready, or why it failed.
    var launcher: @Sendable (_ arguments: [String]) -> Result<ForwardProcess, Error> = PortForwards.launch

    static func key(machine: HerdrMachineProfile, port: ListeningPort) -> Key {
        Key(machineID: machine.id, remoteHost: port.bind.host, remotePort: port.port)
    }

    func state(_ key: Key) -> State? { states[key] }

    /// Starts forwarding `port` from `machine`, or returns the local port of a running forward.
    /// Nil when the forward could not start; its state then says why.
    func forward(_ port: ListeningPort, on machine: HerdrMachineProfile) async -> Int? {
        let key = Self.key(machine: machine, port: port)
        switch states[key] {
        case .active(let local): return local
        case .starting: return nil
        default: break
        }
        guard processes.count < Self.maximumForwards else {
            states[key] = .failed("Too many forwarded ports; stop one first")
            return nil
        }
        states[key] = .starting
        let preferred = lastLocalPorts[key] ?? port.port
        let launcher = launcher
        // Two tries: a free port can be taken between choosing it and ssh binding it.
        for attempt in 0..<2 {
            let local = LocalPorts.choose(preferred: attempt == 0 ? preferred : nil)
            let arguments = Self.arguments(machine: machine, key: key, localPort: local)
            let result = await Task.detached { launcher(arguments) }.value
            guard states[key] == .starting else {
                // Stopped while starting.
                if case .success(let forward) = result { forward.process.terminate() }
                return nil
            }
            switch result {
            case .success(let forward):
                let process = forward.process
                processes[key] = process
                lastLocalPorts[key] = local
                states[key] = .active(localPort: local)
                process.terminationHandler = { [weak self] exited in
                    let handoff = ForwardProcess(process: exited)
                    Task { @MainActor in self?.ended(key, process: handoff.process) }
                }
                if !process.isRunning {
                    ended(key, process: process)
                    return nil
                }
                return local
            case .failure(let error):
                if attempt == 1 { states[key] = .failed(error.localizedDescription) }
            }
        }
        return nil
    }

    func stop(_ key: Key) {
        processes.removeValue(forKey: key)?.terminate()
        states.removeValue(forKey: key)
    }

    /// Stops forwards from `machineID` whose remote port no longer listens.
    func retain(machineID: String, livePorts: Set<Int>) {
        for key in states.keys where key.machineID == machineID && !livePorts.contains(key.remotePort) {
            if case .starting = states[key] { continue }
            stop(key)
        }
    }

    /// Ends every forward; the app delegate calls it on quit.
    func stopAll() {
        for process in processes.values { process.terminate() }
        processes.removeAll()
        states.removeAll()
    }

    private func ended(_ key: Key, process: Process) {
        guard processes[key] === process else { return }
        processes.removeValue(forKey: key)
        states.removeValue(forKey: key)
    }

    static func arguments(machine: HerdrMachineProfile, key: Key, localPort: Int) -> [String] {
        let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
        var arguments = ["-N", "-T",
                         "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                         "-o", "ControlMaster=no", "-o", "ControlPath=none",
                         "-o", "ExitOnForwardFailure=yes",
                         "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                         "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=echo \(readyMarker)"]
        if let port = endpoint.port { arguments += ["-p", port] }
        arguments += ["-L", "127.0.0.1:\(localPort):\(key.remoteHost):\(key.remotePort)", "--", endpoint.destination]
        return arguments
    }

    /// Starts `ssh` and waits up to 15 s for the ready line, which ssh prints once it is
    /// connected and listening locally. Its stderr is dropped: it can hold secrets.
    nonisolated static func launch(_ arguments: [String]) -> Result<ForwardProcess, Error> {
        guard let destination = arguments.last, !destination.isEmpty, !destination.hasPrefix("-") else {
            return .failure(WorkspaceFileError.message("Invalid SSH target"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WorkspaceFiles.sshExecutable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(error) }
        let reader = output.fileHandleForReading
        let ready = DispatchSemaphore(value: 0)
        let found = ReadyFlag()
        Thread {
            var buffer = Data()
            while let chunk = try? reader.read(upToCount: 4_096), !chunk.isEmpty {
                buffer.append(chunk)
                if String(decoding: buffer, as: UTF8.self).contains(readyMarker) {
                    found.set()
                    ready.signal()
                    // Keep draining, so ssh never blocks on a full pipe.
                    while let more = try? reader.read(upToCount: 4_096), !more.isEmpty {}
                    return
                }
                if buffer.count > 65_536 { buffer.removeAll() }
            }
            ready.signal()
        }.start()
        _ = ready.wait(timeout: .now() + 15)
        guard found.isSet, process.isRunning else {
            process.terminate()
            return .failure(WorkspaceFileError.message("The SSH forward did not start; check that the machine is reachable and the local port is free"))
        }
        return .success(ForwardProcess(process: process))
    }
}

/// A forward's `ssh` process, handed from the thread that started it to the main actor, which
/// owns it from then on.
struct ForwardProcess: @unchecked Sendable {
    let process: Process
}

/// A flag set once from one thread and read from another.
private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Picks local ports for forwards on 127.0.0.1.
enum LocalPorts {
    /// `preferred` when free (shifted by 10,000 below 1024, which needs root), otherwise a port
    /// the system picks.
    static func choose(preferred: Int?) -> Int {
        if let preferred {
            let shifted = preferred < 1024 ? preferred + 10_000 : preferred
            if shifted <= 65_535, isFree(shifted) { return shifted }
        }
        return ephemeral() ?? 0
    }

    static func isFree(_ port: Int) -> Bool { bind(port) != nil }

    static func ephemeral() -> Int? { bind(0) }

    /// Binds a TCP socket on 127.0.0.1 and returns the port it got, then closes it.
    private static func bind(_ port: Int) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}

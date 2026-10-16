import Foundation
import Darwin

/// Private local sockets adapt Herdr's API and terminal stdio bridges to our existing
/// socket clients. Each accepted connection owns an SSH channel, never a remote shell pane.
/// Closing this attachment leaves the remote server, Spaces and agents running.
final class HerdrRemoteBridge: @unchecked Sendable {
    let directory: URL
    var apiPath: String { directory.appendingPathComponent("api").path }
    var clientPath: String { directory.appendingPathComponent("client").path }
    private let queue = DispatchQueue(label: "dev.wooloo.remote-bridge")
    private var listeners: [DispatchSourceRead] = []
    private var children: [UUID: (Process, FileHandle, Pipe)] = [:]
    private let queueKey = DispatchSpecificKey<Bool>()
    private let errorLock = NSLock()
    private var diagnostic = ""
    var lastError: String? {
        errorLock.lock(); defer { errorLock.unlock() }
        let text = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.suffix(2000))
    }
    private var stopped = false
    private let machine: HerdrMachineProfile
    private let executable: String

    init(machine: HerdrMachineProfile, sshExecutable: String = WorkspaceFiles.sshExecutable) throws {
        let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
        guard !endpoint.destination.isEmpty, !endpoint.destination.hasPrefix("-"),
              machine.session.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw WorkspaceFileError.message("Invalid remote host or session")
        }
        self.machine = machine
        executable = sshExecutable
        // UNIX socket paths must fit sun_path, even when the app's cache path is long.
        directory = URL(fileURLWithPath: "/tmp/wl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        queue.setSpecific(key: queueKey, value: true)
        do {
            try listen(at: apiPath, command: "remote-api-bridge")
            try listen(at: clientPath, command: "remote-client-bridge")
        } catch {
            stop()
            throw error
        }
    }

    private func listen(at path: String, command: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)
        fcntl(fd, F_SETFL, O_NONBLOCK)
        fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            while true {
                let accepted = accept(fd, nil, nil)
                guard accepted >= 0 else { break }
                self.attach(accepted, command: command)
            }
        }
        source.setCancelHandler { close(fd) }
        listeners.append(source)
        source.resume()
    }

    private func attach(_ fd: Int32, command: String) {
        fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(machine, command: command)
        process.standardInput = handle
        process.standardOutput = handle
        // SSH diagnostics must never enter either wire protocol.
        let errors = Pipe()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.errorLock.lock()
            self.diagnostic = String((self.diagnostic + String(decoding: data, as: UTF8.self)).suffix(4000))
            self.errorLock.unlock()
        }
        process.standardError = errors
        let id = UUID()
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.children.removeValue(forKey: id) }
        }
        do {
            try process.run()
            children[id] = (process, handle, errors)
        } catch {
            try? handle.close()
        }
    }

    static func arguments(_ machine: HerdrMachineProfile, command: String) -> [String] {
        let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                    "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        if let directory = WorkspaceFiles.sshControlDirectory {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(directory)/%C", "-o", "ControlPersist=60"]
        }
        if let port = endpoint.port { args += ["-p", port] }
        // Find Herdr on PATH or in common installation locations; never install software as
        // a side effect of selecting a machine. Shell quoting keeps profile data literal.
        let script = """
        h=$(command -v herdr 2>/dev/null)
        for candidate in "$h" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr /home/linuxbrew/.linuxbrew/bin/herdr "$HOME/.cargo/bin/herdr" "$HOME/.local/share/mise/installs/herdr/\(HerdrRuntimePaths.version)/bin/herdr" "$HOME/.local/share/mise/installs/herdr/\(HerdrRuntimePaths.version)/herdr" "$HOME/.nix-profile/bin/herdr" /run/current-system/sw/bin/herdr /nix/var/nix/profiles/default/bin/herdr; do
            [ -x "$candidate" ] || continue
            capability=$("$candidate" --session \(quote(machine.session)) remote-api-bridge --check </dev/null 2>/dev/null)
            [ "$capability" = herdr-api-bridge-v1 ] || continue
            exec "$candidate" --session \(quote(machine.session)) \(command)
        done
        printf '%s\\n' 'A compatible Herdr is not installed on this host; prepare it in Manage Remote Hosts' >&2
        exit 127
        """
        args += [endpoint.destination, "/bin/sh -c " + quote(script)]
        return args
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        for (process, handle, errors) in children.values {
            errors.fileHandleForReading.readabilityHandler = nil
            shutdown(handle.fileDescriptor, SHUT_RDWR)
            if process.isRunning { process.terminate() }
        }
        children.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

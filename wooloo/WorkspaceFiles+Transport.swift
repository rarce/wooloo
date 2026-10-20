import Darwin
import Foundation
import os

// Implementation of the shared WorkspaceFiles facade.
extension WorkspaceFiles {
    /// Where the Herdr command is looked for, in order; tests replace it.
    private static var overriddenHerdrCandidates: [String]?
    static var herdrCandidates: [String] {
        get { overriddenHerdrCandidates ?? HerdrRuntimePaths.executableCandidates }
        set { overriddenHerdrCandidates = newValue }
    }

    private static func herdrExecutable() throws -> String {
        guard let executable = herdrCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WorkspaceFileError.message("Herdr executable was not found")
        }
        return executable
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func machines(includeDisabled: Bool = false) throws -> [HerdrMachineProfile] {
        let executable = try herdrExecutable()
        let data = try run(executable, ["machine", "list", "--json"], limit: 200_000)
        return try JSONDecoder().decode([HerdrMachineProfile].self, from: data).filter { includeDisabled || $0.enabled }
    }

    /// Delegate persistence and remote preparation to Herdr, which owns machine profiles.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func manageMachine(_ arguments: [String]) throws {
        _ = try run(herdrExecutable(), ["machine"] + arguments, input: Data(),
                    limit: 200_000, timeout: 120, label: "herdr-machine")
    }

    /// Runs `herdr --machine` here, which reaches the machine on a connection of its own rather
    /// than the shared ControlMaster, so it counts against this Mac's limit.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func remoteSnapshot(_ machine: HerdrMachineProfile) throws -> HerdrSnapshot {
        let executable = try herdrExecutable()
        let data = try run(executable, ["--machine", machine.id, "api", "snapshot"], limit: 8_000_000)
        return try JSONDecoder().decode(RemoteSnapshotResponse.self, from: data).result.snapshot
    }

    /// Runs a POSIX shell script in the Space root: locally with /bin/sh, remotely over SSH,
    /// so both paths execute the same text.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func shell(_ script: String, at location: WorkspaceFileLocation, limit: Int) throws -> Data {
        let rooted = "cd \(quote(location.root)) || exit 3\n" + script
        if let machine = location.machine { return try ssh(machine, rooted, limit: limit) }
        return try run("/bin/sh", ["-c", rooted], limit: limit)
    }

    /// What a failed command reports: its errors, or its output when it wrote no errors.
    // Shared by the WorkspaceFiles implementation files.
    static func failureMessage(errors: Data, output: Data) -> String {
        [errors, output].lazy
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Command failed"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Blocking work per machine

    /// Runs blocking work on `location`, such as a listing, a read or a Git command, off the
    /// cooperative pool (see `BlockingWork`), under the limit of the location's machine: a slow
    /// SSH machine then holds only its own slots, and local loads keep running.
    static func blocking<Value: Sendable>(at location: WorkspaceFileLocation, priority: TaskPriority? = nil,
                                          worker: BlockingWorker? = nil,
                                          _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await blocking(on: location.machine, priority: priority, worker: worker, work)
    }

    /// Returns `Value.cancelled` instead of running `work` when cancelled.
    static func blocking<Value: BlockingWorkCancellable & Sendable>(at location: WorkspaceFileLocation,
                                                                    priority: TaskPriority? = nil,
                                                                    worker: BlockingWorker? = nil,
                                                                    _ work: @escaping @Sendable () -> Value) async -> Value {
        await blocking(on: location.machine, priority: priority, worker: worker, work)
    }

    /// Runs blocking work that reaches `machine`, or this Mac when nil, under that machine's limit.
    /// With a `worker`, the work runs on that worker's thread.
    static func blocking<Value: Sendable>(on machine: HerdrMachineProfile?, priority: TaskPriority? = nil,
                                          worker: BlockingWorker? = nil,
                                          _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await BlockingWork.run(priority: priority, reaching: BlockingWorkMachine(machine), on: worker, work)
    }

    /// Returns `Value.cancelled` instead of running `work` when cancelled.
    static func blocking<Value: BlockingWorkCancellable & Sendable>(on machine: HerdrMachineProfile?,
                                                                    priority: TaskPriority? = nil,
                                                                    worker: BlockingWorker? = nil,
                                                                    _ work: @escaping @Sendable () -> Value) async -> Value {
        await BlockingWork.run(priority: priority, reaching: BlockingWorkMachine(machine), on: worker, work)
    }

    /// Where `ssh` connects for a machine: the destination and port it passes, from a target such
    /// as `user@host` or `ssh://user@host:2222`.
    struct SSHEndpoint: Hashable {
        let destination: String
        let port: String?

        init(_ target: String) {
            if target.hasPrefix("ssh://"), let url = URLComponents(string: target), let host = url.host {
                destination = (url.user.map { "\($0)@" } ?? "") + host
                port = url.port.map(String.init)
            } else {
                destination = target
                port = nil
            }
        }

        /// Names the connection SSH shares for this endpoint (`ControlPath=%C` hashes the user,
        /// host and port), so two spellings of one machine share one limit: the host in lower
        /// case, as SSH compares it, and port 22 the same as none. A `Host` alias in ssh_config
        /// that resolves to the same `HostName`, or a user left to ssh_config, would take
        /// `ssh -G` to tell apart, and gets a limit of its own: `box` and `dev@box`, where `dev`
        /// is the default user, also count as two machines.
        var connectionKey: String {
            let user = destination.range(of: "@", options: .backwards).map { String(destination[..<$0.upperBound]) } ?? ""
            let host = String(destination.dropFirst(user.count)).lowercased()
            return user + host + (port.flatMap { $0 == "22" ? nil : ":" + $0 } ?? "")
        }
    }

    // Shared by the WorkspaceFiles implementation files.
    static func ssh(_ machine: HerdrMachineProfile, _ command: String,
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15,
                            label: String = "sh") throws -> Data {
        let endpoint = SSHEndpoint(machine.target)
        let target = endpoint.destination
        guard !target.isEmpty, !target.hasPrefix("-") else {
            throw WorkspaceFileError.message("Invalid SSH target")
        }
        // Work started with `BlockingWork.run` alone counts against this Mac, and could take
        // more sessions on the machine's shared connection than sshd allows.
        assert(BlockingWork.holdsSlot(of: BlockingWorkMachine(machine)),
               "An SSH command for \(machine.target) runs in a slot of \(BlockingWork.currentMachine.map(String.init(describing:)) ?? "none"): start it with WorkspaceFiles.blocking(at:) or blocking(on:)")
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let directory = sshControlDirectory {
            // One connection per machine, kept for a minute, instead of a handshake per command.
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(directory)/%C", "-o", "ControlPersist=60"]
        }
        if let port = endpoint.port { args += ["-p", port] }
        args += [target, command]
        return try run(sshExecutable, args, input: input, limit: limit, timeout: timeout, label: label, remote: true)
    }

    /// Runs a short script on an SSH machine. Input stays on stdin, separate from the command.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func remoteOutput(_ machine: HerdrMachineProfile, script: String, label: String,
                             limit: Int = 64_000, input: Data? = nil) throws -> Data {
        try ssh(machine, script, input: input, limit: limit, timeout: 10, label: label)
    }

    /// Tests replace it with a script that runs the remote command locally.
    static var sshExecutable = "/usr/bin/ssh"

    /// Where SSH keeps the sockets of shared connections: a short path, since socket paths are
    /// limited to about 100 bytes, in a directory only this user can use. Nil turns sharing off.
    static let sshControlDirectory: String? = {
        let path = "/tmp/wooloo-ssh-\(getuid())"
        mkdir(path, 0o700)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return path
    }()

    private static let processTimeouts = DispatchQueue(label: "dev.wooloo.process-timeouts")

    /// Runs a process and returns its output. `label` names it in the process log, for
    /// example `git status`, and `remote` marks commands sent over SSH.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking, or BlockingWork.run for work on this Mac")
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                            input: Data? = nil, limit: Int, timeout: TimeInterval = 15,
                            label: String? = nil, remote: Bool = false) throws -> Data {
        let start = TerminalPipelineMetrics.now()
        var outputBytes = 0
        var status: Int32?
        var errorText: String?
        defer {
            WorkspaceProcessLog.record(label: label ?? (executable as NSString).lastPathComponent, remote: remote,
                                       start: start, bytes: outputBytes, status: status, errors: errorText)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        // Stderr stays apart from the output: SSH writes warnings there even when a command
        // succeeds, and they must not end up in a file's contents or a listing.
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let source = input.map { _ in Pipe() }
        // Without input, a command must not read the app's own stdin; SSH would forward it.
        process.standardInput = source ?? FileHandle.nullDevice
        // Waited on through the termination handler, not `waitUntilExit()`: that one runs the
        // thread's run loop and, when the loop has a source, notices the exit only when a turn of
        // it ends, often 60–140 ms after the process exited (docs/perf/README.md).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Drained on its own thread, so a command that writes a lot to stderr cannot stall on a full pipe.
        // A thread, not a global queue: callers block here on Swift's cooperative threads, and once they
        // reach the system's limit of threads for global queues, work queued there never runs and every
        // caller waits forever.
        var errorData = Data()
        let errorsRead = DispatchSemaphore(value: 0)
        Thread {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            errorsRead.signal()
        }.start()
        // Stops the command: SIGTERM, then SIGKILL 2 s later if it is still running, so a command
        // that ignores SIGTERM cannot hold the caller and its slot forever.
        let stop = {
            guard process.isRunning else { return }
            process.terminate()
            processTimeouts.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // A private serial queue gets a thread beyond that limit too, so the timeout always fires.
        let timer = DispatchSource.makeTimerSource(queue: processTimeouts)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { stop() }
        timer.resume()
        // Input is written on its own thread too, so a command that prints while it reads cannot fill
        // the output pipe and wait on us while we wait on it. A command that exits early closes the
        // pipe; writing then fails with EPIPE instead of a SIGPIPE that would end the app.
        var inputError: Error?
        var inputWritten: DispatchSemaphore?
        if let input, let source {
            let writer = source.fileHandleForWriting
            guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                process.terminate()
                timer.cancel()
                throw WorkspaceFileError.message("Could not prepare the command's input")
            }
            let written = DispatchSemaphore(value: 0)
            inputWritten = written
            Thread {
                do { try writer.write(contentsOf: input) }
                catch { inputError = error }
                try? writer.close()
                written.signal()
            }.start()
        }
        var data = Data()
        var readError: Error?
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit {
                    stop()
                    break
                }
            }
        } catch {
            // Stop the command rather than leave it, its threads and its timer behind.
            readError = error
            stop()
        }
        exited.wait()
        timer.cancel()
        // A process the command left running in the background can keep stderr or stdin open after
        // the command exits. Its threads are then left to finish on their own rather than waited on.
        let settled = DispatchTime.now() + 2
        let stderrRead = errorsRead.wait(timeout: settled) == .success
        let inputSettled = inputWritten.map { $0.wait(timeout: settled) == .success } ?? true
        let errorOutput = stderrRead ? errorData : Data()
        outputBytes = data.count
        // A signal means the timeout or the output limit stopped the process.
        status = process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
        if status != 0 { errorText = String(decoding: errorOutput, as: UTF8.self) }
        if let readError { throw readError }
        guard data.count <= limit else { throw WorkspaceFileError.message("Output is too large") }
        guard process.terminationStatus == 0 else {
            throw WorkspaceFileError.message(failureMessage(errors: errorOutput, output: data))
        }
        if inputSettled, let inputError { throw inputError }
        return data
    }
}

private struct RemoteSnapshotResponse: Decodable {
    let result: RemoteSnapshotResult
}

private struct RemoteSnapshotResult: Decodable {
    let snapshot: HerdrSnapshot
}

/// Every process `WorkspaceFiles` runs: git, SSH and shell commands behind the file explorer,
/// Git panels, diffs and documents. Each one goes to the metrics file as a `proc` event, and
/// benchmarks can collect them to count the processes an operation starts.
enum WorkspaceProcessLog {
    struct Record {
        let label: String
        let remote: Bool
        let nanos: UInt64
        let bytes: Int
        /// The exit status; the negated signal when one stopped the process; nil when it never ran.
        let status: Int32?
        var succeeded: Bool { status == 0 }
    }

    private static let lock = NSLock()
    private static var collected: [Record]?
    private static let logger = Logger(subsystem: "dev.wooloo.workspace", category: "process")

    /// Records a finished process. `errors` is its stderr, given only when it failed; failed SSH
    /// commands are logged with it, since SSH reports there why a connection or command failed.
    static func record(label: String, remote: Bool, start: UInt64, bytes: Int, status: Int32?, errors: String? = nil) {
        let nanos = TerminalPipelineMetrics.now() - start
        TerminalPipelineMetrics.shared?.process(label: label, remote: remote, start: start, nanos: nanos,
                                                bytes: bytes, status: status)
        if remote, status != 0 {
            // 255 is SSH's own failure (connection, shared connection or authentication);
            // other statuses come from the remote command.
            let statusText = status.map(String.init) ?? "none"
            let reason = summary(of: errors ?? "")
            logger.error("SSH \(label, privacy: .public) failed: status \(statusText, privacy: .public) after \(nanos / 1_000_000) ms, \(bytes) output bytes; stderr: \(reason, privacy: .public)")
        }
        lock.lock()
        collected?.append(Record(label: label, remote: remote, nanos: nanos, bytes: bytes, status: status))
        lock.unlock()
    }

    /// Stderr for the log: the last lines, cut to 1,000 characters, with credentials in URLs
    /// (`https://user:token@host`) removed.
    static func summary(of errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline).suffix(8).joined(separator: " | ")
        let redacted = lines.replacingOccurrences(of: #"://[^/@\s]+@"#, with: "://<redacted>@", options: .regularExpression)
        return String(redacted.suffix(1_000))
    }

    /// Runs `body` and returns the processes started meanwhile, from any thread.
    static func collect<T>(_ body: () throws -> T) rethrows -> (result: T, processes: [Record]) {
        lock.lock()
        collected = []
        lock.unlock()
        defer {
            lock.lock()
            collected = nil
            lock.unlock()
        }
        let result = try body()
        lock.lock()
        let processes = collected ?? []
        lock.unlock()
        return (result, processes)
    }
}

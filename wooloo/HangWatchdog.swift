import AppKit
import Darwin

/// Records where the main thread is stuck when the app stops responding. A background thread
/// pings the main thread; once a ping waits `threshold` seconds, it runs `/usr/bin/sample` on this
/// process into `~/Library/Logs/wooloo/Hangs`, then notes there when the main thread answers again.
/// The reports are local files: nothing is sent anywhere.
nonisolated final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/wooloo/Hangs", directoryHint: .isDirectory)
    }

    /// Reports kept; older ones are removed as new ones come.
    static let keptReports = 20

    /// Seconds an unanswered ping waits before the main thread counts as stuck. The spinning
    /// cursor appears after about two.
    private let threshold: TimeInterval = 3
    /// Seconds after a capture before another stall is sampled, so a run of stalls neither slows
    /// the app further nor pushes the first report out.
    private let cooldown: TimeInterval = 60
    /// Seconds between pings while the app is active, and while it is in the background.
    private let activeInterval: TimeInterval = 1
    private let inactiveInterval: TimeInterval = 5
    /// Seconds `sample` may take, symbolication included, before it is stopped.
    private let sampleLimit: TimeInterval = 30
    private let lock = NSLock()
    /// System uptime when the main thread ran the last ping, nil until it does.
    private var answeredAt: TimeInterval?
    private var active = true
    private var started = false

    /// Starts watching, except while hosting tests, under a debugger or with
    /// `WOOLOO_DISABLE_HANG_WATCHDOG` set.
    func start() {
        guard !WoolooApp.isHostingTests, !Self.isDebugged,
              ProcessInfo.processInfo.environment["WOOLOO_DISABLE_HANG_WATCHDOG"] == nil else { return }
        let first = lock.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "dev.wooloo.hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        var stall = Stall(threshold: threshold, cooldown: cooldown)
        var report: URL?
        while true {
            // System uptime stops while the Mac sleeps, so sleep is not a hang.
            let now = ProcessInfo.processInfo.systemUptime
            let (answeredAt, active) = lock.withLock { (self.answeredAt, self.active) }
            switch stall.step(at: now, answeredAt: answeredAt, interval: active ? activeInterval : inactiveInterval) {
            case .wait:
                break
            case .ping:
                ping()
            case .capture:
                // A debugger attached later and stopped at a breakpoint stops the main thread too.
                if !Self.isDebugged { report = capture() }
            case .recovered(let seconds):
                if let report { Self.append("The main thread answered again after \(Int(seconds.rounded())) s.\n", to: report) }
                report = nil
                ping()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func ping() {
        lock.withLock { answeredAt = nil }
        DispatchQueue.main.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            let active = MainActor.assumeIsolated { NSApp?.isActive ?? true }
            lock.withLock { (answeredAt, self.active) = (now, active) }
        }
    }

    /// Samples the whole process for two seconds into a new report, readable only by this user.
    private func capture() -> URL? {
        let manager = FileManager.default
        let directory = Self.directory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // A folder that already existed keeps its own permissions otherwise.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { return nil }
        let report = directory.appending(path: Self.reportName(for: Date()))
        // Created first, so the report is never readable by others while `sample` writes it.
        guard manager.createFile(atPath: report.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        let sample = Process()
        sample.executableURL = URL(filePath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "2", "-file", report.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
        } catch {
            try? manager.removeItem(at: report)
            return nil
        }
        // A `sample` that never finishes must not stop the watchdog for the rest of the session.
        let deadline = ProcessInfo.processInfo.systemUptime + sampleLimit
        while sample.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.1) }
        // SIGTERM, then SIGKILL 2 s later, as `WorkspaceFiles.run` stops a command.
        if sample.isRunning {
            sample.terminate()
            Thread.sleep(forTimeInterval: 2)
            if sample.isRunning { kill(sample.processIdentifier, SIGKILL) }
            sample.waitUntilExit()
        }
        // A `sample` that failed or was stopped leaves an empty or partial report, which would
        // only push real ones out.
        guard sample.terminationReason == .exit, sample.terminationStatus == 0 else {
            try? manager.removeItem(at: report)
            return nil
        }
        chmod(report.path, 0o600)
        Self.prune(directory, keeping: Self.keptReports)
        return report
    }

    static func reportName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // UTC, so names keep sorting by age across time zones and clock changes.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "hang-\(formatter.string(from: date)).txt"
    }

    /// Removes all but the newest `count` reports; their names sort by date.
    static func prune(_ directory: URL, keeping count: Int) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let reports = names.filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted()
        for name in reports.dropLast(count) { try? manager.removeItem(at: directory.appending(path: name)) }
    }

    private static func append(_ text: String, to report: URL) {
        guard let handle = try? FileHandle(forWritingTo: report) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static var isDebugged: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    /// When to ping the main thread and when it counts as stuck, one decision every half second.
    /// Internal for tests.
    struct Stall {
        enum Step: Equatable {
            case wait, ping, capture
            /// The main thread answered a ping it had been stuck on, after this many seconds.
            case recovered(after: TimeInterval)
        }

        let threshold: TimeInterval
        let cooldown: TimeInterval
        /// When the last ping was sent.
        private var sent: TimeInterval?
        /// Whether the ping not yet answered counted as a stall.
        private var stalled = false
        private var lastCapture: TimeInterval?

        init(threshold: TimeInterval, cooldown: TimeInterval) {
            self.threshold = threshold
            self.cooldown = cooldown
        }

        /// `answeredAt` is when the main thread ran the last ping, nil if it has not; `interval`
        /// is how long an answered ping waits before the next. After `.ping` and `.recovered` the
        /// caller sends a new one.
        mutating func step(at now: TimeInterval, answeredAt: TimeInterval?, interval: TimeInterval) -> Step {
            guard let sent else {
                self.sent = now
                return .ping
            }
            if let answeredAt {
                if stalled {
                    stalled = false
                    self.sent = now
                    return .recovered(after: answeredAt - sent)
                }
                guard now - sent >= interval else { return .wait }
                self.sent = now
                return .ping
            }
            guard !stalled, now - sent >= threshold else { return .wait }
            // A stall that began during the cooldown is captured once it ends, if still stuck.
            if let lastCapture, now - lastCapture < cooldown { return .wait }
            stalled = true
            lastCapture = now
            return .capture
        }
    }
}

import Foundation
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
    private let lock = NSLock()
    private var answered = false
    private var started = false

    /// Starts watching, except while hosting tests or with `WOOLOO_DISABLE_HANG_WATCHDOG` set.
    func start() {
        guard !WoolooApp.isHostingTests,
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
        var stall = Stall(threshold: threshold)
        var report: URL?
        while true {
            // System uptime stops while the Mac sleeps, so sleep is not a hang.
            let now = ProcessInfo.processInfo.systemUptime
            switch stall.step(at: now, answered: lock.withLock { answered }) {
            case .wait:
                break
            case .ping:
                ping()
            case .capture:
                // A debugger stopped at a breakpoint stops the main thread too.
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
        lock.withLock { answered = false }
        DispatchQueue.main.async { [self] in lock.withLock { answered = true } }
    }

    /// Samples the whole process for two seconds into a new report, readable only by this user.
    private func capture() -> URL? {
        let manager = FileManager.default
        let directory = Self.directory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let report = directory.appending(path: Self.reportName(for: Date()))
        let sample = Process()
        sample.executableURL = URL(filePath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "2", "-file", report.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
            sample.waitUntilExit()
        } catch { return nil }
        guard manager.fileExists(atPath: report.path) else { return nil }
        chmod(report.path, 0o600)
        Self.prune(directory, keeping: Self.keptReports)
        return report
    }

    static func reportName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
            /// The main thread answered a ping it had been stuck on, after about this many seconds.
            case recovered(after: TimeInterval)
        }

        let threshold: TimeInterval
        /// When the ping not yet answered was sent.
        private var sent: TimeInterval?
        private var captured = false

        init(threshold: TimeInterval) { self.threshold = threshold }

        /// `answered` says whether the main thread ran the last ping. After `.ping` and
        /// `.recovered` the caller sends a new one.
        mutating func step(at now: TimeInterval, answered: Bool) -> Step {
            guard let sent else {
                self.sent = now
                return .ping
            }
            if answered {
                let wasCaptured = captured
                self.sent = now
                captured = false
                return wasCaptured ? .recovered(after: now - sent) : .ping
            }
            guard !captured, now - sent >= threshold else { return .wait }
            captured = true
            return .capture
        }
    }
}

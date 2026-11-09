import AppKit
import Darwin

/// Records where the main thread is stuck when the app stops responding. A background thread
/// pings the main thread; once a ping waits `threshold` seconds, it runs `/usr/bin/sample` on this
/// process into `~/Library/Logs/wooloo/Hangs`. One report holds the recent UI events, periodic
/// memory readings, up to three samples of the same stall, and its recovery time.
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
    private let reportDirectory: URL
    private let lock = NSLock()
    private var history = History()
    private var contexts: [String: String] = [:]
    @MainActor private var eventMonitor: Any?
    /// System uptime when the main thread ran the last ping, nil until it does.
    private var answeredAt: TimeInterval?
    private var active = true
    private var started = false

    init(directory: URL = HangWatchdog.directory) {
        reportDirectory = directory
    }

    /// Context is bounded and stays in memory until a hang occurs. Never pass document text,
    /// keystrokes, notification bodies or command output here. Paths remain in private local logs.
    func record(_ message: String, coalescing key: String? = nil) {
        lock.withLock {
            history.record(message, at: ProcessInfo.processInfo.systemUptime, coalescing: key)
        }
    }

    /// Mounted preview context survives history rollover, and is removed when that preview leaves.
    func setContext(_ value: String?, for key: String) {
        lock.withLock {
            if let value {
                guard contexts[key] != nil || contexts.count < 32 else { return }
                contexts[key] = String(value.prefix(2048)).components(separatedBy: .newlines).joined(separator: " ")
            } else {
                contexts.removeValue(forKey: key)
            }
        }
    }

    func diagnosticContext() -> String {
        lock.withLock {
            contexts.keys.sorted().map { "\($0): \(contexts[$0]!)" }.joined(separator: "\n")
                + "\nRecent events (monotonic uptime in seconds; scroll/geometry events coalesced):\n" + history.formatted()
        }
    }

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
        Task { @MainActor [self] in installEventMonitor() }
        let thread = Thread { [self] in run() }
        thread.name = "dev.wooloo.hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        var stall = Stall(threshold: threshold, cooldown: cooldown)
        var report: URL?
        var lastMemoryAt = -TimeInterval.infinity
        var captureNumber = 0
        while true {
            // System uptime stops while the Mac sleeps, so sleep is not a hang.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMemoryAt >= 5 {
                let reading = Self.memoryReading()
                record(reading)
                if let report { Self.append("uptime=\(now) \(reading)\n", to: report) }
                lastMemoryAt = now
            }
            let (answeredAt, active) = lock.withLock { (self.answeredAt, self.active) }
            switch stall.step(at: now, answeredAt: answeredAt, interval: active ? activeInterval : inactiveInterval) {
            case .wait:
                break
            case .ping:
                ping()
            case .capture:
                // A debugger attached later and stopped at a breakpoint stops the main thread too.
                captureNumber = 1
                if !Self.isDebugged {
                    report = makeReport()
                    if let report { capture(into: report, number: captureNumber) }
                }
            case .recapture:
                captureNumber += 1
                if !Self.isDebugged {
                    if report == nil { report = makeReport() }
                    if let report { capture(into: report, number: captureNumber) }
                }
            case .recovered(let seconds):
                if let report {
                    Self.append("The main thread answered again after \(Int(seconds.rounded())) s.\n"
                                + Self.memoryReading() + "\n", to: report)
                }
                report = nil
                ping()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @MainActor
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            if event.type == .scrollWheel {
                self?.record("scroll window=\(event.windowNumber) dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY)"
                             + " phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)",
                             coalescing: "wheel-\(event.phase.rawValue)-\(event.momentumPhase.rawValue)")
            } else {
                self?.record("mouseDown window=\(event.windowNumber) clicks=\(event.clickCount)")
            }
            return event
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

    /// Write context before starting the sampler, so even an interrupted capture keeps it.
    private func makeReport() -> URL? {
        let manager = FileManager.default
        let directory = reportDirectory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // A folder that already existed keeps its own permissions otherwise.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { return nil }
        let report = directory.appending(path: Self.reportName(for: Date()))
        let context = diagnosticContext()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let header = "Wooloo hang diagnostics v2\nDate: \(Date().ISO8601Format())\n"
            + "PID: \(getpid()) version: \(version)\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + "Mounted views:\n\(context)\n"
        guard manager.createFile(atPath: report.path, contents: Data(header.utf8),
                                 attributes: [.posixPermissions: 0o600]) else { return nil }
        Self.prune(directory, keeping: Self.keptReports)
        return report
    }

    /// Samples are sequential and appended to the incident, never requested from the main thread.
    private func capture(into report: URL, number: Int) {
        let manager = FileManager.default
        let temporary = report.appendingPathExtension("sample")
        Self.append("\n=== Sample \(number), \(Date().ISO8601Format()), uptime=\(ProcessInfo.processInfo.systemUptime) ===\n"
                    + Self.memoryReading() + "\n", to: report)
        guard manager.createFile(atPath: temporary.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            Self.append("Could not create sampler output.\n", to: report)
            return
        }
        defer { try? manager.removeItem(at: temporary) }
        let sample = Process()
        sample.executableURL = URL(filePath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "2", "-file", temporary.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
        } catch {
            Self.append("Could not start sampler: \(error.localizedDescription)\n", to: report)
            return
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
        // Retain context and any partial stacks even when sampling failed or timed out.
        Self.append("Sampler status: \(sample.terminationStatus), reason: \(sample.terminationReason.rawValue)\n", to: report)
        if let input = try? FileHandle(forReadingFrom: temporary),
           let output = try? FileHandle(forWritingTo: report) {
            defer { try? input.close(); try? output.close() }
            do {
                try output.seekToEnd()
                while let data = try input.read(upToCount: 65_536), !data.isEmpty { try output.write(contentsOf: data) }
            } catch { Self.append("Could not append sampler output.\n", to: report) }
        }
        Self.append(Self.memoryReading() + "\n", to: report)
    }

    static func memoryReading() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "memory unavailable kern_return=\(result)" }
        return "memory footprint_bytes=\(info.phys_footprint) resident_bytes=\(info.resident_size) compressed_bytes=\(info.compressed)"
    }

    struct History {
        struct Entry {
            let uptime: TimeInterval
            let message: String
            let key: String?
        }
        static let capacity = 128
        private(set) var entries: [Entry] = []

        mutating func record(_ message: String, at uptime: TimeInterval, coalescing key: String? = nil) {
            if let key, let previous = entries.last, previous.key == key, uptime - previous.uptime < 0.25 { return }
            let cleaned = String(message.prefix(512)).components(separatedBy: .newlines).joined(separator: " ")
            entries.append(Entry(uptime: uptime, message: cleaned, key: key))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        func formatted() -> String {
            entries.map { "uptime=\($0.uptime) \($0.message)" }.joined(separator: "\n")
        }
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
        for name in reports.dropLast(count) {
            let report = directory.appending(path: name)
            try? manager.removeItem(at: report)
            // A process killed during sampling may leave its private sampler output behind.
            try? manager.removeItem(at: report.appendingPathExtension("sample"))
        }
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
            case wait, ping, capture, recapture
            /// The main thread answered a ping it had been stuck on, after this many seconds.
            case recovered(after: TimeInterval)
        }

        let threshold: TimeInterval
        let cooldown: TimeInterval
        let repeatInterval: TimeInterval
        let maximumCaptures: Int
        /// When the last ping was sent.
        private var sent: TimeInterval?
        /// Whether the ping not yet answered counted as a stall.
        private var stalled = false
        private var lastCapture: TimeInterval?
        private var captures = 0

        init(threshold: TimeInterval, cooldown: TimeInterval, repeatInterval: TimeInterval = 30, maximumCaptures: Int = 3) {
            self.threshold = threshold
            self.cooldown = cooldown
            self.repeatInterval = repeatInterval
            self.maximumCaptures = maximumCaptures
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
                    captures = 0
                    self.sent = now
                    return .recovered(after: answeredAt - sent)
                }
                guard now - sent >= interval else { return .wait }
                self.sent = now
                return .ping
            }
            if stalled {
                guard captures < maximumCaptures, let lastCapture, now - lastCapture >= repeatInterval else { return .wait }
                captures += 1
                self.lastCapture = now
                return .recapture
            }
            guard now - sent >= threshold else { return .wait }
            // A stall that began during the cooldown is captured once it ends, if still stuck.
            if let lastCapture, now - lastCapture < cooldown { return .wait }
            stalled = true
            captures = 1
            lastCapture = now
            return .capture
        }
    }
}

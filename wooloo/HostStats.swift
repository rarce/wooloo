import Darwin
import Foundation

/// Cumulative CPU time of a host, in ticks. Usage is the busy share of the ticks between two samples.
struct CPUTicks: Equatable {
    let busy: UInt64
    let total: UInt64

    func usage(since previous: CPUTicks) -> Double? {
        guard total > previous.total, busy >= previous.busy else { return nil }
        return min(1, Double(busy - previous.busy) / Double(total - previous.total))
    }
}

/// One reading of a host's resources. Fields a host cannot report stay nil.
struct HostSample: Equatable {
    var hostname: String
    var cpuTicks: CPUTicks?
    /// Instant CPU usage (0...1), for hosts without tick counters (a remote Mac).
    var cpuUsage: Double?
    var loadAverage: [Double] = []
    var cpuCount: Int?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var uptime: TimeInterval?
    var diskFree: UInt64?
    var diskTotal: UInt64?
}

/// What the sidebar shows: a sample plus the CPU usage worked out from the previous one.
struct HostStats: Equatable {
    var sample: HostSample
    var cpuUsage: Double?

    var memoryFraction: Double? {
        guard let used = sample.memoryUsed, let total = sample.memoryTotal, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    var diskUsedFraction: Double? {
        guard let free = sample.diskFree, let total = sample.diskTotal, total > 0 else { return nil }
        return min(1, Double(total - min(free, total)) / Double(total))
    }

    static func uptimeText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440, hours = minutes / 60 % 24, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }

    static func bytesText(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 100 { return String(format: "%.0f GB", gib) }
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

enum HostProbe {
    /// A read-only POSIX sh script printing `key=value` lines, for Linux (`/proc`) and macOS
    /// (`sysctl`, `vm_stat`). `directory` picks the volume whose free space is reported.
    static func script(directory: String?) -> String {
        let dir = directory.map(WorkspaceFiles.quote) ?? "\"$HOME\""
        return """
            LC_ALL=C; export LC_ALL
            echo "host=$(hostname)"
            if [ -r /proc/stat ]; then
              echo "stat=$(head -n 1 /proc/stat)"
              echo "load=$(cut -d ' ' -f 1-3 /proc/loadavg)"
              echo "ncpu=$(getconf _NPROCESSORS_ONLN)"
              awk '/^(MemTotal|MemAvailable):/ { sub(":", "", $1); print $1 "=" $2 }' /proc/meminfo
              echo "uptime=$(cut -d ' ' -f 1 /proc/uptime)"
            else
              echo "load=$(sysctl -n vm.loadavg | tr -d '{}')"
              echo "ncpu=$(sysctl -n hw.ncpu)"
              echo "memsize=$(sysctl -n hw.memsize)"
              echo "boottime=$(sysctl -n kern.boottime | awk '{ gsub(",", "", $4); print $4 }')"
              echo "now=$(date +%s)"
              echo "pscpu=$(ps -A -o %cpu= | awk '{s+=$1} END {print s+0}')"
              vm_stat | awk '/page size of/ { print "pagesize=" $8 }
                /^Pages (active|wired down|occupied by compressor):/ { k = $0; sub(/^Pages /, "", k); sub(/:.*/, "", k); n = $NF; sub(/\\.$/, "", n); print k "=" n }'
            fi
            echo "df=$(df -Pk \(dir) 2>/dev/null | tail -n 1)"
            """
    }

    static func parse(_ output: String) -> HostSample? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let host = values["host"], !host.isEmpty else { return nil }
        var sample = HostSample(hostname: host)
        sample.cpuCount = values["ncpu"].flatMap { Int($0) }
        sample.loadAverage = (values["load"] ?? "").split(separator: " ").prefix(3).compactMap { Double($0) }

        if let stat = values["stat"] {
            // cpu user nice system idle iowait irq softirq steal …; idle and iowait are not busy.
            let ticks = stat.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            if ticks.count >= 4 {
                let total = ticks.prefix(8).reduce(0, +)
                let idle = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
                sample.cpuTicks = CPUTicks(busy: total - idle, total: total)
            }
            let kib: (String) -> UInt64? = { values[$0].flatMap { UInt64($0) }.map { $0 * 1024 } }
            if let total = kib("MemTotal"), let available = kib("MemAvailable") {
                sample.memoryTotal = total
                sample.memoryUsed = total - min(available, total)
            }
            sample.uptime = values["uptime"].flatMap { Double($0) }
        } else {
            sample.memoryTotal = values["memsize"].flatMap { UInt64($0) }
            if let pageSize = values["pagesize"].flatMap({ UInt64($0) }) {
                let pages = ["active", "wired down", "occupied by compressor"]
                    .compactMap { values[$0].flatMap { UInt64($0) } }
                if !pages.isEmpty { sample.memoryUsed = pages.reduce(0, +) * pageSize }
            }
            if let boot = values["boottime"].flatMap({ Double($0) }), let now = values["now"].flatMap({ Double($0) }) {
                sample.uptime = max(0, now - boot)
            }
            if let percent = values["pscpu"].flatMap({ Double($0) }), let count = sample.cpuCount, count > 0 {
                sample.cpuUsage = min(1, percent / 100 / Double(count))
            }
        }

        // Filesystem 1024-blocks Used Available Capacity Mounted-on; the name may hold spaces,
        // so count from the end.
        let df = (values["df"] ?? "").split(separator: " ")
        if df.count >= 6, let total = UInt64(df[df.count - 5]), let available = UInt64(df[df.count - 3]) {
            sample.diskTotal = total * 1024
            sample.diskFree = available * 1024
        }
        return sample
    }

    /// This Mac, read through Mach and sysctl without starting a process.
    static func local(directory: String?) -> HostSample {
        // Not ProcessInfo.hostName, which can block for seconds on a DNS lookup.
        var name = [CChar](repeating: 0, count: 256)
        let hostname = gethostname(&name, name.count) == 0 ? String(cString: name) : "localhost"
        var sample = HostSample(hostname: hostname.hasSuffix(".local") ? String(hostname.dropLast(6)) : hostname)
        sample.cpuCount = ProcessInfo.processInfo.activeProcessorCount
        sample.memoryTotal = ProcessInfo.processInfo.physicalMemory
        sample.uptime = ProcessInfo.processInfo.systemUptime

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { sample.loadAverage = load }

        let host = mach_host_self()
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let user = UInt64(cpu.cpu_ticks.0), system = UInt64(cpu.cpu_ticks.1)
            let idle = UInt64(cpu.cpu_ticks.2), nice = UInt64(cpu.cpu_ticks.3)
            sample.cpuTicks = CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        mach_port_deallocate(mach_task_self_, host)
        if vmResult == KERN_SUCCESS {
            let pages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            sample.memoryUsed = pages * UInt64(vm_kernel_page_size)
        }

        let url = URL(fileURLWithPath: directory ?? NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            sample.diskTotal = values.volumeTotalCapacity.map { UInt64($0) }
            sample.diskFree = values.volumeAvailableCapacity.map { UInt64($0) }
        }
        return sample
    }

    /// Samples this Mac; tests replace it, since real stats change on every run.
    static var localSample: (_ directory: String?) -> HostSample = { local(directory: $0) }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func sample(machine: HerdrMachineProfile?, directory: String?) throws -> HostSample {
        guard let machine else { return localSample(directory) }
        let data = try WorkspaceFiles.remoteOutput(machine, script: script(directory: directory), label: "host-stats")
        guard let sample = parse(String(decoding: data, as: UTF8.self)) else {
            throw WorkspaceFileError.message("Unreadable host stats")
        }
        return sample
    }
}

/// Samples the selected host every few seconds while the sidebar section is visible. Kept out of
/// `HerdrStore` so a new sample only redraws this section.
@MainActor
final class HostStatsMonitor: ObservableObject {
    struct Target: Equatable {
        var machine: HerdrMachineProfile?
        var directory: String?
    }

    @Published private(set) var stats: HostStats?
    @Published private(set) var failure: String?
    private(set) var target: Target?
    private var task: Task<Void, Never>?
    private var previousTicks: CPUTicks?
    let interval: Duration

    init(interval: Duration = .seconds(5)) {
        self.interval = interval
    }

    /// Starts sampling `target`, or keeps going when it is already the one being sampled.
    func start(_ target: Target) {
        if task != nil, target == self.target { return }
        stop()
        if target.machine?.id != self.target?.machine?.id {
            stats = nil
            failure = nil
        }
        self.target = target
        previousTicks = nil
        // One thread for the loop rather than one per sample. A new loop gets its own, so it does
        // not wait behind the last sample of the target it replaces.
        let worker = BlockingWorker(label: "dev.wooloo.host-stats")
        task = Task { [weak self, interval] in
            while !Task.isCancelled {
                let result = await BlockingWork.run(on: worker) {
                    Result { try HostProbe.sample(machine: target.machine, directory: target.directory) }
                }
                // A monitor released without `stop()` ends the loop rather than sampling forever.
                guard !Task.isCancelled, let self else { return }
                self.apply(result)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func apply(_ result: Result<HostSample, Error>) {
        switch result {
        case .success(let sample):
            let usage = sample.cpuUsage ?? sample.cpuTicks.flatMap { ticks in previousTicks.flatMap { ticks.usage(since: $0) } }
            previousTicks = sample.cpuTicks ?? previousTicks
            let next = HostStats(sample: sample, cpuUsage: usage ?? stats?.cpuUsage)
            if next != stats { stats = next }
            if failure != nil { failure = nil }
        case .failure(let error):
            if failure != error.localizedDescription { failure = error.localizedDescription }
        }
    }
}

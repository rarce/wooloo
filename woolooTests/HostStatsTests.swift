import XCTest
@testable import wooloo

final class HostStatsTests: XCTestCase {
    private static let linuxOutput = """
        host=build-box
        stat=cpu  100 20 30 800 50 0 0 0 0 0
        load=0.52 0.41 0.30
        ncpu=8
        MemTotal=16384000
        MemAvailable=4096000
        uptime=93784.21
        df=/dev/nvme0n1p2 1000000 400000 600000 40% /
        """

    private static let macOutput = """
        host=mini
        load= 1.50 1.25 1.00
        ncpu=10
        memsize=17179869184
        boottime=1700000000
        now=1700090061
        pscpu=250.5
        pagesize=16384
        active=100000
        wired down=50000
        occupied by compressor=10000
        df=/dev/disk3s5 Data 500000000 300000000 200000000 61% /System/Volumes/Data
        """

    func testParsesLinuxProcOutput() throws {
        let sample = try XCTUnwrap(HostProbe.parse(Self.linuxOutput))
        XCTAssertEqual(sample.hostname, "build-box")
        XCTAssertEqual(sample.cpuTicks, CPUTicks(busy: 150, total: 1000))
        XCTAssertNil(sample.cpuUsage)
        XCTAssertEqual(sample.loadAverage, [0.52, 0.41, 0.30])
        XCTAssertEqual(sample.cpuCount, 8)
        XCTAssertEqual(sample.memoryTotal, 16_384_000 * 1024)
        XCTAssertEqual(sample.memoryUsed, 12_288_000 * 1024)
        XCTAssertEqual(try XCTUnwrap(sample.uptime), 93784.21, accuracy: 0.001)
        XCTAssertEqual(sample.diskTotal, 1_000_000 * 1024)
        XCTAssertEqual(sample.diskFree, 600_000 * 1024)
    }

    func testParsesMacOutputWithSpacesInTheFilesystemName() throws {
        let sample = try XCTUnwrap(HostProbe.parse(Self.macOutput))
        XCTAssertEqual(sample.hostname, "mini")
        XCTAssertNil(sample.cpuTicks)
        XCTAssertEqual(try XCTUnwrap(sample.cpuUsage), 0.2505, accuracy: 0.0001)
        XCTAssertEqual(sample.loadAverage, [1.5, 1.25, 1.0])
        XCTAssertEqual(sample.memoryTotal, 17_179_869_184)
        XCTAssertEqual(sample.memoryUsed, 160_000 * 16384)
        XCTAssertEqual(sample.uptime, 90061)
        XCTAssertEqual(sample.diskTotal, 500_000_000 * 1024)
        XCTAssertEqual(sample.diskFree, 200_000_000 * 1024)
    }

    func testRejectsOutputWithoutAHost() {
        XCTAssertNil(HostProbe.parse("load=1 2 3\n"))
        XCTAssertNil(HostProbe.parse(""))
    }

    func testCPUUsageComesFromTheTicksBetweenSamples() {
        let first = CPUTicks(busy: 100, total: 1000)
        XCTAssertEqual(CPUTicks(busy: 150, total: 1100).usage(since: first), 0.5)
        XCTAssertNil(first.usage(since: first), "no time passed")
        XCTAssertNil(CPUTicks(busy: 10, total: 50).usage(since: first), "counters reset")
    }

    @MainActor
    func testMonitorWorksOutUsageFromConsecutiveSamples() {
        let monitor = HostStatsMonitor()
        var sample = HostSample(hostname: "h", cpuTicks: CPUTicks(busy: 100, total: 1000))
        monitor.apply(.success(sample))
        XCTAssertNil(monitor.stats?.cpuUsage, "one sample has no usage yet")
        sample.cpuTicks = CPUTicks(busy: 125, total: 1100)
        monitor.apply(.success(sample))
        XCTAssertEqual(monitor.stats?.cpuUsage, 0.25)

        monitor.apply(.failure(WorkspaceFileError.message("Connection refused")))
        XCTAssertEqual(monitor.failure, "Connection refused")
        XCTAssertEqual(monitor.stats?.cpuUsage, 0.25, "a failed sample keeps the last reading")
        monitor.apply(.success(sample))
        XCTAssertNil(monitor.failure)
    }

    func testFormatting() {
        XCTAssertEqual(HostStats.uptimeText(59), "0m")
        XCTAssertEqual(HostStats.uptimeText(3 * 3600 + 25 * 60), "3h 25m")
        XCTAssertEqual(HostStats.uptimeText(2 * 86400 + 5 * 3600 + 60), "2d 5h")
        XCTAssertEqual(HostStats.bytesText(512 * 1_048_576), "512 MB")
        XCTAssertEqual(HostStats.bytesText(17_179_869_184), "16.0 GB")
        XCTAssertEqual(HostStats.bytesText(500 * 1_073_741_824), "500 GB")
    }

    func testLocalSampleReadsThisMac() throws {
        let sample = HostProbe.local(directory: NSTemporaryDirectory())
        XCTAssertFalse(sample.hostname.isEmpty)
        XCTAssertNotNil(sample.cpuTicks)
        XCTAssertEqual(sample.loadAverage.count, 3)
        let used = try XCTUnwrap(sample.memoryUsed), total = try XCTUnwrap(sample.memoryTotal)
        XCTAssertGreaterThan(used, 0)
        XCTAssertLessThanOrEqual(used, total)
        XCTAssertGreaterThan(try XCTUnwrap(sample.uptime), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sample.diskFree), try XCTUnwrap(sample.diskTotal))
    }

    /// The probe script runs over a fake ssh on this Mac, so its macOS branch runs for real.
    func testRemoteProbeOverSSH() throws {
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
                                          session: "default", enabled: true)

        let sample = try HostProbe.sample(machine: machine, directory: sandbox.base)
        XCTAssertFalse(sample.hostname.isEmpty)
        XCTAssertEqual(sample.loadAverage.count, 3)
        XCTAssertEqual(sample.cpuCount, ProcessInfo.processInfo.processorCount)
        XCTAssertNotNil(sample.cpuUsage)
        XCTAssertEqual(sample.memoryTotal, ProcessInfo.processInfo.physicalMemory)
        let used = try XCTUnwrap(sample.memoryUsed)
        XCTAssertGreaterThan(used, 0)
        XCTAssertLessThanOrEqual(used, try XCTUnwrap(sample.memoryTotal))
        XCTAssertGreaterThan(try XCTUnwrap(sample.uptime), 0)
        XCTAssertNotNil(sample.diskFree)
    }

    func testMemoryAndDiskFractions() {
        var sample = HostSample(hostname: "h", memoryUsed: 4, memoryTotal: 16, diskFree: 30, diskTotal: 120)
        XCTAssertEqual(HostStats(sample: sample).memoryFraction, 0.25)
        XCTAssertEqual(HostStats(sample: sample).diskUsedFraction, 0.75)

        sample.memoryUsed = 20
        sample.diskFree = 200
        XCTAssertEqual(HostStats(sample: sample).memoryFraction, 1, "clamped when used exceeds total")
        XCTAssertEqual(HostStats(sample: sample).diskUsedFraction, 0, "free beyond total counts as empty")

        sample.memoryTotal = 0
        sample.diskTotal = 0
        XCTAssertNil(HostStats(sample: sample).memoryFraction, "zero total")
        XCTAssertNil(HostStats(sample: sample).diskUsedFraction, "zero total")

        let empty = HostStats(sample: HostSample(hostname: "h"))
        XCTAssertNil(empty.memoryFraction)
        XCTAssertNil(empty.diskUsedFraction)
        XCTAssertNil(HostStats(sample: HostSample(hostname: "h", memoryUsed: 1)).memoryFraction, "no total")
        XCTAssertNil(HostStats(sample: HostSample(hostname: "h", diskTotal: 10)).diskUsedFraction, "no free")
    }

    // MARK: - Monitor sampling loop

    /// A fake ssh answering for `alpha.test` and `beta.test` with a host named after the target
    /// and the call number, and CPU ticks growing by 10 busy out of 110 per call. Any other
    /// target prints output without a host. Each call is logged under `calls/`.
    private func makeFakeSSH() throws -> WorkspaceGitSandbox {
        let sandbox = try WorkspaceGitSandbox()
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            calls=\(sandbox.path("calls"))
            case "$*" in
              *alpha.test*) name=alpha ;;
              *beta.test*) name=beta ;;
              *) name=broken ;;
            esac
            echo start >> "$calls/$name.start"
            n=$(wc -l < "$calls/$name.start" | tr -d ' ')
            if [ "$name" = broken ]; then
              echo "load=1 2 3"
            else
              echo "host=$name-$n"
              echo "stat=cpu  $((n * 10)) 0 0 $((n * 100)) 0"
            fi
            echo end >> "$calls/$name.end"
            """], in: ".")
        try sandbox.sh("mkdir -p calls && chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
        return sandbox
    }

    private func machine(_ id: String) -> HerdrMachineProfile {
        HerdrMachineProfile(id: id, label: id, target: "\(id).test", session: "default", enabled: true)
    }

    private func calls(_ sandbox: WorkspaceGitSandbox, _ name: String, _ kind: String = "start") -> Int {
        let text = (try? String(contentsOfFile: sandbox.path("calls/\(name).\(kind)"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Stops the monitor and waits for a probe still running to finish, so no call reaches the
    /// real ssh once the fake is removed.
    @MainActor
    private func stopAndSettle(_ monitor: HostStatsMonitor, _ sandbox: WorkspaceGitSandbox) async throws {
        monitor.stop()
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            for name in ["alpha", "beta", "broken"] {
                try await waitUntil("\(name) probes finish") {
                    calls(sandbox, name, "end") == calls(sandbox, name)
                }
            }
        }
    }

    @MainActor
    func testMonitorPublishesSamplesEveryIntervalUntilStopped() async throws {
        let sandbox = try makeFakeSSH()
        defer {
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        let monitor = HostStatsMonitor(interval: .milliseconds(20))
        XCTAssertEqual(HostStatsMonitor().interval, .seconds(5))
        let target = HostStatsMonitor.Target(machine: machine("alpha"), directory: sandbox.base)
        monitor.start(target)
        XCTAssertEqual(monitor.target, target)

        try await waitUntil("three samples arrive") {
            (monitor.stats?.sample.hostname).flatMap { Int($0.dropFirst("alpha-".count)) } ?? 0 >= 3
        }
        XCTAssertEqual(try XCTUnwrap(monitor.stats?.cpuUsage), 10.0 / 110, accuracy: 1e-9,
                       "usage from the ticks of consecutive samples")
        XCTAssertNil(monitor.failure)

        // Starting the same target again keeps the running loop and its readings.
        let before = monitor.stats
        monitor.start(target)
        XCTAssertEqual(monitor.stats, before)

        try await stopAndSettle(monitor, sandbox)
        let stopped = monitor.stats
        let count = calls(sandbox, "alpha")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls(sandbox, "alpha"), count, "no probes after stop")
        XCTAssertEqual(monitor.stats, stopped, "nothing published after stop")
        XCTAssertEqual(monitor.target, target, "stop keeps the target")
    }

    @MainActor
    func testMonitorStartReplacesTheTargetAndItsLoop() async throws {
        let sandbox = try makeFakeSSH()
        defer {
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        let monitor = HostStatsMonitor(interval: .milliseconds(20))
        monitor.start(.init(machine: machine("alpha"), directory: sandbox.base))
        try await waitUntil("alpha is sampled twice") { monitor.stats?.cpuUsage != nil }

        // Another directory on the same machine restarts the loop but keeps the readings.
        let other = HostStatsMonitor.Target(machine: machine("alpha"), directory: "/")
        monitor.start(other)
        XCTAssertEqual(monitor.target, other)
        XCTAssertNotNil(monitor.stats, "same machine keeps the last reading")

        // Another machine clears them, and its first sample has no usage yet.
        let beta = HostStatsMonitor.Target(machine: machine("beta"), directory: sandbox.base)
        monitor.start(beta)
        XCTAssertEqual(monitor.target, beta)
        XCTAssertNil(monitor.stats, "a new machine starts empty")
        XCTAssertNil(monitor.failure)
        try await waitUntil("beta is sampled") { monitor.stats?.sample.hostname.hasPrefix("beta-") == true }
        XCTAssertEqual(monitor.stats?.sample.hostname, "beta-1")
        XCTAssertNil(monitor.stats?.cpuUsage, "ticks from the previous target are not reused")

        // The alpha loop is gone: its calls stop while beta keeps being sampled.
        try await waitUntil("beta is sampled again") { monitor.stats?.cpuUsage != nil }
        let alphaCalls = calls(sandbox, "alpha")
        let betaCalls = calls(sandbox, "beta")
        try await waitUntil("beta is sampled twice more") { calls(sandbox, "beta") >= betaCalls + 2 }
        XCTAssertEqual(calls(sandbox, "alpha"), alphaCalls, "the replaced loop no longer samples")
        XCTAssertTrue(monitor.stats?.sample.hostname.hasPrefix("beta-") == true)

        try await stopAndSettle(monitor, sandbox)
    }

    @MainActor
    func testMonitorReportsUnreadableSamplesAndRecovers() async throws {
        let sandbox = try makeFakeSSH()
        defer {
            WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
            sandbox.tearDown()
        }
        let monitor = HostStatsMonitor(interval: .milliseconds(20))
        monitor.start(.init(machine: machine("broken"), directory: sandbox.base))
        try await waitUntil("the failure is published") { monitor.failure != nil }
        XCTAssertEqual(monitor.failure, "Unreadable host stats")
        XCTAssertNil(monitor.stats)
        try await waitUntil("the loop keeps probing after a failure") { calls(sandbox, "broken") >= 3 }
        XCTAssertEqual(monitor.failure, "Unreadable host stats")

        // A machine that answers clears the failure.
        monitor.start(.init(machine: machine("alpha"), directory: sandbox.base))
        XCTAssertNil(monitor.failure, "a new machine starts without the old failure")
        try await waitUntil("alpha is sampled") { monitor.stats != nil }
        XCTAssertNil(monitor.failure)

        try await stopAndSettle(monitor, sandbox)
    }

    /// The loop's samples share one worker queue instead of starting a thread each.
    @MainActor
    func testMonitorSamplesOnOneWorkerQueue() async throws {
        let labels = Locked<[String]>([])
        let saved = HostProbe.localSample
        HostProbe.localSample = { directory in
            labels.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))) }
            return saved(directory)
        }
        defer { HostProbe.localSample = saved }
        let monitor = HostStatsMonitor(interval: .milliseconds(10))
        monitor.start(.init(machine: nil, directory: NSTemporaryDirectory()))
        try await waitUntil("three samples are taken") { labels.value.count >= 3 }
        monitor.stop()
        XCTAssertEqual(Set(labels.value), ["dev.wooloo.host-stats"])
    }

    @MainActor
    func testMonitorSamplesThisMacWithoutAMachine() async throws {
        let monitor = HostStatsMonitor(interval: .milliseconds(20))
        monitor.start(.init(machine: nil, directory: NSTemporaryDirectory()))
        try await waitUntil("the local sample arrives") { monitor.stats != nil }
        let stats = try XCTUnwrap(monitor.stats)
        XCTAssertFalse(stats.sample.hostname.isEmpty)
        XCTAssertNotNil(stats.memoryFraction)
        XCTAssertNotNil(stats.diskUsedFraction)
        XCTAssertNil(monitor.failure)
        monitor.stop()
    }
}

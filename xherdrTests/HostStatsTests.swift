import XCTest
@testable import xherdr

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
}

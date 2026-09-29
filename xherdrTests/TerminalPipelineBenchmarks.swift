import AppKit
import XCTest
@testable import xherdr

/// Per-stage timings of the terminal pipeline over synthetic workloads. Skipped unless
/// `XHERDR_BENCH=1`; `scripts/terminal-bench.sh` runs it in an optimized build and compares the
/// JSON lines it writes to `XHERDR_BENCH_OUT` with a saved baseline.
///
/// Stages: `decode` (frame bytes to surface, stream thread), `layout` (surface to grid, main
/// thread, reusing rows from the previous sampled state), `layout-cold` (no rows to reuse), `draw` (grid to pixels at 2x, main thread) and `burst` (every frame of the workload
/// through decode, layout and draw in turn, as the main thread handles a burst of output today).
@MainActor
final class TerminalPipelineBenchmarks: XCTestCase {
    private struct Samples {
        var nanos: [UInt64] = []

        mutating func time<T>(_ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try body()
            nanos.append(DispatchTime.now().uptimeNanoseconds - start)
            return result
        }

        func json(scenario: String, stage: String, extra: String = "") -> String {
            let sorted = nanos.sorted()
            func micros(_ value: UInt64) -> String { String(format: "%.1f", Double(value) / 1000) }
            func percentile(_ p: Double) -> UInt64 {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
            }
            let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / UInt64(sorted.count)
            return #"{"scenario":"\#(scenario)","stage":"\#(stage)","n":\#(sorted.count),"p50_us":\#(micros(percentile(0.5))),"p95_us":\#(micros(percentile(0.95))),"mean_us":\#(micros(mean)),"max_us":\#(micros(sorted.last ?? 0))\#(extra)}"#
        }
    }

    private let environment = ProcessInfo.processInfo.environment
    private var columns: Int { Int(environment["XHERDR_BENCH_COLS"] ?? "") ?? 200 }
    private var rows: Int { Int(environment["XHERDR_BENCH_ROWS"] ?? "") ?? 60 }
    private var frameCount: Int { Int(environment["XHERDR_BENCH_FRAMES"] ?? "") ?? 240 }
    private var repetitions: Int { Int(environment["XHERDR_BENCH_REPEAT"] ?? "") ?? 3 }

    /// Prints a result and appends it to `XHERDR_BENCH_OUT`, since xcodebuild keeps test output
    /// only in the result bundle.
    private func report(_ line: String) {
        print("XHERDR-BENCH " + line)
        guard let path = environment["XHERDR_BENCH_OUT"], !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    func testPipelineStages() throws {
        guard environment["XHERDR_BENCH"] == "1" else { throw XCTSkip("Set XHERDR_BENCH=1 to run benchmarks") }
        report(#"{"config":{"cols":\#(columns),"rows":\#(rows),"frames":\#(frameCount),"repeat":\#(repetitions),"font":"\#(TerminalPaneView.terminalFont.fontName)"}}"#)
        for workload in TerminalWorkload.all(width: columns, height: rows, frames: frameCount) {
            try measure(workload)
        }
    }

    private func measure(_ workload: TerminalWorkload) throws {
        let bytesPerFrame = workload.totalBytes / max(1, workload.frames.count)

        var decode = Samples()
        var states: [HerdrSurface] = []
        let stride = max(1, workload.frames.count / 60)
        for repetition in 0..<repetitions {
            var decoder = HerdrSurfaceDecoder()
            for (index, frame) in workload.frames.enumerated() {
                let surface = try decode.time { try decoder.apply(frame: frame) }
                if repetition == 0, index % stride == 0, let surface { states.append(surface) }
            }
            XCTAssertEqual(decoder.surface?.contentDigest, workload.digests.last, "\(workload.name) decoded wrongly")
        }
        report(decode.json(scenario: workload.name, stage: "decode", extra: #","bytes_per_frame":\#(bytesPerFrame)"#))

        var layout = Samples()
        var grids: [TerminalGrid] = []
        for repetition in 0..<repetitions {
            // Rows carry over between consecutive states as they do in the view.
            var previous: TerminalGrid?
            for state in states {
                let grid = layout.time {
                    TerminalPaneView.layoutGrid(state, theme: TerminalRenderHarness.theme, previous: previous)
                }
                previous = grid
                if repetition == 0 { grids.append(grid) }
            }
        }
        report(layout.json(scenario: workload.name, stage: "layout"))

        // Every row laid out anew, as after a clear, a resize or a tab switch.
        var cold = Samples()
        for _ in 0..<repetitions {
            for state in states.prefix(20) {
                _ = cold.time { TerminalPaneView.layoutGrid(state, theme: TerminalRenderHarness.theme) }
            }
        }
        report(cold.json(scenario: workload.name, stage: "layout-cold"))

        var draw = Samples()
        let view = TerminalRenderHarness.makeView(width: workload.width, height: workload.height)
        let bitmap = TerminalRenderHarness.makeBitmap(for: view)
        for _ in 0..<repetitions {
            for (state, grid) in zip(states, grids) {
                view.surface = state
                view.applySurfaceGrid(grid)
                draw.time { TerminalRenderHarness.draw(view, into: bitmap) }
            }
        }
        report(draw.json(scenario: workload.name, stage: "draw"))

        var burst = Samples()
        var frame = Samples()
        for _ in 0..<repetitions {
            var decoder = HerdrSurfaceDecoder()
            burst.time {
                for payload in workload.frames {
                    frame.time {
                        guard let surface = try? decoder.apply(frame: payload) else { return }
                        TerminalRenderHarness.show(surface, in: view)
                        TerminalRenderHarness.draw(view, into: bitmap)
                    }
                }
            }
        }
        let meanBurst = Double(burst.nanos.reduce(0, +)) / Double(max(1, burst.nanos.count))
        let fps = Double(workload.frames.count) / (meanBurst / 1_000_000_000)
        report(frame.json(scenario: workload.name, stage: "burst",
                          extra: String(format: #","frames":%d,"total_ms":%.1f,"fps":%.1f"#,
                                        workload.frames.count, meanBurst / 1_000_000, fps)))
    }
}

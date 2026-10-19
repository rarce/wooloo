import AppKit
import CryptoKit
import XCTest
@testable import wooloo

/// Opt-in paired experiment. This does not change the app's rendering pipeline.
@MainActor
final class TerminalLayoutEvaluationTests: XCTestCase {
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
            return #"{"scenario":"\#(scenario)","stage":"\#(stage)","n":\#(sorted.count),"p50_us":\#(micros(percentile(0.5))),"p95_us":\#(micros(percentile(0.95))),"p99_us":\#(micros(percentile(0.99))),"mean_us":\#(micros(mean)),"max_us":\#(micros(sorted.last ?? 0))\#(extra)}"#
        }
    }

    private let environment = ProcessInfo.processInfo.environment
    private var columns: Int { Int(environment["WOOLOO_BENCH_COLS"] ?? "") ?? 200 }
    private var rows: Int { Int(environment["WOOLOO_BENCH_ROWS"] ?? "") ?? 60 }
    private var frameCount: Int { Int(environment["WOOLOO_BENCH_FRAMES"] ?? "") ?? 240 }
    private var repetitions: Int { Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 3 }

    /// Prints a result and appends it to `WOOLOO_BENCH_OUT`, since xcodebuild keeps test output
    /// only in the result bundle.
    private func report(_ line: String) {
        print("WOOLOO-BENCH " + line)
        guard let path = environment["WOOLOO_BENCH_OUT"], !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// An opt-in feasibility experiment, not the app's rendering pipeline. One frame is
    /// in flight at a time; view mutation and bitmap drawing always stay on the main thread.
    func testLayoutWorkerEvaluation() async throws {
        guard environment["WOOLOO_LAYOUT_EVAL"] == "1" else {
            throw XCTSkip("Set WOOLOO_LAYOUT_EVAL=1 to evaluate a serial layout worker")
        }
        // Resolve AppKit font-manager state and metrics on main before the worker uses them.
        _ = [TerminalPaneView.terminalFont, TerminalPaneView.boldFont,
             TerminalPaneView.italicFont, TerminalPaneView.boldItalicFont]
        _ = [TerminalPaneView.cellWidth, TerminalPaneView.cellHeight, TerminalPaneView.baseline]
        let theme = TerminalRenderHarness.theme
        let worker = DispatchQueue(label: "dev.wooloo.layout-evaluation", qos: .userInteractive)
        report(#"{"evaluation":{"cols":\#(columns),"rows":\#(rows),"frames":\#(frameCount),"repeat":\#(repetitions),"font":"\#(TerminalPaneView.terminalFont.fontName)","in_flight":1,"drawing":"offscreen-2x","probe":"one-main-queue-callback-per-frame"}}"#)
        let workloads = [TerminalWorkload.scrollShift(width: columns, height: rows, frames: frameCount),
                         TerminalWorkload.unicodeScroll(width: columns, height: rows, frames: frameCount),
                         TerminalWorkload.typing(width: columns, height: rows, frames: frameCount)]
        for workload in workloads {
            var decoder = HerdrSurfaceDecoder()
            let states = try workload.frames.compactMap { try decoder.apply(frame: $0) }
            XCTAssertEqual(states.last?.contentDigest, workload.digests.last)
            for cold in [false, true] {
                let scenario = workload.name + (cold ? "-cold" : "-reuse")
                var inlinePixels: [[UInt8]] = []
                var backgroundPixels: [[UInt8]] = []
                // Reverse the order on alternating repetitions to limit ordering/cache bias.
                for repetition in -1..<repetitions {
                    for background in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        TerminalShapeCache.shared.removeAll()
                        let view = TerminalRenderHarness.makeView(width: columns, height: rows)
                        let bitmap = TerminalRenderHarness.makeBitmap(for: view)
                        var previous: TerminalGrid?
                        var layout = Samples(), main = Samples(), total = Samples(), probe = Samples()
                        for (index, state) in states.enumerated() {
                            if cold { TerminalShapeCache.shared.removeAll(); previous = nil }
                            let started = DispatchTime.now().uptimeNanoseconds
                            // This queues an unrelated main-thread callback before the frame's
                            // preparation. Its delay illustrates availability, not input latency.
                            let queued = Task { @MainActor in DispatchTime.now().uptimeNanoseconds }
                            let grid: TerminalGrid
                            if background {
                                let base = previous
                                let prepared: (TerminalGrid, UInt64) = await withCheckedContinuation { continuation in
                                    worker.async {
                                        autoreleasepool {
                                            precondition(!Thread.isMainThread)
                                            let begin = DispatchTime.now().uptimeNanoseconds
                                            let grid = TerminalPaneView.layoutGrid(state, theme: theme, previous: base)
                                            continuation.resume(returning: (grid, DispatchTime.now().uptimeNanoseconds - begin))
                                        }
                                    }
                                }
                                grid = prepared.0
                                layout.nanos.append(prepared.1)
                            } else {
                                grid = layout.time { TerminalPaneView.layoutGrid(state, theme: theme, previous: previous) }
                            }
                            let mainStart = DispatchTime.now().uptimeNanoseconds
                            view.surface = state
                            view.applySurfaceGrid(grid)
                            TerminalRenderHarness.draw(view, into: bitmap)
                            let finished = DispatchTime.now().uptimeNanoseconds
                            main.nanos.append((background ? 0 : layout.nanos.last!) + finished - mainStart)
                            total.nanos.append(finished - started)
                            previous = grid
                            probe.nanos.append(await queued.value - started)
                            // A separate untimed pass verifies pixels; readback can affect the next draw.
                            if repetition == -1 {
                                let bytes = try XCTUnwrap(TerminalRenderHarness.pixels(of: bitmap)).bytes
                                let pixels = Array(SHA256.hash(data: Data(bytes)))
                                if background { backgroundPixels.append(pixels) } else { inlinePixels.append(pixels) }
                            }
                            XCTAssertEqual(grid.width, state.width, "frame \(index)")
                        }
                        let mode = background ? "worker" : "inline"
                        let extra = #","repetition":\#(repetition),"mode":"\#(mode)""#
                        if repetition >= 0 {
                            report(layout.json(scenario: scenario, stage: "prepare", extra: extra))
                            report(main.json(scenario: scenario, stage: "main-work", extra: extra))
                            report(total.json(scenario: scenario, stage: "ready-to-drawn", extra: extra))
                            report(probe.json(scenario: scenario, stage: "main-probe", extra: extra))
                        }
                    }
                }
                XCTAssertFalse(inlinePixels.isEmpty)
                XCTAssertEqual(inlinePixels.count, backgroundPixels.count)
                for (index, pair) in zip(inlinePixels, backgroundPixels).enumerated() {
                    XCTAssertEqual(pair.0, pair.1, "\(scenario) pixels differ at frame \(index)")
                }
                report(#"{"pixel_check":"\#(scenario)","frames":\#(inlinePixels.count),"equal":true}"#)
            }
        }
    }

}

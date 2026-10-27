import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import wooloo

/// Valid saved-output notebooks, independent of Python, kernels and private documents.
enum NotebookPreviewFixtures {
    struct Workload {
        let name: String
        let source: String
        let cells: Int
        let tables: Int
        let images: Int
    }

    static func make(_ name: String, cells: [[String: Any]], tables: Int = 0, images: Int = 0) throws -> Workload {
        let data = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5,
            "metadata": ["language_info": ["name": "python"],
                         "kernelspec": ["name": "python3", "language": "python", "display_name": "Python 3"]],
            "cells": cells], options: [.sortedKeys])
        return Workload(name: name, source: String(decoding: data, as: UTF8.self), cells: cells.count,
                        tables: tables, images: images)
    }

    static func cell(_ kind: String, _ index: Int, source: String, outputs: [[String: Any]] = []) -> [String: Any] {
        var result: [String: Any] = ["cell_type": kind, "id": "fixture-\(index)", "metadata": [:], "source": source]
        if kind == "code" { result["execution_count"] = index + 1; result["outputs"] = outputs }
        return result
    }

    static func display(_ data: [String: String]) -> [String: Any] {
        ["output_type": "display_data", "data": data, "metadata": [:]]
    }

    static func htmlTable(rows: Int, columns: Int) -> String {
        let header = (0..<columns).map { "<th>Column \($0 + 1)</th>" }.joined()
        let body = (0..<rows).map { row in
            "<tr>" + (0..<columns).map { column in
                "<td>" + (column.isMultiple(of: 2) ? "Rule \(row): acción 日本語 and wrapped evidence" : "\(row * 17 + column).25") + "</td>"
            }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(header)</tr></thead><tbody>\(body)</tbody></table>"
    }

    static var workloads: [Workload] {
        get throws {
            let prose = (0..<20).map { cell("markdown", $0, source: "## Section \($0)\n\nA paragraph with **emphasis**, `code` and [a link](https://example.invalid).") }
            let tables = (0..<10).map { cell("markdown", $0, source: "## Section \($0)\n\n" + MarkdownTableFixtures.table(rows: 8, columns: 4, number: $0)) }
            func mixed(_ count: Int) -> [[String: Any]] { (0..<count).map { index in
                if index.isMultiple(of: 2) {
                    return cell("markdown", index, source: "## Analysis \(index)\n\nSaved **evidence** and $E=mc^2$.\n\n$$\\int_0^1 x^2\\,dx=\\frac13$$")
                }
                return cell("code", index, source: "def evidence_\(index)(values):\n    return [value * 2 for value in values if value > 0]\n\nprint(evidence_\(index)([1, 2, 3]))", outputs: [
                    ["output_type": "stream", "name": "stdout", "text": "[2, 4, 6]\n"],
                    display(["application/json": "\(index)", "text/plain": "Saved result \(index)"])])
            } }
            let stream = (0..<60_000).map { "Saved row \($0): keep source and evidence together.\n" }.joined()
            let plots = (0..<12).map { cell("code", $0, source: "display(saved_plot_\($0))", outputs: [
                display(["image/png": plotPNG, "text/plain": "Saved plot \($0)"])]) }
            return try [
                make("prose", cells: prose),
                make("markdown-tables", cells: tables, tables: 10),
                make("html-tall-table", cells: [cell("code", 0, source: "dataframe", outputs: [display(["text/html": htmlTable(rows: 100, columns: 4), "text/plain": "100 rows × 4 columns"])])], tables: 1),
                make("html-wide-table", cells: [cell("code", 0, source: "dataframe", outputs: [display(["text/html": htmlTable(rows: 12, columns: 12), "text/plain": "12 rows × 12 columns"])])], tables: 1),
                make("many-cells", cells: mixed(100)),
                // As many cells as a notebook may have (`NotebookDocument.maximumCells`).
                make("max-cells", cells: mixed(NotebookDocument.maximumCells)),
                make("large-output", cells: [cell("code", 0, source: "print(saved_log)", outputs: [["output_type": "stream", "name": "stdout", "text": stream]])]),
                make("saved-images", cells: plots, images: 12),
            ]
        }
    }

    static var findTable: Workload {
        get throws {
            // Compact enough to remain below the 500k-character representation limit.
            let rows = (0..<5_000).map { "<tr><td>Rule \($0)</td><td>\($0 * 17)</td></tr>" }.joined()
            return try make("find-5000-row-table", cells: [cell("code", 0, source: "dataframe", outputs: [
                display(["text/html": "<table><tr><th>Rule</th><th>Value</th></tr>" + rows + "</table>"])
            ])], tables: 1)
        }
    }

    static var oversizedSource: Workload {
        get throws {
            try make("large-source", cells: [cell("raw", 0, source:
                (0..<60_000).map { "Saved row \($0): keep source and evidence together.\n" }.joined())])
        }
    }

    static var snapshot: Workload {
        get throws {
            try make("snapshot", cells: [
                cell("markdown", 0, source: "# Saved notebook\n\n**Evidence** with Unicode: acción 日本語 and $E=mc^2$.\n\n" + MarkdownTableFixtures.table(rows: 2, columns: 3)),
                cell("code", 1, source: "values = [1, 2, 3]\nprint(sum(values))", outputs: [
                    ["output_type": "stream", "name": "stdout", "text": "6\n"],
                    display(["text/html": htmlTable(rows: 2, columns: 3), "text/plain": "Saved dataframe"])]),
            ], tables: 2)
        }
    }

    // Fixed 256×128 PNG bytes; generated once, rather than depending on OS image encoders.
    static let plotPNG = "iVBORw0KGgoAAAANSUhEUgAAAQAAAACACAIAAABr1yBdAAADKUlEQVR42u3dQU7rMBCA4d6EY3IxjsOGDdeASt0glSZObCczkw+F7acne/4oaXnJ7fPr2+G47HG7//7M/OHzI/sC4AvAAvEFYIH4ArBAfAFYIL4ALBBfABaILwAbwBeADeALwAbwBWAD+AKwAXwB2AC+AGwAXwA2gC8AG8AXgA3gC8AG8AVgA/gCsAF8AfD5AuDzBcDnC4DPFwCfLwA+XwB8vgD4fAHw+QLg848OwOHwfgBnCL5LIAvEF4AF4gvAAvEFYIH4ArABfAHYAL4AbABfADaALwAbwBeADeALwAbwk/pv7x/3QwD8y/mP0RcA/3L+39EXAP9C/vPouwfgX8J/NfoC4Bf3l0dfAPyyfsvoC4Bf0G8ffQHwS/lbR18A/CL+vtEXAD+3/zz3m0ZfAPys/pDRFwA/nz9w9AXAz+SPnXsB8HP4w0/5AuDn8GePvgD4Qf1jRl8A/HD+89z7H2H8+v7CKV8A/Mr+6tWO9wM4Ch7/zv3jgsf7AfiV/a03uC6B+BX8V6f80//9AuDP9Ts/0xQAP6W/+5QvAH5uf+zXWALg5/BHnfIFwM/kT5p7AfCj+7NHXwD8iP4xcy8Afix/4bvb1OsjAH7XKV8ABqim33ipIwADVMrfeokvAANUwX8196t3twIwQIn93XMvAAOU2O+fewEY0Hz+wLkXgAHN4S8M/ZBvrwRgQCP6s+deAAY0on/Y3AvAgAbyF4be+gigpt94srf+Aijlb73Isf4CSO8vD/25jxURgAGd4vcMvfUXQEp/degv+E2tAIr7M4be+gsgtD976K2/AML5Rw699RdACL9l6K2/AOr4LRN/8PPv+esBOGY86v70J987vB9git848Y3X9NbfJVD6jyl77mKtvwBi+ZsmPv7DX/kCGDnu6Z59yRdA17gbIAGkXKAds17yyWf84gHsHvQgL2njC+CIQfcpDT96AENG3B+T8WMFMHas3aTyBwcwe0Bnn9FtML9IADaYXzAAG8B3E8znC4DPFwCfLwA+XwB8vgD4fAHw+QLg8wXA5wuAzxcAny8APl8AfL4A+HwB8PkC4PMFwOcLgM/v//kF+kXH/XgNWCUAAAAASUVORK5CYII="
}

@MainActor
final class NotebookPreviewHarness {
    final class Probe { var searchText: [String]? }
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let probe: Probe
    let workload: NotebookPreviewFixtures.Workload
    let style: MarkdownPreviewStyle
    private(set) weak var webView: WKWebView?
    private(set) var viewport: [String: Int] = [:]

    init(_ workload: NotebookPreviewFixtures.Workload, style: MarkdownPreviewStyle) {
        self.workload = workload; self.style = style
        let probe = Probe(); self.probe = probe
        host = NSHostingView(rootView: Self.preview(workload, style: style, probe: probe))
        host.frame = NSRect(x: 100, y: 100, width: 1000, height: 800)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wooloo notebook preview test"
        window.appearance = NSAppearance(named: style == .document ? .aqua : .darkAqua)
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    private static func preview(_ workload: NotebookPreviewFixtures.Workload, style: MarkdownPreviewStyle,
                                probe: Probe, matches: [MarkdownFindMatch] = [], current: Int? = nil) -> AnyView {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "notebook-bench",
                                             workspaceLabel: "Notebook benchmark", root: "/private/tmp")
        return AnyView(NotebookPreviewView(text: workload.source, path: "benchmark.ipynb", location: location,
                                          onOpenFile: { _ in }, style: style, matches: matches, currentMatch: current,
                                          revealRequest: matches.isEmpty ? 0 : 1, onSearchText: { probe.searchText = $0 })
            .environment(\.woolooTheme, theme)
            .environment(\.woolooTypography, WoolooTypography())
            .preferredColorScheme(style == .document ? .light : theme.colorScheme)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func ready() async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if let web = Self.findWebView(in: host), probe.searchText?.isEmpty == false,
               (try? await web.evaluateJavaScript("Number(document.getElementById('notebook').dataset.cells)")) as? Int == workload.cells {
                webView = web
                return web
            }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        throw NotebookDocument.ParseError.message("Notebook preview did not become ready: \(workload.name)")
    }

    func find(_ matches: [MarkdownFindMatch], current: Int?) {
        host.rootView = Self.preview(workload, style: style, probe: probe, matches: matches, current: current)
        host.layoutSubtreeIfNeeded()
    }

    /// WebKit paints in another process: cacheDisplay would measure an empty/stale backing store.
    func capture(_ web: WKWebView) async throws -> NSImage {
        let body = """
            // Creating the DOM does not start every font load until it has been laid out.
            void document.documentElement.offsetHeight;
            await document.fonts.ready;
            await Promise.all(Array.from(document.images).filter(image => {
                const rect = image.getBoundingClientRect();
                return rect.bottom > 0 && rect.top < innerHeight;
            }).map(image => image.decode().catch(() => {})));
            await document.fonts.ready;
            return true;
            """
        // The callback overload has a default nil handler. Ignoring its result can select
        // that synchronous overload even with `try await`, leaving font loads pending.
        let painted: Bool = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result.map { $0 as? Bool == true })
            }
        }
        XCTAssertTrue(painted)
        viewport = (try await web.evaluateJavaScript("({width:document.documentElement.clientWidth,height:document.documentElement.clientHeight,gutter:innerWidth-document.documentElement.clientWidth})")) as? [String: Int] ?? [:]
        XCTAssertFalse(viewport.isEmpty, "The effective CSS viewport must be recorded")
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        configuration.afterScreenUpdates = true
        return try await web.takeSnapshot(configuration: configuration)
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }
}

/// Opt-in timings of the complete NotebookPreviewView, including its debounce, parsing and WebKit.
@MainActor
final class NotebookPreviewBenchmarks: XCTestCase {
    func testPreviewRendering() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WOOLOO_BENCH_NOTEBOOK"] == "1" else {
            throw XCTSkip("Run scripts/notebook-bench.sh to measure notebook rendering")
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                            reason: "Measure notebook preview latency")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let repetitions = max(1, Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 3)
        let output = environment["WOOLOO_BENCH_OUT"]
        try report(["config": ["repeat": repetitions, "width": 1000, "height": 800, "resize_width": 780,
                                "base_font": WoolooTypography.defaultBase, "code_font": WoolooTypography.defaultCode,
                                "theme": WoolooTheme.fallbackID, "renderer": "NotebookPreviewView",
                                "scrollbars": Int(NSScroller.preferredScrollerStyle.rawValue),
                                "capture": "WKSnapshot-afterScreenUpdates-layout-fonts-images-nested-scroll-active-viewport-v6"]], to: output)
        for style in [MarkdownPreviewStyle.theme, .document] {
            for workload in try NotebookPreviewFixtures.workloads {
                var samples: [String: [Double]] = [:]
                var nodeCount = 0
                var viewports: [String: [String: Int]] = [:]
                func rememberViewport(_ stage: String, _ viewport: [String: Int]) {
                    if let previous = viewports[stage] { XCTAssertEqual(previous, viewport, "Viewport changed between repetitions") }
                    viewports[stage] = viewport
                }
                for _ in 0..<repetitions {
                    var start = DispatchTime.now().uptimeNanoseconds
                    let source = workload.source
                    let parsed = try await Task.detached(priority: .userInitiated) { try NotebookDocument.parse(source) }.value
                    samples["parse", default: []].append(milliseconds(since: start))
                    XCTAssertEqual(parsed.cells.count, workload.cells)
                    start = DispatchTime.now().uptimeNanoseconds
                    let harness = NotebookPreviewHarness(workload, style: style)
                    defer { harness.close() }
                    let web = try await harness.ready()
                    let first = try await harness.capture(web)
                    XCTAssertEqual(first.size.width, 1000, accuracy: 1)
                    samples["first-render", default: []].append(milliseconds(since: start))
                    rememberViewport("first-render", harness.viewport)
                    let counts = try await web.evaluateJavaScript("({cells:document.querySelectorAll('.cell').length,slots:document.querySelectorAll('.cell-slot').length,tables:document.querySelectorAll('table').length,images:document.images.length,nodes:document.querySelectorAll('*').length})") as? [String: Int]
                    // Large notebooks keep only the cells near the viewport in the document.
                    if counts?["slots"] == 0 {
                        XCTAssertEqual(counts?["cells"], workload.cells)
                        XCTAssertEqual(counts?["tables"], workload.tables)
                        XCTAssertEqual(counts?["images"], workload.images)
                    } else {
                        XCTAssertEqual(counts?["slots"], workload.cells)
                        XCTAssertLessThan(counts?["cells"] ?? .max, workload.cells)
                    }
                    nodeCount = counts?["nodes"] ?? 0
                    start = DispatchTime.now().uptimeNanoseconds
                    harness.window.setContentSize(NSSize(width: 780, height: 800))
                    harness.host.layoutSubtreeIfNeeded()
                    _ = try await harness.capture(web)
                    XCTAssertEqual(web.bounds.width, 780, accuracy: 1)
                    let width = try await web.evaluateJavaScript("innerWidth") as? Int
                    XCTAssertEqual(width, 780, "The web document must actually resize")
                    samples["resize", default: []].append(milliseconds(since: start))
                    rememberViewport("resize", harness.viewport)
                    start = DispatchTime.now().uptimeNanoseconds
                    _ = try await harness.capture(web)
                    samples["cached-draw", default: []].append(milliseconds(since: start))
                    rememberViewport("cached-draw", harness.viewport)
                    start = DispatchTime.now().uptimeNanoseconds
                    let scrollBoxes = try await web.evaluateJavaScript("""
                        Array.from(document.querySelectorAll('.long-output,.rich-output,.source')).filter(element =>
                            element.scrollHeight > element.clientHeight + 2 || element.scrollWidth > element.clientWidth + 2).length
                        """) as? Int ?? 0
                    if workload.name == "large-output" {
                        XCTAssertGreaterThan(scrollBoxes, 0, "The saved stream must exercise its own scroll area")
                    }
                    var bottom = false
                    // Lazy image decoding can increase the document height after reaching its
                    // previous end. Include those updates, rather than measuring a partial scroll.
                    for _ in 0..<10 {
                        _ = try await web.evaluateJavaScript("""
                            document.querySelectorAll('.long-output,.rich-output,.source').forEach(element =>
                                element.scrollTo(element.scrollWidth,element.scrollHeight));
                            window.scrollTo(0,document.documentElement.scrollHeight);
                            """)
                        _ = try await harness.capture(web)
                        bottom = (try await web.evaluateJavaScript("scrollY+innerHeight>=document.documentElement.scrollHeight-2")) as? Bool == true
                        if bottom { break }
                    }
                    XCTAssertTrue(bottom, "Scroll must reach the end of \(workload.name) / \(style)")
                    let outputsAtEnd = try await web.evaluateJavaScript("""
                        Array.from(document.querySelectorAll('.long-output,.rich-output,.source')).every(element =>
                            element.scrollTop + element.clientHeight >= element.scrollHeight - 2 &&
                            element.scrollLeft + element.clientWidth >= element.scrollWidth - 2)
                        """) as? Bool
                    XCTAssertEqual(outputsAtEnd, true, "Nested outputs must also reach their ends")
                    samples["scroll", default: []].append(milliseconds(since: start))
                    rememberViewport("scroll", harness.viewport)
                }
                let digest = SHA256.hash(data: Data(workload.source.utf8)).map { String(format: "%02x", $0) }.joined()
                for stage in ["parse", "first-render", "resize", "cached-draw", "scroll"] {
                    let times = samples[stage]!.sorted()
                    func percentile(_ p: Double) -> Double { times[min(times.count - 1, max(0, Int(ceil(Double(times.count) * p)) - 1))] }
                    try report(["scenario": workload.name, "style": style.rawValue, "stage": stage, "n": times.count,
                                "bytes": workload.source.utf8.count, "sha256": digest, "cells": workload.cells,
                                "dom_nodes": nodeCount, "viewport": viewports[stage] ?? [:], "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "max_ms": times.last!], to: output)
                }
            }
        }
    }

    /// Measures the two operations that opening a small notebook does not stress.
    func testFindAndOversizedSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WOOLOO_BENCH_NOTEBOOK"] == "1" else {
            throw XCTSkip("Run scripts/notebook-bench.sh to measure notebook rendering")
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                            reason: "Measure notebook Find and truncation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let repetitions = max(1, Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 3)
        let output = environment["WOOLOO_BENCH_OUT"]
        let sourceWorkload = try NotebookPreviewFixtures.oversizedSource
        var parseTimes: [Double] = []
        for _ in 0..<repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            let parsed = try await Task.detached(priority: .userInitiated) {
                try NotebookDocument.parse(sourceWorkload.source)
            }.value
            parseTimes.append(milliseconds(since: start))
            XCTAssertTrue(parsed.cells[0].source.hasSuffix("full data remains in Source view."))
            XCTAssertTrue(parsed.warnings.contains { $0.contains("source is truncated") })
        }
        try reportSamples(parseTimes, workload: sourceWorkload, style: "Parser", stage: "parse", to: output)

        let workload = try NotebookPreviewFixtures.findTable
        for style in [MarkdownPreviewStyle.theme, .document] {
            let harness = NotebookPreviewHarness(workload, style: style)
            defer { harness.close() }
            let web = try await harness.ready()
            _ = try await harness.capture(web)
            let find = DocumentFindModel(); find.open(replace: false, query: "Rule")
            find.update(text: workload.source, target: .preview, anchor: nil, previewTextNodes: harness.probe.searchText ?? [])
            XCTAssertEqual(find.count, 5_001, "All rows must survive projection and search indexing")
            for count in [100, 1_000, 5_001] {
                let matches = find.previewMatches.prefix(count).enumerated().map { index, match in
                    ["block": match.block, "lower": match.range.lowerBound, "upper": match.range.upperBound, "index": index]
                }
                var rangeTimes: [Double] = [], paintTimes: [Double] = []
                for _ in 0..<repetitions {
                    _ = try await web.evaluateJavaScript("window.notebook.find([],null,false)")
                    _ = try await harness.capture(web)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let elapsed: Double = try await withCheckedThrowingContinuation { continuation in
                        web.callAsyncJavaScript("const start=performance.now();window.notebook.find(matches,current,false);return performance.now()-start;",
                                                arguments: ["matches": matches, "current": count - 1], in: nil, in: .page) { result in
                            continuation.resume(with: result.map { ($0 as? NSNumber)?.doubleValue ?? -1 })
                        }
                    }
                    rangeTimes.append(elapsed)
                    _ = try await harness.capture(web)
                    paintTimes.append(milliseconds(since: start))
                    let actual = try await web.evaluateJavaScript("({count:CSS.highlights.get('notebook-find').size,valid:Array.from(CSS.highlights.get('notebook-find')).every(range=>range.toString()==='Rule'),current:Array.from(CSS.highlights.get('notebook-current')).map(range=>range.toString()).join('')})") as? [String: Any]
                    XCTAssertEqual(actual?["count"] as? Int, count)
                    XCTAssertEqual(actual?["valid"] as? Bool, true)
                    XCTAssertEqual(actual?["current"] as? String, "Rule")
                    XCTAssertGreaterThanOrEqual(elapsed, 0)
                }
                try reportSamples(rangeTimes, workload: workload, style: style.rawValue, stage: "find-\(count)-ranges", to: output, viewport: harness.viewport)
                try reportSamples(paintTimes, workload: workload, style: style.rawValue, stage: "find-\(count)-paint", to: output, viewport: harness.viewport)
            }
        }
    }

    private func reportSamples(_ samples: [Double], workload: NotebookPreviewFixtures.Workload,
                               style: String, stage: String, to output: String?, viewport: [String: Int] = [:]) throws {
        let times = samples.sorted()
        let digest = SHA256.hash(data: Data(workload.source.utf8)).map { String(format: "%02x", $0) }.joined()
        try report(["scenario": workload.name, "style": style, "stage": stage, "n": times.count,
                    "bytes": workload.source.utf8.count, "sha256": digest, "cells": workload.cells, "viewport": viewport,
                    "p50_ms": times[(times.count - 1) / 2], "p95_ms": times[min(times.count - 1, Int(ceil(Double(times.count) * 0.95)) - 1)],
                    "max_ms": times.last!], to: output)
    }

    private func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    private func report(_ record: [String: Any], to path: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("WOOLOO-NOTEBOOK " + String(decoding: data, as: UTF8.self))
        guard let path, !path.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([10]))
    }
}

@MainActor
final class NotebookPreviewInteractionTests: XCTestCase {
    func testFindRangesCrossInlineNodesAndUnicodeBoundaries() async throws {
        let workload = try NotebookPreviewFixtures.make("find-boundaries", cells: [
            NotebookPreviewFixtures.cell("markdown", 0, source: "**Start**👩🏽‍💻é`End` and $E=mc^2$"),
            NotebookPreviewFixtures.cell("code", 1, source: "print('saved')", outputs: [
                NotebookPreviewFixtures.display(["text/html": "<span>Start</span><span></span><b>👩🏽‍💻é</b><i>End</i>",
                                                 "text/plain": "Start👩🏽‍💻éEnd"])])])
        let harness = NotebookPreviewHarness(workload, style: .document)
        defer { harness.close() }
        let web = try await harness.ready()
        _ = try await harness.capture(web)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.markdown p,.rich-output b,.rich-output i').forEach(element=>{element.prepend(document.createTextNode(''));element.append(document.createTextNode(''))})")
        for (query, count) in [("mc", 1), ("Start", 2), ("👩🏽‍💻é", 2), ("End", 2), ("Start👩🏽‍💻éEnd", 2)] {
            let find = DocumentFindModel(); find.open(replace: false, query: query)
            find.update(text: workload.source, target: .preview, anchor: nil, previewTextNodes: harness.probe.searchText ?? [])
            XCTAssertEqual(find.count, count, query)
            harness.find(find.previewMatches, current: find.current)
            let expected = Array(repeating: query, count: count)
            let expression = "Array.from(CSS.highlights.get('notebook-find') || []).map(range=>range.toString())"
            let deadline = Date().addingTimeInterval(5)
            var actual: [String] = []
            repeat {
                actual = (try await web.evaluateJavaScript(expression)) as? [String] ?? []
                if actual == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            XCTAssertEqual(actual, expected)
        }
        // The same UTF-16 offsets must resolve against new nodes after a MIME switch.
        _ = try await web.evaluateJavaScript("const picker=document.querySelector('.mime-picker select');picker.value='1';picker.dispatchEvent(new Event('change'))")
        let expression = "Array.from(CSS.highlights.get('notebook-find') || []).map(range=>range.toString())"
        let deadline = Date().addingTimeInterval(5)
        var actual: [String] = []
        repeat {
            actual = (try await web.evaluateJavaScript(expression)) as? [String] ?? []
            if actual == ["Start👩🏽‍💻éEnd", "Start👩🏽‍💻éEnd"] { break }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTAssertEqual(actual, ["Start👩🏽‍💻éEnd", "Start👩🏽‍💻éEnd"])
    }

    func testLargeNotebooksKeepOnlyCellsNearTheViewportAndFindEveryCell() async throws {
        let cells = (0..<600).map { index in
            index.isMultiple(of: 2)
                ? NotebookPreviewFixtures.cell("markdown", index, source: "## Cell \(index)\n\nSaved needle\(index) evidence.")
                : NotebookPreviewFixtures.cell("code", index, source: "print('needle\(index)')", outputs: [
                    ["output_type": "stream", "name": "stdout", "text": "needle\(index)\n"]])
        }
        let workload = try NotebookPreviewFixtures.make("virtual", cells: cells)
        let harness = NotebookPreviewHarness(workload, style: .theme)
        defer { harness.close() }
        let web = try await harness.ready()
        _ = try await harness.capture(web)
        func value<T>(_ script: String, as type: T.Type = T.self) async throws -> T? {
            try await web.evaluateJavaScript(script) as? T
        }
        func eventually(_ script: String) async throws -> Bool {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if try await value(script, as: Bool.self) == true { return true }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            return false
        }
        let slots = try await value("document.querySelectorAll('.cell-slot').length", as: Int.self)
        XCTAssertEqual(slots, 600)
        let shown = try await value("document.querySelectorAll('.cell').length", as: Int.self) ?? 0
        XCTAssertGreaterThan(shown, 0)
        XCTAssertLessThan(shown, 100)
        // Find reads every cell, also those outside the document, and reveals the last one.
        let find = DocumentFindModel(); find.open(replace: false, query: "needle599")
        find.update(text: workload.source, target: .preview, anchor: nil, previewTextNodes: harness.probe.searchText ?? [])
        XCTAssertEqual(find.count, 2)
        harness.find(find.previewMatches, current: find.current)
        let last = "document.querySelector('[aria-label=\"code cell 600\"]')"
        let revealed = try await eventually("""
            !!\(last) && \(last).isConnected && \(last).getBoundingClientRect().bottom > 0
                && \(last).getBoundingClientRect().top < innerHeight
                && Array.from(CSS.highlights.get('notebook-current') || []).map(range => range.toString()).join() === 'needle599'
            """)
        XCTAssertTrue(revealed)
        // Cells scrolled far away leave the document, and come back when scrolled to.
        let left = try await eventually("!document.querySelector('[aria-label=\"markdown cell 1\"]')")
        XCTAssertTrue(left)
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 0)")
        let back = try await eventually("!!document.querySelector('[aria-label=\"markdown cell 1\"]')")
        XCTAssertTrue(back)
        let top = try await value("document.querySelector('[aria-label=\"markdown cell 1\"]').getBoundingClientRect().top", as: Double.self)
        XCTAssertLessThan(top ?? .infinity, 200, "The first cell must be at the top again, not pushed down by a slot")
    }

    func testFindRevealsCollapsedTableOutsideTheViewportAfterResize() async throws {
        for style in [MarkdownPreviewStyle.theme, .document] {
            var cells = (0..<80).map { NotebookPreviewFixtures.cell("markdown", $0, source: "## Section \($0)\n\n" + String(repeating: "Keep the evidence and source together. ", count: 10)) }
            cells.append(NotebookPreviewFixtures.cell("code", 80, source: "dataframe", outputs: [
                NotebookPreviewFixtures.display(["text/html": "<table><tr><td>NeedleAtTheEnd</td><td>42</td></tr></table>", "text/plain": "NeedleAtTheEnd 42"]) ]))
            let workload = try NotebookPreviewFixtures.make("find-table", cells: cells, tables: 1)
            let harness = NotebookPreviewHarness(workload, style: style)
            defer { harness.close() }
            let web = try await harness.ready()
            _ = try await harness.capture(web)
            _ = try await web.evaluateJavaScript("document.querySelector('details[data-output]').open=false")
            harness.window.setContentSize(NSSize(width: 780, height: 800)); harness.host.layoutSubtreeIfNeeded()
            let find = DocumentFindModel(); find.open(replace: false, query: "NeedleAtTheEnd")
            find.update(text: workload.source, target: .preview, anchor: nil, previewTextNodes: harness.probe.searchText ?? [])
            XCTAssertEqual(find.count, 1)
            harness.find(find.previewMatches, current: find.current)
            let deadline = Date().addingTimeInterval(5)
            while (try await web.evaluateJavaScript("document.querySelector('.find-active')!==null")) as? Bool != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await harness.capture(web)
            let result = try await web.evaluateJavaScript("({open:document.querySelector('details[data-output]').open,active:document.querySelector('.find-active')?.textContent,visible:(()=>{const r=document.querySelector('.find-active')?.getBoundingClientRect();return !!r&&r.top<innerHeight&&r.bottom>0})(),scroll:scrollY})") as? [String: Any]
            XCTAssertEqual(result?["open"] as? Bool, true)
            XCTAssertTrue((result?["active"] as? String)?.contains("NeedleAtTheEnd") == true)
            XCTAssertEqual(result?["visible"] as? Bool, true)
            XCTAssertGreaterThan(result?["scroll"] as? Double ?? 0, 800)
            _ = try await web.evaluateJavaScript("const picker=document.querySelector('.mime-picker select');picker.value='1';picker.dispatchEvent(new Event('change'))")
            let alternate = try await web.evaluateJavaScript("document.querySelector('.output .rich-output').textContent") as? String
            XCTAssertEqual(alternate, "NeedleAtTheEnd 42")
        }
    }
}

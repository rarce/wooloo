import AppKit
import CryptoKit
import MarkdownView
import SwiftUI
import XCTest
@testable import wooloo

/// Synthetic documents, independent of the developer's files, used by the table benchmarks
/// and the visual checks. Links, inline code, wrapping and alignment exercise real cell layout.
enum MarkdownTableFixtures {
    static func table(rows: Int, columns: Int, number: Int = 0) -> String {
        let header = "| " + (0..<columns).map { "Column \($0 + 1)" }.joined(separator: " | ") + " |"
        let alignment = "| " + (0..<columns).map { [":---", ":---:", "---:"][$0 % 3] }.joined(separator: " | ") + " |"
        let body = (0..<rows).map { row in
            "| " + (0..<columns).map { column in
                switch column % 4 {
                case 0: "**Rule \(number)-\(row)**: preserve the source and its version"
                case 1: "[Evidence](https://example.invalid/\(row)) with `field_\(row)` and Unicode: acción 日本語"
                case 2: "\(row * 17 + column).25"
                default: "A longer explanation that wraps across several lines in a narrow column."
                }
            }.joined(separator: " | ") + " |"
        }
        return ([header, alignment] + body).joined(separator: "\n")
    }

    static let snapshot = "# Table layout\n\n" + table(rows: 3, columns: 4)
        + "\n\nParagraph after the table.\n\n" + table(rows: 1, columns: 3, number: 1)

    static var workloads: [(String, String)] {
        [
            ("prose", (0..<20).map { "## Section \($0)\n\nA paragraph with **emphasis**, `code` and [a link](https://example.invalid)." }.joined(separator: "\n\n")),
            ("many-tables", (0..<10).map { "## Section \($0)\n\n" + table(rows: 8, columns: 4, number: $0) }.joined(separator: "\n\n")),
            ("tall-table", table(rows: 100, columns: 4)),
            ("wide-table", table(rows: 12, columns: 12)),
        ]
    }
}

/// Opt-in Release timings of the actual SwiftUI preview, including table geometry, layout
/// and painting. Run scripts/markdown-bench.sh; ordinary unit tests skip these timings.
@MainActor
final class MarkdownTableBenchmarks: XCTestCase {
    func testPreviewRendering() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WOOLOO_BENCH_MARKDOWN"] == "1" else {
            throw XCTSkip("Run scripts/markdown-bench.sh to measure Markdown rendering")
        }
        let repetitions = max(1, Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 3)
        let output = environment["WOOLOO_BENCH_OUT"]
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-perf", workspaceID: "markdown-bench",
                                             workspaceLabel: "Markdown benchmark", root: "/private/tmp")
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MarkdownPreviewStyle.storageKey)
        defer { defaults.set(saved, forKey: MarkdownPreviewStyle.storageKey) }
        var workloads = MarkdownTableFixtures.workloads
        var externalLocation: WorkspaceFileLocation?
        var externalPath = "benchmark.md"
        if let path = environment["WOOLOO_BENCH_MARKDOWN_FILE"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw WorkspaceFileError.message("The benchmark document path must be absolute") }
            externalPath = (path as NSString).lastPathComponent
            let source = WorkspaceFileLocation(machine: nil, session: "wooloo-perf", workspaceID: "markdown-bench-file",
                                               workspaceLabel: "Markdown benchmark", root: (path as NSString).deletingLastPathComponent)
            externalLocation = source
            workloads.append(("external-document", try WorkspaceFiles.read(externalPath, at: source).text))
        }
        try report(["config": ["repeat": repetitions, "width": 1000, "height": 800, "resize_width": 780,
                                "scrollbars": Int(NSScroller.preferredScrollerStyle.rawValue), "theme": theme.id, "renderer": "MarkdownPreviewView", "capture": "AppKit-cacheDisplay-v1",
                                "base_font": WoolooTypography.defaultBase, "code_font": WoolooTypography.defaultCode]], to: output)
        for style in [MarkdownPreviewStyle.theme, .document] {
            defaults.set(style.rawValue, forKey: MarkdownPreviewStyle.storageKey)
            for (name, text) in workloads {
                let isExternal = name == "external-document"
                let renderedLocation = isExternal ? externalLocation! : location
                let renderedPath = isExternal ? externalPath : "benchmark.md"
                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                var samples: [String: [Double]] = [:]
                for _ in 0..<repetitions {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let host = NSHostingView(rootView: MarkdownPreviewView(text: text, path: renderedPath, location: renderedLocation, onOpenFile: { _ in })
                        .environment(\.woolooTheme, theme)
                        .environment(\.woolooTypography, WoolooTypography())
                        .preferredColorScheme(theme.colorScheme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
                    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.close() }
                    try draw(host)
                    samples["first-render", default: []].append(milliseconds(since: start))
                    // Let preference and geometry updates settle before measuring another size.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let resized = DispatchTime.now().uptimeNanoseconds
                    window.setContentSize(NSSize(width: 780, height: 800))
                    try draw(host)
                    XCTAssertEqual(host.bounds.width, 780, accuracy: 1, "The preview must actually resize")
                    samples["resize", default: []].append(milliseconds(since: resized))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let redrawn = DispatchTime.now().uptimeNanoseconds
                    try draw(host)
                    samples["cached-draw", default: []].append(milliseconds(since: redrawn))
                    let scrolled = DispatchTime.now().uptimeNanoseconds
                    let scroll = try XCTUnwrap(markdownScrollView(in: host))
                    let document = try XCTUnwrap(scroll.documentView)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.maxY - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    // Allow the bounds notification to instantiate newly visible lazy blocks.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    try draw(host)
                    samples["scroll", default: []].append(milliseconds(since: scrolled))
                }
                for stage in ["first-render", "resize", "cached-draw", "scroll"] {
                    let times = samples[stage]!.sorted()
                    func percentile(_ p: Double) -> Double { times[min(times.count - 1, max(0, Int(ceil(Double(times.count) * p)) - 1))] }
                    try report(["scenario": name, "style": style.rawValue, "stage": stage, "n": times.count,
                                "bytes": text.utf8.count, "sha256": digest, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
                                "max_ms": times.last!], to: output)
                }
            }
        }
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func draw(_ host: NSView) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    private func report(_ record: [String: Any], to path: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("WOOLOO-MARKDOWN " + String(decoding: data, as: UTF8.self))
        guard let path, !path.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([10]))
    }
}

/// Find must still reach blocks that have not been built by the lazy preview yet.
@MainActor
final class MarkdownPreviewRenderingTests: XCTestCase {
    func testDifferentShapeStylesAreNotEqual() {
        let red = AnyShapeStyle(SwiftUI.Color.red)
        let blue = AnyShapeStyle(SwiftUI.Color.blue)
        let copy = red
        XCTAssertEqual(red, copy)
        XCTAssertNotEqual(red, blue, "A different style must invalidate the renderer's environment")
    }

    func testFindScrollsToATableOutsideTheInitialViewport() throws {
        let text = (0..<80).map { "Paragraph \($0). " + String(repeating: "Keep the source and evidence together. ", count: 8) }
            .joined(separator: "\n\n") + "\n\n| Target | Value |\n| --- | --- |\n| NeedleAtTheEnd | 42 |"
        let find = DocumentFindModel()
        find.open(replace: false, query: "NeedleAtTheEnd")
        find.update(text: text, target: .preview, anchor: nil)
        let block = try XCTUnwrap(find.previewMatches.first?.block)
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-perf", workspaceID: "find-table",
                                             workspaceLabel: "Find table", root: "/private/tmp")
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MarkdownPreviewStyle.storageKey)
        defer { defaults.set(saved, forKey: MarkdownPreviewStyle.storageKey) }
        for style in [MarkdownPreviewStyle.theme, .document] {
            defaults.set(style.rawValue, forKey: MarkdownPreviewStyle.storageKey)
            func preview(focus: MarkdownFindFocus?) -> some View {
                MarkdownPreviewView(text: text, path: "table.md", location: location, onOpenFile: { _ in }, focus: focus)
                    .environment(\.woolooTheme, WoolooTheme.named(WoolooTheme.fallbackID)!)
                    .environment(\.woolooTypography, WoolooTypography())
                    .frame(width: 1000, height: 500)
            }
            let host = NSHostingView(rootView: preview(focus: nil))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let scroll = try XCTUnwrap(markdownScrollView(in: host))
            let start = scroll.documentVisibleRect.minY
            host.rootView = preview(focus: MarkdownFindFocus(block: block, match: 0))
            let deadline = Date().addingTimeInterval(3)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            } while (scroll.documentVisibleRect.maxY < (scroll.documentView?.bounds.height ?? 0) - 300)
                && Date() < deadline
            XCTAssertGreaterThan(scroll.documentVisibleRect.minY, start + 800, "\(style) find must reveal the offscreen table")
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(scroll.documentVisibleRect.maxY, document.bounds.height - 600,
                                 "Find must reach the last block, not just scroll partway")
        }
    }

}

@MainActor
private func markdownScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { markdownScrollView(in: $0) }.first
}

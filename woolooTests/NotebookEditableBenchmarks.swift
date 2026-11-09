import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import wooloo

@MainActor
private final class EditableNotebookState: ObservableObject {
    @Published var text: String
    @Published var matches: [MarkdownFindMatch] = []
    @Published var current: Int?
    @Published var reveal = 0
    var search: [String] = []
    var edits = 0

    init(_ text: String) { self.text = text }

    func apply(_ base: String, _ outcome: NotebookEditing.Outcome) -> Bool {
        guard text == base, case .success(let change?) = outcome else { return false }
        matches = []; current = nil; search = []
        text = change.text; edits += 1
        return true
    }
}

@MainActor
private struct EditableNotebookPreview: View {
    @ObservedObject var state: EditableNotebookState
    let style: MarkdownPreviewStyle

    var body: some View {
        let theme = WoolooTheme.named(WoolooTheme.fallbackID)!
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "editable-bench",
                                             workspaceLabel: "Notebook benchmark", root: "/private/tmp")
        NotebookPreviewView(text: state.text, path: "benchmark.ipynb", location: location,
                            onOpenFile: { _ in }, style: style, matches: state.matches, currentMatch: state.current,
                            revealRequest: state.reveal, onSearchText: { state.search = $0 },
                            onEdit: { _, base, outcome in state.apply(base, outcome) })
            .environment(\.woolooTheme, theme)
            .environment(\.woolooTypography, WoolooTypography())
            .preferredColorScheme(style == .document ? .light : theme.colorScheme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A separate series: the existing read-only fixtures and timing method remain unchanged.
@MainActor
final class NotebookEditableBenchmarks: XCTestCase {
    func testEditableOpeningFindAndCellEdit() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WOOLOO_BENCH_NOTEBOOK_EDITABLE"] == "1" else {
            throw XCTSkip("Run scripts/notebook-editable-bench.sh")
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure editable notebook")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let repeats = max(1, Int(environment["WOOLOO_BENCH_REPEAT"] ?? "") ?? 5)
        let path = try XCTUnwrap(environment["WOOLOO_BENCH_OUT"])
        try report(["config": ["repeat": repeats, "width": 1000, "height": 800, "resize_width": 780,
                                "base_font": WoolooTypography.defaultBase, "code_font": WoolooTypography.defaultCode,
                                "theme": WoolooTheme.fallbackID, "renderer": "NotebookPreviewView-editable",
                                "capture": "WKSnapshot-afterScreenUpdates-editable-full-index-v1",
                                "scrollbars": Int(NSScroller.preferredScrollerStyle.rawValue)]], path: path)
        for style in [MarkdownPreviewStyle.theme, .document] {
            for workload in try NotebookPreviewFixtures.workloads.filter({ ["many-cells", "max-cells"].contains($0.name) }) {
                var times: [String: [Double]] = [:]
                var viewport: [String: Int] = [:]
                for _ in 0..<repeats {
                    print("NOTEBOOK-EDITABLE opening \(style.rawValue) \(workload.name)")
                    let state = EditableNotebookState(workload.source)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let host = NSHostingView(rootView: EditableNotebookPreview(state: state, style: style))
                    host.frame = NSRect(x: 100, y: 100, width: 1000, height: 800)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    window.appearance = NSAppearance(named: style == .document ? .aqua : .darkAqua)
                    window.makeKeyAndOrderFront(nil); NSApp.activate(); host.layoutSubtreeIfNeeded()
                    defer { host.rootView = EditableNotebookPreview(state: EditableNotebookState(""), style: style); window.contentView = nil; window.close() }
                    var page: WKWebView?
                    try await until {
                        page = Self.webView(in: host)
                        guard let page else { return false }
                        return (try? await page.evaluateJavaScript("Number(document.getElementById('notebook')?.dataset.cells) === \(workload.cells) && !!document.querySelector('.cell-tools')")) as? Bool == true
                    }
                    let web = try XCTUnwrap(page)
                    times["first-viewport", default: []].append(ms(start))
                    try await until { !state.search.isEmpty }
                    times["full-index", default: []].append(ms(start))
                    try await capture(web)
                    times["first-render", default: []].append(ms(start))
                    let actualViewport = try await web.evaluateJavaScript("({width:document.documentElement.clientWidth,height:document.documentElement.clientHeight,gutter:innerWidth-document.documentElement.clientWidth})") as? [String: Int] ?? [:]
                    if !viewport.isEmpty { XCTAssertEqual(actualViewport, viewport) }
                    viewport = actualViewport
                    let query = "evidence_\(workload.cells - 1)"
                    let find = DocumentFindModel(); find.open(replace: false, query: query)
                    let findStart = DispatchTime.now().uptimeNanoseconds
                    print("NOTEBOOK-EDITABLE finding \(style.rawValue) \(workload.name)")
                    find.update(text: state.text, target: .preview, anchor: nil, previewTextNodes: state.search)
                    XCTAssertEqual(find.count, 2)
                    state.matches = find.previewMatches; state.current = find.current; state.reveal += 1
                    try await until {
                        try await web.evaluateJavaScript("!!document.querySelector('#cell-fixture-\(workload.cells - 1) .find-active') && Array.from(CSS.highlights.get('notebook-current') || []).some(range => range.toString() === '\(query)')") as? Bool == true
                    }
                    try await capture(web)
                    times["find-last-paint", default: []].append(ms(findStart))
                    let editStart = DispatchTime.now().uptimeNanoseconds
                    print("NOTEBOOK-EDITABLE editing \(style.rawValue) \(workload.name)")
                    _ = try await web.evaluateJavaScript("""
                        const section = document.getElementById('cell-fixture-\(workload.cells - 1)');
                        section.querySelector('.cell-tools button').click();
                        const editor = section.querySelector('textarea'); editor.value = 'print("EditedNotebookCell")';
                        editor.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',metaKey:true,bubbles:true}));
                        """)
                    try await until {
                        guard state.edits == 1, state.search.contains(where: { $0.contains("EditedNotebookCell") }) else { return false }
                        return try await web.evaluateJavaScript("document.getElementById('cell-fixture-\(workload.cells - 1)').textContent.includes('EditedNotebookCell') && !document.querySelector('textarea.cell-editor')") as? Bool == true
                    }
                    try await capture(web)
                    times["edit-paint", default: []].append(ms(editStart))
                    let diagnostics = try await web.evaluateJavaScript("JSON.stringify(window.notebook.diagnostics?.() || {})")
                    print("NOTEBOOK-EDITABLE-DIAGNOSTICS \(style.rawValue) \(workload.name) \(String(describing: diagnostics))")
                }
                let digest = SHA256.hash(data: Data(workload.source.utf8)).map { String(format: "%02x", $0) }.joined()
                for (stage, samples) in times.sorted(by: { $0.key < $1.key }) {
                    let ordered = samples.sorted()
                    try report(["scenario": workload.name, "style": style.rawValue, "stage": stage, "n": ordered.count,
                                "sha256": digest, "viewport": viewport, "p50_ms": ordered[(ordered.count - 1) / 2],
                                "p95_ms": ordered[min(ordered.count - 1, Int(ceil(Double(ordered.count) * 0.95)) - 1)],
                                "max_ms": ordered.last!], path: path)
                }
            }
        }
    }

    private func until(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        XCTFail("Editable notebook did not reach the expected state")
        throw NotebookDocument.ParseError.message("Editable notebook timed out")
    }

    private func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    private func capture(_ web: WKWebView) async throws {
        let _: Bool = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("""
                void document.documentElement.offsetHeight; await document.fonts.ready;
                await Promise.all(Array.from(document.images).filter(image => {
                    const r=image.getBoundingClientRect(); return r.bottom>0 && r.top<innerHeight;
                }).map(image => image.decode().catch(() => {})));
                await document.fonts.ready; return true;
                """, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result.map { $0 as? Bool == true })
            }
        }
        let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        XCTAssertEqual(image.size.width, 1000, accuracy: 1)
    }

    private func report(_ record: [String: Any], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
    }
}

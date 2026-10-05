import XCTest
import SwiftUI
import WebKit
@testable import xherdr

final class NotebookParsingTests: XCTestCase {
    static func source(cells: [[String: Any]], minor: Int = 5, metadata: [String: Any] = [:]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": minor,
                                                                    "metadata": metadata, "cells": cells]), as: UTF8.self)
    }

    static func cell(_ kind: String, source: Any = "", id: String = "cell", outputs: [[String: Any]] = []) -> [String: Any] {
        ["cell_type": kind, "source": source, "id": id, "metadata": [:], "outputs": outputs, "execution_count": NSNull()]
    }

    func testNormalizesSourcesWithoutInventingNewlinesAndPreservesOrderedOutputs() throws {
        let source = try Self.source(cells: [Self.cell("markdown", source: ["one", "two\n", "three"]),
                                           Self.cell("code", source: "print(1)", id: "code", outputs: [
                                            ["output_type": "stream", "name": "stdout", "text": ["a", "b\n"]],
                                            ["output_type": "stream", "name": "stderr", "text": "warning"],
                                            ["output_type": "error", "ename": "Error", "evalue": "bad", "traceback": ["frame", "bad"]],
                                            ["output_type": "execute_result", "execution_count": 9, "data": ["text/plain": "4", "text/html": "<b>4</b>"], "metadata": [:]]])],
                                     metadata: ["language_info": ["name": "julia"]])
        let notebook = try NotebookDocument.parse(source)
        XCTAssertEqual(notebook.language, "julia")
        XCTAssertEqual(notebook.cells[0].source, "onetwo\nthree")
        XCTAssertEqual(notebook.cells[1].outputs.map(\.kind), ["stdout", "stderr", "error", "execute_result"])
        XCTAssertEqual(notebook.cells[1].outputs[0].text, "ab\n")
        XCTAssertEqual(notebook.cells[1].outputs[2].text, "frame\nbad")
        XCTAssertEqual(notebook.cells[1].outputs[3].executionCount, 9)
        XCTAssertEqual(notebook.cells[1].outputs[3].representations.count, 2)
    }

    func testJSONScalarOutputsAndCellLocalAttachmentsRemainDistinct() throws {
        var first = Self.cell("markdown", source: "![a](attachment:same.png)")
        first["attachments"] = ["same.png": ["image/png": "first"]]
        var second = Self.cell("markdown", source: "![b](attachment:same.png)", id: "second")
        second["attachments"] = ["same.png": ["image/png": "second"]]
        let model = try NotebookDocument.parse(Self.source(cells: [first, second, Self.cell("code", id: "json", outputs: [
            ["output_type": "display_data", "data": ["application/json": false], "metadata": [:]],
            ["output_type": "display_data", "data": ["application/json": [1, 2]], "metadata": [:]]])]))
        let a = try XCTUnwrap(model.cells[0].attachments["same.png"]?.first?.imageID)
        let b = try XCTUnwrap(model.cells[1].attachments["same.png"]?.first?.imageID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(model.images[a]?.base64, "first")
        XCTAssertEqual(model.images[b]?.base64, "second")
        XCTAssertEqual(model.cells[2].outputs[0].representations.first?.text, "false")
        XCTAssertTrue(model.cells[2].outputs[1].representations.first?.text.contains("2") == true)
        XCTAssertFalse(model.previewJSON.contains("base64"), "Image data is served separately from the page payload")
    }

    func testLegacyAndDuplicateIDsReceiveDisplayIdentitiesWithoutChangingOriginalJSON() throws {
        var cell = Self.cell("raw", source: "<script>text only</script>"); cell.removeValue(forKey: "id")
        let text = try Self.source(cells: [cell], minor: 4)
        let model = try NotebookDocument.parse(text)
        XCTAssertEqual(model.cells[0].id, "@cell-0")
        XCTAssertTrue(model.warnings.isEmpty)
        XCTAssertFalse(text.contains("@cell"))
        let duplicates = try NotebookDocument.parse(Self.source(cells: [Self.cell("raw"), Self.cell("raw")]))
        XCTAssertNotEqual(duplicates.cells[0].id, duplicates.cells[1].id)
        XCTAssertEqual(duplicates.warnings.count, 1)
    }

    func testRejectsInvalidVersionAndEssentialFieldsWhileKeepingUnknownOutputInspectable() throws {
        for text in ["{", "[]", #"{"nbformat":true,"nbformat_minor":5,"metadata":{},"cells":[]}"#,
                     #"{"nbformat":3,"nbformat_minor":0,"metadata":{},"cells":[]}"#,
                     #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":[1]}]}"#] {
            XCTAssertThrowsError(try NotebookDocument.parse(text))
        }
        let model = try NotebookDocument.parse(Self.source(cells: [Self.cell("code", outputs: [["output_type": "future-output"]])], minor: 6))
        XCTAssertTrue(model.warnings.contains { $0.contains("Newer") })
        XCTAssertEqual(model.cells[0].outputs[0].kind, "unsupported")
        XCTAssertTrue(model.cells[0].outputs[0].text.contains("future-output"))
    }

    func testPreviewBoundsDoNotTruncateTheSourceDocument() throws {
        let full = String(repeating: "a", count: NotebookDocument.maximumTextCharacters + 1)
        let source = try Self.source(cells: [Self.cell("code", source: full)])
        let model = try NotebookDocument.parse(source)
        XCTAssertTrue(model.cells[0].source.contains("Preview truncated"))
        XCTAssertTrue(source.contains(full))
        XCTAssertThrowsError(try NotebookDocument.parse(String(repeating: " ", count: NotebookDocument.maximumFileBytes + 1)))
        XCTAssertThrowsError(try NotebookDocument.parse(Self.source(cells: Array(repeating: Self.cell("raw"), count: NotebookDocument.maximumCells + 1))))
    }

    func testNotebookReadAndSaveUseTheSameLargerLimitAndKeepConflictChecks() throws {
        let sandbox = try WorkspaceGitSandbox(); defer { sandbox.tearDown() }
        let original = try Self.source(cells: [Self.cell("code", source: String(repeating: "a", count: 1_100_000))])
        let location = try sandbox.repository("repo", files: ["large.ipynb": original, "large.txt": original])
        let contents = try WorkspaceFiles.read("large.ipynb", at: location)
        XCTAssertEqual(contents.text, original)
        XCTAssertThrowsError(try WorkspaceFiles.read("large.txt", at: location))
        let next = original + "\n"
        let version = try WorkspaceFiles.save(next, path: "large.ipynb", expectedVersion: contents.version, at: location)
        XCTAssertEqual(try sandbox.read("large.ipynb", in: "repo"), next)
        XCTAssertThrowsError(try WorkspaceFiles.save(original, path: "large.ipynb", expectedVersion: contents.version, at: location))
        XCTAssertThrowsError(try WorkspaceFiles.save(next, path: "large.txt", expectedVersion: version, at: location))
        var document = WorkspaceDocument(location: location, path: "large.ipynb", kind: .file)
        XCTAssertTrue(document.supportsPreview)
        document.reveal = WorkspaceDocumentReveal(line: 2, range: nil)
        XCTAssertEqual(document.markdownMode, .source)
    }
}

@MainActor
final class NotebookRenderingTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.contentView = nil; window?.close(); window = nil
    }

    private func render(_ source: String, search: @escaping ([String]) -> Void = { _ in }) async throws -> WKWebView {
        let location = WorkspaceFileLocation(machine: nil, session: "xherdr-ui-test", workspaceID: "test",
                                             workspaceLabel: "Notebook test", root: "/private/tmp")
        let model = try NotebookDocument.parse(source)
        let view = NotebookWebView(notebook: model, path: "preview.ipynb", location: location,
                                   theme: XherdrTheme.all[0], typography: XherdrTypography(), matches: [],
                                   currentMatch: nil, revealRequest: 0, onOpenFile: { _ in },
                                   onSearchText: search, onFindCommand: { _, _, _ in })
        let host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false; window?.title = "Notebook rendering test"
        window?.contentView = host; window?.makeKeyAndOrderFront(nil)
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        for _ in 0..<200 {
            if let web = findWebView(host), (try? await web.evaluateJavaScript("document.querySelectorAll('.cell').length")) as? Int == model.cells.count,
               !model.cells.isEmpty { return web }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NotebookDocument.ParseError.message("Notebook did not render its cells")
    }

    func testActualWebKitRendersMathTablesCodeAndSanitizesStoredActiveContent() async throws {
        let malicious = #"<script>window.injectedNotebook=true</script><div style="position:fixed" onclick="window.injectedNotebook=true"><table><tr><td>Saved value</td></tr></table></div><iframe src="https://example.invalid"></iframe><a href="javascript:window.injectedNotebook=true">bad link</a>"#
        let source = try NotebookParsingTests.source(cells: [NotebookParsingTests.cell("markdown", source: "# Heading\n\n$E=mc^2$ and $a_b^2$\n\n\\(x^2\\)\n\n\\[y^2\\]"),
            NotebookParsingTests.cell("code", source: "print('saved')", id: "code", outputs: [
                ["output_type": "display_data", "data": ["text/html": malicious, "text/plain": "fallback"], "metadata": [:]],
                ["output_type": "display_data", "data": ["application/javascript": "window.injectedNotebook=true", "text/plain": "JavaScript skipped"], "metadata": [:]]])])
        var searchable: [String] = []
        let web = try await render(source, search: { searchable = $0 })
        let result = try await web.evaluateJavaScript("({heading:document.querySelector('h1').textContent, math:document.querySelectorAll('.katex').length, tables:document.querySelectorAll('table').length, code:document.querySelector('.source').textContent, unsafe:!!window.injectedNotebook, frames:document.querySelectorAll('iframe').length, inlineStyles:document.querySelectorAll('.output .rich-output [style]').length, javascriptLinks:Array.from(document.querySelectorAll('a')).some(a=>a.getAttribute('href')?.startsWith('javascript:')), text:document.body.textContent})") as? [String: Any]
        XCTAssertEqual(result?["math"] as? Int, 4)
        XCTAssertEqual(result?["tables"] as? Int, 1)
        XCTAssertEqual(result?["code"] as? String, "print('saved')")
        XCTAssertEqual(result?["unsafe"] as? Bool, false)
        XCTAssertEqual(result?["frames"] as? Int, 0)
        XCTAssertEqual(result?["inlineStyles"] as? Int, 0)
        XCTAssertEqual(result?["javascriptLinks"] as? Bool, false)
        XCTAssertTrue((result?["text"] as? String)?.contains("JavaScript skipped") == true)
        XCTAssertTrue(searchable.contains { $0.contains("Saved value") })
        _ = try await web.evaluateJavaScript("document.querySelector('.mime-picker select').value='1';document.querySelector('.mime-picker select').dispatchEvent(new Event('change'))")
        let alternate = try await web.evaluateJavaScript("document.querySelector('.output .rich-output').textContent") as? String
        XCTAssertEqual(alternate, "fallback")
    }

    func testInvalidRasterFallsBackToTextAndFindHighlightsRenderedContent() async throws {
        let source = try NotebookParsingTests.source(cells: [NotebookParsingTests.cell("code", source: "x", outputs: [
            ["output_type": "display_data", "data": ["image/png": "broken", "text/plain": "Recovered saved output"], "metadata": [:]]])])
        var texts: [String] = []
        let web = try await render(source, search: { texts = $0 })
        for _ in 0..<100 where !texts.contains("Recovered saved output") { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(texts.contains("Recovered saved output"))
        let model = DocumentFindModel(); model.open(replace: false, query: "saved")
        model.update(text: source, target: .preview, anchor: 0, previewTextNodes: texts)
        let match = try XCTUnwrap(model.previewMatches.first)
        XCTAssertEqual(model.count, 1)
        _ = try await web.evaluateJavaScript("window.notebook.find([{block:\(match.block),lower:\(match.range.lowerBound),upper:\(match.range.upperBound),index:0}],0,true)")
        let active = try await web.evaluateJavaScript("document.querySelector('.find-active').textContent") as? String
        XCTAssertEqual(active, "Recovered saved output")
    }

    /// Generated by the optional Python development environment; CI still covers the renderer above.
    func testPythonGeneratedSavedOutputNotebooks() async throws {
        guard let path = ProcessInfo.processInfo.environment["XHERDR_NOTEBOOK_FIXTURES"] else {
            throw XCTSkip("Generate fixtures with scripts/notebook-fixtures.py and set XHERDR_NOTEBOOK_FIXTURES")
        }
        let directory = URL(fileURLWithPath: path)
        for name in ["preview", "legacy", "untrusted", "large"] {
            window?.contentView = nil; window?.close(); window = nil
            let source = try String(contentsOf: directory.appendingPathComponent(name + ".ipynb"), encoding: .utf8)
            let web = try await render(source)
            if name == "preview" || name == "legacy" {
                for _ in 0..<100 {
                    let loaded = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('img')).every(image=>image.complete&&image.naturalWidth>0)") as? Bool
                    if loaded == true { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                let result = try await web.evaluateJavaScript("({images:Array.from(document.querySelectorAll('img')).filter(image=>image.naturalWidth>0).length, math:document.querySelectorAll('.katex').length, svg:document.querySelectorAll('svg').length,tables:document.querySelectorAll('table').length,text:document.body.textContent})") as? [String: Any]
                XCTAssertEqual(result?["images"] as? Int, 2, name)
                XCTAssertEqual(result?["math"] as? Int, 2, name)
                XCTAssertEqual(result?["svg"] as? Int, 1, name)
                XCTAssertEqual(result?["tables"] as? Int, 2, name)
                XCTAssertTrue((result?["text"] as? String)?.contains("Widget (saved text fallback)") == true, name)
                XCTAssertTrue((result?["text"] as? String)?.contains("Inspect saved output") == true, name)
                if name == "preview" {
                    // Verify a MIME switch displays the saved matplotlib SVG rather than executing code.
                    _ = try await web.evaluateJavaScript("const pick=document.querySelectorAll('.mime-picker select')[1];pick.value='1';pick.dispatchEvent(new Event('change'))")
                    let svgCount = try await web.evaluateJavaScript("document.querySelectorAll('svg').length") as? Int
                    XCTAssertEqual(svgCount, 2)
                    let stroke = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.output svg [stroke]')).some(element=>getComputedStyle(element).stroke==='rgb(31, 119, 180)')") as? Bool
                    XCTAssertEqual(stroke, true, "Matplotlib SVG strokes survive sanitization")
                    let styles = try await web.evaluateJavaScript("document.querySelectorAll('#notebook svg [style]').length") as? Int
                    XCTAssertEqual(styles, 0, "Only SVG presentation attributes survive")
                }
            } else if name == "untrusted" {
                let result = try await web.evaluateJavaScript("({injected:!!window.notebookInjected,active:document.querySelectorAll('#notebook script, #notebook iframe, #notebook foreignObject, #notebook [onclick], #notebook [onerror], #notebook [onload]').length,externalImages:Array.from(document.querySelectorAll('img')).filter(image=>image.src.startsWith('http')).length,text:document.body.textContent})") as? [String: Any]
                XCTAssertEqual(result?["injected"] as? Bool, false)
                XCTAssertEqual(result?["active"] as? Int, 0)
                XCTAssertEqual(result?["externalImages"] as? Int, 0)
                XCTAssertTrue((result?["text"] as? String)?.contains("JavaScript skipped") == true)
            } else {
                let text = try await web.evaluateJavaScript("document.querySelector('.stdout').textContent") as? String
                XCTAssertTrue(text?.contains("Preview truncated") == true)
                XCTAssertGreaterThan(source.utf8.count, WorkspaceFiles.maximumFileBytes)
            }
        }
        let invalid = try String(contentsOf: directory.appendingPathComponent("invalid.ipynb"), encoding: .utf8)
        XCTAssertThrowsError(try NotebookDocument.parse(invalid))
    }

    func testResourceHandlerRejectsNonImagesEscapesAndOldDocumentResources() throws {
        let sandbox = try WorkspaceGitSandbox(); defer { sandbox.tearDown() }
        try sandbox.write(["secret.txt": "not an image"], in: ".")
        let resources = NotebookResources()
        resources.replace(images: ["bad": .init(base64: "broken", mime: "image/png")],
                          location: sandbox.location(""), documentPath: "preview.ipynb", revision: "first")
        XCTAssertNil(resources.registerImage("../outside.png"))
        XCTAssertNil(resources.registerImage("https://example.invalid/image.png"))
        XCTAssertThrowsError(try resources.data(for: URL(string: "xherdr-notebook://first/image/bad")))
        let text = try XCTUnwrap(resources.registerImage("secret.txt"))
        XCTAssertThrowsError(try resources.data(for: URL(string: text)))
        resources.clear()
        XCTAssertThrowsError(try resources.data(for: URL(string: text)))
        XCTAssertThrowsError(try resources.data(for: URL(string: "xherdr-notebook://app/vendor/../sources.json")))
    }
}

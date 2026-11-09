import XCTest
import SwiftUI
import WebKit
@testable import wooloo

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

    func testTruncationPreservesGraphemesAndWarnsOnlyAboveTheLimit() throws {
        let limit = NotebookDocument.maximumTextCharacters
        let suffix = "\n… Preview truncated; full data remains in Source view."
        for value in [String(repeating: "a", count: limit - 1), String(repeating: "a", count: limit),
                      String(repeating: "a", count: limit + 1),
                      String(repeating: "a", count: limit - 1) + "👩🏽‍💻Z",
                      String(repeating: "e\u{301}", count: limit + 1)] {
            let truncated = value.count > limit
            let expected = truncated ? String(value.prefix(limit)) + suffix : value
            var cell = Self.cell("code", source: value, outputs: [
                ["output_type": "stream", "text": value],
                ["output_type": "error", "traceback": [value]],
                ["output_type": "display_data", "data": ["text/plain": value]]])
            cell["attachments"] = ["evidence.txt": ["text/plain": value]]
            let original = try Self.source(cells: [cell])
            let notebook = try NotebookDocument.parse(original)
            let parsed = notebook.cells[0]
            XCTAssertTrue(parsed.source == expected)
            XCTAssertTrue(parsed.outputs[0].text == expected)
            XCTAssertTrue(parsed.outputs[1].text == expected)
            XCTAssertTrue(parsed.outputs[2].representations[0].text == expected)
            XCTAssertTrue(parsed.attachments["evidence.txt"]?[0].text == expected)
            XCTAssertEqual(notebook.warnings.contains { $0.contains("source is truncated") }, truncated)
            let decoded = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any]
            XCTAssertTrue((decoded?["cells"] as? [[String: Any]])?[0]["source"] as? String == value)
        }
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

    private func render(_ source: String, matches: [MarkdownFindMatch] = [], currentMatch: Int? = nil,
                        search: @escaping ([String]) -> Void = { _ in }) async throws -> WKWebView {
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "test",
                                             workspaceLabel: "Notebook test", root: "/private/tmp")
        let model = try NotebookDocument.parse(source)
        let view = NotebookWebView(notebook: model, path: "preview.ipynb", location: location,
                                   theme: WoolooTheme.all[0], typography: WoolooTypography(), matches: matches,
                                   currentMatch: currentMatch, revealRequest: 0, onOpenFile: { _ in },
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

    func testLargeNotebookFillsTheViewportAndRestoresItsCellBeforeTheFirstPaint() async throws {
        // Blank Markdown lines have large estimated heights but collapse when rendered.
        // Filling only the first estimated batch would leave empty slots on screen.
        let cells = (0..<260).map {
            NotebookPreviewFixtures.cell("markdown", $0, source: "## Cell \($0)\n\n" + String(repeating: "\n", count: 100))
        }
        let workload = try NotebookPreviewFixtures.make("estimated-heights", cells: cells)
        let model = try NotebookDocument.parse(workload.source)
        for style in [MarkdownPreviewStyle.theme, .document] {
            let harness = NotebookPreviewHarness(workload, style: style)
            defer { harness.close() }
            let web = try await harness.ready()
            let result = try await web.evaluateJavaScript("""
                (() => {
                    const data = \(model.previewJSON);
                    const visible = () => Array.from(document.querySelectorAll('.cell-slot')).filter(slot => {
                        const rect = slot.getBoundingClientRect();
                        return rect.bottom > 0 && rect.top < innerHeight;
                    });
                    const filled = () => visible().length > 0 && visible().every(slot => slot.querySelector('.cell'));
                    window.notebook.render({...data, cells:[]}, 'empty-initial', {}, false);
                    window.notebook.render(data, 'initial', {}, false);
                    const initial = filled();
                    // A newly created webview has no previous top cell to override `start`.
                    window.notebook.render({...data, cells:[]}, 'empty', {}, false);
                    window.notebook.render(data, 'restored', {}, false, {cell:'cell-fixture-120', offset:-20});
                    return {initial, restored:filled(), top:document.getElementById('cell-fixture-120').getBoundingClientRect().top};
                })()
                """) as? [String: Any]
            XCTAssertEqual(result?["initial"] as? Bool, true)
            XCTAssertEqual(result?["restored"] as? Bool, true)
            XCTAssertEqual(try XCTUnwrap(result?["top"] as? Double), -20, accuracy: 1)
        }
    }

    func testDeferredCodeFindKeepsEveryRangeWhenRevealingTheSecondMatch() async throws {
        for breaks in ["\n", "\r\n", "\r"] {
            let cells = (0..<250).map { index in
                NotebookPreviewFixtures.cell("code", index, source: index == 249
                    ? "print('needle')" + breaks + "print('needle')" : "pass")
            }
            let workload = try NotebookPreviewFixtures.make("deferred-find", cells: cells)
            let harness = NotebookPreviewHarness(workload, style: .theme)
            defer { harness.close() }
            let web = try await harness.ready()
            let find = DocumentFindModel(); find.open(replace: false, query: "needle")
            find.update(text: workload.source, target: .preview, anchor: nil, previewTextNodes: harness.probe.searchText ?? [])
            XCTAssertEqual(find.count, 2)
            let ranges = find.previewMatches.enumerated().map { index, match in
                ["block": match.block, "lower": match.range.lowerBound, "upper": match.range.upperBound, "index": index]
            }
            let data = try JSONSerialization.data(withJSONObject: ranges)
            let json = String(decoding: data, as: UTF8.self)
            let result = try await web.evaluateJavaScript("""
                (() => {
                    window.notebook.find(\(json), 1, true);
                    const section = document.getElementById('cell-fixture-249');
                    return {ranges:Array.from(CSS.highlights.get('notebook-find')).map(r => r.toString()),
                        current:Array.from(CSS.highlights.get('notebook-current')).map(r => r.toString()),
                        connected:section.isConnected, highlighted:!!section.querySelector('.hljs-string')};
                })()
                """) as? [String: Any]
            XCTAssertEqual(result?["ranges"] as? [String], ["needle", "needle"], breaks.debugDescription)
            XCTAssertEqual(result?["current"] as? [String], ["needle"])
            XCTAssertEqual(result?["connected"] as? Bool, true)
            XCTAssertEqual(result?["highlighted"] as? Bool, true)
        }
    }

    func testVisibleMIMESwitchAndImageFallbackActivateDeferredMarkdownCode() async throws {
        let output = NotebookPreviewFixtures.display(["text/html": "<p>Initial output</p>",
            "text/markdown": "```python\nprint('needle')\n```"])
        let fallback = NotebookPreviewFixtures.display(["image/png": "broken",
            "text/markdown": "```python\nprint('fallback')\n```"])
        let cells = (0..<250).map { index in
            NotebookPreviewFixtures.cell("code", index, source: "pass", outputs: index == 0 ? [output, fallback] : [])
        }
        let workload = try NotebookPreviewFixtures.make("deferred-mime", cells: cells)
        let harness = NotebookPreviewHarness(workload, style: .theme)
        defer { harness.close() }
        let web = try await harness.ready()
        _ = try await web.evaluateJavaScript("""
            const picker = document.querySelector('.mime-picker select');
            picker.value='1'; picker.dispatchEvent(new Event('change'));
            """)
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("document.querySelectorAll('#cell-fixture-0 .markdown .hljs-string').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await web.evaluateJavaScript("""
            ({highlighted:document.querySelectorAll('#cell-fixture-0 .markdown .hljs-string').length,
              pending:document.querySelectorAll('#cell-fixture-0 [data-notebook-language]').length})
            """) as? [String: Int]
        XCTAssertEqual(result?["highlighted"], 2)
        XCTAssertEqual(result?["pending"], 0)
        XCTAssertTrue(harness.probe.searchText?.contains(where: { $0.contains("needle") }) == true)
        XCTAssertTrue(harness.probe.searchText?.contains(where: { $0.contains("fallback") }) == true)
    }

    func testColorChangePreservesTheEditorAndOutputState() async throws {
        let source = try NotebookParsingTests.source(cells: [NotebookParsingTests.cell("code", source: "print('original')", outputs: [
            NotebookPreviewFixtures.display(["text/html": "<p>Initial</p>", "text/plain": "Alternate"])
        ])])
        let web = try await render(source)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? NotebookWebView.Coordinator)
        var owner = coordinator.owner
        owner.onEdit = { _, _, _ in XCTFail("A color change must not save the editor"); return false }
        let find = DocumentFindModel(); find.open(replace: false, query: "original")
        find.update(text: source, target: .preview, anchor: nil, previewTextNodes: ["print('original')", "Initial"])
        owner.matches = find.previewMatches; owner.currentMatch = find.current
        coordinator.update(owner)
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("!!document.querySelector('.cell-tools')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("""
            const picker = document.querySelector('.mime-picker select'); picker.value='1'; picker.dispatchEvent(new Event('change'));
            document.querySelector('details.output').open=false;
            document.querySelector('.cell-tools button').click();
            window.savedEditor=document.querySelector('textarea.cell-editor');
            savedEditor.value='Unsaved text'; savedEditor.setSelectionRange(2,5); savedEditor.focus();
            """)
        let revision = coordinator.revision
        owner = NotebookWebView(notebook: owner.notebook, path: owner.path, location: owner.location,
                                theme: WoolooTheme.all[1], typography: owner.typography, matches: owner.matches, currentMatch: owner.currentMatch,
                                revealRequest: owner.revealRequest, onOpenFile: owner.onOpenFile, onSearchText: owner.onSearchText,
                                onFindCommand: owner.onFindCommand, onEdit: owner.onEdit)
        coordinator.update(owner)
        // Calls are ordered in WebKit; this query follows the palette update.
        let result = try await web.evaluateJavaScript("""
            ({same:savedEditor===document.querySelector('textarea.cell-editor'), value:savedEditor.value,
              start:savedEditor.selectionStart, end:savedEditor.selectionEnd, focused:document.activeElement===savedEditor,
              mime:document.querySelector('.mime-picker select').value, collapsed:!document.querySelector('details.output').open,
              background:document.documentElement.style.getPropertyValue('--background'),
              found:Array.from(CSS.highlights.get('notebook-current') || []).map(r=>r.toString()).join('')})
            """) as? [String: Any]
        XCTAssertEqual(coordinator.revision, revision)
        XCTAssertEqual(result?["same"] as? Bool, true)
        XCTAssertEqual(result?["value"] as? String, "Unsaved text")
        XCTAssertEqual(result?["start"] as? Int, 2)
        XCTAssertEqual(result?["end"] as? Int, 5)
        XCTAssertEqual(result?["focused"] as? Bool, true)
        XCTAssertEqual(result?["mime"] as? String, "1")
        XCTAssertEqual(result?["collapsed"] as? Bool, true)
        XCTAssertEqual(result?["background"] as? String, NotebookWebView.Coordinator.palette(theme: owner.theme, typography: owner.typography)["--background"])
        XCTAssertEqual(result?["found"] as? String, "original")
        _ = try await web.evaluateJavaScript("savedEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
    }

    func testCellEditReusesOnlyUnchangedStaticMarkdownAndRestoreClosesTheEditor() async throws {
        let cells = [
            NotebookPreviewFixtures.cell("markdown", 0, source: "## Static math\n\n$E=mc^2$"),
            NotebookPreviewFixtures.cell("markdown", 1, source: "![missing](attachment:missing.png)"),
            NotebookPreviewFixtures.cell("code", 2, source: "print('before')")
        ]
        let workload = try NotebookPreviewFixtures.make("reuse-markdown", cells: cells)
        let model = try NotebookDocument.parse(workload.source)
        let harness = NotebookPreviewHarness(workload, style: .theme)
        defer { harness.close() }
        let web = try await harness.ready()
        let result = try await web.evaluateJavaScript("""
            (() => {
                const data=\(model.previewJSON), palette={'--body-size':'13px','--code-size':'12px'};
                window.notebook.render(data,'initial',palette,true);
                const before=Array.from(document.querySelectorAll('.cell'));
                window.notebook.find([{block:0,lower:0,upper:6,index:0}],0,false);
                const edited=JSON.parse(JSON.stringify(data)); edited.cells[2].source="print('after')";
                window.notebook.render(edited,'edited',palette,true);
                const after=Array.from(document.querySelectorAll('.cell'));
                const reused=before[0]===after[0], imageRebuilt=before[1]!==after[1], codeRebuilt=before[2]!==after[2];
                const cleared=!after[0].querySelector('.find-active') && !after[0].classList.contains('find-active')
                    && (CSS.highlights.get('notebook-find')?.size ?? 0) === 0 && (CSS.highlights.get('notebook-current')?.size ?? 0) === 0;
                after[0].querySelector('.cell-tools button').click();
                const editor=document.querySelector('textarea.cell-editor'); editor.value='Unsaved';
                window.notebook.restore('edited');
                const restored=!document.querySelector('textarea.cell-editor') && document.querySelector('#cell-fixture-0 .markdown').textContent.includes('Static math');
                const sameAfterRestore=after[0]===document.getElementById('cell-fixture-0');
                return {reused,imageRebuilt,codeRebuilt,cleared,restored,sameAfterRestore,
                    controls:document.querySelectorAll('#cell-fixture-0 .cell-tools').length};
            })()
            """) as? [String: Any]
        XCTAssertEqual(result?["reused"] as? Bool, true)
        XCTAssertEqual(result?["imageRebuilt"] as? Bool, true)
        XCTAssertEqual(result?["codeRebuilt"] as? Bool, true)
        XCTAssertEqual(result?["cleared"] as? Bool, true)
        XCTAssertEqual(result?["restored"] as? Bool, true)
        XCTAssertEqual(result?["sameAfterRestore"] as? Bool, false)
        XCTAssertEqual(result?["controls"] as? Int, 1)
    }

    func testReusedOffscreenMarkdownGetsANewSlotAndCanBeFoundAndHighlighted() async throws {
        let cells = (0..<250).map { index in
            NotebookPreviewFixtures.cell("markdown", index, source: index == 249
                ? "```python\nprint('needle')\n```" : "# Cell \(index)")
        }
        let workload = try NotebookPreviewFixtures.make("reuse-offscreen", cells: cells)
        let model = try NotebookDocument.parse(workload.source)
        let harness = NotebookPreviewHarness(workload, style: .theme)
        defer { harness.close() }
        let web = try await harness.ready()
        let result = try await web.evaluateJavaScript("""
            (() => {
                const data=\(model.previewJSON), palette={'--body-size':'13px','--code-size':'12px'};
                window.notebook.render(data,'first',palette,true);
                const oldSlot=document.querySelectorAll('.cell-slot')[249], before=oldSlot.cellSection;
                const deferred=!!before.querySelector('[data-notebook-language]') && !before.isConnected;
                const edited=JSON.parse(JSON.stringify(data)); edited.cells[1].source='# Changed';
                window.notebook.render(edited,'edited',palette,true);
                const newSlot=document.querySelectorAll('.cell-slot')[249], after=newSlot.cellSection;
                const reused=before===after, newLink=oldSlot!==newSlot && after.cellSlot===newSlot;
                const lower=after.querySelector('.markdown').textContent.indexOf('needle');
                window.notebook.find([{block:249,lower,upper:lower+6,index:0}],0,true);
                window.notebook.find([{block:249,lower,upper:lower+6,index:0}],0,true);
                const found=Array.from(CSS.highlights.get('notebook-current')).map(r=>r.toString()).join('');
                const highlighted=!!after.querySelector('.hljs-string') && !after.querySelector('[data-notebook-language]');
                const controls=after.querySelectorAll('.cell-tools').length;
                const changed=JSON.parse(JSON.stringify(edited)); changed.cells[249].source='# Replacement';
                window.notebook.render(changed,'changed-source',palette,true);
                const replaced=document.querySelectorAll('.cell-slot')[249].cellSection;
                window.notebook.render(changed,'changed-font',{...palette,'--body-size':'18px'},true);
                const resized=document.querySelectorAll('.cell-slot')[249].cellSection;
                return {deferred,reused,newLink,found,highlighted,controls,sourceRebuilt:replaced!==after,fontRebuilt:resized!==replaced};
            })()
            """) as? [String: Any]
        for key in ["deferred", "reused", "newLink", "highlighted", "sourceRebuilt", "fontRebuilt"] {
            XCTAssertEqual(result?[key] as? Bool, true, key)
        }
        XCTAssertEqual(result?["found"] as? String, "needle")
        XCTAssertEqual(result?["controls"] as? Int, 1)
    }

    func testQuickFindJumpsPreserveAnOpenEditorAndInternalLinksReachOffscreenCells() async throws {
        let cells = (0..<260).map { index in
            NotebookPreviewFixtures.cell("markdown", index, source: index == 0
                ? "[Go to end](#last-heading)\n\nneedlefirst"
                : index == 259 ? "<h2 id='last-heading'>needlelast</h2>" : "## Cell \(index)")
        }
        let workload = try NotebookPreviewFixtures.make("quick-jumps", cells: cells)
        let model = try NotebookDocument.parse(workload.source)
        let harness = NotebookPreviewHarness(workload, style: .theme)
        defer { harness.close() }
        let web = try await harness.ready()
        _ = try await web.evaluateJavaScript("""
            window.notebook.render(\(model.previewJSON),'quick-jumps',{},true);
            document.querySelector('.cell-tools button').click();
            document.querySelector('textarea.cell-editor').value='Unsaved source';
            window.jumpTo = (block, query) => {
                const section=document.querySelectorAll('.cell-slot')[block].cellSection;
                const lower=section.querySelector('.markdown').textContent.indexOf(query);
                window.notebook.find([{block,lower,upper:lower+query.length,index:0}],0,true);
            };
            jumpTo(259,'needlelast'); jumpTo(0,'needlefirst'); jumpTo(259,'needlelast');
            """)
        _ = try await harness.capture(web)
        let editor = try await web.evaluateJavaScript("document.querySelector('textarea.cell-editor')?.value") as? String
        XCTAssertEqual(editor, "Unsaved source")
        let current = try await web.evaluateJavaScript("Array.from(CSS.highlights.get('notebook-current') || []).map(r=>r.toString()).join('')") as? String
        XCTAssertEqual(current, "needlelast")
        _ = try await web.evaluateJavaScript("""
            document.querySelector('textarea.cell-editor').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
            window.scrollTo(0,0);
            """)
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("!!document.querySelector('#cell-fixture-0 a')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("document.querySelector('#cell-fixture-0 a').click()")
        _ = try await harness.capture(web)
        let result = try await web.evaluateJavaScript("""
            (() => {
                const heading=document.getElementById('last-heading'), rect=heading?.getBoundingClientRect();
                return {visible:!!rect && rect.bottom>0 && rect.top<innerHeight,
                    bounded:document.querySelectorAll('.cell').length<80,
                    controls:document.querySelectorAll('#cell-fixture-259 .cell-tools').length};
            })()
            """) as? [String: Any]
        XCTAssertEqual(result?["visible"] as? Bool, true)
        XCTAssertEqual(result?["bounded"] as? Bool, true)
        XCTAssertEqual(result?["controls"] as? Int, 1)
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

    func testMissingAttachmentsNamedLikeObjectPropertiesDoNotStopRendering() async throws {
        var attached = NotebookParsingTests.cell("markdown", source: "![present](attachment:constructor)", id: "attached")
        attached["attachments"] = ["constructor": ["image/svg+xml": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect width=\"40\" height=\"40\"/></svg>"]]
        let source = try NotebookParsingTests.source(cells: [
            NotebookParsingTests.cell("markdown", source: "![missing](attachment:constructor)\n\n![missing](attachment:toString)\n\n![missing](attachment:__proto__)"),
            attached,
            NotebookParsingTests.cell("code", source: "print('after attachments')", id: "following")
        ])
        let web = try await render(source)
        let unavailable = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.image-failure')).map(element=>element.textContent)") as? [String]
        XCTAssertEqual(unavailable, ["Attachment unavailable: constructor", "Attachment unavailable: toString", "Attachment unavailable: __proto__"])
        let svgCount = try await web.evaluateJavaScript("document.querySelectorAll('.markdown svg').length") as? Int
        let followingSource = try await web.evaluateJavaScript("document.querySelector('.source').textContent") as? String
        XCTAssertEqual(svgCount, 1)
        XCTAssertEqual(followingSource, "print('after attachments')")
    }

    func testMIMESwitchRebuildsFindHighlightsWhenMatchPositionsStayTheSame() async throws {
        for alternate in ["saved result", "saved alternate"] {
            window?.contentView = nil; window?.close(); window = nil
            let source = try NotebookParsingTests.source(cells: [NotebookParsingTests.cell("code", source: "x", outputs: [
                ["output_type": "display_data", "data": ["text/html": "<pre>saved result</pre>", "text/plain": alternate], "metadata": [:]]])])
            let find = DocumentFindModel(); find.open(replace: false, query: "saved")
            find.update(text: source, target: .preview, anchor: 0, previewTextNodes: ["x", "saved result"])
            let web = try await render(source, matches: find.previewMatches, currentMatch: find.current)
            let highlightedText = "CSS.highlights?.get('notebook-current') ? Array.from(CSS.highlights.get('notebook-current')).map(range=>range.toString()).join('') : ''"
            for _ in 0..<100 {
                if (try await web.evaluateJavaScript(highlightedText)) as? String == "saved" { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let initialHighlight = try await web.evaluateJavaScript(highlightedText) as? String
            XCTAssertEqual(initialHighlight, "saved")
            _ = try await web.evaluateJavaScript("const picker=document.querySelector('.mime-picker select');picker.value='1';picker.dispatchEvent(new Event('change'))")
            for _ in 0..<100 {
                if (try await web.evaluateJavaScript(highlightedText)) as? String == "saved" { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let alternateHighlight = try await web.evaluateJavaScript(highlightedText) as? String
            let activeText = try await web.evaluateJavaScript("document.querySelector('.find-active')?.textContent") as? String
            XCTAssertEqual(alternateHighlight, "saved", alternate)
            XCTAssertEqual(activeText, alternate)
        }
    }

    /// Generated by the optional Python development environment; CI still covers the renderer above.
    func testPythonGeneratedSavedOutputNotebooks() async throws {
        guard let path = ProcessInfo.processInfo.environment["WOOLOO_NOTEBOOK_FIXTURES"] else {
            throw XCTSkip("Generate fixtures with scripts/notebook-fixtures.py and set WOOLOO_NOTEBOOK_FIXTURES")
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
        XCTAssertThrowsError(try resources.data(for: URL(string: "wooloo-notebook://first/image/bad")))
        let text = try XCTUnwrap(resources.registerImage("secret.txt"))
        XCTAssertThrowsError(try resources.data(for: URL(string: text)))
        resources.clear()
        XCTAssertThrowsError(try resources.data(for: URL(string: text)))
        XCTAssertThrowsError(try resources.data(for: URL(string: "wooloo-notebook://app/vendor/../sources.json")))
    }
}

/// Which notebook resources wait for a slot of the Space's machine: only image files of the
/// Space, read over SSH for a remote one. Requests go through the WebKit handler with a fake task,
/// and SSH through a fake `ssh` that logs its target and runs the command here.
@MainActor
final class NotebookResourceSlotTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var release: (() -> Void)?

    override func setUpWithError() throws {
        sandbox = try WorkspaceGitSandbox()
        try FileManager.default.createDirectory(atPath: sandbox.path("space"), withIntermediateDirectories: true)
        try Self.png().write(to: URL(fileURLWithPath: sandbox.path("space/plot.png")))
        try sandbox.write(["bin/ssh": """
            #!/bin/sh
            echo "$*" >> '\(sandbox.path("ssh.log"))'
            for command; do :; done
            exec /bin/sh -c "$command"
            """], in: ".")
        _ = try sandbox.sh("chmod 755 bin/ssh")
        WorkspaceFiles.sshExecutable = sandbox.path("bin/ssh")
    }

    override func tearDown() {
        release?()
        WorkspaceFiles.sshExecutable = "/usr/bin/ssh"
        sandbox.tearDown()
    }

    func testEncodedImagesDoNotWaitForASaturatedMachine() throws {
        let location = sshLocation("nb-encoded.test")
        let resources = NotebookResources()
        let png = try Self.png().base64EncodedString()
        resources.replace(images: ["saved": .init(base64: png, mime: "image/png")], location: location,
                          documentPath: "notebook.ipynb", revision: "one")
        try holdSlots(of: location)
        let dataURL = try XCTUnwrap(resources.registerImage("data:image/png;base64," + png))
        for url in ["wooloo-notebook://one/image/saved", dataURL] {
            let task = FakeSchemeTask(url, test: self)
            resources.webView(WKWebView(), start: task)
            wait(for: [task.finished], timeout: 10)
            XCTAssertEqual(task.mime, "image/png", url)
        }
        XCTAssertEqual(resources.pendingReads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("ssh.log")), "Nothing went over SSH")
    }

    /// A request stopped while it waits for a slot gives up its place and never reads.
    func testAStoppedRequestDoesNotReadOverSSH() throws {
        let location = sshLocation("nb-stopped.test")
        let resources = NotebookResources()
        resources.replace(images: [:], location: location, documentPath: "notebook.ipynb", revision: "one")
        try holdSlots(of: location)
        let task = FakeSchemeTask(try XCTUnwrap(resources.registerImage("plot.png")), test: self)
        task.finished.isInverted = true
        resources.webView(WKWebView(), start: task)
        let slots = BlockingWork.slots(for: BlockingWorkMachine(location.machine))
        XCTAssertTrue(spin { slots.waiting == 1 }, "The image file waits for a slot of the machine")
        XCTAssertEqual(resources.pendingReads, 1)
        resources.webView(WKWebView(), stop: task)
        XCTAssertTrue(spin { slots.waiting == 0 }, "The stopped request left the line")
        XCTAssertEqual(resources.pendingReads, 0)
        release?()
        wait(for: [task.finished], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path("ssh.log")), "The stopped request did not read")
    }

    /// A file read uses the location its request started with, under that machine's slot, even
    /// when another document opens while it waits.
    func testAFileReadKeepsTheLocationItStartedWith() throws {
        let first = sshLocation("nb-first.test")
        let resources = NotebookResources()
        resources.replace(images: [:], location: first, documentPath: "notebook.ipynb", revision: "one")
        try holdSlots(of: first)
        let task = FakeSchemeTask(try XCTUnwrap(resources.registerImage("plot.png")), test: self)
        resources.webView(WKWebView(), start: task)
        let slots = BlockingWork.slots(for: BlockingWorkMachine(first.machine))
        XCTAssertTrue(spin { slots.waiting == 1 })
        resources.replace(images: [:], location: sshLocation("nb-second.test"), documentPath: "other.ipynb", revision: "two")
        release?()
        wait(for: [task.finished], timeout: 10)
        let log = try String(contentsOfFile: sandbox.path("ssh.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("nb-first.test"), log)
        XCTAssertFalse(log.contains("nb-second.test"), log)
        XCTAssertNotNil(task.error, "An image of a replaced document is not served")
    }

    func testAFileImageOfTheSpaceIsServed() throws {
        let location = sshLocation("nb-served.test")
        let resources = NotebookResources()
        resources.replace(images: [:], location: location, documentPath: "notebook.ipynb", revision: "one")
        let task = FakeSchemeTask(try XCTUnwrap(resources.registerImage("plot.png")), test: self)
        resources.webView(WKWebView(), start: task)
        wait(for: [task.finished], timeout: 10)
        XCTAssertEqual(task.mime, "image/png")
        XCTAssertEqual(task.data, try Self.png())
        XCTAssertEqual(resources.pendingReads, 0)
    }

    private func sshLocation(_ target: String) -> WorkspaceFileLocation {
        let machine = HerdrMachineProfile(id: target, label: target, target: target, session: "default", enabled: true)
        return WorkspaceFileLocation(machine: machine, session: "default", workspaceID: "space",
                                     workspaceLabel: "space", root: sandbox.path("space"))
    }

    /// Holds every slot of the location's machine until `release`.
    private func holdSlots(of location: WorkspaceFileLocation) throws {
        let machine = BlockingWorkMachine(location.machine)
        let gate = DispatchSemaphore(value: 0)
        let started = Locked(0)
        for _ in 0..<BlockingWork.machineLimit {
            Task.detached {
                try? await BlockingWork.run(reaching: machine) { () throws in
                    started.withLock { $0 += 1 }
                    gate.wait()
                }
            }
        }
        var released = false
        release = {
            guard !released else { return }
            released = true
            for _ in 0..<BlockingWork.machineLimit { gate.signal() }
        }
        XCTAssertTrue(spin { started.value == BlockingWork.machineLimit }, "Every slot of the machine is held")
    }

    private func spin(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private static func png() throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}

private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    let finished: XCTestExpectation
    private(set) var mime: String?
    private(set) var data = Data()
    private(set) var error: Error?

    init(_ url: String, test: XCTestCase) {
        request = URLRequest(url: URL(string: url)!)
        finished = test.expectation(description: "\(url.prefix(60)) finished")
    }

    func didReceive(_ response: URLResponse) { mime = response.mimeType }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished.fulfill() }
    func didFailWithError(_ error: Error) {
        self.error = error
        finished.fulfill()
    }
}

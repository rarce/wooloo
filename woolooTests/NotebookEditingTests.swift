import XCTest
import SwiftUI
import WebKit
@testable import wooloo

@MainActor
final class NotebookEditingTests: XCTestCase {
    private typealias F = NotebookEditingFixtures

    private func apply(_ edit: NotebookEdit, to text: String = F.original) throws -> String {
        let replacement = try XCTUnwrap(NotebookEditing.replacement(for: edit, in: text, makeID: { "abcd1234" }))
        return (text as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
    }

    /// Each edit of a file Jupyter wrote gives what Jupyter writes after the same change, so a
    /// notebook edited here and saved by Jupyter later shows no other difference.
    func testEditsMatchWhatJupyterWritesAfterTheSameChange() throws {
        XCTAssertEqual(try apply(.setSource(cell: 1, text: "y = \"3\"\tok\nprint(y)\n")), F.source)
        XCTAssertEqual(try apply(.setSource(cell: 0, text: "")), F.emptySource)
        XCTAssertEqual(try apply(.setSource(cell: 2, text: "new raw\nline")), F.stringSource)
        XCTAssertEqual(try apply(.setKind(cell: 1, kind: "markdown")), F.codeToMarkdown)
        XCTAssertEqual(try apply(.setKind(cell: 2, kind: "code")), F.rawToCode)
        XCTAssertEqual(try apply(.insert(at: 1, kind: "code")), F.insertMiddle)
        XCTAssertEqual(try apply(.insert(at: 0, kind: "code")), F.insertFirst)
        XCTAssertEqual(try apply(.insert(at: 3, kind: "markdown")), F.insertLast)
        XCTAssertEqual(try apply(.insert(at: 0, kind: "code"), to: F.empty), F.insertIntoEmpty)
        XCTAssertEqual(try apply(.delete(cell: 0)), F.deleteFirst)
        XCTAssertEqual(try apply(.delete(cell: 2)), F.deleteLast)
        XCTAssertEqual(try apply(.delete(cell: 0), to: F.single), F.empty)
        XCTAssertEqual(try apply(.move(cell: 1, offset: 1)), F.moveDown)
        XCTAssertEqual(try apply(.move(cell: 2, offset: -1)), F.moveDown)
    }

    func testEditsChangeOnlyTheirOwnBytesAndUndoToTheOriginal() throws {
        let edited = try apply(.setSource(cell: 1, text: "changed"))
        let replacement = try XCTUnwrap(NotebookEditing.replacement(for: .setSource(cell: 1, text: "changed"), in: F.original))
        let original = F.original as NSString
        XCTAssertTrue(edited.hasPrefix(original.substring(to: replacement.range.location)))
        XCTAssertTrue(edited.hasSuffix(original.substring(from: NSMaxRange(replacement.range))))
        XCTAssertEqual(try apply(.setSource(cell: 1, text: "x = 2\nprint(x * 2)"), to: edited), F.original)
        XCTAssertEqual(try apply(.setKind(cell: 1, kind: "code"), to: F.codeToMarkdown).contains("\"outputs\": []"), true)
        XCTAssertEqual(try apply(.move(cell: 2, offset: -1), to: F.moveDown), F.original)
    }

    func testEditsThatChangeNothingOrCannotApplyAreRefused() throws {
        XCTAssertNil(try NotebookEditing.replacement(for: .setSource(cell: 1, text: "x = 2\nprint(x * 2)"), in: F.original))
        XCTAssertNil(try NotebookEditing.replacement(for: .setKind(cell: 1, kind: "code"), in: F.original))
        XCTAssertNil(try NotebookEditing.replacement(for: .move(cell: 0, offset: -1), in: F.original))
        XCTAssertNil(try NotebookEditing.replacement(for: .move(cell: 2, offset: 1), in: F.original))
        XCTAssertThrowsError(try NotebookEditing.replacement(for: .delete(cell: 3), in: F.original))
        XCTAssertThrowsError(try NotebookEditing.replacement(for: .setKind(cell: 0, kind: "plot"), in: F.original))
        XCTAssertThrowsError(try NotebookEditing.replacement(for: .insert(at: 5, kind: "code"), in: F.original))
        XCTAssertThrowsError(try NotebookEditing.replacement(for: .setSource(cell: 0, text: "x"), in: "{\"cells\": [}"))
        // A code cell cannot keep attachments, and they are never dropped silently.
        XCTAssertThrowsError(try NotebookEditing.replacement(for: .setKind(cell: 0, kind: "code"), in: F.original)) {
            XCTAssertTrue($0.localizedDescription.contains("attachments"))
        }
    }

    func testMinifiedNotebooksStayMinifiedAndCellsWithoutIDsGetNone() throws {
        let text = #"{"cells":[{"cell_type":"code","execution_count":1,"metadata":{},"outputs":[],"source":"a"}],"metadata":{},"nbformat":4,"nbformat_minor":4}"#
        let inserted = try apply(.insert(at: 1, kind: "markdown"), to: text)
        XCTAssertEqual(inserted, #"{"cells":[{"cell_type":"code","execution_count":1,"metadata":{},"outputs":[],"source":"a"},{"cell_type":"markdown","metadata":{},"source":[]}],"metadata":{},"nbformat":4,"nbformat_minor":4}"#)
        let source = try apply(.setSource(cell: 1, text: "one\ntwo"), to: inserted)
        XCTAssertTrue(source.contains(#""source":["one\n","two"]}"#))
        let markdown = try apply(.setKind(cell: 0, kind: "markdown"), to: text)
        XCTAssertEqual(markdown, #"{"cells":[{"cell_type":"markdown","metadata":{},"source":"a"}],"metadata":{},"nbformat":4,"nbformat_minor":4}"#)
    }

    func testNotebooksWithWindowsLineEndingsKeepThem() throws {
        let crlf = F.original.replacingOccurrences(of: "\n", with: "\r\n")
        for edit in [NotebookEdit.setSource(cell: 1, text: "a\nb"), .insert(at: 1, kind: "code"), .insert(at: 3, kind: "markdown"),
                     .setKind(cell: 2, kind: "code"), .delete(cell: 1)] {
            let edited = try apply(edit, to: crlf)
            XCTAssertEqual(edited.replacingOccurrences(of: "\r\n", with: "\n"), try apply(edit), "\(edit)")
            XCTAssertFalse(edited.components(separatedBy: "\r\n").joined().contains("\n"), "\(edit) wrote a bare line feed")
        }
        XCTAssertEqual(try apply(.insert(at: 0, kind: "code"), to: F.empty.replacingOccurrences(of: "\n", with: "\r\n")),
                       F.insertIntoEmpty.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testSourcesRoundTripThroughJSONWithControlCharactersAndEmoji() throws {
        let tricky = "quote \" backslash \\ tab\t\u{01}\u{1F}\u{7F} é 👩‍👩‍👧 \u{2028}\r\nnext\rlast"
        let edited = try apply(.setSource(cell: 2, text: tricky))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any])
        let cells = try XCTUnwrap(root["cells"] as? [[String: Any]])
        XCTAssertEqual(cells[2]["source"] as? String, tricky)
        let array = try apply(.setSource(cell: 1, text: tricky))
        let arrayCells = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(array.utf8)) as? [String: Any])?["cells"] as? [[String: Any]])
        XCTAssertEqual((arrayCells[1]["source"] as? [String])?.joined(), tricky)
        // The other cells, attachments and outputs are unchanged.
        let original = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(F.original.utf8)) as? [String: Any])?["cells"] as? [[String: Any]])
        XCTAssertEqual(NSDictionary(dictionary: arrayCells[0]), NSDictionary(dictionary: original[0]))
        XCTAssertEqual(arrayCells[1]["outputs"] as? NSArray, original[1]["outputs"] as? NSArray)
    }

    func testNewCellIDsAreUniqueInTheNotebook() throws {
        var ids = ["calc", "fresh"]
        let replacement = try XCTUnwrap(NotebookEditing.replacement(for: .insert(at: 0, kind: "raw"), in: F.original,
                                                                     makeID: { ids.removeFirst() }))
        XCTAssertTrue(replacement.text.contains(#""id": "fresh""#))
        XCTAssertEqual(NotebookEditing.randomID().count, 8)
    }

    // MARK: Messages from the page

    func testMessagesApplyOnlyToTheCellThePageShowed() throws {
        let notebook = try NotebookDocument.parse(F.original)
        typealias C = NotebookWebView.Coordinator
        XCTAssertEqual(C.edit(["op": "source", "cell": 1, "id": "calc", "text": "y"], in: notebook), .setSource(cell: 1, text: "y"))
        XCTAssertNil(C.edit(["op": "source", "cell": 1, "id": "intro", "text": "y"], in: notebook))
        XCTAssertNil(C.edit(["op": "source", "cell": 7, "id": "calc", "text": "y"], in: notebook))
        XCTAssertEqual(C.edit(["op": "kind", "cell": 0, "id": "intro", "value": "raw"], in: notebook), .setKind(cell: 0, kind: "raw"))
        XCTAssertNil(C.edit(["op": "kind", "cell": 0, "id": "intro", "value": "html"], in: notebook))
        XCTAssertEqual(C.edit(["op": "move", "cell": 2, "id": "tail", "offset": -1], in: notebook), .move(cell: 2, offset: -1))
        XCTAssertNil(C.edit(["op": "move", "cell": 2, "id": "tail", "offset": 2], in: notebook))
        XCTAssertEqual(C.edit(["op": "insert", "cell": 2, "id": "tail", "value": "code"], in: notebook), .insert(at: 3, kind: "code"))
        XCTAssertNil(C.edit(["op": "insert", "cell": -1, "value": "code"], in: notebook))
        XCTAssertEqual(C.edit(["op": "delete", "cell": 0, "id": "intro"], in: notebook), .delete(cell: 0))
        let empty = try NotebookDocument.parse(F.empty)
        XCTAssertEqual(C.edit(["op": "insert", "cell": -1, "value": "markdown"], in: empty), .insert(at: 0, kind: "markdown"))
        // A source the preview truncated is not editable there.
        let long = try NotebookParsingTests.source(cells: [NotebookParsingTests.cell(
            "code", source: String(repeating: "x", count: NotebookDocument.maximumTextCharacters + 1), id: "long")])
        let truncated = try NotebookDocument.parse(long)
        XCTAssertFalse(truncated.cells[0].editable)
        XCTAssertNil(C.edit(["op": "source", "cell": 0, "id": "long", "text": "y"], in: truncated))
        XCTAssertEqual(truncated.sourceText, long)
    }

    // MARK: Undo

    func testUndoAndRedoRestoreTextOnlyWhileTheDocumentStillHasIt() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        var text = "[a, after, z]", revision = 1
        let replace: (Int, NSRange, String) -> Int? = { expected, range, new in
            guard revision == expected else { return nil }
            text = (text as NSString).replacingCharacters(in: range, with: new)
            revision += 1
            return revision
        }
        manager.beginUndoGrouping()
        NotebookUndo.register(manager, revision: 1, range: NSRange(location: 4, length: 5), current: "after", previous: "before",
                              name: "Edit Cell", replace: replace)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Edit Cell")
        manager.undo()
        XCTAssertEqual(text, "[a, before, z]")
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(text, "[a, after, z]")
        // Changed some other way since, even where the step's range is empty: undo leaves it alone.
        text = "[b, a, after, z]"; revision += 1
        manager.undo()
        XCTAssertEqual(text, "[b, a, after, z]")
    }

    func testTheStoreUndoesOnlyWhileTheTextIsUnchanged() {
        let store = WorkspaceDocumentStore()
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "test",
                                             workspaceLabel: "Notebook test", root: "/private/tmp")
        var document = WorkspaceDocument(location: location, path: "n.ipynb", kind: .file)
        document.text = "[a, after]"
        store.documents = [document]
        let id = document.id, revision = document.textRevision
        XCTAssertNil(store.replaceText(id, in: NSRange(location: 4, length: 5), with: "before", ifRevision: revision + 1))
        XCTAssertNil(store.replaceText(id, in: NSRange(location: 8, length: 5), with: "before", ifRevision: revision))
        XCTAssertNil(store.replaceText("missing", in: NSRange(location: 4, length: 5), with: "before", ifRevision: revision))
        XCTAssertEqual(store.document(id)?.text, "[a, after]")
        let next = store.replaceText(id, in: NSRange(location: 4, length: 5), with: "before", ifRevision: revision)
        XCTAssertEqual(store.document(id)?.text, "[a, before]")
        XCTAssertEqual(next, store.document(id)?.textRevision)
        XCTAssertNotEqual(next, revision)
        // An empty range is no exception.
        XCTAssertNil(store.replaceText(id, in: NSRange(location: 1, length: 0), with: "x, ", ifRevision: revision))
    }

    func testOutcomesCarryTheNewTextOrTheFailure() throws {
        let outcome = try XCTUnwrap(NotebookEditing.outcome(for: .delete(cell: 0), in: F.original).get())
        XCTAssertEqual(outcome.text, F.deleteFirst)
        XCTAssertNil(try NotebookEditing.outcome(for: .move(cell: 0, offset: -1), in: F.original).get())
        XCTAssertThrowsError(try NotebookEditing.outcome(for: .delete(cell: 9), in: F.original).get())
    }

    // MARK: WebKit

    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    func testTheCellToolbarAndEditorSendEdits() async throws {
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "test",
                                             workspaceLabel: "Notebook test", root: "/private/tmp")
        // Cell 1's first line ends in "\r\n", which a textarea shows as "\n".
        let text = F.original.replacingOccurrences(of: #""x = 2\n""#, with: #""x = 2\r\n""#)
        let model = try NotebookDocument.parse(text)
        var edits: [(NotebookEdit, String)] = []
        var commands: [String] = []
        let view = NotebookWebView(notebook: model, path: "edit.ipynb", location: location,
                                   theme: WoolooTheme.all[0], typography: WoolooTypography(), matches: [],
                                   currentMatch: nil, revealRequest: 0, onOpenFile: { _ in },
                                   onSearchText: { _ in }, onFindCommand: { key, shift, _ in commands.append(key + (shift ? "+shift" : "")) },
                                   onEdit: { edit, base, _ in edits.append((edit, base)); return false })
        let host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false
        window?.contentView = host
        window?.makeKeyAndOrderFront(nil)
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        var web: WKWebView?
        for _ in 0..<200 {
            if let found = findWebView(host),
               (try? await found.evaluateJavaScript("document.querySelectorAll('.cell-tools').length")) as? Int == 3 {
                web = found
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let page = try XCTUnwrap(web)
        func waitForEdits(_ count: Int) async throws {
            for _ in 0..<100 where edits.count < count { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(edits.count, count)
        }
        /// Marks the page; the mark is gone once the page renders again.
        let mark = "document.querySelector('header').dataset.stale = '1';"
        func rendered() async throws -> Bool {
            for _ in 0..<100 {
                if try await page.evaluateJavaScript("document.querySelector('header').dataset.stale === undefined") as? Bool == true { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        _ = try await page.evaluateJavaScript(mark + "document.querySelectorAll('.cell')[2].querySelector('[aria-label=\"Delete the cell\"]').click()")
        try await waitForEdits(1)
        let restoredDelete = try await rendered()
        XCTAssertTrue(restoredDelete)
        XCTAssertEqual(edits.last?.0, .delete(cell: 2))
        XCTAssertEqual(edits.last?.1, text)
        let disabled = try await page.evaluateJavaScript("document.querySelectorAll('.cell')[0].querySelector('[aria-label=\"Move the cell up\"]').disabled") as? Bool
        XCTAssertEqual(disabled, true)
        _ = try await page.evaluateJavaScript(mark + """
            { const select = document.querySelectorAll('.cell')[1].querySelector('select[aria-label="Cell type"]');
              select.value = 'raw'; select.dispatchEvent(new Event('change')); }
            """)
        try await waitForEdits(2)
        XCTAssertEqual(edits.last?.0, .setKind(cell: 1, kind: "raw"))
        // An edit the app does not make renders the page again as it was.
        let restoredKind = try await rendered()
        XCTAssertTrue(restoredKind)
        let kind = try await page.evaluateJavaScript("document.querySelectorAll('.cell')[1].querySelector('select[aria-label=\"Cell type\"]').value") as? String
        XCTAssertEqual(kind, "code")
        // Editing a source: the editor shows the whole source, Escape cancels, ⌘↩ applies.
        _ = try await page.evaluateJavaScript("document.querySelectorAll('.cell')[1].querySelector('[aria-label=\"Edit the cell\\'s source\"]').click()")
        let shown = try await page.evaluateJavaScript("document.querySelector('textarea.cell-editor').value") as? String
        XCTAssertEqual(shown, "x = 2\nprint(x * 2)")
        _ = try await page.evaluateJavaScript("""
            document.querySelector('textarea.cell-editor')
                .dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
            """)
        let cancelled = try await page.evaluateJavaScript("document.querySelector('textarea.cell-editor') === null && !document.querySelectorAll('.cell')[1].querySelector('.source').hidden") as? Bool
        XCTAssertEqual(cancelled, true)
        // Applying an unchanged source sends nothing, though the textarea changed its line breaks.
        _ = try await page.evaluateJavaScript("""
            document.querySelectorAll('.cell')[1].querySelector('[aria-label="Edit the cell\\'s source"]').click();
            document.querySelector('textarea.cell-editor')
                .dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true}));
            """)
        XCTAssertEqual(edits.count, 2)
        _ = try await page.evaluateJavaScript(mark + """
            document.querySelectorAll('.cell')[1].querySelector('[aria-label="Edit the cell\\'s source"]').click();
            { const editor = document.querySelector('textarea.cell-editor');
              editor.value = 'print(3)\\nprint(4)';
              editor.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true})); }
            """)
        try await waitForEdits(3)
        XCTAssertEqual(edits.last?.0, .setSource(cell: 1, text: "print(3)\r\nprint(4)"))
        let restoredSource = try await rendered()
        XCTAssertTrue(restoredSource)
        let editorClosed = try await page.evaluateJavaScript("document.querySelector('textarea.cell-editor') === null") as? Bool
        XCTAssertEqual(editorClosed, true)
        // ⌘Z outside a text field goes to the app's undo.
        _ = try await page.evaluateJavaScript("document.querySelector('.cell').dispatchEvent(new KeyboardEvent('keydown', {key: 'z', metaKey: true, shiftKey: true, bubbles: true}))")
        for _ in 0..<100 where commands.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(commands, ["z+shift"])
        // Edits sent together are applied one at a time, in the order sent.
        _ = try await page.evaluateJavaScript("""
            { const cells = document.querySelectorAll('.cell');
              cells[2].querySelector('[aria-label="Delete the cell"]').click();
              cells[0].querySelector('[aria-label="Move the cell down"]').click(); }
            """)
        try await waitForEdits(5)
        XCTAssertEqual(edits.suffix(2).map(\.0), [.delete(cell: 2), .move(cell: 0, offset: 1)])
    }

    func testAReadOnlyPreviewHasNoCellToolbar() async throws {
        let location = WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "test",
                                             workspaceLabel: "Notebook test", root: "/private/tmp")
        let model = try NotebookDocument.parse(F.original)
        let view = NotebookWebView(notebook: model, path: "edit.ipynb", location: location,
                                   theme: WoolooTheme.all[0], typography: WoolooTypography(), matches: [],
                                   currentMatch: nil, revealRequest: 0, onOpenFile: { _ in },
                                   onSearchText: { _ in }, onFindCommand: { _, _, _ in })
        let host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false
        window?.contentView = host
        window?.makeKeyAndOrderFront(nil)
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        var tools: Int?
        for _ in 0..<200 {
            if let found = findWebView(host),
               (try? await found.evaluateJavaScript("document.querySelectorAll('.cell').length")) as? Int == 3 {
                tools = try await found.evaluateJavaScript("document.querySelectorAll('.cell-tools').length") as? Int
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(tools, 0)
    }
}

final class NotebookDiffTests: XCTestCase {
    private func notebook(_ cells: [[String: Any]], minor: Int = 5, metadata: [String: Any] = [:]) throws -> String {
        try NotebookParsingTests.source(cells: cells, minor: minor, metadata: metadata)
    }

    private func cell(_ kind: String, _ source: String, id: String? = nil, outputs: [[String: Any]] = [],
                      count: Any = NSNull(), metadata: [String: Any] = [:]) -> [String: Any] {
        var cell: [String: Any] = ["cell_type": kind, "source": source, "metadata": metadata]
        if let id { cell["id"] = id }
        if kind == "code" { cell["outputs"] = outputs; cell["execution_count"] = count }
        return cell
    }

    func testCellsMatchByIDThroughMovesEditsAdditionsAndRemovals() throws {
        let old = try notebook([cell("markdown", "# Title", id: "a"), cell("code", "x = 1\ny = 2", id: "b"),
                                cell("code", "gone()", id: "c"), cell("raw", "end", id: "d")])
        let new = try notebook([cell("markdown", "# Title", id: "a"), cell("code", "x = 1\ny = 3", id: "b"),
                                cell("raw", "end", id: "d"), cell("code", "added()", id: "e")])
        let diff = try XCTUnwrap(NotebookDiff.compare(old: old, new: new))
        XCTAssertEqual(diff.cells.map(\.status), [.unchanged, .modified, .removed, .unchanged, .added])
        XCTAssertEqual(diff.cells[1].aspects, [.source])
        XCTAssertEqual(diff.cells[1].source, [.init(kind: .context, text: "x = 1"), .init(kind: .removed, text: "y = 2"),
                                              .init(kind: .added, text: "y = 3")])
        XCTAssertEqual(diff.cells[2].source, [.init(kind: .removed, text: "gone()")])
        XCTAssertEqual(diff.cells[3].oldIndex, 3)
        XCTAssertEqual(diff.cells[3].newIndex, 2)
        XCTAssertEqual(diff.changedCount, 3)
        XCTAssertFalse(diff.metadataChanged)
    }

    func testCellsWithoutIDsMatchByContentAndPairEditsInPlace() throws {
        let old = try notebook([cell("markdown", "intro"), cell("code", "a()"), cell("code", "b()")], minor: 4)
        let new = try notebook([cell("markdown", "intro"), cell("code", "a2()"), cell("code", "b()")], minor: 4)
        let diff = try XCTUnwrap(NotebookDiff.compare(old: old, new: new))
        XCTAssertEqual(diff.cells.map(\.status), [.unchanged, .modified, .unchanged])
        XCTAssertEqual(diff.cells[1].oldIndex, 1)
        XCTAssertEqual(diff.cells[1].newIndex, 1)
        // A cell replaced by one of another type is a removal and an addition.
        let retyped = try notebook([cell("markdown", "intro"), cell("raw", "a2()"), cell("code", "b()")], minor: 4)
        XCTAssertEqual(NotebookDiff.compare(old: old, new: retyped)?.cells.map(\.status), [.unchanged, .removed, .added, .unchanged])
        // An edited cell after a cell of another type inserted before it is still an edit.
        let inserted = try notebook([cell("markdown", "intro"), cell("markdown", "note"), cell("code", "a2()"), cell("code", "b()")], minor: 4)
        let paired = try XCTUnwrap(NotebookDiff.compare(old: old, new: inserted))
        XCTAssertEqual(paired.cells.map(\.status), [.unchanged, .added, .modified, .unchanged])
        XCTAssertEqual(paired.cells.map(\.newIndex), [0, 1, 2, 3])
        XCTAssertEqual(paired.cells[2].oldIndex, 1)
    }

    func testOutputsMetadataAndCountsAreReportedWithImagesSummarized() throws {
        let plot = ["output_type": "display_data", "metadata": [:], "data": ["image/png": "iVBORw0KGgoAAAA", "text/plain": "<Figure>"]] as [String: Any]
        var newPlot = plot
        newPlot["data"] = ["image/png": "iVBORw0KGgoBBBB", "text/plain": "<Figure>"]
        let old = try notebook([cell("code", "plot()", id: "p", outputs: [plot], count: 1)], metadata: ["kernelspec": ["name": "python3"]])
        let new = try notebook([cell("code", "plot()", id: "p", outputs: [newPlot], count: 2, metadata: ["tags": ["x"]])],
                               metadata: ["kernelspec": ["name": "julia"]])
        let diff = try XCTUnwrap(NotebookDiff.compare(old: old, new: new))
        XCTAssertEqual(diff.cells[0].status, .modified)
        XCTAssertEqual(diff.cells[0].aspects, [.outputs, .executionCount, .metadata])
        XCTAssertTrue(diff.metadataChanged)
        let removed = diff.cells[0].outputs.filter { $0.kind == .removed }.map(\.text)
        let added = diff.cells[0].outputs.filter { $0.kind == .added }.map(\.text)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(removed[0].hasPrefix("image/png: "))
        XCTAssertTrue(added[0].contains("checksum"))
        XCTAssertNotEqual(removed[0], added[0])
        XCTAssertFalse(added[0].contains("BBBB"))
        XCTAssertTrue(diff.cells[0].outputs.contains(.init(kind: .context, text: "<Figure>")))
    }

    func testAddedAndDeletedNotebooksAndUnreadableSides() throws {
        let one = try notebook([cell("code", "a()", id: "a")])
        XCTAssertEqual(NotebookDiff.compare(old: nil, new: one)?.cells.map(\.status), [.added])
        XCTAssertEqual(NotebookDiff.compare(old: one, new: nil)?.cells.map(\.status), [.removed])
        XCTAssertEqual(NotebookDiff.compare(old: nil, new: one)?.metadataChanged, false)
        // A side the patch shows as a file is unreadable when missing, not empty.
        let added = "diff --git a/n.ipynb b/n.ipynb\nnew file mode 100644\n--- /dev/null\n+++ b/n.ipynb\n@@ -0,0 +1 @@\n+{}\n"
        let deleted = "diff --git a/n.ipynb b/n.ipynb\ndeleted file mode 100644\n--- a/n.ipynb\n+++ /dev/null\n@@ -1 +0,0 @@\n-{}\n"
        let modified = "diff --git a/n.ipynb b/n.ipynb\n--- a/n.ipynb\n+++ b/n.ipynb\n@@ -1 +1 @@\n-{}\n+{ }\n"
        XCTAssertEqual(NotebookDiff.compare(old: nil, new: one, patch: added)?.cells.map(\.status), [.added])
        XCTAssertEqual(NotebookDiff.compare(old: one, new: nil, patch: deleted)?.cells.map(\.status), [.removed])
        XCTAssertNil(NotebookDiff.compare(old: nil, new: one, patch: modified))
        XCTAssertNil(NotebookDiff.compare(old: one, new: nil, patch: modified))
        XCTAssertEqual(NotebookDiff.compare(old: one, new: one, patch: modified)?.changedCount, 0)
        XCTAssertNil(NotebookDiff.compare(old: one, new: "{ not json"))
        XCTAssertNil(NotebookDiff.compare(old: nil, new: nil))
        XCTAssertEqual(NotebookDiff.compare(old: one, new: one)?.changedCount, 0)
    }

    func testLineDiffKeepsOrder() {
        XCTAssertEqual(NotebookDiff.lineDiff(["a", "b", "c"], ["a", "x", "c", "d"]).map { "\($0.kind)\($0.text)" },
                       ["contexta", "removedb", "addedx", "contextc", "addedd"])
        XCTAssertEqual(NotebookDiff.lines("a\r\nb\n"), ["a", "b"])
        XCTAssertEqual(NotebookDiff.lines(""), [])
    }
}

// Generated with Python's json.dumps(indent=1, sort_keys=True, ensure_ascii=False), as Jupyter saves notebooks.
enum NotebookEditingFixtures {
    static let original = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let source = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "y = \"3\"\tok\n",
    "print(y)\n"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let emptySource = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": []
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let stringSource = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "new raw\nline"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let codeToMarkdown = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "markdown",
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let rawToCode = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "tail",
   "metadata": {},
   "outputs": [],
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let insertMiddle = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "abcd1234",
   "metadata": {},
   "outputs": [],
   "source": []
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let insertFirst = #"""
{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "abcd1234",
   "metadata": {},
   "outputs": [],
   "source": []
  },
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let insertLast = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  },
  {
   "cell_type": "markdown",
   "id": "abcd1234",
   "metadata": {},
   "source": []
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let deleteFirst = #"""
{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let deleteLast = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let moveDown = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  },
  {
   "cell_type": "raw",
   "id": "tail",
   "metadata": {},
   "source": "raw text"
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "calc",
   "metadata": {
    "collapsed": false
   },
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "4\n"
     ]
    }
   ],
   "source": [
    "x = 2\n",
    "print(x * 2)"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let empty = #"""
{
 "cells": [],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let insertIntoEmpty = #"""
{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "abcd1234",
   "metadata": {},
   "outputs": [],
   "source": []
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
    static let single = #"""
{
 "cells": [
  {
   "attachments": {
    "plot.png": {
     "image/png": "iVBORw0KGgo="
    }
   },
   "cell_type": "markdown",
   "id": "intro",
   "metadata": {
    "tags": [
     "title"
    ]
   },
   "source": [
    "# Título 🚀\n",
    "Some *text*"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}

"""#
}

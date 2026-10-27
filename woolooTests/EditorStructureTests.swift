import XCTest
import SwiftUI
import Vision
import CodeEditSourceEditor
import CodeEditLanguages
@testable import wooloo

final class EditorStructureTests: XCTestCase {
    func testMarkdownSectionsHierarchyUnicodeAndEOF() {
        let source = "# 😀 Guide\nintro\n## Install\nsteps\n### macOS\ntext\n## Usage\nend\n# Other\nlast"
        let symbols = EditorStructure.markdown(source)
        XCTAssertEqual(symbols.map(\.name), ["😀 Guide", "Other"])
        XCTAssertEqual(symbols[0].children.map(\.name), ["Install", "Usage"])
        let offset = (source as NSString).range(of: "text").location
        XCTAssertEqual(EditorStructure.chain(at: offset, in: symbols, documentLength: source.utf16.count).map(\.name),
                       ["😀 Guide", "Install", "macOS"])
        XCTAssertEqual(NSMaxRange(symbols[0].range), (source as NSString).range(of: "# Other").location)
        XCTAssertEqual(EditorStructure.chain(at: source.utf16.count, in: symbols, documentLength: source.utf16.count).map(\.name), ["Other"])
        XCTAssertEqual((source as NSString).substring(with: symbols[0].children[0].selectionRange), "## Install")
    }

    func testMarkdownSetextFencesAndContainerCodeDoNotInventSections() {
        let source = """
        Document
        ========
        intro

          ```markdown
        # fenced
          ```
         ~~~~
        Hidden
        ------
         ~~~~
        > # Quote
        > quoted
        -------
            # Indented
        \t# Tab code
        - list item
        -------
        ***
        -------
        <pre>
        # Literal HTML
        </pre>
        ## Real ##
        body

        Ending
        ------
        EOF
        """
        let symbols = EditorStructure.markdown(source)
        XCTAssertEqual(symbols.map(\.name), ["Document"])
        XCTAssertEqual(symbols[0].children.map(\.name), ["Real", "Ending"])
        XCTAssertEqual(EditorStructure.chain(at: source.utf16.count, in: symbols, documentLength: source.utf16.count).map(\.name), ["Document", "Ending"])
        XCTAssertTrue(EditorStructure.markdown("").isEmpty)
    }

    @MainActor
    func testMarkdownModelDiscardsObsoleteVersionsAndLanguageChanges() async throws {
        let model = EditorStructureModel()
        model.update(source: "# Old", languageID: "markdown")
        model.update(source: "# New😀\n## Child", languageID: "markdown")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.symbols.map(\.name), ["New😀"])
        model.update(source: "# Not markdown", languageID: "plaintext")
        XCTAssertTrue(model.symbols.isEmpty)
        XCTAssertFalse(model.isIndexing)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.symbols.isEmpty)
    }

    @MainActor
    func testCodeGrammarsProduceNestedDeclarationsWithUTF16Selections() async throws {
        let fixtures: [(String, String, String, String)] = [
            ("swift", "// 😀\nstruct Café {\n func greet() {\n func nested() {}\n }\n}\n", "Café", "greet"),
            ("python", "# 😀\nclass Café:\n    def greet(self):\n        def nested():\n            pass\n", "Café", "greet"),
            ("javascript", "// 😀\nclass Café { greet() { function nested() {} } }\n", "Café", "greet"),
            ("typescript", "// 😀\nclass Café { greet(): void { function nested() {} } }\n", "Café", "greet"),
            ("jsx", "// 😀\nclass Café { greet() { return <div/>; } }\n", "Café", "greet"),
            ("tsx", "// 😀\nclass Café { greet(): any { return <div/>; } }\n", "Café", "greet")
        ]
        for (id, text, typeName, methodName) in fixtures {
            let fixture = try await makeEditor(text, languageID: id)
            defer { fixture.window.close() }
            let symbols = try await query(fixture.spy.controller!, source: text, languageID: id)
            XCTAssertEqual(symbols.map(\.name), [typeName], id)
            let type = try XCTUnwrap(symbols.first, id)
            XCTAssertEqual(type.children.first?.name, methodName, id)
            XCTAssertEqual((text as NSString).substring(with: type.selectionRange), typeName, id)
            let offset = (text as NSString).range(of: "greet").location
            XCTAssertEqual(EditorStructure.chain(at: offset, in: symbols, documentLength: text.utf16.count).map(\.name), [typeName, methodName], id)
            if ["swift", "python", "javascript", "typescript"].contains(id) {
                XCTAssertEqual(type.children.first?.children.map(\.name), ["nested"], id)
            }
        }
    }

    @MainActor
    func testSwiftInitializersHaveKeywordSelectionsAndModifiersRemainInRange() async throws {
        let source = "class Example { public init(value: Int) {} deinit {} }"
        let fixture = try await makeEditor(source, languageID: "swift")
        defer { fixture.window.close() }
        let symbols = try await query(fixture.spy.controller!, source: source, languageID: "swift")
        let members = try XCTUnwrap(symbols.first).children
        XCTAssertEqual(members.map(\.name), ["init", "deinit"])
        XCTAssertEqual(members.map { (source as NSString).substring(with: $0.selectionRange) }, ["init", "deinit"])
    }

    @MainActor
    func testSameLengthEditIncompleteSourceAndChangedLanguage() async throws {
        let text = "class First { method() {} }"
        let fixture = try await makeEditor(text, languageID: "typescript")
        defer { fixture.window.close() }
        let controller = try XCTUnwrap(fixture.spy.controller)
        let initial = try await query(controller, source: text, languageID: "typescript")
        XCTAssertEqual(initial.first?.name, "First")
        controller.textView.insertText("Other", replacementRange: (text as NSString).range(of: "First"))
        try await Task.sleep(for: .milliseconds(120))
        let changed = controller.textView.string
        let updated = try await query(controller, source: changed, languageID: "typescript")
        XCTAssertEqual(updated.first?.name, "Other")
        controller.textView.insertText("", replacementRange: NSRange(location: changed.utf16.count - 1, length: 1))
        try await Task.sleep(for: .milliseconds(120))
        let afterDeletion = controller.textView.string
        let recovered = try await query(controller, source: afterDeletion, languageID: "typescript")
        XCTAssertFalse(recovered.isEmpty)
        let incomplete = "class Other { method() {}"
        let unfinished = try await makeEditor(incomplete, languageID: "typescript")
        defer { unfinished.window.close() }
        let unfinishedController = try XCTUnwrap(unfinished.spy.controller)
        let symbols = try await query(unfinishedController, source: incomplete, languageID: "typescript")
        XCTAssertFalse(symbols.isEmpty, "The grammar should recover useful declarations in an unfinished file")
        for symbol in symbols {
            XCTAssertLessThanOrEqual(NSMaxRange(symbol.range), incomplete.utf16.count)
            XCTAssertFalse((incomplete as NSString).substring(with: symbol.selectionRange).isEmpty)
        }
        let incompatible = expectation(description: "Language revision rejected")
        unfinishedController.treeSitterClient?.querySymbols(source: incomplete, languageID: "python") { symbols in
            XCTAssertNil(symbols)
            incompatible.fulfill()
        }
        await fulfillment(of: [incompatible], timeout: 3)
    }

    @MainActor
    func testStructureEditorLayouts() async throws {
        var document = WorkspaceDocument(location: WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "outline", workspaceLabel: "Outline", root: "/private/tmp"), path: "Sources/Navigation.swift", kind: .file)
        document.text = """
        import Foundation

        struct Greeter {
            let greeting = "Hello 🌎"

            func greet(name: String) -> String {
                return "\\(greeting), \\(name)!"
            }
        }
        """
        document.savedText = document.text
        document.isLoading = false
        document.cursorPositions = [CursorPosition(range: (document.text as NSString).range(of: "return"))]
        for (width, outline) in [(900, false), (900, true), (360, true)] {
            let view = WorkspaceDocumentView(document: Binding(get: { document }, set: { document = $0 }),
                                             onSave: {}, showsOutline: outline)
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // NSHostingView does not expose its SwiftUI AX subtree in an offscreen test
            // window. Inspect only the rendered breadcrumb strip: names in source code or
            // the outline cannot accidentally satisfy this assertion. The symbols are indexed
            // after a debounce, later on a slower machine, so look again until they show.
            var bitmap: NSBitmapImageRep
            var visible = ""
            var attempts = 0
            repeat {
                attempts += 1
                try await Task.sleep(for: .milliseconds(attempts == 1 ? 700 : 250))
                host.layoutSubtreeIfNeeded()
                bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.cgImage)
                let scale = CGFloat(image.width) / host.bounds.width
                let breadcrumb = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 34 * scale,
                                                                          width: CGFloat(image.width), height: 26 * scale)))
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: breadcrumb).perform([recognition])
                visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            } while attempts < 20 && (visible.range(of: #"\bGreeter\b"#, options: .regularExpression) == nil
                                      || visible.range(of: #"\bgreet\b"#, options: .regularExpression) == nil)
            XCTAssertNotNil(visible.range(of: #"\bGreeter\b"#, options: .regularExpression), visible)
            XCTAssertNotNil(visible.range(of: #"\bgreet\b"#, options: .regularExpression), visible)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let label = "\(width)-\(outline ? "outline" : "breadcrumbs")"
            try png.write(to: URL(fileURLWithPath: "/private/tmp/wooloo-structure-\(label).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Editor structure \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.close()
        }
    }

    private final class Spy: TextViewCoordinator {
        var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    @MainActor
    private func makeEditor(_ text: String, languageID: String) async throws -> (window: NSWindow, spy: Spy) {
        let spy = Spy()
        let syntax = try XCTUnwrap(EditorSyntax.named(languageID))
        let editor = CodeEditSourceEditor(NSTextStorage(string: text), language: syntax.language,
                                         theme: WoolooTheme.all[0].editorTheme,
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                         tabWidth: 4, lineHeight: 1.15, wrapLines: false,
                                         cursorPositions: .constant([]), coordinators: [spy])
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        _ = try XCTUnwrap(spy.controller)
        return (window, spy)
    }

    @MainActor
    private func query(_ controller: TextViewController, source: String, languageID: String) async throws -> [SourceSymbol] {
        let result = await withCheckedContinuation { continuation in
            controller.treeSitterClient!.querySymbols(source: source, languageID: languageID) { result in
                continuation.resume(returning: result)
            }
        }
        return try XCTUnwrap(result)
    }
}

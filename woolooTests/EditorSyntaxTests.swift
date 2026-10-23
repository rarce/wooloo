import XCTest
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
@testable import wooloo

final class EditorSyntaxTests: XCTestCase {
    func testConfigurationDefaultsAndExistingDetection() {
        for path in ["server.conf", "app.cfg", "app.properties", ".gitconfig", ".gitmodules", ".editorconfig", "repo/.git/config", ".git/config"] {
            XCTAssertEqual(EditorSyntax.resolve(path: path, text: "").id, "properties", path)
        }
        XCTAssertEqual(EditorSyntax.resolve(path: "APP.INI", text: "").id, "ini")
        XCTAssertEqual(EditorSyntax.resolve(path: "main.swift", text: "").id, "swift")
        XCTAssertEqual(EditorSyntax.resolve(path: "Dockerfile", text: "").id, "dockerfile")
        XCTAssertEqual(EditorSyntax.resolve(path: "script", text: "#!/bin/bash\necho hi\n").id, "bash")
        XCTAssertEqual(EditorSyntax.resolve(path: "unknown", text: "").id, "plaintext")
    }

    func testExplicitPlainTextOverridesAssociationsAndAutomaticDetection() {
        let rules = [SyntaxAssociation(pattern: "*.conf", syntaxID: "toml")]
        XCTAssertEqual(EditorSyntax.resolve(path: "app.conf", text: "", associations: rules).id, "toml")
        XCTAssertEqual(EditorSyntax.resolve(path: "app.conf", text: "", override: "plaintext", associations: rules).id, "plaintext")
        XCTAssertEqual(EditorSyntax.resolve(path: "app.conf", text: "", override: "unknown", associations: rules).id, "toml")
        XCTAssertEqual(EditorSyntax.resolve(path: "file.ipynb", text: "").id, "json")
        XCTAssertEqual(EditorSyntax.resolve(path: "file.ipynb", text: "", override: "plaintext").id, "plaintext")
    }

    func testSpecificRulesWinAndGlobPathsMatchZeroOrMoreDirectories() {
        let rules = [SyntaxAssociation(pattern: "nginx.conf", syntaxID: "ini"),
                     SyntaxAssociation(pattern: "*.conf", syntaxID: "properties"),
                     SyntaxAssociation(pattern: "config/**/*.conf", syntaxID: "toml")]
        XCTAssertEqual(SyntaxAssociation.match("etc/nginx.conf", in: rules)?.id, "ini")
        XCTAssertEqual(SyntaxAssociation.match("other.conf", in: rules)?.id, "properties")
        XCTAssertEqual(SyntaxAssociation.match("config/app.conf", in: rules)?.id, "toml")
        XCTAssertEqual(SyntaxAssociation.match("config/a/b/app.conf", in: rules)?.id, "toml")
        XCTAssertEqual(SyntaxAssociation.match("elsewhere/config/app.conf", in: rules)?.id, "properties")
        XCTAssertNil(SyntaxAssociation.match("app.conf.bak", in: rules))
        XCTAssertEqual(SyntaxAssociation.decode(SyntaxAssociation.encode(rules)), rules)
        XCTAssertEqual(SyntaxAssociation.decode("invalid"), [])
        XCTAssertEqual(EditorSyntax.resolve(path: "app.conf", text: "", associations: [.init(pattern: "*", syntaxID: "removed")]).id, "properties")
    }

    func testCatalogExcludesLanguagesWithoutQueriesAndIncludesPlainText() {
        XCTAssertNotNil(EditorSyntax.named("plaintext"))
        for id in ["agda", "julia", "perl", "verilog"] { XCTAssertNil(EditorSyntax.named(id)) }
        XCTAssertEqual(Set(EditorSyntax.all.map(\.id)).count, EditorSyntax.all.count)
    }

    func testConfigurationTokensUseUTF16AndKeepCommentsOutOfQuotedValues() {
        let text = "[server]\r\nemoji😀 = \"hello # ; world\" # note\r\nport: 8080\r\nenabled=true\nurl=https://example.test/#anchor\n! comment\n"
        let source = text as NSString
        let tokens = ConfigurationSyntax.highlights(text).map { "\(source.substring(with: $0.range).trimmingCharacters(in: .newlines)):\(String(describing: $0.capture!))" }
        XCTAssertTrue(tokens.contains("[server]:type"))
        XCTAssertTrue(tokens.contains("emoji😀:keyword"))
        XCTAssertTrue(tokens.contains("\"hello # ; world\":string"))
        XCTAssertTrue(tokens.contains("# note:comment"))
        XCTAssertTrue(tokens.contains("8080:number"))
        XCTAssertTrue(tokens.contains("true:boolean"))
        XCTAssertTrue(tokens.contains("https://example.test/#anchor:string"))
        XCTAssertTrue(tokens.contains("! comment:comment"))
        XCTAssertTrue(ConfigurationSyntax.highlights("").isEmpty)
    }

    func testDiffUsesTheSharedConfigurationTokensAndHonorsOverrides() {
        let old = "[server]\nport=80\n", new = "[server]\nport=8080\n"
        let patch = "diff --git a/app.conf b/app.conf\n--- a/app.conf\n+++ b/app.conf\n@@ -1,2 +1,2 @@\n [server]\n-port=80\n+port=8080\n"
        let colored = ParsedDiff(patch).withSides(old: old, new: new)
        let lines = colored.files[0].hunks[0].lines
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.syntax.contains { $0.capture == .number } })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.syntax.contains { $0.capture == .number } })
        let plain = ParsedDiff(patch).withSides(old: old, new: new, syntaxOverride: "plaintext")
        XCTAssertTrue(plain.files[0].hunks[0].lines.allSatisfy { $0.syntax.isEmpty })
        let expected = ConfigurationSyntax.highlights("port=8080\n")
        let spans = DiffHighlighter.highlight(new, syntax: .properties)[1]
        XCTAssertEqual(spans.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }, expected.map(\.range))
        XCTAssertEqual(spans.map(\.capture), expected.compactMap(\.capture))
    }

    func testConfigurationDiffLineNumbersFollowGitForCRLFAndUnicodeSeparators() {
        let text = "value=one\u{2028}two\r\nport=80\r\n"
        let lines = DiffHighlighter.highlight(text, syntax: .ini)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains { $0.capture == .number && $0.range == 5..<7 })
        XCTAssertTrue(lines[2].isEmpty)
    }

    @MainActor
    func testSnapshotRestoresOverrideAndOlderSnapshotsDefaultToAutomatic() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let location = try sandbox.repository("repo", files: ["app.conf": "port=80\n"])
        var document = WorkspaceDocument(space: nil, location: location, path: "app.conf", kind: .file)
        document.syntaxOverride = "ini"
        let snapshot = WorkspaceDocumentSnapshot(document)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceDocumentSnapshot.self, from: encoded).document().syntaxOverride, "ini")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "syntaxOverride")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceDocumentSnapshot.self, from: legacy).document().syntaxOverride)
    }

    private final class Spy: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    }

    @MainActor
    func testMarkdownSourceColorsHeadingsInlineAndInjectedCode() async throws {
        let text = "# Heading\n\nPlain **strong** and *emphasis* and ***combined*** with `inline` and [label](https://example.test).\n\n- item\n\n```swift\nlet answer = 42\n```\n"
        let storage = NSTextStorage(string: text)
        let spy = Spy()
        let theme = WoolooTheme.all[0].editorTheme
        let editor = CodeEditSourceEditor(storage, language: .markdown, theme: theme,
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                         tabWidth: 4, lineHeight: 1.15, wrapLines: false,
                                         cursorPositions: .constant([]), coordinators: [spy])
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        let controller = try XCTUnwrap(spy.controller)
        let rendered = try XCTUnwrap(controller.textView.textStorage)
        for (token, color) in [("Heading", theme.keywords), ("strong", theme.keywords), ("combined", theme.keywords),
                               ("emphasis", theme.attributes), ("inline", theme.strings),
                               ("label", theme.attributes), ("https://example.test", theme.strings),
                               ("-", theme.comments), ("let", theme.keywords), ("42", theme.numbers),
                               ("Plain", theme.text)] {
            let offset = (text as NSString).range(of: token).location
            XCTAssertEqual(rendered.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, color, token)
        }
        for (token, trait) in [("Heading", NSFontTraitMask.boldFontMask), ("strong", .boldFontMask), ("emphasis", .italicFontMask), ("combined", .boldFontMask), ("combined", .italicFontMask)] {
            let offset = (text as NSString).range(of: token).location
            let font = try XCTUnwrap(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(trait), token)
        }
        XCTAssertEqual(rendered.string, text)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Markdown source highlighting"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        host.rootView = CodeEditSourceEditor(storage, language: .default, theme: theme,
                                             font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                             tabWidth: 4, lineHeight: 1.15, wrapLines: false,
                                             cursorPositions: .constant([]), coordinators: [spy])
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        for token in ["Heading", "strong", "emphasis"] {
            let offset = (text as NSString).range(of: token).location
            let font = try XCTUnwrap(rendered.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask), token)
            XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.italicFontMask), token)
            XCTAssertEqual(rendered.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, theme.text, token)
        }
    }

    @MainActor
    func testDeletingTheLastCharacterOfHighlightedSourceWithoutNewline() async throws {
        let source = "class First { method() {} }"
        let storage = NSTextStorage(string: source)
        let spy = Spy()
        let theme = WoolooTheme.all[0].editorTheme
        let host = NSHostingView(rootView: CodeEditSourceEditor(
            storage, language: .typescript, theme: theme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            tabWidth: 4, lineHeight: 1.15, wrapLines: false,
            cursorPositions: .constant([]), coordinators: [spy]))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let textView = try XCTUnwrap(spy.controller?.textView)
        textView.insertText("Other", replacementRange: (source as NSString).range(of: "First"))
        try await Task.sleep(nanoseconds: 150_000_000)
        let renamed = source.replacingOccurrences(of: "First", with: "Other")
        XCTAssertEqual(textView.string, renamed)
        textView.insertText("", replacementRange: NSRange(location: renamed.utf16.count - 1, length: 1))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(textView.string, String(renamed.dropLast()))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, theme.keywords)
        textView.insertText("", replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        XCTAssertEqual(textView.string, "")
        textView.insertText("class Again {}", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(textView.string, "class Again {}")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, theme.keywords)
    }

    @MainActor
    func testSwitchingFromConfigurationToTagSyntaxRestoresClosingTagsAndNewlines() async throws {
        for id in ["html", "jsx", "tsx"] {
            let spy = Spy()
            let storage = NSTextStorage(string: "<div>")
            func editor(_ syntax: EditorSyntax) -> CodeEditSourceEditor {
                CodeEditSourceEditor(storage, language: syntax.language, theme: WoolooTheme.all[0].editorTheme,
                                     font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                     tabWidth: 4, lineHeight: 1.15, wrapLines: false,
                                     cursorPositions: .constant([]),
                                     highlightProviders: syntax.isConfiguration ? [ConfigurationHighlightProvider()] : [TreeSitterClient()],
                                     highlightingID: syntax.isConfiguration ? "configuration" : nil,
                                     coordinators: [spy])
            }
            let host = NSHostingView(rootView: editor(.properties))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let controller = try XCTUnwrap(spy.controller)
            let textView = try XCTUnwrap(controller.textView)
            host.rootView = editor(try XCTUnwrap(EditorSyntax.named(id)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(spy.controller === controller, id)
            textView.insertText("\n", replacementRange: NSRange(location: 5, length: 0))
            let lines = textView.string.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 3, "\(id): insert an indented line and a closing-tag line")
            XCTAssertEqual(lines.last, "</div>", "\(id): close the opening tag without reopening the editor")
            if lines.count == 3 {
                XCTAssertFalse(lines[1].isEmpty, id)
                XCTAssertTrue(lines[1].allSatisfy { $0 == " " || $0 == "\t" }, id)
            }
        }
    }

    @MainActor
    func testChangingConfigurationSyntaxRetainsTextViewSelectionAndUndoHistory() async throws {
        let spy = Spy()
        let storage = NSTextStorage(string: "port=80\n")
        let theme = WoolooTheme.all[0].editorTheme
        func editor(_ syntax: EditorSyntax) -> CodeEditSourceEditor {
            CodeEditSourceEditor(storage, language: syntax.language, theme: theme,
                                 font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                 tabWidth: 4, lineHeight: 1.15, wrapLines: false,
                                 cursorPositions: .constant([]),
                                 highlightProviders: syntax.isConfiguration ? [ConfigurationHighlightProvider()] : [TreeSitterClient()],
                                 highlightingID: syntax.isConfiguration ? "configuration" : nil,
                                 coordinators: [spy])
        }
        let host = NSHostingView(rootView: editor(.plainText))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let controller = try XCTUnwrap(spy.controller)
        let textView = try XCTUnwrap(controller.textView)
        textView.insertText("# hello\n", replacementRange: NSRange(location: 0, length: 0))
        let text = textView.string
        let selections = textView.selectionManager.textSelections.map(\.range)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        for syntax in [EditorSyntax.properties, EditorSyntax.named("swift")!, .plainText, .ini] {
            host.rootView = editor(syntax)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(spy.controller === controller)
            XCTAssertTrue(spy.controller?.textView === textView)
            XCTAssertEqual(textView.string, text)
            XCTAssertEqual(textView.selectionManager.textSelections.map(\.range), selections)
            XCTAssertTrue(textView.undoManager?.canUndo == true)
            XCTAssertEqual(controller.highlightProviders.first is ConfigurationHighlightProvider, syntax.isConfiguration)
            let key = (textView.string as NSString).range(of: "port").location
            let color = textView.textStorage.attribute(.foregroundColor, at: key, effectiveRange: nil) as? NSColor
            if syntax.isConfiguration { XCTAssertEqual(color, theme.keywords) }
            else if syntax == .plainText { XCTAssertEqual(color, theme.text) }
        }
        let key = (textView.string as NSString).range(of: "port").location
        textView.insertText("# ", replacementRange: NSRange(location: key, length: 0))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: key + 2, effectiveRange: nil) as? NSColor,
                       theme.comments, "Editing a key into a comment must recolor the entire line")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, text)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "port=80\n")
    }
}

final class EditorDocumentMetadataTests: XCTestCase {
    func testLineContentRangesMatchAllDetectedTerminators() {
        let text = "😀\rsecond\u{2028}third\r\nfourth\nlast\u{2029}\u{85}" as NSString
        let metadata = EditorDocumentMetadata(text as String)
        let expected = ["😀", "second", "third", "fourth", "last", "", ""]
        for (index, contents) in expected.enumerated() {
            let range = metadata.contentRange(ofLine: index + 1, in: text)
            XCTAssertEqual(range.map { text.substring(with: $0) }, contents)
            XCTAssertEqual(range.map { metadata.position(at: $0.location).line }, index + 1)
        }
        XCTAssertNil(metadata.contentRange(ofLine: 0, in: text))
        XCTAssertNil(metadata.contentRange(ofLine: 8, in: text))
    }

    @MainActor
    func testDocumentRevealSupportsEditorAndSearchLinesForCRAndUnicodeSeparators() async throws {
        for (text, expected, editorLines) in [("a\rb\nc", "b", true), ("a\u{2028}b\nc", "b", true),
                                              ("a\rb\nc", "c", false), ("a\u{2028}b\nc", "c", false)] {
            let target = 2
            var document = WorkspaceDocument(location: WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "reveal", workspaceLabel: "Reveal", root: "/private/tmp"), path: "reveal.txt", kind: .file)
            document.text = text
            document.savedText = text
            document.isLoading = false
            let editorRange = document.metadata.contentRange(ofLine: target, in: text as NSString)
            document.reveal = WorkspaceDocumentReveal(line: target, range: NSRange(location: 0, length: 1),
                                                     absoluteRange: editorLines ? editorRange : nil)
            let binding = Binding(get: { document }, set: { document = $0 })
            let host = NSHostingView(rootView: WorkspaceDocumentView(document: binding, onSave: {}))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let selection = try XCTUnwrap(document.cursorPositions.first?.range)
            XCTAssertEqual((text as NSString).substring(with: selection), expected)
            XCTAssertEqual(document.metadata.position(at: selection.location).line, editorLines ? target : 3)
            XCTAssertNil(document.reveal)
            window.close()
        }
    }

    func testLineEndingsPreserveCRLFAndIdentifyMixedDocuments() {
        XCTAssertEqual(EditorDocumentMetadata("a\r\nb\r\n").lineStarts, [0, 3, 6])
        XCTAssertEqual(EditorDocumentMetadata("a\r\nb\r\n").lineEndings, "CRLF")
        XCTAssertEqual(EditorDocumentMetadata("a\nb\r\n").lineEndings, "Mixed EOL")
        XCTAssertEqual(EditorDocumentMetadata("a\rb").lineEndings, "CR")
        XCTAssertEqual(EditorDocumentMetadata("a\nb").lineEndings, "LF")
        XCTAssertEqual(EditorDocumentMetadata("hello").lineEndings, "No EOL")
        XCTAssertEqual(EditorDocumentMetadata("a\u{2028}b").lineEndings, "LS")
        XCTAssertEqual(EditorDocumentMetadata("a\u{2029}b").lineEndings, "PS")
        XCTAssertEqual(EditorDocumentMetadata("a\u{85}b").lineEndings, "NEL")
        XCTAssertEqual(EditorDocumentMetadata("a\u{2028}b\n").lineEndings, "Mixed EOL")
    }

    func testCursorLookupUsesUTF16AndClampsInvalidOffsets() {
        let metadata = EditorDocumentMetadata("😀a\r\nb\n")
        XCTAssertEqual(metadata.position(at: 3).column, 4)
        XCTAssertEqual(metadata.position(at: 5).line, 2)
        XCTAssertEqual(metadata.position(at: 5).column, 1)
        XCTAssertEqual(metadata.position(at: 100).line, 3)
        XCTAssertEqual(metadata.position(at: NSNotFound).line, 1)
        XCTAssertEqual(EditorDocumentMetadata().position(at: 0).column, 1)
    }

    func testSelectionCountsGraphemesAcrossMultipleUTF16Ranges() {
        let text = "😀e\u{301}\r\nx"
        XCTAssertEqual(EditorDocumentMetadata.selectedCharacters(in: text, ranges: [
            NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)
        ]), 2)
        XCTAssertEqual(EditorDocumentMetadata.selectedCharacters(in: text, ranges: [
            NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0)
        ]), 0)
    }

    @MainActor
    func testStatusBarRendersInWideAndNarrowEditors() async throws {
        var document = WorkspaceDocument(location: WorkspaceFileLocation(machine: nil, session: "wooloo-ui-test", workspaceID: "statusbar", workspaceLabel: "Status bar", root: "/private/tmp"), path: "StatusBar.swift", kind: .file)
        document.text = "import SwiftUI\r\n\r\nstruct Example {\r\n    let greeting = \"Hello 🌎\"\r\n}\r\n"
        document.savedText = document.text
        document.isLoading = false
        document.cursorPositions = [CursorPosition(range: NSRange(location: 0, length: 6))]
        for width in [900, 360] {
            let view = WorkspaceDocumentView(document: .constant(document), onSave: {})
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/wooloo-statusbar-\(width).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Editor status bar \(width)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.close()
        }
    }

    func testDocumentMetadataUpdatesAfterTextReplacement() {
        var document = WorkspaceDocument(location: WorkspaceFileLocation(machine: nil, session: "test", workspaceID: "test", workspaceLabel: "Test", root: "/tmp"), path: "sample.md", kind: .file)
        document.text = "first\r\nsecond"
        XCTAssertEqual(document.metadata.lineEndings, "CRLF")
        document.text = "single"
        XCTAssertEqual(document.metadata.lineStarts, [0])
    }
}

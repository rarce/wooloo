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

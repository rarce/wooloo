import CodeEditLanguages
import CodeEditSourceEditor
import SwiftTreeSitter
import SwiftUI
import XCTest
@testable import wooloo

/// Syntax colors for diff lines: tree-sitter captures split by line, and their theme colors.
final class DiffHighlighterTests: XCTestCase {
    /// Each line's highlighted text and capture, sorted so the order of captures does not matter.
    private func highlighted(_ text: String, _ language: CodeLanguage) -> [[String]] {
        let lines = text.components(separatedBy: "\n").map { Array($0.utf16) }
        return DiffHighlighter.highlight(text, language: language).enumerated().map { index, spans in
            spans.map { span in
                let slice = Array(lines[index][span.range])
                return "\(String(decoding: slice, as: UTF16.self)):\(span.capture)"
            }.sorted()
        }
    }

    func testCapturesAreSplitByLine() {
        let swift = "let x = 42 // note\nlet s = \"hi\"\n"
        let lines = highlighted(swift, .swift)
        XCTAssertEqual(lines.count, 3, "One entry per line, including the empty last one")
        XCTAssertTrue(lines[0].contains("let:keyword"), "\(lines[0])")
        XCTAssertTrue(lines[0].contains("42:number"), "\(lines[0])")
        XCTAssertTrue(lines[0].contains("// note:comment"), "\(lines[0])")
        XCTAssertTrue(lines[1].contains("hi:string"), "\(lines[1])")
        XCTAssertEqual(lines[2], [])
    }

    /// A capture that spans lines, such as a block comment, is cut at each line end.
    func testMultilineCapturesAreCutPerLine() {
        let lines = highlighted("/* one\ntwo */\nlet a = 1", .swift)
        XCTAssertEqual(lines[0], ["/* one:comment"])
        XCTAssertEqual(lines[1], ["two */:comment"])
    }

    func testPlainTextHasNoCaptures() {
        XCTAssertEqual(DiffHighlighter.highlight("let x = 1\n", language: .default).count, 0)
    }

    func testPaletteMapsCapturesToThemeColors() {
        let theme = WoolooTheme.all[0].editorTheme
        let palette = SyntaxPalette(theme)
        XCTAssertEqual(palette.color(.keyword), SwiftUI.Color(nsColor: theme.keywords))
        XCTAssertEqual(palette.color(.keywordReturn), SwiftUI.Color(nsColor: theme.keywords))
        XCTAssertEqual(palette.color(.comment), SwiftUI.Color(nsColor: theme.comments))
        XCTAssertEqual(palette.color(.float), SwiftUI.Color(nsColor: theme.numbers))
        XCTAssertEqual(palette.color(.string), SwiftUI.Color(nsColor: theme.strings))
        XCTAssertEqual(palette.color(.type), SwiftUI.Color(nsColor: theme.types))
        XCTAssertEqual(palette.color(.typeAlternate), SwiftUI.Color(nsColor: theme.attributes))
        XCTAssertNil(palette.color(.variable), "Plain identifiers keep the text color")
    }

    // MARK: Same colors as the reference

    /// Checks each line against `ReferenceDiffHighlighter`: the same captures for every range, in
    /// the same order where they share a range, and no span after one inside it, so painting in
    /// order gives the same colors. Spans of different ranges may be listed in another order.
    private func assertSameColors(_ text: String, _ language: CodeLanguage, _ name: String) {
        let expected = ReferenceDiffHighlighter.highlight(text, language: language)
        let actual = DiffHighlighter.highlight(text, language: language)
        XCTAssertEqual(actual.count, expected.count, "\(name): line count")
        XCTAssertGreaterThan(expected.reduce(0) { $0 + $1.count }, 0, "\(name): has captures")
        func byRange(_ spans: [DiffSyntaxSpan]) -> [String: [String]] {
            Dictionary(grouping: spans, by: { "\($0.range)" }).mapValues { $0.map { "\($0.capture)" } }
        }
        for (index, (line, reference)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(byRange(line), byRange(reference), "\(name): line \(index + 1)")
            for (later, span) in line.enumerated() {
                for earlier in line[..<later] where span.range != earlier.range && span.range.lowerBound <= earlier.range.lowerBound
                    && earlier.range.upperBound <= span.range.upperBound {
                    XCTFail("\(name): line \(index + 1) paints \(span.range) over \(earlier.range) inside it")
                }
            }
        }
    }

    func testLargeFileColorsMatchTheReference() {
        let sides = Self.bigSides()
        assertSameColors(sides.old, .swift, "old side")
        assertSameColors(sides.new, .swift, "new side")
    }

    /// Checks every patch line's colors against the reference run over its whole file: the old
    /// one for removed lines, the new one for the others and the lines kept for expanding gaps.
    @discardableResult
    private func assertSidesColored(_ patch: String, old: String, new: String, language: CodeLanguage = .swift,
                                    _ name: String) -> ParsedDiff {
        let diff = ParsedDiff(patch, old: old, new: new)
        let oldSyntax = ReferenceDiffHighlighter.highlight(old, language: language)
        let newSyntax = ReferenceDiffHighlighter.highlight(new, language: language)
        func key(_ spans: [DiffSyntaxSpan]) -> [String] { spans.map { "\($0.range):\($0.capture)" }.sorted() }
        let lines = diff.files.first?.hunks.flatMap(\.lines) ?? []
        XCTAssertFalse(lines.isEmpty, "\(name): no lines")
        XCTAssertTrue(lines.contains { !$0.syntax.isEmpty }, "\(name): no colors")
        for line in lines {
            let expected = line.kind == .removed ? oldSyntax[line.oldNumber! - 1] : newSyntax[line.newNumber! - 1]
            XCTAssertEqual(key(line.syntax), key(expected),
                           "\(name): \(line.kind) line \(line.oldNumber ?? 0)/\(line.newNumber ?? 0): \(line.text)")
        }
        XCTAssertEqual(diff.files.first?.newSyntax.map(key), newSyntax.map(key), "\(name): new file")
        return diff
    }

    /// `git diff --no-index` of two texts, with its usual three lines of context.
    private func gitDiff(_ old: String, _ new: String, path: String = "f.swift") throws -> String {
        let directory = URL(fileURLWithPath: "/private/tmp/wooloo-tests/diff-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try old.write(to: directory.appendingPathComponent("a/" + path), atomically: true, encoding: .utf8)
        try new.write(to: directory.appendingPathComponent("b/" + path), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.autocrlf=false", "diff", "--no-index", "--no-color", "a/" + path, "b/" + path]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testDiffLinesTakeColorsFromTheirSide() {
        let sides = Self.bigSides()
        let diff = assertSidesColored(sides.patch, old: sides.old, new: sides.new, "every third line")
        XCTAssertEqual(diff.files[0].hunks.flatMap(\.lines).count, 5000 + 5000 / 3)
        XCTAssertEqual(diff.files[0].newLines?.count, 5000)
    }

    /// The old file is parsed by editing the new file's tree; check edits that move lines, open
    /// and close comments and strings, and touch the first and last lines.
    func testOldSideParsedFromEditsMatchesTheReference() throws {
        var lines = (0..<400).map { "    let value\($0) = compute(\($0), \"text \($0)\") // note" }
        lines.insert("struct Big {", at: 0)
        lines.append("}")
        let base = lines.joined(separator: "\n") + "\n"
        func edited(_ change: (inout [String]) -> Void, newline: Bool = true) -> String {
            var copy = lines
            change(&copy)
            return copy.joined(separator: "\n") + (newline ? "\n" : "")
        }
        let cases: [(String, String, String)] = [
            ("sparse replacements", base, edited { $0[10] = "    var changed = 1"; $0[390] = "    // replaced" }),
            ("insertions and deletions", base, edited {
                $0.remove(at: 50); $0.insert(contentsOf: ["    let a = 1", "    let b = \"two\""], at: 200); $0.remove(at: 300)
            }),
            ("comment opened in a removed line", edited { $0.insert("    /* open", at: 100); $0.insert("    close */", at: 120) },
             base),
            ("string opened in an added line", base, edited { $0.insert("    let s = \"\"\"", at: 30); $0.insert("    \"\"\"", at: 33) }),
            ("first and last lines", base, edited({ $0[0] = "final class Big {"; $0[$0.count - 1] = "} // end" }, newline: false)),
            ("whole file replaced", base, "let other = 1\n"),
            ("unicode", base, edited { $0[5] = "    let café = \"日本 👍🏽\" // ü"; $0.insert("    // 👨‍👩‍👧 ✓", at: 7) }),
        ]
        for (name, old, new) in cases {
            assertSidesColored(try gitDiff(old, new), old: old, new: new, name)
            assertSidesColored(try gitDiff(new, old), old: new, new: old, name + " reversed")
        }
        let crlf = base.replacingOccurrences(of: "\n", with: "\r\n")
        let crlfEdited = crlf.replacingOccurrences(of: "value7 =", with: "renamed7 =")
        assertSidesColored(try gitDiff(crlf, crlfEdited), old: crlf, new: crlfEdited, "crlf")
    }

    /// JavaScript reuses most of the new tree when parsing the old file, unlike Swift's grammar.
    func testOldJavaScriptParsedFromEditsMatchesTheReference() throws {
        let lines = (0..<400).map { "const value\($0) = compute(\($0), `text ${\($0)}`); // note" }
        let base = lines.joined(separator: "\n") + "\n"
        func edited(_ change: (inout [String]) -> Void) -> String {
            var copy = lines
            change(&copy)
            return copy.joined(separator: "\n") + "\n"
        }
        let cases: [(String, String, String)] = [
            ("sparse replacements", base, edited { $0[10] = "let changed = 1;"; $0[390] = "// replaced" }),
            ("insertions and deletions", base, edited {
                $0.remove(at: 50); $0.insert(contentsOf: ["function f(a) {", "  return a?.b;", "}"], at: 200); $0.remove(at: 300)
            }),
            ("comment opened in a removed line", edited { $0.insert("/* open", at: 100); $0.insert("close */", at: 120) }, base),
            ("template opened in an added line", base, edited { $0.insert("const s = `", at: 30); $0.insert("`;", at: 33) }),
        ]
        for (name, old, new) in cases {
            assertSidesColored(try gitDiff(old, new, path: "f.js"), old: old, new: new, language: .javascript, name)
            assertSidesColored(try gitDiff(new, old, path: "f.js"), old: new, new: old, language: .javascript,
                               name + " reversed")
        }
    }

    /// An old file edited outside the patch's lines can't be parsed from the new tree; it is
    /// parsed whole, so its lines still get their own colors.
    func testOldSideEditedOutsideThePatchIsParsedWhole() throws {
        let old = (0..<50).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "let v25 = 25", with: "var v25 = 25")
        let patch = try gitDiff(old, new)
        // An unclosed comment before the patch turns its lines into comment too.
        let stale = old.replacingOccurrences(of: "let v20 = 20\n", with: "/* let v20 = 20\n")
        assertSidesColored(patch, old: stale, new: new, "stale old side")

        let document = try XCTUnwrap(DiffHighlighter.Document(new, language: .swift))
        let changes = [DiffHighlighter.Change(old: 25, removed: 1, new: 25, added: 1)]
        XCTAssertNotNil(document.reparsed(as: old, changes: changes))
        XCTAssertNil(document.reparsed(as: stale, changes: changes))
        XCTAssertNil(document.reparsed(as: old + "let extra = 1\n", changes: changes), "Text after the last change differs")
    }

    func testSourceFileColorsMatchTheReference() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("wooloo/WorkspaceDiffView.swift")
        assertSameColors(try String(contentsOf: source, encoding: .utf8), .swift, "WorkspaceDiffView.swift")
    }

    /// Wide and combined characters, multi-line comments and strings, CRLF line ends and no final
    /// newline, so UTF-16 offsets and line cuts are exercised.
    func testMixedTextColorsMatchTheReference() {
        let swift = """
        /* Ünïcödé 日本語 👍🏽 comment
           spanning lines */
        let café = "naïve 👨‍👩‍👧 \\(value)" // trailing 🎉\r
        let multi = \"\"\"
            line one ✓
            line two
            \"\"\"
        func f<T: Equatable>(_ a: T) -> Bool { return a == a } // 中文
        @MainActor final class Ω { var x = 0x1F; let y = 3.14 }
        """
        assertSameColors(swift, .swift, "swift")
        let javascript = "// é\nconst s = `a ${b + \"ü\"} c`;\n/** doc\n * 👍 */\nfunction g(x) { return x?.y ?? 1; }"
        assertSameColors(javascript, .javascript, "javascript")
        let python = "# ñ\ndef f(x: int) -> str:\n    \"\"\"Doc 文字\n    more\"\"\"\n    return f\"{x!r} ✓\"\n"
        assertSameColors(python, .python, "python")
    }
}


/// The first `DiffHighlighter`, kept to check that faster versions color every line the same:
/// for each range the lowest capture index wins, captures are cut at line ends, and each line
/// lists outer captures before the ones inside them.
enum ReferenceDiffHighlighter {
    static func highlight(_ text: String, language: CodeLanguage) -> [[DiffSyntaxSpan]] {
        guard let treeSitterLanguage = language.language,
              let query = TreeSitterModel.shared.query(for: language.id) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(treeSitterLanguage)) != nil, let tree = parser.parse(text) else { return [] }

        var lineStarts = [0]
        var length = 0
        for unit in text.utf16 {
            length += 1
            if unit == 10 { lineStarts.append(length) }
        }

        var captures: [NSRange: (index: Int, name: CaptureName)] = [:]
        for match in query.execute(in: tree).resolve(with: .init(string: text)) {
            for capture in match.captures {
                guard let name = CaptureName.fromString(capture.name), capture.range.length > 0 else { continue }
                if let existing = captures[capture.range], existing.index <= capture.index { continue }
                captures[capture.range] = (capture.index, name)
            }
        }

        var result = Array(repeating: [DiffSyntaxSpan](), count: lineStarts.count)
        for (range, capture) in captures.sorted(by: { $0.key.length > $1.key.length }) {
            var line = max(0, (lineStarts.firstIndex { $0 > range.location } ?? lineStarts.count) - 1)
            while line < lineStarts.count, lineStarts[line] < range.upperBound {
                let start = lineStarts[line]
                let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
                let lower = max(range.location, start) - start, upper = min(range.upperBound, end) - start
                if upper > lower { result[line].append(DiffSyntaxSpan(range: lower..<upper, capture: capture.name)) }
                line += 1
            }
        }
        return result
    }
}

extension DiffHighlighterTests {
    static func bigSides() -> (patch: String, old: String, new: String) {
        var old = "", new = "", patch = "--- a/big/generated.swift\n+++ b/big/generated.swift\n@@ -1,5000 +1,5000 @@\n"
        for i in 0..<5000 {
            let o = "    let value\(i) = compute(\(i)) // generated line"
            let n = (i + 1) % 3 == 0 ? "    let value\(i) = compute(\(i)) // edited line" : o
            old += o + "\n"; new += n + "\n"
            if o == n { patch += " " + o + "\n" } else { patch += "-" + o + "\n+" + n + "\n" }
        }
        return (patch, old, new)
    }
}

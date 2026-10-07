import CodeEditLanguages
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
}

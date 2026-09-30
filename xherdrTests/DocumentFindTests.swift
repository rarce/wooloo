import XCTest
@testable import xherdr

/// Find and replace within an open document, in its source and in its rendered Markdown.
@MainActor
final class DocumentFindTests: XCTestCase {
    /// An open find bar with `query` typed in, as a pattern when `regex` is set.
    private func model(_ query: String, regex: Bool = false) -> DocumentFindModel {
        let model = DocumentFindModel()
        model.open(replace: false, query: nil)
        model.options.regex = regex
        model.options.query = query
        return model
    }

    func testMatchesAndNavigationWrapAround() {
        let find = model("foo")
        find.update(text: "foo bar foo baz foo", target: .source, anchor: nil)
        XCTAssertEqual(find.count, 3)
        XCTAssertEqual(find.current, 0)
        find.move(1); find.move(1)
        XCTAssertEqual(find.current, 2)
        find.move(1)
        XCTAssertEqual(find.current, 0)
        find.move(-1)
        XCTAssertEqual(find.current, 2)
    }

    func testAnchorSelectsTheNextMatchAfterTheCursor() {
        let find = model("foo")
        find.update(text: "foo bar foo baz foo", target: .source, anchor: 5)
        XCTAssertEqual(find.current, 1)
        find.update(text: "foo bar foo baz foo", target: .source, anchor: 100)
        XCTAssertEqual(find.current, 0, "Past the last match, find wraps to the first")
    }

    /// After replacing the current match the index stays, so it points at the next one.
    func testCurrentIndexSurvivesAReplacement() {
        let find = model("foo")
        find.update(text: "foo foo foo", target: .source, anchor: nil)
        find.move(1); find.move(1)
        find.update(text: "foo foo bar", target: .source, anchor: nil)
        XCTAssertEqual(find.current, 1)
    }

    /// Opening with selected text searches for that text, escaped when regex mode is on.
    func testOpeningWithASelectionEscapesItInRegexMode() {
        let regex = DocumentFindModel()
        regex.options.regex = true
        regex.open(replace: false, query: "a.b")
        XCTAssertEqual(regex.options.query, "a\\.b")
        let plain = DocumentFindModel()
        plain.open(replace: false, query: "a.b")
        XCTAssertEqual(plain.options.query, "a.b")
        let multiline = DocumentFindModel()
        multiline.open(replace: true, query: "two\nlines")
        XCTAssertEqual(multiline.options.query, "")
        XCTAssertTrue(multiline.showsReplace)
    }

    func testInvalidExpressionsAndClosingClearMatches() {
        let find = model("(", regex: true)
        find.update(text: "(((", target: .source, anchor: nil)
        XCTAssertNotNil(find.error)
        XCTAssertEqual(find.count, 0)
        XCTAssertNil(find.current)

        let open = model("x")
        open.update(text: "x x", target: .source, anchor: nil)
        open.close()
        XCTAssertEqual(open.count, 0)
        XCTAssertFalse(open.isVisible)
    }

    func testRegexReplacementExpandsCaptures() throws {
        let find = model("(\\w+)@(\\w+)", regex: true)
        find.replacement = "$2 at $1"
        let text = "user@host"
        find.update(text: text, target: .source, anchor: nil)
        let match = try XCTUnwrap(find.sourceMatches.first)
        XCTAssertEqual(find.replacementText(for: match, in: text), "host at user")
    }

    func testMatchesAreCappedAndReportedAsTruncated() {
        let find = model("a")
        find.update(text: String(repeating: "a", count: DocumentFindModel.maximumMatches + 5), target: .source, anchor: nil)
        XCTAssertEqual(find.count, DocumentFindModel.maximumMatches)
        XCTAssertTrue(find.isTruncated)
    }

    /// The preview searches rendered text: headings, paragraphs and inline code, not image
    /// descriptions or code blocks. Each match records its top-level block for scrolling.
    func testPreviewSearchesRenderedText() {
        let find = model("foo")
        let markdown = "# Title foo\n\nSome `foo` and foo.\n\n![foo](x.png)\n\n```\nfoo\n```\n"
        find.update(text: markdown, target: .preview, anchor: nil)
        XCTAssertEqual(find.count, 3)
        XCTAssertEqual(find.previewMatches.map(\.block), [0, 1, 1])
        XCTAssertTrue(find.sourceMatches.isEmpty)
    }
}

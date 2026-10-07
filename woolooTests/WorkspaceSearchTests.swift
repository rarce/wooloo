import XCTest
@testable import wooloo

/// Project search: expressions, globs, parsing of `git grep` and `grep` output, and replacement.
final class WorkspaceSearchTests: XCTestCase {
    private func options(_ query: String, caseSensitive: Bool = false, wholeWord: Bool = false,
                         regex: Bool = false) -> WorkspaceSearchOptions {
        WorkspaceSearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
    }

    private func matches(_ options: WorkspaceSearchOptions, in text: String) throws -> [String] {
        let expression = try WorkspaceSearch.expression(for: options)
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map { (text as NSString).substring(with: $0.range) }
    }

    func testExpressionOptions() throws {
        XCTAssertEqual(try matches(options("a.b"), in: "a.b axb"), ["a.b"])
        XCTAssertEqual(try matches(options("a.b", regex: true), in: "a.b axb"), ["a.b", "axb"])
        XCTAssertEqual(try matches(options("Foo"), in: "foo Foo"), ["foo", "Foo"])
        XCTAssertEqual(try matches(options("Foo", caseSensitive: true), in: "foo Foo"), ["Foo"])
        XCTAssertEqual(try matches(options("cat", wholeWord: true), in: "cat concat cats cat."), ["cat", "cat"])
        XCTAssertThrowsError(try WorkspaceSearch.expression(for: options("(", regex: true)))
    }

    func testGlobsSplitOnCommasOutsideBraces() {
        XCTAssertEqual(WorkspaceSearch.globs(" *.swift , {a,b}.md,, "), ["*.swift", "a.md", "b.md"])
        XCTAssertEqual(WorkspaceSearch.globs("src/{x,y}/*.{ts,tsx}"),
                       ["src/x/*.ts", "src/x/*.tsx", "src/y/*.ts", "src/y/*.tsx"])
        XCTAssertEqual(WorkspaceSearch.globs(""), [])
    }

    /// Recorded from `git grep -n -z -C 2` and `grep --null -n -C 2`; both must give the same result.
    func testParsesGitGrepAndGrepOutput() throws {
        let gitGrep = "s.txt\u{0}1\u{0}one\ns.txt\u{0}2\u{0}two\ns.txt\u{0}3\u{0}foo here\ns.txt\u{0}4\u{0}three\n"
            + "s.txt\u{0}5\u{0}four\n--\ns.txt\u{0}7\u{0}six\ns.txt\u{0}8\u{0}seven\ns.txt\u{0}9\u{0}Foo again\n"
        let grep = "./s.txt\u{0}1-one\n./s.txt\u{0}2-two\n./s.txt\u{0}3:foo here\n./s.txt\u{0}4-three\n"
            + "./s.txt\u{0}5-four\n--\n./s.txt\u{0}7-six\n./s.txt\u{0}8-seven\n./s.txt\u{0}9:Foo again\n"
        let expression = try WorkspaceSearch.expression(for: options("foo"))
        for output in [gitGrep, grep] {
            // SSH may print a banner before the line count.
            let result = WorkspaceSearch.parse(Data(("banner\n9\n" + output).utf8), expression: expression)
            XCTAssertEqual(result.matchCount, 2)
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.files.map(\.path), ["s.txt"])
            let excerpts = result.files[0].excerpts
            XCTAssertEqual(excerpts.map { $0.map(\.number) }, [[1, 2, 3, 4, 5], [7, 8, 9]])
            XCTAssertEqual(excerpts[0][2].matches, [NSRange(location: 0, length: 3)])
            XCTAssertEqual(excerpts[1][2].text, "Foo again")
        }
    }

    func testParseDropsFilesWhereTheExpressionFindsNothing() throws {
        // Whole-word search: the tool prefilters "cat" in "concat", the expression rejects it.
        let expression = try WorkspaceSearch.expression(for: options("cat", wholeWord: true))
        let output = "1\na.txt\u{0}1\u{0}concat\n"
        let result = WorkspaceSearch.parse(Data(output.utf8), expression: expression)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.matchCount, 0)
    }

    func testParseReportsTruncation() throws {
        let expression = try WorkspaceSearch.expression(for: options("x"))
        let output = "\(WorkspaceSearch.maximumOutputLines + 1)\na.txt\u{0}1\u{0}x\n"
        XCTAssertTrue(WorkspaceSearch.parse(Data(output.utf8), expression: expression).truncated)
    }

    func testScriptQuotesTheQuery() {
        let query = "'; touch /tmp/wooloo-pwned; echo '"
        let script = WorkspaceSearch.script(for: options(query))
        XCTAssertTrue(script.contains("-e " + WorkspaceFiles.quote(query)))
    }

    func testReplacementTemplates() throws {
        XCTAssertEqual(WorkspaceSearch.template("$1 \\n", regex: false), "\\$1 \\\\n")
        let expression = try WorkspaceSearch.expression(for: options("(\\w+)=(\\w+)", regex: true))
        let text = "key=value"
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(location: 0, length: 9)))
        let replaced = expression.replacementString(for: match, in: text, offset: 0,
                                                    template: WorkspaceSearch.template("$2\\t$1\\n\\\\", regex: true))
        XCTAssertEqual(replaced, "value\tkey\n\\")
    }

    func testRangeOfLine() {
        let text = "one\ntwo\n\nfour" as NSString
        XCTAssertEqual(WorkspaceSearch.range(ofLine: 1, in: text), NSRange(location: 0, length: 3))
        XCTAssertEqual(WorkspaceSearch.range(ofLine: 2, in: text), NSRange(location: 4, length: 3))
        XCTAssertEqual(WorkspaceSearch.range(ofLine: 3, in: text), NSRange(location: 8, length: 0))
        XCTAssertEqual(WorkspaceSearch.range(ofLine: 4, in: text), NSRange(location: 9, length: 4))
        XCTAssertNil(WorkspaceSearch.range(ofLine: 5, in: text))
    }
}

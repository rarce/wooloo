import XCTest
@testable import wooloo

/// Unified diffs parsed into files, hunks and numbered lines for the diff view.
final class ParsedDiffTests: XCTestCase {
    func testFilesHunksAndLineNumbers() {
        let patch = """
        diff --git a/a.txt b/a.txt
        index ddc897f..ccea01a 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,3 @@
         one
        -two
        +TWO
        +three
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +only line
        \\ No newline at end of file
        """
        let files = ParsedDiff(patch).files
        XCTAssertEqual(files.map(\.path), ["a.txt", "new name.txt", "new.txt"])

        let edited = files[0]
        XCTAssertNil(edited.status)
        XCTAssertEqual(edited.additions, 2)
        XCTAssertEqual(edited.deletions, 1)
        let lines = edited.hunks[0].lines
        XCTAssertEqual(lines.map(\.text), ["one", "two", "TWO", "three"])
        XCTAssertEqual(lines.map(\.oldNumber), [1, 2, nil, nil])
        XCTAssertEqual(lines.map(\.newNumber), [1, nil, 2, 3])

        XCTAssertEqual(files[1].status, "Renamed from old name.txt")
        XCTAssertTrue(files[1].hunks.isEmpty)

        XCTAssertEqual(files[2].status, "Added")
        XCTAssertEqual(files[2].hunks[0].lines.map(\.newNumber), [1])
        XCTAssertTrue(files[2].hunks[0].lines[0].missingNewline)
    }

    /// A removed line that starts with "-- " looks like a `---` file header; the hunk's counts
    /// must keep it in the body.
    func testBodyLinesThatLookLikeHeadersStayInTheHunk() {
        let patch = """
        --- a/query.sql
        +++ b/query.sql
        @@ -1,2 +1,2 @@
        --- old comment
        -++ odd line
        +-- new comment
        ++++ plus line
        """
        let files = ParsedDiff(patch).files
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks[0].lines.map(\.text), ["-- old comment", "++ odd line", "-- new comment", "+++ plus line"])
        XCTAssertEqual(files[0].deletions, 2)
        XCTAssertEqual(files[0].additions, 2)
    }

    func testEditedLinesEmphasizeOnlyTheChangedWords() {
        let patch = "@@ -1 +1 @@\n-let total = items.count\n+let total = items.size\n"
        let lines = ParsedDiff(patch).files[0].hunks[0].lines
        XCTAssertEqual(lines[0].emphasis, [18..<23])
        XCTAssertEqual(lines[1].emphasis, [18..<22])
    }

    func testUnrelatedLinesAreNotEmphasized() {
        let patch = "@@ -1 +1 @@\n-return cachedValue\n+throw ValidationError.missing\n"
        let lines = ParsedDiff(patch).files[0].hunks[0].lines
        XCTAssertTrue(lines[0].emphasis.isEmpty)
        XCTAssertTrue(lines[1].emphasis.isEmpty)
    }

    func testSplitRowsPairRemovalsWithAdditions() {
        let patch = "@@ -1,3 +1,2 @@\n same\n-old one\n-old two\n+new one\n"
        let rows = ParsedDiff(patch).rows(.split, expanded: [])
        let pairs: [(String?, String?)] = rows.compactMap {
            if case .pair(let old, let new, _) = $0 { return (old?.text, new?.text) }
            return nil
        }
        XCTAssertEqual(pairs.map(\.0), ["same", "old one", "old two"])
        XCTAssertEqual(pairs.map(\.1), ["same", "new one", nil])
    }

    /// With the whole new file, the unchanged lines around a hunk become expandable gaps.
    func testWholeFileAddsGapsAroundHunks() {
        let old = (1...8).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 5", with: "line five")
        let patch = "--- a/f.txt\n+++ b/f.txt\n@@ -5 +5 @@\n-line 5\n+line five\n"
        let diff = ParsedDiff(patch, old: old, new: new)
        XCTAssertEqual(diff.files[0].newLines?.count, 8)

        func gaps(_ expanded: Set<DiffGap>) -> [Int] {
            diff.rows(.unified, expanded: expanded).compactMap {
                if case .gap(_, let count) = $0 { return count }
                return nil
            }
        }
        XCTAssertEqual(gaps([]), [4, 3])
        let expanded = diff.rows(.unified, expanded: [DiffGap(file: 0, hunk: 0)])
        let before = expanded.compactMap { row -> Int? in
            if case .line(let line, _) = row, line.kind == .context { return line.oldNumber }
            return nil
        }
        XCTAssertEqual(before, [1, 2, 3, 4])
    }

    /// A file edited since the patch was taken no longer lines up, so no gaps are offered.
    func testStaleWholeFileIsIgnored() {
        let patch = "--- a/f.txt\n+++ b/f.txt\n@@ -2 +2 @@\n-b\n+B\n"
        let diff = ParsedDiff(patch, old: "a\nb\nc\n", new: "a\nchanged\nc\n")
        XCTAssertNil(diff.files[0].newLines)
    }

    func testLinesSplitCrlfLikeTheirPatch() {
        XCTAssertEqual(ParsedDiff.lines("a\r\nb\nc"), ["a", "b", "c"])
        XCTAssertEqual(ParsedDiff.lines("a\n"), ["a", ""])
    }
}

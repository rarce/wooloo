import XCTest
@testable import wooloo

/// Splits, popups and inline graphics in endpoint surface frames.
final class SurfaceLayersTests: XCTestCase {
    private let model = SurfaceModel(width: 4, height: 2)

    private func decode(_ frame: Data, with decoder: inout HerdrSurfaceDecoder) throws -> HerdrSurface {
        try XCTUnwrap(decoder.apply(frame: frame))
    }

    private func decode(_ frame: Data) throws -> HerdrSurface {
        var decoder = HerdrSurfaceDecoder()
        return try decode(frame, with: &decoder)
    }

    private func assertRejected(_ frame: Data, _ message: String = "", line: UInt = #line) {
        var decoder = HerdrSurfaceDecoder()
        XCTAssertThrowsError(try decoder.apply(frame: frame), message, line: line)
    }

    /// A frame with the given splits, popup, graphic assets, placements and retained keys.
    private func frame(splits: [HerdrSplit] = [], popup: Bool = false,
                       assets: [(GraphicKey, Data)] = [], placements: [Placement] = [],
                       retained: [GraphicKey] = []) -> Data {
        model.surfaceFrame { writer in
            writer.number(splits.count)
            for split in splits { writer.split(split) }
            if popup {
                writer.byte(1)
                writer.popup()
            } else {
                writer.byte(0)
            }
            writer.number(assets.count)
            for (key, bytes) in assets {
                writer.graphicKey(key)
                writer.blob(bytes)
            }
            writer.number(placements.count)
            for placement in placements { writer.placement(placement) }
            writer.number(retained.count)
            for key in retained { writer.graphicKey(key) }
        }
    }

    func testSplitsAreDecodedWithTheirPath() throws {
        let splits = [
            HerdrSplit(direction: .horizontal, pos: 2, area: HerdrRect(x: 0, y: 0, width: 4, height: 2),
                       hitRect: HerdrRect(x: 1, y: 0, width: 2, height: 2), path: []),
            HerdrSplit(direction: .vertical, pos: 1, area: HerdrRect(x: 2, y: 0, width: 2, height: 2),
                       hitRect: HerdrRect(x: 2, y: 1, width: 2, height: 1), path: [true, false])
        ]
        XCTAssertEqual(try decode(frame(splits: splits)).splits, splits)
    }

    func testUnknownSplitDirectionOrPathStepIsRejected() {
        let direction = model.surfaceFrame { writer in
            writer.number(1)
            writer.number(2) // neither horizontal nor vertical
            writer.number(1)
            writer.rect(HerdrRect(x: 0, y: 0, width: 1, height: 1))
            writer.rect(HerdrRect(x: 0, y: 0, width: 1, height: 1))
            writer.number(0)
            writer.byte(0); writer.number(0); writer.number(0); writer.number(0)
        }
        assertRejected(direction)

        let path = model.surfaceFrame { writer in
            writer.number(1)
            writer.number(0); writer.number(1)
            writer.rect(HerdrRect(x: 0, y: 0, width: 1, height: 1))
            writer.rect(HerdrRect(x: 0, y: 0, width: 1, height: 1))
            writer.number(1); writer.byte(2) // a path step is 0 or 1
            writer.byte(0); writer.number(0); writer.number(0); writer.number(0)
        }
        assertRejected(path)
    }

    func testPopupAndItsGraphicsRemainSeparateFromThePane() throws {
        let pane = GraphicKey.image(id: 1)
        let popup = GraphicKey.image(id: 2, isPopup: true)
        let surface = try decode(frame(popup: true,
                                       assets: [(pane, Data(count: 16)), (popup, Data(count: 16))],
                                       placements: [Placement(key: pane), Placement(key: popup)]))
        XCTAssertEqual(surface.cells, model.cells)
        XCTAssertEqual(surface.graphics.map(\.key.isPopup), [false, true])
        XCTAssertEqual(surface.popup?.terminalID, "popup-terminal")
        XCTAssertEqual(surface.popup?.cols, 1)
    }

    func testPlacementResolvesItsAssetAndFields() throws {
        let key = GraphicKey.image(id: 7)
        let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        var placement = Placement(key: key)
        placement.z = -3
        let graphic = try XCTUnwrap(decode(frame(assets: [(key, bytes)], placements: [placement])).graphics.first)
        XCTAssertEqual(graphic.data, bytes)
        XCTAssertEqual(graphic.key.width, 2)
        XCTAssertEqual(graphic.key.height, 2)
        XCTAssertEqual(graphic.key.format, .rgba)
        XCTAssertEqual([graphic.x, graphic.y, graphic.cols, graphic.rows], [1, 0, 2, 1])
        XCTAssertEqual([graphic.sourceX, graphic.sourceY, graphic.sourceWidth, graphic.sourceHeight], [0, 0, 2, 2])
        XCTAssertEqual([graphic.xOffset, graphic.yOffset], [3, 4])
        XCTAssertEqual(graphic.z, -3)
    }

    func testPaneLayerKeysAreSupported() throws {
        let key = GraphicKey.layer(pane: "w1:p1", layer: "kitty")
        let surface = try decode(frame(assets: [(key, Data(count: 16))], placements: [Placement(key: key)]))
        XCTAssertEqual(surface.graphics.count, 1)
        XCTAssertFalse(surface.graphics[0].key.isPopup)
    }

    /// Assets are sent once. Later frames reuse them while a placement or retained key names
    /// them, and they are dropped once nothing does.
    func testAssetsAreCachedWhileRetained() throws {
        let key = GraphicKey.image(id: 3)
        var decoder = HerdrSurfaceDecoder()
        _ = try decode(frame(assets: [(key, Data(count: 16))], placements: [Placement(key: key)]), with: &decoder)
        XCTAssertEqual(try decode(frame(placements: [Placement(key: key)]), with: &decoder).graphics.count, 1)
        XCTAssertEqual(try decode(frame(retained: [key]), with: &decoder).graphics.count, 0)
        XCTAssertEqual(try decode(frame(placements: [Placement(key: key)]), with: &decoder).graphics.count, 1,
                       "A retained key keeps its asset")
        _ = try decode(frame(), with: &decoder)
        XCTAssertEqual(try decode(frame(placements: [Placement(key: key)]), with: &decoder).graphics.count, 0,
                       "An asset nothing referenced is gone")
    }

    func testInvalidGraphicsAreRejected() {
        let key = GraphicKey.image(id: 1)
        assertRejected(frame(assets: [(key, Data(count: 3))]), "Length differs from the key")

        var unknownFormat = key
        unknownFormat.format = 3
        assertRejected(frame(retained: [unknownFormat]))

        var empty = key
        empty.width = 0
        assertRejected(frame(retained: [empty]))

        var outside = Placement(key: key)
        outside.sourceWidth = 3 // wider than the 2-pixel image
        assertRejected(frame(placements: [outside]))

        let unknownKind = model.surfaceFrame { writer in
            writer.number(0); writer.byte(0); writer.number(0); writer.number(0)
            writer.number(1)
            writer.number(2) // neither an image nor a pane layer
            writer.string("w1:p1"); writer.string("layer")
            for value in [2, 2, 1, 16, 0] { writer.number(value) }
        }
        assertRejected(unknownKind)
    }
}

private struct GraphicKey {
    enum Kind {
        case image(id: Int, isPopup: Bool)
        case layer(pane: String, layer: String)
    }

    var kind: Kind
    var width = 2
    var height = 2
    var format = 1 // rgba
    var dataLength = 16

    static func image(id: Int, isPopup: Bool = false) -> GraphicKey {
        GraphicKey(kind: .image(id: id, isPopup: isPopup))
    }

    static func layer(pane: String, layer: String) -> GraphicKey {
        GraphicKey(kind: .layer(pane: pane, layer: layer))
    }
}

private struct Placement {
    let key: GraphicKey
    var x = 1, y = 0, cols = 2, rows = 1
    var sourceX = 0, sourceY = 0, sourceWidth = 2, sourceHeight = 2
    var xOffset = 3, yOffset = 4
    var z = 0
}

private extension SurfaceWireWriter {
    mutating func blob(_ bytes: Data) {
        number(bytes.count)
        for value in bytes { byte(value) }
    }

    mutating func split(_ split: HerdrSplit) {
        number(split.direction == .horizontal ? 0 : 1)
        number(split.pos)
        rect(split.area)
        rect(split.hitRect)
        number(split.path.count)
        for step in split.path { byte(step ? 1 : 0) }
    }

    /// A popup with a title, both size hints and a one-cell frame of its own.
    mutating func popup() {
        string("popup-terminal")
        string("Title")
        byte(1); number(0); number(40)
        byte(1); number(1); number(50)
        number(1)
        cell(SurfaceModel.blank)
        number(1); number(1)
        cursor(nil)
        number(1); string("https://example.com")
        blob(Data([0]))
        byte(0); byte(0)
        number(320); number(200)
    }

    mutating func graphicKey(_ key: GraphicKey) {
        switch key.kind {
        case .image(let id, let isPopup):
            number(0)
            number(isPopup ? 1 : 0)
            string(isPopup ? "popup-terminal" : "w1:p1")
            number(id)
        case .layer(let pane, let layer):
            number(1)
            string(pane)
            string(layer)
        }
        number(key.width)
        number(key.height)
        number(key.format)
        number(key.dataLength)
        number(0xfeed) // fingerprint
    }

    mutating func placement(_ placement: Placement) {
        graphicKey(placement.key)
        number(1) // logical placement ID
        for value in [placement.x, placement.y, placement.cols, placement.rows,
                      placement.sourceX, placement.sourceY, placement.sourceWidth, placement.sourceHeight,
                      placement.xOffset, placement.yOffset] {
            number(value)
        }
        number(placement.z >= 0 ? placement.z * 2 : -placement.z * 2 - 1)
        number(0) // scrollback offset
    }
}

@MainActor
final class HerdrPopupTests: XCTestCase {
    private func popup(id: String = "popup-test", title: String = "Test Popup", width: HerdrPopup.Size? = .cells(12),
                       height: HerdrPopup.Size? = .cells(6), mouse: Bool = true) -> HerdrPopup {
        var row = RowBuilder(width: 9)
        row.put("POPUP", foreground: Color.ansi(2))
        return HerdrPopup(terminalID: id, title: title, width: width, height: height, cols: 9, rows: 4,
                          cells: row.cells + Array(repeating: SurfaceModel.blank, count: 27),
                          cursor: HerdrCursor(x: 2, y: 1, visible: true, shape: 0), hyperlinks: ["https://example.com"],
                          mouseReporting: mouse, pixelMouse: false, pixelWidth: 0, pixelHeight: 0)
    }

    private func frame(_ popup: HerdrPopup?, revision: UInt64 = 1) -> Data {
        var model = SurfaceModel(width: 30, height: 12)
        model.revision = revision
        return model.surfaceFrame { writer in
            writer.number(0)
            writer.popup(popup)
            writer.number(0); writer.number(0); writer.number(0)
        }
    }

    func testPopupFramesDecodeIndependentlyAndCloseReplacesTheState() throws {
        var actual = HerdrSurfaceDecoder(), reference = ReferenceSurfaceDecoder()
        for (index, value) in [popup(), popup(id: "replacement"), popup(width: .cells(0), height: .cells(0)), nil].enumerated() {
            let wire = frame(value, revision: UInt64(index + 1))
            let surface = try XCTUnwrap(actual.apply(frame: wire))
            let expected = try XCTUnwrap(reference.apply(wire))
            XCTAssertEqual(surface.popup, value)
            XCTAssertEqual(surface.contentDigest, expected.contentDigest)
            XCTAssertEqual(surface.cells, SurfaceModel(width: 30, height: 12).cells)
        }
        let wire = frame(popup())
        for count in [1, wire.count / 2, wire.count - 1] {
            var decoder = HerdrSurfaceDecoder()
            XCTAssertThrowsError(try decoder.apply(frame: wire.prefix(count)))
        }
    }

    func testGeometryMatchesHerdrAndClampsCellsAndPercentSizes() throws {
        let defaultSize = try XCTUnwrap(popup(width: nil, height: nil).geometry(cols: 100, rows: 24))
        XCTAssertEqual(defaultSize.outer, HerdrRect(x: 25, y: 6, width: 50, height: 12))
        XCTAssertEqual(defaultSize.inner, HerdrRect(x: 26, y: 7, width: 47, height: 10))
        let percent = try XCTUnwrap(popup(width: .percent(80), height: .percent(50)).geometry(cols: 100, rows: 24))
        XCTAssertEqual(percent.outer, HerdrRect(x: 10, y: 6, width: 80, height: 12))
        let small = try XCTUnwrap(popup(width: .cells(2), height: .cells(2)).geometry(cols: 6, rows: 4))
        XCTAssertEqual(small.inner, HerdrRect(x: 1, y: 1, width: 4, height: 2))
        let zero = try XCTUnwrap(popup(width: .cells(0), height: .cells(0)).geometry(cols: 30, rows: 12))
        XCTAssertEqual(zero.outer, HerdrRect(x: 12, y: 4, width: 6, height: 4))
        XCTAssertNil(popup().geometry(cols: 5, rows: 3))
    }

    private func titleWidth(_ text: String) -> Int { HerdrTitle.measure(text).width }

    private func titleClusters(_ text: String) -> [String] { HerdrTitle.measure(text).clusters }

    /// The popup's top row from corner to corner, as symbols with "·" for cells hidden behind a
    /// wide cluster.
    private func topRow(_ title: String, width: Int = 12) throws -> [String] {
        var decoder = HerdrSurfaceDecoder()
        var raw = try XCTUnwrap(decoder.apply(frame: frame(popup())))
        raw.popup = popup(title: title, width: .cells(width))
        let outer = try XCTUnwrap(raw.popup?.geometry(cols: raw.width, rows: raw.height)?.outer)
        let display = raw.displayingPopup(theme: TerminalRenderHarness.theme)
        return (outer.x..<outer.x + outer.width).map { x in
            let cell = display.cells[outer.y * display.width + x]
            return cell.skip ? "·" : cell.symbol
        }
    }

    /// The title cells, from the first cell after the corner to the cell before the close control,
    /// without the border left after the title.
    private func titleRow(_ title: String, width: Int = 12) throws -> [String] {
        var row = Array(try topRow(title, width: width).dropFirst().dropLast(2))
        while row.last == "─" { row.removeLast() }
        return row
    }

    func testPopupTitleStartsAfterTheCornerAndKeepsTheCloseControlCell() throws {
        // As in Herdr's ratatui Block, the title starts right after the corner; wooloo keeps the
        // cell before the right corner for its close button.
        XCTAssertEqual(try topRow("Ab"), ["╭", "A", "b", "─", "─", "─", "─", "─", "─", "─", " ", "╮"])
        XCTAssertEqual(try topRow("abcdefghijkl"), ["╭", "a", "b", "c", "d", "e", "f", "g", "h", "i", " ", "╮"])
    }

    func testPopupTitleGivesWideCharactersTwoCells() throws {
        XCTAssertEqual(try titleRow("Ab"), ["A", "b"])
        XCTAssertEqual(try titleRow("漢字x"), ["漢", "·", "字", "·", "x"])
        XCTAssertEqual(try titleRow("😀👍🏽🇨🇱"), ["😀", "·", "👍🏽", "·", "🇨🇱", "·"])
        XCTAssertEqual(try titleRow("ｗ☺\u{FE0F}"), ["ｗ", "·", "☺\u{FE0F}", "·"])
    }

    func testPopupTitleAddsZeroWidthClustersToTheCellBeforeAndLeavesOutControls() throws {
        XCTAssertEqual(try titleRow("e\u{301}a"), ["e\u{301}", "a"])
        XCTAssertEqual(try titleRow("a\u{200B}b"), ["a\u{200B}", "b"])
        // The tab is left out but still counts toward the title's width (three cells).
        XCTAssertEqual(try topRow("a\u{200B}\tb").prefix(5), ["╭", "a\u{200B}", "b", "─", "─"])
        XCTAssertEqual(HerdrTitle.cells(of: "a\u{200B}\tb", room: 9).count, 3)
        // After a wide cluster, a zero-width one joins the hidden cell, as in ratatui.
        XCTAssertEqual(HerdrTitle.cells(of: "漢\u{200B}a", room: 9),
                       [.init(symbol: "漢"), .init(symbol: "\u{200B}", covered: true), .init(symbol: "a")])
    }

    func testPopupTitleLeavesOutAZeroWidthClusterWithNoCellBefore() throws {
        // ratatui would give it the first cell for the next cluster to join, a combining mark with
        // no base; wooloo leaves it out instead, and joins one that starts a later line to the
        // cell before.
        XCTAssertEqual(try titleRow("\u{301}abc"), ["a", "b", "c"])
        XCTAssertEqual(try titleRow("\u{301}a\u{200B}\tb"), ["a\u{200B}", "b"])
        XCTAssertEqual(try titleRow("\u{200B}漢"), ["漢", "·"])
        XCTAssertEqual(try titleRow("a\n\u{301}b"), ["a\u{301}", "b"])
        XCTAssertEqual(try titleRow("\u{200B}\u{301}"), [])
    }

    func testPopupTitleKeepsLineSeparatorsAndRemovesLineBreaks() throws {
        XCTAssertEqual(try titleRow("\u{2028}a\u{2029}"), ["\u{2028}", "a", "\u{2029}"])
        XCTAssertEqual(try titleRow("a\nb"), ["a", "b"])
        XCTAssertEqual(try titleRow("a\r\nb\n"), ["a", "b"])
    }

    func testPopupTitleIsClippedToItsStringWidthLikeRatatui() throws {
        // Lam-alef is one cell as a string, so "سلام" gets three cells and loses its last letter.
        XCTAssertEqual(titleWidth("سلام"), 3)
        XCTAssertEqual(titleClusters("سلام").map(titleWidth), [1, 1, 1, 1])
        XCTAssertEqual(try titleRow("سلام"), ["س", "ل", "ا"])
        XCTAssertEqual(try titleRow("لاab"), ["ل", "ا", "a"])
    }

    func testPopupTitleJoinsConjunctsAsHerdrsSegmentationDoes() throws {
        // unicode-segmentation 1.13 (Unicode 17) joins conjuncts in Khmer and other scripts.
        XCTAssertEqual(titleClusters("ក្ក"), ["ក្ក"])
        XCTAssertEqual(titleClusters("ក្ខ្គa"), ["ក្ខ្គ", "a"])
        XCTAssertEqual(titleClusters("क्षि"), ["क्षि"])
        XCTAssertEqual(titleWidth("ក្ក"), 1)
        XCTAssertEqual(titleWidth("ក្ខ្គ"), 1)
        XCTAssertEqual(titleWidth("क्ष"), 2)
        XCTAssertEqual(try titleRow("ក្ខ្គa"), ["ក្ខ្គ", "a"])
        // Kirat Rai vowel signs are Hangul-like vowels in Unicode 17 and form one cluster.
        XCTAssertEqual(titleClusters("\u{16D63}\u{16D67}"), ["\u{16D63}\u{16D67}"])
        XCTAssertEqual(titleWidth("\u{16D63}\u{16D67}"), 1)
        XCTAssertEqual(titleWidth("\u{16D63}\u{16D67}\u{16D67}"), 1)
        XCTAssertEqual(titleWidth("\u{16D63}\u{16D68}"), 1)
    }

    func testPopupTitleStopsBeforeAWideCharacterThatWouldReachTheCloseControl() throws {
        // Nine title cells: four wide characters fill eight, the fifth does not fit in one.
        XCTAssertEqual(try titleRow("漢字漢字漢"), ["漢", "·", "字", "·", "漢", "·", "字", "·"])
        XCTAssertEqual(try titleRow("abcdefghij"), ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
    }

    func testPopupTitleHandlesEmptyTitlesAndTheNarrowestPopups() throws {
        XCTAssertEqual(try titleRow(""), [])
        // A six-cell popup has three title cells.
        XCTAssertEqual(try titleRow("漢漢", width: 6), ["漢", "·"], "the second wide character does not fit")
        XCTAssertEqual(try titleRow("a漢b", width: 6), ["a", "漢", "·"])
    }

    func testPopupTitleRepeatsTheLastLayoutForTheSameTitleAndRoom() {
        let first = HerdrTitle.cells(of: "漢a", room: 9)
        XCTAssertEqual(HerdrTitle.cells(of: "漢a", room: 9), first)
        XCTAssertEqual(HerdrTitle.cells(of: "漢a", room: 2), [.init(symbol: "漢"), .init(symbol: "", covered: true)])
        XCTAssertEqual(HerdrTitle.cells(of: "a漢", room: 9).first, .init(symbol: "a"))
    }

    func testPopupTitleGivesSkinTonedTextDefaultEmojiTwoCells() throws {
        XCTAssertEqual(try titleRow("✌\u{1F3FB}✌"), ["✌\u{1F3FB}", "·", "✌"])
    }

    /// Expected widths come from `unicode-width` 0.2.2 per grapheme cluster, as ratatui-core 0.1.0
    /// (bundled Herdr) draws popup titles.
    func testPopupTitleClusterWidthsMatchHerdrsUnicodeWidth() {
        let cases: [(String, Int, String)] = [
            ("\u{1F1E6}", 1, "a lone regional indicator"),
            ("\u{1F1E8}\u{1F1F1}", 2, "a flag"),
            ("😀\u{FE0E}", 2, "U+FE0E after an emoji without a text variation"),
            ("🈁\u{FE0E}", 2, "U+FE0E in the Enclosed Ideographic Supplement"),
            ("⌚\u{FE0E}", 1, "U+FE0E after an emoji with a text variation"),
            ("❤\u{FE0E}", 1, "U+FE0E after a text-default emoji"),
            ("1\u{20E3}", 1, "a keycap without U+FE0F"),
            ("1\u{FE0F}\u{20E3}", 2, "a keycap"),
            ("🏳\u{200D}🌈", 3, "a ZWJ sequence without U+FE0F"),
            ("🏳\u{FE0F}\u{200D}🌈", 2, "a ZWJ sequence"),
            ("👨\u{200D}👩\u{200D}👧", 2, "a family"),
            ("👍\u{1F3FD}", 2, "a skin tone"),
            ("✌\u{1F3FB}", 2, "a skin tone on a text-default emoji"),
            ("\u{FF76}\u{FF9E}", 1, "halfwidth kana with a sound mark (ratatui-core 0.1.2 gives 2)"),
            ("ก\u{0E33}", 2, "Thai SARA AM after a consonant"),
            ("\u{0E33}", 1, "a lone SARA AM"),
            ("\u{0915}\u{093E}", 2, "a Devanagari spacing mark"),
            ("\u{1161}", 0, "a lone Hangul vowel"),
            ("\u{11A8}", 0, "a lone Hangul trailing consonant"),
            ("\u{1100}\u{1161}\u{11A8}", 2, "a Hangul syllable of jamo"),
            ("\u{17D8}", 3, "Khmer sign beyyal"),
            ("\u{2018}\u{FE01}", 2, "a quote with U+FE01"),
            ("\u{4DC0}", 2, "a hexagram"),
            ("\u{00AD}", 0, "a soft hyphen"),
            ("\u{0600}1", 2, "a prepended number sign"),
            ("\u{2028}", 1, "a line separator"), ("e\u{301}", 1, "a combining mark"), ("漢", 2, "CJK"),
            // Emoji newer than some supported macOS versions, from the crate's tables.
            ("\u{1FAE9}", 2, "Unicode 16 face with bags under eyes"), ("\u{1FAEA}", 2, "a Unicode 17 emoji"),
        ]
        for (text, width, label) in cases {
            XCTAssertEqual(titleClusters(text), [text], label)
            XCTAssertEqual(titleWidth(text), width, label)
        }
        XCTAssertEqual(titleWidth("\t"), 1, "a control counts in a string width")
        XCTAssertEqual(titleWidth("\r\n"), 1)
        // The editor keeps its own widths for clusters it draws as one glyph.
        XCTAssertEqual(DisplayColumns.width(of: "\u{1F1E6}", at: 0, tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.width(of: "1\u{20E3}", at: 0, tabWidth: 4), 2)
        XCTAssertEqual(DisplayColumns.width(of: "🏳\u{200D}🌈", at: 0, tabWidth: 4), 2)
    }

    func testPopupTitleGivesClustersHerdrsCells() throws {
        XCTAssertEqual(try titleRow("\u{1F1E6}1\u{20E3}a"), ["\u{1F1E6}", "1\u{20E3}", "a"])
        XCTAssertEqual(try titleRow("🏳\u{200D}🌈😀\u{FE0E}"), ["🏳\u{200D}🌈", "·", "·", "😀\u{FE0E}", "·"])
        XCTAssertEqual(try titleRow("ก\u{0E33}\u{1161}x"), ["ก\u{0E33}", "·", "x"])
    }

    func testCompositionMovesCursorAndRestrictsSelectionToPopupContent() throws {
        var decoder = HerdrSurfaceDecoder()
        let raw = try XCTUnwrap(decoder.apply(frame: frame(popup())))
        let display = raw.displayingPopup(theme: TerminalRenderHarness.theme)
        let inner = try XCTUnwrap(raw.popup?.geometry(cols: raw.width, rows: raw.height)?.inner)
        XCTAssertEqual(display.cells[inner.y * display.width + inner.x].symbol, "P")
        XCTAssertEqual(display.cursor?.x, inner.x + 2)
        XCTAssertEqual(display.cursor?.y, inner.y + 1)
        XCTAssertNotEqual(display.cells, raw.cells)
        let view = TerminalRenderHarness.makeView(width: raw.width, height: raw.height)
        view.show(raw)
        view.selectAll(nil)
        let text = try XCTUnwrap(view.selectedCellText())
        XCTAssertTrue(text.contains("POPUP"))
        XCTAssertFalse(text.contains("Test Popup"))
        XCTAssertFalse(text.contains("╭"))
        let shown = TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(raw))
        let closed = TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(SurfaceModel(width: 30, height: 12).surface))
        XCTAssertNotEqual(shown?.bytes, closed?.bytes)
        view.show(nil)
        XCTAssertNil(view.surface)
        XCTAssertNil(view.terminalGrid)
    }

    func testKeyboardImeMouseAndCloseStayOnPopupAndPaneResumesAfterClose() throws {
        var decoder = HerdrSurfaceDecoder()
        let raw = try XCTUnwrap(decoder.apply(frame: frame(popup())))
        let view = TerminalRenderHarness.makeView(width: raw.width, height: raw.height)
        var popupEvents: [HerdrInputEvent] = [], paneEvents = 0, shortcuts = 0, closes = 0
        view.sendPopupInput = { event, id, boot in
            XCTAssertEqual(id, "popup-test"); XCTAssertEqual(boot, "boot-test")
            popupEvents.append(event)
        }
        view.sendText = { _, _ in paneEvents += 1 }
        view.sendKey = { _, _ in paneEvents += 1 }
        view.selectPane = { _ in paneEvents += 1 }
        view.setSplitRatio = { _, _ in paneEvents += 1 }
        view.onShortcut = { _ in shortcuts += 1 }
        view.closePopup = { id, _ in XCTAssertEqual(id, "popup-test"); closes += 1 }
        view.show(raw)
        view.insertText("IME 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        let prefix = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{2}",
                                                   charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        view.keyDown(with: prefix)
        let inner = try XCTUnwrap(raw.popup?.geometry(cols: raw.width, rows: raw.height)?.inner)
        let location = NSPoint(x: view.textContainerInset.width + CGFloat(inner.x + 1) * TerminalPaneView.cellWidth,
                               y: view.textContainerInset.height + CGFloat(inner.y + 1) * TerminalPaneView.cellHeight)
        XCTAssertTrue(view.scrollPane(at: location, deltaX: 0, deltaY: 3, precise: false, modifiers: []))
        XCTAssertTrue(view.scrollPane(at: .zero, deltaX: 0, deltaY: 3, precise: false, modifiers: []))
        XCTAssertEqual(paneEvents, 0)
        XCTAssertEqual(shortcuts, 0)
        XCTAssertEqual(closes, 0, "Escape belongs to the terminal program")
        XCTAssertEqual(popupEvents.count, 4)
        if case .key("esc") = popupEvents[1] {} else { XCTFail("Escape was not forwarded") }
        let menu = try XCTUnwrap(view.menu(for: escape))
        let close = try XCTUnwrap(menu.items.first { $0.title == "Close Popup" })
        _ = view.perform(try XCTUnwrap(close.action), with: close)
        XCTAssertEqual(closes, 1)
        view.show(SurfaceModel(width: 30, height: 12).surface)
        view.insertText("pane", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(paneEvents, 1)
    }

    func testPopupInputUsesItsOwnWireTagAndStableTerminalID() throws {
        let popup = try XCTUnwrap(SurfaceWriter.popupInput(terminalID: "popup-id", event: .key("esc")))
        let pane = try XCTUnwrap(SurfaceWriter.paneInput(paneID: "popup-id", event: .key("esc")))
        XCTAssertEqual(popup.first, 14)
        XCTAssertEqual(pane.first, 13)
        XCTAssertEqual(popup.dropFirst(), pane.dropFirst())
    }

    func testGraphicsAreClippedToTheMatchingPopupAndOccludePaneImages() throws {
        var decoder = HerdrSurfaceDecoder()
        var surface = try XCTUnwrap(decoder.apply(frame: frame(popup())))
        let plain = TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(surface))?.bytes
        func image(popupID: String?, x: Int = 0, y: Int = 0) -> HerdrGraphic {
            let key = HerdrGraphicKey(identity: Data([1]), width: 1, height: 1, format: .rgb,
                                      isPopup: popupID != nil, dataLength: 3, popupTerminalID: popupID)
            return HerdrGraphic(key: key, data: Data([255, 0, 0]), x: x, y: y, cols: 2, rows: 1,
                                sourceX: 0, sourceY: 0, sourceWidth: 1, sourceHeight: 1,
                                xOffset: 0, yOffset: 0, z: 0)
        }
        surface.graphics = [image(popupID: "old-popup")]
        XCTAssertEqual(TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(surface))?.bytes, plain)
        surface.graphics = [image(popupID: "popup-test")]
        XCTAssertNotEqual(TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(surface))?.bytes, plain)
        let inner = try XCTUnwrap(surface.popup?.geometry(cols: surface.width, rows: surface.height)?.inner)
        surface.graphics = [image(popupID: nil, x: inner.x, y: inner.y)]
        XCTAssertEqual(TerminalRenderHarness.pixels(of: TerminalRenderHarness.render(surface))?.bytes, plain)
    }
}

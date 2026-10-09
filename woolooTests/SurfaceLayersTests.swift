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

    /// The title row from the first title cell to the close control, as symbols with "·" for the
    /// trailing half of a wide character.
    private func titleRow(_ title: String, width: Int = 12) throws -> [String] {
        var decoder = HerdrSurfaceDecoder()
        var raw = try XCTUnwrap(decoder.apply(frame: frame(popup())))
        raw.popup = popup(title: title, width: .cells(width))
        let outer = try XCTUnwrap(raw.popup?.geometry(cols: raw.width, rows: raw.height)?.outer)
        let display = raw.displayingPopup(theme: TerminalRenderHarness.theme)
        return (outer.x + 2..<outer.x + outer.width - 2).map { x in
            let cell = display.cells[outer.y * display.width + x]
            return cell.skip ? "·" : cell.symbol
        }
    }

    func testPopupTitleGivesWideCharactersTwoCells() throws {
        XCTAssertEqual(try titleRow("Ab"), ["A", "b", "─", "─", "─", "─", "─", "─"])
        XCTAssertEqual(try titleRow("漢字x"), ["漢", "·", "字", "·", "x", "─", "─", "─"])
        XCTAssertEqual(try titleRow("😀👍🏽🇨🇱"), ["😀", "·", "👍🏽", "·", "🇨🇱", "·", "─", "─"])
        XCTAssertEqual(try titleRow("ｗ☺\u{FE0F}"), ["ｗ", "·", "☺\u{FE0F}", "·", "─", "─", "─", "─"])
    }

    func testPopupTitleKeepsCombiningMarksInTheirCellAndDropsZeroWidthCharacters() throws {
        XCTAssertEqual(try titleRow("e\u{301}a"), ["e\u{301}", "a", "─", "─", "─", "─", "─", "─"])
        XCTAssertEqual(try titleRow("\u{301}a\u{200B}\tb"), ["a", "b", "─", "─", "─", "─", "─", "─"])
    }

    func testPopupTitleStopsBeforeAWideCharacterThatWouldReachTheCloseControl() throws {
        // Seven title cells: three wide characters fill six, the fourth does not fit in one.
        XCTAssertEqual(try titleRow("漢字漢字", width: 12), ["漢", "·", "字", "·", "漢", "·", "─", "─"])
        XCTAssertEqual(try titleRow("abcdefghij", width: 12), ["a", "b", "c", "d", "e", "f", "g", "─"])
    }

    func testPopupTitleHandlesEmptyTitlesAndPopupsWithRoomForOneTitleCell() throws {
        XCTAssertEqual(try titleRow(""), ["─", "─", "─", "─", "─", "─", "─", "─"])
        XCTAssertEqual(try titleRow("\u{200B}\u{301}"), ["─", "─", "─", "─", "─", "─", "─", "─"])
        // One title cell, then the border cell kept before the close control.
        XCTAssertEqual(try titleRow("漢a", width: 6), ["─", "─"], "a wide first character does not fit")
        XCTAssertEqual(try titleRow("a漢", width: 6), ["a", "─"])
    }

    func testPopupTitleGivesSkinTonedTextDefaultEmojiTwoCells() throws {
        XCTAssertEqual(try titleRow("✌\u{1F3FB}✌"), ["✌\u{1F3FB}", "·", "✌", "─", "─", "─", "─", "─"])
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

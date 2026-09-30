import XCTest
@testable import xherdr

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

    /// A popup is read past, including its own cells, so the rest of the frame still decodes;
    /// graphics that belong to the popup are not shown in the pane.
    func testPopupIsSkippedAndItsGraphicsAreHidden() throws {
        let pane = GraphicKey.image(id: 1)
        let popup = GraphicKey.image(id: 2, isPopup: true)
        let surface = try decode(frame(popup: true,
                                       assets: [(pane, Data(count: 16)), (popup, Data(count: 16))],
                                       placements: [Placement(key: pane), Placement(key: popup)]))
        XCTAssertEqual(surface.cells, model.cells)
        XCTAssertEqual(surface.graphics.map(\.key.isPopup), [false])
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
            string("w1:p1")
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

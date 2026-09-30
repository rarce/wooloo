import Foundation
@testable import xherdr

/// A deliberately plain decoder for Herdr's surface and patch frames, kept separate from the
/// app's reader. It is the oracle for "no information lost": whatever the app's pipeline
/// optimizes, the screen it shows for a revision must match what this decoder produces.
/// Graphics assets are parsed but only placements' identities are kept.
struct ReferenceSurfaceDecoder {
    enum Failure: Error { case truncated, invalid(String), noBaseSurface, staleBase }

    private(set) var surface: HerdrSurface?
    private var assets: [Data: Data] = [:]

    /// Applies a tag 13 or 19 frame; returns nil for any other tag.
    mutating func apply(_ frame: Data) throws -> HerdrSurface? {
        var input = Input(bytes: [UInt8](frame))
        switch try input.number() {
        case 13:
            surface = try readSurface(&input)
        case 19:
            guard var current = surface else { throw Failure.noBaseSurface }
            try readPatch(&input, into: &current)
            surface = current
        default:
            return nil
        }
        return surface
    }

    private struct Input {
        let bytes: [UInt8]
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.truncated }
            offset += 1
            return bytes[offset - 1]
        }

        mutating func number() throws -> UInt64 {
            let tag = try byte()
            let width: Int
            switch tag {
            case 0..<251: return UInt64(tag)
            case 251: width = 2
            case 252: width = 4
            case 253: width = 8
            default: throw Failure.invalid("varint tag \(tag)")
            }
            var value: UInt64 = 0
            for index in 0..<width { value |= UInt64(try byte()) << UInt64(8 * index) }
            return value
        }

        mutating func int() throws -> Int { Int(try number()) }

        mutating func raw() throws -> [UInt8] {
            let count = try int()
            guard offset + count <= bytes.count else { throw Failure.truncated }
            offset += count
            return Array(bytes[(offset - count)..<offset])
        }

        mutating func text() throws -> String {
            guard let value = String(bytes: try raw(), encoding: .utf8) else { throw Failure.invalid("utf8") }
            return value
        }

        mutating func flag() throws -> Bool {
            switch try byte() {
            case 0: return false
            case 1: return true
            case let other: throw Failure.invalid("bool \(other)")
            }
        }

        mutating func rect() throws -> HerdrRect {
            HerdrRect(x: try int(), y: try int(), width: try int(), height: try int())
        }

        mutating func cell() throws -> HerdrCell {
            let symbol = try text()
            let foreground = UInt32(try number())
            let background = UInt32(try number())
            let modifier = UInt16(try number())
            let skip = try byte() != 0
            let hyperlink = try flag() ? UInt32(try number()) : nil
            return HerdrCell(symbol: symbol, foreground: foreground, background: background, modifier: modifier, skip: skip,
                             hyperlink: hyperlink)
        }

        mutating func cursor() throws -> HerdrCursor? {
            guard try flag() else { return nil }
            let x = try int(), y = try int()
            let visible = try byte() != 0
            return HerdrCursor(x: x, y: y, visible: visible, shape: try byte())
        }

        struct Pane {
            let id: String
            let rect: HerdrRect
            let inner: HerdrRect
            let mouseReporting: Bool
        }

        mutating func pane() throws -> Pane {
            let id = try text()
            _ = try number() // content revision
            let outer = try rect(), inner = try rect()
            if try flag() { _ = try rect() }
            if try flag() { for _ in 0..<3 { _ = try number() } }
            _ = try byte() // focused
            let mouseReporting = try byte() != 0
            _ = try byte(); _ = try byte()
            _ = try number(); _ = try number()
            return Pane(id: id, rect: outer, inner: inner, mouseReporting: mouseReporting)
        }

        mutating func graphicKey() throws -> (identity: Data, isPopup: Bool) {
            let start = offset
            var isPopup = false
            switch try number() {
            case 0:
                isPopup = try number() == 1
                _ = try text(); _ = try number()
            case 1:
                _ = try text(); _ = try text()
            case let other:
                throw Failure.invalid("graphic key \(other)")
            }
            for _ in 0..<5 { _ = try number() } // width, height, format, length, fingerprint
            return (Data(bytes[start..<offset]), isPopup)
        }

        mutating func skipPopup() throws {
            _ = try text(); _ = try text()
            for _ in 0..<2 {
                if try flag() { _ = try number(); _ = try number() } // size constraint kind and value
            }
            for _ in 0..<(try int()) { _ = try cell() }
            _ = try number(); _ = try number()
            _ = try cursor()
            for _ in 0..<(try int()) { _ = try text() }
            _ = try raw()
            _ = try byte(); _ = try byte()
            _ = try number(); _ = try number()
        }
    }

    private mutating func readSurface(_ input: inout Input) throws -> HerdrSurface {
        let bootID = try input.text()
        let projectionRevision = try input.number()
        let revision = try input.number()
        let cellCount = try input.int()
        var cells: [HerdrCell] = []
        for _ in 0..<cellCount { cells.append(try input.cell()) }
        let width = try input.int(), height = try input.int()
        guard width * height == cellCount else { throw Failure.invalid("cell count") }
        let cursor = try input.cursor()
        var hyperlinks: [String] = []
        for _ in 0..<(try input.int()) { hyperlinks.append(try input.text()) }
        _ = try input.raw() // legacy graphics bytes
        var paneIDs: [String] = []
        var rects: [String: HerdrRect] = [:], inner: [String: HerdrRect] = [:]
        var mouse: Set<String> = []
        for _ in 0..<(try input.int()) {
            let pane = try input.pane()
            paneIDs.append(pane.id)
            rects[pane.id] = pane.rect
            inner[pane.id] = pane.inner
            if pane.mouseReporting { mouse.insert(pane.id) }
        }
        var splits: [HerdrSplit] = []
        for _ in 0..<(try input.int()) {
            let direction: HerdrSplit.Direction = try input.number() == 0 ? .horizontal : .vertical
            let pos = try input.int()
            let area = try input.rect(), hit = try input.rect()
            var path: [Bool] = []
            for _ in 0..<(try input.int()) { path.append(try input.flag()) }
            splits.append(HerdrSplit(direction: direction, pos: pos, area: area, hitRect: hit, path: path))
        }
        if try input.flag() { try input.skipPopup() }
        for _ in 0..<(try input.int()) {
            let key = try input.graphicKey()
            assets[key.identity] = Data(try input.raw())
        }
        var graphics: [HerdrGraphic] = []
        var keep = Set<Data>()
        for _ in 0..<(try input.int()) {
            let key = try input.graphicKey()
            _ = try input.number() // placement ID
            var values: [Int] = []
            for _ in 0..<10 { values.append(try input.int()) }
            let encodedZ = try input.number()
            let z = encodedZ & 1 == 0 ? Int(encodedZ / 2) : -Int(encodedZ / 2) - 1
            _ = try input.number() // scrollback offset
            keep.insert(key.identity)
            guard !key.isPopup, let bytes = assets[key.identity] else { continue }
            let graphicKey = HerdrGraphicKey(identity: key.identity, width: 0, height: 0, format: .png,
                                             isPopup: false, dataLength: bytes.count)
            graphics.append(HerdrGraphic(key: graphicKey, data: bytes, x: values[0], y: values[1],
                                         cols: values[2], rows: values[3], sourceX: values[4], sourceY: values[5],
                                         sourceWidth: values[6], sourceHeight: values[7],
                                         xOffset: values[8], yOffset: values[9], z: z))
        }
        for _ in 0..<(try input.int()) { keep.insert(try input.graphicKey().identity) }
        assets = assets.filter { keep.contains($0.key) }
        return HerdrSurface(bootID: bootID, projectionRevision: projectionRevision, revision: revision,
                            width: width, height: height, cells: cells, cursor: cursor, paneIDs: paneIDs,
                            paneRects: rects, paneInnerRects: inner, mouseReportingPaneIDs: mouse,
                            splits: splits, graphics: graphics, hyperlinks: hyperlinks)
    }

    private func readPatch(_ input: inout Input, into surface: inout HerdrSurface) throws {
        let bootID = try input.text()
        let projectionRevision = try input.number()
        let base = try input.number()
        let revision = try input.number()
        guard bootID == surface.bootID, projectionRevision == surface.projectionRevision,
              base == surface.revision else { throw Failure.staleBase }
        for _ in 0..<(try input.int()) {
            let x = try input.int(), y = try input.int(), length = try input.int()
            guard y < surface.height, x + length <= surface.width else { throw Failure.invalid("run bounds") }
            for offset in 0..<length { surface.cells[y * surface.width + x + offset] = try input.cell() }
        }
        for _ in 0..<(try input.int()) {
            let pane = try input.pane()
            surface.paneRects[pane.id] = pane.rect
            surface.paneInnerRects[pane.id] = pane.inner
            if pane.mouseReporting {
                surface.mouseReportingPaneIDs.insert(pane.id)
            } else {
                surface.mouseReportingPaneIDs.remove(pane.id)
            }
        }
        surface.cursor = try input.cursor()
        surface.revision = revision
    }
}

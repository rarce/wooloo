import AppKit
import Darwin
import Foundation

struct HerdrCell: Hashable {
    let symbol: String
    let foreground: UInt32
    let background: UInt32
    let modifier: UInt16
    let skip: Bool
    /// Index into the surface's `hyperlinks`, for text an OSC 8 hyperlink covers.
    var hyperlink: UInt32? = nil
}

struct HerdrCursor: Equatable {
    let x: Int
    let y: Int
    let visible: Bool
    let shape: UInt8
}

struct HerdrSplit: Equatable {
    enum Direction: Equatable {
        case horizontal
        case vertical
    }

    let direction: Direction
    let pos: Int
    let area: HerdrRect
    let hitRect: HerdrRect
    let path: [Bool]
}

struct HerdrGraphicKey: Hashable {
    enum Format: UInt64 {
        case rgb = 0
        case rgba = 1
        case png = 2
    }

    let identity: Data
    let width: Int
    let height: Int
    let format: Format
    let isPopup: Bool
    let dataLength: Int
    var popupTerminalID: String? = nil
}

struct HerdrPopup: Equatable {
    enum Size: Equatable { case cells(Int), percent(Int) }
    let terminalID: String
    let title: String
    let width: Size?
    let height: Size?
    let cols: Int
    let rows: Int
    let cells: [HerdrCell]
    let cursor: HerdrCursor?
    let hyperlinks: [String]
    let mouseReporting: Bool
    let pixelMouse: Bool
    let pixelWidth: Int
    let pixelHeight: Int

    /// Matches Herdr's popup_size::resolve_popup_geometry, including its right gutter.
    func geometry(cols: Int, rows: Int) -> (outer: HerdrRect, inner: HerdrRect)? {
        func resolve(_ size: Size?, available: Int, minimum: Int) -> Int {
            let value: Int
            switch size {
            case .cells(let cells): value = cells
            case .percent(let percent): value = available * percent / 100
            case nil: value = available / 2
            }
            return min(available, max(minimum, value))
        }
        let width = resolve(width, available: cols, minimum: 6)
        let height = resolve(height, available: rows, minimum: 4)
        guard width >= 6, height >= 4 else { return nil }
        let outer = HerdrRect(x: (cols - width) / 2, y: (rows - height) / 2, width: width, height: height)
        let innerWidth = width - 2
        return (outer, HerdrRect(x: outer.x + 1, y: outer.y + 1,
                                width: innerWidth > 4 ? innerWidth - 1 : innerWidth, height: height - 2))
    }
}

extension HerdrRect {
    func contains(column: Int, row: Int) -> Bool {
        column >= x && row >= y && column < x + width && row < y + height
    }
}

struct HerdrGraphic: Equatable {
    let key: HerdrGraphicKey
    let data: Data
    let x: Int
    let y: Int
    let cols: Int
    let rows: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let xOffset: Int
    let yOffset: Int
    let z: Int
}

private struct HerdrGraphicPlacement {
    let key: HerdrGraphicKey
    let x: Int
    let y: Int
    let cols: Int
    let rows: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let xOffset: Int
    let yOffset: Int
    let z: Int

    func resolved(with data: Data) -> HerdrGraphic {
        HerdrGraphic(key: key, data: data, x: x, y: y, cols: cols, rows: rows,
                     sourceX: sourceX, sourceY: sourceY,
                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                     xOffset: xOffset, yOffset: yOffset, z: z)
    }
}

struct HerdrSurface: Equatable {
    let bootID: String
    let projectionRevision: UInt64
    var revision: UInt64
    let width: Int
    let height: Int
    var cells: [HerdrCell]
    var cursor: HerdrCursor?
    let paneIDs: [String]
    var paneRects: [String: HerdrRect]
    var paneInnerRects: [String: HerdrRect]
    var mouseReportingPaneIDs: Set<String>
    let splits: [HerdrSplit]
    var graphics: [HerdrGraphic]
    /// OSC 8 hyperlink URIs of a complete surface. Herdr sends a complete surface instead of a
    /// patch whenever changed cells touch a hyperlink, so patches keep these indices valid.
    var hyperlinks: [String] = []
    var popup: HerdrPopup? = nil

    /// The raw surface stays intact for patches and trace verification. Only the view
    /// composes popup chrome and cells into the grid it draws.
    func displayingPopup(theme: XherdrTheme) -> HerdrSurface {
        guard let popup, let geometry = popup.geometry(cols: width, rows: height) else { return self }
        var result = self
        let outer = geometry.outer, inner = geometry.inner
        let panel = UInt32(0x02000000) | theme.herdr.panel
        let accent = UInt32(0x02000000) | theme.herdr.accent
        func cell(_ symbol: String) -> HerdrCell {
            HerdrCell(symbol: symbol, foreground: accent, background: panel, modifier: 0, skip: false)
        }
        for y in outer.y..<(outer.y + outer.height) {
            for x in outer.x..<(outer.x + outer.width) {
                let top = y == outer.y, bottom = y == outer.y + outer.height - 1
                let left = x == outer.x, right = x == outer.x + outer.width - 1
                let symbol = top ? (left ? "╭" : right ? "╮" : "─")
                    : bottom ? (left ? "╰" : right ? "╯" : "─") : (left || right ? "│" : " ")
                result.cells[y * width + x] = cell(symbol)
            }
        }
        // Keep title glyphs inside the border and leave the close control at the right.
        var x = outer.x + 2
        for character in popup.title where !character.isNewline {
            let symbol = String(character)
            let scalarWidth = symbol.unicodeScalars.map { wcwidth(wchar_t($0.value)) }.max() ?? 1
            let span = max(1, Int(scalarWidth))
            guard x + span <= outer.x + outer.width - 3 else { break }
            result.cells[outer.y * width + x] = cell(symbol)
            if span == 2 { result.cells[outer.y * width + x + 1] = HerdrCell(symbol: "", foreground: accent, background: panel, modifier: 0, skip: true) }
            x += span
        }
        result.cells[outer.y * width + outer.x + outer.width - 2] = cell(" ")
        let linkOffset = result.hyperlinks.count
        result.hyperlinks += popup.hyperlinks
        for y in 0..<min(inner.height, popup.rows) {
            for x in 0..<min(inner.width, popup.cols) {
                var value = popup.cells[y * popup.cols + x]
                if let link = value.hyperlink {
                    value.hyperlink = Int(link) < popup.hyperlinks.count ? UInt32(linkOffset + Int(link)) : nil
                }
                result.cells[(inner.y + y) * width + inner.x + x] = value
            }
        }
        result.cursor = popup.cursor.flatMap { cursor in
            guard cursor.x < inner.width, cursor.y < inner.height else { return nil }
            return HerdrCursor(x: inner.x + cursor.x, y: inner.y + cursor.y, visible: cursor.visible, shape: cursor.shape)
        }
        return result
    }
}

private enum SurfaceProtocolError: Error {
    case invalidFrame
    case unexpectedEnd
    case incompatible(String)
}

private struct SurfaceReader {
    let bytes: [UInt8]
    var position = 0

    init(_ data: Data) { bytes = Array(data) }

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw SurfaceProtocolError.unexpectedEnd }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func number() throws -> UInt64 {
        let tag = try byte()
        if tag < 251 { return UInt64(tag) }
        let count: Int
        switch tag {
        case 251: count = 2
        case 252: count = 4
        case 253: count = 8
        default: throw SurfaceProtocolError.invalidFrame
        }
        guard position + count <= bytes.count else { throw SurfaceProtocolError.unexpectedEnd }
        var value: UInt64 = 0
        for offset in 0..<count { value |= UInt64(bytes[position + offset]) << (offset * 8) }
        position += count
        return value
    }

    /// Single ASCII characters, which most cells hold, without decoding each one again.
    private static let asciiStrings = (0..<128).map { String(UnicodeScalar(UInt8($0))) }

    mutating func string() throws -> String {
        let length = try Int(number())
        guard length <= 8_000_000, position + length <= bytes.count else { throw SurfaceProtocolError.invalidFrame }
        if length == 1, bytes[position] < 128 {
            position += 1
            return Self.asciiStrings[Int(bytes[position - 1])]
        }
        defer { position += length }
        guard let value = String(bytes: bytes[position..<(position + length)], encoding: .utf8) else {
            throw SurfaceProtocolError.invalidFrame
        }
        return value
    }

    mutating func count() throws -> Int {
        let value = try number()
        guard value <= 1_000_000 else { throw SurfaceProtocolError.invalidFrame }
        return Int(value)
    }

    mutating func data(maximum: Int = 32 * 1024 * 1024) throws -> Data {
        let length = try number()
        guard length <= maximum, length <= bytes.count - position else { throw SurfaceProtocolError.invalidFrame }
        let result = Data(bytes[position..<(position + Int(length))])
        position += Int(length)
        return result
    }

    mutating func signedNumber() throws -> Int {
        let encoded = try number()
        guard encoded <= UInt64(Int.max) else { throw SurfaceProtocolError.invalidFrame }
        return encoded & 1 == 0 ? Int(encoded / 2) : -Int(encoded / 2) - 1
    }

    mutating func optional<T>(_ read: (inout SurfaceReader) throws -> T) throws -> T? {
        switch try byte() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw SurfaceProtocolError.invalidFrame
        }
    }

    mutating func rect() throws -> HerdrRect {
        HerdrRect(x: try Int(number()), y: try Int(number()),
                  width: try Int(number()), height: try Int(number()))
    }

    mutating func cell() throws -> HerdrCell {
        let symbol = try string()
        let foreground = try UInt32(number())
        let background = try UInt32(number())
        let modifier = try UInt16(number())
        let skip = try byte() != 0
        let hyperlink = try optional { reader in try reader.number() }
        return HerdrCell(symbol: symbol, foreground: foreground, background: background, modifier: modifier, skip: skip,
                         hyperlink: hyperlink.map { UInt32(clamping: $0) })
    }

    mutating func cursor() throws -> HerdrCursor {
        let x = try Int(number())
        let y = try Int(number())
        let visible = try byte() != 0
        let shape = try byte()
        return HerdrCursor(x: x, y: y, visible: visible, shape: shape)
    }

    mutating func pane() throws -> (String, HerdrRect, HerdrRect, Bool) {
        let paneID = try string()
        _ = try number() // content revision
        let paneRect = try rect()
        let innerRect = try rect()
        _ = try optional { reader in try reader.rect() }
        _ = try optional { reader in
            for _ in 0..<3 { _ = try reader.number() }
        }
        _ = try byte() // focused
        let mouseReporting = try byte() != 0
        _ = try byte() // sgr pixel mouse
        _ = try byte() // alternate screen
        _ = try number()
        _ = try number()
        return (paneID, paneRect, innerRect, mouseReporting)
    }

    mutating func split() throws -> HerdrSplit {
        let direction: HerdrSplit.Direction
        switch try number() {
        case 0: direction = .horizontal
        case 1: direction = .vertical
        default: throw SurfaceProtocolError.invalidFrame
        }
        let pos = try Int(number())
        let area = try rect()
        let hitRect = try rect()
        var path: [Bool] = []
        for _ in 0..<(try count()) {
            switch try byte() {
            case 0: path.append(false)
            case 1: path.append(true)
            default: throw SurfaceProtocolError.invalidFrame
            }
        }
        return HerdrSplit(direction: direction, pos: pos, area: area, hitRect: hitRect, path: path)
    }

    mutating func skipFrame() throws {
        for _ in 0..<(try count()) { _ = try cell() }
        _ = try number() // width
        _ = try number() // height
        _ = try optional { reader in try reader.cursor() }
        for _ in 0..<(try count()) { _ = try string() }
        _ = try data() // legacy graphics bytes
    }

    mutating func popup() throws -> HerdrPopup {
        let id = try string(), title = try string()
        func size(_ reader: inout SurfaceReader) throws -> HerdrPopup.Size {
            let kind = try reader.number(), value = try reader.number()
            switch kind {
            case 0 where value <= UInt16.max: return .cells(Int(value))
            case 1 where value > 0 && value <= 100: return .percent(Int(value))
            default: throw SurfaceProtocolError.invalidFrame
            }
        }
        let width = try optional(size), height = try optional(size)
        let length = try count()
        guard length <= 200_000 else { throw SurfaceProtocolError.invalidFrame }
        var cells: [HerdrCell] = []
        for _ in 0..<length { cells.append(try cell()) }
        let cols = try number(), rows = try number()
        guard !id.isEmpty, cols > 0, rows > 0, cols <= 200_000, rows <= 200_000,
              cols * rows == UInt64(length) else { throw SurfaceProtocolError.invalidFrame }
        let cursor = try optional { try $0.cursor() }
        var links: [String] = []
        for _ in 0..<(try count()) { links.append(try string()) }
        _ = try data()
        let mouse = try byte(), pixels = try byte()
        guard mouse <= 1, pixels <= 1 else { throw SurfaceProtocolError.invalidFrame }
        let pixelWidth = try number(), pixelHeight = try number()
        guard pixelWidth <= UInt32.max, pixelHeight <= UInt32.max else { throw SurfaceProtocolError.invalidFrame }
        return HerdrPopup(terminalID: id, title: title, width: width, height: height, cols: Int(cols), rows: Int(rows),
                          cells: cells, cursor: cursor, hyperlinks: links, mouseReporting: mouse == 1,
                          pixelMouse: pixels == 1, pixelWidth: Int(pixelWidth), pixelHeight: Int(pixelHeight))
    }

    mutating func graphicKey() throws -> HerdrGraphicKey {
        let start = position
        let isPopup: Bool
        var popupID: String?
        switch try number() {
        case 0:
            switch try number() {
            case 0: isPopup = false
            case 1: isPopup = true
            default: throw SurfaceProtocolError.invalidFrame
            }
            let targetID = try string()
            if isPopup { popupID = targetID }
            _ = try number() // image ID
        case 1:
            isPopup = false
            _ = try string() // pane ID
            _ = try string() // layer ID
        default: throw SurfaceProtocolError.invalidFrame
        }
        let width = try number()
        let height = try number()
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let format = HerdrGraphicKey.Format(rawValue: try number()) else {
            throw SurfaceProtocolError.invalidFrame
        }
        let dataLength = try number()
        guard dataLength <= 32 * 1024 * 1024 else { throw SurfaceProtocolError.invalidFrame }
        _ = try number() // fingerprint
        return HerdrGraphicKey(identity: Data(bytes[start..<position]), width: Int(width),
                               height: Int(height), format: format, isPopup: isPopup,
                               dataLength: Int(dataLength), popupTerminalID: popupID)
    }

    mutating func graphicPlacement() throws -> HerdrGraphicPlacement {
        let key = try graphicKey()
        _ = try number() // logical placement ID
        let x = try number(), y = try number()
        let cols = try number(), rows = try number()
        let sourceX = try number(), sourceY = try number()
        let sourceWidth = try number(), sourceHeight = try number()
        let xOffset = try number(), yOffset = try number()
        let z = try signedNumber()
        _ = try number() // scrollback offset
        guard x <= 16_384, y <= 16_384, cols <= 16_384, rows <= 16_384,
              sourceX <= key.width, sourceY <= key.height,
              sourceWidth <= UInt64(key.width) - sourceX, sourceHeight <= UInt64(key.height) - sourceY,
              xOffset <= 16_384, yOffset <= 16_384 else { throw SurfaceProtocolError.invalidFrame }
        return HerdrGraphicPlacement(key: key, x: Int(x), y: Int(y), cols: Int(cols), rows: Int(rows),
                                     sourceX: Int(sourceX), sourceY: Int(sourceY),
                                     sourceWidth: Int(sourceWidth), sourceHeight: Int(sourceHeight),
                                     xOffset: Int(xOffset), yOffset: Int(yOffset), z: z)
    }

    mutating func surface(graphicsCache: inout [Data: Data]) throws -> HerdrSurface {
        let bootID = try string()
        let projectionRevision = try number()
        let revision = try number()
        let cellCount = try count()
        guard cellCount <= 200_000 else { throw SurfaceProtocolError.invalidFrame }
        var cells: [HerdrCell] = []
        cells.reserveCapacity(cellCount)
        for _ in 0..<cellCount { cells.append(try cell()) }
        let width = try Int(number())
        let height = try Int(number())
        guard width > 0, height > 0, width * height == cellCount else { throw SurfaceProtocolError.invalidFrame }
        let cursor = try optional { reader in try reader.cursor() }
        var hyperlinks: [String] = []
        for _ in 0..<(try count()) { hyperlinks.append(try string()) }
        for _ in 0..<(try count()) { _ = try byte() } // legacy graphics bytes
        var paneIDs: [String] = []
        var paneRects: [String: HerdrRect] = [:]
        var paneInnerRects: [String: HerdrRect] = [:]
        var mouseReportingPaneIDs: Set<String> = []
        for _ in 0..<(try count()) {
            let (id, rect, innerRect, mouseReporting) = try pane()
            paneIDs.append(id)
            paneRects[id] = rect
            paneInnerRects[id] = innerRect
            if mouseReporting { mouseReportingPaneIDs.insert(id) }
        }
        var splits: [HerdrSplit] = []
        for _ in 0..<(try count()) { splits.append(try split()) }
        let popup = try optional { reader in try reader.popup() }
        var delivered: [Data: Data] = [:]
        for _ in 0..<(try count()) {
            let key = try graphicKey()
            let bytes = try data()
            guard bytes.count == key.dataLength else { throw SurfaceProtocolError.invalidFrame }
            delivered[key.identity] = bytes
        }
        var placements: [HerdrGraphicPlacement] = []
        for _ in 0..<(try count()) { placements.append(try graphicPlacement()) }
        var retained = Set<Data>()
        for _ in 0..<(try count()) { retained.insert(try graphicKey().identity) }
        retained.formUnion(placements.map { $0.key.identity })
        graphicsCache = graphicsCache.filter { retained.contains($0.key) }
        graphicsCache.merge(delivered) { _, new in new }
        let graphics = placements.compactMap { placement -> HerdrGraphic? in
            guard let bytes = graphicsCache[placement.key.identity] else { return nil }
            return placement.resolved(with: bytes)
        }
        return HerdrSurface(bootID: bootID, projectionRevision: projectionRevision,
                            revision: revision, width: width, height: height,
                            cells: cells, cursor: cursor, paneIDs: paneIDs, paneRects: paneRects,
                            paneInnerRects: paneInnerRects, mouseReportingPaneIDs: mouseReportingPaneIDs,
                            splits: splits, graphics: graphics, hyperlinks: hyperlinks, popup: popup)
    }

    /// Applies a patch; `scrolls` move rows of pane regions first, as a scrolled patch does.
    mutating func applyPatch(to surface: inout HerdrSurface, scrolls: [HerdrSurfaceScroll] = []) throws {
        let bootID = try string()
        let projectionRevision = try number()
        let baseRevision = try number()
        let revision = try number()
        guard bootID == surface.bootID, projectionRevision == surface.projectionRevision,
              baseRevision == surface.revision else { throw SurfaceProtocolError.invalidFrame }
        guard scrolls.allSatisfy({ $0.fits(width: surface.width, height: surface.height) }),
              HerdrSurfaceScroll.disjoint(scrolls) else { throw SurfaceProtocolError.invalidFrame }
        for scroll in scrolls { scroll.apply(to: &surface.cells, width: surface.width) }
        for _ in 0..<(try count()) {
            let x = try Int(number())
            let y = try Int(number())
            let length = try count()
            guard x >= 0, y >= 0, y < surface.height, x + length <= surface.width else {
                throw SurfaceProtocolError.invalidFrame
            }
            for offset in 0..<length {
                surface.cells[y * surface.width + x + offset] = try cell()
            }
        }
        for _ in 0..<(try count()) {
            let (id, rect, innerRect, mouseReporting) = try pane()
            guard surface.paneRects[id] != nil else { throw SurfaceProtocolError.invalidFrame }
            surface.paneRects[id] = rect
            surface.paneInnerRects[id] = innerRect
            if mouseReporting {
                surface.mouseReportingPaneIDs.insert(id)
            } else {
                surface.mouseReportingPaneIDs.remove(id)
            }
        }
        surface.cursor = try optional { reader in try reader.cursor() }
        surface.revision = revision
    }
}

/// Moves the rows of one pane region before a scrolled patch's rows apply (Herdr's
/// `protocol::surface_scroll`). A positive `shift` moves content up: row `y` shows the previous
/// row `y + shift`, and rows that scroll out rotate into the vacated rows in the order Herdr's
/// row swaps leave them, since the patch omits vacated rows that already match.
struct HerdrSurfaceScroll: Equatable {
    let rect: HerdrRect
    let shift: Int

    func fits(width: Int, height: Int) -> Bool {
        rect.width > 0 && rect.height >= 2 && shift != 0 && abs(shift) < rect.height
            && rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    static func disjoint(_ scrolls: [HerdrSurfaceScroll]) -> Bool {
        scrolls.indices.allSatisfy { index in
            scrolls[(index + 1)...].allSatisfy { other in
                let a = scrolls[index].rect, b = other.rect
                return !(a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height)
            }
        }
    }

    /// Swaps rows exactly as Herdr's `for_each_swap` does, so both ends agree on the order.
    func apply(to cells: inout [HerdrCell], width: Int) {
        let distance = abs(shift)
        let pairs = shift > 0
            ? (0..<(rect.height - distance)).map { ($0, $0 + distance) }
            : (distance..<rect.height).reversed().map { ($0, $0 - distance) }
        cells.withUnsafeMutableBufferPointer { cells in
            for (a, b) in pairs {
                let first = (rect.y + a) * width + rect.x, second = (rect.y + b) * width + rect.x
                for x in 0..<rect.width { cells.swapAt(first + x, second + x) }
            }
        }
    }
}

/// Turns endpoint frames into surfaces: a complete surface replaces the current one and a
/// patch updates it. The live stream and the pipeline tests share it.
struct HerdrSurfaceDecoder {
    /// The control frame kind of scrolled patches, sent when the hello asks for `surface_scroll`.
    static let scrollKind = "endpoint.surface-scroll.v1"

    private(set) var surface: HerdrSurface?
    private var graphicsCache: [Data: Data] = [:]

    /// Applies one surface (tag 13), patch (tag 19) or scrolled patch (a tag 20 control frame
    /// of `scrollKind`); other frames return nil.
    mutating func apply(frame: Data) throws -> HerdrSurface? {
        var reader = SurfaceReader(frame)
        let tag = try reader.number()
        if tag == 20 {
            guard try reader.string() == Self.scrollKind else { return nil }
            return try applyScroll(try reader.string())
        }
        guard tag == 13 || tag == 19 else { return nil }
        return try apply(tag: tag, from: &reader)
    }

    /// Applies a scrolled patch: unpadded base64 of a count byte, each scroll's x, y, width
    /// and height (UInt16 LE) and shift (Int16 LE), then one framed patch (tag 19). Scrolling
    /// output then carries only the rows that still differ after the shift, not every row.
    mutating func applyScroll(_ data: String) throws -> HerdrSurface {
        let padded = data + String(repeating: "=", count: (4 - data.utf8.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded) else { throw SurfaceProtocolError.invalidFrame }
        let bytes = [UInt8](decoded)
        guard let count = bytes.first.map(Int.init), (1...64).contains(count) else { throw SurfaceProtocolError.invalidFrame }
        let header = 1 + count * 10
        guard bytes.count >= header + 4 else { throw SurfaceProtocolError.unexpectedEnd }
        func value(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        let scrolls = (0..<count).map { index in
            let at = 1 + index * 10
            return HerdrSurfaceScroll(rect: HerdrRect(x: Int(value(at)), y: Int(value(at + 2)),
                                                      width: Int(value(at + 4)), height: Int(value(at + 6))),
                                      shift: Int(Int16(bitPattern: value(at + 8))))
        }
        let length = (0..<4).reduce(0) { $0 | Int(bytes[header + $1]) << ($1 * 8) }
        guard header + 4 + length == bytes.count else { throw SurfaceProtocolError.invalidFrame }
        var reader = SurfaceReader(bytes: Array(bytes[(header + 4)...]))
        guard try reader.number() == 19, var patched = surface else { throw SurfaceProtocolError.invalidFrame }
        try reader.applyPatch(to: &patched, scrolls: scrolls)
        surface = patched
        return patched
    }

    fileprivate mutating func apply(tag: UInt64, from reader: inout SurfaceReader) throws -> HerdrSurface {
        if tag == 13 {
            let decoded = try reader.surface(graphicsCache: &graphicsCache)
            surface = decoded
            return decoded
        }
        guard var patched = surface else { throw SurfaceProtocolError.invalidFrame }
        try reader.applyPatch(to: &patched)
        surface = patched
        return patched
    }
}

enum SurfaceWriter {
    static func number(_ value: UInt64) -> Data {
        if value < 251 { return Data([UInt8(value)]) }
        if value <= UInt16.max {
            return Data([251, UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
        }
        if value <= UInt32.max {
            var data = Data([252])
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 0xff)) }
            return data
        }
        var data = Data([253])
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> shift) & 0xff)) }
        return data
    }

    static func string(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        return number(UInt64(utf8.count)) + utf8
    }

    static func control(kind: String, data: String) -> Data {
        number(20) + string(kind) + string(data)
    }

    static func paneInput(paneID: String, event: HerdrInputEvent) -> Data? {
        input(tag: 13, id: paneID, event: event)
    }

    static func popupInput(terminalID: String, event: HerdrInputEvent) -> Data? {
        input(tag: 14, id: terminalID, event: event)
    }

    private static func input(tag: UInt64, id: String, event: HerdrInputEvent) -> Data? {
        var payload = number(tag) + string(id) + number(1)
        switch event {
        case .text(let value):
            payload += number(1) + string(value)
        case .paste(let value):
            payload += number(3) + string(value)
        case .mouse(let mouse):
            payload += number(2)
            switch mouse.kind {
            case .down(let button): payload += number(0) + number(button)
            case .up(let button): payload += number(1) + number(button)
            case .drag(let button): payload += number(2) + number(button)
            case .scrollUp: payload += number(4)
            case .scrollDown: payload += number(5)
            case .scrollLeft: payload += number(6)
            case .scrollRight: payload += number(7)
            }
            payload += number(0) // ClientMousePosition::Cell
            payload += number(UInt64(mouse.column)) + number(UInt64(mouse.row))
            payload.append(0) // geometry: None
            payload.append(mouse.modifiers)
            payload += number(UInt64(mouse.lines))
        case .key(let name):
            // "ctrl++" is Control with the plus key: a trailing "++" names "+" itself.
            var parts = name.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, Array(parts.suffix(2)) == ["", ""] { parts = Array(parts.dropLast(2)) + ["+"] }
            guard let key = parts.last, !key.isEmpty else { return nil }
            let code: UInt64
            var character: String?
            switch key {
            case "backspace": code = 0
            case "enter": code = 1
            case "left": code = 2
            case "right": code = 3
            case "up": code = 4
            case "down": code = 5
            case "home": code = 6
            case "end": code = 7
            case "pageup": code = 8
            case "pagedown": code = 9
            case "tab": code = parts.contains("shift") ? 11 : 10
            case "delete": code = 12
            case "esc": code = 14
            default:
                guard key.unicodeScalars.count == 1 else { return nil }
                code = 15
                character = key
            }
            var modifiers: UInt8 = 0
            if parts.contains("shift") { modifiers |= 1 }
            if parts.contains("ctrl") { modifiers |= 2 }
            if parts.contains("alt") { modifiers |= 4 }
            payload += number(0) + number(code)
            // Bincode 2 encodes Rust char as UTF-8 without a length prefix.
            if let character { payload += Data(character.utf8) }
            payload.append(modifiers)
            payload += number(0) // Press
            payload += number(1) // repeat_count
            payload.append(0) // shifted_codepoint: None
            payload.append(0) // generated_text: None
            payload.append(1) // tracks_release
            payload.append(0) // physical_key_id: None
            payload.append(0) // windows_record: None
        }
        return payload
    }
}

enum HerdrInputEvent {
    case text(String)
    case paste(String)
    case key(String)
    case mouse(HerdrMouseEvent)
}

struct HerdrMouseEvent {
    enum Kind {
        case down(UInt64)
        case up(UInt64)
        case drag(UInt64)
        case scrollUp
        case scrollDown
        case scrollLeft
        case scrollRight
    }

    let kind: Kind
    let column: UInt16
    let row: UInt16
    let modifiers: UInt8
    let lines: UInt16
}

final class HerdrSurfaceStream {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    private var bootID: String?

    /// Runs `body`, a blocking `run`, on a thread of its own at user-interactive priority. The
    /// surfaces it reads are what the user is watching: in a `.utility` task, a loaded machine
    /// starved the thread for up to 0.4 s at a time, and a blocking read also holds a thread of
    /// Swift's small cooperative pool.
    static func onOwnThread(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread { continuation.resume(with: Result { try body() }) }
            thread.name = "dev.xherdr.surface-stream"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard cols > 0, rows > 0, cols <= 1000, rows <= 1000 else { return }
        var payload = SurfaceWriter.number(12) // ClientShellResize
        payload += SurfaceWriter.number(UInt64(cellWidth))
        payload += SurfaceWriter.number(UInt64(cellHeight))
        payload += SurfaceWriter.number(UInt64(cols))
        payload += SurfaceWriter.number(UInt64(rows))
        payload.append(0) // pixel mouse
        if send(payload) { TerminalPipelineMetrics.shared?.resizeSent(cols: cols, rows: rows) }
    }

    func focus(tabID: String) {
        request(method: "tab.focus", params: ["tab_id": tabID])
    }

    func focus(paneID: String) {
        request(method: "pane.focus", params: ["pane_id": paneID])
    }

    func focus(workspaceID: String) {
        request(method: "workspace.focus", params: ["workspace_id": workspaceID])
    }

    @discardableResult
    func setSplitRatio(tabID: String, path: [Bool], ratio: Double) -> Bool {
        request(method: "layout.set_split_ratio", params: [
            "tab_id": tabID, "path": path, "ratio": ratio
        ])
    }

    @discardableResult
    private func request(method: String, params: [String: Any]) -> Bool {
        lock.lock()
        let boot = bootID
        lock.unlock()
        guard let boot,
              let json = try? JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "method": method, "params": params
              ]), let request = String(data: json, encoding: .utf8) else { return false }
        return send(SurfaceWriter.number(15) + SurfaceWriter.string(boot) + SurfaceWriter.string(request))
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0 && !cancelled && bootID != nil
    }

    func sendInput(_ event: HerdrInputEvent, to paneID: String) -> Bool {
        guard isReady, let payload = SurfaceWriter.paneInput(paneID: paneID, event: event) else { return false }
        let sent = send(payload)
        if sent { TerminalPipelineMetrics.shared?.inputSent(bytes: payload.count) }
        return sent
    }

    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool {
        guard isReady, let payload = SurfaceWriter.popupInput(terminalID: terminalID, event: event) else { return false }
        return send(payload)
    }

    func closePopup() -> Bool { request(method: "popup.close", params: [:]) }

    @discardableResult
    private func send(_ payload: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0, !cancelled else { return false }
        var frame = Data()
        let length = UInt32(payload.count)
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8((length >> shift) & 0xff)) }
        frame += payload
        let completed = frame.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
        if !completed {
            cancelled = true
            _ = shutdown(fd, SHUT_RDWR)
        }
        return completed
    }

    func run(path: String, cols: Int, rows: Int, cellWidth: Int, cellHeight: Int,
             onReady: () -> Void, onSurface: (HerdrSurface) -> Void,
             onAgents: ((HerdrAgentProjection) -> Void)? = nil) throws {
        let connected = try HerdrSocket.open(path: path)
        lock.lock()
        fd = connected
        let wasCancelled = cancelled
        lock.unlock()
        defer {
            lock.lock()
            fd = -1
            bootID = nil
            lock.unlock()
            close(connected)
        }
        if wasCancelled { return }
        let hello: [String: Any] = [
            "generation": 1, "cell_width_px": cellWidth, "cell_height_px": cellHeight,
            "surface_size": ["cols": cols, "rows": rows],
            "pixel_mouse": false, "direct_graphics": false,
            "endpoint_keybindings": false, "mouse_capture": false,
            "surface_active": true, "surface_reuse": false, "surface_delta": false, "surface_scroll": true,
            "snapshot_codecs": ["shell.snapshot.v1"],
            "surface_codecs": ["shell.surface.v1"],
            "input_codecs": ["shell.input.semantic.v1"],
            "blob_codecs": ["shell.blob.v1"]
        ]
        let helloData = try JSONSerialization.data(withJSONObject: hello)
        guard let helloString = String(data: helloData, encoding: .utf8) else { throw SurfaceProtocolError.invalidFrame }
        guard send(SurfaceWriter.control(kind: "endpoint.hello.v1", data: helloString)) else {
            throw SurfaceProtocolError.unexpectedEnd
        }
        var decoder = HerdrSurfaceDecoder()
        var agents = HerdrAgentProjectionDecoder()
        var welcomed = false
        var supportsAgentView = false
        let metrics = TerminalPipelineMetrics.shared
        let recorder = TerminalSurfaceTraceRecorder.shared
        while !isCancelled {
            let frame = try readFrame(fd: connected)
            let receivedAt = TerminalPipelineMetrics.now()
            var reader = SurfaceReader(bytes: frame)
            let tag = try reader.number()
            switch tag {
            case 20:
                let kind = try reader.string()
                let data = try reader.string()
                if kind == "endpoint.welcome.v1" {
                    guard let json = data.data(using: .utf8),
                          let welcome = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                          (welcome["generation"] as? Int) == 1,
                          (welcome["error"] is NSNull || welcome["error"] == nil),
                          (welcome["snapshot_codec"] as? String) == "shell.snapshot.v1",
                          (welcome["surface_codec"] as? String) == "shell.surface.v1",
                          (welcome["input_codec"] as? String) == "shell.input.semantic.v1",
                          (welcome["blob_codec"] as? String) == "shell.blob.v1" else {
                        throw SurfaceProtocolError.incompatible("Herdr rejected surface endpoint")
                    }
                    welcomed = true
                    supportsAgentView = (welcome["capabilities"] as? [String] ?? []).contains("agent_view_projection")
                } else if welcomed, kind == HerdrSurfaceDecoder.scrollKind {
                    recorder?.record(Data(frame), at: receivedAt)
                    let decodeStart = TerminalPipelineMetrics.now()
                    let surface = try TerminalPipelineMetrics.signposter.withIntervalSignpost("decode") {
                        try decoder.applyScroll(data)
                    }
                    metrics?.received(surface, isPatch: true, bytes: frame.count, at: receivedAt,
                                      decodeNanos: TerminalPipelineMetrics.now() - decodeStart)
                    onSurface(surface)
                    continue
                } else if welcomed, kind == "shell.snapshot.v1",
                          let json = data.data(using: .utf8),
                          let snapshot = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                          let boot = snapshot["boot_id"] as? String {
                    lock.lock()
                    let changedBoot = bootID != boot
                    bootID = boot
                    lock.unlock()
                    if changedBoot { onReady() }
                }
                if welcomed, supportsAgentView, let onAgents {
                    if let projection = agents.receive(kind: kind, data: Data(data.utf8)) { onAgents(projection) }
                }
            case 13 where welcomed, 19 where welcomed:
                recorder?.record(Data(frame), at: receivedAt)
                let decodeStart = TerminalPipelineMetrics.now()
                let surface = try TerminalPipelineMetrics.signposter.withIntervalSignpost("decode") {
                    try decoder.apply(tag: tag, from: &reader)
                }
                metrics?.received(surface, isPatch: tag == 19, bytes: frame.count, at: receivedAt,
                                  decodeNanos: TerminalPipelineMetrics.now() - decodeStart)
                onSurface(surface)
            default: break
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Reads one frame straight into the bytes the decoder reads, without an intermediate copy.
    private func readFrame(fd: Int32) throws -> [UInt8] {
        let header = try readExactly(fd: fd, count: 4)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        guard length > 0, length <= 32 * 1024 * 1024 else { throw SurfaceProtocolError.invalidFrame }
        return try readExactly(fd: fd, count: Int(length))
    }

    private func readExactly(fd: Int32, count: Int) throws -> [UInt8] {
        try [UInt8](unsafeUninitializedCapacity: count) { bytes, initialized in
            guard let base = bytes.baseAddress else { return }
            while initialized < count {
                let amount = Darwin.read(fd, base.advanced(by: initialized), count - initialized)
                if amount <= 0 { throw SurfaceProtocolError.unexpectedEnd }
                initialized += amount
            }
        }
    }
}

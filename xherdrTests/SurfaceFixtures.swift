import Foundation
@testable import xherdr

/// Writes Herdr generation-1 endpoint frames, the inverse of the app's surface reader.
struct SurfaceWireWriter {
    private(set) var data = Data()

    mutating func number(_ value: UInt64) {
        if value < 251 {
            data.append(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            data.append(251)
            for shift in stride(from: 0, to: 16, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
        } else if value <= UInt64(UInt32.max) {
            data.append(252)
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
        } else {
            data.append(253)
            for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
        }
    }

    mutating func number(_ value: Int) { number(UInt64(value)) }
    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func string(_ value: String) {
        number(value.utf8.count)
        data.append(contentsOf: value.utf8)
    }

    mutating func rect(_ rect: HerdrRect) {
        number(rect.x); number(rect.y); number(rect.width); number(rect.height)
    }

    mutating func cell(_ cell: HerdrCell) {
        string(cell.symbol)
        number(UInt64(cell.foreground))
        number(UInt64(cell.background))
        number(UInt64(cell.modifier))
        byte(cell.skip ? 1 : 0)
        if let hyperlink = cell.hyperlink {
            byte(1)
            number(UInt64(hyperlink))
        } else {
            byte(0)
        }
    }

    mutating func cursor(_ cursor: HerdrCursor?) {
        guard let cursor else { return byte(0) }
        byte(1)
        number(cursor.x); number(cursor.y)
        byte(cursor.visible ? 1 : 0)
        byte(cursor.shape)
    }

    mutating func pane(_ model: SurfaceModel) {
        string(model.paneID)
        number(model.revision) // content revision
        rect(model.paneRect)
        rect(model.paneRect)
        byte(0) // scroll region: None
        byte(0) // scrollbar: None
        byte(1) // focused
        byte(model.mouseReporting ? 1 : 0)
        byte(0) // sgr pixel mouse
        byte(0) // alternate screen
        number(0); number(0)
    }
}

/// The screen a test expects the pipeline to show.
struct SurfaceModel {
    static let blank = HerdrCell(symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false)

    var bootID = "boot-test"
    var projectionRevision: UInt64 = 1
    var revision: UInt64 = 1
    let width: Int
    let height: Int
    var cells: [HerdrCell]
    var cursor: HerdrCursor? = HerdrCursor(x: 0, y: 0, visible: true, shape: 0)
    var paneID = "w1:p1"
    var mouseReporting = false
    var hyperlinks: [String] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: Self.blank, count: width * height)
    }

    var paneRect: HerdrRect { HerdrRect(x: 0, y: 0, width: width, height: height) }

    var surface: HerdrSurface {
        HerdrSurface(bootID: bootID, projectionRevision: projectionRevision, revision: revision,
                     width: width, height: height, cells: cells, cursor: cursor, paneIDs: [paneID],
                     paneRects: [paneID: paneRect], paneInnerRects: [paneID: paneRect],
                     mouseReportingPaneIDs: mouseReporting ? [paneID] : [], splits: [], graphics: [], hyperlinks: hyperlinks)
    }

    func row(_ y: Int) -> ArraySlice<HerdrCell> { cells[(y * width)..<((y + 1) * width)] }

    mutating func setRow(_ y: Int, _ row: [HerdrCell]) {
        precondition(row.count == width)
        cells.replaceSubrange((y * width)..<((y + 1) * width), with: row)
    }

    /// Moves every row up one line and puts `row` at the bottom, like terminal output scrolling.
    mutating func scroll(appending row: [HerdrCell]) {
        cells.removeFirst(width)
        cells.append(contentsOf: row)
    }

    /// A complete surface frame (tag 13). `tail` writes what follows the panes: splits,
    /// popup and graphics, which are empty by default.
    func surfaceFrame(tail: ((inout SurfaceWireWriter) -> Void)? = nil) -> Data {
        var writer = SurfaceWireWriter()
        writer.number(13)
        writer.string(bootID)
        writer.number(projectionRevision)
        writer.number(revision)
        writer.number(cells.count)
        for cell in cells { writer.cell(cell) }
        writer.number(width)
        writer.number(height)
        writer.cursor(cursor)
        writer.number(hyperlinks.count)
        for hyperlink in hyperlinks { writer.string(hyperlink) }
        writer.number(0) // legacy graphics bytes
        writer.number(1)
        writer.pane(self)
        if let tail { tail(&writer); return writer.data }
        writer.number(0) // splits
        writer.byte(0) // popup: None
        writer.number(0) // graphics assets
        writer.number(0) // graphics placements
        writer.number(0) // retained graphics keys
        return writer.data
    }

    /// A patch (tag 19) from `baseRevision` to this model's revision that rewrites `rows`.
    func patchFrame(baseRevision: UInt64, rows: [Int]) -> Data {
        patchFrame(baseRevision: baseRevision, runs: rows.map { (x: 0, y: $0, length: width) })
    }

    func patchFrame(baseRevision: UInt64, runs: [(x: Int, y: Int, length: Int)]) -> Data {
        var writer = SurfaceWireWriter()
        writer.number(19)
        writer.string(bootID)
        writer.number(projectionRevision)
        writer.number(baseRevision)
        writer.number(revision)
        writer.number(runs.count)
        for run in runs {
            writer.number(run.x)
            writer.number(run.y)
            writer.number(run.length)
            for offset in 0..<run.length { writer.cell(cells[run.y * width + run.x + offset]) }
        }
        writer.number(1)
        writer.pane(self)
        writer.cursor(cursor)
        return writer.data
    }
}

/// A deterministic stream of frames plus the screen expected after each one.
struct TerminalWorkload {
    let name: String
    let width: Int
    let height: Int
    var frames: [Data] = []
    /// `contentDigest` of the expected surface after each frame.
    var digests: [UInt64] = []
    var final: SurfaceModel

    var totalBytes: Int { frames.reduce(0) { $0 + $1.count } }

    fileprivate mutating func emit(_ frame: Data, _ model: SurfaceModel) {
        frames.append(frame)
        digests.append(model.surface.contentDigest)
        final = model
    }

    static func all(width: Int, height: Int, frames: Int) -> [TerminalWorkload] {
        [asciiScroll(width: width, height: height, frames: frames),
         colorScroll(width: width, height: height, frames: frames),
         unicodeScroll(width: width, height: height, frames: frames),
         typing(width: width, height: height, frames: frames),
         fullFrames(width: width, height: height, frames: max(1, frames / 4))]
    }

    /// Plain log output: every frame appends a line and rewrites every row.
    static func asciiScroll(width: Int, height: Int, frames: Int) -> TerminalWorkload {
        scrolling("ascii-scroll", width: width, height: height, frames: frames) { index, random, width in
            var row = RowBuilder(width: width)
            row.put(String(format: "[%06d] ", index))
            while row.column < width - 12, random.next(8) != 0 {
                row.put(random.word() + " ")
            }
            return row.cells
        }
    }

    /// Compiler-style output with ANSI, 256-color and RGB foregrounds, bold, underline and
    /// highlighted rows.
    static func colorScroll(width: Int, height: Int, frames: Int) -> TerminalWorkload {
        scrolling("color-scroll", width: width, height: height, frames: frames) { index, random, width in
            var row = RowBuilder(width: width)
            let level = random.next(6)
            let highlight: UInt32 = level == 0 ? Color.ansi(1) : 0
            row.put(String(format: "%02d:%02d:%02d ", index / 3600 % 24, index / 60 % 60, index % 60),
                    foreground: Color.palette(244), background: highlight)
            let tags: [(String, UInt32)] = [("ERROR", Color.ansi(2)), ("WARN ", Color.ansi(4)),
                                            ("INFO ", Color.ansi(3)), ("DEBUG", Color.ansi(5)),
                                            ("TRACE", Color.ansi(7)), ("NOTE ", Color.ansi(6))]
            row.put(tags[level].0, foreground: tags[level].1, background: highlight, modifier: level == 0 ? 1 : 0)
            row.put(" ", background: highlight)
            row.put("src/module\(random.next(40))/file\(random.next(200)).swift:\(random.next(900) + 1)",
                    foreground: Color.rgb(0x89B4FA), background: highlight, modifier: 8)
            row.put(" ", background: highlight)
            while row.column < width - 16, random.next(7) != 0 {
                let foreground = random.next(3) == 0 ? Color.palette(UInt32(16 + random.next(216))) : 0
                row.put(random.word() + " ", foreground: foreground, background: highlight,
                        modifier: random.next(9) == 0 ? 1 : 0)
            }
            row.fill(background: highlight)
            return row.cells
        }
    }

    /// Tree drawing, wide CJK and emoji cells, combining marks and Nerd Font symbols.
    static func unicodeScroll(width: Int, height: Int, frames: Int) -> TerminalWorkload {
        let fragments = ["│   ├── ", "└── ", "─────", "→ ", "✓ ", "✗ ", "\u{E0B0} ", "\u{F07C} ", "é", "ñ", "ü̈"]
        let wide = ["漢", "字", "テ", "ス", "ト", "한", "글", "🚀", "✅", "📦"]
        return scrolling("unicode-scroll", width: width, height: height, frames: frames) { index, random, width in
            var row = RowBuilder(width: width)
            row.put(String(format: "%05d ", index), foreground: Color.ansi(3))
            while row.column < width - 12, random.next(10) != 0 {
                switch random.next(3) {
                case 0: row.put(fragments[random.next(fragments.count)], foreground: Color.ansi(5))
                case 1: row.putWide(wide[random.next(wide.count)], foreground: Color.ansi(6))
                default: row.put(random.word() + " ")
                }
            }
            return row.cells
        }
    }

    /// Keystrokes echoed one cell at a time: small patches and a moving cursor.
    static func typing(width: Int, height: Int, frames: Int) -> TerminalWorkload {
        var random = SplitMix64(seed: 4)
        var model = SurfaceModel(width: width, height: height)
        for y in 0..<(height - 1) {
            var row = RowBuilder(width: width)
            row.put("~/project $ ", foreground: Color.ansi(3), modifier: 1)
            row.put(random.sentence(maxLength: width - 20))
            model.setRow(y, row.cells)
        }
        var prompt = RowBuilder(width: width)
        prompt.put("~/project $ ", foreground: Color.ansi(3), modifier: 1)
        model.setRow(height - 1, prompt.cells)
        model.cursor = HerdrCursor(x: prompt.column, y: height - 1, visible: true, shape: 0)
        var workload = TerminalWorkload(name: "typing", width: width, height: height, final: model)
        workload.emit(model.surfaceFrame(), model)
        let text = Array(random.sentence(maxLength: 10_000))
        for index in 0..<max(0, frames - 1) {
            let base = model.revision
            model.revision += 1
            guard let cursor = model.cursor else { break }
            let x = cursor.x, y = cursor.y
            model.cells[y * width + x] = HerdrCell(symbol: String(text[index % text.count]), foreground: 0,
                                                   background: 0, modifier: 0, skip: false)
            model.cursor = HerdrCursor(x: min(x + 1, width - 1), y: y, visible: true, shape: 0)
            workload.emit(model.patchFrame(baseRevision: base, runs: [(x, y, 1)]), model)
        }
        return workload
    }

    /// Complete surfaces only, as after a resize or a tab switch.
    static func fullFrames(width: Int, height: Int, frames: Int) -> TerminalWorkload {
        let colors = colorScroll(width: width, height: height, frames: frames)
        var model = SurfaceModel(width: width, height: height)
        var workload = TerminalWorkload(name: "full-frames", width: width, height: height, final: model)
        var decoder = HerdrSurfaceDecoder()
        for frame in colors.frames {
            guard let surface = try? decoder.apply(frame: frame) else { continue }
            model.cells = surface.cells
            model.cursor = surface.cursor
            model.revision = surface.revision
            workload.emit(model.surfaceFrame(), model)
        }
        return workload
    }

    private static func scrolling(_ name: String, width: Int, height: Int, frames: Int,
                                  line: (Int, inout SplitMix64, Int) -> [HerdrCell]) -> TerminalWorkload {
        var random = SplitMix64(seed: UInt64(name.utf8.reduce(0) { $0 &* 31 &+ Int($1) }.magnitude))
        var model = SurfaceModel(width: width, height: height)
        for y in 0..<height { model.setRow(y, line(y, &random, width)) }
        model.cursor = HerdrCursor(x: 0, y: height - 1, visible: true, shape: 0)
        var workload = TerminalWorkload(name: name, width: width, height: height, final: model)
        workload.emit(model.surfaceFrame(), model)
        for index in 0..<max(0, frames - 1) {
            let base = model.revision
            model.revision += 1
            model.scroll(appending: line(height + index, &random, width))
            workload.emit(model.patchFrame(baseRevision: base, rows: Array(0..<height)), model)
        }
        return workload
    }
}

/// Herdr cell colors: kind 0 is the default or ANSI 1–16, kind 1 the 256-color palette, kind 2 RGB.
enum Color {
    static func ansi(_ index: UInt32) -> UInt32 { index }
    static func palette(_ index: UInt32) -> UInt32 { 1 << 24 | index }
    static func rgb(_ value: UInt32) -> UInt32 { 2 << 24 | value }
}

struct RowBuilder {
    let width: Int
    private(set) var cells: [HerdrCell] = []

    init(width: Int) {
        self.width = width
        cells = Array(repeating: SurfaceModel.blank, count: width)
    }

    private(set) var column = 0

    /// Writes one cell per character (grapheme cluster), clipped at the row's end.
    mutating func put(_ text: String, foreground: UInt32 = 0, background: UInt32 = 0, modifier: UInt16 = 0,
                      hyperlink: UInt32? = nil) {
        for character in text where column < width {
            cells[column] = HerdrCell(symbol: String(character), foreground: foreground,
                                      background: background, modifier: modifier, skip: false, hyperlink: hyperlink)
            column += 1
        }
    }

    /// Writes a double-width character followed by its continuation cell.
    mutating func putWide(_ symbol: String, foreground: UInt32 = 0, background: UInt32 = 0) {
        guard column + 1 < width else { return }
        cells[column] = HerdrCell(symbol: symbol, foreground: foreground, background: background, modifier: 0, skip: false)
        cells[column + 1] = HerdrCell(symbol: "", foreground: foreground, background: background, modifier: 0, skip: true)
        column += 2
    }

    /// Extends `background` to the end of the row, as a highlighted line does.
    mutating func fill(background: UInt32) {
        guard background != 0 else { return }
        while column < width {
            cells[column] = HerdrCell(symbol: " ", foreground: 0, background: background, modifier: 0, skip: false)
            column += 1
        }
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    private static let words = ["build", "compile", "link", "warning", "error", "func", "struct", "let", "var",
                                "herdr", "pane", "surface", "render", "glyph", "cell", "cursor", "patch",
                                "frame", "layout", "draw", "metal", "atlas", "swift", "zig", "ghostty",
                                "0x7f3a", "42", "true", "nil", "(done)", "->", "{}", "[ok]", "--release"]

    mutating func word() -> String { Self.words[next(Self.words.count)] }

    mutating func sentence(maxLength: Int) -> String {
        var text = ""
        while text.count < maxLength - 12 {
            text += word() + " "
            if next(12) == 0 { break }
        }
        return text
    }
}

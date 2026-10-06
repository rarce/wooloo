import AppKit
import XCTest
@testable import xherdr

/// The grid layout and the drawn pixels must keep every cell Herdr sent: its glyph, its
/// background, its underline and nothing left over from an earlier frame.
@MainActor
final class TerminalRenderingTests: XCTestCase {
    private static let snapshotDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Snapshots")

    func testGridKeepsEveryCell() throws {
        for workload in TerminalWorkload.all(width: 100, height: 30, frames: 12) {
            try assertGridMatches(workload.final.surface, workload.name)
        }
    }

    /// Each intermediate screen of a scrolling workload lays out on its own; a grid reused
    /// across frames must not keep glyphs, fills or underlines from the previous one.
    func testGridHasNothingStaleAcrossFrames() throws {
        let workload = TerminalWorkload.colorScroll(width: 90, height: 25, frames: 20)
        var decoder = HerdrSurfaceDecoder()
        let view = TerminalRenderHarness.makeView(width: workload.width, height: workload.height)
        for (index, frame) in workload.frames.enumerated() {
            let surface = try XCTUnwrap(decoder.apply(frame: frame))
            TerminalRenderHarness.show(surface, in: view)
            let grid = try XCTUnwrap(view.terminalGrid)
            try assertGrid(grid, matches: surface, "\(workload.name) frame \(index)")
        }
    }

    /// Command-C goes through menu validation, which must see the grid selection even though
    /// the text view itself holds no selected range.
    func testCopyIsEnabledForGridSelection() throws {
        let workload = TerminalWorkload.colorScroll(width: 90, height: 25, frames: 1)
        let view = TerminalRenderHarness.makeView(width: workload.width, height: workload.height)
        TerminalRenderHarness.show(workload.final.surface, in: view)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertFalse(view.validateUserInterfaceItem(copyItem))

        view.selectAll(nil)
        XCTAssertTrue(view.validateUserInterfaceItem(copyItem))
        NSPasteboard.general.clearContents()
        view.copy(nil)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertFalse(copied.isEmpty)
    }

    /// Programs such as Claude Code insert a newline on Shift-Enter and submit on Enter.
    func testShiftEnterKeepsShift() throws {
        let view = TerminalRenderHarness.makeView(width: 10, height: 2)
        var sent: [String] = []
        view.sendKey = { key, _ in sent.append(key) }
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))
            view.keyDown(with: event)
        }
        XCTAssertEqual(sent, ["enter", "shift+enter"])
    }

    /// Pixel snapshots of each workload's final screen. A missing snapshot is recorded and the
    /// test skipped; set `XHERDR_RECORD_SNAPSHOTS=1` to record them all again. Snapshots depend
    /// on the installed terminal font, so record them on the machine that compares them.
    func testSnapshotsMatch() throws {
        let record = ProcessInfo.processInfo.environment["XHERDR_RECORD_SNAPSHOTS"] == "1"
        // The saved snapshots use FiraCode Nerd Font Mono; with the fallback font every glyph differs.
        guard record || NSFont(name: "FiraCodeNFM-Reg", size: 12) != nil else {
            throw XCTSkip("Snapshots are compared only where FiraCode Nerd Font Mono is installed")
        }
        var recorded: [String] = []
        for workload in TerminalWorkload.all(width: 100, height: 30, frames: 12) {
            let bitmap = TerminalRenderHarness.render(workload.final.surface)
            let url = Self.snapshotDirectory.appendingPathComponent("\(workload.name).png")
            if record || !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                recorded.append(workload.name)
                continue
            }
            let expected = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            let actualPixels = try XCTUnwrap(TerminalRenderHarness.pixels(of: bitmap))
            let expectedPixels = try XCTUnwrap(TerminalRenderHarness.pixels(of: expected))
            XCTAssertEqual(actualPixels.width, expectedPixels.width, workload.name)
            XCTAssertEqual(actualPixels.height, expectedPixels.height, workload.name)
            guard actualPixels.bytes.count == expectedPixels.bytes.count else { continue }
            var differing = 0
            for index in stride(from: 0, to: actualPixels.bytes.count, by: 4) {
                for channel in 0..<4 where abs(Int(actualPixels.bytes[index + channel]) - Int(expectedPixels.bytes[index + channel])) > 2 {
                    differing += 1
                    break
                }
            }
            if differing > 0 {
                let failure = FileManager.default.temporaryDirectory.appendingPathComponent("xherdr-\(workload.name)-actual.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: failure)
                XCTFail("\(workload.name): \(differing) pixels differ from \(url.lastPathComponent); actual image at \(failure.path)")
            }
        }
        if !recorded.isEmpty { throw XCTSkip("Recorded snapshots: \(recorded.joined(separator: ", "))") }
    }

    /// Dim, reversed, hidden and crossed-out cells are drawn as iTerm2 draws them, so Claude
    /// Code's faint suggestions stand apart from typed text.
    func testCellModifiersChangeColors() throws {
        var model = SurfaceModel(width: 5, height: 1)
        model.cursor = nil
        for (x, modifier) in [UInt16(0), 2, 64, 128, 256].enumerated() {
            model.cells[x] = HerdrCell(symbol: "x", foreground: 0, background: 0, modifier: modifier, skip: false)
        }
        let row = TerminalPaneView.layoutGrid(model.surface, theme: TerminalRenderHarness.theme, previous: nil).rows[0]
        func color(_ x: Int) -> NSColor? {
            row.runs.first { $0.columns.contains(x) }.flatMap { NSColor(cgColor: $0.color)?.usingColorSpace(.sRGB) }
        }
        let theme = TerminalRenderHarness.theme
        let foreground = try XCTUnwrap(theme.terminalForeground.usingColorSpace(.sRGB))
        let background = try XCTUnwrap(theme.terminalBackground.usingColorSpace(.sRGB))
        XCTAssertEqual(color(0), foreground)
        XCTAssertEqual(try XCTUnwrap(color(1)).redComponent,
                       (foreground.redComponent + background.redComponent) / 2, accuracy: 0.01)
        XCTAssertEqual(color(2), background)
        XCTAssertTrue(row.backgrounds.contains { $0.rect.contains(CGPoint(x: 2.5 * TerminalPaneView.cellWidth, y: 1)) })
        XCTAssertEqual(color(3), background)
        XCTAssertEqual(row.underlines.count, 1)
    }

    /// A view fed every frame of a workload, reusing rows between frames, ends up drawing
    /// exactly what a view shown only the last frame draws.
    func testIncrementalLayoutDrawsLikeFreshLayout() throws {
        for workload in TerminalWorkload.all(width: 100, height: 30, frames: 12) {
            var decoder = HerdrSurfaceDecoder()
            let view = TerminalRenderHarness.makeView(width: workload.width, height: workload.height)
            for frame in workload.frames {
                TerminalRenderHarness.show(try XCTUnwrap(decoder.apply(frame: frame)), in: view)
            }
            let incremental = TerminalRenderHarness.makeBitmap(for: view)
            TerminalRenderHarness.draw(view, into: incremental)
            let fresh = TerminalRenderHarness.render(try XCTUnwrap(decoder.surface))
            XCTAssertEqual(TerminalRenderHarness.pixels(of: incremental)?.bytes, TerminalRenderHarness.pixels(of: fresh)?.bytes,
                           "\(workload.name): incremental layout drew a different screen")
        }
    }

    /// Core Text shapes a row's text in pieces split at long runs of blanks, and remembers each
    /// piece. Every cell must still get the glyphs, fonts and offsets that shaping the whole row
    /// at once gives, ligatures included, however far apart their parts are.
    func testShapingInPiecesMatchesWholeRows() throws {
        var texts = ["a -> b => c == d != e <= f >= g === h !== i", "0xFF 1920x1080 www.example.com 0o17 0b1010",
                     "<!-- x --> |> <| :: ::: ... ..< .. /* */ // /// ;; __init__", "fn main() -> Result<T, E> { a?.b ?? c }",
                     "## ### #{ } #[ ] #( ) <=> <-> <<= >>= |||  |>  <|>  ~~>  -->  <--  ==>  <==  www",
                     "é ü̈ ñ 漢字 🚀 ✅ → ✓ \u{E0B0} \u{F07C} │   ├── └── ─────", "->", "  ==  ",
                     // Fira Code picks Greek capitals with tonos by the capital past a space.
                     "Ά Α ΈΒ Ή Γ  Ό Δ"]
        for gap in 1...12 {
            let spaces = String(repeating: " ", count: gap)
            texts += ["-\(spaces)>", "=\(spaces)=\(spaces)>", "x\(spaces)0x1\(spaces)www", "<\(spaces)!--\(spaces)-->"]
        }
        var model = SurfaceModel(width: 90, height: texts.count)
        model.cursor = nil
        for (y, text) in texts.enumerated() {
            var row = RowBuilder(width: model.width)
            for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { row.put(" ", modifier: index % 3 == 0 ? 1 : 0) }
                for character in word {
                    if character == "漢" || character == "字" || character == "🚀" || character == "✅" {
                        row.putWide(String(character))
                    } else {
                        row.put(String(character), modifier: index % 3 == 0 ? 1 : index % 5 == 0 ? 4 : 0)
                    }
                }
            }
            model.setRow(y, row.cells)
        }
        let surface = model.surface
        TerminalShapeCache.shared.removeAll()
        let shaped = TerminalPaneView.layoutGrid(surface, theme: TerminalRenderHarness.theme)
        let cached = TerminalPaneView.layoutGrid(surface, theme: TerminalRenderHarness.theme)
        for y in 0..<surface.height {
            let expected = Self.wholeRowGlyphs(Array(surface.cells[(y * surface.width)..<((y + 1) * surface.width)]))
            for grid in [shaped, cached] {
                var actual: [Int: [String]] = [:]
                for run in grid.rows[y].runs {
                    for index in run.glyphs.indices {
                        actual[run.columns[index], default: []].append(Self.describe(
                            run.font, run.glyphs[index], run.positions[index], column: run.columns[index]))
                    }
                }
                XCTAssertEqual(actual, expected, "row \(y): \(texts[y].debugDescription)")
            }
        }
    }

    /// Each column's glyphs when Core Text shapes the whole row at once, as layout did before
    /// it split rows into pieces.
    private static func wholeRowGlyphs(_ cells: [HerdrCell]) -> [Int: [String]] {
        let text = NSMutableAttributedString()
        var columnAt: [Int] = []
        for (x, cell) in cells.enumerated() where !cell.skip {
            let symbol = cell.symbol.isEmpty ? " " : cell.symbol
            let font = switch cell.modifier & 5 {
            case 1: TerminalPaneView.boldFont
            case 4: TerminalPaneView.italicFont
            case 5: TerminalPaneView.boldItalicFont
            default: TerminalPaneView.terminalFont
            }
            text.append(NSAttributedString(string: symbol, attributes: [.font: font]))
            columnAt += Array(repeating: x, count: symbol.utf16.count)
        }
        var glyphs: [Int: [String]] = [:]
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            var cellStart: (column: Int, x: CGFloat)?
            for index in 0..<count {
                let column = columnAt[indices[index]]
                if cells[column].symbol.isEmpty || cells[column].symbol == " " { continue }
                if cellStart?.column != column { cellStart = (column, positions[index].x) }
                let position = CGPoint(x: CGFloat(column) * TerminalPaneView.cellWidth + (positions[index].x - cellStart!.x),
                                       y: positions[index].y)
                glyphs[column, default: []].append(describe(font, ids[index], position, column: column))
            }
        }
        return glyphs
    }

    private static func describe(_ font: CTFont, _ glyph: CGGlyph, _ position: CGPoint, column: Int) -> String {
        let x = position.x - CGFloat(column) * TerminalPaneView.cellWidth
        // Adding zero turns -0 into 0, so rounding noise never shows as a difference.
        return "\(CTFontCopyPostScriptName(font)) \(glyph) \(String(format: "%.2f %.2f", (x * 100).rounded() / 100 + 0, (position.y * 100).rounded() / 100 + 0))"
    }

    /// Rows are found again by fingerprint: a row that scrolled up must keep it, wide, combining
    /// and Nerd Font symbols included, or every frame would lay out the whole screen again.
    func testScrolledRowsKeepTheirFingerprints() throws {
        for workload in [TerminalWorkload.unicodeScroll(width: 80, height: 20, frames: 10),
                         TerminalWorkload.colorScroll(width: 80, height: 20, frames: 10)] {
            var decoder = HerdrSurfaceDecoder()
            var previous: TerminalGrid?
            for (index, frame) in workload.frames.enumerated() {
                let grid = TerminalPaneView.layoutGrid(try XCTUnwrap(decoder.apply(frame: frame)),
                                                       theme: TerminalRenderHarness.theme, previous: previous)
                if let previous {
                    for row in 0..<(grid.height - 1) {
                        XCTAssertEqual(grid.keys[row].fingerprint, previous.keys[row + 1].fingerprint,
                                       "\(workload.name) frame \(index) row \(row)")
                        // The cursor sat on the last row, so the row above it is laid out again.
                        guard row < grid.height - 2 else { continue }
                        XCTAssertEqual(previous.row(matching: grid.keys[row], near: row + 1), row + 1,
                                       "\(workload.name) frame \(index) row \(row)")
                    }
                }
                previous = grid
            }
        }
    }

    /// Every row whose cells or cursor changed between two frames is redrawn.
    func testChangedRowsCoverEveryChange() throws {
        for workload in TerminalWorkload.all(width: 60, height: 20, frames: 24) {
            var decoder = HerdrSurfaceDecoder()
            var previous: (surface: HerdrSurface, grid: TerminalGrid)?
            for (index, frame) in workload.frames.enumerated() {
                let surface = try XCTUnwrap(decoder.apply(frame: frame))
                let grid = TerminalPaneView.layoutGrid(surface, theme: TerminalRenderHarness.theme, previous: previous?.grid)
                if let previous {
                    let redrawn = Set(grid.changedRows(since: previous.grid).flatMap { $0 })
                    for row in 0..<surface.height {
                        let cells = { (s: HerdrSurface) in s.cells[(row * s.width)..<((row + 1) * s.width)] }
                        let cursorRow = { (s: HerdrSurface) in s.cursor?.visible == true && s.cursor?.y == row ? s.cursor?.x : nil }
                        let differs = cells(previous.surface) != cells(surface) || cursorRow(previous.surface) != cursorRow(surface)
                        if differs && !redrawn.contains(row) {
                            XCTFail("\(workload.name) frame \(index): row \(row) changed but is not redrawn")
                        }
                    }
                }
                previous = (surface, grid)
            }
        }
    }

    private func assertGridMatches(_ surface: HerdrSurface, _ label: String) throws {
        let view = TerminalRenderHarness.makeView(width: surface.width, height: surface.height)
        TerminalRenderHarness.show(surface, in: view)
        try assertGrid(XCTUnwrap(view.terminalGrid), matches: surface, label)
    }

    private func assertGrid(_ grid: TerminalGrid, matches surface: HerdrSurface, _ label: String) throws {
        XCTAssertEqual(grid.width, surface.width, label)
        XCTAssertEqual(grid.height, surface.height, label)
        let cellWidth = TerminalPaneView.cellWidth
        let cellHeight = TerminalPaneView.cellHeight
        var failures = 0
        func fail(_ message: String) {
            failures += 1
            if failures <= 10 { XCTFail("\(label): \(message)") }
        }
        for y in 0..<surface.height {
            let row = grid.rows[y]
            let glyphColumns = Set(row.runs.flatMap(\.columns))
            let underlined = row.underlines
            for x in 0..<surface.width {
                let cell = surface.cells[y * surface.width + x]
                let expectedSymbol = cell.skip ? "" : (cell.symbol.isEmpty ? " " : cell.symbol)
                if row.symbols[x] != expectedSymbol {
                    fail("cell \(x),\(y) holds \(row.symbols[x].debugDescription), expected \(expectedSymbol.debugDescription)")
                }
                let visible = !cell.skip && !expectedSymbol.trimmingCharacters(in: .whitespaces).isEmpty
                if visible != glyphColumns.contains(x) {
                    fail("cell \(x),\(y) \(expectedSymbol.debugDescription) \(visible ? "has no glyph" : "has a stray glyph")")
                }
                let center = CGPoint(x: (CGFloat(x) + 0.5) * cellWidth, y: cellHeight / 2)
                let isCursor = surface.cursor?.visible == true && surface.cursor?.x == x && surface.cursor?.y == y
                let filled = row.backgrounds.contains { $0.rect.contains(center) }
                if filled != (cell.background != 0 || cell.modifier & 64 != 0 || isCursor) {
                    fail("cell \(x),\(y) background \(filled ? "filled" : "missing") for color \(cell.background)")
                }
                if cell.modifier & 8 != 0, !cell.skip,
                   !underlined.contains(where: { $0.rect.minX <= center.x && $0.rect.maxX >= center.x }) {
                    fail("cell \(x),\(y) lost its underline")
                }
            }
            let underlinedCells = (0..<surface.width).filter {
                let cell = surface.cells[y * surface.width + $0]
                // Underlines (8) and strikethroughs (256) are both line fills.
                return cell.modifier & 264 != 0
                    || (cell.skip && $0 > 0 && surface.cells[y * surface.width + $0 - 1].modifier & 264 != 0)
            }
            for line in underlined {
                let first = Int((line.rect.minX / cellWidth).rounded())
                let last = Int((line.rect.maxX / cellWidth).rounded()) - 1
                if first > last || !(first...last).allSatisfy(underlinedCells.contains) {
                    fail("row \(y) has a stray underline over columns \(first)...\(last)")
                }
            }
        }
    }
}

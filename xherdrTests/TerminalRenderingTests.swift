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
                if filled != (cell.background != 0 || isCursor) {
                    fail("cell \(x),\(y) background \(filled ? "filled" : "missing") for color \(cell.background)")
                }
                if cell.modifier & 8 != 0, !cell.skip,
                   !underlined.contains(where: { $0.rect.minX <= center.x && $0.rect.maxX >= center.x }) {
                    fail("cell \(x),\(y) lost its underline")
                }
            }
            let underlinedCells = (0..<surface.width).filter {
                let cell = surface.cells[y * surface.width + $0]
                return cell.modifier & 8 != 0 || (cell.skip && $0 > 0 && surface.cells[y * surface.width + $0 - 1].modifier & 8 != 0)
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

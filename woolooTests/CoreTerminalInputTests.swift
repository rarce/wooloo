import WoolooTerminalEngine
import XCTest
@testable import wooloo

/// Mouse and wheel input in herdr-core panes, emulated in wooloo with libghostty-vt: reports
/// for programs that ask for the mouse, client scrollback for those that do not.
final class CoreTerminalInputTests: XCTestCase {
    private func terminal(_ output: String = "") throws -> VTTerminal {
        let terminal = try VTTerminal(cols: 80, rows: 24)
        try terminal.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        terminal.write(Data(output.utf8))
        return terminal
    }

    private func mouse(_ kind: HerdrMouseEvent.Kind, column: UInt16 = 4, row: UInt16 = 2,
                       modifiers: UInt8 = 0, lines: UInt16 = 1) -> HerdrMouseEvent {
        HerdrMouseEvent(kind: kind, column: column, row: row, modifiers: modifiers, lines: lines)
    }

    private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    func testReportsFollowTheProgramsMouseMode() throws {
        let plain = try terminal()
        XCTAssertFalse(plain.reportsMouse)
        XCTAssertNil(CoreTerminalPresentation.mouseInput(mouse(.down(0)), to: plain).bytes,
                     "Without mouse reports a click stays in the window, for selecting text")

        let x10 = try terminal("\u{1b}[?1000h")
        XCTAssertTrue(x10.reportsMouse)
        XCTAssertEqual(CoreTerminalPresentation.mouseInput(mouse(.down(0), column: 2, row: 1), to: x10).bytes,
                       Data([0x1b, 0x5b, 0x4d, 32, 32 + 3, 32 + 2]), "Normal tracking, X10 format, 1-based cells")

        let sgr = try terminal("\u{1b}[?1002h\u{1b}[?1006h")
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.down(0)), to: sgr).bytes), "\u{1b}[<0;5;3M")
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.up(0)), to: sgr).bytes), "\u{1b}[<0;5;3m")
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.down(1)), to: sgr).bytes), "\u{1b}[<2;5;3M",
                       "wooloo's button 1 is the right button")
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.drag(0), column: 6), to: sgr).bytes),
                       "\u{1b}[<32;7;3M", "A drag is motion with the button held")
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.down(0), modifiers: 2), to: sgr).bytes),
                       "\u{1b}[<16;5;3M", "Control")
        let wheel = CoreTerminalPresentation.mouseInput(mouse(.scrollUp, lines: 3), to: sgr)
        XCTAssertEqual(text(wheel.bytes), String(repeating: "\u{1b}[<64;5;3M", count: 3))
        XCTAssertFalse(wheel.scrolled, "A program that takes the mouse gets the wheel too")
    }

    func testTheWheelMovesTheScrollbackAndTypingReturns() throws {
        let terminal = try terminal((1...100).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(terminal.isAtBottom)
        let bottom = terminal.scrollPosition
        XCTAssertEqual(bottom.total, 100)
        _ = terminal.frame()
        let input = CoreTerminalPresentation.mouseInput(mouse(.scrollUp, lines: 5), to: terminal)
        XCTAssertNil(input.bytes)
        XCTAssertTrue(input.scrolled)
        XCTAssertFalse(terminal.isAtBottom)
        XCTAssertEqual(terminal.scrollPosition.offset, bottom.offset - 5)
        let frame = try XCTUnwrap(terminal.frame())
        XCTAssertEqual(frame.rows[0]?.map(\.text).joined().trimmingCharacters(in: .whitespaces), "line 72",
                       "The viewport shows older lines")
        _ = CoreTerminalPresentation.mouseInput(mouse(.scrollDown, lines: 2), to: terminal)
        XCTAssertEqual(terminal.scrollPosition.offset, bottom.offset - 3)
        terminal.scrollToBottom()
        XCTAssertTrue(terminal.isAtBottom)
        XCTAssertFalse(CoreTerminalPresentation.mouseInput(mouse(.scrollLeft), to: terminal).scrolled)
    }

    func testTheWheelOnTheAlternateScreenSendsArrowsWhenAsked() throws {
        let pager = try terminal("\u{1b}[?1049h")
        XCTAssertTrue(pager.isAlternateScreen)
        XCTAssertNil(CoreTerminalPresentation.mouseInput(mouse(.scrollDown), to: pager).bytes,
                     "The alternate screen has no scrollback, and the program did not ask for arrows")
        pager.write(Data("\u{1b}[?1007h".utf8))
        let input = CoreTerminalPresentation.mouseInput(mouse(.scrollDown, lines: 3), to: pager)
        XCTAssertEqual(text(input.bytes), String(repeating: "\u{1b}[B", count: 3))
        XCTAssertFalse(input.scrolled)
        let capped = CoreTerminalPresentation.mouseInput(mouse(.scrollUp, lines: 50), to: pager)
        XCTAssertEqual(capped.bytes?.count, 3 * CoreTerminalPresentation.maxWheelRepeat)
    }

    // MARK: Kitty images

    func testAKittyImageReachesTheSurfaceAtItsPlace() throws {
        let terminal = try terminal("\r\n")
        _ = terminal.frame()
        XCTAssertEqual(terminal.imagesIfChanged() ?? [], [])
        // Two red RGB pixels, transmitted and shown over two cells at the cursor (column 0, row 1).
        let pixels = Data([255, 0, 0, 255, 0, 0])
        terminal.write(Data("\u{1b}_Ga=T,f=24,s=2,v=1,c=2,r=1,i=7;\(pixels.base64EncodedString())\u{1b}\\".utf8))
        _ = terminal.frame()
        let image = try XCTUnwrap(terminal.imagesIfChanged()?.first)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.format, .rgb)
        XCTAssertEqual(image.pixels, pixels)
        XCTAssertEqual([image.column, image.row, image.cols, image.rows], [0, 1, 2, 1])
        _ = terminal.frame()
        XCTAssertNil(terminal.imagesIfChanged(), "Unchanged placements are not read again")

        let graphic = try XCTUnwrap(CoreTerminalPresentation.graphic(image, of: "t1",
                                                                    in: HerdrRect(x: 41, y: 3, width: 40, height: 20)))
        XCTAssertEqual([graphic.x, graphic.y, graphic.cols, graphic.rows], [41, 4, 2, 1], "At the pane's place")
        XCTAssertEqual(graphic.key.format, .rgb)
        XCTAssertEqual(graphic.data, pixels)
        XCTAssertGreaterThanOrEqual(graphic.z, 0, "Above the text by default")
    }

    func testImagesAreCutToTheirPane() throws {
        let image = TerminalImage(identity: "1:1", width: 100, height: 100, format: .rgba,
                                  pixels: Data(count: 40_000), column: 8, row: -5, cols: 10, rows: 10,
                                  offsetY: 3, sourceWidth: 100, sourceHeight: 100, belowText: true, z: 0)
        let graphic = try XCTUnwrap(CoreTerminalPresentation.graphic(image, of: "t1", in: HerdrRect(x: 0, y: 0, width: 12, height: 20)))
        XCTAssertEqual([graphic.x, graphic.y, graphic.cols, graphic.rows], [8, 0, 4, 5])
        XCTAssertEqual([graphic.sourceX, graphic.sourceY, graphic.sourceWidth, graphic.sourceHeight], [0, 50, 40, 50])
        XCTAssertEqual(graphic.yOffset, 0, "The cut edge starts at the cell")
        XCTAssertLessThan(graphic.z, 0, "Below the text when the program asked")
        let gone = TerminalImage(identity: "1:1", width: 1, height: 1, format: .rgb, pixels: Data(count: 3),
                                 column: 0, row: -3, cols: 1, rows: 2, sourceWidth: 1, sourceHeight: 1)
        XCTAssertNil(CoreTerminalPresentation.graphic(gone, of: "t1", in: HerdrRect(x: 0, y: 0, width: 5, height: 5)))
    }

    func testRGBAImagesKeepTheirPixels() throws {
        let terminal = try terminal()
        let rgba = Data([1, 2, 3, 4])
        terminal.write(Data("\u{1b}_Ga=T,f=32,s=1,v=1,c=1,r=1,i=9;\(rgba.base64EncodedString())\u{1b}\\".utf8))
        _ = terminal.frame()
        let image = try XCTUnwrap(terminal.imagesIfChanged()?.first)
        XCTAssertEqual(image.format, .rgba)
        XCTAssertEqual(image.pixels, rgba)
    }
}

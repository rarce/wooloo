import AppKit
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

    func testControlCUsesTheProgramsKeyboardProtocol() throws {
        let emulator = try terminal()
        XCTAssertEqual(emulator.encodeKey("ctrl+c"), Data([3]))
        emulator.write(Data("\u{1b}[>1u".utf8))
        XCTAssertEqual(text(emulator.encodeKey("ctrl+c")), "\u{1b}[99;5u")
    }

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

    /// A program on the main screen that takes the mouse, such as `fzf --height`, while older
    /// lines show: its reports would name the wrong rows, so the wheel moves the scrollback and
    /// a click returns to the live screen first.
    func testTheMouseWhileScrolledBackReturnsToTheLiveScreen() throws {
        let terminal = try terminal((1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(terminal.reportsMouse)
        terminal.scroll(by: -10)
        XCTAssertFalse(terminal.isAtBottom)
        let wheel = CoreTerminalPresentation.mouseInput(mouse(.scrollDown, lines: 4), to: terminal)
        XCTAssertNil(wheel.bytes)
        XCTAssertTrue(wheel.scrolled, "The wheel moves the scrollback")
        XCTAssertFalse(terminal.isAtBottom)
        let click = CoreTerminalPresentation.mouseInput(mouse(.down(0)), to: terminal)
        XCTAssertNil(click.bytes, "The click that returns is not reported")
        XCTAssertTrue(click.scrolled)
        XCTAssertTrue(terminal.isAtBottom)
        XCTAssertEqual(text(CoreTerminalPresentation.mouseInput(mouse(.down(0)), to: terminal).bytes), "\u{1b}[<0;5;3M")
        XCTAssertNotNil(CoreTerminalPresentation.mouseInput(mouse(.scrollUp), to: terminal).bytes,
                        "On the live screen the program gets the wheel")
    }

    func testTheWheelOnTheAlternateScreenSendsArrowsUnlessTurnedOff() throws {
        // Alternate scroll (1007) is on unless a program turns it off, as in Ghostty and xterm.
        let pager = try terminal("\u{1b}[?1049h\u{1b}[?1007l")
        XCTAssertTrue(pager.isAlternateScreen)
        XCTAssertNil(CoreTerminalPresentation.mouseInput(mouse(.scrollDown), to: pager).bytes,
                     "The alternate screen has no scrollback, and the program turned arrows off")
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
        // A new attachment's emulator numbers its images afresh: its images are not the old ones.
        let again = try XCTUnwrap(CoreTerminalPresentation.graphic(image, of: "t1", stream: 9,
                                                                  in: HerdrRect(x: 41, y: 3, width: 40, height: 20)))
        XCTAssertNotEqual(again.key, graphic.key)
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

    func testKittyImagesDecodeOnlyPNG() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for (index, byte) in [255, 0, 0, 255, 0, 0, 255, 255].enumerated() { pixels[index] = UInt8(byte) }
        func shown(_ data: Data?) throws -> TerminalImage? {
            let terminal = try terminal()
            let payload = try XCTUnwrap(data).base64EncodedString()
            terminal.write(Data("\u{1b}_Ga=T,f=100,c=2,r=1,i=5;\(payload)\u{1b}\\".utf8))
            _ = terminal.frame()
            return terminal.imagesIfChanged()?.first
        }
        let png = try XCTUnwrap(try shown(bitmap.representation(using: .png, properties: [:])))
        XCTAssertEqual([png.width, png.height], [2, 1])
        XCTAssertEqual(png.format, .rgba)
        XCTAssertEqual(Array(png.pixels), [255, 0, 0, 255, 0, 0, 255, 255])
        // The same pixels in formats ImageIO also reads are refused: the protocol's f=100 is PNG.
        XCTAssertNil(try shown(bitmap.representation(using: .tiff, properties: [:])), "TIFF")
        XCTAssertNil(try shown(bitmap.representation(using: .gif, properties: [:])), "GIF")
        XCTAssertNil(try shown(bitmap.representation(using: .bmp, properties: [:])), "BMP")
    }

    // MARK: Find

    func testFindWalksMatchesFromTheNewestThroughTheScrollback() throws {
        let terminal = try terminal((1...100).map { "line \($0)" }.joined(separator: "\r\n"))
        let newest = try XCTUnwrap(terminal.find("line 7"))
        XCTAssertEqual(newest.total, 11, "line 7 and line 70 to 79")
        XCTAssertEqual(newest.index, 1)
        // line 79 is row 78 of 100; the viewport shows rows 76 to 99.
        XCTAssertEqual(newest.start?.row, 2)
        XCTAssertEqual(newest.start?.column, 0)
        XCTAssertEqual(newest.end?.column, 5)
        XCTAssertTrue(terminal.isAtBottom, "A match on screen does not scroll")
        var match = newest
        for _ in 0..<10 { match = try XCTUnwrap(terminal.find("line 7")) }
        XCTAssertEqual(match.index, 11, "The oldest: line 7")
        XCTAssertFalse(terminal.isAtBottom, "The viewport scrolled back to it")
        XCTAssertEqual(match.start?.column, 0)
        XCTAssertEqual(try XCTUnwrap(terminal.find("line 7")).index, 1, "Past the oldest it wraps to the newest")
        XCTAssertEqual(try XCTUnwrap(terminal.find("line 7", older: false)).index, 11, "and back")
        XCTAssertNil(terminal.find("not there"))
        XCTAssertNil(terminal.find(""))
        terminal.endSearch()
    }

    func testTheSelectedMatchFollowsNewOutput() throws {
        let terminal = try terminal((1...30).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(terminal.beginFind("line 29"))
        while !terminal.continueFind() {}
        let match = try XCTUnwrap(terminal.selectMatch(older: true))
        let row = try XCTUnwrap(match.start?.row)
        terminal.write(Data("\r\nnew 1\r\nnew 2\r\nnew 3".utf8))
        XCTAssertEqual(terminal.followMatch()?.start.row, row - 3, "Output scrolled the match up three rows")
        terminal.write(Data(String(repeating: "\r\nmore", count: 30).utf8))
        XCTAssertNil(terminal.followMatch(), "Out of view, nothing is highlighted")
        terminal.endSearch()
        XCTAssertNil(terminal.followMatch())
    }

    func testAMatchIsDrawnInverted() {
        let match = (start: (column: 3, row: 1), end: (column: 2, row: 2))
        XCTAssertFalse(CoreTerminalPresentation.contains(match, column: 2, row: 1))
        XCTAssertTrue(CoreTerminalPresentation.contains(match, column: 3, row: 1))
        XCTAssertTrue(CoreTerminalPresentation.contains(match, column: 70, row: 1), "A match can run onto the next line")
        XCTAssertTrue(CoreTerminalPresentation.contains(match, column: 0, row: 2))
        XCTAssertFalse(CoreTerminalPresentation.contains(match, column: 3, row: 2))
        let cell = HerdrCell(symbol: "a", foreground: 1, background: 2, modifier: 1, skip: false)
        XCTAssertEqual(CoreTerminalPresentation.highlighted(cell).modifier, 1 | 64)
        let reversed = HerdrCell(symbol: "a", foreground: 1, background: 2, modifier: 64, skip: false)
        XCTAssertEqual(CoreTerminalPresentation.highlighted(reversed).modifier, 64 | 1 | 8,
                       "Text that is already reversed stays reversed, bold and underlined")
    }
}

/// Opening the terminal find bar takes the keyboard from the terminal at once: SwiftUI focuses
/// the field only after it shows it, and keys typed meanwhile must not reach the shell.
@MainActor
final class TerminalFindBarFocusTests: XCTestCase {
    func testOpeningTheBarTakesTheKeyboardFromTheTerminal() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = HerdrTerminalTextView(usingTextLayoutManager: false)
        window.contentView = terminal
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(TerminalFindBar.releaseKeyboard(in: window) === terminal, "Kept to give it back on close")
        XCTAssertFalse(window.firstResponder === terminal)
        terminal.claimKeyboardFocusIfIdle()
        XCTAssertFalse(window.firstResponder === terminal, "Keys typed before the field shows must not reach the shell")
        XCTAssertNil(TerminalFindBar.releaseKeyboard(in: window), "Nothing to take when the terminal lacks it")
        XCTAssertTrue(window.makeFirstResponder(terminal), "The bar gives it back on close")
        window.makeFirstResponder(nil)
        terminal.claimKeyboardFocusIfIdle()
        XCTAssertTrue(window.firstResponder === terminal, "Once given back, it claims the keyboard as before")
        XCTAssertNil(TerminalFindBar.releaseKeyboard(in: nil))
    }
}

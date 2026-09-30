import AppKit
import XCTest
@testable import xherdr

/// A 20×4 surface with two panes side by side and the divider between them at column 10.
private func twoPaneSurface(mouseReporting: Set<String> = []) -> HerdrSurface {
    let blank = SurfaceModel.blank
    var cells = Array(repeating: blank, count: 20 * 4)
    for (offset, character) in "hello world".enumerated() {
        cells[offset] = HerdrCell(symbol: String(character), foreground: 0, background: 0, modifier: 0, skip: false)
    }
    let left = HerdrRect(x: 0, y: 0, width: 10, height: 4)
    let right = HerdrRect(x: 11, y: 0, width: 9, height: 4)
    let split = HerdrSplit(direction: .horizontal, pos: 10, area: HerdrRect(x: 0, y: 0, width: 20, height: 4),
                           hitRect: HerdrRect(x: 10, y: 0, width: 1, height: 4), path: [true])
    return HerdrSurface(bootID: "boot", projectionRevision: 1, revision: 1, width: 20, height: 4, cells: cells,
                        cursor: nil, paneIDs: ["w1:p1", "w1:p2"],
                        paneRects: ["w1:p1": left, "w1:p2": right], paneInnerRects: ["w1:p1": left, "w1:p2": right],
                        mouseReportingPaneIDs: mouseReporting, splits: [split], graphics: [])
}

/// Where the pointer lands on a surface: panes, splits, words and scroll lines.
final class TerminalPointerTests: XCTestCase {
    func testCellsMapToPanesAndTheirContent() throws {
        let surface = twoPaneSurface()
        XCTAssertEqual(TerminalPointer.paneID(atColumn: 3, row: 2, in: surface), "w1:p1")
        XCTAssertEqual(TerminalPointer.paneID(atColumn: 12, row: 0, in: surface), "w1:p2")
        XCTAssertNil(TerminalPointer.paneID(atColumn: 10, row: 0, in: surface), "The divider belongs to no pane")
        XCTAssertNil(TerminalPointer.paneID(atColumn: 25, row: 0, in: surface))

        let hit = try XCTUnwrap(TerminalPointer.pane(atColumn: 13, row: 3, in: surface))
        XCTAssertEqual(hit.id, "w1:p2")
        XCTAssertEqual([hit.column, hit.row], [2, 3], "Reports are relative to the pane's content")
    }

    func testCellsAreClampedToThePaneContent() {
        let inner = HerdrRect(x: 11, y: 1, width: 9, height: 2)
        let above = TerminalPointer.cell(column: 5, row: 0, inside: inner)
        XCTAssertEqual([above?.column, above?.row], [0, 0])
        let beyond = TerminalPointer.cell(column: 40, row: 9, inside: inner)
        XCTAssertEqual([beyond?.column, beyond?.row], [8, 1])
        XCTAssertNil(TerminalPointer.cell(column: 0, row: 0, inside: HerdrRect(x: 0, y: 0, width: 0, height: 3)))
    }

    func testSplitsAreHitOnTheirDivider() {
        let surface = twoPaneSurface()
        XCTAssertEqual(TerminalPointer.split(atColumn: 10, row: 3, in: surface)?.path, [true])
        XCTAssertNil(TerminalPointer.split(atColumn: 9, row: 3, in: surface))
    }

    func testSplitRatioFollowsThePointerWithinLimits() throws {
        let split = try XCTUnwrap(twoPaneSurface().splits.first)
        XCTAssertEqual(TerminalPointer.splitRatio(split, pointer: 15, grabOffset: 0), 0.75)
        XCTAssertEqual(TerminalPointer.splitRatio(split, pointer: 14, grabOffset: 1), 0.75, "The grab point is kept")
        XCTAssertEqual(TerminalPointer.splitRatio(split, pointer: 40, grabOffset: 0), 0.9)
        XCTAssertEqual(TerminalPointer.splitRatio(split, pointer: -5, grabOffset: 0), 0.1)

        let vertical = HerdrSplit(direction: .vertical, pos: 2, area: HerdrRect(x: 0, y: 2, width: 20, height: 10),
                                  hitRect: HerdrRect(x: 0, y: 4, width: 20, height: 1), path: [])
        XCTAssertEqual(TerminalPointer.splitRatio(vertical, pointer: 5, grabOffset: 0), 0.3)
    }

    func testModifierBits() {
        XCTAssertEqual(TerminalPointer.modifiers([]), 0)
        XCTAssertEqual(TerminalPointer.modifiers([.shift, .control, .option]), 7)
        XCTAssertEqual(TerminalPointer.modifiers([.command, .capsLock]), 0, "Herdr has no bit for Command")
    }

    func testWordsAreRunsOfNonBlankCells() {
        let symbols = "ls -la  src/main.swift".map(String.init)
        XCTAssertEqual(TerminalPointer.wordRange(in: symbols, at: 4), 3..<6)
        XCTAssertEqual(TerminalPointer.wordRange(in: symbols, at: 21), 8..<22)
        XCTAssertEqual(TerminalPointer.wordRange(in: symbols, at: 0), 0..<2)
        XCTAssertNil(TerminalPointer.wordRange(in: symbols, at: 6))
        XCTAssertNil(TerminalPointer.wordRange(in: symbols, at: 99))
    }

    /// A trackpad's small deltas add up to whole lines; a wheel scrolls by its own count.
    func testScrollDeltasBecomeLines() {
        var scroll = TerminalScrollAccumulator()
        XCTAssertNil(scroll.lines(for: 6, precise: true, lineHeight: 16))
        XCTAssertNil(scroll.lines(for: 6, precise: true, lineHeight: 16))
        XCTAssertEqual(scroll.lines(for: 6, precise: true, lineHeight: 16), 1)
        XCTAssertEqual(scroll.remainder, 2)
        XCTAssertEqual(scroll.lines(for: -50, precise: true, lineHeight: 16), 3, "Changing direction scrolls back")
        XCTAssertEqual(scroll.lines(for: 16 * 40, precise: true, lineHeight: 16), 20, "At most 20 lines at once")
        scroll.reset()
        XCTAssertEqual(scroll.remainder, 0)

        XCTAssertEqual(scroll.lines(for: 0.2, precise: false, lineHeight: 16), 1, "A wheel click is at least a line")
        XCTAssertEqual(scroll.lines(for: -3, precise: false, lineHeight: 16), 3)
        XCTAssertEqual(scroll.lines(for: 90, precise: false, lineHeight: 16), 20)
    }
}

/// Inline images and dropped files.
@MainActor
final class TerminalGraphicsAndDropTests: XCTestCase {
    private func graphic(_ format: HerdrGraphicKey.Format, width: Int, height: Int, data: Data) -> HerdrGraphic {
        let key = HerdrGraphicKey(identity: Data([1]), width: width, height: height, format: format,
                                  isPopup: false, dataLength: data.count)
        return HerdrGraphic(key: key, data: data, x: 0, y: 0, cols: 1, rows: 1, sourceX: 0, sourceY: 0,
                            sourceWidth: width, sourceHeight: height, xOffset: 0, yOffset: 0, z: 0)
    }

    func testRawAndPNGImagesDecode() throws {
        let rgba = HerdrTerminalTextView.decodeGraphic(graphic(.rgba, width: 2, height: 3, data: Data(count: 24)))
        XCTAssertEqual(rgba?.size, NSSize(width: 2, height: 3))
        let rgb = HerdrTerminalTextView.decodeGraphic(graphic(.rgb, width: 2, height: 1, data: Data(count: 6)))
        XCTAssertEqual(rgb?.size, NSSize(width: 2, height: 1))

        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertEqual(HerdrTerminalTextView.decodeGraphic(graphic(.png, width: 4, height: 2, data: png))?.size,
                       NSSize(width: 4, height: 2))
    }

    func testMalformedImagesAreSkipped() {
        XCTAssertNil(HerdrTerminalTextView.decodeGraphic(graphic(.rgba, width: 2, height: 2, data: Data(count: 15))),
                     "Too few bytes for the size")
        XCTAssertNil(HerdrTerminalTextView.decodeGraphic(graphic(.png, width: 1, height: 1, data: Data([1, 2, 3]))))
    }

    /// Dropped files paste their escaped paths, as Terminal does; dropped text pastes as is.
    func testDropsPasteEscapedPathsOrText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("xherdr-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let view = HerdrTerminalTextView(usingTextLayoutManager: false)

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/My Files/a (1).txt") as NSURL,
                                 URL(fileURLWithPath: "/tmp/b.txt") as NSURL])
        XCTAssertEqual(view.droppedText(pasteboard), "/tmp/My\\ Files/a\\ \\(1\\).txt /tmp/b.txt ")

        pasteboard.clearContents()
        pasteboard.setString("echo hi", forType: .string)
        XCTAssertEqual(view.droppedText(pasteboard), "echo hi")

        pasteboard.clearContents()
        XCTAssertNil(view.droppedText(pasteboard))
        XCTAssertEqual(HerdrTerminalTextView.shellEscaped("/a/$HOME;rm*.txt"), "/a/\\$HOME\\;rm\\*.txt")
        XCTAssertEqual(HerdrTerminalTextView.shellEscaped("/tmp/café"), "/tmp/café", "Non-ASCII letters stay")
    }
}

/// Mouse input on a live terminal in an offscreen window: selection, reports to mouse-aware
/// programs, split dragging and the context menu.
@MainActor
final class TerminalMouseTests: XCTestCase {
    private var view: HerdrTerminalTextView!
    private var window: NSWindow!
    private var mouse: [String] = []
    private var ratios: [Double] = []
    private var selectedPanes: [String] = []
    private var actions: [String] = []

    private func show(_ surface: HerdrSurface) {
        view = TerminalRenderHarness.makeView(width: surface.width, height: surface.height)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        TerminalRenderHarness.show(surface, in: view)
        view.paneID = "w1:p1"
        view.sendMouse = { [unowned self] event, pane in
            mouse.append("\(pane) \(event.kind) \(event.column),\(event.row) m\(event.modifiers)")
        }
        view.setSplitRatio = { [unowned self] _, ratio in ratios.append(ratio) }
        view.selectPane = { [unowned self] in selectedPanes.append($0) }
        view.onShortcut = { [unowned self] in actions.append($0) }
    }

    override func tearDown() {
        window?.close()
        window = nil
        view = nil
    }

    /// A mouse event over a cell, a quarter of the way in so it also counts as that caret position.
    private func event(_ type: NSEvent.EventType, _ column: Int, _ row: Int, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let inset = view.textContainerInset
        let point = NSPoint(x: inset.width + (CGFloat(column) + 0.25) * TerminalPaneView.cellWidth,
                            y: inset.height + (CGFloat(row) + 0.5) * TerminalPaneView.cellHeight)
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                                  timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    private func click(_ column: Int, _ row: Int, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: event(.leftMouseDown, column, row, clicks: clicks, flags: flags))
        view.mouseUp(with: event(.leftMouseUp, column, row, clicks: clicks, flags: flags))
    }

    func testDraggingSelectsCells() {
        show(twoPaneSurface())
        view.mouseDown(with: event(.leftMouseDown, 0, 0))
        view.mouseDragged(with: event(.leftMouseDragged, 5, 0))
        view.mouseUp(with: event(.leftMouseUp, 5, 0))
        XCTAssertEqual(view.selectedCellText(), "hello")
        XCTAssertEqual(selectedPanes, ["w1:p1"])
        XCTAssertTrue(mouse.isEmpty, "A pane that does not report the mouse gets no events")
    }

    func testDoubleAndTripleClicksSelectAWordAndALine() {
        show(twoPaneSurface())
        click(7, 0, clicks: 2)
        XCTAssertEqual(view.selectedCellText(), "world")
        click(2, 0, clicks: 3)
        XCTAssertEqual(view.selectedCellText()?.trimmingCharacters(in: .whitespaces), "hello world")
        click(15, 2, clicks: 2)
        XCTAssertNil(view.selectedCellText(), "Double-clicking a blank selects nothing")
    }

    func testShiftClickExtendsTheSelection() {
        show(twoPaneSurface())
        click(0, 0)
        click(4, 0, flags: .shift)
        XCTAssertEqual(view.selectedCellText(), "hell")
    }

    /// Programs that ask for the mouse get presses, drags and releases relative to their pane.
    func testMouseReportingPanesReceiveTheMouse() {
        show(twoPaneSurface(mouseReporting: ["w1:p2"]))
        view.mouseDown(with: event(.leftMouseDown, 12, 1, flags: .control))
        view.mouseDragged(with: event(.leftMouseDragged, 14, 2))
        view.mouseUp(with: event(.leftMouseUp, 30, 9))
        XCTAssertEqual(mouse, ["w1:p2 down(0) 1,1 m2", "w1:p2 drag(0) 3,2 m0", "w1:p2 up(0) 8,3 m0"])
        XCTAssertEqual(selectedPanes, ["w1:p2"])
        XCTAssertNil(view.selectedCellText())

        mouse = []
        view.mouseDown(with: event(.leftMouseDown, 12, 0, flags: .shift))
        view.mouseDragged(with: event(.leftMouseDragged, 16, 0, flags: .shift))
        view.mouseUp(with: event(.leftMouseUp, 16, 0, flags: .shift))
        XCTAssertTrue(mouse.isEmpty, "Shift selects text even in a mouse-aware program")
        XCTAssertNotNil(view.selectedCellText())
    }

    func testDraggingADividerResizesTheSplit() {
        show(twoPaneSurface())
        view.mouseDown(with: event(.leftMouseDown, 10, 1))
        view.mouseDragged(with: event(.leftMouseDragged, 15, 1))
        view.mouseDragged(with: event(.leftMouseDragged, 15, 2))
        view.mouseUp(with: event(.leftMouseUp, 16, 1))
        XCTAssertEqual(ratios, [0.75, 0.8], "An unchanged ratio is not sent again")
        XCTAssertTrue(selectedPanes.isEmpty)
        XCTAssertNil(view.selectedCellText())
    }

    /// A drag whose split disappeared, e.g. after the layout changed, stops quietly.
    func testDividerDragStopsWhenTheSplitIsGone() {
        show(twoPaneSurface())
        view.mouseDown(with: event(.leftMouseDown, 10, 1))
        var changed = twoPaneSurface()
        changed.revision = 2
        TerminalRenderHarness.show(HerdrSurface(bootID: "other-boot", projectionRevision: 1, revision: 1,
                                                width: 20, height: 4, cells: changed.cells, cursor: nil,
                                                paneIDs: changed.paneIDs, paneRects: changed.paneRects,
                                                paneInnerRects: changed.paneInnerRects, mouseReportingPaneIDs: [],
                                                splits: changed.splits, graphics: []), in: view)
        view.mouseDragged(with: event(.leftMouseDragged, 15, 1))
        view.mouseUp(with: event(.leftMouseUp, 15, 1))
        XCTAssertTrue(ratios.isEmpty)
    }

    /// The context menu runs Herdr actions, shows their bindings, and offers Copy only with a selection.
    func testContextMenuRunsHerdrActions() throws {
        show(twoPaneSurface())
        let menu = try XCTUnwrap(view.menu(for: event(.rightMouseDown, 2, 1)))
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy" })
        XCTAssertNil(copy.action, "Nothing is selected")

        let items = menu.items + menu.items.compactMap(\.submenu).flatMap(\.items)
        let herdrItems = items.filter { $0.representedObject is String }
        XCTAssertEqual(herdrItems.count, 18)
        for item in herdrItems {
            let action = try XCTUnwrap(item.representedObject as? String)
            XCTAssertNotNil(HerdrCommand(action: action), "\(action) is not a command")
        }
        let split = try XCTUnwrap(items.first { $0.representedObject as? String == "split_vertical" })
        XCTAssertTrue(split.title.hasPrefix("Split Right\t"), split.title)
        XCTAssertNotNil(split.toolTip, "The item shows Herdr's binding")
        _ = (split.target as? NSObject)?.perform(split.action, with: split)
        XCTAssertEqual(actions, ["split_vertical"])

        view.selectAll(nil)
        let selected = try XCTUnwrap(view.menu(for: event(.rightMouseDown, 2, 1))?.items.first { $0.title == "Copy" })
        XCTAssertNotNil(selected.action)
    }
}

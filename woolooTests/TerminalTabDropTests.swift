import AppKit
import XCTest
@testable import wooloo

/// Where a terminal tab dragged onto the panes would split, and which tabs may be dropped.
final class TerminalTabDropTests: XCTestCase {
    private let pane = CGRect(x: 100, y: 50, width: 400, height: 100)

    func testTheNearestSideIsRelativeToThePanesSize() {
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 110, y: 100)), .left)
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 490, y: 100)), .right)
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 300, y: 55)), .top, "Top is minY: views are flipped")
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 300, y: 145)), .bottom)
        // 60 points from the left of a 400-point-wide pane is nearer, relatively, than 30 from
        // the top of a 100-point-high one: the zones follow the diagonals.
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 160, y: 80)), .left)
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 260, y: 80)), .top)
        XCTAssertEqual(TerminalTabDrop.edge(in: pane, at: CGPoint(x: 0, y: 100)), .left, "Points outside are clamped")
    }

    func testTheHighlightCoversThatHalf() {
        XCTAssertEqual(TerminalTabDrop.highlight(of: pane, edge: .left), CGRect(x: 100, y: 50, width: 200, height: 100))
        XCTAssertEqual(TerminalTabDrop.highlight(of: pane, edge: .right), CGRect(x: 300, y: 50, width: 200, height: 100))
        XCTAssertEqual(TerminalTabDrop.highlight(of: pane, edge: .top), CGRect(x: 100, y: 50, width: 400, height: 50))
        XCTAssertEqual(TerminalTabDrop.highlight(of: pane, edge: .bottom), CGRect(x: 100, y: 100, width: 400, height: 50))
    }

    func testHerdrSplitsRightOrDownAndSwapsForLeftAndTop() {
        XCTAssertEqual(TerminalDropEdge.allCases.map(\.split), ["right", "right", "down", "down"])
        XCTAssertEqual(TerminalDropEdge.allCases.map(\.swapsAfterMove), [true, false, true, false])
    }

    func testTheTargetIsThePaneUnderThePointerOrTheNearest() throws {
        let panes: [(id: String, rect: CGRect)] = [("a", CGRect(x: 0, y: 0, width: 100, height: 100)),
                                                   ("b", CGRect(x: 108, y: 0, width: 100, height: 100))]
        let right = try XCTUnwrap(TerminalTabDrop.target(at: CGPoint(x: 190, y: 50), panes: panes))
        XCTAssertEqual(right, TerminalTabDropTarget(paneID: "b", edge: .right,
                                                    highlight: CGRect(x: 158, y: 0, width: 50, height: 100)))
        XCTAssertEqual(TerminalTabDrop.target(at: CGPoint(x: 102, y: 50), panes: panes)?.paneID, "a",
                       "A point on the divider goes to the nearest pane")
        XCTAssertNil(TerminalTabDrop.target(at: .zero, panes: []))
    }

    func testSurfacePanesMapToViewRects() {
        let surface = HerdrSurface(bootID: "boot", projectionRevision: 1, revision: 1, width: 20, height: 4,
                                   cells: [], cursor: nil, paneIDs: ["w1:p1", "w1:p2"],
                                   paneRects: ["w1:p1": HerdrRect(x: 0, y: 0, width: 10, height: 4),
                                               "w1:p2": HerdrRect(x: 11, y: 0, width: 9, height: 4)],
                                   paneInnerRects: [:], mouseReportingPaneIDs: [], splits: [], graphics: [])
        let rects = TerminalTabDrop.paneRects(of: surface, inset: CGSize(width: 10, height: 9),
                                              cell: CGSize(width: 7, height: 15))
        XCTAssertEqual(rects.map(\.id), ["w1:p1", "w1:p2"])
        XCTAssertEqual(rects.map(\.rect), [CGRect(x: 10, y: 9, width: 70, height: 60),
                                           CGRect(x: 87, y: 9, width: 63, height: 60)])
    }

    func testOnlyAnotherTabsOnlyPaneCanSplitIn() throws {
        let json = """
        {"workspaces": [], "agents": [], "focused_workspace_id": null, "focused_tab_id": null, "focused_pane_id": null,
         "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "label": "1"},
                  {"tab_id": "w1:t2", "workspace_id": "w1", "label": "2"},
                  {"tab_id": "w1:t3", "workspace_id": "w1", "label": "3"},
                  {"tab_id": "w1:t4", "workspace_id": "w1", "label": "4"}],
         "panes": [{"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1"},
                   {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2"},
                   {"pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t3"},
                   {"pane_id": "w1:p4", "workspace_id": "w1", "tab_id": "w1:t3"},
                   {"pane_id": "w1:p5", "workspace_id": "w1", "tab_id": "w1:t4"}],
         "layouts": [{"tab_id": "w1:t4", "zoomed": true, "area": {"x": 0, "y": 0, "width": 80, "height": 24},
                      "panes": [{"pane_id": "w1:p5", "rect": {"x": 0, "y": 0, "width": 80, "height": 24}}]}]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.paneToSplit(fromTab: "w1:t2", into: "w1:t1"), "w1:p2")
        XCTAssertNil(snapshot.paneToSplit(fromTab: "w1:t1", into: "w1:t1"), "Not the selected tab itself")
        XCTAssertNil(snapshot.paneToSplit(fromTab: "w1:t3", into: "w1:t1"), "Not a tab with several panes")
        XCTAssertNil(snapshot.paneToSplit(fromTab: "w1:t9", into: "w1:t1"), "Not an unknown tab")
        XCTAssertNil(snapshot.paneToSplit(fromTab: "w1:t2", into: nil))
        XCTAssertNil(snapshot.paneToSplit(fromTab: "w1:t2", into: "w1:t4"), "Herdr refuses a zoomed tab")
        XCTAssertEqual(snapshot.paneToSplit(fromTab: "w1:t4", into: "w1:t2"), "w1:p5", "A zoomed tab may leave")
    }
}

/// Drags reaching the terminal view: tab drags split through the window's handler and never
/// paste; Finder files and text still paste into the pane under the pointer.
@MainActor
final class TerminalTabDropViewTests: XCTestCase {
    /// A drag over the view with a given pasteboard, at a cell of the surface.
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        let draggingDestinationWindow: NSWindow?

        init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
            draggingPasteboard = pasteboard
            draggingLocation = location
            draggingDestinationWindow = window
        }

        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private var view: HerdrTerminalTextView!
    private var window: NSWindow!
    private var overlay: TerminalDropOverlayView!
    private var pasteboard: NSPasteboard!
    private var accepts = true
    private var drops: [String] = []
    private var pastes: [String] = []

    override func setUp() async throws {
        let surface = HerdrSurface(bootID: "boot", projectionRevision: 1, revision: 1, width: 20, height: 4,
                                   cells: Array(repeating: SurfaceModel.blank, count: 80), cursor: nil,
                                   paneIDs: ["w1:p1", "w1:p2"],
                                   paneRects: ["w1:p1": HerdrRect(x: 0, y: 0, width: 10, height: 4),
                                               "w1:p2": HerdrRect(x: 11, y: 0, width: 9, height: 4)],
                                   paneInnerRects: ["w1:p1": HerdrRect(x: 0, y: 0, width: 10, height: 4),
                                                    "w1:p2": HerdrRect(x: 11, y: 0, width: 9, height: 4)],
                                   mouseReportingPaneIDs: [], splits: [], graphics: [])
        view = TerminalRenderHarness.makeView(width: surface.width, height: surface.height)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        overlay = TerminalDropOverlayView(frame: view.frame)
        container.addSubview(overlay)
        window.contentView = container
        view.dropOverlay = overlay
        TerminalRenderHarness.show(surface, in: view)
        view.paneID = "w1:p1"
        view.sendPaste = { [unowned self] text, pane in pastes.append("\(pane) \(text)") }
        view.selectPane = { _ in }
        view.tabDrop = TerminalTabDropHandler(accepts: { [unowned self] in accepts },
                                              drop: { [unowned self] pane, edge in
                                                  drops.append("\(pane) \(edge)")
                                                  return true
                                              })
        pasteboard = NSPasteboard(name: NSPasteboard.Name("wooloo-tests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        window.close()
    }

    /// A drag at a point inside a cell, as a fraction of it.
    private func drag(column: Double, row: Double) -> FakeDrag {
        let inset = view.textContainerInset
        let point = NSPoint(x: inset.width + CGFloat(column) * TerminalPaneView.cellWidth,
                            y: inset.height + CGFloat(row) * TerminalPaneView.cellHeight)
        return FakeDrag(pasteboard: pasteboard, location: view.convert(point, to: nil), window: window)
    }

    private func putTab() {
        pasteboard.clearContents()
        pasteboard.setData(Data("w1:t2".utf8), forType: TerminalTabDrop.pasteboardType)
        pasteboard.setString("w1:t2", forType: .string)
    }

    private var highlight: CGRect? {
        let layer = overlay.layer?.sublayers?.first
        return layer?.isHidden == false ? layer?.frame : nil
    }

    /// A tab drag offers the tab type, which the terminal view looks for on the drag pasteboard,
    /// and the dragged terminal tab ends with the drop.
    func testTerminalTabDragsEndWithTheDrop() throws {
        let drag = TabDragModel()
        let provider = drag.begin(.terminal, id: "w1:t2")
        XCTAssertEqual(provider.registeredTypeIdentifiers, [TerminalTabDrop.pasteboardType.rawValue])
        XCTAssertEqual(drag.draggedTerminalTab, "w1:t2")
        XCTAssertEqual(drag.dropTerminalTab(), "w1:t2")
        XCTAssertNil(drag.draggedTerminalTab)

        _ = drag.begin(.document, id: "doc")
        XCTAssertNil(drag.draggedTerminalTab, "Document tabs never split the panes")
        XCTAssertNil(drag.dropTerminalTab())
    }

    func testTabDragsHighlightTheNearestHalfAndSplitThere() throws {
        putTab()
        XCTAssertEqual(view.draggingEntered(drag(column: 18.5, row: 2)), .move)
        let paneLeft = view.textContainerInset.width + 11 * TerminalPaneView.cellWidth
        let right = try XCTUnwrap(highlight)
        XCTAssertEqual(right.minX, paneLeft + 4.5 * TerminalPaneView.cellWidth + 1, accuracy: 0.01,
                       "The right half of the second pane")

        XCTAssertEqual(view.draggingUpdated(drag(column: 1, row: 2)), .move)
        XCTAssertEqual(try XCTUnwrap(highlight).minX, view.textContainerInset.width + 1, accuracy: 0.01)
        XCTAssertTrue(view.performDragOperation(drag(column: 5, row: 0.2)))
        XCTAssertEqual(drops, ["w1:p1 top"])
        XCTAssertTrue(pastes.isEmpty, "A tab never pastes its ID")
        XCTAssertNil(highlight, "The highlight goes with the drop")
    }

    func testRefusedTabDragsShowNothingAndDropNothing() {
        putTab()
        accepts = false
        XCTAssertEqual(view.draggingEntered(drag(column: 5, row: 2)), [])
        XCTAssertNil(highlight)
        XCTAssertFalse(view.performDragOperation(drag(column: 5, row: 2)))
        XCTAssertTrue(drops.isEmpty)
        XCTAssertTrue(pastes.isEmpty)
    }

    func testLeavingHidesTheHighlight() {
        putTab()
        _ = view.draggingEntered(drag(column: 5, row: 2))
        XCTAssertNotNil(highlight)
        view.draggingExited(drag(column: 30, row: 2))
        XCTAssertNil(highlight)
    }

    func testFilesStillPasteIntoThePaneUnderThePointer() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL])
        XCTAssertEqual(view.draggingEntered(drag(column: 15, row: 2)), .copy)
        XCTAssertNil(highlight, "File drags show no split highlight")
        XCTAssertTrue(view.performDragOperation(drag(column: 15, row: 2)))
        XCTAssertEqual(pastes, ["w1:p2 /tmp/a\\ b.txt "])
        XCTAssertTrue(drops.isEmpty)
    }
}

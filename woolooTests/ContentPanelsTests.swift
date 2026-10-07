import XCTest
@testable import wooloo

/// Splitting the main area into the main panel, which alone shows Herdr's terminals, and panels
/// of documents and Search, and the same rules for every tab type.
@MainActor
final class ContentPanelsTests: XCTestCase {
    private let a = PanelContent.document(UUID())
    private let b = PanelContent.document(UUID())

    // MARK: Layout

    func testPlacingSplitsTheTargetOnThatSide() {
        XCTAssertEqual(PanelLayout.single.placing(a, beside: .main, edge: .right),
                       .split(.horizontal, ratio: 0.5, .panel(.main), .panel(a)))
        XCTAssertEqual(PanelLayout.single.placing(a, beside: .main, edge: .left),
                       .split(.horizontal, ratio: 0.5, .panel(a), .panel(.main)))
        XCTAssertEqual(PanelLayout.single.placing(a, beside: .main, edge: .top),
                       .split(.vertical, ratio: 0.5, .panel(a), .panel(.main)))
        let nested = PanelLayout.single.placing(a, beside: .main, edge: .right).placing(b, beside: a, edge: .bottom)
        XCTAssertEqual(nested, .split(.horizontal, ratio: 0.5, .panel(.main),
                                      .split(.vertical, ratio: 0.5, .panel(a), .panel(b))))
    }

    func testATabShowsInOnePanelOnly() {
        let layout = PanelLayout.single.placing(a, beside: .main, edge: .right).placing(b, beside: a, edge: .bottom)
        let moved = layout.placing(a, beside: .main, edge: .left)
        XCTAssertEqual(moved.contents, [a, .main, b], "Moving a panel closes its old place")
        XCTAssertEqual(layout.replacing(b, with: a).contents, [.main, a], "Replacing with a shown tab moves it")
        XCTAssertEqual(layout.placing(a, beside: a, edge: .left), layout, "A panel never splits beside itself")
        XCTAssertEqual(layout.placing(.main, beside: a, edge: .left), layout, "The main panel never moves")
    }

    func testTheMainPanelIsNeverRemoved() {
        let layout = PanelLayout.single.placing(a, beside: .main, edge: .right)
        XCTAssertEqual(layout.removing(.main), layout)
        XCTAssertEqual(layout.removing(a), .single)
        XCTAssertEqual(layout.keeping { _ in false }, .single)
        XCTAssertEqual(layout.replacing(.main, with: b), layout, "The main panel's content is the tab bar's")
    }

    func testRemovingAPanelGivesItsPlaceToTheOtherHalf() {
        let layout = PanelLayout.single.placing(a, beside: .main, edge: .right).placing(b, beside: a, edge: .bottom)
            .settingRatio(0.3, at: [])
        XCTAssertEqual(layout.removing(a), .split(.horizontal, ratio: 0.3, .panel(.main), .panel(b)))
    }

    func testPanelsAndDividersAreArrangedInWholePoints() {
        let layout = PanelLayout.single.placing(a, beside: .main, edge: .right).placing(b, beside: a, edge: .bottom)
            .settingRatio(0.25, at: [])
        let arranged = layout.arranged(in: CGRect(x: 0, y: 0, width: 401, height: 201))
        XCTAssertEqual(arranged.panels.map(\.content), [.main, a, b])
        XCTAssertEqual(arranged.panels.map(\.frame), [CGRect(x: 0, y: 0, width: 100, height: 201),
                                                      CGRect(x: 101, y: 0, width: 300, height: 100),
                                                      CGRect(x: 101, y: 101, width: 300, height: 100)])
        XCTAssertEqual(arranged.dividers.map(\.path), [[], [true]])
        XCTAssertEqual(arranged.dividers.map(\.frame), [CGRect(x: 100, y: 0, width: 1, height: 201),
                                                        CGRect(x: 101, y: 100, width: 300, height: 1)])
    }

    func testDraggingADividerKeepsBothHalvesUsable() {
        XCTAssertEqual(PanelDrop.ratio(0.5, dragged: 100, in: 1001), 0.6, accuracy: 0.0001)
        XCTAssertEqual(PanelDrop.ratio(0.5, dragged: -1000, in: 1001), 0.16, accuracy: 0.0001)
        XCTAssertEqual(PanelDrop.ratio(0.5, dragged: 1000, in: 1001), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PanelDrop.ratio(0.5, dragged: -1000, in: 401), 0.25, accuracy: 0.0001)
    }

    // MARK: Dropping

    func testTheMiddleReplacesAndTheSidesSplit() {
        let panel = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(PanelDrop.zone(in: panel, at: CGPoint(x: 200, y: 100)), .center)
        XCTAssertEqual(PanelDrop.zone(in: panel, at: CGPoint(x: 390, y: 100)), .edge(.right))
        XCTAssertEqual(PanelDrop.zone(in: panel, at: CGPoint(x: 200, y: 10)), .edge(.top))
        XCTAssertEqual(PanelDrop.highlight(of: panel, zone: .center), panel)
        XCTAssertEqual(PanelDrop.highlight(of: panel, zone: .edge(.right)), CGRect(x: 200, y: 0, width: 200, height: 200))
    }

    func testOnlyDropsThatChangeSomethingAreAccepted() {
        XCTAssertTrue(PanelDrop.accepts(a, on: .main, zone: .edge(.right), mainShows: a),
                      "The main panel's document can leave it for a panel beside it")
        XCTAssertFalse(PanelDrop.accepts(a, on: .main, zone: .center, mainShows: a))
        XCTAssertTrue(PanelDrop.accepts(a, on: .main, zone: .center, mainShows: nil))
        XCTAssertFalse(PanelDrop.accepts(a, on: a, zone: .edge(.left), mainShows: nil))
        XCTAssertFalse(PanelDrop.accepts(a, on: a, zone: .center, mainShows: nil))
        XCTAssertTrue(PanelDrop.accepts(.search, on: a, zone: .center, mainShows: nil))
        XCTAssertFalse(PanelDrop.accepts(.main, on: a, zone: .edge(.left), mainShows: nil))
    }

    func testOnlyDocumentAndSearchDragsReachThePanels() {
        let drag = TabDragModel()
        _ = drag.begin(.terminal, id: "w1:t2")
        XCTAssertNil(drag.draggedPanelTab, "Terminal tabs split inside Herdr instead")
        XCTAssertEqual(drag.draggedTerminalTab, "w1:t2")
        _ = drag.begin(.search, id: WorkspaceSearchModel.tabID)
        XCTAssertEqual(drag.dropPanelTab(), WorkspaceSearchModel.tabID)
        XCTAssertNil(drag.draggedPanelTab, "Dropping ends the drag")
        XCTAssertEqual(TabDragModel.type(of: .terminal), TabDragModel.type)
        XCTAssertEqual(TabDragModel.type(of: .document), TabDragModel.panelType)
        XCTAssertEqual(TabDragModel.type(of: .search), TabDragModel.panelType)
    }

    // MARK: Commands

    private let location = WorkspaceFileLocation(machine: nil, session: "test", workspaceID: "w1",
                                                 workspaceLabel: "w1", root: "/tmp/wooloo-panels")

    private func makeCommands() -> (ContentCommands, WorkspaceDocumentStore, ContentWindowModel) {
        let window = ContentWindowModel(defaults: UserDefaults(suiteName: "ContentPanelsTests-\(UUID())")!)
        let documents = WorkspaceDocumentStore(persistence: nil)
        documents.showSpace("test|w1")
        let commands = ContentCommands(window: window, herdr: HerdrStore(), documents: documents,
                                       search: WorkspaceSearchModel(), explorerLocation: location)
        return (commands, documents, window)
    }

    func testDraggingTheMainDocumentBesideItLeavesTheTerminalsInTheMainPanel() throws {
        let (commands, documents, window) = makeCommands()
        let id = documents.newUntitled(at: location)
        let document = try XCTUnwrap(documents.document(id))
        XCTAssertEqual(documents.activeID, id)

        XCTAssertTrue(commands.dropTab(id, on: .main, zone: .edge(.right)))
        XCTAssertEqual(commands.panelLayout.contents, [.main, .document(document.backupID)])
        XCTAssertNil(documents.activeID, "The main panel shows the terminals again")
        XCTAssertEqual(window.focusedPanel, .document(document.backupID))
        XCTAssertEqual(commands.focusedDocumentID, id, "Editor commands and ⌘W follow the focused panel")

        XCTAssertFalse(commands.dropTab(id, on: .document(document.backupID), zone: .edge(.left)))
        XCTAssertTrue(commands.dropTab(id, on: .main, zone: .center))
        XCTAssertEqual(commands.panelLayout, .single)
        XCTAssertEqual(documents.activeID, id)
        XCTAssertEqual(window.focusedPanel, .main)
    }

    func testSelectingATabWithAPanelFocusesThatPanel() throws {
        let (commands, documents, window) = makeCommands()
        let first = documents.newUntitled(at: location)
        let second = documents.newUntitled(at: location)
        let firstContent = try XCTUnwrap(commands.panelContent(forTab: first))
        commands.dropTab(first, on: .main, zone: .edge(.bottom))
        commands.selectTab(second)
        XCTAssertEqual(documents.activeID, second)
        XCTAssertEqual(window.focusedPanel, .main)

        commands.selectTab(first)
        XCTAssertEqual(documents.activeID, second, "The main panel keeps its document")
        XCTAssertEqual(window.focusedPanel, firstContent)

        // Opening it some other way, as from the explorer, does the same.
        commands.focusPanel(.main)
        documents.activeID = first
        commands.activeDocumentChanged(from: second, to: first)
        XCTAssertEqual(documents.activeID, second)
        XCTAssertEqual(window.focusedPanel, firstContent)
    }

    func testClosingATabClosesItsPanel() throws {
        let (commands, documents, window) = makeCommands()
        let id = documents.newUntitled(at: location)
        commands.splitTab(id, edge: .right)
        XCTAssertTrue(commands.panelLayout.isSplit)
        documents.close(id, force: true)
        commands.prunePanels()
        XCTAssertEqual(commands.panelLayout, .single)
        XCTAssertEqual(window.focusedPanel, .main)
        XCTAssertTrue(window.panelLayouts.isEmpty)
    }

    func testSearchSplitsLikeADocument() {
        let (commands, documents, window) = makeCommands()
        commands.openSearch(replace: false)
        XCTAssertEqual(documents.activeID, WorkspaceSearchModel.tabID)
        commands.splitTab(WorkspaceSearchModel.tabID, edge: .right)
        XCTAssertEqual(commands.panelLayout.contents, [.main, .search])
        XCTAssertNil(documents.activeID)
        commands.openSearch(replace: true)
        XCTAssertNil(documents.activeID, "Opening Search again focuses its panel")
        XCTAssertEqual(window.focusedPanel, .search)
        commands.closeSearch()
        XCTAssertEqual(commands.panelLayout, .single)
    }
}

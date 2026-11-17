import XCTest
@testable import wooloo

/// wooloo's arrangement of herdr-core terminals: the `wooloo` document, reconciliation with the
/// terminals Core reports, pane trees and their layout.
final class CoreStructureTests: XCTestCase {
    private typealias Node = CoreStructure.Node

    private func terminal(_ address: String, space: String? = nil, state: String = "live") -> CoreTerminal {
        CoreTerminal(address: address, labels: space.map { [CoreStructure.spaceLabel: $0] } ?? [:], state: state)
    }

    private let arranged = CoreStructure(spaces: [
        .init(id: "s1", name: "api", folder: "/src/api", tabs: [
            .init(id: "a", name: "server", root: .split(.right, ratio: 0.5, first: .terminal("t1"), second: .terminal("t2"))),
            .init(id: "b", name: nil, root: .terminal("t3")),
        ]),
        .init(id: "s2", name: "docs", folder: nil, tabs: [.init(id: "c", name: nil, root: .terminal("t4"))]),
    ])

    func testTheDocumentRoundTripsAndKeepsUnknownFields() throws {
        let previous: [String: Any] = ["schema": 1, "spaces": [], "future": ["keep": true]]
        let encoded = arranged.encoded(over: previous)
        XCTAssertEqual((encoded["future"] as? [String: Bool])?["keep"], true)
        let data = try JSONSerialization.data(withJSONObject: encoded)
        XCTAssertEqual(CoreStructure.decode(try JSONSerialization.jsonObject(with: data)), arranged)
    }

    func testUntrustedDocumentsAreReadDefensively() {
        XCTAssertNil(CoreStructure.decode(nil))
        XCTAssertNil(CoreStructure.decode(["schema": 2, "spaces": []]))
        XCTAssertNil(CoreStructure.decode(["schema": 1, "spaces": "no"]))
        let hostile: [String: Any] = ["schema": 1, "spaces": [
            ["id": "s1", "name": "ok", "folder": "relative/path", "tabs": [
                ["id": "a", "root": ["terminal": "t1"]],
                ["id": "b", "root": ["split": "sideways", "first": ["terminal": "t2"], "second": ["terminal": "t3"]]],
                ["id": "c", "root": ["split": "down", "ratio": 7.0, "first": ["terminal": "t4"], "second": ["terminal": "t5"]]],
            ]],
            ["name": "no id", "tabs": []],
        ]]
        let decoded = CoreStructure.decode(hostile)
        XCTAssertEqual(decoded?.spaces.count, 1)
        XCTAssertNil(decoded?.spaces.first?.folder, "Only absolute folders are kept")
        XCTAssertEqual(decoded?.spaces.first?.tabs.map(\.id), ["a", "c"])
        XCTAssertEqual(decoded?.spaces.first?.tabs.last?.root,
                       .split(.down, ratio: 0.95, first: .terminal("t4"), second: .terminal("t5")))
    }

    func testGoneTerminalsLeaveTheTreeAndLooseOnesAreFiled() {
        let terminals = [terminal("t2"), terminal("t4"), terminal("t5", space: "s1"), terminal("t6"),
                         terminal("t7", space: "gone"), terminal("t8", state: "finished"), terminal("box/t1")]
        let result = arranged.reconciled(with: terminals)
        XCTAssertEqual(result.spaces.map(\.id), ["s1", "s2", CoreStructure.unfiledID])
        XCTAssertEqual(result.spaces[0].tabs.map(\.id), ["a", "tab-t5"], "Tab b lost its only terminal")
        XCTAssertEqual(result.spaces[0].tabs[0].root, .terminal("t2"), "A split left with one side becomes that side")
        XCTAssertEqual(result.spaces[0].tabs[0].name, "server")
        XCTAssertEqual(result.spaces[2].tabs.map(\.root), [.terminal("t6"), .terminal("t7")])
        XCTAssertEqual(result.spaces[2].name, "Unfiled")
    }

    func testALostDocumentRebuildsFromLabels() {
        let result = CoreStructure().reconciled(with: [terminal("t1", space: "s1"), terminal("t2")])
        XCTAssertEqual(result.spaces.map(\.id), [CoreStructure.unfiledID])
        XCTAssertEqual(result.terminals, ["t1", "t2"])
    }

    func testTreeEdits() {
        let tree = Node.terminal("t1")
        let split = tree.splitting("t1", with: "t2", direction: .down)
        XCTAssertEqual(split, .split(.down, ratio: 0.5, first: .terminal("t1"), second: .terminal("t2")))
        XCTAssertEqual(tree.splitting("t1", with: "t2", direction: .right, newFirst: true),
                       .split(.right, ratio: 0.5, first: .terminal("t2"), second: .terminal("t1")))
        let nested = split.splitting("t2", with: "t3", direction: .right)
        XCTAssertEqual(nested.terminals, ["t1", "t2", "t3"])
        XCTAssertEqual(nested.settingRatio(0.3, at: [true][...]),
                       .split(.down, ratio: 0.5, first: .terminal("t1"),
                              second: .split(.right, ratio: 0.3, first: .terminal("t2"), second: .terminal("t3"))))
        XCTAssertEqual(nested.swapping("t1", "t3").terminals, ["t3", "t2", "t1"])
        XCTAssertNil(tree.filtered { _ in false })
    }

    func testLayoutLeavesABorderBetweenSides() {
        let tree = Node.split(.right, ratio: 0.5, first: .terminal("t1"),
                              second: .split(.down, ratio: 0.5, first: .terminal("t2"), second: .terminal("t3")))
        let area = HerdrRect(x: 0, y: 0, width: 81, height: 25)
        let panes = CoreLayout.panes(tree, in: area)
        XCTAssertEqual(panes.map(\.terminal), ["t1", "t2", "t3"])
        XCTAssertEqual(panes[0].rect, HerdrRect(x: 0, y: 0, width: 40, height: 25))
        XCTAssertEqual(panes[1].rect, HerdrRect(x: 41, y: 0, width: 40, height: 12))
        XCTAssertEqual(panes[2].rect, HerdrRect(x: 41, y: 13, width: 40, height: 12))
        let splits = CoreLayout.splits(tree, in: area)
        XCTAssertEqual(splits.map(\.position), [40, 12])
        XCTAssertEqual(splits.map(\.path), [[], [true]])
        XCTAssertEqual(CoreLayout.panes(tree, in: HerdrRect(x: 0, y: 0, width: 2, height: 2)).map(\.terminal), ["t1"],
                       "A pane too small to split shows its first side")
        XCTAssertEqual(CoreLayout.visible(tree, zoomed: "t3"), .terminal("t3"))
        XCTAssertEqual(CoreLayout.visible(tree, zoomed: "gone"), tree, "A zoom on a pane that left the tab shows the tab")
    }

    func testSnapshotsShowTheArrangement() {
        let terminals = [CoreTerminal(address: "t1", argv: ["/bin/zsh"], cols: 81, rows: 25, cwd: "/src/api"),
                         CoreTerminal(address: "t2", argv: ["claude"], cols: 81, rows: 25, cwd: "/src/api",
                                      labels: ["herdr.seen": "2"],
                                      status: CoreStatus(state: "done", app: "claude", msg: nil, title: nil), turn: 3),
                         CoreTerminal(address: "t3", cwd: "/src/api"), CoreTerminal(address: "t4")]
        let structure = arranged.reconciled(with: terminals)
        let snapshot = CoreSessionBackend.snapshot(of: structure, terminals: terminals, core: nil,
                                                   focus: (space: "s1", tab: "a", pane: "t2"))
        XCTAssertEqual(snapshot.workspaces.map(\.label), ["api", "docs"])
        XCTAssertEqual(snapshot.tabs.map(\.label), ["server", "t3", "t4"])
        XCTAssertEqual(snapshot.panes.filter { $0.tabID == "a" }.map(\.paneID), ["t1", "t2"])
        XCTAssertEqual(snapshot.layouts.first?.panes.map(\.rect.width), [40, 40])
        XCTAssertEqual(snapshot.agents.first?.agentStatus, "done", "Turn 3 is past the seen turn 2")
        XCTAssertEqual(snapshot.focusedPaneID, "t2")
    }

    func testAgentStatesFollowTheSeenLabel() {
        func state(_ reported: String, turn: UInt64, seen: String?) -> String? {
            CoreSessionBackend.agentState(CoreTerminal(address: "t", labels: seen.map { ["herdr.seen": $0] } ?? [:],
                                                       status: CoreStatus(state: reported, app: nil, msg: nil, title: nil),
                                                       turn: turn))
        }
        XCTAssertEqual(state("done", turn: 4, seen: "4"), "idle")
        XCTAssertEqual(state("idle", turn: 5, seen: "4"), "done")
        XCTAssertEqual(state("done", turn: 4, seen: nil), "done")
        XCTAssertEqual(state("blocked", turn: 9, seen: "9"), "blocked")
        XCTAssertEqual(state("working", turn: 1, seen: "0"), "working")
        XCTAssertNil(CoreSessionBackend.agentState(CoreTerminal(address: "t")))
    }
}

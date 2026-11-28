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

    func testWorktreeCheckoutsAreKeptOnlyForSpacesThatExist() throws {
        var structure = arranged
        structure.worktrees = ["s1": "/src/api", "gone": "/src/old"]
        let encoded = structure.encoded(over: ["schema": 1, "spaces": [], "worktrees": ["stale": "/src/x"]])
        XCTAssertEqual(encoded["worktrees"] as? [String: String], ["s1": "/src/api"])
        let data = try JSONSerialization.data(withJSONObject: encoded)
        XCTAssertEqual(CoreStructure.decode(try JSONSerialization.jsonObject(with: data))?.worktrees, ["s1": "/src/api"])
        XCTAssertNil(arranged.encoded(over: ["schema": 1, "spaces": [], "worktrees": ["s1": "/src/x"]])["worktrees"],
                     "An arrangement without worktrees removes the field")
        let later = arranged.encoded(over: ["schema": 1, "spaces": [],
                                            "worktrees": ["s2": ["path": "/src/docs"], "gone": ["path": "/src/old"]]])
        XCTAssertEqual((later["worktrees"] as? [String: Any])?["s2"] as? [String: String], ["path": "/src/docs"],
                       "A later build's entry of a remaining Space is kept")
        XCTAssertNil((later["worktrees"] as? [String: Any])?["gone"])
        XCTAssertEqual(CoreStructure.decode(later)?.worktrees, [:], "and not read as a checkout")
        let richer: [String: Any] = ["schema": 1, "spaces": [["id": "s2", "name": "docs", "folder": "/src/docs", "tabs": [Any]()]],
                                     "worktrees": ["s2": ["path": "/src/docs"]]]
        let foreign = try XCTUnwrap(CoreStructure.decode(richer))
        XCTAssertEqual(foreign.foreignWorktrees, ["s2"])
        XCTAssertFalse(CoreSessionBackend.adoptable(foreign.spaces[0], checkout: "/src/docs", in: foreign),
                       "A Space with a checkout this build cannot read is not adopted")

        // A build before worktrees rewrote the Spaces and kept the top-level field.
        let older: [String: Any] = ["schema": 1, "spaces": [["id": "s1", "name": "api", "tabs": []],
                                                            ["id": "s2", "name": "docs", "tabs": []]],
                                    "worktrees": ["s1": "/src/api", "s2": "relative", "s4": 7, "": "/a", "s9": "/src/s9"]]
        XCTAssertEqual(CoreStructure.decode(["schema": 1, "spaces": []])?.worktrees, [:])
        XCTAssertEqual(CoreStructure.decode(older)?.worktrees, ["s1": "/src/api"], "Only absolute paths of known Spaces are kept")

        structure.worktrees = ["s2": "/src/docs"]
        let live = structure.reconciled(with: [terminal("t1"), terminal("t4")])
        XCTAssertEqual(live.worktrees, ["s2": "/src/docs"])
        XCTAssertEqual(CoreSessionBackend.snapshot(of: live, terminals: [terminal("t1"), terminal("t4")], core: nil)
                           .workspaces.map(\.worktree?.checkoutPath), [nil, "/src/docs"])
        XCTAssertEqual(structure.reconciled(with: [terminal("t1")]).worktrees, [:], "Space s2 lost its only terminal")
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

    // MARK: The official app's document

    private let appDocument: [String: Any] = ["version": 9, "spaces": [
        ["id": "s1", "name": "", "folder": "/src/web", "tabs": [
            ["id": "a", "name": "dev", "root": ["type": "row", "children": [
                ["type": "block", "content": ["terminal": "t1"], "size": ["weight": 3.0]],
                ["type": "column", "size": ["weight": 1.0], "children": [
                    ["type": "block", "content": ["terminal": "t2"]],
                    ["type": "block", "content": ["terminal": "t3"]],
                    ["type": "block", "content": ["terminal": "gone"]],
                    ["type": "webview", "content": ["url": "https://example.com"]],
                ]],
            ], "floating": [["content": ["terminal": "t4"]], ["content": ["mod": "clock"]]]]],
            ["id": "b", "root": ["type": "block", "content": ["terminal": "t1"]]],
            ["id": "a", "root": ["type": "block", "content": ["terminal": "t5"]]],
        ]],
        ["id": "s2", "name": "notes", "tabs": [["id": "c", "root": ["type": "block", "content": ["terminal": "t6"]]]]],
        ["id": "s3", "name": "empty", "tabs": []],
        "not a space",
    ]]

    func testTheAppsDocumentIsReadDefensively() {
        let spaces = HerdrAppStructure.spaces(in: appDocument, live: ["t1", "t2", "t3", "t4", "t5", "t6"])
        XCTAssertEqual(spaces.map(\.id), ["app:s1", "app:s2"], "Spaces with no live terminal are left out")
        XCTAssertEqual(spaces[0].name, "web", "An unnamed Space is named after its folder")
        XCTAssertEqual(spaces[0].tabs.map(\.id), ["app:s1:a"], "A terminal shows once; a repeated tab id is skipped")
        XCTAssertEqual(spaces[0].tabs[0].name, "dev")
        XCTAssertEqual(spaces[0].tabs[0].root,
                       .split(.right, ratio: 0.5,
                              first: .split(.right, ratio: 0.75, first: .terminal("t1"),
                                            second: .split(.down, ratio: 0.5, first: .terminal("t2"), second: .terminal("t3"))),
                              second: .terminal("t4")),
                       "Weights become ratios, columns stack, floating terminals join the tab, other content is skipped")
        XCTAssertTrue(HerdrAppStructure.spaces(in: ["spaces": "no"], live: ["t1"]).isEmpty)
        XCTAssertTrue(HerdrAppStructure.spaces(in: nil, live: ["t1"]).isEmpty)
    }

    func testWoolooKeepsItsOwnAndTheAppFilesTheRest() {
        let mine = CoreStructure(spaces: [.init(id: "w", name: "mine", folder: nil, tabs: [.init(id: "x", name: nil, root: .terminal("t1"))])])
        let terminals = ["t1", "t2", "t3", "t6", "t7", "t8"].map { terminal($0) }
            + [CoreTerminal(address: "t9", labels: [HerdrAppStructure.spaceLabel: "s2"], state: "live")]
        let result = mine.reconciled(with: terminals, app: appDocument)
        XCTAssertEqual(result.spaces.map(\.id), ["w", "app:s1", "app:s2", CoreStructure.unfiledID])
        XCTAssertEqual(result.spaces[0].tabs.first?.root, .terminal("t1"), "wooloo's document wins for a terminal it holds")
        XCTAssertEqual(result.spaces[1].tabs.first?.root.terminals, ["t2", "t3"])
        XCTAssertEqual(result.spaces[2].tabs.map(\.root), [.terminal("t6"), .terminal("t9")], "The app's label files t9")
        XCTAssertEqual(result.spaces[3].tabs.map(\.root), [.terminal("t7"), .terminal("t8")])
    }
}

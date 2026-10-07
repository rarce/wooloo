import Combine
import XCTest
@testable import wooloo

enum AgentViewFixture {
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    static func agent(_ pane: String, workspace: String = "w1", tab: String = "w1:t1",
                      status: String = "working", sequence: UInt64 = 1, tokens: [[String]] = []) -> [String: Any] {
        ["pane_id": pane, "workspace_id": workspace, "tab_id": tab, "agent": "codex", "name": pane,
         "agent_status": status, "state_change_seq": sequence, "state_labels": [["working", "Busy"]], "tokens": tokens]
    }

    static func snapshot(_ agents: [[String: Any]], revision: UInt64 = 1, boot: String = "boot-test",
                         label: String? = "Focus") -> [String: Any] {
        ["boot_id": boot, "revision": revision, "agent_view_label": label as Any? ?? NSNull(),
         "workspaces": [["workspace_id": "w1"], ["workspace_id": "w2"]],
         "tabs": [["tab_id": "w1:t1", "number": 1], ["tab_id": "w2:t1", "number": 1]], "agents": agents]
    }

    static func view(filter: [String: Any]? = nil, sort: [[String: Any]] = []) -> [String: Any] {
        var view: [String: Any] = ["source": "plugin:example.views", "label": "Focus", "sort": sort]
        view["filter"] = filter
        return view
    }

    static func projection(agents: [[String: Any]], view: [String: Any]? = nil, revision: UInt64 = 1,
                           boot: String = "boot-test", completions: [String: UInt64]? = nil) throws -> HerdrAgentProjection {
        HerdrAgentProjection(snapshot: try JSONDecoder().decode(HerdrAgentSnapshot.self,
                                                               from: data(snapshot(agents, revision: revision, boot: boot, label: view == nil ? nil : "Focus"))),
                             view: try view.map { try JSONDecoder().decode(HerdrAgentView.self, from: data($0)) },
                             unavailable: false, completions: completions)
    }

    static func state(_ agents: [[String: Any]], view: [String: Any]) throws -> HerdrAgentViewState {
        var presentation = HerdrAgentPresentation()
        return presentation.receive(try projection(agents: agents, view: view))
    }
}

final class HerdrAgentViewTests: XCTestCase {
    func testComposedQueryKeepsSpaceFilterAndPluginOrder() throws {
        let filter: [String: Any] = ["op": "all", "filters": [
            ["op": "in", "field": "status", "values": ["working", "blocked"]],
            ["op": "not", "filter": ["op": "eq", "field": ["token": "team"], "value": "other"]]
        ]]
        let state = try AgentViewFixture.state([
            AgentViewFixture.agent("w1:p1", sequence: 4, tokens: [["team", "ours"]]),
            AgentViewFixture.agent("w2:p1", workspace: "w2", tab: "w2:t1", status: "blocked", sequence: 8),
            AgentViewFixture.agent("w1:p2", sequence: 9, tokens: [["team", "other"]]),
            AgentViewFixture.agent("w1:p3", sequence: 7)
        ], view: AgentViewFixture.view(filter: filter, sort: [["field": "state_change_seq", "order": "desc"]]))
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: "w1:t1", spaceOnly: false, followView: true).map(\.paneID),
                       ["w2:p1", "w1:p3", "w1:p1"])
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: "w1:t1", spaceOnly: true, followView: true).map(\.paneID),
                       ["w1:p3", "w1:p1"])
        XCTAssertEqual(state.agents(workspaceID: "w2", tabID: "w2:t1", spaceOnly: true, followView: true).map(\.paneID), ["w2:p1"])
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: "w1:t1", spaceOnly: true, followView: false).map(\.paneID),
                       ["w1:p1", "w1:p2", "w1:p3"], "Bypassing the view must preserve the Space scope")
    }

    func testCurrentSpaceAndTabOperandsTrackTheWindowSelection() throws {
        let state = try AgentViewFixture.state([
            AgentViewFixture.agent("w1:p1"), AgentViewFixture.agent("w2:p1", workspace: "w2", tab: "w2:t1")
        ], view: AgentViewFixture.view(filter: ["op": "any", "filters": [
            ["op": "eq", "field": "workspace_id", "value": ["context": "current_workspace_id"]],
            ["op": "eq", "field": "tab_id", "value": ["context": "current_tab_id"]]
        ]]))
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: "w1:t1", spaceOnly: false, followView: true).map(\.paneID), ["w1:p1"])
        XCTAssertEqual(state.agents(workspaceID: "w2", tabID: "w2:t1", spaceOnly: false, followView: true).map(\.paneID), ["w2:p1"])
        XCTAssertTrue(state.agents(workspaceID: nil, tabID: nil, spaceOnly: false, followView: true).isEmpty)
    }

    func testTokenSortIsStableAndMissingValuesStayLastInBothDirections() throws {
        let agents = [AgentViewFixture.agent("w1:p1", tokens: [["rank", "a"]]),
                      AgentViewFixture.agent("w1:p2"), AgentViewFixture.agent("w1:p3", tokens: [["rank", "z"]]),
                      AgentViewFixture.agent("w1:p4", tokens: [["rank", "a"]])]
        for (order, expected) in [("asc", ["w1:p1", "w1:p4", "w1:p3", "w1:p2"]),
                                  ("desc", ["w1:p3", "w1:p1", "w1:p4", "w1:p2"])] {
            let state = try AgentViewFixture.state(agents, view: AgentViewFixture.view(sort: [["field": ["token": "rank"], "order": order]]))
            XCTAssertEqual(state.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true).map(\.paneID), expected)
        }
        let exists = try AgentViewFixture.state(agents, view: AgentViewFixture.view(filter: ["op": "exists", "field": ["token": "rank"]]))
        XCTAssertEqual(exists.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true).count, 3)
    }

    func testNumericSortUsesFullPrecisionAndHerdrPaneNumbers() throws {
        let agents = [AgentViewFixture.agent("w1:pA", sequence: UInt64.max),
                      AgentViewFixture.agent("w1:p9", sequence: UInt64.max - 1)]
        let state = try AgentViewFixture.state(agents, view: AgentViewFixture.view(sort: [["field": "state_change_seq"]]))
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true).map(\.paneID), ["w1:p9", "w1:pA"])
        XCTAssertEqual(HerdrAgentViewRow.publicNumber("9"), 9)
        XCTAssertEqual(HerdrAgentViewRow.publicNumber("A"), 10)
        XCTAssertEqual(HerdrAgentViewRow.publicNumber("11"), 33)
        XCTAssertNil(HerdrAgentViewRow.publicNumber("not-a-pane"))
    }

    func testDefaultPrioritySortAppliesOnlyWhenTheViewDoesNotSpecifySort() throws {
        let agents = [AgentViewFixture.agent("w1:p1", sequence: 8),
                      AgentViewFixture.agent("w2:p1", workspace: "w2", tab: "w2:t1", status: "blocked", sequence: 3)]
        let state = try AgentViewFixture.state(agents, view: AgentViewFixture.view())
        XCTAssertEqual(state.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true, prioritySort: true).map(\.paneID), ["w2:p1", "w1:p1"])
        let explicit = try AgentViewFixture.state(agents, view: AgentViewFixture.view(sort: [["field": "state_change_seq", "order": "desc"]]))
        XCTAssertEqual(explicit.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true, prioritySort: true).map(\.paneID), ["w1:p1", "w2:p1"])
        XCTAssertNotEqual(HerdrAgentValue.string("é"), .string("e\u{301}"), "Match Herdr's bytewise string comparisons")
    }

    func testInvalidRulesRejectTheWholeQuery() throws {
        let filters: [[String: Any]] = [
            ["op": "future", "field": "status"], ["op": "all", "filters": []],
            ["op": "eq", "field": "seen", "value": 1],
            ["op": "eq", "field": "workspace_id", "value": ["context": "current_tab_id"]],
            ["op": "exists", "field": "attention"], ["op": "eq", "field": "status", "value": "future"]
        ]
        for filter in filters {
            XCTAssertThrowsError(try JSONDecoder().decode(HerdrAgentView.self, from: AgentViewFixture.data(AgentViewFixture.view(filter: filter))))
        }
        var deep: [String: Any] = ["op": "exists", "field": "agent"]
        for _ in 0..<8 { deep = ["op": "not", "filter": deep] }
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrAgentView.self, from: AgentViewFixture.data(AgentViewFixture.view(filter: deep))))
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrAgentView.self, from: AgentViewFixture.data(AgentViewFixture.view(sort: [["field": "pane_id"]]))))
    }

    func testViewReplacementClearAndRevisionsStayCoherent() throws {
        var decoder = HerdrAgentProjectionDecoder()
        let agents = [AgentViewFixture.agent("w1:p1")]
        let query = AgentViewFixture.view(filter: ["op": "eq", "field": "status", "value": "blocked"])
        let message: [String: Any] = ["boot_id": "boot-test", "revision": 2, "view": query]
        XCTAssertNil(decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(message)))
        let old = try XCTUnwrap(decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot(agents))))
        XCTAssertNil(old.view)
        XCTAssertTrue(old.unavailable, "A label without its matching query must not apply a stale filter")
        let next = try XCTUnwrap(decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot(agents, revision: 2))))
        XCTAssertNotNil(next.view)
        XCTAssertFalse(next.unavailable)
        XCTAssertNil(decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot([], revision: 1))))
        _ = decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(["boot_id": "boot-test", "revision": 3, "view": NSNull()]))
        let clear = try XCTUnwrap(decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot(agents, revision: 3, label: nil))))
        XCTAssertNil(clear.view)
        XCTAssertFalse(clear.unavailable)
        _ = decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(["boot_id": "boot-test", "revision": 4, "view": query]))
        let reboot = try XCTUnwrap(decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot(agents, boot: "new-boot", label: nil))))
        XCTAssertNil(reboot.view, "Views do not cross endpoint boots")
    }

    func testLateCompanionsMatchOnlyTheirOwnSnapshot() throws {
        var decoder = HerdrAgentProjectionDecoder()
        let agents = [AgentViewFixture.agent("w1:p1")]
        _ = decoder.receive(kind: "shell.snapshot.v1", data: try AgentViewFixture.data(AgentViewFixture.snapshot(agents, revision: 3)))
        XCTAssertNil(decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(["boot_id": "boot-test", "revision": 2, "view": AgentViewFixture.view()])))
        let late = decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(["boot_id": "boot-test", "revision": 3, "view": AgentViewFixture.view()]))
        XCTAssertNotNil(late?.view)
        let unknown = decoder.receive(kind: "endpoint.agent-view.v1", data: try AgentViewFixture.data(["boot_id": "boot-test", "revision": 3, "view": AgentViewFixture.view(filter: ["op": "future"])]))
        XCTAssertTrue(unknown?.unavailable == true)
        XCTAssertNil(unknown?.view)
    }

    func testCompletionsBecomeSeenOnlyAfterAMatchingSurface() throws {
        let view = AgentViewFixture.view(filter: ["op": "eq", "field": "seen", "value": false])
        var presentation = HerdrAgentPresentation()
        _ = presentation.receive(try AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1")], view: view, completions: [:]))
        let completed = try presentation.receive(AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", status: "idle", sequence: 2)],
                                                                             view: view, revision: 2, completions: ["w1:p1": 2]))
        XCTAssertEqual(completed.agents.first?.agentStatus, "done")
        XCTAssertEqual(completed.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true).count, 1)
        var surface = SurfaceModel(width: 2, height: 1)
        XCTAssertNil(presentation.acknowledge(surface.surface), "Old surfaces must not mark a new completion seen")
        surface.projectionRevision = 2
        surface.bootID = "another-boot"
        XCTAssertNil(presentation.acknowledge(surface.surface))
        surface.bootID = "boot-test"
        let seen = try XCTUnwrap(presentation.acknowledge(surface.surface))
        XCTAssertEqual(seen.agents.first?.agentStatus, "idle")
        XCTAssertTrue(seen.agents(workspaceID: "w1", tabID: nil, spaceOnly: false, followView: true).isEmpty)
        XCTAssertNil(presentation.acknowledge(surface.surface), "Repeated draws must not publish repeatedly")
    }

    func testStartupIdleAndSuppressedCompletionsAreNotUnreadWork() throws {
        var presentation = HerdrAgentPresentation()
        let baseline = try presentation.receive(AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", status: "idle", sequence: 5)],
                                                                            completions: ["w1:p1": 5]))
        XCTAssertEqual(baseline.agents.first?.agentStatus, "idle")
        _ = presentation.receive(try AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", sequence: 6)], revision: 2, completions: [:]))
        let suppressed = try presentation.receive(AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", status: "idle", sequence: 7)],
                                                                              revision: 3, completions: [:]))
        XCTAssertEqual(suppressed.agents.first?.agentStatus, "idle", "An authoritative empty map suppresses the fallback")
        _ = presentation.receive(try AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", sequence: 8)], revision: 4))
        let fallback = try presentation.receive(AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", status: "idle", sequence: 9)], revision: 5))
        XCTAssertEqual(fallback.agents.first?.agentStatus, "done")
        let reboot = try presentation.receive(AgentViewFixture.projection(agents: [AgentViewFixture.agent("w1:p1", status: "idle", sequence: 9)], boot: "new-boot"))
        XCTAssertEqual(reboot.agents.first?.agentStatus, "idle")
    }

    @MainActor
    func testStoreKeepsSelectionAndDoesNotPublishRevisionOnlyChanges() throws {
        let store = HerdrStore()
        store.selectedWorkspaceID = "w1"
        store.selectedTabID = "w1:t1"
        store.selectedPaneID = "w1:p1"
        let agents = [AgentViewFixture.agent("w1:p1"), AgentViewFixture.agent("w2:p1", workspace: "w2", tab: "w2:t1", status: "blocked")]
        let view = AgentViewFixture.view(filter: ["op": "eq", "field": "status", "value": "blocked"])
        var published = 0
        let subscription = store.$agentViewState.dropFirst().sink { _ in published += 1 }
        store.receiveAgentProjection(try AgentViewFixture.projection(agents: agents, view: view))
        store.receiveAgentProjection(try AgentViewFixture.projection(agents: agents, view: view, revision: 2))
        XCTAssertEqual(published, 1)
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: false).map(\.paneID), ["w2:p1"])
        XCTAssertTrue(store.visibleAgents(inSelectedSpaceOnly: true).isEmpty)
        XCTAssertEqual(store.visibleAgents(inSelectedSpaceOnly: true, followHerdrView: false).map(\.paneID), ["w1:p1"])
        XCTAssertEqual(store.selectedPaneID, "w1:p1", "Filtering a selected row must not move terminal focus")
        store.receiveAgentProjection(try AgentViewFixture.projection(agents: agents, revision: 3))
        XCTAssertNil(store.agentViewState)
        store.receiveAgentProjection(try AgentViewFixture.projection(agents: agents, revision: 4))
        XCTAssertEqual(published, 2, "The normal sidebar should not publish endpoint agent facts twice")
        store.receiveAgentProjection(try AgentViewFixture.projection(agents: agents, view: view, revision: 5))
        store.stop()
        XCTAssertNil(store.agentViewState)
        withExtendedLifetime(subscription) {}
    }
}

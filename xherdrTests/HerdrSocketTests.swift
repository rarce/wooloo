import XCTest
@testable import xherdr

/// The Herdr JSON socket client against a fake server.
final class HerdrSocketTests: XCTestCase {
    private var server: FakeHerdrServer!

    override func setUpWithError() throws {
        server = try FakeHerdrServer { method, params in
            switch method {
            case "session.snapshot": return fakeSnapshot()
            case "pane.read": return ["result": ["read": ["text": "$ ls\nREADME.md\n"]]]
            case "workspace.create": return ["result": ["workspace": ["workspace_id": "w9"]]]
            case "tab.create": return ["result": ["tab": ["tab_id": "w1:t9"]]]
            case "pane.send_input": return ["result": [:]]
            default: return ["error": ["message": "unknown method \(method)"]]
            }
        }
    }

    override func tearDown() {
        server.stop()
    }

    func testRequestsCarryTheirParameters() throws {
        XCTAssertEqual(try HerdrSocket.snapshot(path: server.path).workspaces.first?.label, "project")
        XCTAssertEqual(try HerdrSocket.paneText(path: server.path, paneID: "w1:p1"), "$ ls\nREADME.md\n")
        XCTAssertEqual(try HerdrSocket.createWorkspace(path: server.path, sourceWorkspaceID: "w1", cwd: "/tmp/x",
                                                       label: "New"), "w9")
        XCTAssertEqual(try HerdrSocket.createTab(path: server.path, workspaceID: "w1"), "w1:t9")
        try HerdrSocket.sendInput(path: server.path, paneID: "w1:p1", text: "echo hi")
        try HerdrSocket.sendInput(path: server.path, paneID: "w1:p1", keys: ["Enter"])

        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["session.snapshot", "pane.read", "workspace.create", "tab.create",
                                                "pane.send_input", "pane.send_input"])
        XCTAssertEqual(requests[1].params["source"] as? String, "visible")
        XCTAssertEqual(requests[2].params["source_workspace_id"] as? String, "w1")
        XCTAssertEqual(requests[2].params["cwd"] as? String, "/tmp/x")
        XCTAssertEqual(requests[2].params["label"] as? String, "New")
        XCTAssertEqual(requests[2].params["focus"] as? Bool, true)
        XCTAssertEqual(requests[3].params["workspace_id"] as? String, "w1")
        XCTAssertNil(requests[3].params["cwd"])
        XCTAssertEqual(requests[4].params["text"] as? String, "echo hi")
        XCTAssertNil(requests[4].params["keys"])
        XCTAssertEqual(requests[5].params["keys"] as? [String], ["Enter"])
        XCTAssertNil(requests[5].params["text"])
    }

    func testServerErrorsBecomeMessages() {
        XCTAssertThrowsError(try HerdrSocket.request(path: server.path, method: "nope")) {
            XCTAssertEqual($0.localizedDescription, "unknown method nope")
        }
    }

    func testMissingFieldsAndClosedConnectionsAreErrors() {
        server.setResponder { method, _ in method == "workspace.create" ? ["result": ["workspace": [:]]] : nil }
        XCTAssertThrowsError(try HerdrSocket.createWorkspace(path: server.path, sourceWorkspaceID: nil)) {
            XCTAssertEqual($0.localizedDescription, "Herdr did not return the new space")
        }
        XCTAssertThrowsError(try HerdrSocket.snapshot(path: server.path)) {
            XCTAssertEqual($0.localizedDescription, "Herdr socket closed or timed out")
        }
    }

    func testUnreachableSockets() {
        XCTAssertThrowsError(try HerdrSocket.open(path: server.directory + "/missing.sock")) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Cannot connect to"))
        }
        XCTAssertThrowsError(try HerdrSocket.open(path: "/tmp/" + String(repeating: "x", count: 120))) {
            XCTAssertEqual($0.localizedDescription, "Herdr socket path is too long")
        }
    }

    func testReloadReportsEachOutcome() throws {
        for (status, prefix) in [("applied", "Saved and reloaded"), ("partial", "Saved; some settings need a restart. a\nb"),
                                 ("failed", "Saved, but Herdr could not apply")] {
            server.setResponder { _, _ in ["result": ["status": status, "diagnostics": ["a", "b"]]] }
            XCTAssertTrue(try HerdrConfigFile.reloadServer(socketPath: server.path).hasPrefix(prefix), status)
        }
        server.setResponder { _, _ in ["result": ["status": "strange"]] }
        XCTAssertThrowsError(try HerdrConfigFile.reloadServer(socketPath: server.path))
        XCTAssertEqual(server.requests.last?.method, "server.reload_config")
    }
}

/// `HerdrEventStream` subscribes, then takes a snapshot for every event until the panes change.
final class HerdrEventStreamTests: XCTestCase {
    private var server: FakeHerdrServer!
    private let lock = NSLock()
    private var label = "first"
    private var paneIDs = ["w1:p1", "w1:p2"]

    override func setUpWithError() throws {
        server = try FakeHerdrServer { [unowned self] method, _ in
            guard method == "session.snapshot" else { return ["error": ["message": "unexpected"]] }
            lock.lock()
            defer { lock.unlock() }
            return fakeSnapshot(label: label, paneIDs: paneIDs)
        }
    }

    override func tearDown() {
        server.stop()
    }

    private func update(label: String? = nil, paneIDs: [String]? = nil) {
        lock.lock()
        if let label { self.label = label }
        if let paneIDs { self.paneIDs = paneIDs }
        lock.unlock()
    }

    /// Starts the stream on a thread; returns the snapshots it delivers and a finished expectation.
    private func start(_ stream: HerdrEventStream) -> (snapshots: () -> [String], finished: XCTestExpectation) {
        let finished = expectation(description: "stream returned")
        let collected = NSLock()
        var labels: [String] = []
        Thread.detachNewThread { [path = server.path] in
            _ = try? stream.run(path: path) { snapshot in
                collected.lock()
                labels.append(snapshot.workspaces[0].label)
                collected.unlock()
            }
            finished.fulfill()
        }
        return ({ collected.lock(); defer { collected.unlock() }; return labels }, finished)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(condition())
    }

    func testEventsRefreshTheSnapshotUntilThePanesChange() {
        let stream = HerdrEventStream()
        let (snapshots, finished) = start(stream)
        waitUntil { snapshots() == ["first"] }

        let subscribe = server.requests.first { $0.method == "events.subscribe" }
        let subscriptions = subscribe?.params["subscriptions"] as? [[String: String]] ?? []
        XCTAssertTrue(subscriptions.contains(["type": "workspace.renamed"]))
        XCTAssertEqual(Set(subscriptions.filter { $0["type"] == "pane.agent_status_changed" }.compactMap { $0["pane_id"] }),
                       ["w1:p1", "w1:p2"])

        server.emit(["note": "not an event"])
        update(label: "renamed")
        server.emit(["event": "workspace.renamed"])
        waitUntil { snapshots() == ["first", "renamed"] }

        // A new pane needs its own status subscription, so the stream returns to be restarted.
        update(paneIDs: ["w1:p1", "w1:p2", "w1:p3"])
        server.emit(["event": "pane.created"])
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(snapshots(), ["first", "renamed", "renamed"])
    }

    func testCancelEndsTheStream() {
        let stream = HerdrEventStream()
        let (snapshots, finished) = start(stream)
        waitUntil { snapshots().count == 1 }
        stream.cancel()
        wait(for: [finished], timeout: 3)
    }

    func testRejectedSubscriptionIsAnError() throws {
        let refusing = try FakeHerdrServer(acceptsSubscriptions: false) { method, _ in
            method == "session.snapshot" ? fakeSnapshot() : ["error": ["message": "subscriptions are disabled"]]
        }
        defer { refusing.stop() }
        XCTAssertThrowsError(try HerdrEventStream().run(path: refusing.path) { _ in }) {
            XCTAssertEqual($0.localizedDescription, "Herdr event subscription was rejected")
        }
        XCTAssertEqual(refusing.requests.map(\.method), ["session.snapshot", "events.subscribe"])
    }
}

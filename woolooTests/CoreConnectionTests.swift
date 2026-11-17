import XCTest
@testable import wooloo

/// The herdr-core client: frames, the handshake, calls, streams with credit, and the session
/// backend built on them, against `FakeCore`. Set WOOLOO_CORE_LIVE_HC to an `hc` executable to
/// also run against a real core, in the session named by HC_SESSION (default `wooloo-ui-test`).
final class CoreConnectionTests: XCTestCase {
    // MARK: Frames

    func testFramesRoundTripThroughThePartialDecoder() throws {
        let frames = [CoreFrame(channel: 0, kind: .data, payload: Data("{\"id\":1}".utf8)),
                      CoreFrame.credit(70_000, channel: 3),
                      CoreFrame(channel: 7, kind: .close, payload: Data())]
        let bytes = frames.map { $0.encoded() }.reduce(Data(), +)
        XCTAssertEqual(Array(bytes.prefix(9)), [0, 0, 0, 0, 0, 8, 0, 0, 0])
        var decoder = CoreFrameDecoder()
        var decoded: [CoreFrame] = []
        for byte in bytes {
            decoder.append(Data([byte]))
            while let frame = try decoder.next() { decoded.append(frame) }
        }
        XCTAssertEqual(decoded, frames)
        XCTAssertEqual(Array(decoded[1].payload), [0x70, 0x11, 0x01, 0x00])
    }

    func testOversizedAndUnknownFramesAreRefused() {
        var decoder = CoreFrameDecoder()
        decoder.append(Data([1, 0, 0, 0, 0]) + Data([0, 0, 0, 2]))
        XCTAssertThrowsError(try decoder.next()) { XCTAssertEqual($0 as? CoreProtocolError, .frameTooLarge(32 * 1024 * 1024)) }
        var unknown = CoreFrameDecoder()
        unknown.append(Data([1, 0, 0, 0, 9, 0, 0, 0, 0]))
        XCTAssertThrowsError(try unknown.next()) { XCTAssertEqual($0 as? CoreProtocolError, .unknownFrameKind(9)) }
    }

    func testVersionGate() {
        XCTAssertTrue(CoreProtocol.version("0.1.21", isAtLeast: "0.1.21"))
        XCTAssertTrue(CoreProtocol.version("0.2.0", isAtLeast: "0.1.21"))
        XCTAssertTrue(CoreProtocol.version("0.1.22-dev", isAtLeast: "0.1.21"))
        XCTAssertFalse(CoreProtocol.version("0.1.20", isAtLeast: "0.1.21"))
        XCTAssertFalse(CoreProtocol.version("0.1", isAtLeast: "0.1.21"))
    }

    func testEventLinesSplitAcrossChunks() {
        var lines = CoreEventLines()
        let text = #"{"jsonrpc":"2.0","method":"event","params":{"seq":5,"type":"created","terminal":"t2"}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"event","params":{"seq":5}}"# + "\n"
        let bytes = Data(text.utf8)
        XCTAssertEqual(lines.append(bytes.prefix(30)), [])
        XCTAssertEqual(lines.append(bytes.dropFirst(30)), [
            CoreEvent(seq: 5, type: "created", terminal: "t2"), CoreEvent(seq: 5, type: nil, terminal: nil),
        ])
    }

    // MARK: Connection

    func testHandshakeSkipsALoginGreetingUntilTheBanner() throws {
        let core = FakeCore()
        core.greeting = ["Welcome to box", CoreTarget.banner]
        let connection = CoreConnection(transport: core.connect())
        let hello = try connection.open(banner: CoreTarget.banner)
        defer { connection.close() }
        XCTAssertEqual(hello.core, CoreInfo(id: "0123456789abcdef", name: "box"))
        XCTAssertEqual(core.callsTo("hello").first?.params["framed"] as? Bool, true)
        XCTAssertEqual(core.callsTo("hello").first?.params["generation"] as? Int, 1)
    }

    func testOldOrIncompleteCoresAreRefused() {
        let old = FakeCore()
        old.version = "0.1.18"
        XCTAssertThrowsError(try CoreConnection(transport: old.connect()).open()) { error in
            XCTAssertEqual(error as? CoreProtocolError, .unsupportedCore(version: "0.1.18", missing: []))
        }
        let partial = FakeCore()
        partial.methods.removeAll { $0 == "doc.set" }
        XCTAssertThrowsError(try CoreConnection(transport: partial.connect()).open()) { error in
            XCTAssertEqual(error as? CoreProtocolError, .unsupportedCore(version: "0.1.21", missing: ["doc.set"]))
        }
    }

    func testCallsDecodeResultsAndErrors() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", argv: ["/bin/zsh"], cwd: "/src")]
        core.overrides["terminal.keep"] = { _ in nil }
        let connection = CoreConnection(transport: core.connect())
        try connection.open()
        defer { connection.close() }
        XCTAssertEqual(try connection.call("terminal.list", as: CoreListResult.self).terminals.map(\.address), ["t1"])
        XCTAssertThrowsError(try connection.callRaw("terminal.keep", ["terminal": "t1"]).decodedResult()) { error in
            XCTAssertEqual(error as? CoreProtocolError, .remote(kind: "refused", message: "refused terminal.keep"))
        }
    }

    func testStreamBytesAreCreditedAndClosesReported() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1")]
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        defer { connection.close() }
        let subscribed = try connection.call("events.subscribe", as: CoreSubscribeResult.self)
        let channel = try XCTUnwrap(subscribed.channel)
        let received = expectation(description: "event")
        let ended = expectation(description: "closed")
        var events: [CoreEvent] = []
        var lines = CoreEventLines()
        connection.route(channel: channel, onData: { data in
            events += lines.append(data)
            if !events.isEmpty { received.fulfill() }
        }, onClose: { ended.fulfill() })
        server.emit(type: "created", terminal: "t2")
        wait(for: [received], timeout: 5)
        server.closeChannel(channel)
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(events.first?.type, "created")
        XCTAssertGreaterThan(server.credits[channel] ?? 0, 0)
    }

    func testAnEndedConnectionFailsCalls() throws {
        let core = FakeCore()
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        server.close()
        let deadline = Date().addingTimeInterval(5)
        while !connection.isClosed, Date() < deadline { usleep(10_000) }
        XCTAssertTrue(connection.isClosed)
        XCTAssertThrowsError(try connection.callRaw("terminal.list")) { XCTAssertEqual($0 as? CoreProtocolError, .closed) }
    }

    // MARK: Session backend

    private func backend(_ core: FakeCore) -> CoreSessionBackend {
        CoreSessionBackend(target: .local(hc: "/usr/local/bin/hc", session: "wooloo-ui-test"),
                           makeTransport: { _ in core.connect() })
    }

    func testTerminalsBecomeTabsOfTheCoresSpace() throws {
        let core = FakeCore()
        core.terminals = [
            CoreTerminal(address: "t1", argv: ["/bin/zsh"], cols: 120, rows: 40, cwd: "/src/app"),
            CoreTerminal(address: "t2", argv: ["claude"], cwd: "/src/app", labels: ["wooloo.name": "review"],
                         status: CoreStatus(state: "blocked", app: "claude", msg: "Allow edit?", title: nil), turn: 3),
            CoreTerminal(address: "t3", argv: ["make"], state: "finished"),
            CoreTerminal(address: "vps/t1", argv: ["sh"]),
        ]
        let snapshot = try backend(core).snapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.workspaceID), [CoreSessionBackend.spaceID])
        XCTAssertEqual(snapshot.workspaces.first?.label, "box")
        XCTAssertEqual(snapshot.tabs.map(\.tabID), ["t1", "t2"])
        XCTAssertEqual(snapshot.tabs.map(\.label), ["zsh", "review"])
        XCTAssertEqual(snapshot.panes.map(\.cwd), ["/src/app", "/src/app"])
        XCTAssertEqual(snapshot.layouts.first?.area, HerdrRect(x: 0, y: 0, width: 120, height: 40))
        let agent = try XCTUnwrap(snapshot.agents.first)
        XCTAssertEqual(agent.paneID, "t2")
        XCTAssertEqual(agent.agentStatus, "blocked")
        XCTAssertEqual(agent.displayName, "claude")
        XCTAssertEqual(agent.stateChangeSeq, 3)
        let session = snapshot.session(backend: BackendID(kind: .core, context: "box"), capabilities: CoreSessionBackend.capabilities)
        XCTAssertEqual(session.agents.first?.state, .blocked)
        XCTAssertNotNil(session.tabSpaceMoveRefusal("t1", to: nil))
    }

    func testCommandsAndCreationUseTerminalCalls() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", cols: 100, rows: 30)]
        core.screens["t1"] = "$ ls\nREADME.md\n"
        let backend = backend(core)
        XCTAssertEqual(try backend.paneText("t1"), "$ ls\nREADME.md\n")
        XCTAssertEqual(try backend.create(.tab(spaceID: CoreSessionBackend.spaceID, cwd: "/src")), "t2")
        XCTAssertEqual(try backend.create(.space(sourceSpaceID: nil, cwd: "/tmp", label: nil)), CoreSessionBackend.spaceID)
        XCTAssertEqual(core.callsTo("terminal.run").first?.params["cwd"] as? String, "/src")
        XCTAssertEqual(core.callsTo("terminal.run").first?.params["labels"] as? [String: String], ["wooloo.space": "core"])
        try backend.perform(.renameTab(tabID: "t1", label: "build"))
        XCTAssertEqual(core.callsTo("terminal.label").first?.params["labels"] as? [String: String], ["wooloo.name": "build"])
        try backend.perform(.closePane(paneID: "t2"))
        XCTAssertEqual(core.callsTo("terminal.kill").first?.params["terminal"] as? String, "t2")
        XCTAssertThrowsError(try backend.perform(.splitPane(spaceID: "core", paneID: "t1", direction: "right"))) {
            XCTAssertEqual($0 as? CoreProtocolError, .unsupported("split panes"))
        }
        XCTAssertThrowsError(try backend.moveSpace("core", beside: "core", after: true, checkpoint: {}))
    }

    func testTypingAttachesAtTheTerminalsOwnSizeAndKeysUseTerminalKeys() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", cols: 100, rows: 30)]
        let backend = backend(core)
        try backend.sendInput(to: "t1", text: nil, keys: ["ctrl+c"])
        XCTAssertEqual(core.callsTo("terminal.keys").first?.params["keys"] as? [String], ["ctrl+c"])
        try backend.sendInput(to: "t1", text: "ls\r", keys: [])
        let attach = try XCTUnwrap(core.callsTo("terminal.attach").first)
        XCTAssertEqual(attach.params["cols"] as? Int, 100)
        XCTAssertEqual(attach.params["rows"] as? Int, 30)
        let deadline = Date().addingTimeInterval(5)
        var frames: [CoreFrame] = []
        while Date() < deadline {
            frames = core.connections.flatMap { $0.recordedFrames() }
            if frames.count >= 2 { break }
            usleep(10_000)
        }
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "ls\r")
        XCTAssertEqual(frames.last?.kind, .close)
    }

    func testTheWatcherReportsTheListThenEachChange() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1")]
        let watcher = backend(core).makeWatcher()
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        let seen = Recorder()
        let thread = Thread {
            try? watcher.run { snapshot in
                let count = seen.append(snapshot.tabs.map(\.tabID))
                if count == 1 { first.fulfill() }
                if count == 2 { second.fulfill() }
            }
        }
        thread.start()
        wait(for: [first], timeout: 5)
        core.update { $0.terminals.append(CoreTerminal(address: "t2")) }
        let watching = try XCTUnwrap(core.connections.first { $0.eventsChannel != nil })
        watching.emit(type: nil)
        watching.emit(type: "created", terminal: "t2")
        wait(for: [second], timeout: 10)
        watcher.cancel()
        XCTAssertEqual(seen.values, [["t1"], ["t1", "t2"]])
    }

    // MARK: Live

    func testLiveCore() throws {
        guard let hc = ProcessInfo.processInfo.environment["WOOLOO_CORE_LIVE_HC"] else {
            throw XCTSkip("Set WOOLOO_CORE_LIVE_HC to an hc executable to run against a real core")
        }
        let session = ProcessInfo.processInfo.environment["HC_SESSION"] ?? "wooloo-ui-test"
        XCTAssertNotEqual(session, "default")
        let backend = CoreSessionBackend(target: .local(hc: hc, session: session))
        defer { backend.disconnect() }
        let id = try backend.create(.tab(spaceID: CoreSessionBackend.spaceID, cwd: NSTemporaryDirectory()))
        defer { try? backend.perform(.closePane(paneID: id)) }
        XCTAssertTrue(try backend.snapshot().tabs.contains { $0.tabID == id })
        try backend.sendInput(to: id, text: "echo wooloo-live-check\r", keys: [])
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = try backend.paneText(id)
            if text.contains("wooloo-live-check\n") || text.components(separatedBy: "wooloo-live-check").count > 2 { break }
            usleep(200_000)
        }
        XCTAssertTrue(text.components(separatedBy: "wooloo-live-check").count > 2, text)
        XCTAssertNotNil(backend.core?.id)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [[String]] = []
    func append(_ value: [String]) -> Int { lock.withLock { values.append(value); return values.count } }
}

private extension Data {
    func decodedResult() throws {
        struct Empty: Decodable {}
        _ = try CoreConnection.result(Empty.self, from: self)
    }
}

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

    func testResizeFrameEncodesClampedLittleEndianDimensions() {
        XCTAssertEqual(CoreFrame.resize(cols: 300, rows: 1025, channel: 9),
                       CoreFrame(channel: 9, kind: .resize, payload: Data([44, 1, 1, 4])))
        XCTAssertEqual(CoreFrame.resize(cols: -1, rows: 70000, channel: 2).payload, Data([0, 0, 255, 255]))
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

    /// An event's details of an unexpected shape are dropped, never the event, which may ask
    /// for a fresh read of the tree.
    func testAnEventWithOddDetailsStillArrives() {
        var lines = CoreEventLines()
        let text = #"{"jsonrpc":"2.0","method":"event","params":{"seq":6,"type":"doc","data":"changed"}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"event","params":{"seq":7,"type":"size","terminal":"t1","data":{"cols":"x","rows":24}}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"event","params":{"seq":8,"type":"size","terminal":"t1","data":{"cols":90,"rows":30}}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"event","params":{"seq":9,"type":{"kind":"exit"},"terminal":"t1"}}"# + "\n"
        XCTAssertEqual(lines.append(Data(text.utf8)), [
            CoreEvent(seq: 6, type: "doc", terminal: nil),
            CoreEvent(seq: 7, type: "size", terminal: "t1", data: .init(cols: nil, rows: 24)),
            CoreEvent(seq: 8, type: "size", terminal: "t1", data: .init(cols: 90, rows: 30)),
            CoreEvent(seq: 9, type: "unknown", terminal: "t1"),
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

    /// Core sends an attach's replay right after the reply, and the reader may handle it before
    /// the caller routes the channel: those bytes, a size and an end wait for `route`.
    func testStreamFramesBeforeTheRouteAreKeptInOrder() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1")]
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        defer { connection.close() }
        let attached = try connection.call("terminal.attach", ["terminal": "t1", "cols": 80, "rows": 24],
                                           as: CoreAttachResult.self)
        server.send(Data("replay ".utf8), on: attached.channel)
        server.sendResize(cols: 100, rows: 30, on: attached.channel)
        server.send(Data("screen".utf8), on: attached.channel)
        // A probe stream's frame comes after them: once it is in, theirs were read.
        let probe = try connection.call("terminal.attach", ["terminal": "t1", "cols": 80, "rows": 24],
                                        as: CoreAttachResult.self)
        let probed = expectation(description: "probe")
        connection.route(channel: probe.channel, onData: { _ in probed.fulfill() }, onClose: {})
        server.send(Data("p".utf8), on: probe.channel)
        wait(for: [probed], timeout: 5)
        XCTAssertNil(server.credits[attached.channel], "Bytes nobody took yet are not credited, so Core holds the rest")

        var received = Data()
        var order: [String] = []
        let more = expectation(description: "later bytes")
        connection.route(channel: attached.channel, onData: { data in
            received.append(data)
            order.append(String(decoding: data, as: UTF8.self))
            if received.count == 17 { more.fulfill() }
        }, onClose: {}, onResize: { order.append("\($0)x\($1)") })
        XCTAssertEqual(order, ["replay ", "100x30", "screen"], "A resize applies between the bytes around it")
        let deadline = Date().addingTimeInterval(5)
        while (server.credits[attached.channel] ?? 0) < 13, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(server.credits[attached.channel], 13, "Handed-over bytes are credited")
        server.send(Data(" new".utf8), on: attached.channel)
        wait(for: [more], timeout: 5)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "replay screen new")

        let early = try connection.call("terminal.attach", ["terminal": "t1", "cols": 80, "rows": 24],
                                        as: CoreAttachResult.self)
        server.send(Data("x".utf8), on: early.channel)
        server.closeChannel(early.channel)
        // Frames arrive in order: once "y" is in, the early channel's frames were read.
        let after = expectation(description: "a frame after the close")
        connection.route(channel: attached.channel, onData: { if $0 == Data("y".utf8) { after.fulfill() } }, onClose: {})
        server.send(Data("y".utf8), on: attached.channel)
        wait(for: [after], timeout: 5)
        var earlyBytes = Data()
        var closed = false
        connection.route(channel: early.channel, onData: { earlyBytes.append($0) }, onClose: { closed = true })
        XCTAssertEqual(String(decoding: earlyBytes, as: UTF8.self), "x")
        XCTAssertTrue(closed, "A stream that ended before its route reports the end")
    }

    /// An attach that timed out may still open a stream once Core answers: nothing would read
    /// it, so it is closed, and what it sends is not kept.
    func testAStreamFromATimedOutAttachIsClosed() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1")]
        core.heldReplies = ["terminal.attach"]
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        defer { connection.close() }
        XCTAssertThrowsError(try connection.call("terminal.attach", ["terminal": "t1", "cols": 80, "rows": 24],
                                                 as: CoreAttachResult.self, timeout: 0.1)) {
            XCTAssertEqual($0 as? CoreProtocolError, .timedOut("terminal.attach"))
        }
        let channel = try XCTUnwrap(server.attachChannels.first)
        server.releaseReplies()
        server.send(Data("late".utf8), on: channel)
        let deadline = Date().addingTimeInterval(5)
        while !server.recordedFrames().contains(where: { $0.channel == channel && $0.kind == .close }), Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(server.recordedFrames().contains { $0.channel == channel && $0.kind == .close })
        // Frames arrive in order: once a later call is answered, "late" was read and dropped.
        core.update { $0.heldReplies = [] }
        _ = try connection.call("terminal.list", as: CoreListResult.self)
        var received = Data()
        connection.route(channel: channel, onData: { received.append($0) }, onClose: {})
        XCTAssertTrue(received.isEmpty, "A closed stream's bytes are not kept for a route")
    }

    /// A reply that opens a stream but does not decode (here, a subscription without its seq
    /// and terminals) closes that stream: nothing would ever read it.
    func testAStreamFromAReplyThatDoesNotDecodeIsClosed() throws {
        let core = FakeCore()
        core.overrides["events.subscribe"] = { _ in ["channel": 7] }
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        defer { connection.close() }
        XCTAssertThrowsError(try connection.call("events.subscribe", as: CoreSubscribeResult.self))
        XCTAssertTrue(server.recordedFrames().contains { $0.channel == 7 && $0.kind == .close })
    }

    /// Discarding a stream Core already closed sends nothing more.
    func testDiscardingAClosedStreamSendsNoClose() throws {
        let core = FakeCore()
        let server = core.connect()
        let connection = CoreConnection(transport: server)
        try connection.open()
        defer { connection.close() }
        server.closeChannel(9)
        // Frames arrive in order: once a later call is answered, the close was read.
        _ = try connection.call("terminal.list", as: CoreListResult.self)
        connection.discard(channel: 9)
        _ = try connection.call("terminal.list", as: CoreListResult.self)
        XCTAssertFalse(server.recordedFrames().contains { $0.channel == 9 && $0.kind == .close })
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

    private func structure(_ core: FakeCore) -> CoreStructure? {
        core.lock.withLock { CoreStructure.decode(core.documents[CoreStructure.documentName]?.value ?? nil) }
    }

    func testLooseTerminalsShowInUnfiledWithTheirAgents() throws {
        let core = FakeCore()
        core.terminals = [
            CoreTerminal(address: "t1", argv: ["/bin/zsh"], cols: 120, rows: 40, cwd: "/src/app"),
            CoreTerminal(address: "t2", argv: ["claude"], cwd: "/src/app", labels: ["wooloo.name": "review"],
                         status: CoreStatus(state: "blocked", app: "claude", msg: "Allow edit?", title: nil), turn: 3),
            CoreTerminal(address: "t3", argv: ["make"], state: "finished"),
            CoreTerminal(address: "vps/t1", argv: ["sh"]),
        ]
        let snapshot = try backend(core).snapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.workspaceID), [CoreStructure.unfiledID])
        XCTAssertEqual(snapshot.tabs.map(\.tabID), ["tab-t1", "tab-t2"])
        XCTAssertEqual(snapshot.tabs.map(\.label), ["zsh", "review"])
        XCTAssertEqual(snapshot.layouts.first?.area, HerdrRect(x: 0, y: 0, width: 120, height: 40))
        let agent = try XCTUnwrap(snapshot.agents.first)
        XCTAssertEqual(agent.paneID, "t2")
        XCTAssertEqual(agent.agentStatus, "blocked")
        XCTAssertEqual(agent.stateChangeSeq, 3)
        XCTAssertNil(core.documents[CoreStructure.documentName], "Reading never writes the document")
    }

    func testSpacesTabsAndSplitsAreWrittenToTheDocument() throws {
        let core = FakeCore()
        let backend = backend(core)
        let space = try backend.create(.space(sourceSpaceID: nil, cwd: "/src/api", label: nil))
        XCTAssertEqual(core.callsTo("terminal.run").first?.params["labels"] as? [String: String],
                       [CoreStructure.spaceLabel: space])
        var arranged = try XCTUnwrap(structure(core))
        XCTAssertEqual(arranged.spaces.map(\.name), ["api"])
        XCTAssertEqual(arranged.spaces.first?.folder, "/src/api")
        let tab = try backend.create(.tab(spaceID: space, cwd: nil))
        XCTAssertEqual(core.callsTo("terminal.run").last?.params["cwd"] as? String, "/src/api", "New tabs start in the Space's folder")
        try backend.perform(.splitPane(spaceID: space, paneID: "t2", direction: "down"))
        arranged = try XCTUnwrap(structure(core))
        XCTAssertEqual(arranged.spaces.first?.tabs.map(\.id).last, tab)
        XCTAssertEqual(arranged.spaces.first?.tabs.last?.root,
                       .split(.down, ratio: 0.5, first: .terminal("t2"), second: .terminal("t3")))
        XCTAssertTrue(core.callsTo("terminal.run").allSatisfy { $0.params["keep"] as? Bool == true },
                      "A Space, tab or split created by wooloo can recover its shell after a core stop")
        let afterSplit = try backend.snapshot()
        XCTAssertEqual(afterSplit.focusedPaneID, "t3", "The window follows the new pane")
        XCTAssertNil(try backend.snapshot().focusedPaneID, "only once")
        try backend.perform(.renameTab(tabID: tab, label: "logs"))
        try backend.perform(.renameSpace(spaceID: space, label: "API"))
        try backend.setSplitRatio(tabID: tab, path: [], ratio: 0.25)
        arranged = try XCTUnwrap(structure(core))
        XCTAssertEqual(arranged.spaces.first?.name, "API")
        XCTAssertEqual(arranged.spaces.first?.tabs.last?.name, "logs")
        XCTAssertEqual(arranged.spaces.first?.tabs.last?.root,
                       .split(.down, ratio: 0.25, first: .terminal("t2"), second: .terminal("t3")))
        try backend.perform(.closeTab(tabID: tab))
        XCTAssertEqual(Set(core.callsTo("terminal.kill").compactMap { $0.params["terminal"] as? String }), ["t2", "t3"])
        XCTAssertEqual(try XCTUnwrap(structure(core)).spaces.first?.tabs.count, 1)
    }

    func testAWorktreeCheckoutHasOneSpace() throws {
        let core = FakeCore()
        let backend = backend(core)
        let space = try backend.create(.worktreeSpace(checkout: "/src/app-feature", repository: "/src/app"))
        XCTAssertEqual(structure(core)?.worktrees, [space: "/src/app-feature"])
        XCTAssertEqual(try backend.snapshot().workspaces.first { $0.workspaceID == space }?.worktree?.checkoutPath,
                       "/src/app-feature")
        // Another window opening the same checkout, before its own snapshot shows the Space.
        XCTAssertEqual(try backend.create(.worktreeSpace(checkout: "/src/app-feature", repository: "/src/app")), space)
        XCTAssertEqual(core.callsTo("terminal.run").count, 1, "The checkout's Space is reused")
        let plain = try backend.create(.space(sourceSpaceID: nil, cwd: "/src/app-feature", label: nil))
        XCTAssertNotEqual(plain, space)
        XCTAssertNil(try backend.snapshot().workspaces.first { $0.workspaceID == plain }?.worktree,
                     "A plain Space in the same folder is not a worktree Space")
        // Its shell ends; the next write leaves the Space and its checkout out of the document.
        core.update { $0.terminals[0] = CoreTerminal(address: "t1", argv: ["/bin/zsh"], state: "finished") }
        _ = try backend.create(.tab(spaceID: plain, cwd: nil))
        XCTAssertEqual(structure(core)?.worktrees, [:], "A closed worktree Space leaves the document")
    }

    func testAWorktreeAdoptsASpaceAlreadyOpenOnItsFolder() throws {
        let core = FakeCore()
        let backend = backend(core)
        let plain = try backend.create(.space(sourceSpaceID: nil, cwd: "/src/app-feature", label: nil))
        XCTAssertEqual(try backend.create(.worktreeSpace(checkout: "/src/app-feature", repository: "/src/app")), plain)
        XCTAssertEqual(core.callsTo("terminal.run").count, 1, "No second shell on the checkout")
        XCTAssertEqual(structure(core)?.worktrees, [plain: "/src/app-feature"])
    }

    func testTwoWindowsOpeningOneWorktreeAtOnceShareOneSpace() throws {
        let core = FakeCore()
        let backend = backend(core)
        let checkout = "/src/app-feature"
        let other = CoreStructure(spaces: [.init(id: "w", name: "app-feature", folder: checkout,
                                                 tabs: [.init(id: "x", name: nil, root: .terminal("t1"))])],
                                  worktrees: ["w": checkout])
        // Another window records its Space while this window's shell starts.
        core.update { core in
            core.overrides["terminal.run"] = { [unowned core] params in
                let started = CoreTerminal(address: "t2", cwd: checkout, labels: params["labels"] as? [String: String] ?? [:])
                core.terminals = [CoreTerminal(address: "t1", cwd: checkout), started]
                core.documents[CoreStructure.documentName] = (value: other.encoded(over: nil) as Any?, version: 1)
                return ["address": "t2", "cwd": checkout, "state": "live"]
            }
        }
        XCTAssertEqual(try backend.create(.worktreeSpace(checkout: checkout, repository: "/src/app")), "w")
        XCTAssertEqual(structure(core)?.spaces.map(\.id), ["w"])
        XCTAssertEqual(structure(core)?.worktrees, ["w": checkout])
        XCTAssertEqual(core.callsTo("terminal.kill").first?.params["terminal"] as? String, "t2",
                       "The shell this window started is closed")
    }

    func testAWorktreeSpacesOnlyTabTakesTheCheckoutToANewSpace() throws {
        let core = FakeCore()
        let backend = backend(core)
        let space = try backend.create(.worktreeSpace(checkout: "/src/app-feature", repository: "/src/app"))
        let tab = try XCTUnwrap(structure(core)?.spaces.first { $0.id == space }?.tabs.first?.id)
        let pane = try backend.moveTab(tab, toSpace: nil, lastTabWasChecked: true, checkpoint: {})
        XCTAssertNotEqual(pane.spaceID, space)
        XCTAssertEqual(structure(core)?.worktrees, [pane.spaceID: "/src/app-feature"])
    }

    func testMovesRearrangeTheDocument() throws {
        let core = FakeCore()
        let backend = backend(core)
        let first = try backend.create(.space(sourceSpaceID: nil, cwd: "/a", label: "a"))
        let second = try backend.create(.space(sourceSpaceID: nil, cwd: "/b", label: "b"))
        try backend.moveSpace(second, beside: first, after: false, checkpoint: {})
        XCTAssertEqual(try XCTUnwrap(structure(core)).spaces.map(\.name), ["b", "a"])
        let extra = try backend.create(.tab(spaceID: first, cwd: nil))
        let moved = try backend.moveTab(extra, toSpace: second, lastTabWasChecked: false, checkpoint: {})
        XCTAssertEqual(moved.spaceID, second)
        XCTAssertEqual(moved.id, "t3")
        let only = try XCTUnwrap(structure(core).flatMap { arranged in arranged.tab(of: "t1").map { arranged.spaces[$0.space].tabs[$0.tab].id } })
        XCTAssertThrowsError(try backend.moveTab(only, toSpace: second, lastTabWasChecked: false, checkpoint: {}),
                             "Taking a Space's last tab without the documents check is refused")
        try backend.movePane("t3", to: .beside(targetPaneID: "t2", tabID: "", split: "right", swapAfter: true,
                                               detachFirst: true), checkpoint: {})
        let arranged = try XCTUnwrap(structure(core))
        XCTAssertEqual(arranged.spaces.map(\.name), ["b", "a"])
        XCTAssertEqual(arranged.spaces.first?.tabs.count, 1, "The tab the pane left was empty and is gone")
        XCTAssertEqual(arranged.spaces.first?.tabs.first?.root,
                       .split(.right, ratio: 0.5, first: .terminal("t3"), second: .terminal("t2")))
        try backend.movePane("t3", to: .newTab, checkpoint: {})
        XCTAssertEqual(try XCTUnwrap(structure(core)).spaces.first?.tabs.map(\.root), [.terminal("t2"), .terminal("t3")])
    }

    func testAConflictingWriteIsRetriedOnTheNewerDocument() throws {
        let core = FakeCore()
        let backend = backend(core)
        let space = try backend.create(.space(sourceSpaceID: nil, cwd: "/a", label: "a"))
        var raced = false
        core.overrides["doc.get"] = { [unowned core] params in
            // Another client renames the Space between this read and the write that follows.
            let document = core.documents[CoreStructure.documentName]!
            if !raced, var value = CoreStructure.decode(document.value) {
                raced = true
                value.spaces[0].name = "renamed elsewhere"
                core.documents[CoreStructure.documentName] = (value.encoded(over: document.value), document.version + 1)
                return ["value": document.value ?? NSNull(), "version": document.version]
            }
            return ["value": core.documents[CoreStructure.documentName]?.value ?? NSNull(),
                    "version": core.documents[CoreStructure.documentName]?.version ?? 0]
        }
        _ = try backend.create(.tab(spaceID: space, cwd: nil))
        let arranged = try XCTUnwrap(structure(core))
        XCTAssertEqual(arranged.spaces.first?.name, "renamed elsewhere", "The other client's change is kept")
        XCTAssertEqual(arranged.spaces.first?.tabs.count, 2, "and this one is applied on top")
    }

    func testTheAppsSpacesAreShownAndOnlyAdoptedWhenChanged() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", cwd: "/src/web"), CoreTerminal(address: "t2", cwd: "/src/api")]
        let app: [String: Any] = ["spaces": [
            ["id": "s1", "name": "web", "tabs": [["id": "a", "root": ["type": "block", "content": ["terminal": "t1"]]]]],
            ["id": "s2", "name": "api", "tabs": [["id": "b", "root": ["type": "block", "content": ["terminal": "t2"]]]]],
        ]]
        core.documents[HerdrAppStructure.documentName] = (app, 4)
        let backend = backend(core)
        XCTAssertEqual(try backend.snapshot().workspaces.map(\.label), ["web", "api"])
        let mine = try backend.create(.space(sourceSpaceID: nil, cwd: "/src/docs", label: "docs"))
        XCTAssertEqual(try XCTUnwrap(structure(core)).spaces.map(\.id), [mine], "Untouched app Spaces are not copied")
        try backend.perform(.renameSpace(spaceID: "app:s2", label: "API"))
        XCTAssertEqual(try XCTUnwrap(structure(core)).spaces.map(\.name), ["docs", "API"], "A changed one is wooloo's from then on")
        XCTAssertEqual(try backend.snapshot().workspaces.map(\.label), ["docs", "API", "web"])
        XCTAssertTrue(core.callsTo("doc.set").allSatisfy { $0.params["name"] as? String == CoreStructure.documentName },
                      "The app's document is never written")
        XCTAssertEqual(core.documents[HerdrAppStructure.documentName]?.version, 4)
    }

    func testSeenTurnsAreOnlyRaised() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", labels: ["herdr.seen": "5"], turn: 4),
                          CoreTerminal(address: "t2", turn: 7)]
        let backend = backend(core)
        try backend.markSeen("t1")
        try backend.markSeen("t2")
        XCTAssertEqual(core.callsTo("terminal.label").count, 1)
        XCTAssertEqual(core.callsTo("terminal.label").first?.params["labels"] as? [String: String], ["herdr.seen": "7"])
    }

    func testPinsAndUnreadMarksAreSharedLabels() throws {
        let core = FakeCore()
        let status = CoreStatus(state: "idle", app: "claude", msg: nil, title: nil)
        core.terminals = [CoreTerminal(address: "t1", labels: ["herdr.seen": "4"], status: status, turn: 4),
                          CoreTerminal(address: "t2", labels: ["wooloo.name": "reviewer"], status: status, turn: 0)]
        let backend = backend(core)
        try backend.setPinned("t1", true)
        try backend.markUnread("t1")
        try backend.markUnread("t2")
        XCTAssertEqual(core.callsTo("terminal.label").compactMap { $0.params["labels"] as? [String: String] },
                       [["herdr.pinned": "1"], ["herdr.seen": "3"]], "Turn 0 has nothing to mark unread")
        let agents = try backend.snapshot().agents
        XCTAssertEqual(agents.first { $0.paneID == "t1" }?.pinned, true)
        XCTAssertEqual(agents.first { $0.paneID == "t1" }?.agentStatus, "done", "Unread again")
        XCTAssertEqual(agents.first { $0.paneID == "t2" }?.displayName, "reviewer", "A renamed agent shows its name")
        try backend.setPinned("t1", false)
        XCTAssertEqual(try backend.snapshot().agents.first { $0.paneID == "t1" }?.pinned, false)
    }

    func testCommandsAndCreationUseTerminalCalls() throws {
        let core = FakeCore()
        core.terminals = [CoreTerminal(address: "t1", cols: 100, rows: 30)]
        core.screens["t1"] = "$ ls\nREADME.md\n"
        let backend = backend(core)
        XCTAssertEqual(try backend.paneText("t1"), "$ ls\nREADME.md\n")
        try backend.perform(.renameAgent(paneID: "t1", name: "build"))
        XCTAssertEqual(core.callsTo("terminal.label").first?.params["labels"] as? [String: String], ["wooloo.name": "build"])
        try backend.perform(.closePane(paneID: "t1"))
        XCTAssertEqual(core.callsTo("terminal.kill").first?.params["terminal"] as? String, "t1")
        XCTAssertThrowsError(try backend.perform(.reloadConfig)) {
            XCTAssertEqual($0 as? CoreProtocolError, .unsupported("reload the configuration"))
        }
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
        XCTAssertEqual(seen.values, [["tab-t1"], ["tab-t1", "tab-t2"]])
    }

    func testClosingTheEventSubscriptionDisconnectsTheWatcher() throws {
        let core = FakeCore()
        let watcher = backend(core).makeWatcher()
        defer { watcher.cancel() }
        let connected = expectation(description: "snapshot received")
        let ended = expectation(description: "watcher reported disconnection")
        Thread {
            do { try watcher.run { _ in connected.fulfill() } }
            catch CoreProtocolError.closed { ended.fulfill() }
            catch { XCTFail("Unexpected watcher error: \(error)") }
        }.start()
        wait(for: [connected], timeout: 5)
        let server = try XCTUnwrap(core.connections.first { $0.eventsChannel != nil })
        server.closeChannel(try XCTUnwrap(server.eventsChannel))
        wait(for: [ended], timeout: 2)
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
        let space = try backend.create(.space(sourceSpaceID: nil, cwd: NSTemporaryDirectory(), label: "wooloo live check"))
        defer { try? backend.perform(.closeSpace(spaceID: space)) }
        let snapshot = try backend.snapshot()
        let id = try XCTUnwrap(snapshot.panes.first { $0.workspaceID == space }?.paneID)
        XCTAssertEqual(snapshot.workspaces.first { $0.workspaceID == space }?.label, "wooloo live check")
        try backend.sendInput(to: id, text: "echo wooloo-live-check\r", keys: [])
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = try backend.paneText(id)
            if text.contains("wooloo-live-check\n") || text.components(separatedBy: "wooloo-live-check").count > 2 { break }
            usleep(200_000)
        }
        XCTAssertTrue(text.components(separatedBy: "wooloo-live-check").count > 2, text)
        // An empty value removes a label on a real core too.
        try backend.setPinned(id, true)
        XCTAssertEqual(try backend.snapshot().agents.first { $0.paneID == id }.map(\.pinned) ?? true, true)
        let pinned = try backend.connect().call("terminal.list", [:], as: CoreListResult.self).terminals.first { $0.address == id }
        XCTAssertEqual(pinned?.labels["herdr.pinned"], "1")
        try backend.setPinned(id, false)
        let unpinned = try backend.connect().call("terminal.list", [:], as: CoreListResult.self).terminals.first { $0.address == id }
        XCTAssertNil(unpinned?.labels["herdr.pinned"])
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

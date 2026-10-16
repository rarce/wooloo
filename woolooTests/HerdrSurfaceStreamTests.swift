import Darwin
import XCTest
@testable import wooloo

/// Herdr's binary client endpoint (`herdr-client.sock`) for one connection: it records the
/// frames wooloo sends, answers the hello, and sends the frames a test gives it.
final class FakeSurfaceEndpoint {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let readingGate = DispatchSemaphore(value: 0)
    private var connection: Int32 = -1
    private var frames: [Data] = []
    private var stopped = false

    /// `welcome` overrides fields of the welcome message; `afterHello` frames follow the snapshot.
    init(path: String, welcome: [String: Any] = [:], afterHello: [Data],
         sendsWelcome: Bool = true, sendsSnapshot: Bool = true, readsClient: Bool = true,
         echoesHealth: Bool = true, wrongHealthToken: Bool = false) throws {
        self.path = path
        listener = try listenUnixSocket(at: path)
        var message: [String: Any] = ["generation": 1, "error": NSNull(),
                                      "snapshot_codec": "shell.snapshot.v1", "surface_codec": "shell.surface.v1",
                                      "input_codec": "shell.input.semantic.v1", "blob_codec": "shell.blob.v1"]
        message.merge(welcome) { $1 }
        let welcomeJSON = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        Thread.detachNewThread { [self] in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            connection = fd
            let wasStopped = stopped
            lock.unlock()
            defer {
                lock.withLock { connection = -1 }
                close(fd)
            }
            guard !wasStopped else { return }
            guard let hello = readFrame(fd) else { return }
            record(hello)
            if sendsWelcome { send(Self.control("endpoint.welcome.v1", welcomeJSON)) }
            if sendsSnapshot { send(Self.control("shell.snapshot.v1", #"{"boot_id":"boot-test"}"#)) }
            for frame in afterHello { send(frame) }
            if !readsClient { readingGate.wait(); return }
            while let frame = readFrame(fd) {
                record(frame)
                if echoesHealth, frame.first == 20 {
                    var reader = SurfaceReaderProbe(frame)
                    _ = reader.number()
                    if reader.string() == "endpoint.health.ping.v1" {
                        let token = reader.string()
                        send(Self.control("endpoint.health.pong.v1", wrongHealthToken ? "wrong-token" : token))
                    }
                }
            }
        }
    }

    static func control(_ kind: String, _ data: String) -> Data {
        var writer = SurfaceWireWriter()
        writer.number(20)
        writer.string(kind)
        writer.string(data)
        return writer.data
    }

    var received: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// Sends one length-prefixed frame; `length` overrides the prefix to test malformed frames.
    func send(_ payload: Data, length: UInt32? = nil) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let fd = lock.withLock { connection >= 0 && !stopped ? dup(connection) : -1 }
        guard fd >= 0 else { return }
        defer { close(fd) }
        let size = length ?? UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8((size >> ($0 * 8)) & 0xff) })
        frame += payload
        frame.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    /// Writes a truncated length prefix without completing it.
    func sendPartialHeader() {
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.withLock {
            guard connection >= 0 else { return }
            var byte: UInt8 = 42
            _ = Darwin.write(connection, &byte, 1)
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        lock.unlock()
        readingGate.signal()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private func record(_ frame: Data) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    private func readFrame(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        return readExactly(fd, length)
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let amount = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: received), count - received) }
            guard amount > 0 else { return nil }
            received += amount
        }
        return data
    }
}

/// How key, text, paste and mouse input is encoded for Herdr's semantic input codec.
final class HerdrInputEncodingTests: XCTestCase {
    private let header: [UInt8] = [13, 5] + Array("w1:p1".utf8) + [1]

    private func encoded(_ event: HerdrInputEvent) -> [UInt8]? {
        SurfaceWriter.paneInput(paneID: "w1:p1", event: event).map { Array($0) }
    }

    /// Key payloads end with Press, one repeat, three empty options, tracks_release and two more.
    private let keyTail: [UInt8] = [0, 1, 0, 0, 1, 0, 0]

    func testNumbersUseVariableLength() {
        XCTAssertEqual(Array(SurfaceWriter.number(250)), [250])
        XCTAssertEqual(Array(SurfaceWriter.number(251)), [251, 251, 0])
        XCTAssertEqual(Array(SurfaceWriter.number(65_535)), [251, 255, 255])
        XCTAssertEqual(Array(SurfaceWriter.number(65_536)), [252, 0, 0, 1, 0])
        XCTAssertEqual(Array(SurfaceWriter.number(1 << 32)), [253, 0, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(Array(SurfaceWriter.string("ñ")), [2, 0xC3, 0xB1])
    }

    func testTextAndPaste() {
        XCTAssertEqual(encoded(.text("hi")), header + [1, 2] + Array("hi".utf8))
        XCTAssertEqual(encoded(.paste("x")), header + [3, 1] + Array("x".utf8))
    }

    func testNamedAndCharacterKeys() {
        XCTAssertEqual(encoded(.key("enter")), header + [0, 1, 0] + keyTail)
        XCTAssertEqual(encoded(.key("shift+enter")), header + [0, 1, 1] + keyTail)
        XCTAssertEqual(encoded(.key("shift+tab")), header + [0, 11, 1] + keyTail, "Shift-Tab is BackTab")
        XCTAssertEqual(encoded(.key("ctrl+c")), header + [0, 15] + Array("c".utf8) + [2] + keyTail)
        XCTAssertEqual(encoded(.key("alt+ñ")), header + [0, 15, 0xC3, 0xB1, 4] + keyTail)
    }

    /// Control or Option with the plus key arrives as "ctrl++"; it must not be dropped.
    func testPlusKeyIsEncoded() {
        XCTAssertEqual(encoded(.key("ctrl++")), header + [0, 15] + Array("+".utf8) + [2] + keyTail)
        XCTAssertEqual(encoded(.key("alt++")), header + [0, 15] + Array("+".utf8) + [4] + keyTail)
    }

    func testUnknownKeysAreNotSent() {
        XCTAssertNil(encoded(.key("f13")))
        XCTAssertNil(encoded(.key("ctrl+")))
        XCTAssertNil(encoded(.key("")))
    }

    func testMouseEvents() {
        let down = HerdrMouseEvent(kind: .down(0), column: 3, row: 4, modifiers: 1, lines: 0)
        XCTAssertEqual(encoded(.mouse(down)), header + [2, 0, 0, 0, 3, 4, 0, 1, 0])
        let scroll = HerdrMouseEvent(kind: .scrollUp, column: 300, row: 2, modifiers: 0, lines: 3)
        XCTAssertEqual(encoded(.mouse(scroll)), header + [2, 4, 0, 251, 44, 1, 2, 0, 0, 3])
        let drag = HerdrMouseEvent(kind: .drag(2), column: 0, row: 0, modifiers: 0, lines: 0)
        XCTAssertEqual(encoded(.mouse(drag)), header + [2, 2, 2, 0, 0, 0, 0, 0, 0])
    }
}

/// `HerdrSurfaceStream` against a fake binary endpoint.
final class HerdrSurfaceStreamTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = "/private/tmp/wooloo-tests/\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private var model: SurfaceModel {
        var model = SurfaceModel(width: 20, height: 4)
        var row = RowBuilder(width: 20)
        row.put("hello", foreground: Color.ansi(2))
        model.setRow(0, row.cells)
        return model
    }

    /// Runs the stream on a thread; returns what it delivered and a finished expectation.
    private func start(_ stream: HerdrSurfaceStream, path: String)
        -> (ready: XCTestExpectation, surfaces: () -> [HerdrSurface], error: () -> Error?, finished: XCTestExpectation) {
        let ready = expectation(description: "ready")
        let finished = expectation(description: "finished")
        let lock = NSLock()
        var surfaces: [HerdrSurface] = []
        var failure: Error?
        Thread.detachNewThread {
            do {
                try stream.run(path: path, cols: 20, rows: 4, cellWidth: 8, cellHeight: 16) {
                    ready.fulfill()
                } onSurface: { surface in
                    lock.lock(); surfaces.append(surface); lock.unlock()
                }
            } catch {
                lock.lock(); failure = error; lock.unlock()
            }
            finished.fulfill()
        }
        return (ready, { lock.lock(); defer { lock.unlock() }; return surfaces },
                { lock.lock(); defer { lock.unlock() }; return failure }, finished)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(condition())
    }

    private var shortTimeouts: HerdrEndpointTimeouts {
        HerdrEndpointTimeouts(handshake: .milliseconds(200), frame: .milliseconds(200),
                              write: .milliseconds(400), healthInterval: .milliseconds(100),
                              healthReply: .milliseconds(200))
    }

    func testMissingWelcomeOrSnapshotTimesOutAndCanBeCancelled() throws {
        for welcome in [false, true] {
            let endpoint = try FakeSurfaceEndpoint(path: directory + "/\(welcome).sock", afterHello: [],
                                                   sendsWelcome: welcome, sendsSnapshot: false)
            defer { endpoint.stop() }
            let stream = HerdrSurfaceStream(timeouts: shortTimeouts)
            let run = start(stream, path: endpoint.path)
            run.ready.isInverted = true
            wait(for: [run.finished], timeout: 2)
            wait(for: [run.ready], timeout: 0.01)
            XCTAssertTrue(String(describing: run.error()).contains("handshake"))
            XCTAssertFalse(stream.isReady)
            stream.cancel()
        }
    }

    func testIncompleteHeaderAndPayloadHaveAWholeFrameDeadline() throws {
        for header in [true, false] {
            let endpoint = try FakeSurfaceEndpoint(path: directory + "/\(header).sock", afterHello: [])
            defer { endpoint.stop() }
            let stream = HerdrSurfaceStream(timeouts: shortTimeouts)
            let run = start(stream, path: endpoint.path)
            wait(for: [run.ready], timeout: 3)
            if header { endpoint.sendPartialHeader() }
            else { endpoint.send(Data([20]), length: 200) }
            wait(for: [run.finished], timeout: 2)
            XCTAssertTrue(String(describing: run.error()).contains("frame"))
            XCTAssertFalse(stream.isReady)
        }
    }

    func testHealthyIdleEndpointsStayConnectedWithAndWithoutHealthCapability() throws {
        for health in [false, true] {
            let endpoint = try FakeSurfaceEndpoint(path: directory + "/\(health).sock",
                                                   welcome: ["capabilities": health ? ["health_check"] : []], afterHello: [])
            defer { endpoint.stop() }
            let stream = HerdrSurfaceStream(timeouts: shortTimeouts)
            let run = start(stream, path: endpoint.path)
            wait(for: [run.ready], timeout: 3)
            // Longer than the handshake, frame, and health-reply limits, without any surfaces.
            Thread.sleep(forTimeInterval: 0.9)
            XCTAssertTrue(stream.isReady)
            let probes = endpoint.received.filter { frame in
                guard frame.first == 20 else { return false }
                var reader = SurfaceReaderProbe(frame)
                _ = reader.number()
                return reader.string() == "endpoint.health.ping.v1"
            }
            XCTAssertEqual(probes.isEmpty, !health)
            stream.cancel()
            wait(for: [run.finished], timeout: 2)
        }
    }

    func testMissingOrUnmatchedHealthRepliesEndEvenAnActiveEndpoint() throws {
        for wrong in [false, true] {
            let endpoint = try FakeSurfaceEndpoint(path: directory + "/\(wrong).sock",
                                                   welcome: ["capabilities": ["health_check"]], afterHello: [model.surfaceFrame()],
                                                   echoesHealth: wrong, wrongHealthToken: wrong)
            defer { endpoint.stop() }
            let stream = HerdrSurfaceStream(timeouts: shortTimeouts)
            let run = start(stream, path: endpoint.path)
            wait(for: [run.ready, run.finished], timeout: 3)
            XCTAssertTrue(String(describing: run.error()).contains("health reply"))
            XCTAssertFalse(stream.isReady)
        }
    }

    func testStoppedReaderDoesNotBlockSendingOrCancellation() throws {
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", afterHello: [], readsClient: false)
        defer { endpoint.stop() }
        var timeouts = shortTimeouts
        timeouts.write = .seconds(5)
        let stream = HerdrSurfaceStream(timeouts: timeouts)
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 3)
        let before = ContinuousClock.now
        XCTAssertTrue(stream.sendInput(.paste(String(repeating: "x", count: 8 * 1024 * 1024)), to: "w1:p1"))
        // The writer now has more than a socket buffer to deliver to a peer which never reads.
        Thread.sleep(forTimeInterval: 0.1)
        stream.cancel()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        wait(for: [run.finished], timeout: 2)
        XCTAssertFalse(stream.sendInput(.text("late"), to: "w1:p1"))
    }

    func testStoppedReaderWriteTimesOutWithoutCancellation() throws {
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", afterHello: [], readsClient: false)
        defer { endpoint.stop() }
        let stream = HerdrSurfaceStream(timeouts: shortTimeouts)
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 3)
        XCTAssertTrue(stream.sendInput(.paste(String(repeating: "x", count: 8 * 1024 * 1024)), to: "w1:p1"))
        wait(for: [run.finished], timeout: 2)
        XCTAssertTrue(String(describing: run.error()).contains("write"))
        XCTAssertFalse(stream.isReady)
    }

    func testCancellationInterruptsHandshakeAndPartialRead() throws {
        for ready in [false, true] {
            let endpoint = try FakeSurfaceEndpoint(path: directory + "/\(ready).sock", afterHello: [],
                                                   sendsWelcome: ready, sendsSnapshot: ready)
            defer { endpoint.stop() }
            let stream = HerdrSurfaceStream()
            let run = start(stream, path: endpoint.path)
            if ready {
                wait(for: [run.ready], timeout: 3)
                endpoint.sendPartialHeader()
            } else {
                run.ready.isInverted = true
                waitUntil { !endpoint.received.isEmpty }
            }
            stream.cancel()
            wait(for: [run.finished], timeout: 1)
            if !ready { wait(for: [run.ready], timeout: 0.01) }
            XCTAssertFalse(stream.isReady)
        }
    }

    func testHandshakeSurfacesAndClientMessages() throws {
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", afterHello: [model.surfaceFrame()])
        defer { endpoint.stop() }
        let stream = HerdrSurfaceStream()
        XCTAssertFalse(stream.sendInput(.text("early"), to: "w1:p1"), "Input waits for the endpoint")
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 5)
        waitUntil { run.surfaces().count == 1 }
        XCTAssertEqual(run.surfaces().first?.cells, model.surface.cells)
        XCTAssertEqual(run.surfaces().first?.paneIDs, ["w1:p1"])

        // The hello asks for the codecs wooloo decodes.
        var hello = SurfaceReaderProbe(endpoint.received[0])
        XCTAssertEqual(hello.number(), 20)
        XCTAssertEqual(hello.string(), "endpoint.hello.v1")
        let helloJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.string().utf8)) as? [String: Any])
        XCTAssertEqual(helloJSON["generation"] as? Int, 1)
        XCTAssertEqual(helloJSON["surface_codecs"] as? [String], ["shell.surface.v1"])
        XCTAssertEqual(helloJSON["surface_scroll"] as? Bool, true, "scrolling output arrives as row shifts")

        XCTAssertTrue(stream.sendInput(.text("ls"), to: "w1:p1"))
        stream.resize(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        stream.resize(cols: 0, rows: 30, cellWidth: 8, cellHeight: 16)
        stream.focus(tabID: "w1:t2")
        waitUntil { endpoint.received.count == 4 }
        let frames = endpoint.received
        XCTAssertEqual(frames[1], SurfaceWriter.paneInput(paneID: "w1:p1", event: .text("ls")))
        XCTAssertEqual(Array(frames[2]), [12, 8, 16, 100, 30, 0], "An invalid size is not sent")

        var request = SurfaceReaderProbe(frames[3])
        XCTAssertEqual(request.number(), 15)
        XCTAssertEqual(request.string(), "boot-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.string().utf8)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "tab.focus")
        XCTAssertEqual((json["params"] as? [String: Any])?["tab_id"] as? String, "w1:t2")

        stream.cancel()
        wait(for: [run.finished], timeout: 3)
        XCTAssertFalse(stream.sendInput(.text("late"), to: "w1:p1"))
    }

    func testPatchesUpdateTheSurface() throws {
        var next = model
        next.revision = 2
        var row = RowBuilder(width: 20)
        row.put("world")
        next.setRow(2, row.cells)
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock",
                                               afterHello: [model.surfaceFrame(), next.patchFrame(baseRevision: 1, rows: [2])])
        defer { endpoint.stop() }
        let stream = HerdrSurfaceStream()
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 5)
        waitUntil { run.surfaces().count == 2 }
        XCTAssertEqual(run.surfaces().last?.cells, next.surface.cells)
        XCTAssertEqual(run.surfaces().last?.revision, 2)
        stream.cancel()
        wait(for: [run.finished], timeout: 3)
    }

    func testScrolledPatchesUpdateTheSurface() throws {
        var next = model
        next.revision = 2
        var row = RowBuilder(width: 20)
        row.put("scrolled in")
        next.scroll(appending: row.cells)
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", afterHello: [
            model.surfaceFrame(), next.scrollFrame(from: model, scrolls: [(next.paneRect, 1)])
        ])
        defer { endpoint.stop() }
        let stream = HerdrSurfaceStream()
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 5)
        waitUntil { run.surfaces().count == 2 }
        XCTAssertEqual(run.surfaces().last?.cells, next.surface.cells)
        XCTAssertEqual(run.surfaces().last?.revision, 2)
        stream.cancel()
        wait(for: [run.finished], timeout: 3)
    }

    func testIncompatibleWelcomeIsRejected() throws {
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", welcome: ["generation": 2], afterHello: [])
        defer { endpoint.stop() }
        let run = start(HerdrSurfaceStream(), path: endpoint.path)
        run.ready.isInverted = true
        wait(for: [run.finished, run.ready], timeout: 3)
        XCTAssertTrue(String(describing: run.error() as Any).contains("Herdr rejected surface endpoint"))
    }

    func testMalformedFramesEndTheStream() throws {
        let endpoint = try FakeSurfaceEndpoint(path: directory + "/c.sock", afterHello: [])
        defer { endpoint.stop() }
        let stream = HerdrSurfaceStream()
        let run = start(stream, path: endpoint.path)
        wait(for: [run.ready], timeout: 5)
        endpoint.send(Data(), length: 0)
        wait(for: [run.finished], timeout: 3)
        XCTAssertNotNil(run.error())
        XCTAssertFalse(stream.isReady)
    }
}

/// Reads the numbers and strings of a frame wooloo wrote, like Herdr's decoder.
struct SurfaceReaderProbe {
    private var bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func number() -> UInt64 {
        let first = bytes[index]; index += 1
        let width: Int
        switch first {
        case 251: width = 2
        case 252: width = 4
        case 253: width = 8
        default: return UInt64(first)
        }
        var value: UInt64 = 0
        for offset in 0..<width { value |= UInt64(bytes[index + offset]) << (offset * 8) }
        index += width
        return value
    }

    mutating func string() -> String {
        let count = Int(number())
        defer { index += count }
        return String(decoding: bytes[index..<(index + count)], as: UTF8.self)
    }
}

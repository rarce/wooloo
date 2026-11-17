import Foundation

/// A byte pipe to a core: `hc connect` over a process's stdio, locally or through SSH, or an
/// in-memory server in tests. `read` blocks and returns empty data at the end.
protocol CoreTransport: AnyObject, Sendable {
    func read() throws -> Data
    func write(_ data: Data) throws
    func close()
}

/// `hc connect` (or another command that ends in it, such as `ssh host … hc connect`), with
/// the protocol on its stdin and stdout.
final class ProcessCoreTransport: CoreTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var closed = false

    init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func read() throws -> Data { output.fileHandleForReading.availableData }

    func write(_ data: Data) throws {
        guard lock.withLock({ !closed }) else { throw CoreProtocolError.closed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        guard lock.withLock({ () -> Bool in defer { closed = true }; return !closed }) else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// One framed connection to a core. Calls on channel 0 run side by side; every stream byte
/// read is credited back, so a slow reader never stalls channel 0 or other streams.
/// A reader thread owns the transport's input; writes are serialized under a lock.
final class CoreConnection: @unchecked Sendable {
    private let transport: CoreTransport
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID = 1
    private var replies: [Int: Data] = [:]
    private var waiting: [Int: DispatchSemaphore] = [:]
    private var streams: [UInt32: (Data) -> Void] = [:]
    private var closers: [UInt32: () -> Void] = [:]
    private var resizers: [UInt32: (Int, Int) -> Void] = [:]
    private var ended = false
    private var lastFrame = Date()
    private var leftover = Data()

    private(set) var hello: CoreHello?

    init(transport: CoreTransport) { self.transport = transport }

    var isClosed: Bool { lock.withLock { ended } }
    /// When the core last sent anything; the heartbeat guarantees something every 15 s.
    var lastActivity: Date { lock.withLock { lastFrame } }

    /// Sends `hello` in plain mode, switches to framed mode and starts reading. Lines before the
    /// handshake that are not JSON (a remote login's greeting) are skipped until `banner`, when
    /// one is given, or else ignored.
    @discardableResult
    func open(banner: String? = nil, timeout: TimeInterval = 15) throws -> CoreHello {
        let deadline = Date().addingTimeInterval(timeout)
        if let banner { try readLine(until: { $0 == banner }, deadline: deadline) }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "hello",
                                      "params": ["framed": true, "generation": 1]]
        try transport.write(JSONSerialization.data(withJSONObject: request) + Data([0x0a]))
        var reply: Data?
        try readLine(until: { line in
            guard line.hasPrefix("{") else { return false }
            reply = Data(line.utf8)
            return true
        }, deadline: deadline)
        guard let reply else { throw CoreProtocolError.handshake("no answer") }
        let hello = try Self.result(CoreHello.self, from: reply)
        try CoreProtocol.validate(hello)
        self.hello = hello
        let thread = Thread { [self] in readFrames() }
        thread.name = "dev.wooloo.core-reader"
        thread.qualityOfService = .userInitiated
        thread.start()
        return hello
    }

    private func readLine(until done: (String) -> Bool, deadline: Date) throws {
        while true {
            while let newline = leftover.firstIndex(of: 0x0a) {
                let line = String(decoding: leftover[leftover.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                leftover = Data(leftover[(newline + 1)...])
                if done(line) { return }
            }
            guard Date() < deadline else { throw CoreProtocolError.handshake("timed out") }
            let data = try transport.read()
            guard !data.isEmpty else { throw CoreProtocolError.handshake("the connection closed") }
            leftover.append(data)
        }
    }

    private func readFrames() {
        var decoder = CoreFrameDecoder()
        decoder.append(leftover)
        leftover = Data()
        do {
            while true {
                while let frame = try decoder.next() { try handle(frame) }
                let data = try transport.read()
                if data.isEmpty { break }
                decoder.append(data)
            }
        } catch {}
        finish()
    }

    private func handle(_ frame: CoreFrame) throws {
        lock.withLock { lastFrame = Date() }
        switch (frame.channel, frame.kind) {
        case (0, .data):
            guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            let semaphore = lock.withLock { () -> DispatchSemaphore? in
                replies[id] = frame.payload
                return waiting.removeValue(forKey: id)
            }
            semaphore?.signal()
        case (_, .data):
            let handler = lock.withLock { streams[frame.channel] }
            handler?(frame.payload)
            try send(.credit(frame.payload.count, channel: frame.channel))
        case (_, .resize):
            guard frame.payload.count >= 4 else { return }
            let bytes = [UInt8](frame.payload.prefix(4))
            let cols = Int(bytes[0]) | Int(bytes[1]) << 8, rows = Int(bytes[2]) | Int(bytes[3]) << 8
            let resizer = lock.withLock { resizers[frame.channel] }
            if cols > 0, rows > 0 { resizer?(cols, rows) }
        case (_, .close):
            let closer = lock.withLock { () -> (() -> Void)? in
                streams[frame.channel] = nil
                resizers[frame.channel] = nil
                return closers.removeValue(forKey: frame.channel)
            }
            closer?()
        default:
            break
        }
    }

    private func finish() {
        let (semaphores, closing) = lock.withLock { () -> ([DispatchSemaphore], [() -> Void]) in
            ended = true
            let semaphores = Array(waiting.values)
            waiting = [:]
            let closing = Array(closers.values)
            closers = [:]
            streams = [:]
            resizers = [:]
            return (semaphores, closing)
        }
        semaphores.forEach { $0.signal() }
        closing.forEach { $0() }
        transport.close()
    }

    func close() { transport.close() }

    func send(_ frame: CoreFrame) throws {
        try writeLock.withLock { try transport.write(frame.encoded()) }
    }

    /// Calls `method` and decodes its result.
    func call<Result: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: Result.Type = Result.self,
                                 timeout: TimeInterval = 10) throws -> Result {
        try Self.result(type, from: callRaw(method, params, timeout: timeout))
    }

    /// Calls `method` and returns the whole reply.
    func callRaw(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let id = try lock.withLock { () throws -> Int in
            guard !ended else { throw CoreProtocolError.closed }
            defer { nextID += 1 }
            waiting[nextID] = semaphore
            return nextID
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        do {
            try send(CoreFrame(channel: 0, kind: .data, payload: JSONSerialization.data(withJSONObject: request)))
        } catch {
            _ = lock.withLock { waiting.removeValue(forKey: id) }
            throw error
        }
        let answered = semaphore.wait(timeout: .now() + timeout) == .success
        let reply = lock.withLock { () -> Data? in
            waiting[id] = nil
            return replies.removeValue(forKey: id)
        }
        guard let reply else { throw answered ? CoreProtocolError.closed : CoreProtocolError.timedOut(method) }
        return reply
    }

    /// Routes a stream channel's bytes to `onData` (credited after it returns), its end to
    /// `onClose`, and the terminal's size to `onResize` when Core sends one, as it does to
    /// observers that asked for `resize_notifications`. Register it before the reply that names
    /// the channel can be followed by data: cores send the reply first, and this runs on the
    /// caller's thread right after it.
    func route(channel: UInt32, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void,
               onResize: ((Int, Int) -> Void)? = nil) {
        let alreadyEnded = lock.withLock { () -> Bool in
            guard !ended else { return true }
            streams[channel] = onData
            closers[channel] = onClose
            resizers[channel] = onResize
            return false
        }
        if alreadyEnded { onClose() }
    }

    static func result<Result: Decodable>(_ type: Result.Type, from reply: Data) throws -> Result {
        if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "herdr-core refused the request"
            let data = error["data"] as? [String: Any]
            throw CoreProtocolError.remote(kind: data?["kind"] as? String, message: message)
        }
        return try JSONDecoder().decode(CoreReply<Result>.self, from: reply).result
    }
}

private struct CoreReply<Result: Decodable>: Decodable {
    let result: Result
}

/// Splits an events channel's bytes into JSON lines.
struct CoreEventLines {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [CoreEvent] {
        buffer.append(data)
        var events: [CoreEvent] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[(newline + 1)...])
            struct Notification: Decodable { let params: CoreEvent }
            if let event = try? JSONDecoder().decode(Notification.self, from: line) { events.append(event.params) }
        }
        return events
    }
}

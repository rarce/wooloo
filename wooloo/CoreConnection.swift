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
/// handed to a route is credited back, so a slow reader never stalls channel 0 or other streams.
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
    /// What a stream channel sent before anyone routed it: the reader thread goes on with the
    /// frames that follow a reply while the caller is still reading that reply, so an attach's
    /// replay can arrive first. `route` hands it over. Those bytes are credited only once handed
    /// over, so Core holds the rest (or repaints): nothing is dropped, and memory stays within
    /// the stream's initial credit.
    private var early: [UInt32: EarlyStream] = [:]
    /// Streams closed before anyone routed them: what they still send is dropped.
    private var discarded: Set<UInt32> = []
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
                guard let semaphore = waiting.removeValue(forKey: id) else { return nil }
                replies[id] = frame.payload
                return semaphore
            }
            guard let semaphore else {
                // Nobody waits for this reply any more: its call timed out. A stream it opened
                // would never be read, so it is closed.
                if let channel = Self.channel(in: frame.payload) { discard(channel: channel) }
                return
            }
            semaphore.signal()
        case (_, .data):
            let handler = lock.withLock { () -> ((Data) -> Void)? in
                if let handler = streams[frame.channel] { return handler }
                if !discarded.contains(frame.channel) { early[frame.channel, default: EarlyStream()].append(data: frame.payload) }
                return nil
            }
            guard let handler else { return }
            handler(frame.payload)
            try send(.credit(frame.payload.count, channel: frame.channel))
        case (_, .resize):
            guard frame.payload.count >= 4 else { return }
            let bytes = [UInt8](frame.payload.prefix(4))
            let cols = Int(bytes[0]) | Int(bytes[1]) << 8, rows = Int(bytes[2]) | Int(bytes[3]) << 8
            guard cols > 0, rows > 0 else { return }
            let resizer = lock.withLock { () -> ((Int, Int) -> Void)? in
                if streams[frame.channel] == nil, !discarded.contains(frame.channel) {
                    early[frame.channel, default: EarlyStream()].events.append(.resize(cols, rows))
                }
                return resizers[frame.channel]
            }
            resizer?(cols, rows)
        case (_, .close):
            let closer = lock.withLock { () -> (() -> Void)? in
                if discarded.remove(frame.channel) == nil, streams[frame.channel] == nil {
                    early[frame.channel, default: EarlyStream()].closed = true
                }
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
            early = [:]
            discarded = []
            return (semaphores, closing)
        }
        semaphores.forEach { $0.signal() }
        closing.forEach { $0() }
        transport.close()
    }

    func close() { transport.close() }

    /// Closes a stream that will never be routed, such as one whose attach failed after Core
    /// opened it, and drops what it sent or still sends.
    func discard(channel: UInt32) {
        let open = lock.withLock { () -> Bool in
            // Core may have closed it already: then there is nothing left to drop or close.
            if early.removeValue(forKey: channel)?.closed == true { return false }
            if streams[channel] == nil { discarded.insert(channel) }
            return true
        }
        if open { try? send(CoreFrame(channel: channel, kind: .close, payload: Data())) }
    }

    func send(_ frame: CoreFrame) throws {
        try writeLock.withLock { try transport.write(frame.encoded()) }
    }

    /// Calls `method` and decodes its result. A reply this build cannot read may still have
    /// opened a stream (`terminal.attach`, `events.subscribe`); nothing would read it, so it is closed.
    func call<Result: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: Result.Type = Result.self,
                                 timeout: TimeInterval = 10) throws -> Result {
        let reply = try callRaw(method, params, timeout: timeout)
        do {
            return try Self.result(type, from: reply)
        } catch {
            if let channel = Self.channel(in: reply) { discard(channel: channel) }
            throw error
        }
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
    /// observers that asked for `resize_notifications`. Cores send the reply that names the
    /// channel first and its data right after, often before the caller gets here: what came
    /// meanwhile is delivered now, in order, before anything newer.
    func route(channel: UInt32, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void,
               onResize: ((Int, Int) -> Void)? = nil) {
        // The handler goes in only once nothing is waiting, so the reader never hands
        // `onData` newer bytes before older ones.
        while true {
            let step = lock.withLock { () -> (ended: Bool, held: EarlyStream?) in
                guard !ended else { return (true, nil) }
                if let held = early.removeValue(forKey: channel) { return (false, held) }
                streams[channel] = onData
                closers[channel] = onClose
                resizers[channel] = onResize
                return (false, nil)
            }
            if step.ended { onClose(); return }
            guard let held = step.held else { return }
            // In the order they came: a resize applies to the bytes after it, not before.
            for event in held.events {
                switch event {
                case .data(let data):
                    onData(data)
                    try? send(.credit(data.count, channel: channel))
                case .resize(let cols, let rows):
                    onResize?(cols, rows)
                }
            }
            if held.closed { onClose(); return }
        }
    }

    /// The stream channel a reply opened, if it names one.
    static func channel(in reply: Data) -> UInt32? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let channel = (result["channel"] as? NSNumber)?.uint32Value, channel != 0 else { return nil }
        return channel
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

/// A stream channel's frames that arrived before `route` registered it, in order.
private struct EarlyStream {
    enum Event {
        case data(Data)
        case resize(Int, Int)
    }

    var events: [Event] = []
    var closed = false

    mutating func append(data: Data) {
        if case .data(var held)? = events.last {
            // Taken out first, so the buffer is not shared and grows in place.
            events.removeLast()
            held.append(data)
            events.append(.data(held))
        } else {
            events.append(.data(data))
        }
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

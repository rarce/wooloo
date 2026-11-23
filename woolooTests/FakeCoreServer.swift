import Foundation
@testable import wooloo

/// An in-memory herdr-core. Each `connect()` is one client connection: it answers `hello` in
/// plain mode, then framed JSON-RPC calls, and can push events on its subscription channel.
/// Connections share the core's terminals, screens and the record of calls.
final class FakeCore: @unchecked Sendable {
    struct Call { let method: String; let params: [String: Any] }

    let lock = NSLock()
    var version = "0.1.21"
    /// What `hello` advertises; without `resize_notifications`, observers get no RESIZE frames.
    var features = ["framed", "automatic_input", "resize_notifications"]
    var methods: [String] = Array(CoreProtocol.requiredMethods) + ["hello", "rpc.discover"]
    var terminals: [CoreTerminal] = []
    var screens: [String: String] = [:]
    var greeting: [String] = []
    /// Answers to calls by method; a nil answer is a JSON-RPC error.
    var overrides: [String: ([String: Any]) -> Any?] = [:]
    var calls: [Call] = []
    /// Methods whose replies wait for `FakeCoreServer.releaseReplies()`, as from a slow core.
    var heldReplies: Set<String> = []
    /// Documents by name: the value (nil when deleted or never written) and its version.
    var documents: [String: (value: Any?, version: Int)] = [:]
    private(set) var connections: [FakeCoreServer] = []

    func connect() -> FakeCoreServer {
        let server = FakeCoreServer(core: self)
        lock.withLock { connections.append(server) }
        return server
    }

    func callsTo(_ method: String) -> [Call] { lock.withLock { calls.filter { $0.method == method } } }
    func update(_ change: (FakeCore) -> Void) { lock.withLock { change(self) } }
}

final class FakeCoreServer: CoreTransport, @unchecked Sendable {
    let core: FakeCore
    init(core: FakeCore) {
        self.core = core
        // A remote script prints its greeting and banner before the protocol starts.
        for text in core.greeting { outgoing.append(Data((text + "\n").utf8)) }
    }

    private var lock: NSLock { core.lock }
    private let available = DispatchSemaphore(value: 0)
    private var outgoing = Data()
    private var incoming = Data()
    private var framed = false
    private var closed = false
    private var decoder = CoreFrameDecoder()
    private(set) var streamFrames: [CoreFrame] = []
    private(set) var credits: [UInt32: Int] = [:]
    private var nextChannel: UInt32 = 1
    private(set) var eventsChannel: UInt32?
    private var seq: UInt64 = 0

    // MARK: CoreTransport

    func read() throws -> Data {
        while true {
            let data = lock.withLock { () -> Data? in
                if !outgoing.isEmpty { defer { outgoing = Data() }; return outgoing }
                return closed ? Data() : nil
            }
            if let data { return data }
            available.wait()
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !closed else { throw CoreProtocolError.closed }
            incoming.append(data)
            try process()
        }
    }

    func close() {
        lock.withLock { closed = true }
        available.signal()
    }

    // MARK: Server side

    /// Pushes one event notification on the subscription channel.
    func emit(type: String?, terminal: String? = nil, data: [String: Any]? = nil) {
        lock.withLock { pushEvent(type: type, terminal: terminal, data: data) }
    }

    /// `emit` for a caller that already holds the core's lock.
    fileprivate func pushEvent(type: String?, terminal: String?, data: [String: Any]? = nil) {
        do {
            guard let channel = eventsChannel else { return }
            seq += 1
            var params: [String: Any] = ["seq": seq]
            if let type { params["type"] = type }
            if let terminal { params["terminal"] = terminal }
            if let data { params["data"] = data }
            let line = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
            enqueue(CoreFrame(channel: channel, kind: .data, payload: line + Data([0x0a])).encoded())
        }
    }

    /// Tells an observer the terminal's size, as Core does with `resize_notifications`.
    func sendResize(cols: Int, rows: Int, on channel: UInt32) {
        lock.withLock { enqueue(CoreFrame.resize(cols: cols, rows: rows, channel: channel).encoded()) }
    }

    /// Sends a terminal's output on an attach channel.
    func send(_ data: Data, on channel: UInt32) {
        lock.withLock { enqueue(CoreFrame(channel: channel, kind: .data, payload: data).encoded()) }
    }

    /// Stream frames the client sent, read under the core's lock.
    func recordedFrames() -> [CoreFrame] { lock.withLock { streamFrames } }

    /// The channels `terminal.attach` handed out, in order.
    private(set) var attachChannels: [UInt32] = []

    private var withheld: [Data] = []

    /// Sends the replies `FakeCore.heldReplies` kept back.
    func releaseReplies() {
        lock.withLock { for reply in withheld { enqueue(reply) }; withheld = [] }
    }

    /// Ends a stream from the core's side.
    func closeChannel(_ channel: UInt32) {
        lock.withLock { enqueue(CoreFrame(channel: channel, kind: .close, payload: Data()).encoded()) }
    }

    private func enqueue(_ data: Data) {
        outgoing.append(data)
        available.signal()
    }

    private func process() throws {
        if !framed {
            guard let newline = incoming.firstIndex(of: 0x0a) else { return }
            let line = Data(incoming[incoming.startIndex..<newline])
            incoming = Data(incoming[(newline + 1)...])
            let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
            core.calls.append(FakeCore.Call(method: request["method"] as? String ?? "", params: request["params"] as? [String: Any] ?? [:]))
            let hello: [String: Any] = [
                "core": ["id": "0123456789abcdef", "name": "box"], "features": core.features,
                "framed": true, "generation": 1, "methods": core.methods, "version": core.version,
            ]
            enqueue(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": request["id"] ?? 0,
                                                                "result": hello]) + Data([0x0a]))
            framed = true
            decoder.append(incoming)
            incoming = Data()
        } else {
            decoder.append(incoming)
            incoming = Data()
        }
        while let frame = try decoder.next() {
            if frame.channel == 0, frame.kind == .data { try answer(frame.payload) }
            else if frame.kind == .credit {
                credits[frame.channel, default: 0] += Int(frame.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            } else { streamFrames.append(frame) }
        }
    }

    private func answer(_ payload: Data) throws {
        let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        core.calls.append(FakeCore.Call(method: method, params: params))
        let result: Any?
        if let override = core.overrides[method] {
            result = override(params)
        } else {
            switch method {
            case "terminal.list": result = ["terminals": try encoded(core.terminals), "hidden_finished": 0, "machines": []]
            case "events.subscribe":
                eventsChannel = nextChannel
                nextChannel += 1
                result = ["channel": eventsChannel!, "seq": seq, "terminals": try encoded(core.terminals)]
            case "terminal.read":
                result = ["text": core.screens[params["terminal"] as? String ?? ""] ?? "", "complete": true, "how": "screen"]
            case "terminal.run":
                let terminal = CoreTerminal(address: "t\(core.terminals.count + 1)", argv: ["/bin/zsh"],
                                            cwd: params["cwd"] as? String ?? "/",
                                            labels: params["labels"] as? [String: String] ?? [:])
                core.terminals.append(terminal)
                result = try encoded(terminal)
            case "terminal.kill":
                core.terminals.removeAll { $0.address == params["terminal"] as? String }
                result = ["address": params["terminal"] ?? ""]
            case "terminal.attach":
                let channel = nextChannel
                nextChannel += 1
                attachChannels.append(channel)
                let terminal = core.terminals.first { $0.address == params["terminal"] as? String }
                result = ["channel": channel, "terminal": try terminal.map(encoded) ?? [:],
                          "resize_notifications": params["resize_notifications"] as? Bool == true
                              && core.features.contains("resize_notifications"),
                          "automatic_input": true]
            case "terminal.keys": result = ["turn": 0, "status": NSNull()]
            case "doc.get":
                let document = core.documents[params["name"] as? String ?? ""]
                result = ["value": document?.value ?? NSNull(), "version": document?.version ?? 0]
            case "doc.set":
                let name = params["name"] as? String ?? ""
                let current = core.documents[name]?.version ?? 0
                guard params["version"] as? Int == current else {
                    let reply: [String: Any] = ["jsonrpc": "2.0", "id": request["id"] ?? 0,
                        "error": ["code": -32000, "message": "document \"\(name)\" is at version \(current)",
                                  "data": ["kind": "conflict"]]]
                    enqueue(CoreFrame(channel: 0, kind: .data, payload: try JSONSerialization.data(withJSONObject: reply)).encoded())
                    return
                }
                let value = params["value"].flatMap { $0 is NSNull ? nil : $0 }
                core.documents[name] = (value, current + 1)
                result = ["version": current + 1]
                for server in core.connections { server.pushEvent(type: "doc", terminal: nil) }
            case "terminal.label":
                if let address = params["terminal"] as? String, let labels = params["labels"] as? [String: String],
                   let index = core.terminals.firstIndex(where: { $0.address == address }) {
                    let old = core.terminals[index]
                    var merged = old.labels
                    for (key, value) in labels { merged[key] = value.isEmpty ? nil : value }
                    core.terminals[index] = CoreTerminal(address: old.address, argv: old.argv, cols: old.cols, rows: old.rows,
                                                         cwd: old.cwd, labels: merged, name: old.name, state: old.state,
                                                         status: old.status, title: old.title, turn: old.turn)
                }
                result = [:]
            default: result = [:]
            }
        }
        let reply: [String: Any] = result.map { ["jsonrpc": "2.0", "id": request["id"] ?? 0, "result": $0] }
            ?? ["jsonrpc": "2.0", "id": request["id"] ?? 0,
                "error": ["code": -32000, "message": "refused \(method)", "data": ["kind": "refused"]]]
        let frame = CoreFrame(channel: 0, kind: .data, payload: try JSONSerialization.data(withJSONObject: reply)).encoded()
        if core.heldReplies.contains(method) { withheld.append(frame) } else { enqueue(frame) }
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

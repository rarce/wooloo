import Foundation

// herdr-core's client protocol, generation 1 (docs/herdr-core.md; Core `schema/README.md`):
// newline-delimited JSON-RPC 2.0 until `hello` with `framed: true`, then frames of
// `[channel u32 LE][kind u8][len u32 LE][payload]`. Channel 0 carries JSON-RPC; others carry
// streams (events as JSON lines, terminals as raw bytes) with byte credit.

enum CoreFrameKind: UInt8, Sendable {
    case data = 0
    case credit = 1
    case close = 2
    case resize = 3
    case focus = 4
    case facts = 5
    case automaticInput = 6
}

struct CoreFrame: Equatable, Sendable {
    static let headerLength = 9
    static let maximumPayload = 16 * 1024 * 1024

    let channel: UInt32
    let kind: CoreFrameKind
    let payload: Data

    func encoded() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        withUnsafeBytes(of: channel.littleEndian) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func credit(_ bytes: Int, channel: UInt32) -> CoreFrame {
        var payload = Data()
        withUnsafeBytes(of: UInt32(clamping: bytes).littleEndian) { payload.append(contentsOf: $0) }
        return CoreFrame(channel: channel, kind: .credit, payload: payload)
    }
}

/// Splits a byte stream into frames, keeping a partial frame until the rest arrives.
struct CoreFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    mutating func next() throws -> CoreFrame? {
        guard buffer.count >= CoreFrame.headerLength else { return nil }
        let start = buffer.startIndex
        let channel = UInt32(littleEndianBytes: buffer[start..<start + 4])
        let rawKind = buffer[start + 4]
        let length = Int(UInt32(littleEndianBytes: buffer[start + 5..<start + 9]))
        guard length <= CoreFrame.maximumPayload else { throw CoreProtocolError.frameTooLarge(length) }
        guard buffer.count >= CoreFrame.headerLength + length else { return nil }
        guard let kind = CoreFrameKind(rawValue: rawKind) else { throw CoreProtocolError.unknownFrameKind(rawKind) }
        let payload = Data(buffer[start + 9..<start + 9 + length])
        buffer = Data(buffer[(start + 9 + length)...])
        return CoreFrame(channel: channel, kind: kind, payload: payload)
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: Data) {
        var value: UInt32 = 0
        for (offset, byte) in bytes.enumerated() { value |= UInt32(byte) << (8 * offset) }
        self = value
    }
}

enum CoreProtocolError: LocalizedError, Equatable {
    case frameTooLarge(Int)
    case unknownFrameKind(UInt8)
    case handshake(String)
    case unsupportedCore(version: String, missing: [String])
    case remote(kind: String?, message: String)
    case closed
    case timedOut(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let length): return "herdr-core sent a frame of \(length) bytes, over the 16 MiB limit."
        case .unknownFrameKind(let kind): return "herdr-core sent an unknown frame kind (\(kind))."
        case .handshake(let detail): return "Could not start talking to herdr-core: \(detail)"
        case let .unsupportedCore(version, missing):
            let needs = missing.isEmpty ? "" : " It lacks \(missing.joined(separator: ", "))."
            return "herdr-core \(version) is too old for wooloo, which needs \(CoreProtocol.minimumVersion) or later.\(needs) Run `hc update`."
        case let .remote(_, message): return message
        case .closed: return "The connection to herdr-core ended."
        case .timedOut(let method): return "herdr-core did not answer \(method) in time."
        case .unsupported(let action): return "herdr-core connections cannot \(action) yet."
        }
    }
}

enum CoreProtocol {
    /// The version Phase 0 measured (docs/proposals/herdr-core-backend.md).
    static let minimumVersion = "0.1.21"
    static let requiredMethods: Set<String> = [
        "terminal.run", "terminal.attach", "terminal.list", "terminal.kill", "terminal.label",
        "terminal.rm", "terminal.keep", "terminal.read", "terminal.keys",
        "events.subscribe", "doc.get", "doc.set",
    ]

    /// Whether dotted version `a` is at least `b`, comparing numeric parts.
    static func version(_ a: String, isAtLeast b: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0, y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Checks a `hello` answer: protocol generation, version and the methods wooloo calls.
    static func validate(_ hello: CoreHello) throws {
        guard hello.generation == 1 else { throw CoreProtocolError.handshake("protocol generation \(hello.generation)") }
        guard hello.framed else { throw CoreProtocolError.handshake("framed mode was refused") }
        let missing = requiredMethods.subtracting(hello.methods).sorted()
        guard version(hello.version, isAtLeast: minimumVersion), missing.isEmpty else {
            throw CoreProtocolError.unsupportedCore(version: hello.version, missing: missing)
        }
    }
}

// MARK: - Messages

struct CoreInfo: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct CoreHello: Codable, Equatable, Sendable {
    let core: CoreInfo
    let features: [String]
    let framed: Bool
    let generation: Int
    let methods: [String]
    let version: String
}

struct CoreStatus: Codable, Equatable, Sendable {
    let state: String
    let app: String?
    let msg: String?
    let title: String?
}

struct CoreTerminal: Codable, Equatable, Sendable {
    let address: String
    let argv: [String]
    let cols: Int
    let rows: Int
    let cwd: String
    let labels: [String: String]
    let name: String?
    let state: String
    let status: CoreStatus?
    let title: String?
    let turn: UInt64?

    enum CodingKeys: String, CodingKey {
        case address, argv, cols, rows, cwd, labels, name, state, status, title, turn
    }

    init(address: String, argv: [String] = [], cols: Int = 80, rows: Int = 24, cwd: String = "/",
         labels: [String: String] = [:], name: String? = nil, state: String = "live",
         status: CoreStatus? = nil, title: String? = nil, turn: UInt64? = 0) {
        self.address = address
        self.argv = argv
        self.cols = cols
        self.rows = rows
        self.cwd = cwd
        self.labels = labels
        self.name = name
        self.state = state
        self.status = status
        self.title = title
        self.turn = turn
    }

    /// Records may leave out fields the schema gives defaults for.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        argv = try values.decodeIfPresent([String].self, forKey: .argv) ?? []
        cols = try values.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try values.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        name = try values.decodeIfPresent(String.self, forKey: .name)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? "live"
        status = try values.decodeIfPresent(CoreStatus.self, forKey: .status)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        turn = try values.decodeIfPresent(UInt64.self, forKey: .turn)
    }
}

struct CoreListResult: Codable, Sendable {
    let terminals: [CoreTerminal]
}

struct CoreSubscribeResult: Codable, Sendable {
    let channel: UInt32?
    let seq: UInt64
    let terminals: [CoreTerminal]
}

struct CoreReadResult: Codable, Sendable {
    let text: String
}

struct CoreAttachResult: Codable, Sendable {
    let channel: UInt32
    let terminal: CoreTerminal
}

/// One notification on an events channel. `type` is nil for a heartbeat, which only carries
/// the current sequence.
struct CoreEvent: Codable, Equatable, Sendable {
    let seq: UInt64?
    let type: String?
    let terminal: String?
}

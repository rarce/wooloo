import Darwin
import Foundation

/// A Herdr JSON socket on a Unix domain socket under /private/tmp. It records every request,
/// answers through `respond`, and keeps `events.subscribe` connections open so tests can send
/// events on them.
final class FakeHerdrServer {
    struct Request {
        let method: String
        let params: [String: Any]
    }

    /// The reply's fields besides `id`, such as `["result": …]` or `["error": …]`; nil closes the
    /// connection without replying.
    typealias Responder = (_ method: String, _ params: [String: Any]) -> [String: Any]?

    let directory: String
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var responder: Responder
    private var recorded: [Request] = []
    private var connections: [Int32] = []
    private var subscribers: [Int32] = []
    private var stopped = false
    private let acceptsSubscriptions: Bool

    init(acceptsSubscriptions: Bool = true, respond: @escaping Responder) throws {
        self.acceptsSubscriptions = acceptsSubscriptions
        directory = "/private/tmp/xherdr-tests/\(UUID().uuidString)"
        path = directory + "/herdr.sock"
        responder = respond
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func setResponder(_ respond: @escaping Responder) {
        lock.lock()
        responder = respond
        lock.unlock()
    }

    /// Writes one JSON line to every event subscription.
    func emit(_ object: [String: Any]) {
        lock.lock()
        let targets = subscribers
        lock.unlock()
        for fd in targets { write(object, to: fd) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = connections
        lock.unlock()
        for fd in open { shutdown(fd, SHUT_RDWR) }
        close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            connections.append(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            guard byte == 0x0A else { buffer.append(byte); continue }
            defer { buffer.removeAll() }
            guard let request = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
                  let method = request["method"] as? String else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            lock.lock()
            recorded.append(Request(method: method, params: params))
            let respond = responder
            lock.unlock()
            if method == "events.subscribe" && acceptsSubscriptions {
                lock.lock()
                subscribers.append(fd)
                lock.unlock()
                write(["id": request["id"] ?? "", "result": ["type": "subscription_started"]], to: fd)
                continue
            }
            guard var reply = respond(method, params) else { return }
            reply["id"] = request["id"]
            write(reply, to: fd)
        }
    }

    private func write(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

/// A `session.snapshot` result with one workspace, one tab and the given panes.
func fakeSnapshot(label: String = "project", paneIDs: [String] = ["w1:p1"]) -> [String: Any] {
    ["result": ["snapshot": [
        "workspaces": [["workspace_id": "w1", "label": label]],
        "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "label": "1"]],
        "panes": paneIDs.map { ["pane_id": $0, "workspace_id": "w1", "tab_id": "w1:t1", "cwd": "/tmp/project"] },
        "agents": [], "layouts": [],
        "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": paneIDs.first ?? NSNull()
    ] as [String: Any]]]
}

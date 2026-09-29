import AppKit
import Darwin
import Foundation

struct HerdrCell: Equatable {
    let symbol: String
    let foreground: UInt32
    let background: UInt32
    let modifier: UInt16
    let skip: Bool
}

struct HerdrCursor: Equatable {
    let x: Int
    let y: Int
    let visible: Bool
    let shape: UInt8
}

struct HerdrSurface: Equatable {
    let bootID: String
    let projectionRevision: UInt64
    var revision: UInt64
    let width: Int
    let height: Int
    var cells: [HerdrCell]
    var cursor: HerdrCursor?
    let paneIDs: [String]
    let paneRects: [String: HerdrRect]
}

private enum SurfaceProtocolError: Error {
    case invalidFrame
    case unexpectedEnd
    case incompatible(String)
}

private struct SurfaceReader {
    let bytes: [UInt8]
    var position = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw SurfaceProtocolError.unexpectedEnd }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func number() throws -> UInt64 {
        let tag = try byte()
        if tag < 251 { return UInt64(tag) }
        let count: Int
        switch tag {
        case 251: count = 2
        case 252: count = 4
        case 253: count = 8
        default: throw SurfaceProtocolError.invalidFrame
        }
        guard position + count <= bytes.count else { throw SurfaceProtocolError.unexpectedEnd }
        var value: UInt64 = 0
        for offset in 0..<count { value |= UInt64(bytes[position + offset]) << (offset * 8) }
        position += count
        return value
    }

    mutating func string() throws -> String {
        let length = try Int(number())
        guard length <= 8_000_000, position + length <= bytes.count else { throw SurfaceProtocolError.invalidFrame }
        defer { position += length }
        guard let value = String(bytes: bytes[position..<(position + length)], encoding: .utf8) else {
            throw SurfaceProtocolError.invalidFrame
        }
        return value
    }

    mutating func count() throws -> Int {
        let value = try number()
        guard value <= 1_000_000 else { throw SurfaceProtocolError.invalidFrame }
        return Int(value)
    }

    mutating func optional<T>(_ read: (inout SurfaceReader) throws -> T) throws -> T? {
        switch try byte() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw SurfaceProtocolError.invalidFrame
        }
    }

    mutating func rect() throws -> HerdrRect {
        HerdrRect(x: try Int(number()), y: try Int(number()),
                  width: try Int(number()), height: try Int(number()))
    }

    mutating func cell() throws -> HerdrCell {
        let symbol = try string()
        let foreground = try UInt32(number())
        let background = try UInt32(number())
        let modifier = try UInt16(number())
        let skip = try byte() != 0
        _ = try optional { reader in try reader.number() } // hyperlink index
        return HerdrCell(symbol: symbol, foreground: foreground, background: background, modifier: modifier, skip: skip)
    }

    mutating func cursor() throws -> HerdrCursor {
        let x = try Int(number())
        let y = try Int(number())
        let visible = try byte() != 0
        let shape = try byte()
        return HerdrCursor(x: x, y: y, visible: visible, shape: shape)
    }

    mutating func pane() throws -> (String, HerdrRect) {
        let paneID = try string()
        _ = try number() // content revision
        let paneRect = try rect()
        _ = try rect()
        _ = try optional { reader in try reader.rect() }
        _ = try optional { reader in
            for _ in 0..<3 { _ = try reader.number() }
        }
        for _ in 0..<4 { _ = try byte() }
        _ = try number()
        _ = try number()
        return (paneID, paneRect)
    }

    mutating func surface() throws -> HerdrSurface {
        let bootID = try string()
        let projectionRevision = try number()
        let revision = try number()
        let cellCount = try count()
        guard cellCount <= 200_000 else { throw SurfaceProtocolError.invalidFrame }
        var cells: [HerdrCell] = []
        cells.reserveCapacity(cellCount)
        for _ in 0..<cellCount { cells.append(try cell()) }
        let width = try Int(number())
        let height = try Int(number())
        guard width > 0, height > 0, width * height == cellCount else { throw SurfaceProtocolError.invalidFrame }
        let cursor = try optional { reader in try reader.cursor() }
        for _ in 0..<(try count()) { _ = try string() } // hyperlinks
        for _ in 0..<(try count()) { _ = try byte() } // legacy graphics bytes
        var paneIDs: [String] = []
        var paneRects: [String: HerdrRect] = [:]
        for _ in 0..<(try count()) {
            let (id, rect) = try pane()
            paneIDs.append(id)
            paneRects[id] = rect
        }
        // Split handles, popups, and graphics follow. The screen cells and pane
        // metadata above are complete independently of those optional layers.
        return HerdrSurface(bootID: bootID, projectionRevision: projectionRevision,
                            revision: revision, width: width, height: height,
                            cells: cells, cursor: cursor, paneIDs: paneIDs, paneRects: paneRects)
    }

    mutating func applyPatch(to surface: inout HerdrSurface) throws {
        let bootID = try string()
        let projectionRevision = try number()
        let baseRevision = try number()
        let revision = try number()
        guard bootID == surface.bootID, projectionRevision == surface.projectionRevision,
              baseRevision == surface.revision else { throw SurfaceProtocolError.invalidFrame }
        for _ in 0..<(try count()) {
            let x = try Int(number())
            let y = try Int(number())
            let length = try count()
            guard x >= 0, y >= 0, y < surface.height, x + length <= surface.width else {
                throw SurfaceProtocolError.invalidFrame
            }
            for offset in 0..<length {
                surface.cells[y * surface.width + x + offset] = try cell()
            }
        }
        for _ in 0..<(try count()) { _ = try pane() }
        surface.cursor = try optional { reader in try reader.cursor() }
        surface.revision = revision
    }
}

private enum SurfaceWriter {
    static func number(_ value: UInt64) -> Data {
        if value < 251 { return Data([UInt8(value)]) }
        if value <= UInt16.max {
            return Data([251, UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
        }
        if value <= UInt32.max {
            var data = Data([252])
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 0xff)) }
            return data
        }
        var data = Data([253])
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> shift) & 0xff)) }
        return data
    }

    static func string(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        return number(UInt64(utf8.count)) + utf8
    }

    static func control(kind: String, data: String) -> Data {
        number(20) + string(kind) + string(data)
    }
}

final class HerdrSurfaceStream {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    private var bootID: String?

    func cancel() {
        lock.lock()
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard cols > 0, rows > 0, cols <= 1000, rows <= 1000 else { return }
        var payload = SurfaceWriter.number(12) // ClientShellResize
        payload += SurfaceWriter.number(UInt64(cellWidth))
        payload += SurfaceWriter.number(UInt64(cellHeight))
        payload += SurfaceWriter.number(UInt64(cols))
        payload += SurfaceWriter.number(UInt64(rows))
        payload.append(0) // pixel mouse
        send(payload)
    }

    func focus(tabID: String) {
        request(method: "tab.focus", params: ["tab_id": tabID])
    }

    func focus(paneID: String) {
        request(method: "pane.focus", params: ["pane_id": paneID])
    }

    func focus(workspaceID: String) {
        request(method: "workspace.focus", params: ["workspace_id": workspaceID])
    }

    private func request(method: String, params: [String: Any]) {
        lock.lock()
        let boot = bootID
        lock.unlock()
        guard let boot,
              let json = try? JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "method": method, "params": params
              ]), let request = String(data: json, encoding: .utf8) else { return }
        send(SurfaceWriter.number(15) + SurfaceWriter.string(boot) + SurfaceWriter.string(request))
    }

    private func send(_ payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0, !cancelled else { return }
        var frame = Data()
        let length = UInt32(payload.count)
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8((length >> shift) & 0xff)) }
        frame += payload
        frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    func run(path: String, cols: Int, rows: Int, cellWidth: Int, cellHeight: Int,
             onSurface: (HerdrSurface) -> Void) throws {
        let connected = try HerdrSocket.open(path: path)
        lock.lock()
        fd = connected
        let wasCancelled = cancelled
        lock.unlock()
        defer {
            lock.lock()
            fd = -1
            bootID = nil
            lock.unlock()
            close(connected)
        }
        if wasCancelled { return }
        let hello: [String: Any] = [
            "generation": 1, "cell_width_px": cellWidth, "cell_height_px": cellHeight,
            "surface_size": ["cols": cols, "rows": rows],
            "pixel_mouse": false, "direct_graphics": false,
            "endpoint_keybindings": false, "mouse_capture": false,
            "surface_active": true, "surface_reuse": false, "surface_delta": false,
            "snapshot_codecs": ["shell.snapshot.v1"],
            "surface_codecs": ["shell.surface.v1"],
            "input_codecs": ["shell.input.semantic.v1"],
            "blob_codecs": ["shell.blob.v1"]
        ]
        let helloData = try JSONSerialization.data(withJSONObject: hello)
        guard let helloString = String(data: helloData, encoding: .utf8) else { throw SurfaceProtocolError.invalidFrame }
        send(SurfaceWriter.control(kind: "endpoint.hello.v1", data: helloString))
        var currentSurface: HerdrSurface?
        var welcomed = false
        while !isCancelled {
            let frame = try readFrame(fd: connected)
            var reader = SurfaceReader(frame)
            let tag = try reader.number()
            switch tag {
            case 20:
                let kind = try reader.string()
                let data = try reader.string()
                if kind == "endpoint.welcome.v1" {
                    guard let json = data.data(using: .utf8),
                          let welcome = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                          (welcome["generation"] as? Int) == 1,
                          welcome["error"] is NSNull || welcome["error"] == nil else {
                        throw SurfaceProtocolError.incompatible("Herdr rejected surface endpoint")
                    }
                    welcomed = true
                } else if kind == "shell.snapshot.v1",
                          let json = data.data(using: .utf8),
                          let snapshot = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                          let boot = snapshot["boot_id"] as? String {
                    lock.lock()
                    bootID = boot
                    lock.unlock()
                }
            case 13 where welcomed:
                let surface = try reader.surface()
                currentSurface = surface
                onSurface(surface)
            case 19 where welcomed:
                if var surface = currentSurface {
                    do {
                        try reader.applyPatch(to: &surface)
                        currentSurface = surface
                        onSurface(surface)
                    } catch {
                        currentSurface = nil // wait for the next complete frame
                    }
                }
            default: break
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func readFrame(fd: Int32) throws -> Data {
        let header = try readExactly(fd: fd, count: 4)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        guard length > 0, length <= 32 * 1024 * 1024 else { throw SurfaceProtocolError.invalidFrame }
        return try readExactly(fd: fd, count: Int(length))
    }

    private func readExactly(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var received = 0
            while received < count {
                let amount = Darwin.read(fd, base.advanced(by: received), count - received)
                if amount <= 0 { throw SurfaceProtocolError.unexpectedEnd }
                received += amount
            }
        }
        return data
    }
}

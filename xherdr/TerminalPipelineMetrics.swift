import AppKit
import Foundation
import notify
import os
import QuartzCore

/// Opt-in measurements of the live terminal pipeline, from a surface frame's arrival on the
/// endpoint socket to the draw that shows it. Set `XHERDR_METRICS_FILE` to a path to record
/// one JSON line per event; `scripts/terminal-perf.py e2e` turns them into a report.
/// Signposts under the `dev.xherdr.terminal` subsystem show the same stages in Instruments
/// whether or not the file is enabled.
///
/// Events: `recv` (frame decoded on the stream thread), `deliver` (surface published on the
/// main thread), `update` (SwiftUI view update, with the grid layout when a revision changed)
/// and `draw` (grid drawn). `commit` marks the main thread's next turn after a draw, by which
/// Core Animation has committed it, and `vsync` records each display refresh the terminal
/// view's display link reports, with the time its frame reaches the screen; together they
/// estimate when a draw became visible. Keystrokes add `key` (the event's own time, so waiting
/// in the main thread's queue counts, and when the view handled it) and `sent` (input written
/// to the socket). The mouse and UI probes add `mouse` (a click, scroll, split drag, selection
/// drag, tab switch or window resize they played, with the event's own time), and `publish`
/// counts the store's change notifications, each of which makes SwiftUI update the window. The workspace side adds `proc` (a git, SSH or shell process that `WorkspaceFiles`
/// ran) and `span` (a user-visible operation such as loading the file list, from its start
/// until its result is on screen). Times are nanoseconds since the first event's `start` line.
final class TerminalPipelineMetrics {
    static let shared: TerminalPipelineMetrics? = {
        guard let path = ProcessInfo.processInfo.environment["XHERDR_METRICS_FILE"], !path.isEmpty else { return nil }
        return TerminalPipelineMetrics(path: path)
    }()

    static let signposter = OSSignposter(subsystem: "dev.xherdr.terminal", category: .pointsOfInterest)

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private enum Event {
        case received(boot: String, projection: UInt64, revision: UInt64, size: (Int, Int), isPatch: Bool,
                      bytes: Int, at: UInt64, decode: UInt64, cursor: HerdrCursor?)
        case key(eventAt: UInt64, at: UInt64, cursor: HerdrCursor?)
        case sent(at: UInt64, bytes: Int)
        case mouse(kind: String, eventAt: UInt64, at: UInt64)
        case published(at: UInt64)
        case process(label: String, remote: Bool, start: UInt64, nanos: UInt64, bytes: Int, status: Int32?)
        case span(name: String, start: UInt64, end: UInt64, detail: String?)
        case delivered(boot: String, projection: UInt64, revision: UInt64, at: UInt64)
        case updated(revision: UInt64?, at: UInt64, duration: UInt64, layout: UInt64?)
        case drawn(boot: String, projection: UInt64, revision: UInt64, at: UInt64, duration: UInt64, surface: HerdrSurface?)
        case committed(at: UInt64)
        case vsync(at: UInt64, target: UInt64)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var digestedRevision: (boot: String, projection: UInt64, revision: UInt64)?
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.xherdr.terminal-metrics", qos: .utility)
    private let timer: DispatchSourceTimer
    private let origin = TerminalPipelineMetrics.now()
    /// Digests let a replayed trace prove each drawn revision matched what Herdr sent.
    private let recordsDigests = ProcessInfo.processInfo.environment["XHERDR_METRICS_DIGESTS"] != "0"

    private init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        timer = DispatchSource.makeTimerSource(queue: queue)
        let start = #"{"e":"start","wall_ms":\#(Int(Date().timeIntervalSince1970 * 1000)),"pid":\#(getpid())}"#
        handle.write(Data((start + "\n").utf8))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync { self?.flush() }
        }
    }

    func received(_ surface: HerdrSurface, isPatch: Bool, bytes: Int, at: UInt64, decodeNanos: UInt64) {
        append(.received(boot: surface.bootID, projection: surface.projectionRevision, revision: surface.revision,
                         size: (surface.width, surface.height), isPatch: isPatch,
                         bytes: bytes, at: at, decode: decodeNanos, cursor: surface.cursor))
    }

    /// A key event reached the terminal view while `cursor` was showing.
    func keyPressed(_ event: NSEvent, cursor: HerdrCursor?) {
        let eventAt = UInt64(max(0, event.timestamp) * 1_000_000_000)
        append(.key(eventAt: eventAt, at: Self.now(), cursor: cursor))
    }

    func inputSent(bytes: Int) {
        append(.sent(at: Self.now(), bytes: bytes))
    }

    /// A probe is about to play a `kind` event, due at `eventAt`.
    func mouseEvent(_ kind: String, eventAt: UInt64) {
        append(.mouse(kind: kind, eventAt: eventAt, at: Self.now()))
    }

    /// `HerdrStore` announced a change: SwiftUI updates every view that observes it.
    func published() {
        append(.published(at: Self.now()))
    }

    func process(label: String, remote: Bool, start: UInt64, nanos: UInt64, bytes: Int, status: Int32?) {
        append(.process(label: label, remote: remote, start: start, nanos: nanos, bytes: bytes, status: status))
    }

    /// Records an operation whose result was just assigned to view state, once SwiftUI has
    /// had the rest of this main-thread turn to show it.
    static func spanShown(_ name: String, start: UInt64, detail: String? = nil) {
        guard let metrics = shared else { return }
        DispatchQueue.main.async { metrics.span(name, start: start, detail: detail) }
    }

    /// Records an operation that started at `start` and has just finished.
    func span(_ name: String, start: UInt64, detail: String? = nil) {
        append(.span(name: name, start: start, end: Self.now(), detail: detail))
    }

    func delivered(_ surface: HerdrSurface) {
        append(.delivered(boot: surface.bootID, projection: surface.projectionRevision, revision: surface.revision, at: Self.now()))
    }

    func updated(revision: UInt64?, start: UInt64, layoutNanos: UInt64?) {
        let end = Self.now()
        append(.updated(revision: revision, at: end, duration: end - start, layout: layoutNanos))
    }

    func drawn(_ surface: HerdrSurface, start: UInt64) {
        let end = Self.now()
        lock.lock()
        // Only the first draw of a revision needs a digest; redraws show the same cells.
        let needsDigest = recordsDigests
            && (digestedRevision?.boot != surface.bootID || digestedRevision?.projection != surface.projectionRevision
                || digestedRevision?.revision != surface.revision)
        if needsDigest { digestedRevision = (surface.bootID, surface.projectionRevision, surface.revision) }
        events.append(.drawn(boot: surface.bootID, projection: surface.projectionRevision, revision: surface.revision, at: end,
                             duration: end - start, surface: needsDigest ? surface : nil))
        lock.unlock()
    }

    /// A draw has just returned; the next main-thread turn comes after Core Animation's commit.
    func drawCommitted() {
        DispatchQueue.main.async { [weak self] in self?.append(.committed(at: Self.now())) }
    }

    /// A display refresh began at `timestamp`; its frame reaches the screen at `target`. Both
    /// use the same uptime clock as `now()`.
    func vsync(timestamp: CFTimeInterval, target: CFTimeInterval) {
        append(.vsync(at: UInt64(timestamp * 1_000_000_000), target: UInt64(target * 1_000_000_000)))
    }

    private func append(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let pending = events
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !pending.isEmpty else { return }
        var output = ""
        for event in pending {
            output += line(for: event)
            output += "\n"
        }
        handle.write(Data(output.utf8))
    }

    private func line(for event: Event) -> String {
        func time(_ value: UInt64) -> UInt64 { value >= origin ? value - origin : 0 }
        func position(_ cursor: HerdrCursor?) -> String {
            cursor.map { #","cx":\#($0.x),"cy":\#($0.y)"# } ?? ""
        }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch event {
        case let .received(boot, projection, revision, size, isPatch, bytes, at, decode, cursor):
            return #"{"e":"recv","boot":\#(quoted(boot)),"proj":\#(projection),"rev":\#(revision),"cols":\#(size.0),"rows":\#(size.1),"patch":\#(isPatch),"bytes":\#(bytes),"t":\#(time(at)),"decode":\#(decode)\#(position(cursor))}"#
        case let .key(eventAt, at, cursor):
            return #"{"e":"key","t_event":\#(time(eventAt)),"t":\#(time(at))\#(position(cursor))}"#
        case let .sent(at, bytes):
            return #"{"e":"sent","t":\#(time(at)),"bytes":\#(bytes)}"#
        case let .mouse(kind, eventAt, at):
            return #"{"e":"mouse","kind":\#(quoted(kind)),"t_event":\#(time(eventAt)),"t":\#(time(at))}"#
        case let .published(at):
            return #"{"e":"publish","t":\#(time(at))}"#
        case let .process(label, remote, start, nanos, bytes, status):
            return #"{"e":"proc","label":\#(quoted(label)),"remote":\#(remote),"t":\#(time(start)),"dur":\#(nanos),"bytes":\#(bytes),"ok":\#(status == 0),"status":\#(status.map(String.init) ?? "null")}"#
        case let .span(name, start, end, detail):
            let extra = detail.map { #","detail":\#(quoted($0))"# } ?? ""
            return #"{"e":"span","name":\#(quoted(name)),"t":\#(time(start)),"dur":\#(end - start)\#(extra)}"#
        case let .delivered(boot, projection, revision, at):
            return #"{"e":"deliver","boot":\#(quoted(boot)),"proj":\#(projection),"rev":\#(revision),"t":\#(time(at))}"#
        case let .updated(revision, at, duration, layout):
            return #"{"e":"update","rev":\#(revision.map(String.init) ?? "null"),"t":\#(time(at)),"dur":\#(duration),"layout":\#(layout.map(String.init) ?? "null")}"#
        case let .committed(at):
            return #"{"e":"commit","t":\#(time(at))}"#
        case let .vsync(at, target):
            return #"{"e":"vsync","t":\#(time(at)),"target":\#(time(target))}"#
        case let .drawn(boot, projection, revision, at, duration, surface):
            let digest = surface.map { #","digest":"\#(String($0.contentDigest, radix: 16))""# } ?? ""
            return #"{"e":"draw","boot":\#(quoted(boot)),"proj":\#(projection),"rev":\#(revision),"t":\#(time(at)),"dur":\#(duration)\#(digest)}"#
        }
    }
}

/// Records the display refreshes of the screen a view is on, for `TerminalPipelineMetrics`.
/// The display link retains its target, so this object holds no view.
final class TerminalVsyncRecorder: NSObject {
    private var link: CADisplayLink?

    /// Follows `view`'s screen while metrics are on; nil stops recording.
    @MainActor
    func follow(_ view: NSView?) {
        link?.invalidate()
        link = nil
        guard TerminalPipelineMetrics.shared != nil, let view, view.window != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func refresh(_ link: CADisplayLink) {
        TerminalPipelineMetrics.shared?.vsync(timestamp: link.timestamp, target: link.targetTimestamp)
    }
}

/// Records every surface and patch frame read from the endpoint socket, so a live session can
/// be replayed offline against a reference decoder. Enabled by `XHERDR_SURFACE_TRACE=<path>`.
///
/// Format: the 8 bytes `XHTRACE1`, then per frame a little-endian UInt64 uptime in nanoseconds,
/// a little-endian UInt32 payload length and the payload without its socket length prefix.
final class TerminalSurfaceTraceRecorder {
    static let magic = Data("XHTRACE1".utf8)

    static let shared: TerminalSurfaceTraceRecorder? = {
        guard let path = ProcessInfo.processInfo.environment["XHERDR_SURFACE_TRACE"], !path.isEmpty,
              FileManager.default.createFile(atPath: path, contents: magic, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return TerminalSurfaceTraceRecorder(handle: handle)
    }()

    private let handle: FileHandle
    private let lock = NSLock()

    private init(handle: FileHandle) { self.handle = handle }

    func record(_ frame: Data, at time: UInt64) {
        var header = Data(capacity: 12)
        for shift in stride(from: 0, to: 64, by: 8) { header.append(UInt8((time >> UInt64(shift)) & 0xff)) }
        let length = UInt32(frame.count)
        for shift in stride(from: 0, to: 32, by: 8) { header.append(UInt8((length >> UInt32(shift)) & 0xff)) }
        lock.lock()
        handle.write(header + frame)
        lock.unlock()
    }

    /// Reads a trace written by the recorder.
    static func frames(in data: Data) throws -> [(time: UInt64, payload: Data)] {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count, Data(bytes[0..<magic.count]) == magic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var frames: [(UInt64, Data)] = []
        var position = magic.count
        while position < bytes.count {
            guard position + 12 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            var time: UInt64 = 0
            for offset in 0..<8 { time |= UInt64(bytes[position + offset]) << UInt64(offset * 8) }
            var length = 0
            for offset in 0..<4 { length |= Int(bytes[position + 8 + offset]) << (offset * 8) }
            position += 12
            guard position + length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            frames.append((time, Data(bytes[position..<(position + length)])))
            position += length
        }
        return frames
    }
}

extension HerdrSurface {
    /// A 64-bit FNV-1a hash of everything a pane shows: size, cells, cursor and graphics
    /// placements. Equal digests mean two pipelines produced the same screen.
    var contentDigest: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mixByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        func mix(_ value: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) { mixByte(UInt8((value >> UInt64(shift)) & 0xff)) }
        }
        mix(UInt64(width))
        mix(UInt64(height))
        for cell in cells {
            for byte in cell.symbol.utf8 { mixByte(byte) }
            mixByte(0xff)
            mix(UInt64(cell.foreground) << 32 | UInt64(cell.background))
            mix(UInt64(cell.modifier) << 1 | (cell.skip ? 1 : 0))
        }
        if let cursor {
            mix(UInt64(cursor.x))
            mix(UInt64(cursor.y))
            mix(UInt64(cursor.shape) << 1 | (cursor.visible ? 1 : 0))
        } else {
            mix(UInt64.max)
        }
        for graphic in graphics {
            for byte in graphic.key.identity { mixByte(byte) }
            mix(UInt64(graphic.x) << 32 | UInt64(graphic.y))
            mix(UInt64(graphic.cols) << 32 | UInt64(graphic.rows))
            mix(UInt64(bitPattern: Int64(graphic.z)))
        }
        if let popup {
            mixByte(0xfe)
            for byte in (popup.terminalID + "\0" + popup.title).utf8 { mixByte(byte) }
            for size in [popup.width, popup.height] {
                switch size {
                case .cells(let value): mix(0); mix(UInt64(value))
                case .percent(let value): mix(1); mix(UInt64(value))
                case nil: mix(UInt64.max)
                }
            }
            let frame = HerdrSurface(bootID: bootID, projectionRevision: projectionRevision, revision: revision,
                                     width: popup.cols, height: popup.rows, cells: popup.cells, cursor: popup.cursor,
                                     paneIDs: [], paneRects: [:], paneInnerRects: [:], mouseReportingPaneIDs: [], splits: [], graphics: [])
            mix(frame.contentDigest)
            for link in popup.hyperlinks { for byte in link.utf8 { mixByte(byte) }; mixByte(0xff) }
            mix(popup.mouseReporting ? 1 : 0)
        }
        return hash
    }
}

/// Types into the live terminal view on request, through the same `keyDown` path as the
/// keyboard, so `scripts/terminal-e2e.sh` can measure keystroke-to-screen latency without
/// accessibility access. Enabled with the metrics file and `XHERDR_TYPING_PROBE=1`; each
/// `notifyutil -p dev.xherdr.typing-probe` types `XHERDR_TYPING_PROBE_KEYS` letters (100),
/// one every `XHERDR_TYPING_PROBE_INTERVAL_MS` (100). The same flag enables the mouse probe:
/// `dev.xherdr.mouse-probe.click`, `.scroll` and `.drag` play clicks in a pane without mouse
/// reporting, wheel events over one with it, and a drag of the first split, through the
/// view's own mouse handlers; `.select` drags a text selection across a pane. The UI probe's
/// `dev.xherdr.ui-probe.tabs` switches between the selected Space's first two tabs as the tab
/// row does, and `.resize` changes the window's content size back and forth. Any local process
/// can post these notifications, so the probes are compiled only with the `XHERDR_PROBES`
/// condition, which the script sets. `XHERDR_WINDOW_SIZE` (for example `1400x900`) fixes the
/// window's content size, in every build.
@MainActor
enum TerminalTypingProbe {
    /// The terminal view showing the live surface.
    static weak var target: HerdrTerminalTextView?
    /// The store, for probes that act on Herdr's tabs.
    static weak var store: HerdrStore?
    private static var token: Int32 = 0

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        if let size = environment["XHERDR_WINDOW_SIZE"] { resizeWindow(to: size, attempts: 50) }
        #if XHERDR_PROBES
        guard TerminalPipelineMetrics.shared != nil, environment["XHERDR_TYPING_PROBE"] == "1", token == 0 else { return }

        let keys = Int(environment["XHERDR_TYPING_PROBE_KEYS"] ?? "") ?? 100
        let interval = Double(environment["XHERDR_TYPING_PROBE_INTERVAL_MS"] ?? "") ?? 100
        notify_register_dispatch("dev.xherdr.typing-probe", &token, .main) { _ in
            MainActor.assumeIsolated { type(keys, every: interval / 1000) }
        }
        for kind in ["click", "scroll", "drag", "select"] {
            var mouseToken: Int32 = 0
            notify_register_dispatch("dev.xherdr.mouse-probe.\(kind)", &mouseToken, .main) { _ in
                MainActor.assumeIsolated { playMouse(kind) }
            }
        }
        for kind in ["tabs", "resize"] {
            var uiToken: Int32 = 0
            notify_register_dispatch("dev.xherdr.ui-probe.\(kind)", &uiToken, .main) { _ in
                MainActor.assumeIsolated { playUI(kind) }
            }
        }
        #endif
    }

    private static var timer: DispatchSourceTimer?

    /// Gives the first window a fixed content size such as `1400x900`, so runs compare the
    /// same grid whatever size the developer's own xherdr window was saved at.
    private static func resizeWindow(to size: String, attempts: Int) {
        let parts = size.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                    resizeWindow(to: size, attempts: attempts - 1)
                    return
                }
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
            }
        }
    }

    /// Runs `step` `count` times, one every `interval`, on the main thread with the time each
    /// was due. A strict timer on its own queue keeps the steps apart; each then waits for the
    /// main thread like a hardware event.
    private static func play(_ count: Int, every interval: TimeInterval,
                             _ step: @escaping @MainActor (Int, TimeInterval) -> Void) {
        var index = 0
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue.global(qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        source.setEventHandler {
            let current = index
            let timestamp = ProcessInfo.processInfo.systemUptime
            index += 1
            if index >= count { source.cancel() }
            DispatchQueue.main.async { MainActor.assumeIsolated { step(current, timestamp) } }
        }
        timer?.cancel()
        timer = source
        source.resume()
    }

    /// Plays one mouse workload against the live view. Clicks go to a pane without mouse
    /// reporting, after one unrecorded click that selects it, so the recorded ones click the
    /// pane already selected. Wheel events go to a pane with mouse reporting. The drag moves
    /// the first split 6 columns or rows each way and back.
    private static func playMouse(_ kind: String) {
        guard let view = target, let surface = view.surface, let window = view.window else {
            NSLog("xherdr mouse probe: no live terminal view")
            return
        }
        /// The window point at the middle of a cell.
        func point(column: Int, row: Int) -> NSPoint {
            view.convert(NSPoint(x: view.textContainerInset.width + (CGFloat(column) + 0.5) * TerminalPaneView.cellWidth,
                                 y: view.textContainerInset.height + (CGFloat(row) + 0.5) * TerminalPaneView.cellHeight),
                         to: nil)
        }
        func center(_ rect: HerdrRect) -> NSPoint {
            point(column: Int(rect.x) + Int(rect.width) / 2, row: Int(rect.y) + Int(rect.height) / 2)
        }
        func mouse(_ type: NSEvent.EventType, at location: NSPoint, timestamp: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: timestamp,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func record(_ kind: String, _ timestamp: TimeInterval) {
            TerminalPipelineMetrics.shared?.mouseEvent(kind, eventAt: UInt64(timestamp * 1_000_000_000))
        }
        switch kind {
        case "click":
            guard let pane = surface.paneIDs.first(where: { !surface.mouseReportingPaneIDs.contains($0) }),
                  let rect = surface.paneInnerRects[pane] else { return NSLog("xherdr mouse probe: no pane to click") }
            let location = center(rect)
            play(41, every: 0.1) { index, timestamp in
                guard let down = mouse(.leftMouseDown, at: location, timestamp: timestamp),
                      let up = mouse(.leftMouseUp, at: location, timestamp: timestamp) else { return }
                if index > 0 { record("click", timestamp) }
                view.mouseDown(with: down)
                view.mouseUp(with: up)
            }
        case "scroll":
            guard let pane = surface.paneIDs.first(where: { surface.mouseReportingPaneIDs.contains($0) }),
                  let rect = surface.paneInnerRects[pane] else { return NSLog("xherdr mouse probe: no mouse-aware pane") }
            let location = center(rect)
            play(40, every: 0.1) { index, timestamp in
                record("scroll", timestamp)
                // Three lines, as a wheel notch scrolls, alternately up and down.
                _ = view.scrollPane(at: location, deltaX: 0, deltaY: index % 2 == 0 ? 3 : -3, precise: false, modifiers: [])
            }
        case "select":
            guard let pane = surface.paneIDs.first(where: { !surface.mouseReportingPaneIDs.contains($0) }),
                  let rect = surface.paneInnerRects[pane], rect.width > 4, rect.height > 4
            else { return NSLog("xherdr mouse probe: no pane to select in") }
            let steps = 101
            // From the top left, the head sweeps down and back across most of the pane.
            play(steps + 1, every: 0.04) { index, timestamp in
                let phase = Double(index % 50) / 49
                let sweep = index % 100 < 50 ? phase : 1 - phase
                let location = point(column: rect.x + 1 + Int(sweep * Double(rect.width - 3)),
                                     row: rect.y + 1 + Int(sweep * Double(rect.height - 3)))
                switch index {
                case 0:
                    if let down = mouse(.leftMouseDown, at: point(column: rect.x + 1, row: rect.y + 1), timestamp: timestamp) {
                        view.mouseDown(with: down)
                    }
                case steps:
                    if let up = mouse(.leftMouseUp, at: location, timestamp: timestamp) { view.mouseUp(with: up) }
                    view.clearTerminalSelection()
                default:
                    record("select", timestamp)
                    if let drag = mouse(.leftMouseDragged, at: location, timestamp: timestamp) { view.mouseDragged(with: drag) }
                }
            }
        case "drag":
            guard let split = surface.splits.first else { return NSLog("xherdr mouse probe: no split to drag") }
            let horizontal = split.direction == .horizontal
            let middle = center(split.hitRect)
            let steps = 49
            // Down, 6 cells one way, 12 back, 6 again, up: 48 moves after the press.
            let offsets = (0..<steps).map { index -> Int in
                let phase = index % 24
                let wave = phase <= 6 ? phase : phase <= 18 ? 12 - phase : phase - 24
                return index == 0 ? 0 : wave
            }
            play(steps + 1, every: 0.04) { index, timestamp in
                let offset = CGFloat(offsets[min(index, steps - 1)])
                let location = NSPoint(x: middle.x + (horizontal ? offset * TerminalPaneView.cellWidth : 0),
                                       y: middle.y - (horizontal ? 0 : offset * TerminalPaneView.cellHeight))
                switch index {
                case 0: if let down = mouse(.leftMouseDown, at: location, timestamp: timestamp) { view.mouseDown(with: down) }
                case steps: if let up = mouse(.leftMouseUp, at: location, timestamp: timestamp) { view.mouseUp(with: up) }
                default:
                    record("drag", timestamp)
                    if let drag = mouse(.leftMouseDragged, at: location, timestamp: timestamp) { view.mouseDragged(with: drag) }
                }
            }
        default:
            break
        }
    }

    /// Plays a window-level workload: 20 switches between the selected Space's first two tabs,
    /// or 16 content-size changes alternating between the current size and one 240×160 points
    /// smaller, each making Herdr send a complete surface of the new grid.
    private static func playUI(_ kind: String) {
        func record(_ timestamp: TimeInterval) {
            TerminalPipelineMetrics.shared?.mouseEvent(kind, eventAt: UInt64(timestamp * 1_000_000_000))
        }
        switch kind {
        case "tabs":
            guard let store, let workspace = store.selectedWorkspaceID,
                  let tabs = store.snapshot?.tabs.filter({ $0.workspaceID == workspace }).map(\.tabID),
                  tabs.count >= 2, let current = store.selectedTabID
            else { return NSLog("xherdr UI probe: the selected Space has fewer than two tabs") }
            let other = current == tabs[0] ? tabs[1] : tabs[0]
            play(20, every: 0.3) { index, timestamp in
                record(timestamp)
                store.select(tabID: index % 2 == 0 ? other : current)
            }
        case "resize":
            guard let window = target?.window, let content = window.contentView else {
                return NSLog("xherdr UI probe: no window to resize")
            }
            let large = content.frame.size
            let small = NSSize(width: large.width - 240, height: large.height - 160)
            play(16, every: 0.4) { index, timestamp in
                record(timestamp)
                window.setContentSize(index % 2 == 0 ? small : large)
            }
        default:
            break
        }
    }

    private static func type(_ count: Int, every interval: TimeInterval) {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var typed = 0
        // A strict timer on its own queue keeps keys apart; the event then waits for the main
        // thread like a hardware event.
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue.global(qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        source.setEventHandler {
            let character = String(letters[typed % letters.count])
            let timestamp = ProcessInfo.processInfo.systemUptime
            typed += 1
            if typed >= count { source.cancel() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let view = target,
                          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: timestamp,
                                                       windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                                       characters: character, charactersIgnoringModifiers: character,
                                                       isARepeat: false, keyCode: 0) else { return }
                    view.keyDown(with: event)
                }
            }
        }
        timer?.cancel()
        timer = source
        source.resume()
    }
}

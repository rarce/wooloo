import Foundation

/// The live presentation of the selected tab: terminal surfaces come in, and input, resizes,
/// focus and split ratios go out. `HerdrStore` holds one while the window shows terminals;
/// the Herdr TUI's binary client endpoint (`HerdrSurfaceStream`) is today's only kind, and a
/// herdr-core connection will provide another (docs/proposals/herdr-core-backend.md, §4).
/// Every method returns at once: implementations queue their writes off the main thread.
protocol TerminalSurfaceConnection: AnyObject, Sendable {
    /// Connected, and able to send.
    var isReady: Bool { get }
    func cancel()
    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    /// The window's colours and focus, which programs read through terminal queries.
    func updateHost(theme: WoolooTheme, focused: Bool)
    func focus(tabID: String)
    @discardableResult func focus(paneID: String) -> Bool
    func focus(workspaceID: String)
    @discardableResult func setSplitRatio(tabID: String, path: [Bool], ratio: Double) -> Bool
    /// Sends typed text, a paste, a key or a mouse event to a pane; false when it could not.
    func sendInput(_ event: HerdrInputEvent, to paneID: String) -> Bool
    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool
    func closePopup() -> Bool
    /// Finds text in a pane's terminal, scrollback included, and shows the next match, older or
    /// newer; nil when nothing matches or the presentation cannot search (the TUI's). It can
    /// search a long scrollback, so it blocks its thread.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    func find(_ query: String, in paneID: String, older: Bool) -> TerminalFindResult?
    /// Ends a search and removes its highlight.
    func endFind()
}

/// Where a terminal search stands: the shown match's place among all of them, 1 the newest.
struct TerminalFindResult: Equatable, Sendable {
    let index: Int
    let total: Int
}

extension TerminalSurfaceConnection {
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    func find(_ query: String, in paneID: String, older: Bool) -> TerminalFindResult? { nil }
    func endFind() {}
}

extension HerdrSurfaceStream: TerminalSurfaceConnection {}

/// A surface connection that can be run: it connects, reports readiness, and delivers surfaces,
/// agent projections and clipboard writes until the connection ends. `run` blocks; `HerdrStore`
/// calls it on a thread of its own.
protocol TerminalPresentation: TerminalSurfaceConnection {
    func run(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int,
             onReady: () -> Void, onSurface: (HerdrSurface) -> Void,
             onAgents: ((HerdrAgentProjection) -> Void)?,
             onClipboard: ((String) -> Void)?) throws
}

/// Makes the live presentation for a connection; one per attempt, since a connection that
/// ended is not reused.
protocol TerminalPresentationProvider: Sendable {
    func makePresentation(timeouts: HerdrEndpointTimeouts) -> any TerminalPresentation
}

extension TUISessionBackend: TerminalPresentationProvider {
    func makePresentation(timeouts: HerdrEndpointTimeouts) -> any TerminalPresentation {
        TUITerminalPresentation(stream: HerdrSurfaceStream(timeouts: timeouts), path: surfacePath)
    }
}

/// The Herdr TUI's binary client endpoint (`herdr-client.sock`) at a known path.
final class TUITerminalPresentation: TerminalPresentation, @unchecked Sendable {
    private let stream: HerdrSurfaceStream
    private let path: String

    init(stream: HerdrSurfaceStream, path: String) {
        self.stream = stream
        self.path = path
    }

    func run(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int,
             onReady: () -> Void, onSurface: (HerdrSurface) -> Void,
             onAgents: ((HerdrAgentProjection) -> Void)?,
             onClipboard: ((String) -> Void)?) throws {
        try stream.run(path: path, cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight,
                       onReady: onReady, onSurface: onSurface, onAgents: onAgents, onClipboard: onClipboard)
    }

    var isReady: Bool { stream.isReady }
    func cancel() { stream.cancel() }
    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        stream.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
    }
    func updateHost(theme: WoolooTheme, focused: Bool) { stream.updateHost(theme: theme, focused: focused) }
    func focus(tabID: String) { stream.focus(tabID: tabID) }
    @discardableResult func focus(paneID: String) -> Bool { stream.focus(paneID: paneID) }
    func focus(workspaceID: String) { stream.focus(workspaceID: workspaceID) }
    @discardableResult func setSplitRatio(tabID: String, path: [Bool], ratio: Double) -> Bool {
        stream.setSplitRatio(tabID: tabID, path: path, ratio: ratio)
    }
    func sendInput(_ event: HerdrInputEvent, to paneID: String) -> Bool { stream.sendInput(event, to: paneID) }
    func sendPopupInput(_ event: HerdrInputEvent, terminalID: String) -> Bool {
        stream.sendPopupInput(event, terminalID: terminalID)
    }
    func closePopup() -> Bool { stream.closePopup() }
}

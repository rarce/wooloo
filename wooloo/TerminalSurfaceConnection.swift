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
}

extension HerdrSurfaceStream: TerminalSurfaceConnection {}

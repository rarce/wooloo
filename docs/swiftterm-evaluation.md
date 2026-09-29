# SwiftTerm evaluation

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) is useful when a client receives raw VT/PTY output bytes. Its macOS `TerminalView` is an embeddable AppKit control; the host provides output to `feed` and implements `TerminalViewDelegate` to forward input and size changes. It already handles ANSI colors, Unicode, selection, hyperlinks, and terminal graphics. A thin `NSViewRepresentable` could place it inside the existing SwiftUI pane layout.

Do not use `LocalProcessTerminalView`: Herdr already owns each pane's process and PTY. Starting a local process in xherdr would create a second terminal rather than attach to the existing one.

The `pane.read` response is a complete visible screen snapshot, not an incremental PTY byte stream. Herdr 0.9.1's generation-1 client endpoint sends rendered `FrameData` cells and incremental `PaneSurfacePatch` changes, with colors and cursor state. xherdr now renders those cells directly in an AppKit view. Feeding this data to SwiftTerm would require inventing VT output and a second terminal state, so it would add complexity without improving fidelity.

If a future supported Herdr transport provides raw VT bytes, SwiftTerm can be integrated with a narrow adapter:

1. Wrap `TerminalView` in `NSViewRepresentable`, one view per Herdr pane.
2. Feed incremental screen/output bytes into that view on its expected queue.
3. Forward `TerminalViewDelegate.send` and `sizeChanged` through the Herdr client transport.
4. Let Herdr remain the owner of process, pane layout, and session lifecycle.

Herdr's [protocol stability documentation](https://herdr.dev/docs/socket-api/#protocol-stability) distinguishes its client-rendered endpoint from the numbered internal terminal attach protocol. The current endpoint supports a small native cell renderer and does not need a SwiftTerm package dependency.

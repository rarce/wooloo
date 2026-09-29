# SwiftTerm evaluation

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) is useful when a client receives raw VT/PTY output bytes. Its macOS `TerminalView` is an embeddable AppKit control; the host provides output to `feed` and implements `TerminalViewDelegate` to forward input and size changes. It already handles ANSI colors, Unicode, selection, hyperlinks, and terminal graphics. A thin `NSViewRepresentable` could place it inside the existing SwiftUI pane layout.

Do not use `LocalProcessTerminalView`: Herdr already owns each pane's process and PTY. Starting a local process in xherdr would create a second terminal rather than attach to the existing one.

The current `pane.read` response is a complete visible screen snapshot, including an optional ANSI-styled text representation. It is not an incremental PTY byte stream. Clearing and re-feeding a SwiftTerm view on every read would duplicate terminal state, reset selection and scrollback, and make resize behavior ambiguous. Herdr's documented client endpoint negotiates a *screen codec*, so the future stream may also contain rendered screen state rather than raw VT output. If so, a small screen renderer is a better fit than SwiftTerm. This is an inference from the published protocol description; the exact endpoint payload still needs inspection.

If a supported Herdr transport provides raw VT bytes, SwiftTerm can be integrated with a narrow adapter:

1. Wrap `TerminalView` in `NSViewRepresentable`, one view per Herdr pane.
2. Feed incremental screen/output bytes into that view on its expected queue.
3. Forward `TerminalViewDelegate.send` and `sizeChanged` through the Herdr client transport.
4. Let Herdr remain the owner of process, pane layout, and session lifecycle.

Herdr's [protocol stability documentation](https://herdr.dev/docs/socket-api/#protocol-stability) distinguishes its client-rendered endpoint from the numbered internal terminal attach protocol. Inspect the endpoint payload before adding SwiftTerm as a package dependency. This keeps the current app small and avoids building a second terminal model around `pane.read`.

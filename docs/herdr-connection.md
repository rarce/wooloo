# Herdr server connection plan

## Scope

xherdr connects to the named test session `xherdr-ui-test` through Herdr's JSON and client sockets. It subscribes to lifecycle events, takes `session.snapshot` after subscription and after structural changes, and maps server IDs into the sidebar and tabs. A generation-1 client endpoint streams the selected tab's terminal cells and carries semantic pane input; `pane.read` and JSON `pane.send_input` are fallbacks while the endpoint is unavailable. The sidebar session picker can switch to another named session, while `default` is rejected. Herdr's server owns the processes and terminal state; xherdr is a client. See [Herdr concepts](https://herdr.dev/docs/concepts/).

## Local socket and control API

Herdr's [Socket API](https://herdr.dev/docs/socket-api/) uses newline-delimited JSON over a Unix domain socket on macOS. The default path is `~/.config/herdr/herdr.sock`; a named session uses `~/.config/herdr/sessions/<name>/herdr.sock`. This build constructs only the named-session path. It does not use CLI environment overrides or the default socket. A socket file alone does not prove the server is healthy: xherdr checks the connection by subscribing and requesting a snapshot.

```json
{"id":"health-1","method":"ping","params":{}}
```

Use the installed binary's `herdr api schema --json` as the method and payload contract. On this machine, Herdr 0.9.1 reports JSON schema version 1 and terminal protocol 22; those numbers are observations, not hardcoded compatibility requirements.

## State synchronization

The client opens a persistent `events.subscribe` socket for workspace, tab, pane, and layout lifecycle changes, plus agent status changes for known panes. It waits for the subscription acknowledgement, then requests `session.snapshot` over another socket. Any events arriving during that request stay queued on the subscription socket and each triggers a fresh snapshot. If the pane set changes, the stream is reopened so status subscriptions cover the new panes. This follows the bootstrap ordering in the [Socket API documentation](https://herdr.dev/docs/socket-api/).

The selected tab uses the binary client endpoint at `herdr-client.sock`. xherdr negotiates endpoint generation 1 and verifies the selected snapshot, surface, input, and blob codecs. It opts out of optional retained and delta encodings, decodes complete surfaces and incremental cell patches, and sends viewport resize and focus requests. The surface's colors, cursor, and cell grid render in an AppKit text view. When no matching surface is available, visible pane text is refreshed with `pane.read`. On socket failure or an invalid surface patch, the UI drops the stale surface and reconnects with the latest viewport size, then restores workspace, tab, and pane focus. The sidebar uses the server's `blocked`, `working`, `done`, `idle`, and `unknown` values.

This was validated against `xherdr-ui-test` by creating a workspace, tabs, and a split pane; sending `printf xherdr_socket_ok` from the app; and reporting then clearing a test agent status. The UI updated from `working` to `blocked` and removed the agent after the authority was cleared.

## Terminal surface

An AppKit text view captures keyboard input and paste without editing the displayed screen. A serialized queue sends `TextCommit`, `Paste`, and semantic `Key` events to the selected pane through the client endpoint. When that endpoint is unavailable, the queue uses JSON `pane.send_input`. The shell was checked with typed commands, Enter, Backspace, paste, and Ctrl+C in `xherdr-ui-test`. The live endpoint was also checked with colored shell output, a split tab with input directed to its right pane, and a full-screen Codex pane.

The pane surface supplies its inner rectangle and `mouse_reporting` flag. When mouse reporting is active, clicks, releases, drags, and wheel events go to that pane as cell-relative semantic mouse events; Shift-click keeps native text selection available. The input remains local to `herdr-client.sock` and is skipped while the endpoint is unavailable because JSON `pane.send_input` has no mouse field. A test program in `xherdr-ui-test` enabled DEC mouse mode and received SGR press, release, and wheel sequences.

The surface also supplies split handle areas, hit rectangles, and paths. Dragging a handle sends `layout.set_split_ratio` over the endpoint, capped at about 30 updates per second with a final update on release. The server owns the layout; xherdr redraws from the next surface. In `xherdr-ui-test`, dragging both split orientations changed the ratios reported by `session.snapshot`. See [Protocol stability](https://herdr.dev/docs/socket-api/#protocol-stability) and [Reading panes](https://herdr.dev/docs/socket-api/#reading-panes).

Complete surfaces also carry native graphics assets and placements. xherdr decodes PNG, RGB, and RGBA bytes, caches assets by the protocol key while the server retains them, and draws pane placements in z order with source cropping. Graphics survive incremental cell patches because patches update only text and cursor state. Popup graphics are parsed but are not displayed until popup layers are implemented. A four-color PNG sent with `pane.graphics.set` to pane `w1:p6` in `xherdr-ui-test` appeared in the live surface.

The live renderer records UTF-16 offsets at cell boundaries. Before replacing the attributed text for a new surface, it maps the selected range to cells, then restores the range in the new render. Copy uses a snapshot of the selected text so subsequent screen updates do not change clipboard content, and trims terminal row padding. In `xherdr-ui-test`, selection remained active through about 200 updates from another pane, and Command-C/Command-V reproduced the selected text.

The suitability and integration boundary for [SwiftTerm](swiftterm-evaluation.md) are documented separately.

The surface decoder follows the frozen generation-1 field order in Herdr 0.9.1. It should be checked against a new release's frozen fixtures before changing the parser. Unsupported optional messages are ignored without dropping the JSON connection.

## Implementation order

1. Render popup layers and their graphics.
2. Add hyperlink actions.
3. Add optional remote sessions after local behavior is stable.

Validate against a running Herdr server with `herdr status`, `herdr api schema --json`, and `herdr api snapshot`. These commands should be used as local diagnostics; no server state needs to be changed for the initial connection.

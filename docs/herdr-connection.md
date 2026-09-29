# Herdr server connection plan

## Scope

xherdr now connects to the named test session `xherdr-ui-test` via its Unix socket. It subscribes to lifecycle events, takes `session.snapshot` after subscription and after structural changes, polls `pane.read` for visible text, maps server IDs into the sidebar, tabs, and pane layout, and sends complete input lines through `pane.send_input`. The toolbar can switch to another named session, while `default` is rejected. Herdr's server owns the processes and terminal state; xherdr is a client. See [Herdr concepts](https://herdr.dev/docs/concepts/).

## Local socket and control API

Herdr's [Socket API](https://herdr.dev/docs/socket-api/) uses newline-delimited JSON over a Unix domain socket on macOS. The default path is `~/.config/herdr/herdr.sock`; a named session uses `~/.config/herdr/sessions/<name>/herdr.sock`. This build constructs only the named-session path. It does not use CLI environment overrides or the default socket. A socket file alone does not prove the server is healthy: xherdr checks the connection by subscribing and requesting a snapshot.

```json
{"id":"health-1","method":"ping","params":{}}
```

Use the installed binary's `herdr api schema --json` as the method and payload contract. On this machine, Herdr 0.9.1 reports JSON schema version 1 and terminal protocol 22; those numbers are observations, not hardcoded compatibility requirements.

## State synchronization

The client opens a persistent `events.subscribe` socket for workspace, tab, pane, and layout lifecycle changes, plus agent status changes for known panes. It waits for the subscription acknowledgement, then requests `session.snapshot` over another socket. Any events arriving during that request stay queued on the subscription socket and each triggers a fresh snapshot. If the pane set changes, the stream is reopened so status subscriptions cover the new panes. This follows the bootstrap ordering in the [Socket API documentation](https://herdr.dev/docs/socket-api/).

Visible pane text is still refreshed with `pane.read` once per second because lifecycle events do not stream arbitrary terminal output. On socket failure, the UI shows a disconnected state and retries the named session. The client's current selection remains independent of another Herdr client's focus. The sidebar uses the server's `blocked`, `working`, `done`, `idle`, and `unknown` values.

This was validated against `xherdr-ui-test` by creating a workspace, tabs, and a split pane; sending `printf xherdr_socket_ok` from the app; and reporting then clearing a test agent status. The UI updated from `working` to `blocked` and removed the agent after the authority was cleared.

## Terminal surface

`pane.read` shows visible text, and `pane.send_input` sends a complete line. Periodic reads are insufficient for a faithful interactive terminal: cursor movement, colors, resizing, alternate screen applications, graphics, and key-by-key input need the client terminal surface. Herdr documents a stable endpoint generation that negotiates snapshot, screen, input, and blob codecs, while a numbered binary protocol remains for same-install operations. The native client should implement the negotiated endpoint for full terminal interaction. See [Protocol stability](https://herdr.dev/docs/socket-api/#protocol-stability) and [Reading panes](https://herdr.dev/docs/socket-api/#reading-panes).

The suitability and integration boundary for [SwiftTerm](swiftterm-evaluation.md) are documented separately.

Once a live surface is available, render each pane in a terminal view, forward keyboard and mouse input to the selected pane, report pane size on layout changes, and make split dividers update Herdr's layout. Keep preview text visibly labeled until the real surface replaces it.

## Implementation order

1. Implement the negotiated terminal surface and full keyboard input.
2. Add terminal resizing, scrolling, and pane layout controls.
3. Add capability negotiation and optional remote sessions after local behavior is stable.

Validate against a running Herdr server with `herdr status`, `herdr api schema --json`, and `herdr api snapshot`. These commands should be used as local diagnostics; no server state needs to be changed for the initial connection.

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

Agent rows use the snapshot's workspace and tab IDs to show location, plus `display_agent`, `name`, `agent`, or `title` for the label. They use `state_labels` when present and show a `summary` token, title, or stripped terminal title as secondary detail. The default two-line structure follows Herdr's [Agent sidebar rows](https://herdr.dev/docs/config-reference/); xherdr adds the secondary detail when available. These fields are refreshed through the existing snapshot event stream.

## Agent views

xherdr follows the server's declarative agent view when the client endpoint advertises `agent_view_projection`. The endpoint sends `endpoint.agent-view.v1` alongside `shell.snapshot.v1`; the JSON snapshot alone does not contain the query, and setting a view does not require a JSON lifecycle event. The client pairs query and agent facts by boot ID and revision, discards older revisions, and clears the projection when the connection or session changes. The source contract was checked against [Herdr 0.9.3's endpoint agent state](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/client/shell/endpoint_agent_state.rs).

The native Agents header displays the view label and exposes its source and a per-window **Follow Herdr View** toggle. Turning it off bypasses the server query locally. The existing selected-Space filter remains a separate intersection applied after the query and its ordering; switching to all Spaces removes only that local restriction. Context values for the current workspace and tab use the native window's selection. Filtering never changes the selected terminal pane. Empty states distinguish an empty view from a view with no matches in the selected Space.

The evaluator supports `all`, `any`, `not`, `eq`, `in`, and `exists`, built-in fields and string tokens, and stable ascending or descending sorting with missing values last. An explicit query sort takes precedence over the local `ui.agent_panel_sort` setting. Unknown or invalid rules reject the entire query, show **Unavailable**, and retain the ordinary list with its Space filter. Servers without the capability retain the existing JSON-backed sidebar.

When available, `endpoint.agent-completions.v1` supplies completion sequences for the same boot and revision. Each connection tracks its own seen state, baselines existing completions on attach, and acknowledges visible panes only after a matching terminal surface is drawn in the active key window. Working-to-idle transitions provide a fallback when the completion companion is absent. The projected status and seen state participate in filtering and sorting.

Unit and socket integration tests cover query-only updates, Space intersection, local bypass, selected context, token ordering, invalid queries, revision pairing, reconnects, and completion acknowledgement. An isolated local plugin in `xherdr-ui-test`, with temporary XDG configuration and state roots, set an Attention view and a selected-workspace view. Captures of the running native app verified their rows, Space intersection, empty state, and restoration after clearing the query. Interactive menu clicks were not checked because native automation failed to start and Accessibility access was unavailable. No remote execution was checked. See [Herdr plugins](herdr-plugins.md) for the remaining integration scope.

## Terminal surface

An AppKit text view captures keyboard input and paste without editing the displayed screen. A serialized queue sends `TextCommit`, `Paste`, and semantic `Key` events to the selected pane through the client endpoint. When that endpoint is unavailable, the queue uses JSON `pane.send_input`. The shell was checked with typed commands, Enter, Backspace, paste, and Ctrl+C in `xherdr-ui-test`. The live endpoint was also checked with colored shell output, a split tab with input directed to its right pane, and a full-screen Codex pane.

The pane surface supplies its inner rectangle and `mouse_reporting` flag. When mouse reporting is active, clicks, releases, drags, and wheel events go to that pane as cell-relative semantic mouse events; Shift-click keeps native text selection available. The input remains local to `herdr-client.sock` and is skipped while the endpoint is unavailable because JSON `pane.send_input` has no mouse field. A test program in `xherdr-ui-test` enabled DEC mouse mode and received SGR press, release, and wheel sequences.

The surface also supplies split handle areas, hit rectangles, and paths. Dragging a handle sends `layout.set_split_ratio` over the endpoint, capped at about 30 updates per second with a final update on release. The server owns the layout; xherdr redraws from the next surface. In `xherdr-ui-test`, dragging both split orientations changed the ratios reported by `session.snapshot`. See [Protocol stability](https://herdr.dev/docs/socket-api/#protocol-stability) and [Reading panes](https://herdr.dev/docs/socket-api/#reading-panes).

Complete surfaces also carry native graphics assets and placements. xherdr decodes PNG, RGB, and RGBA bytes, caches assets by the protocol key while the server retains them, and draws pane placements in z order with source cropping. Graphics survive incremental cell patches because patches update only text and cursor state. Popup graphics are parsed but are not displayed until popup layers are implemented. A four-color PNG sent with `pane.graphics.set` to pane `w1:p6` in `xherdr-ui-test` appeared in the live surface.

The live renderer records UTF-16 offsets at cell boundaries. Before replacing the attributed text for a new surface, it maps the selected range to cells, then restores the range in the new render. Copy uses a snapshot of the selected text so subsequent screen updates do not change clipboard content, and trims terminal row padding. In `xherdr-ui-test`, selection remained active through about 200 updates from another pane, and Command-C/Command-V reproduced the selected text.

The suitability and integration boundary for [SwiftTerm](swiftterm-evaluation.md) are documented separately.

## Herdr configuration

The sidebar gear opens a compact settings sheet for common Herdr options and the full TOML file. The file path follows `HERDR_CONFIG_PATH` when set, otherwise `~/.config/herdr/config.toml`, as described in [Herdr configuration](https://herdr.dev/docs/configuration/). Guided edits preserve unrelated tables and comments. `herdr config check` validates a temporary copy before any write; the save then checks that the on-disk file still matches the loaded version and writes atomically. After saving, xherdr calls `server.reload_config` only on the selected named session and reports partial or failed reloads. Settings that Herdr applies only at startup still need a server restart. The local file is shared across local sessions, so changing it can affect another session when that server next reloads or starts.

The settings screen was checked against the local config without saving to it. A separate temporary TOML fixture verified comment preservation, nested tables, validation errors, and external-change rejection. A reload request to `xherdr-ui-test` returned `applied` with no diagnostics. Herdr's presentation theme applies to its terminal client; xherdr keeps its own native colors for now.

## Workspace controls

New Space sends `workspace.create` with the selected workspace as its directory source and `focus = true`. New Tab sends `tab.create` for the selected workspace with `focus = true`. xherdr then refreshes `session.snapshot` and selects the returned IDs, while the event subscription keeps later changes in sync. Both actions live in Menu as well as in the Spaces and tab headers. The sidebar button and Menu item toggle xherdr's sidebar locally. The controls were exercised in `xherdr-ui-test`: one new tab and one new workspace appeared and became selected without touching the default session.

## Keyboard shortcuts

The focused terminal text view handles Herdr's prefix sequence and direct chords before forwarding input to the pane. The default prefix is `ctrl+b`; the next key selects an action and an unmatched key cancels the prefix. Supported actions cover help/settings, new space/tab, tab switching, sidebar visibility, pane focus and splits, zoom, and config reload. Pane commands call `pane.focus_direction`, `pane.split`, or `pane.zoom` on the selected named session and refresh the snapshot. Shortcut help opens the editable Shortcuts settings section.

Bindings come from the same local `[keys]` table as the Herdr TUI, including multiline arrays of alternatives. The settings section writes the Herdr syntax and validates through `herdr config check` before saving. Custom bindings become active in xherdr after saving. The remaining Herdr TUI actions are preserved in config.toml but are not intercepted by xherdr. Shortcut handling currently applies while the terminal has keyboard focus; settings fields and other native controls keep their usual keyboard behavior.

## Links

Holding Command underlines the link under the pointer and shows a pointing hand; Command-click opens it with the default browser, as in iTerm2. A complete surface carries the OSC 8 hyperlink URIs and each cell their index; Herdr sends a complete surface instead of a patch whenever changed cells touch a hyperlink, so patches keep the indices valid. Cells with the same destination form one link, across rows. Without OSC 8, `http` and `https` URLs are found in the text, dropping trailing punctuation and unbalanced closers, and a row whose last cell is filled continues on the next one so wrapped URLs open whole. Only web links open, like Herdr's own client: a `file:` hyperlink could otherwise launch an application.

The surface decoder follows the frozen generation-1 field order in Herdr 0.9.1. It should be checked against a new release's frozen fixtures before changing the parser. Unsupported optional messages are ignored without dropping the JSON connection.

## Implementation order

1. Render popup layers and their graphics.
2. Add optional remote sessions after local behavior is stable.

Validate against a running Herdr server with `herdr status`, `herdr api schema --json`, and `herdr api snapshot`. These commands should be used as local diagnostics; no server state needs to be changed for the initial connection.

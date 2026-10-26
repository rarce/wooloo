# Herdr server connection plan

## Scope

wooloo connects to the named test session `wooloo-ui-test` through Herdr's JSON and client sockets. It subscribes to lifecycle events, takes `session.snapshot` after subscription and after structural changes, and maps server IDs into the sidebar and tabs. A generation-1 client endpoint streams the selected tab's terminal cells and carries semantic pane input; `pane.read` and JSON `pane.send_input` are fallbacks while the endpoint is unavailable. The sidebar session picker can switch to another named session, while `default` is rejected. Herdr's server owns the processes and terminal state; wooloo is a client. See [Herdr concepts](https://herdr.dev/docs/concepts/).

## Local socket and control API

Herdr's [Socket API](https://herdr.dev/docs/socket-api/) uses newline-delimited JSON over a Unix domain socket on macOS. The default path is `~/.config/herdr/herdr.sock`; a named session uses `~/.config/herdr/sessions/<name>/herdr.sock`. This build constructs only the named-session path. It does not use CLI environment overrides or the default socket. A socket file alone does not prove the server is healthy: wooloo checks the connection by subscribing and requesting a snapshot.

```json
{"id":"health-1","method":"ping","params":{}}
```

Use the installed binary's `herdr api schema --json` as the method and payload contract. The initial Herdr 0.9.1 inspection reported JSON schema version 1 and terminal protocol 22; those are historical observations, not hardcoded compatibility requirements or the endpoint generation. Later integration work used Herdr 0.9.3. See the release review below for the source comparison with 0.9.5 and its pending runtime validation.

## Release review: 0.9.3 to 0.9.5

Reviewed on 2026-10-16. The latest release-specific source baseline already cited in this document is [0.9.3, commit `7b116c05`](https://github.com/herdrdev/herdr/commit/7b116c05bfda646af39d2524c54e70c751f57ee8), released on September 29. The latest published release at review time is [0.9.5](https://github.com/herdrdev/herdr/releases/tag/v0.9.5), released on October 14, following [0.9.4](https://github.com/herdrdev/herdr/releases/tag/v0.9.4) on October 13. The local `herdr --version` still reports 0.9.3. This review compared upstream source and release notes; it did not upgrade Herdr or run wooloo against 0.9.5.

### Endpoint compatibility

`src/protocol/endpoint.rs` and `src/protocol/surface_scroll.rs` have identical contents at the documented 0.9.3 commit and tag `v0.9.5`. Endpoint generation 1, `shell.snapshot.v1`, `shell.surface.v1`, `shell.input.semantic.v1`, `shell.blob.v1`, and the agent-view and completion companion kinds remain unchanged. The scroll control layout also remains unchanged. See the 0.9.5 [endpoint contract](https://github.com/herdrdev/herdr/blob/v0.9.5/src/protocol/endpoint.rs) and [scroll codec](https://github.com/herdrdev/herdr/blob/v0.9.5/src/protocol/surface_scroll.rs). This comparison indicates no endpoint migration for wooloo; it does not replace checking frozen wire fixtures and running the native client against the new server.

### Changes relevant to wooloo

- **Semantic keyboard input:** 0.9.4 routes pane key encoding through libghostty instead of Herdr's own encoder. It corrects function keys, key releases, enhanced keyboard input, and modifier handling. Ctrl+Shift+letter now reaches a plain shell as the Ctrl byte; unsupported Super, Hyper, and Meta chords no longer insert escape-code text. wooloo captures input in AppKit, but the server still encodes its semantic key events for the pane, so this change warrants native regression checks. See [#5017](https://github.com/herdrdev/herdr/pull/5017).
- **Performance and sizing:** the server avoids per-cell allocations in text reads and unused terminal reads in client snapshots, reuses unchanged shell-detection text, and reduces hidden-pane memory. New workspaces, tabs, and splits start at the correct size. These are potential server-side benefits without a new wooloo codec. See [#4845](https://github.com/herdrdev/herdr/pull/4845), [#4847](https://github.com/herdrdev/herdr/pull/4847), [#5085](https://github.com/herdrdev/herdr/pull/5085), and [#4873](https://github.com/herdrdev/herdr/pull/4873).
- **Server lifetime and persistence:** 0.9.4 saves sessions before macOS restart closes applications, flushes saves before replacing the previous file, and keeps the server alive when thread creation fails. Unix servers ignore `SIGHUP`; shutdown scripts should use `herdr server stop` or `SIGTERM`. Restored layouts and supported agent conversations are distinct from preserving the original processes across restart. See [#5092](https://github.com/herdrdev/herdr/pull/5092), [#5152](https://github.com/herdrdev/herdr/pull/5152), [#4958](https://github.com/herdrdev/herdr/pull/4958), and [#4965](https://github.com/herdrdev/herdr/pull/4965).
- **Agent state:** 0.9.5 removes Codex turn-status hooks and returns to screen detection, avoiding the Interrupt-hook timeout warning. Upstream recommends `herdr integration install codex` to update the installed integration. Claude Code questions are correctly marked blocked in named sessions. These affect the facts wooloo displays, independently of its agent-view evaluator. See [#5278](https://github.com/herdrdev/herdr/pull/5278) and [#5192](https://github.com/herdrdev/herdr/pull/5192).
- **SSH and worktrees:** the server stops probing forwarded SSH agents every second. Restore remains responsive during slow Git discovery and preserves worktree grouping when checkouts are temporarily unavailable. See [#4962](https://github.com/herdrdev/herdr/pull/4962), [#4945](https://github.com/herdrdev/herdr/pull/4945), and [#4770](https://github.com/herdrdev/herdr/pull/4770).
- **Plugin updates:** `herdr plugin update` updates GitHub-installed plugins, either all or by name, while leaving locally linked plugins alone. Running plugin panes retain their old files; subsequent runs use the update without config reload. This adds no native plugin catalog to wooloo. See [#4245](https://github.com/herdrdev/herdr/pull/4245) and the separate [plugin integration scope](herdr-plugins.md).

The TUI also changes link routing to give plugin handlers priority while mouse capture is enabled, and confirms closing a workspace's last pane. Those client-side behaviors do not automatically apply to wooloo's native links or close controls. Likewise, 0.9.5's plain-text prefix fix addresses Herdr's terminal client; wooloo has its own shortcut handling. Windows-specific notification, input, process-launch, and permissions fixes are listed in the upstream release notes.

### Unreleased follow-up and validation

The reviewed `master` tip was [`143bf5fd`](https://github.com/herdrdev/herdr/commit/143bf5fd4781d164260c63fe28e7dc08054ad32f), dated October 15. It includes handshake deadlines, endpoint connection cancellation and recovery after wake, blocked shared-SSH recovery, a hyperlink-related server crash fix, and another macOS server-lifetime fix when its terminal quits. These must not be attributed to 0.9.5. The [comparison with that pinned tip](https://github.com/herdrdev/herdr/compare/v0.9.5...143bf5fd4781d164260c63fe28e7dc08054ad32f) also includes release-branch changes merged back into master, so its commit count is not a count of new fixes.

Before claiming runtime compatibility with 0.9.5, build and test wooloo, then use only the isolated `wooloo-ui-test` session to check semantic keys and modifiers, IME and paste, Codex and Claude state, panel creation and resizing, Kitty graphics, popups, and reconnection. Run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh` for the terminal validation; the latter uses its own `wooloo-perf` session. No such 0.9.5 runtime checks were performed in this review.

## State synchronization

The client opens a persistent `events.subscribe` socket for workspace, tab, pane, and layout lifecycle changes, plus agent status changes for known panes. It waits for the subscription acknowledgement, then requests `session.snapshot` over another socket. Any events arriving during that request stay queued on the subscription socket and each triggers a fresh snapshot. If the pane set changes, the stream is reopened so status subscriptions cover the new panes. This follows the bootstrap ordering in the [Socket API documentation](https://herdr.dev/docs/socket-api/).

The selected tab uses the binary client endpoint at `herdr-client.sock`. wooloo negotiates endpoint generation 1 and verifies the selected snapshot, surface, input, and blob codecs. It asks for scroll-aware patches (`surface_scroll`) and opts out of the optional retained and delta encodings, decodes complete surfaces, incremental cell patches and scrolled patches, and sends viewport resize and focus requests. The surface's colors, cursor, and cell grid render in an AppKit text view. When no matching surface is available, visible pane text is refreshed with `pane.read`. On socket failure or an invalid surface patch, the UI drops the stale surface and reconnects with the latest viewport size, then restores workspace, tab, and pane focus. The sidebar uses the server's `blocked`, `working`, `done`, `idle`, and `unknown` values.

This was validated against `wooloo-ui-test` by creating a workspace, tabs, and a split pane; sending `printf wooloo_socket_ok` from the app; and reporting then clearing a test agent status. The UI updated from `working` to `blocked` and removed the agent after the authority was cleared.

Agent rows use the snapshot's workspace and tab IDs to show location, plus `display_agent`, `name`, `agent`, or `title` for the label. They use `state_labels` when present and show a `summary` token, title, or stripped terminal title as secondary detail. The default two-line structure follows Herdr's [Agent sidebar rows](https://herdr.dev/docs/config-reference/); wooloo adds the secondary detail when available. These fields are refreshed through the existing snapshot event stream.

## Endpoint recovery policy

The generation-1 client socket uses nonblocking I/O and monotonic `ContinuousClock` deadlines. The initial welcome and first boot-bearing shell snapshot must arrive within five seconds. Once the first byte of a frame arrives, its entire length prefix and payload must finish within ten seconds; a trickle of bytes does not reset this limit. Outgoing frames have a five-second deadline from enqueue through delivery. The serial writer runs off the main thread, and queued data is bounded to 64 MiB and 1,024 frames. Exceeding either bound closes the connection instead of growing an unbounded input backlog.

When the welcome advertises `health_check`, wooloo sends `endpoint.health.ping.v1` every five seconds after the previous matched reply and requires the identical token in `endpoint.health.pong.v1` within ten seconds. These controls are part of the [existing generation-1 contract](https://github.com/herdrdev/herdr/blob/v0.9.5/src/protocol/endpoint.rs), not a new codec. Screen output is not a heartbeat: a quiet terminal stays connected when its health replies arrive. Endpoints without this capability receive no probes and may remain idle indefinitely; their stalled partial frames and writes are still bounded, but a silent, unresponsive legacy endpoint cannot be distinguished from a healthy idle one.

Cancellation shuts down the socket without waiting for the writer. Each in-flight write owns a duplicated descriptor, so reader cleanup cannot make it write to a reused descriptor. A failed connection invalidates queued store callbacks, clears the surface, agent view, completion state and Git counters, and re-enables text fallback. The existing one-second retry loop opens a fresh endpoint with the latest viewport, reconciles resizes received while waiting for the first snapshot, then restores the selected tab/Space and pane. Frames accepted by the failed writer are not replayed: delivery cannot be inferred after a partial write.

`events_lost` retains the existing JSON subscription recovery: Herdr emits the error envelope and closes the subscription, wooloo detects EOF, reconnects and waits for `subscription_started` before obtaining a new authoritative `session.snapshot`. A store integration test changes state without emitting its lifecycle event, sends `events_lost` plus EOF, and verifies the missed change appears after resubscription. No additional event recovery mechanism was needed.

Fake-peer and store tests cover missing welcome/snapshot, stalled headers/payloads, stalled writers, matching/missing/incorrect health replies, idle legacy endpoints, cancellation, session-switch isolation, stale-state cleanup, fallback and restoration of the latest focus/viewport. The final focused endpoint, store, socket and event-stream suite passed 74 tests in Release on macOS, including a resize received during the initial handshake. A live macOS check against Herdr 0.9.3 used a local proxy over `wooloo-ui-test` to discard endpoint responses while leaving the JSON socket and Herdr server running. The native app reconnected in 14.39 seconds, restored the selected tab and pane, used the last resized viewport (69×37 cells, rather than the provisional 80×24 hello), and drew newly generated output. The temporary Space was removed afterward. No remote SSH or Herdr 0.9.5 runtime check was performed; the release review above remains a source comparison.

Validation on 2026-10-16 also ran the full unit suite (973 tests, 9 skipped, with only the two notebook snapshot failures already observed before this change: `ViewSnapshotTests.testNotebookPreviewDocument` and `ViewSnapshotTests.testNotebookPreview`). The startup-resize follow-up was verified in the final focused Release run. `scripts/terminal-bench.sh` completed its default Release workloads, and `scripts/terminal-e2e.sh` completed all default workloads in its isolated `wooloo-perf` session. The 30 MiB trace replay matched every drawn revision to the reference decoder; all 100 probed keys had matching output, with 1.83 ms median key-to-draw latency in this run. These are measurements of this machine/run, not latency guarantees.

## Agent views

wooloo follows the server's declarative agent view when the client endpoint advertises `agent_view_projection`. The endpoint sends `endpoint.agent-view.v1` alongside `shell.snapshot.v1`; the JSON snapshot alone does not contain the query, and setting a view does not require a JSON lifecycle event. The client pairs query and agent facts by boot ID and revision, discards older revisions, and clears the projection when the connection or session changes. The source contract was checked against [Herdr 0.9.3's endpoint agent state](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/client/shell/endpoint_agent_state.rs).

The native Agents header displays the view label and exposes its source and a per-window **Follow Herdr View** toggle. Turning it off bypasses the server query locally. The existing selected-Space filter remains a separate intersection applied after the query and its ordering; switching to all Spaces removes only that local restriction. Context values for the current workspace and tab use the native window's selection. Filtering never changes the selected terminal pane. Empty states distinguish an empty view from a view with no matches in the selected Space.

The evaluator supports `all`, `any`, `not`, `eq`, `in`, and `exists`, built-in fields and string tokens, and stable ascending or descending sorting with missing values last. An explicit query sort takes precedence over the local `ui.agent_panel_sort` setting. Unknown or invalid rules reject the entire query, show **Unavailable**, and retain the ordinary list with its Space filter. Servers without the capability retain the existing JSON-backed sidebar.

When available, `endpoint.agent-completions.v1` supplies completion sequences for the same boot and revision. Each connection tracks its own seen state, baselines existing completions on attach, and acknowledges visible panes only after a matching terminal surface is drawn in the active key window. Working-to-idle transitions provide a fallback when the completion companion is absent. The projected status and seen state participate in filtering and sorting.

Unit and socket integration tests cover query-only updates, Space intersection, local bypass, selected context, token ordering, invalid queries, revision pairing, reconnects, and completion acknowledgement. An isolated local plugin in `wooloo-ui-test`, with temporary XDG configuration and state roots, set an Attention view and a selected-workspace view. Captures of the running native app verified their rows, Space intersection, empty state, and restoration after clearing the query. Interactive menu clicks were not checked because native automation failed to start and Accessibility access was unavailable. No remote execution was checked. See [Herdr plugins](herdr-plugins.md) for the remaining integration scope.

## Terminal surface

An AppKit text view captures keyboard input and paste without editing the displayed screen. A serialized queue sends `TextCommit`, `Paste`, and semantic `Key` events to the selected pane through the client endpoint. When that endpoint is unavailable, the queue uses JSON `pane.send_input`. The shell was checked with typed commands, Enter, Backspace, paste, and Ctrl+C in `wooloo-ui-test`. The live endpoint was also checked with colored shell output, a split tab with input directed to its right pane, and a full-screen Codex pane.

The pane surface supplies its inner rectangle and `mouse_reporting` flag. When mouse reporting is active, clicks, releases, and drags go to that pane as cell-relative semantic mouse events; Shift-click keeps native text selection available. The input remains local to `herdr-client.sock` and is skipped while the endpoint is unavailable because JSON `pane.send_input` has no mouse field. A test program in `wooloo-ui-test` enabled DEC mouse mode and received SGR press, release, and wheel sequences.

Wheel events are sent even when a pane has not enabled mouse reporting. Herdr owns the decision between program mouse input and terminal scrollback; filtering wheels by `mouse_reporting` prevents shell and agent history from scrolling. The right-side scrollbar block characters are drawn as full-height cell fills so the track remains continuous across terminal rows.

The native window publishes `ClientShellHostTheme` (default foreground/background, ANSI palette, and light/dark appearance) followed by `ClientShellFocus` on connection, theme changes, and key-window transitions. Herdr uses the foreground client's host theme and forwards focus to the child terminal. This restores the native palette and child focus after another client such as Ghostty used the same session; otherwise a focus-aware program can retain its inactive appearance. Reconnection republishes the latest window state.

The surface also supplies split handle areas, hit rectangles, and paths. Dragging a handle sends `layout.set_split_ratio` over the endpoint, capped at about 30 updates per second with a final update on release. The server owns the layout; wooloo redraws from the next surface. In `wooloo-ui-test`, dragging both split orientations changed the ratios reported by `session.snapshot`. See [Protocol stability](https://herdr.dev/docs/socket-api/#protocol-stability) and [Reading panes](https://herdr.dev/docs/socket-api/#reading-panes).

Complete surfaces also carry native graphics assets and placements. wooloo decodes PNG, RGB, and RGBA bytes, caches assets by the protocol key while the server retains them, and draws pane placements in z order with source cropping. Graphics survive incremental cell patches because patches update only text and cursor state. Popup placements use their own terminal identity and are clipped to the popup content rectangle. An earlier test displayed a four-color PNG through `pane.graphics.set`; that is historical validation only. Herdr removed `pane.graphics.info`, `set`, `clear`, and `stream` in [0.9.2](https://github.com/herdrdev/herdr/releases/tag/v0.9.2), and those methods return `unknown_method` in the documented 0.9.3 baseline as well. Programs must write standard Kitty graphics to their terminal; the endpoint still projects graphics assets and placements for wooloo to render. The popup test below exercised that Kitty path.

## Popup terminals

Popup title cell transport is an upstream dependency; the [unsubmitted protocol proposal](herdr-popup-title-cells.md) records the compatibility and clipping contract. Until Herdr provides it, wooloo retains its pinned Unicode title layout.

A complete surface can carry a separate popup terminal with its ID, title, size hints, cells, cursor, links, and mouse modes. wooloo retains that model and composes it in the existing AppKit terminal grid, with a centered border, title, accessible Close Popup button, and dimmed background. Geometry follows Herdr's cell and percentage sizing, minimum dimensions, viewport clamping, and reserved right gutter. The raw pane surface stays intact for patches and independent trace verification. See [Herdr's popup composition](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/client/shell/composition.rs).

Keyboard input, IME text, text paste, file-path drops, and mouse reporting address the popup terminal through `ClientShellPopupInput`. Escape reaches the program. The close button and popup context menu send `popup.close`. Input, pane menus, split drags, tab drops, and pane shortcuts cannot act on the covered terminal. Selection and link activation stay within the popup content; popup graphics are clipped there, and underlying pane graphics are clipped around the popup. Pane input resumes when a surface confirms the popup closed.

Herdr permits one popup per session and projects it to clients showing its owning tab. wooloo follows that projection without changing its Space, tab, pane selection, or agent filter. Opening a popup brings the terminal forward when a document or Search tab is active; closing restores that tab if the user stayed in the same session, Space, and terminal tab. Popup appearance and identity changes publish a structural update; subsequent terminal frames use the normal surface feed without publishing the whole window.

Input carries the popup's boot ID and terminal ID locally and is discarded when either no longer matches the current surface. During an endpoint interruption, popup input never falls back to JSON `pane.send_input`, and the pane input guard remains until a fresh surface confirms the modal state. Changing sessions resets that guard. A reconnect rebuilds popup state from the server; closing the client does not close the server's popup process.

Unit and socket tests cover decoding, replacement, malformed frames, geometry, cursor placement, selection, keyboard and IME routing, mouse hit testing, graphics clipping, explicit close, and disconnected input. A temporary plugin in the isolated `wooloo-ui-test` session displayed live terminal content and a Kitty graphic in the native app. Eight letters sent through the native keyboard probe reached the popup's PTY as `abcdefgh`; closing restored the covered pane, with Space, tab, and pane focus unchanged. The plugin registry and state were kept under temporary XDG roots. The terminal benchmark and all E2E workloads completed, and the E2E trace matched the independent decoder. The native plugin catalog remains deferred; popups opened through Herdr's CLI, API, or plugins appear automatically.

The live renderer records UTF-16 offsets at cell boundaries. Before replacing the attributed text for a new surface, it maps the selected range to cells, then restores the range in the new render. Copy uses a snapshot of the selected text so subsequent screen updates do not change clipboard content, and trims terminal row padding. In `wooloo-ui-test`, selection remained active through about 200 updates from another pane, and Command-C/Command-V reproduced the selected text.

The suitability and integration boundary for [SwiftTerm](swiftterm-evaluation.md) are documented separately.

## Herdr configuration

The sidebar gear opens a compact settings sheet for common Herdr options and the full TOML file. The file path follows `HERDR_CONFIG_PATH` when set, otherwise `~/.config/herdr/config.toml`, as described in [Herdr configuration](https://herdr.dev/docs/configuration/). Guided edits preserve unrelated tables and comments. `herdr config check` validates a temporary copy before any write; the save then checks that the on-disk file still matches the loaded version and writes atomically. After saving, wooloo calls `server.reload_config` only on the selected named session and reports partial or failed reloads. Settings that Herdr applies only at startup still need a server restart. The local file is shared across local sessions, so changing it can affect another session when that server next reloads or starts.

The settings screen was checked against the local config without saving to it. A separate temporary TOML fixture verified comment preservation, nested tables, validation errors, and external-change rejection. A reload request to `wooloo-ui-test` returned `applied` with no diagnostics. Herdr's presentation theme applies to its terminal client; wooloo keeps its own native colors for now.

## Workspace controls

New Space sends `workspace.create` with the selected workspace as its directory source and `focus = true`. New Tab sends `tab.create` for the selected workspace with `focus = true`. wooloo then refreshes `session.snapshot` and selects the returned IDs, while the event subscription keeps later changes in sync. Both actions live in Menu as well as in the Spaces and tab headers. The sidebar button and Menu item toggle wooloo's sidebar locally. The controls were exercised in `wooloo-ui-test`: one new tab and one new workspace appeared and became selected without touching the default session.

## Keyboard shortcuts

The focused terminal text view handles Herdr's prefix sequence and direct chords before forwarding input to the pane. The default prefix is `ctrl+b`; the next key selects an action and an unmatched key cancels the prefix. Supported actions cover help/settings, new space/tab, tab switching, sidebar visibility, pane focus and splits, zoom, and config reload. Pane commands call `pane.focus_direction`, `pane.split`, or `pane.zoom` on the selected named session and refresh the snapshot. Shortcut help opens the editable Shortcuts settings section.

Bindings come from the same local `[keys]` table as the Herdr TUI, including multiline arrays of alternatives. The settings section writes the Herdr syntax and validates through `herdr config check` before saving. Custom bindings become active in wooloo after saving. The remaining Herdr TUI actions are preserved in config.toml but are not intercepted by wooloo. Shortcut handling currently applies while the terminal has keyboard focus; settings fields and other native controls keep their usual keyboard behavior.

## Native keyboard input

`TerminalKeyInput` maps native key-down events before pane/popup routing. Enter, Tab, Escape, Backspace, Delete, arrows, Home/End and Page Up/Down retain every combination of Control, Option (Alt) and Shift. Control character chords (including Control+Option) use AppKit's `charactersIgnoringModifiers`, which retains the active layout's Shift-produced symbol, rather than a US key-code table or Option's text glyph. All active modifiers are included in the existing key-name format, including literal `+` characters. Both routes use the unchanged generation-1 key encoder.

Plain, Shift-only and Option text pass through AppKit's input method, allowing accents, dead-key composition and layout symbols. Option with a printable key is text input rather than an Alt character chord; configured Herdr shortcuts still take precedence. Empty dead-key events and multi-scalar text are not converted to character keys. While marked text is active, navigation and editing keys stay with the input method; forwarding an IME commit also clears the marked range so subsequent keys resume terminal input. Text commits and clipboard paste remain separate operations. Herdr shortcuts run first, and native Command shortcuts keep their existing AppKit path. Wooloo defaults to Control+Command+B when no prefix is configured; repeating an explicit non-Command prefix forwards it to the terminal. See [agent shortcut research](agent-shortcuts.md) for conflicts and the last-terminal Space confirmation. Chords reserved by macOS may never arrive at the view.

The semantic model remains synthetic Press events: each native repeat produces one additional Press with `repeat_count = 1`; no key-up events or physical key identity are fabricated. The existing `tracks_release` wire field is unchanged and does not demonstrate actual release delivery. The model preserves the layout-produced symbol, but does not carry an alternate unshifted physical symbol, hardware identity or the full Kitty event lifecycle. This fix therefore does not claim support for release reporting or all Kitty enhancement flags.

`TerminalKeyInputTests` exercises native events through the view, both routes and an independent wire decoder, including modifier combinations, non-US symbols, repeat delivery, focus changes, composition and paste. The opt-in live test uses a raw PTY child under Herdr 0.9.5, with Kitty disambiguation (`CSI > 1 u`) off and on. Representative expected bytes are:

| Input | Normal mode | Kitty disambiguation |
| --- | --- | --- |
| Option+Left | `ESC [ 1 ; 3 D` | `ESC [ 1 ; 3 D` |
| Option+Backspace | `ESC DEL` | `ESC [ 127 ; 3 u` |
| Shift+Enter | `CR` | `ESC [ 13 ; 2 u` |
| Control+Shift+A | `SOH` | `ESC [ 97 ; 6 u` |
| Control+Option+Shift+A | `ESC SOH` | `ESC [ 97 ; 8 u` |

Legacy terminal encoding cannot distinguish every combination; for example Control+A and Control+Shift+A both become SOH. The distinction reaches Herdr and is visible when the child enables Kitty disambiguation. The probe passed all 66 pane/popup captures on macOS 26.6.2 with Herdr 0.9.5, including repeated keys, Unicode commits and bracketed multiline paste. Interactive checks against the isolated session also confirmed Option+Backspace word deletion, Command+A/Command+C copied into an untitled document, focus returning to the terminal, and multiline Unicode paste followed by Enter. Layout-symbol cases use synthetic NSEvents, not an automated system-wide layout switch; IME candidate windows and real hardware/layout switching were not exercised.

To reproduce, first build the Debug test bundle (the live test skips without a fixture):

```sh
xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -disableAutomaticPackageResolution -only-testing:woolooTests/TerminalKeyInputTests test
WOOLOO_HERDR=/path/to/herdr-0.9.5 python3 scripts/terminal-key-probe.py
```

`WOOLOO_DERIVED_DATA` selects a different matching build directory. The script creates disposable XDG directories, starts only its own `wooloo-ui-test` server, runs 33 cases each against a pane and plugin popup, checks captured PTY bytes, and stops that server. Logs and JSON results go to `build/perf/keyboard-input/`. This targeted runtime validation supplements the source-only release review above; it does not change the bundled Herdr version or validate SSH transport.

## Links

Holding Command underlines the link under the pointer and shows a pointing hand; Command-click opens it with the default browser, as in iTerm2. A complete surface carries the OSC 8 hyperlink URIs and each cell their index; Herdr sends a complete surface instead of a patch whenever changed cells touch a hyperlink, so patches keep the indices valid. Cells with the same destination form one link, across rows. Without OSC 8, `http` and `https` URLs are found in the text, dropping trailing punctuation and unbalanced closers, and a row whose last cell is filled continues on the next one so wrapped URLs open whole. Only web links open, like Herdr's own client: a `file:` hyperlink could otherwise launch an application.

The surface decoder follows the frozen generation-1 field order in Herdr 0.9.1. It should be checked against a new release's frozen fixtures before changing the parser. Unsupported optional messages are ignored without dropping the JSON connection.

With `surface_scroll`, Herdr 0.9.3 sends scrolling output as `endpoint.surface-scroll.v1` control frames instead of patches that rewrite every row: unpadded base64 of a scroll count, each pane region's x, y, width and height (16-bit little-endian) and row shift (signed 16-bit), then one length-prefixed ordinary patch frame. The receiver swaps each region's rows in the order Herdr's `for_each_swap` defines, then applies the patch, which carries only the rows that still differ. A region outside the surface, overlapping regions, a shift of zero or at least the region's height, or bytes after the patch fail the frame like an invalid patch. The layout is frozen with the message kind; see [Herdr's `protocol/surface_scroll.rs`](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/protocol/surface_scroll.rs). Earlier Herdr releases ignore the hello field and keep sending plain patches. Herdr 0.9.3's `surface_reuse` and `surface_delta` did not change the frames for scrolling output, so wooloo still declines them.

## Implementation order

1. Add optional remote sessions after local behavior is stable.

Validate against a running Herdr server with `herdr status`, `herdr api schema --json`, and `herdr api snapshot`. These commands should be used as local diagnostics; no server state needs to be changed for the initial connection.

### Rearranging terminal panes

Right-click a terminal and use **Move Terminal** to place it on any side of another pane,
or choose **Move to Own Tab** to detach it. Hovering a pane reveals a move handle in its
upper-right corner: drag it onto another pane's highlighted edge to reinsert it there,
or onto the tab bar to create its own tab. Clicking the handle also opens the move menu.
The handle does not send terminal mouse input; Option-right-click retains the existing
mouse-aware program behavior, and popup terminals do not offer layout moves.

Herdr refuses `pane.move` within the same tab (`same_tab`). Wooloo first moves that pane to
an intermediate `new_tab`, then moves it back beside the target. Left/top placements add
`pane.swap` after the right/down split. The pane and terminal identities survive these
moves. A failed intermediate step refreshes the snapshot and reports Herdr's reason;
if reinsertion fails, the terminal remains reachable in the detached tab. Zoomed targets
and self-drops are rejected. Local and SSH connections use the same socket requests.

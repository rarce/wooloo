# herdr-core 0.1.18: protocol and integration review

Reviewed on 2026-11-05. This is a source-based reference for a possible future wooloo backend. wooloo currently bundles Herdr TUI 0.9.5 and uses its JSON API and native cell-surface endpoint; it does not implement herdr-core support. See the [current connection design](herdr-connection.md).

## Version baseline and verification

The baseline is herdr-core **0.1.18**, recorded by the upstream [release commit `3965a46c`](https://github.com/herdrdev/herdr-core/commit/3965a46caae095a3ead01de237fa13955e52b8c6) on 2026-11-04. Its [OpenRPC schema](https://github.com/herdrdev/herdr-core/blob/3965a46caae095a3ead01de237fa13955e52b8c6/schema/hc.openrpc.json) also identifies version 0.1.18. The [README](https://github.com/herdrdev/herdr-core/blob/3965a46caae095a3ead01de237fa13955e52b8c6/README.md) and [protocol documentation](https://github.com/herdrdev/herdr-core/blob/3965a46caae095a3ead01de237fa13955e52b8c6/schema/README.md) at that commit are the sources for the behavior below.

The reviewed `master` tip was [`c6b316f8`](https://github.com/herdrdev/herdr-core/commit/c6b316f87c33e6f2ab1a1ceea3e3461e2b6bb61a), dated 2026-11-05. Its additional fix preserves the core environment across planned restarts; it is after the 0.1.18 release commit and must not be attributed to that baseline. The three reference files above were identical at the release commit and the reviewed tip.

Core and App distribute through `releases.herdr.dev`; their GitHub release collections were empty at review time. The Core `latest.json` distribution manifest returned HTTP 403, and the App manifest could not be retrieved through the web tool, so this review verifies source release versions rather than downloadable artifacts. No Core installation, server session, runtime compatibility test, or migration was performed. The existing local `herdr --version` reported 0.9.5; that executable is Herdr TUI, not Core.

## Relationship to Herdr TUI and App

| Component | Responsibility | Reviewed baseline |
| --- | --- | --- |
| Herdr TUI (`herdr`) | Existing multiplexer, its server, agent detection, and native cell-surface protocol | Published release 0.9.5; `master` at `ee5bfb50` |
| herdr-core (`hc`) | Persistent terminals, explicit program status, agent coordination, and remote machines | Source release 0.1.18 |
| herdr-app | Desktop client over Core, with spaces, tabs, splits, layouts, and JavaScript mods | Source release 0.1.13, 2026-11-04 |

The author [confirmed on 2026-10-29](https://github.com/herdrdev/herdr-app/issues/63#issuecomment-6508292436) that the separate backends are intentional: the app cannot attach to a TUI server, they cannot share agents today, and whether the TUI will move to Core remains undecided. Core is not a drop-in update to the `herdr` binary bundled by wooloo.

As a separate compatibility check, TUI `src/protocol/endpoint.rs`, `wire.rs`, and `surface_scroll.rs` had identical contents at `v0.9.5` and [the reviewed TUI tip `ee5bfb50`](https://github.com/herdrdev/herdr/tree/ee5bfb5041bb3e4a49d591c72308aae3c81ecdde/src/protocol). There was no new surface codec to adopt in that comparison. This does not establish runtime compatibility with every server change.

## Control API and transport

Core's API is **preview, protocol generation 1, version 0.x**. Its generation number is independent of the TUI endpoint's generation 1; the two protocols are incompatible.

On Unix, clients connect through a Unix socket; on Windows, through a named pipe. `hc connect` exposes the same protocol over stdin/stdout, including through SSH. Endpoint locations and overrides should follow the version's [security and endpoint rules](https://github.com/herdrdev/herdr-core/blob/3965a46caae095a3ead01de237fa13955e52b8c6/docs/security.md), rather than wooloo's existing TUI session paths.

A connection begins with newline-delimited JSON-RPC 2.0:

```json
{"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{}}
```

`hc schema` and `rpc.discover` expose the OpenRPC document. `hello` returns the generation, core identity, supported methods, and features. Errors include a stable `data.kind` and a hint. Discover capabilities from the connected server instead of inferring them only from its version.

The schema compatibility test compares against `released.openrpc.json` and rejects structural breaks such as removed methods or fields, new required inputs, narrowed inputs, or incompatible result types. The documented policy is additive API evolution, with an intentional generation change for a real break. This does not settle behavioral defaults or CLI JSON compatibility: [Core #33](https://github.com/herdrdev/herdr-core/issues/33) asks for those guarantees and remained open without comments at review time. For an integration, prefer the socket API and explicit options over CLI output projections and assumed defaults.

The 0.1.18 schema groups its methods as follows:

| Area | Methods |
| --- | --- |
| Discovery and server | `hello`, `rpc.discover`, `server.status`, `server.stop`, `server.restart` |
| Terminal lifecycle | `terminal.run`, `terminal.list`, `terminal.get`, `terminal.kill`, `terminal.rm`, `terminal.keep`, `terminal.label` |
| Terminal interaction | `terminal.read`, `terminal.attach`, `terminal.send`, `terminal.wait`, `terminal.keys`, `terminal.interrupt`, `terminal.put` |
| Coordination | `templates.list`, `events.subscribe` |
| Remote machines | `machine.add`, `machine.list`, `machine.connect`, `machine.rename`, `machine.rm`, `machine.exec` |
| Files and documents | `file.read`, `file.write`, `file.edit`, `doc.get`, `doc.set` |

## Terminal streams and rendering

`hello` with `{"framed":true}` switches to framed mode after the reply. Attach requires this mode. Each frame has a little-endian channel number (`u32`), kind (`u8`), payload length (`u32`), and payload, capped at 16 MiB. Channel 0 carries JSON-RPC; other channels carry terminal streams.

| Kind | Value | Purpose |
| --- | --- | --- |
| DATA | 0 | JSON-RPC on channel 0; terminal output/input on stream channels |
| CREDIT | 1 | Receiver consumption, as a little-endian `u32` byte count |
| CLOSE | 2 | Stream termination; the server can provide a JSON reason |
| RESIZE | 3 | Column and row counts as little-endian `u16` values |
| FOCUS | 4 | Viewer focus gained or lost |
| FACTS | 5 | Viewer display facts as JSON |
| AUTOMATIC_INPUT | 6 | Terminal-generated replies, separately from human input; requires negotiation |

`terminal.attach` returns a channel, then the initial terminal paint and live output. The initial paint includes the current screen, optional history, status, title, and win32-input-mode state. Output excludes terminal queries already answered by Core. This is terminal output to interpret, not the TUI's `shell.surface.v1` cell grid, patches, and graphics blobs.

wooloo would need a terminal emulator and input encoding on the attach path, plus handling for terminal modes and graphics. `terminal.keys` exists for named-key RPC requests, but does not replace implementing interactive attach input. In particular, a viewer honoring win32-input-mode must encode those key events itself.

The last active viewer owns the terminal size; attaching, typing, resizing, or gaining focus counts as activity. Observe-only viewers neither type nor resize. Optional `resize_notifications` must be negotiated; confirmed observers apply incoming RESIZE before subsequent DATA. Automatic query replies use AUTOMATIC_INPUT only when both `hello.features` and the attach result confirm support. Sending kind 6 without negotiation can lose input on old cores; otherwise use DATA with its legacy activity semantics.

Streams start with 256 KiB of credit. The viewer acknowledges consumed bytes with CREDIT. A stream more than 4 MiB behind receives a fresh repaint instead of the accumulated backlog. A stalled stream does not block channel 0 or other streams. Reconnection must establish new streams and reconcile authoritative state.

## Events, status, and persistence

`events.subscribe` returns a terminal snapshot and sequence number. Framed connections receive an event channel; a plain connection becomes notification-only. Events include terminal creation, loss, restart, finish, removal, keep changes, status, turn, title, labels, size, foreground process, and document changes. Remote terminals join the same stream with machine-qualified addresses such as `box/t7`.

Heartbeats carry the current sequence after 15 seconds without queued events. A subscriber that falls behind receives `missed` with a replacement terminal snapshot. Sequence numbers restart with each Core process, so reconnecting requires a fresh snapshot. Documents are not included in terminal snapshots and must be refetched separately after reconnect or missed notifications.

Status comes from **OSC 7501**, the Program Status Protocol. Core stores the program's report; it does not infer agent state from screen text or maintain a list of recognized agent brands. Programs without reports have no status. This differs from wooloo's current dependence on TUI detection and integrations, and needs an explicit presentation policy for terminals with no report.

Closing a viewer leaves programs running. Planned Core updates can preserve running terminals, but this must not be confused with recovery after program loss. `--keep` preserves a terminal record and recovers a fresh shell after loss; it does not rerun the original task or resume its conversation. Normal exit and explicit kill remain final. Child terminals end with their parent unless started with `--outlive-parent`.

Conversation resume references through OSC 7501 are still being discussed in [Core #15](https://github.com/herdrdev/herdr-core/issues/15). They are not a supported resume contract in 0.1.18.

## Spaces, files, and remote operations

Core stores opaque versioned JSON with `doc.get` and `doc.set`. Writes use the expected version and fail with `conflict` on stale updates. Each document is capped at 1 MiB and persists across restart and handover. Core does not interpret its contents.

The app stores its spaces, tabs, and splits in a `herdr-app` document. Terminal labels help associate terminals with app spaces and tabs, but do not represent their complete order or empty tabs. [App #43](https://github.com/herdrdev/herdr-app/issues/43) asks whether external clients may rely on that document's format and how to name or arrange work remotely. It remained open without an authoritative compatibility answer. Reusing that private document in wooloo would therefore introduce a separate format dependency, beyond Core's OpenRPC compatibility promise.

`file.read`, `file.write`, `file.edit`, and `machine.exec` can target local or added remote machines. File reads support line ranges and an 8 MB limit; writes accept base64 data up to 8 MB and replace the file atomically. `machine.exec` accepts an argument array or shell line and returns captured output and exit status. Its timeout defaults to 60 seconds, with a maximum of 600 seconds.

These methods could simplify wooloo's separate SSH file/Git transport, but their semantics require review before replacing it. For example, `file.write` follows symlinks, while wooloo currently validates workspace-relative paths and rejects escapes. The schema does not expose a dedicated Git worktree API. [Core #120](https://github.com/herdrdev/herdr-core/issues/120), requesting Git facts in terminal records, was still a proposal.

## Development direction and pending work

The visible direction is a terminal runtime usable by multiple clients, explicit status reporting, remote machines, and agent-to-agent coordination, with a customizable desktop app above it. This is an interpretation of the shipped architecture and repository activity, not a commitment to retire or migrate the TUI.

The following items were open at review time and must not be described as 0.1.18 features:

| Item | Proposed change or unresolved question |
| --- | --- |
| [Core #81](https://github.com/herdrdev/herdr-core/pull/81) | `terminal.report` / `hc report` for hooks without a terminal to emit OSC 7501 |
| [Core #90](https://github.com/herdrdev/herdr-core/pull/90) | Message-send metadata events for observing agent coordination |
| [Core #132](https://github.com/herdrdev/herdr-core/pull/132) | Draft `terminal.keys_if`, checking observed state before sending keys |
| [Core #71](https://github.com/herdrdev/herdr-core/pull/71) | `terminal.encode`, returning named-key encodings for attach clients |
| [Core #12](https://github.com/herdrdev/herdr-core/issues/12) | Whether reconnecting should automatically start an intentionally stopped Core |
| [Core #25](https://github.com/herdrdev/herdr-core/issues/25) | A Core-native TUI and shared structure across terminal and desktop clients |
| [Core #115](https://github.com/herdrdev/herdr-core/issues/115) | Canonical integration API, backend convergence, and migration guarantees; no response yet |

## Recommendation for wooloo

Keep Herdr TUI 0.9.5 as the current production backend. Evaluate Core in a separate proof of concept before planning a migration. The useful experiment is to discover the schema, subscribe and recover from missed events, attach and render a terminal, verify semantic input and resize behavior, and read/write files on a disposable remote workspace.

The decision should explicitly cover rendering and graphics, a no-status fallback, ownership of spaces/tabs/splits, conversation recovery, and continued access to existing TUI sessions. Core may reduce transport duplication and provide a better coordination API, but those benefits do not establish feature parity with wooloo's existing backend. Any future runtime checks must use isolated Core state and disposable repositories, leaving the user's running TUI and Core sessions untouched.

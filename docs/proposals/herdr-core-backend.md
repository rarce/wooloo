# herdr-core as a second backend

Status: proposal, 2026-11-16. Revised the same day after an adversarial review (see [Review history](#review-history)). Decisions D1–D5 are taken and the protocol part of Phase 0 is measured (see [Decisions](#decisions) and [Phase 0 findings](#phase-0-findings-2026-11-16)). The first Phase 1 gate is in place: golden tests for persisted keys (`woolooTests/PersistedKeyGoldenTests.swift`). No backend code is implemented yet.

## Goal

wooloo should work with herdr-core (`hc`) as well as the Herdr TUI server, on this Mac and over SSH. The TUI backend keeps working exactly as it does today, and stays the default until Core reaches parity. Later the TUI can be deprecated without another rewrite. Core sessions stay usable by other Core clients: the official Herdr app, the phone apps and `hc`.

Background:
- [herdr-core protocol review](../herdr-core.md)
- [Herdr app and herdr-core](../herdr-app-and-core.md): what Core adds and lacks, and the ecosystem
- [Herdr connection](../herdr-connection.md): today's TUI backend

The plan also uses two research passes from 2026-11-16:
- an inventory of wooloo's coupling to the TUI;
- a source reading of Sheprd's dual backend at [`21f2e5a`](https://github.com/sheprd-labs/sheprd/tree/21f2e5a54d5765c35370a5ed4f0d5a4562d685b1). Nothing in Sheprd was built or run.

Core facts are from herdr-core `master` (`bb8a2f77`, schema 0.1.21) unless noted.

## Requirements

1. **Both backends, local and over SSH,** in any combination per window: TUI local, TUI over SSH, Core local, Core over SSH. Core must work on a Mac or host **without the `herdr` TUI binary** (Sheprd #1261 is the failure to avoid).
2. **No behaviour change for TUI users** during the work, including performance. This is enforced by tests that CI runs (see [Testing](#testing)), not only by local benchmarks.
3. **One UI.** The sidebar, tabs, agents list, explorer, Git, editor and command palette do not fork per backend. Features a backend lacks are hidden through command availability. The terminal view gains features Core needs (client scrollback), described as explicit changes in Phase 4.
4. **Shared Core data is untrusted input** and must never be corrupted by wooloo (see [Security](#security)).
5. **Core support starts behind a setting that is off by default.** Making it the default is a later, explicit decision (Phase 7).

## Where wooloo is coupled to the TUI today

From the inventory, with file references as of `b7ef264`:

- **Model types are decoded TUI JSON.** `HerdrSnapshot`, `HerdrWorkspace`, `HerdrTab`, `HerdrPane`, `HerdrAgent` and `HerdrLayout` (`HerdrConnection.swift`, around L6–237) carry snake_case keys and TUI ids.
  - They are read directly by `ContentView` (about 124 references), `ContentCommands`, `WoolooCommandAvailability`, `HerdrDestinations`, `SpaceDrag`, `TabBarControls`, `TerminalTabDrop`, `HerdrNotifier`, `WorkspaceGitBar` and `WorkspaceFiles.location(snapshot:…)`.
  - Snapshot helpers encode TUI rules, such as zoomed panes refusing moves and only one-pane tabs moving.
- **Actions already go through `HerdrStore`.** About 61 call sites use store methods, and views never open sockets. The transport (`HerdrSocket`, `HerdrEventStream`, `HerdrSurfaceStream`, `performAction`) is private to the store. This is the main seam.
- **The terminal view draws one server-composited surface per tab, and relies on the server for more than cells:**
  - **Scrollback is server-side.** `scrollPane` only sends a mouse event, and "Herdr decides whether the program receives it or its scrollback moves" (`TerminalPaneView.swift`, around L2196–2213).
  - **Selection** is in viewport cell coordinates, with no history offset (around L1228–1233).
  - **`setSurface`** drops a surface with an unchanged `revision`/`bootID` (around L1534). `bootID` gates split drags and selection clearing (around L1222, L1535), and `projectionRevision` gates agent presentation (around L1353).
  - **Server-side vocabulary:** the context menu sends TUI action strings (around L2059–2087), and popups assume `HerdrPopup`.
  - **Cells:** `HerdrCell.modifier` uses ratatui bits, so there are no curly or coloured underlines. `RowKey` hashes the `HerdrCell` layout.
- **Terminal semantics live in the server:** key, paste and mouse encoding, mouse-mode detection, scrollback, pane layout and borders.
- **Herdr owns discovery and SSH profiles.** `HerdrMachineProfile` is decoded from `herdr machine list --json` (`WorkspaceFiles.swift`, around L6–19; `WorkspaceFiles+Transport.swift`, around L24). Sessions come from `herdr session list`, and SSH capability from the `remote-api-bridge` probe.
- **Herdr's `config.toml` is shared** by shortcuts, theme, sounds and toasts, the settings screens and `ui.agent_panel_sort`. It is validated with `herdr config check`.
- **Persisted keys embed TUI ids:**
  - `HerdrConnectionWindowState` stores `"<contextID>|<workspaceID>"` and checks the TUI config root;
  - document backups and panel layouts are keyed by the hashed Space string.
- **Size:** about 9,400 lines of TUI-specific app code in 18 files and 7,400 lines of tests. On top of that, `TerminalPaneView` is 2,451 lines.

## Lessons from Sheprd

Verified in Sheprd's source (`21f2e5a`):

- **One cell model and one painter.** Core output goes through a client emulator (`sheprd-terminal`, wrapping `alacritty_terminal`) that produces the same frames and row patches as the TUI's surfaces.
- **Two parallel paths, slowly converging.** Its `Backend`/`Terminal` traits are implemented only for Core. A shared `Session` model unifies workspaces, tabs and agents, and readers move onto it one at a time.
- **The client does terminal work for Core:** key encoding (xterm, kitty keyboard, win32-input-mode, mouse, bracketed paste), scrollback (10,000 lines by default), find and copy mode.
- **Structure lives in a local client file** (`browser-tabs.json`), keyed by host. Labels use its own namespace. It reads the app's `herdr-app` document only in its phone hub, read-only.
- **Notifications are client-side.** It watches status transitions and ignores `turn`.
- **SSH:** `ssh <target> /bin/sh -c '<script>'` with a ready banner, then `herdr-core connect`. It installs a pinned core only on request and never replaces an existing core.
- **Known problems to avoid:**
  - Core tabs filed under a TUI workspace are deleted with it, which orphans their terminals (#1009).
  - The app is unusable without the TUI installed (#1261).
  - A `+` in an SSH workspace opened a local terminal (#1079).
  - Terminal ids are unique only per core.

Sheprd is not a model for query answering or flow control. Check those against Core's documentation, not against Sheprd's choices.

## Architecture

### 1. Backend-neutral session model

Introduce plain wooloo types for what the UI shows. Working names: `WoolooSession`, `WoolooSpace`, `WoolooTab`, `WoolooPaneTree`, `WoolooPane`, `WoolooAgent`, `AgentState`.

- **Ids are `(BackendID, raw id)`.**
  - For the TUI, `BackendID` encodes the existing context, and serializes to exactly today's strings.
  - For Core, it is the core's identity from `hello` (`core.id`), not the SSH target. Two routes to one core then resolve to one backend (see §7).
- **Serialization rule.** Every persisted key keeps a version tag, and TUI keys stay byte-for-byte as they are. A golden-file test pins the existing formats before Phase 1 starts.
- **Adapter.** The TUI snapshot decodes into these types through an adapter, and the `Decodable` TUI structs become private to the TUI backend. TUI-specific rules move into that backend's capability answers.
- **Migration order.** Readers move off `HerdrSnapshot` one file at a time.

**Progress (Phase 1, first step).**
- **New Foundation-only files:**
  - `WoolooSession.swift`: the model, `BackendID`, `AgentState` and `BackendCapabilities`.
  - `HerdrSessionAdapter.swift`: `HerdrSnapshot.session(backend:)`.
  - `HerdrSnapshotModel.swift`: the TUI snapshot types, moved out of `HerdrConnection.swift` unchanged.

  Being Foundation-only, these files and `WoolooSessionTests` also build and run with Swift on Linux. All three are in the concurrency audit.
- **Ids.** Ids inside a session stay the backend's raw strings, and the session carries one `BackendID` that scopes them all, instead of a pair on every id. `WoolooSession.spaceKey` builds the persisted Space key, and `BackendID.persistentKey` keeps TUI keys unchanged.
- **Move rules.** The rules (`paneToSplit`, `spaceMoveIndex`, `tabSpaceMoveRefusal`) take their TUI restrictions from `BackendCapabilities.herdrTUI`. A test checks them against the snapshot's rules for every pair of tabs and Spaces in a fixture. The snapshot versions stay until their callers inside `HerdrStore` move.
- **First reader.** `HerdrStore.session` caches the mapping per snapshot and context. `HerdrStore.tabSpaceMoveRefusal` is the first reader moved to it.
- **Second step.** These readers now take `WoolooSession`:
  - **`HerdrNotifier`:** agent transitions, toasts and per-tab counts. `process(session:)` takes `AgentState`, and the snapshot entry point now delegates to it, so the existing notification tests check the new path.
  - **`WorkspaceGitBar` and `WorkspaceBrowserView`:** worktree Spaces, through `WoolooSpace.worktreePath` and `state`.
  - **`HerdrStore`:** `moveWorkspace`, `canSplit` and `splitTab` read the current session. Requests that read a fresh snapshot from the socket stay TUI-backend code.
- **Third step: the selection.**
  - `HerdrStore.selectedWorkspace`, `selectedTabs` and `selectedPanes` now return `WoolooSpace`, `WoolooTab` and `WoolooPane`.
  - Through them, `ContentView` (the window title and Space menu, tab row, all-tabs menu, pane grid and pane drops) and `ContentCommands` (tab cycling, rename, close and pane directory commands) read the neutral model.
  - A cached `session` read now does no work: a new snapshot, session name or machine clears the cache.
- **Fourth step: the agents list and Space folders.**
  - `HerdrStore.visibleAgents` returns `WoolooAgent`, including agents from Herdr's agent views (`HerdrAgent.woolooAgent`).
  - The agents list, the agent focus action and `AgentStatusDot` read `AgentState`. Theme colours and marks for states are tested against the status strings.
  - A Space's folder comes from the session, through `WorkspaceFiles.location(in:spaceID:…)`. The snapshot variant delegates to it, so the existing explorer tests cover it.
  - `ContentView` no longer reads the snapshot.
- **Fifth step, in the same change: the rest of the UI.**
  - `HerdrStore.displaySession` is the current session, or the last known one while disconnected, from `cachedSnapshot`, cached the same way.
  - The sidebar's Space rows and attention counts read it (`HerdrDestinationSection`, with `WoolooSpace` in its rename and close actions), as do window membership (`HerdrWindowConnection`), back navigation and notification clicks, closing panes, and the UI probes.
  - Outside the TUI backend itself (`HerdrStore` requests and events, `HerdrRuntime`, `HerdrAgentView` and the remote snapshot helper), only the snapshot entry points kept for tests remain. They delegate to the session ones.

### 2. Backend protocol behind `HerdrStore`

`HerdrStore` keeps its public API and becomes the façade of one backend connection. A `SessionBackend` protocol covers:

- **lifecycle:** connect, disconnect, reconnect state, errors;
- **structure:** a session-model publisher, create/rename/close/move Space and tab, split, zoom, swap, focus;
- **terminals:** attach a pane to a surface sink, send input, resize, focus, set split ratio, close pane;
- **agents:** rename, plus status in the model;
- **capabilities:** a set read by `WoolooCommandAvailability`. It covers zoom, cross-tab moves, worktrees, agent view, popups, config reload, scrollback location, and the terminal context-menu actions.

`TUIBackend` is today's code moved behind the protocol. `CoreBackend` is new. `HerdrDestinations.makeStore` picks the backend from the connection descriptor.

**Performance rule for both backends:** the session-model publisher must only publish on structural change, never per frame or per keystroke (CLAUDE.md, "Terminal pipeline").

### 3. Connection descriptor and hosts

- A connection descriptor gains `backend: .tui | .core`.
- `HerdrMachineProfile` is Herdr's own record decoded from `herdr machine list`, so it cannot carry the new field. **wooloo-owned host profiles arrive in Phase 3.** They hold the target, the backends found and a label. They are imported from Herdr's saved machines and from `~/.ssh/config` Hosts. TUI discovery keeps using Herdr's list, so today's behaviour does not change.
- `contextID`, `HerdrMetadataPool.key`, the window-state `spaces` keys and the document-backup keys gain a backend prefix for Core only.
- Window-state restore stops requiring the TUI config root for Core connections.

### 4. Terminal path for Core

**The surface contract.** Phase 0 writes down what a `HerdrSurface` producer must guarantee, so the Core compositor can meet it:

- `revision` increases on every change, including local-only changes such as scroll offset;
- `bootID` changes only when the backend's terminal identity resets;
- the semantics of `projectionRevision`, full frames versus row patches, and the hyperlink table;
- graphics placement, and popups (none on Core).

**Transport.**
- One framed connection per core carries channel 0 (JSON-RPC), the events channel, and attach channels.
- It runs on its own `.userInteractive` thread, like `HerdrSurfaceStream`, through `BlockingWork` with `limited: false`.
- **Every stream channel is credited, including the events channel.** Core requires credit for event channels too: `SubscribeResult.channel`, "with credit".
- **Liveness:** any received frame resets a timer. Core sends a heartbeat only "when no events are queued", so a timer that counts only heartbeats would fire falsely under load.

**Emulator.** A VT engine per live terminal, fed raw output, emits `HerdrSurface` cells in the existing colour encoding and modifier bits. It also produces the cursor, hyperlinks, and kitty images as `HerdrGraphic`. It must parse every byte before credit is returned, so its throughput bounds the stream (256 KiB window, with a repaint beyond 4 MiB behind). It must emit dirty rows, not full surfaces per chunk, to keep row reuse.

**Query answering.** Measured in Phase 0 on core 0.1.21 (see [Phase 0 findings](#phase-0-findings-2026-11-16)):
- **Core answers most queries itself,** with or without a viewer: DA1, DA2, XTVERSION (`ghostty`), DSR, OSC 4/10/11 colours, DECRQM 2048 and 2026, kitty keyboard flags, XTWINOPS 14t/16t/18t and DECRQSS.
- **Core forwards two queries to the viewer** in the measured set: the kitty graphics support query and XTGETTCAP. Without a viewer, they go unanswered.
- So the emulator answers kitty graphics and XTGETTCAP queries, and any other query Core forwards, as `AUTOMATIC_INPUT`, tagged at their source in the emulator rather than by inspecting bytes.
- `AUTOMATIC_INPUT` is sent only when both `hello.features` and the attach result confirm it; both did on 0.1.21. Otherwise replies go as DATA, which takes size ownership and resets the quiet period, a documented legacy behaviour.
- Only one viewer per terminal answers queries (the active viewer), so the program does not receive duplicate replies.

**Display facts.** `FACTS` carries cell pixel size *and* colours. In Phase 0, Core answered OSC 10 and 11 with its own defaults (white on `#282c34`) when the viewer had sent none. Programs would then see Core's colours instead of wooloo's theme, so the colours are required. They are sent at attach (`display`) and again when wooloo's theme changes.

**Compositor.** Core has no tab layout. A wooloo compositor lays out each tab's pane tree.
- It draws split borders the way Herdr does, and fills `paneRects`, `paneInnerRects`, `splits`, `focusedPaneID` and `mouseReportingPaneIDs` from emulator state.
- It emits one `HerdrSurface` per tab into the existing mailbox.
- A terminal has one size: the last active viewer owns it. When a window shows a terminal whose grid differs from its rect, the compositor shows the grid as it is, clipped or padded. It must never resize the terminal from a passive window.

**Input.**
- A per-backend input encoder replaces the hard-wired `SurfaceWriter.input`. The TUI backend keeps semantic events.
- The Core backend encodes keys, paste and mouse from the emulator's modes: cursor keys, kitty keyboard flags, bracketed paste, mouse reporting, and win32-input-mode for Windows hosts. Core identifies itself through XTVERSION and assumes Ghostty defaults, so programs will use the kitty keyboard protocol, graphics and synchronized output.
- Prefix and direct shortcuts are handled in wooloo, but their bindings currently come from Herdr's `config.toml`; on Core they come from wooloo's settings (§10).

**Explicit `TerminalPaneView` changes (Phase 4):**
- a viewport offset into client history, with the wheel scrolling local history unless the program reads the mouse;
- selection with history coordinates, drag autoscroll, a scroll indicator, and find in terminal;
- a context menu driven by capabilities instead of TUI action strings;
- no popup path for Core.

These changes must not alter TUI behaviour: on the TUI the offset stays zero, and the existing paths apply.

**Attach policy.** This is decided in Phase 0 from measurements, choosing between:
- keeping emulators of hidden tabs alive, which costs memory per emulator and continuous parsing;
- reattaching on tab switch with `history`, which replays only the main screen.

Metrics: flood throughput, tab-switch latency with 10,000 lines of history, and memory per emulator.

**Viewers.**
- The focused window's pane is the active viewer and sends RESIZE and FOCUS.
- Other windows showing the same terminal attach with `observe`, adding `resize_notifications` when both `hello` and the attach result confirm it. Without it, they track size from size events.

### 5. Structure for Core sessions

Core keeps terminals, not layout, so Spaces, tabs and pane trees need a store.

**What is shared, and what is not.**
- Shared, in the chosen store: Space names and order, each Space's folder, tab names and order, and the pane tree (terminal ids and split directions).
- Local per window: zoom, focus, selection, and split ratios while dragging. A ratio is written once when the drag ends, debounced, never per frame.
- Each write emits a doc event to every subscriber, including the official app and phones, so writes stay rare.

**Store (decision D2).** Options:
- **(a)** A private `wooloo` document in the core, written only with compare-and-set on its version. It works across Macs and over SSH, and keeps structure on the server as the TUI does.
- **(b)** The official app's `herdr-app` document. It would share structure with the app and phones, and three community TUIs already use it. Its format is not a contract ([herdr-app #43](https://github.com/herdrdev/herdr-app/issues/43), open).
- **(c)** A local file per host, as in Sheprd. It is simple, but works for one Mac only.

Proposed for Phase 0: read `herdr-app` read-only from the start, to measure how complete it is. Store wooloo structure under (a), with a schema version, and preserve unknown fields when writing. Reconsider (b) if #43 is answered. In every option, wooloo never writes `herdr-app` unless that format becomes a contract.

**Labels.** Every terminal wooloo starts carries `wooloo.space` and `wooloo.tab`. Labels cannot rebuild order or the split tree; they only let an orphaned terminal be refiled under the right Space.

**Reconciliation.** This is a written algorithm with tests. It runs after subscribe, reconnect, `missed`, a remote-machine reconnect, and each `doc` event for the store.
- The terminal set from Core is the truth for which terminals exist. The document is the truth for arrangement. Labels are hints.
- Document entries whose terminal is gone are dropped from the tree. A finished terminal stays visible as finished until removed (`terminal.rm`); `hidden_finished` records are not shown.
- Live terminals in no tab go to an "Unfiled" Space per core, placed by their labels when present.
- `terminal.run` and `doc.set` are not atomic. A terminal started just before a failed write is caught by the next reconciliation through its labels.
- A conflicting write is retried after a refetch and a re-merge, never blindly.
- **Corruption:** if Core loses its documents (a broken `docs.json` is renamed, and the core starts with empty documents), terminals survive, and reconciliation rebuilds Spaces from labels into Unfiled.

**Doc events.**
- Doc events carry only the name and version, so the document is refetched with `doc.get`.
- wooloo needs every terminal, so it uses one subscription without filters, which already receives `doc` events on 0.1.21. It filters `type: doc, name: <store>` on the client.
- The `docs` subscription parameter is *not* used: naming documents narrows the subscription to those documents ("documents alone hear only them", OpenRPC). Terminal, parent and label filters exclude doc events.

**Required methods** add `terminal.rm` and `terminal.keep` to the set in §7.

### 6. Agents and notifications on Core

- **Agent state** comes from OSC 7501 `status.state` and `status.app`:
  - `blocked` and `error` map to blocked;
  - `working` maps to working;
  - otherwise **done** when `turn > herdr.seen`, else idle, following [labels.md](https://github.com/herdrdev/herdr-app/blob/master/docs/labels.md).
- A status is dropped when the foreground process is no longer the reporting agent. Terminals without a report show as plain terminals.
- **Writing `herdr.seen`** follows labels.md:
  - only to raise it, or when it is missing;
  - once per turn;
  - only when the agent is really in front of someone: the window active and the pane drawn, not covered.
- **Mark unread** writes `turn - 1`. This is read and written from the start of Core support (Phase 5), matching [herdr-app-and-core.md](../herdr-app-and-core.md).
- **Notifications.** `HerdrNotifier` takes transition events from the neutral model: any state to blocked, and done when `turn` rises. Settings are wooloo's (§10), with `[ui.sound]`/`[ui.toast]` as the source on TUI connections.

### 7. Reaching a core, local and over SSH

**One transport:** `hc connect --session <name>` (or `herdr-core connect`) over a process's stdio.
- **Locally,** it is spawned directly, with no reimplementation of endpoint resolution. A direct socket can come later, once the macOS path is verified (Q1).
- **Over SSH,** it uses `ssh <target> /bin/sh -c '<script>'`.
  - The script searches `PATH` and known prefixes (`~/.local/bin`, Homebrew, Nix), prints a ready banner, then execs `connect --session`.
  - Exit 127 means no core.
  - SSH arguments and session names are built and validated by the same code as `HerdrRemoteBridge`: its session regex, rejection of a leading `-`, `WorkspaceFiles.quote`, and `ServerAliveInterval=10`, `ServerAliveCountMax=2`. That code is factored out in Phase 3, not copied.

**SSH session budget.**
- The long-lived `connect` stream must never become the ControlMaster. If it did, killing it on reconnect would drop every multiplexed file and Git session. Phase 3 either starts a dedicated master (`ssh -MNf`) before the stream, or runs the stream with `ControlMaster=no` against an existing master. Today `WorkspaceFiles` uses `ControlMaster=auto`, so whichever command runs first becomes the master. The choice is made after testing.
- Budget per host: `BlockingWork.machineLimit` (8) + one Core stream + TUI bridge children ≤ `MaxSessions` (10 by default). Mixed windows on one host may need a lower `machineLimit` for that host, or a separate master for streams. Phase 3 measures and documents this.

**Detection without side effects.**
- The CLI "starts a background core when it needs one" (Core `docs/security.md`). Over SSH, Core may also try to enable lingering, but only when it runs under the user's systemd manager.
- **Phase 0 found that `hc server status` starts a core on 0.1.21:** its reply showed `uptime_ms: 5` and a new socket. The 0.1.12 changelog line "Checking status no longer starts a core" does not hold. `hc --version` started nothing.
- A host is therefore probed only with `hc --version` (found or not, and which version). Whether a core is running is reported only by connecting.
- `connect` runs only when the user opens a Core connection. This follows the same rule as today's "never install software as a side effect of selecting a machine" (`HerdrRemoteBridge.swift`, around L153–167).

**Core machines.**
- A core lists terminals "here and on connected machines" (`machine/t7`), and events and `missed` are machine-scoped. A user of the official app will have machines added. If wooloo also reaches that machine over its own SSH, it would see the same terminal twice: `rohan/t7` through the local core and `t7` directly.
- Proposed default: identify every core by `core.id`. Hide machine-prefixed terminals from a core whose machine wooloo also reaches directly, and show each machine's terminals only through its own core.
- Using Core's machines *instead* of wooloo's SSH is decision D5. It would cut SSH transports, but makes wooloo depend on a local core for remote work.

**Handshake.**
- `hello` with `framed: true`, generation 1, a minimum core version (Q2), and a required method set: `terminal.run`, `.attach`, `.list`, `.kill`, `.label`, `.rm`, `.keep`, `events.subscribe`, `doc.get`, `doc.set`.
- `automatic_input` and `resize_notifications` are used only when advertised. `doc.get`/`doc.set` without `on` address the connected core.

**Events.**
- wooloo keeps the last `seq`. On `missed`, it replaces the terminal set, drops older events, and refetches documents.
- After a reconnect, it takes a fresh snapshot and refetches documents. While reconnecting, views are stale (last frame dimmed, input withheld), then reattach with history.

**Sessions.** A Core connection names a session. Tests and development always use an isolated session (`wooloo-ui-test`), never `default`.

### 8. Runtime and setup

- **No TUI dependency.** A Core-only Mac or host must work without the `herdr` binary: no `herdr machine list`, `session list` or `config check` on the Core path. Host profiles and settings come from wooloo (§3, §10). This lands in Phase 3, not later.
- **Installing Core** happens only on explicit user action, and never replaces or upgrades an existing core; Core's own updater owns that.
  - Remote hosts get a pinned, SHA-256-checked build in `~/.local/bin`, in the style of `scripts/bundle-herdr.sh`.
  - Core releases have no signature independent of the release service (Core `docs/security.md`). The pinned hash in wooloo's source is the integrity check. A later `hc machine add --install` from the official app may replace that copy, and wooloo must tolerate it.
  - On this Mac, prefer the official installer. Since 0.1.18 the macOS core is its own launchd-started app, which makes bundling it harder (D3).
- **Setup wizard.** `HerdrSetupView` offers "Herdr TUI (included)" and "herdr-core" once Core is past beta.

### 9. Files and Git

- `WorkspaceFiles` keeps wooloo's own SSH for both backends. Core's `file.*` and `machine.exec` are not adopted: `file.write` follows symlinks where wooloo rejects escapes, and there is no Git API.
- For Core Spaces, `WorkspaceFileLocation` takes its **machine from the window's connection**, never from shared Core data. The Space folder comes from the structure store and is validated (see [Security](#security)).
- Worktrees on Core: create with Git directly, then open a Space on the folder. The TUI keeps `worktree.open`.

### 10. Settings independent of `config.toml`

Theme, shortcuts (prefix and direct bindings), and sounds and toasts move to a wooloo settings file, seeded from Herdr's `config.toml` when it exists. This lands in Phase 3, because Core connections need shortcuts from day one.

- TUI connections keep editing `config.toml` exactly as today.
- Core connections use wooloo's file, plus `~/.config/herdr-core/config.toml` for `shell`, `draft_wait`, `notes_quiet` and `restore_screen`.
- Herdr-only screens show only for TUI connections.

## Security

Core has "no separate API password or per-client permission check" (Core `docs/security.md`). Any program in any terminal of that core can write documents and labels. wooloo therefore treats the structure store, `herdr-app` and all labels as **untrusted input**:

- **Decoding:** defensive, with size caps (a document is at most 1 MiB), a schema version, and unknown fields preserved but never acted on.
- **Machines and folders:**
  - The machine for files, Git and SSH comes from the window's connection, never from a document or label.
  - Folders must be absolute paths on that machine, and are opened through the same validation `WorkspaceFiles` applies today.
  - A label never names a host.
- **Names** are display-only: they are never used in shell commands, and are quoted if ever passed on.
- **Writes** are compare-and-set only, and only to wooloo's own document and the documented `herdr.seen`/`herdr.pinned` labels.
- **Installs** are user-initiated and hash-pinned (§8). Detection never runs a command that starts a core (§7).

## Phases

Each phase ends with:
- all unit tests passing in CI;
- the CI-enforced TUI gates in [Testing](#testing) unchanged;
- local gates (view snapshots, `terminal-bench`, `terminal-e2e`) run by the change's author and recorded in the pull request, as CLAUDE.md requires for terminal changes.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| 0. Proof of concept and decisions | On a real `hc` (macOS and a Linux SSH host, isolated session): socket path, `connect`, which commands start a core, `hello` features, the attach paint, `missed`, the query table (forwarded versus answered), doc events, and Core machines. Prototype D1 engines against recorded Core output, measuring flood throughput, tab switch with 10,000 lines, and memory. Read `herdr-app` read-only. Write the surface contract. Decide D1–D5 | Decisions and measurements written in this file. Questions Q1–Q3 answered. A go/no-go for Phase 3 onward |
| 1. Neutral model | Golden-file tests for persisted keys *first*. `WoolooSession` types, the TUI adapter, readers moved off `HerdrSnapshot`, capabilities in `WoolooCommandAvailability` | CI gates unchanged; golden files byte-identical |
| 2. Backend protocol | `SessionBackend`, `TUIBackend` as a move of existing code, per-backend input encoder, backend kind in descriptors (TUI keys unchanged), new files added to `MIGRATED` in `scripts/concurrency_audit.py` | Same as Phase 1, plus local benchmarks within baselines |
| 3. Core transport, hosts and settings | Framed connection with credit and liveness, `hello` gating, event recovery, local and SSH `connect` with shared SSH argument code, the session budget, wooloo host profiles, wooloo settings, the no-`herdr`-binary path, `FakeCoreServer`. Core behind a setting that is off by default | Store-level tests against `FakeCoreServer`; a live run against isolated cores, local and SSH, on a machine without `herdr` |
| 4. Core terminals | Emulator to `HerdrSurface` under the surface contract, query answering, compositor, input encoding, the `TerminalPaneView` changes (history, selection, find, capability menu), attach policy, reconnect and stale view, multi-window observe | Terminal conformance fixtures; a Core benchmark next to `terminal-bench`; TUI gates unchanged; manual checks of vim, less, htop, an agent CLI and kitty images |
| 5. Core structure and agents | Structure store and reconciliation, labels, splits, zoom, moves, the Unfiled Space, agent states, `herdr.seen`/`herdr.pinned`, notifications, Core detection and opt-in install | Reconciliation tests, including corrupted and empty documents and concurrent writers; two windows or two Macs on one core stay consistent |
| 6. Interop and beta | Adoption of `herdr-app` spaces (read-only, or shared if #43 allows), setup wizard option, docs and README | Beta in a release, setting off by default; published parity matrix |
| 7. Default and deprecation | Decide whether new connections default to Core; TUI deprecation messaging and removal criteria | Separate decision, against the triggers in [herdr-app-and-core.md](../herdr-app-and-core.md#decision-triggers) |

Phases 1 and 2 are worth doing even if Core support stopped there. They separate the UI from one wire protocol, and they make TUI forks with different capabilities easier to support.

## Parity matrix (initial)

| Feature | TUI today | Core plan |
| --- | --- | --- |
| Spaces, tabs, splits, zoom, swap, moves | Server | Structure store (shared) and local view state; compositor (Phase 5) |
| Terminal rendering, cursor, links | Server cells | Emulator to the same cells (Phase 4) |
| Kitty images | Server blobs | Emulator; viewer answers capability queries |
| Keys, paste, mouse | Server encodes | wooloo encodes (Phase 4) |
| Scrollback, find in terminal | Server | Client history plus new `TerminalPaneView` support |
| Agent status | Detection and integrations | OSC 7501 and `turn`; no status without a report |
| Unread and pinned | wooloo local | `herdr.seen`/`herdr.pinned` labels (Phase 5) |
| Notifications | `[ui.sound]`/`[ui.toast]` | wooloo settings |
| Resume after reboot | TUI resumes supported agents | Not available ([Core #15](https://github.com/herdrdev/herdr-core/issues/15)); kept terminals get shells |
| Worktrees | `worktree.*` | Git directly, then a Space on the folder |
| Agent view, popups, popup titles | Server | Not offered |
| Settings | `config.toml` | wooloo settings plus Core's `config.toml` |
| SSH | `remote-api-bridge` | `hc connect` over SSH, with shared argument code |
| Files and Git | wooloo SSH | Unchanged; machine from the connection only |
| Mobile companion and Remote Access | `remote-api-bridge` | Separate decision (D4) |

## Decisions

Decided by the maintainer on 2026-11-16.

- **D1, VT engine: libghostty-vt.**
  - It is the engine of the official app and Heeler, and Core identifies itself as `ghostty` (XTVERSION) and assumes Ghostty's defaults. Using the same engine gives the closest behaviour to what programs expect.
  - Cost: a C API built with Zig, which must fit the Xcode build, the universal (arm64 and x86_64) release, the notices (`scripts/third-party-notices.py`) and Swift 6 concurrency.
  - The first Phase 4 task is a build spike on a Mac: Zig version pinning, a static library per architecture, and a module map. It also measures throughput, dirty-row output and memory.
  - If the build cannot be made reliable, SwiftTerm's engine used headless is the fallback. [swiftterm-evaluation.md](../swiftterm-evaluation.md) covers only its `TerminalView`, so that use would need its own check.
- **D2, structure store: a private `wooloo` document in the core, plus `herdr-app` read-only** ((a) with read-only (b) in §5). wooloo never writes `herdr-app` unless herdr-app #43 makes its format a contract.
- **D3, local runtime: a user-installed core.** wooloo detects `hc` and links to the official installer when it is missing. It does not bundle a core, and Core's own updater owns updates. On remote hosts, wooloo installs a pinned build only on explicit user action (§8).
- **D4, mobile: the Android companion stays TUI-only.** `RemoteAccessLink` and the Android parser do not change. This is revisited in Phase 6 against the official phone apps.
- **D5, remote cores: wooloo's own SSH to each host's core.** Every core is identified by `core.id`. Machine-prefixed terminals (`machine/t7`) are hidden from a core whose machine wooloo also reaches directly.

## Phase 0 findings (2026-11-16)

Measured against herdr-core 0.1.21 (`linux-x86_64` release, SHA-256 checked against `releases.herdr.dev/core/latest.json`). The core ran in a temporary isolated environment: its own `HOME`, `XDG_RUNTIME_DIR`, `XDG_STATE_HOME` and `XDG_CONFIG_HOME`, and `HC_SESSION=wooloo-ui-test`. With its own runtime directory, Core used neither systemd nor lingering (`platform/systemd.rs`, `manager()`). The core was stopped and its files removed afterwards. [`scripts/core_protocol_probe.py`](../../scripts/core_protocol_probe.py) reproduces the protocol part on any machine, including a Mac.

The macOS-specific checks are still open: the socket on a Mac, the launchd-started "Herdr Core" app, and the libghostty build.

- **Q1, socket path and side effects.**
  - On Linux, the socket was `$XDG_RUNTIME_DIR/herdr-core/<session>.sock`.
  - Source (`platform/unix.rs`, `endpoints`): without `XDG_RUNTIME_DIR` and without `/run/user/<uid>` (macOS), the socket goes in the session's state directory, `~/.local/state/herdr-core/<session>/`. Not yet checked on a Mac; the plan does not depend on it, because it uses `hc connect`.
  - Side effects: `hc --version` started nothing. **`hc server status` started a core** (see §7). Other commands were not checked separately, because a core was already running when they ran.
- **Q2, version and features.**
  - `hello` (plain and framed) reported version 0.1.21, generation 1, and features `framed`, `attach`, `events`, `status`, `shell`, `resize_notifications`, `automatic_input` and `restart_environment`, plus `methods`.
  - `core` was `{id, name}`, with the host name as `name`. `id` is the identity used for D5.
  - Proposed minimum: 0.1.21, the version measured. Lower versions are refused with a message linking to `hc update`.
- **Q3, queries.** See the table in §4 ("Query answering").
  - Only the kitty graphics query and XTGETTCAP reached the viewer.
  - The attach result confirmed `automatic_input: true`.
  - Window-size answers (14t, 18t) followed the viewer's size (100×30). Headless, they used Core's 200×120 default.
- **Events and documents.**
  - An unfiltered subscription returned `channel` and `seq` and received `doc` events carrying only `{name, version}`.
  - A stale `doc.set` failed with `data.kind: "conflict"` and the hint "read doc.get and retry with its version".
  - Terminal events seen: `created`, `size`, `foreground`, `finished`, `removed`.
  - A heartbeat arrived as an event carrying the current `seq` and no `type`.
  - A terminal record includes `identity: "ghostty"`, `screen`, `turn`, `status` and `labels` (an object).
- **API shapes the code must follow.** `terminal.run` returns the terminal as `address` (for example `t2`). `labels` is a JSON object, not a list of `k=v` strings. The attach result carries the full terminal record.

## Open questions

- **Q1–Q3** are answered in [Phase 0 findings](#phase-0-findings-2026-11-16), except the socket path on a Mac, which is still to be verified there.
- **Q4.** How wooloo and the official app coexist on one core until D2 is settled. wooloo would see the app's terminals as Unfiled or adoptable, and the app would see wooloo's terminals without wooloo's structure.
- **Q5.** Whether the binary name is stable. The installers provide both `hc` and `herdr-core`.

## Risks

- **Emulator fidelity and cost.** It replaces work the TUI server does. If Phase 0 shows it cannot meet the baselines with client scrollback, a separate Core terminal view is the fallback, and the plan is revisited.
- **Moving contracts.** Core's API is 0.x. Behavioural defaults (#33), the integration strategy (#115), resume (#15) and `herdr-app` (#43) are unsettled.
- **Shared data.** Concurrent writers and untrusted content require compare-and-set, reconciliation and the rules in [Security](#security).
- **SSH session limits** in mixed TUI and Core windows on one host.
- **Upstream TUI decisions** can make Phase 7 urgent. Phases 3–4 make a minimal Core path (single-pane tabs, local and SSH, no TUI binary) usable early.

## Testing

**CI-enforced TUI gates**, added in Phase 1:
- golden files for persisted keys;
- a replay of recorded TUI surface traces through the decoder and layout (the existing trace-replay harness);
- the existing `HerdrStoreTests` and surface suites.

View snapshots and `terminal-e2e` stay local, as CI skips them, and their results go in each pull request.

**New tests:**
- **`FakeCoreServer`:** JSON-RPC 2.0 plus framed channels, scripted events, `missed`, CLOSE reasons, and credit accounting on stream and event channels. It sits beside `FakeHerdrServer`, and store-level tests are parameterized by backend.
- **Emulator conformance:** recorded Core attach streams (vim, less, htop, an agent CLI, kitty images) replayed into the emulator and compared with fixtures and, where both exist, with the TUI's surfaces for the same program. Query-reply tagging and the single-answerer rule are covered.
- **Input encoding** tables for each keyboard mode, beside `TerminalInputTests`.
- **Reconciliation:** missing and extra terminals, finished terminals, conflicts, an empty or corrupted document, hostile content, and labels without a document.
- **SSH** with the fake `ssh` (`WorkspaceFiles.sshExecutable`): shared argument validation, the ready banner, exit 127, reconnect without killing the master, and side-effect-free detection.
- **Live tests** behind an environment variable, like `TEST_RUNNER_WOOLOO_RUNTIME_E2E`, against a real core in an isolated session, local and over SSH, including a machine without `herdr`.
- **Benchmarks and audit:** a Core benchmark beside `scripts/terminal-bench.sh` (emulate, composite, draw; flood and tab switch). New files go into the concurrency audit's `MIGRATED` set from their first commit.

## Review history

**2026-11-16, adversarial review** of the first draft, checked against wooloo `b7ef264`, herdr-core `master`, herdr-app `labels.md` and Sheprd `21f2e5a`. The two protocol findings (query answering and the `docs` filter) were re-checked against Core's schema. Changes made:

- **Terminal path:**
  - Query answering corrected: replies are forwarded to the viewer and sent as `AUTOMATIC_INPUT`, with one answering viewer per terminal.
  - Display colours in `FACTS` are required.
  - The events channel is credited, and liveness counts any traffic.
  - "`TerminalPaneView` unchanged" replaced by a surface contract and an explicit list of view changes, with an attach policy and Phase 0 measurements.
- **Structure and events:**
  - The `docs` subscription filter removed; documents are refetched on four triggers.
  - The shared store is limited to structure; view state stays local, ratio writes are debounced, and a reconciliation algorithm was added.
  - `terminal.rm` and `terminal.keep` required.
  - D2 widened to include `herdr-app`, read-only from the start.
- **Hosts, SSH and phasing:**
  - Core machines and identity by `core.id` added, with D5.
  - Side-effect-free detection.
  - SSH argument code shared with `HerdrRemoteBridge`, `ServerAliveInterval` added, the stream kept from becoming the ControlMaster, and a session budget.
  - Host profiles, settings and the no-TUI-binary path moved to Phase 3.
  - Golden-file and trace-replay CI gates; new files in the concurrency audit from their first commit.
  - Phase 0 recast as the proof of concept that [herdr-core.md](../herdr-core.md) asks for before a migration plan.
- **Security and docs:**
  - A Security section treating shared data as untrusted.
  - Install integrity relies on wooloo's pinned hash.
  - `herdr.seen` write rules.
  - The SwiftTerm reference corrected.

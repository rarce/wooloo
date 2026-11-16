# Herdr app and herdr-core: what they mean for wooloo

Reviewed on 2026-11-16 from upstream sources (GitHub repositories, release notes, issues) and herdr.dev. Nothing was installed or run. This follows the [herdr-core 0.1.18 protocol review](herdr-core.md) of 2026-11-05, which remains the reference for Core's protocol; this note covers what changed since then, the desktop app, and the consequences for wooloo's development. The current wooloo backend is described in [Herdr connection](herdr-connection.md).

## Summary

- Herdr now has three products with two incompatible backends. The **desktop app** (repository `herdr-app`, shipped under the name "Herdr") runs on **herdr-core** (`hc`). The **Herdr TUI** (`herdr` 0.9.x), which wooloo bundles and speaks to, has its own server. They do not share sessions, agents or APIs.
- herdr.dev is now app-first. The TUI is "the original Herdr" and "keeps working", with no deprecation or migration statement. Whether the TUI moves onto Core is still undecided upstream.
- Upstream activity has moved to Core and the app. Core shipped 0.1.19–0.1.21 in eight days; the app shipped 0.1.14–0.1.16. The TUI's last release is 0.9.5 (2026-10-14) and its `master` has no commits after 2026-10-29.
- Every contract wooloo uses is TUI-only: the JSON socket API and its events, the `shell.surface.v1` cell endpoint, `config.toml` and its key bindings, screen-based agent detection, `remote-api-bridge`, and the session directory layout. None of them exists in Core.
- The app overlaps with most of wooloo's scope, and the official phone apps work only with Core. wooloo's distinct position is a native macOS client for TUI sessions, with deeper Git and editor features. That position depends on the TUI staying alive.
- Core is not a superset of the TUI protocol. It adds feature negotiation, multiplexed streams with flow control, event recovery, program-reported status, labels, shared documents, agent hierarchy, and machines/files in the API. It drops workspaces, tabs, cell surfaces and detection.
- The community is filling the gap. Several open-source TUIs run on Core and share the app's `herdr-app` document. Sheprd, a native GPUI client, already speaks both backends. Forks such as Herdr Extended keep the TUI protocol alive.
- Recommendation: keep the TUI backend, stop counting on upstream TUI changes, and turn the Core proof of concept from [herdr-core.md](herdr-core.md) into planned work with explicit decision triggers (below).

## State of the three projects

| | Herdr TUI (`herdr`) | herdr-core (`hc`) | Herdr app (`herdr-app`) |
| --- | --- | --- | --- |
| Role | Terminal multiplexer with its own server | Headless terminal runtime ("Core draws nothing") | Desktop client of Core |
| Latest release | 0.9.5, 2026-10-14 | 0.1.21, 2026-11-12, plus unreleased work | 0.1.16, 2026-11-14 |
| Activity since 2026-11-05 | No commits on `master` after 2026-10-29; a monthly stale-issue job was added on 2026-10-28 | 83 commits from the 0.1.18 release commit to `master` (2026-11-15) | Several fixes a day |
| Distribution | herdr.dev/install.sh, Homebrew `herdr`, GitHub releases | releases.herdr.dev/core, `hc update` | releases.herdr.dev/app, `Herdr.dmg`, Homebrew cask `herdr-app` |
| Platforms | macOS, Linux, Windows | macOS, Linux (x86_64, aarch64), Windows x86_64 | macOS Apple Silicon only (Intel from source, [app #140](https://github.com/herdrdev/herdr-app/issues/140)), Linux, Windows |

Sources: the repositories' READMEs, tags and commit history ([herdr](https://github.com/herdrdev/herdr), [herdr-core](https://github.com/herdrdev/herdr-core), [herdr-app](https://github.com/herdrdev/herdr-app)) as of 2026-11-16. The TUI's quiet period may be a pause; nothing upstream calls it an end of development.

### Positioning on herdr.dev

- The home page presents the app: "Herdr is an app for running coding agents that you shape by asking." Its main link is "Download Herdr", and the TUI is a secondary link to herdr.dev/tui.
- Its FAQ: "Herdr TUI is the original Herdr: a terminal app with its own server. This is a new, separate program built on herdr-core." Also: "They don't share agents, so what runs in one doesn't show up in the other." Also: "Herdr TUI keeps working, and everything for it is at herdr.dev/tui."
- herdr.dev/core calls Core the runtime under the app and invites other clients: "The Herdr app is one client. The same API is open to yours."
- herdr.dev/mobile offers official iPhone, iPad and Android apps that connect over SSH. They work with herdr-core ("Herdr TUI isn't supported").
- There is no TUI-to-app migration guide and no deprecation notice.

### Direction is still undecided

- [App #63](https://github.com/herdrdev/herdr-app/issues/63), "Share agents between Herdr TUI and the app?", was closed. The maintainer's answer (2026-10-29) says the backends are separate on purpose, the app will not attach to a TUI server, and "whether the tui moves onto herdr-core later is still open". Users asked for an import path or a decision; no later answer.
- [Core #115](https://github.com/herdrdev/herdr-core/issues/115) asks for the long-term integration API and a migration strategy for downstream tools. It is open with no replies.
- [Core #25](https://github.com/herdrdev/herdr-core/issues/25) asks for a terminal UI over Core. Remote-first TUI users describe losing `herdr --remote` (one session on a server, any client attached, sidebar with agent states). A third party published [hc-tui](https://github.com/followcat/hc-tui) v0.1.0 (2026-11-09), which reads the app's `herdr-app` document for spaces and tabs.
- [Core #33](https://github.com/herdrdev/herdr-core/issues/33) (what the compatibility check promises) is open with no replies.

The issues show users moving from the TUI to the app ("I migrated from the TUI to the app today"). The main thing they say they lose is agent conversation resume after a reboot ([Core #15](https://github.com/herdrdev/herdr-core/issues/15)).

## Core since the 0.1.18 review

The method list in the OpenRPC schema is unchanged from 0.1.18 to `master`: no methods were added or removed. Changes that matter for a future wooloo client:

- **`events.subscribe` accepts `docs`** (unreleased, [#273](https://github.com/herdrdev/herdr-core/pull/273)). A subscriber can name the documents it wants, or a prefix ending in `*`. A client following only `herdr-app` no longer receives every document change.
- **`server.restart` accepts `environment`** (0.1.20, `hc server restart --fresh`). Restarts and updates keep the environment the core started with, unless asked for a fresh one.
- **macOS service model** (0.1.18–0.1.20). The core is its own app, "Herdr Core", started by launchd separately from the window. It asks once for local network and microphone access. Holders register as background apps. This is the same problem wooloo solves for the TUI with its own launchd job (`HerdrRuntime.swift`).
- **Kept-terminal recovery.** `restore_screen = true` shows a lost program's last screen above the new shell. Recovery still starts a shell and never reruns the program. A recovery-command prototype for #15 exists only on a fork.
- **Attach fixes.** The primary screen is replayed when attaching on the alternate screen. A character cut by the first paint is kept. Observers no longer resize. Image queries are answered by the viewer. Any client that renders Core's attach stream depends on these.
- **Status fixes.** Status resets when an agent exits back to the shell, and is announced after crash adoption. `terminal.list` always includes `machines`.

## What Core adds over the TUI protocol

Compared here: the TUI 0.9.5 API as reported by `herdr api schema --json` (protocol 22, schema version 1, 128 method and event names) and its `herdr-client.sock` endpoint, against Core's OpenRPC schema on `master` (32 methods). Neither is a superset of the other. Core drops the TUI's structure and presentation and adds the following.

| Area | Core | Closest in the TUI |
| --- | --- | --- |
| Discovery and compatibility | `hello` negotiates generation and features. `rpc.discover` returns the whole API as OpenRPC. CI rejects structural breaks against `released.openrpc.json` | `herdr api schema --json` exists, but has no feature negotiation and no published compatibility check |
| Multiplexed transport | One framed connection carries JSON-RPC on channel 0 and any number of terminal streams, with per-stream CREDIT flow control. A stream over 4 MiB behind gets a repaint instead of the backlog, and a stalled stream blocks nothing else | Two sockets: JSON on `herdr.sock` and one surface stream per tab on `herdr-client.sock`. Frames are dropped when a client lags (see `TODO.md`) |
| Size ownership and viewers | The last active viewer owns the size. `observe` viewers never type or resize. Optional resize notifications. Terminal-generated replies are marked `AUTOMATIC_INPUT` so they do not count as human activity | The server lays out panes for its clients; no observe-only role |
| Event recovery | Events carry sequence numbers, a heartbeat every 15 s, and `missed` with a replacement snapshot when a subscriber lags. Subscriptions filter by terminal, labels, `children_of` and (unreleased) `docs` | `events.subscribe` without sequence or loss signal. wooloo takes a fresh `session.snapshot` after each event for this reason |
| Program status protocol | OSC 7501: the program reports `working`/`blocked`/`done`/`error` in-band, and the core keeps a `turn` counter of finished work. Independent of agent brands | Screen detection plus per-agent integrations (`integration.install`) and `pane.report_agent`. More agents work without changes, but status depends on Herdr knowing them |
| Free-form labels | `terminal.label`: arbitrary `key=value`, never interpreted, filterable in `terminal.list` and subscriptions. Clients build shared state on them (`herdr.seen`, `herdr.pinned`, `herdr.space`) | `pane.report_metadata`, `workspace.report_metadata` |
| Shared client documents | `doc.get`/`doc.set`: opaque versioned JSON up to 1 MiB, compare-and-set on the version, persisted across restarts, per machine with `on`. This is where the app keeps spaces and tabs | None: the server owns the structure itself |
| Agent hierarchy | Terminals started inside a terminal become its children: `parent`, `die_with_parent`/`outlive_parent`, `wait --children`, notes to the parent when a child needs attention or ends | `agent.start`, `agent.prompt`, `agent.wait` act on agents; no parent/child lifetime |
| Templates | `templates.list` and `terminal.run` with a template name: a command plus a role prompt | None |
| Draft-aware input | `terminal.send` waits up to 60 s for a person to send or clear an unfinished draft (`draft_wait`). `if` conditions on observed state. `terminal.interrupt` reports what it observed. `terminal.keys` encodes named keys for the program's current keyboard modes | `pane.send_text`, `pane.send_keys`, `agent.send_keys` send immediately |
| Pasted files | `terminal.put` writes bytes to a file beside a terminal, on its machine, for its program to read (a pasted image) | None; wooloo pastes paths |
| Lifetime | Finished terminals stay readable until `terminal.rm`. `keep` restarts a lost terminal as a shell, optionally under the old screen (`restore_screen`). `server.restart` adopts running programs and keeps the environment | The TUI restores layouts and resumes supported agent conversations (`pane.report_agent_session`) but not processes. `server.live_handoff` covers planned upgrades |
| Machines in the API | `machine.add`/`list`/`connect`/`rename`/`rm`. Machine-qualified addresses (`box/t7`) in one terminal list and event stream. `on` targets a machine for `terminal.run`, `file.*`, `doc.*` and `machine.exec` | Remote work happens through the CLI (`herdr --remote`, saved SSH machines, `remote-api-bridge`). The socket API addresses one server |
| Files and commands | `file.read`, `file.write` (atomic), `file.edit` (exact-match edits), `machine.exec` (argv, output and exit code, no terminal) on any machine | None; wooloo runs its own SSH file and Git transport |
| Transports | Unix socket, Windows named pipe, and `hc connect` over stdin/stdout, so the same protocol runs over SSH without a bridge | Unix socket (named pipe on Windows); `remote-api-bridge` for SSH |

The TUI has things Core lacks: workspaces, tabs, splits and layouts; the cell surface (`shell.surface.v1`) and semantic input encoded by the server; agent detection and integrations; Git worktrees (`worktree.*`); plugins, popups, notifications and sounds; copy mode, search, links and selection; config reload. Agent conversation resume is TUI-only for now ([Core #15](https://github.com/herdrdev/herdr-core/issues/15)).

For wooloo, the additions that would pay off most are event recovery with sequence numbers, observe-only viewers, OSC 7501 for agents Herdr does not detect, `machine.*` with `on` (one connection for remote terminals, files and commands), and `hc connect` in place of `remote-api-bridge`. The cost is that wooloo would have to own the structure (spaces, tabs, splits), terminal emulation and key encoding.

### A documented multi-client contract: labels

The app's [docs/labels.md](https://github.com/herdrdev/herdr-app/blob/master/docs/labels.md) specifies how "the desktop app, the phone app, a terminal UI" share per-agent state through Core terminal labels:

- `herdr.seen=<turn>` records the last turn a person looked at. It tells "done" apart from "idle", and a lower write means "mark unread".
- `herdr.pinned=1` marks a pinned agent.
- `herdr.space` and `herdr.tab` associate terminals with the app's spaces and tabs.

This is the first written contract aimed at third-party clients other than the OpenRPC schema. The space/tab structure itself (order, names, empty tabs) still lives in the private `herdr-app` document. [App #43](https://github.com/herdrdev/herdr-app/issues/43), which asks whether other clients may read it, is open without an answer.

## The app compared with wooloo

| Area | Herdr app 0.1.16 | wooloo |
| --- | --- | --- |
| Backend | herdr-core only; cannot attach to a TUI server | Herdr TUI 0.9 only (bundled 0.9.5) |
| Toolkit and rendering | Rust with GPUI; terminal state through vendored Ghostty (libghostty) | SwiftUI/AppKit; native Core Text drawing of Herdr's cell surfaces |
| Structure | Spaces, tabs, splits, agents rail, peek, command palette | Spaces, tabs, splits, agents list, command palette |
| Customization | Layouts and JavaScript mods (QuickJS); mods can run programs, read files and use the network | Native settings and the TUI's `config.toml` |
| Files and Git | Basic; Markdown/image/PDF previews and Files/Changes toggles are open requests ([#91](https://github.com/herdrdev/herdr-app/issues/91), [#168](https://github.com/herdrdev/herdr-app/issues/168)) | Explorer, editor, diffs, history, branches, worktrees, project search |
| Remote | SSH machines through Core; each machine's core stores its own structure | SSH profiles saved in Herdr, `remote-api-bridge`, SSH file transport |
| Mobile | Official iOS/iPadOS/Android apps over SSH, Core only | Companion Android app (unpublished) through tunnel or direct SSH, TUI `remote-api-bridge` |
| Agent state | Programs report it through OSC 7501; no detection | TUI's screen detection and integrations |
| Resume after reboot | Fresh shells; conversations not resumed | TUI restores layouts and resumes supported agent sessions |
| Notifications | macOS Notification Center alerts requested ([#120](https://github.com/herdrdev/herdr-app/issues/120), [#634](https://github.com/herdrdev/herdr-app/issues/634)) | Herdr's sounds, toasts and system notifications |
| Updates and privacy | SHA-256 checked against the release manifest, no separate signature; telemetry on by default | Sparkle with EdDSA signatures; no telemetry |
| macOS Intel | Not shipped | Universal build |

The app ships fixes several times a day, so this snapshot will age fast. Its open issues match features wooloo already has (previews, Git panels, notifications, Intel). That gap may close.

## Open-source projects responding to the split

Found with GitHub searches for `herdr`, `herdr-core` and `herdr tui` and the TUI's fork list on 2026-11-16. Stars and descriptions are from GitHub that day; nothing was installed or run. Hundreds of other repositories are mods, layouts, plugins and orchestration scripts; they are left out. The search found no bridge that serves the TUI's socket API (`herdr.sock`, `herdr-client.sock`) on top of Core, so existing TUI clients such as wooloo cannot reach Core sessions through one.

### Terminal UIs on Core (replacing the TUI)

These answer [Core #25](https://github.com/herdrdev/herdr-core/issues/25). All of them rebuild spaces and tabs on top of Core, mostly by sharing the app's private `herdr-app` document.

| Project | Approach |
| --- | --- |
| [followcat/hc-tui](https://github.com/followcat/hc-tui) (Rust, ★15, v0.1.0) | TUI look and keys over `hc`, local or `--remote` over SSH. Reads spaces and tabs from the `herdr-app` document. Status only for programs that report OSC 7501 |
| [lukeed/rodeo](https://github.com/lukeed/rodeo) (★8) | Keyboard-first TUI over `hc` 0.1.18+. Shares spaces, tabs and panes with the desktop app both ways |
| [xxb/herdr-tui](https://github.com/xxb/herdr-tui) (`hct`, ★1) | Reads and writes `doc("herdr-app")`, syncing with the desktop and Android apps |
| [MohammedRashad/herdr-tui-support](https://github.com/MohammedRashad/herdr-tui-support) (Python) | Describes itself as replacing "the removed TUI" for phone SSH use. Takes structure from the app's own CLI (`herdr-app ls`/`do`), so it needs the app running; falls back to `hc` alone |
| [SuTang-vain/herdr-core-tui](https://github.com/SuTang-vain/herdr-core-tui) | Experimental: the Herdr TUI itself with a herdr-core pane backend |
| [takagiy/herdr-core.nvim](https://github.com/takagiy/herdr-core.nvim), [bunnylushington/herdr-core-mode](https://github.com/bunnylushington/herdr-core-mode), [moneylobster/herdr-core-el](https://github.com/moneylobster/herdr-core-el) | Core clients inside Neovim and Emacs |

### Desktop and mobile clients that speak both backends

| Project | Approach |
| --- | --- |
| [sheprd-labs/sheprd](https://github.com/sheprd-labs/sheprd) (Rust/GPUI, ★2313, macOS/Linux/Windows; formerly `penso/herdr-gpui`) | The closest analogue to wooloo. It is a native client of the TUI server ("Herdr 1", terminal cells from `herdr-client.sock`) and adds "Herdr 2" (Core) terminals. Its own `sheprd-terminal` emulates Core's raw output and draws it with the same painter. Core has no workspaces, so Sheprd keeps its own per host. Releases bundle a pinned herdr-core. Both kinds of tab live side by side in the same workspaces; nothing migrates between them |
| [ZingerLittleBee/Heeler](https://github.com/ZingerLittleBee/Heeler) (iOS/iPadOS, ★900) | Over SSH to the TUI (a streamlocal channel onto `herdr.sock`), the desktop app/Core, or tmux. libghostty renders the terminal |
| [0cv/herdr-mobile-relay](https://github.com/0cv/herdr-mobile-relay) (★381) | Mobile web app with relays for the TUI (0.7.5+) and for herdr-app/`hc` (tested with core 0.1.18, app 0.1.13) |

### Core-only clients

Mobile and web clients for Core: [afloury/wherdr](https://github.com/afloury/wherdr) (browser and phone, talks to `HC_SOCKET`), [juanibiapina/herdr-mobile](https://github.com/juanibiapina/herdr-mobile), [tajchert/flocket](https://github.com/tajchert/flocket), [lucasscariot/herdie](https://github.com/lucasscariot/herdie), [isaacasamoah/voyagershell](https://github.com/isaacasamoah/voyagershell) (a workspace built on Core). [Heretikio/herdr-wake](https://github.com/Heretikio/herdr-wake) starts Core at boot and resumes agent sessions, a stopgap for #15. [devswha/ovis](https://github.com/devswha/ovis) (★2082) is a browser and phone client for the TUI (0.9.0+) whose desktop build has terminals of its own.

### TUI forks that keep the original protocol

| Project | What it changes |
| --- | --- |
| [hdosys/herdr-ext](https://github.com/hdosys/herdr-ext) ("Herdr Extended", ★11) | An upstream-first patch queue on 0.9.5 (release 2026.10.29.1: fixes for terminal crashes, shutdown session preservation, live Unix sockets). The executable, config, state, sessions, sockets and protocol stay `herdr`, and attachment negotiates the upstream endpoint protocol. A candidate source for wooloo's bundled runtime if upstream TUI fixes stop |
| [wkentaro/lawn](https://github.com/wkentaro/lawn) | Forked at `ee5bfb50` (0.9.5). Adds a `pane_presentation_v1` capability for "parking". Older servers keep working without it, which shows forks extending the protocol through capability negotiation |
| [Rivaldito/shepherd](https://github.com/Rivaldito/shepherd) | Forked at `ee5bfb50`. Adds orchestration (roles, patterns, worktrees, an event bus), turns off upstream update checks, and follows upstream with a sync routine |
| [jerryfane/herdr](https://github.com/jerryfane/herdr) | Server features for the Herdrup iOS app: messaging, push notifications, a live streaming terminal. Published as preview builds |
| [andreconde21/sheprd](https://github.com/andreconde21/sheprd) | A client-side fork (different from sheprd-labs) with cross-machine project groups; talks to stock servers |

### What this means for wooloo

- **Sheprd shows a dual-backend path that works**, and it competes with wooloo directly: TUI cells where a TUI server exists, its own emulator for Core output, workspaces kept by the client, and a pinned core bundled with the app. It is the reference to study before wooloo's Core proof of concept.
- **The `herdr-app` document is becoming a de facto shared format.** At least three Core TUIs read it, and two write it, without the guarantee asked for in [App #43](https://github.com/herdrdev/herdr-app/issues/43). A wooloo Core client could join that convention for interoperability with the app and phones. It should read it defensively and write it only with compare-and-set on the version.
- **The TUI protocol is fragmenting through forks.** Forks are extending it (`pane_presentation_v1`, Herdrup's streaming terminal). wooloo should keep negotiating capabilities, as it does with `surface_codecs`, rather than assume a server is upstream 0.9.5.
- **Herdr Extended is a fallback** if the TUI stays unmaintained: it keeps the protocol and state layout that wooloo bundles today. Before relying on it, check that its release assets and checksums can replace `scripts/bundle-herdr.sh`'s GitHub source.
- **Naming in the community:** Sheprd calls the TUI server "Herdr 1" and Core "Herdr 2". herdr.dev uses neither name.

## Impact on wooloo's development

### What wooloo depends on, and Core lacks

| wooloo component | TUI contract it uses | Core equivalent |
| --- | --- | --- |
| `HerdrStore`, `HerdrEventStream` (`HerdrConnection.swift`) | `herdr.sock` JSON: `session.snapshot`, `events.subscribe`, about 30 `workspace.*`/`tab.*`/`pane.*`/`layout.*` methods and events | `terminal.*` and `events.subscribe` over JSON-RPC. No workspaces, tabs or splits: the app keeps those in a private document |
| `HerdrSurfaceStream`, `HerdrSurfaceDecoder`, `TerminalPaneView` | `herdr-client.sock`, `shell.surface.v1` cell grid, patches, `surface_scroll`, blobs | `terminal.attach` raw terminal output. The client must run its own emulator (the app uses libghostty) |
| Input (`TerminalInputTests`) | `shell.input.semantic.v1`; Herdr encodes keys | The viewer encodes keys itself (win32-input-mode included); `terminal.keys` exists only for named keys |
| Agents list and alerts (`HerdrNotifier`) | `pane.agent_detected`, `pane.agent_status_changed`, `[ui.sound]`/`[ui.toast]` | OSC 7501 status and `turn`; `herdr.seen` labels; no detection, no sound/toast config |
| Settings (`HerdrConfig`, `HerdrShortcuts`) | `~/.config/herdr/config.toml`, `herdr config check`, `server.reload_config` | `~/.config/herdr-core/config.toml` (shell, draft wait, restore screen); keys belong to each client |
| Remote and mobile (`HerdrRemoteBridge`, `MobileSSHAccess`) | `herdr remote-api-bridge`, `terminal session control` | `hc connect` over SSH; `hc machine` |
| Bundled runtime (`HerdrRuntime.swift`, `scripts/bundle-herdr.sh`) | Herdr 0.9.5 binaries from GitHub releases, wooloo's own launchd job | Core installs itself as "Herdr Core" under launchd and updates itself; release assets are on releases.herdr.dev, not GitHub |

Supporting Core is a second backend, not an upgrade. The terminal path is the largest part: the surface pipeline and its performance work (`docs/perf/README.md`) have no Core counterpart. [SwiftTerm evaluation](swiftterm-evaluation.md) is the starting point for choosing an emulator.

### Risks

1. **TUI stagnation.** If the TUI stays quiet, wooloo keeps 0.9.5's bugs. The upstream requests in `TODO.md` (scrolled patches with graphics, the ~43 fps limit, popup titles as cells) become unlikely to land. The [plugin plan](herdr-plugins.md) targets a TUI-only plugin system.
2. **Audience drift.** The users wooloo targets, developers who want a native window over their agent sessions, are the ones the app is built for. Users who move to the app lose their TUI sessions, and wooloo with them.
3. **Mobile overlap.** The official phone apps cover what wooloo's unpublished Android companion and Remote Access aim to do, but for Core. A companion that only reaches TUI sessions has a shrinking audience. `RemoteAccessLink` and the Android parser change together, so a change of direction costs both.
4. **Contract uncertainty on Core.** Only the OpenRPC schema and the labels document are written promises. Spaces and tabs (the `herdr-app` document, #43), CLI JSON and behavioral defaults (#33), and resume (#15) are not settled. A wooloo Core client that copies the app's structure takes on a private format.
5. **Naming on the Mac.** The app installs `~/Applications/Herdr.app` and a `herdr-app` command. The core installs a "Herdr Core" app and `hc`. The TUI command stays `herdr`. Setup, the session picker and support answers should say "Herdr TUI" wherever "Herdr" could now mean the app.

### Advantages wooloo still has

- It works with existing TUI sessions, which the app cannot open. Users who stay on the TUI, including remote-first users who rely on `herdr --remote` ([Core #25](https://github.com/herdrdev/herdr-core/issues/25)), have few GUI options: among the projects found, only Sheprd also does this (see above).
- TUI resume after reboot and screen-based agent detection work today for agents that do not report OSC 7501.
- Native macOS behavior, Intel support, signed updates, no telemetry, and an editor/Git feature set the app has not reached.

## Recommendations

1. **Keep Herdr TUI 0.9.5 as the production backend.** Nothing upstream retires it, and it is the only backend wooloo can render today.
2. **Stop planning on upstream TUI changes.** Keep the drafted TUI issues in `TODO.md` as optional. Avoid new features that work only with a new TUI release (for example, the popup title proposal), and prefer wooloo-side workarounds.
3. **Use TUI vocabulary in user-visible text.** Say "Herdr TUI" where the README, setup and errors mean the TUI server, so users with the app installed are not confused.
4. **Prepare a backend seam before writing a Core client.** The UI should depend on wooloo's own model (Spaces, tabs, panes, agents, surfaces) rather than on TUI method names, so a second backend can plug in. This is a design step, not a commitment to Core.
5. **Run the Core proof of concept** described in [herdr-core.md](herdr-core.md), with these additions:
   - Choose a terminal emulator for `terminal.attach` and measure it against `scripts/terminal-bench.sh` baselines.
   - Implement the `herdr.seen`/`herdr.pinned` label contract for the agents list.
   - Subscribe with `docs` to follow `herdr-app` read-only, and document the dependency on its shape until #43 is answered.
   - Run against an isolated `HC_SESSION`, never the user's core.
6. **Decide on the mobile companion separately.** Before publishing it, weigh it against the official Core-only phone apps.

### Decision triggers

Revisit the backend decision when any of these happen:

- An upstream statement on the TUI's future (#63, #115), or a TUI release after 0.9.5, or a long gap with none.
- A Core-native TUI (#25), which would make Core the shared backend for terminal users too.
- An answer on #43 that makes the `herdr-app` document readable by other clients.
- Resume support in Core (#15), which removes the TUI's main remaining advantage for users.
- A wooloo user request to open app/Core sessions.

### Watch list

| Item | Why it matters to wooloo |
| --- | --- |
| [herdr commits](https://github.com/herdrdev/herdr/commits/master) and [releases](https://github.com/herdrdev/herdr/releases) | Whether the backend wooloo bundles is still maintained |
| [App #63](https://github.com/herdrdev/herdr-app/issues/63), [Core #115](https://github.com/herdrdev/herdr-core/issues/115) | Convergence and migration decisions |
| [Core #25](https://github.com/herdrdev/herdr-core/issues/25), [hc-tui](https://github.com/followcat/hc-tui) | Whether terminal users move to Core |
| [App #43](https://github.com/herdrdev/herdr-app/issues/43), [labels.md](https://github.com/herdrdev/herdr-app/blob/master/docs/labels.md) | Contracts a third-party Core client may rely on |
| [Core #15](https://github.com/herdrdev/herdr-core/issues/15), [Core #33](https://github.com/herdrdev/herdr-core/issues/33) | Resume and compatibility guarantees |
| [sheprd-labs/sheprd](https://github.com/sheprd-labs/sheprd), [hdosys/herdr-ext](https://github.com/hdosys/herdr-ext) | A dual-backend native client to compare against; a maintained TUI distribution |
| [Core CHANGELOG](https://github.com/herdrdev/herdr-core/blob/master/CHANGELOG.md), [OpenRPC schema](https://github.com/herdrdev/herdr-core/blob/master/schema/hc.openrpc.json) | API changes before a client is written |

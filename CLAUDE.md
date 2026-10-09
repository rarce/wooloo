# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

wooloo is a native macOS (14+) SwiftUI client for [Herdr](https://herdr.dev/), a server that manages terminal/agent sessions. Herdr owns the processes, layout and terminal state; wooloo only renders and sends input. `AGENTS.md` holds the repository conventions (style, commits, testing expectations) and also applies.

## Commands

```sh
# Build (the project signs ad hoc; keep a signature — without one macOS refuses notification permission)
xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' build

# Unit tests: same command with `test`. Single class or method:
#   ... test -only-testing:woolooTests/SurfaceDecodingTests
#   ... test -only-testing:woolooTests/SharedLoadsTests/testSomeMethod

# Re-record terminal pixel snapshots (woolooTests/Snapshots, font-dependent)
TEST_RUNNER_WOOLOO_RECORD_SNAPSHOTS=1 xcodebuild ... test -only-testing:woolooTests/TerminalRenderingTests

# Performance (Release builds, results in build/perf/, compared with docs/perf/*baseline*)
scripts/terminal-bench.sh [--save-baseline]   # decode/layout/draw stage benchmarks
scripts/terminal-e2e.sh                       # live run on its own `wooloo-perf` Herdr session
scripts/workspace-bench.sh                    # WorkspaceFiles ops; WOOLOO_BENCH_SSH_TARGET=none skips SSH
```

Benchmarks and trace replay are skipped in normal `test` runs unless their env vars are set (the scripts do this). Pixel snapshots run locally only: CI (`.github/workflows/ci.yml`, macos-26) skips `ViewSnapshotTests` and `TerminalRenderingTests/testSnapshotsMatch` to stay fast. Terminal snapshots also need FiraCode Nerd Font Mono; view snapshots are saved per macOS version (`woolooTests/Snapshots/Views`, re-record with `TEST_RUNNER_WOOLOO_RECORD_SNAPSHOTS=1`). No linter or formatter is configured.

Git, SSH and Herdr socket tests use `WorkspaceGitSandbox` (disposable repos under `/private/tmp/wooloo-tests`, global Git config ignored), a fake `ssh` via `WorkspaceFiles.sshExecutable`, and `FakeHerdrServer`. After changing a dependency, run `scripts/third-party-notices.py` to regenerate `THIRD_PARTY_NOTICES.txt` (after `scripts/herdr-notices.py <herdr checkout>` when the bundled Herdr changes).

Develop against an isolated Herdr session, never `default` or your primary one. The app opens the last session it used (`default` on first launch), so switch to the test session in the sidebar's session picker:

```sh
herdr --session wooloo-ui-test server
herdr --session wooloo-ui-test workspace create --cwd "$PWD" --label wooloo-test
herdr --session wooloo-ui-test server stop
```

The Xcode project lists sources explicitly: adding a Swift file requires editing `wooloo.xcodeproj/project.pbxproj`.

## Architecture

**Herdr connection (`HerdrConnection.swift`).** `HerdrStore` (the app's `ObservableObject`) talks to Herdr over two Unix sockets in the session directory (`~/.config/herdr/` for `default`, `~/.config/herdr/sessions/<name>/` otherwise; tests repoint `HerdrStore.sessionRoot`):
- `herdr.sock`: newline-delimited JSON. A persistent `events.subscribe` stream (`HerdrEventStream`) triggers a fresh `session.snapshot` on each event; commands (`workspace.create`, `tab.create`, `pane.split`, `server.reload_config`, …) are one-shot requests via `HerdrSocket`. `herdr api schema --json` is the method contract.
- `herdr-client.sock`: binary generation-1 client endpoint for the selected tab — streams terminal surfaces and carries keyboard, paste, mouse and split-resize input. `pane.read` / JSON `pane.send_input` are fallbacks when it is unavailable.

**Terminal pipeline** (details and measurements in `docs/perf/README.md`): `HerdrSurfaceStream` (its own `.userInteractive` thread) → `HerdrSurfaceDecoder` (`HerdrSurface.swift`, full surfaces, incremental patches and `surface_scroll` scrolled patches, follows Herdr's frozen field order) → `HerdrSurfaceMailbox` (keeps only the newest surface, wakes main once) → `HerdrSurfaceFeed` → `TerminalPaneView` (row-reusing layout matched by row fingerprints, Core Text shaping in pieces cached by `TerminalShapeCache`, draws only changed rows). Surfaces deliberately bypass SwiftUI; only `HerdrStore.surfaceLayout` is published, when panes change. Avoid publishing `@Published` values per frame or per keystroke — a redundant write to `inputError` once cost ~8 ms per key. Tests check the decoder against an independent `ReferenceSurfaceDecoder`.

**Workspace files and Git (`WorkspaceFiles.swift`).** A stateless `enum` of static functions used by the explorer, Git bar, repository panel, diffs, search and document editor. Everything runs through `WorkspaceFiles.run`, for a local path or an SSH machine from Herdr's saved profiles (`WorkspaceFileLocation`). SSH uses a shared ControlMaster socket in `/tmp/wooloo-ssh-<uid>`; local git is resolved via `xcrun --find git` to skip the `/usr/bin/git` shim. `SharedLoads` dedupes concurrent `repository()` loads for 2 s and must be invalidated after any git mutation or explicit refresh. `WorkspaceProcessLog` records every process for metrics.

**UI.** `ContentView` assembles the left sidebar (spaces, agents, session picker), tab row and terminal panes, and the right sidebar (`WorkspaceBrowserView` Files/Changes, `WorkspaceRepositoryView` history/branches/worktrees, `WorkspaceGitBar`). Editor tabs use the vendored CodeEditSourceEditor (`Vendor/`, pinned, SwiftLint plugins stripped). `HerdrConfig` / `HerdrSettingsView` edit the shared `config.toml` (validated with `herdr config check`, conflict-checked, written atomically, then `server.reload_config`); `HerdrShortcuts` implements Herdr's prefix and direct key bindings from the same file.

**Commands.** Window state lives in `ContentWindowModel`; `ContentCommands` (built by `ContentView` per use) is the single place menu items, shortcuts, dialogs and the command palette act on Herdr, documents, search and the window, with `WoolooCommandAvailability` deciding what applies. View-local commands (editor, explorer) reach the palette through a `PaletteCommandTarget` that the visible view registers and unregisters by owner UUID. Side effects beyond the window go through `ContentCommandEffects` so tests can replace them. A new action usually needs wiring in all of these: menu (`WoolooApp`), availability, `ContentCommands`, and the palette list.

**Models vs. views.** Logic is kept in testable models beside their views: `WorkspaceDocumentStore` (per-Space editor tabs, single preview tab, save/close), `WorkspaceExplorerModel` (multi-selection, create/rename/move/trash with undo and redo), `QuickOpen` (Go to File index and fuzzy matching), `WorkspaceSearch` (project search and replace), `HerdrNotifier` (Herdr's `[ui.sound]`/`[ui.toast]` alerts), `AgentQuota` (Claude Code / Codex subscription limits from undocumented endpoints; parse every field as optional) and `HostStats` (local or SSH CPU/memory sampling).

**Remote access (`RemoteAccess.swift`).** `RemoteAccessModel.shared` runs `cloudflared` (quick tunnel, or a named tunnel whose token lives in the Keychain and goes through `TUNNEL_TOKEN`) to publish this Mac's SSH for remote clients, such as the companion Android app. A quick tunnel counts as running only once Cloudflare's authoritative nameserver answers for its hostname, so no resolver caches a miss. `RemoteAccessLink` builds the `add-host` link shown as a QR code; the Android app parses the same format, so change both together. The app delegate stops the tunnel on quit.

**Updates (`AppUpdater.swift`).** Sparkle 2 updates the app from GitHub releases: the feed is the `appcast.xml` asset of the latest release, and both it and the archive must be signed with the EdDSA key in `wooloo/Info.plist` (merged with the generated Info.plist). Pushing a `vX.Y.Z` tag that matches `MARKETING_VERSION` runs `.github/workflows/release.yml`, which builds, signs with `scripts/release-appcast.sh` and publishes; see CONTRIBUTING.md, "Releases". `CURRENT_PROJECT_VERSION` follows `MARKETING_VERSION`, since Sparkle compares the build number. Dynamic frameworks such as Sparkle load through the `@executable_path/../Frameworks` rpath, which tests do not exercise: Xcode puts its products on the framework path.

**Instrumentation env vars** (read by the app): `WOOLOO_METRICS_FILE`, `WOOLOO_SURFACE_TRACE`, `WOOLOO_WINDOW_SIZE`, and `WOOLOO_TYPING_PROBE*`, which works only in builds with the `WOOLOO_PROBES` compilation condition (set by `scripts/terminal-e2e.sh`). Trace files are created with mode 0600. Signposts use subsystem `dev.wooloo.terminal`.

## Working here

- Other agents may edit this working tree concurrently: stage only files you changed.
- Requires Xcode 26 (a vendored package needs Swift 6.2) and Herdr 0.9+.
- Keep process, file and SSH work off the main thread; pass command arguments as arrays and quote anything sent to a remote shell with `WorkspaceFiles.quote`.
- Test Git worktree operations in a disposable repo under `/private/tmp`; normal removal must reject dirty worktrees.
- For terminal rendering or surface changes, run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh` in addition to unit tests.
- Deferred work is tracked in `TODO.md`; design notes are in `docs/` (`herdr-connection.md`, `git-and-files-research.md`).

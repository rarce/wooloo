# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

xherdr is a native macOS (14+) SwiftUI client for [Herdr](https://herdr.dev/), a server that manages terminal/agent sessions. Herdr owns the processes, layout and terminal state; xherdr only renders and sends input. `AGENTS.md` holds the repository conventions (style, commits, testing expectations) and also applies.

## Commands

```sh
# Build (ad hoc signature; keep it — without a signature macOS refuses notification permission)
xcodebuild -project xherdr.xcodeproj -scheme xherdr -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

# Unit tests: same command with `test`. Single class or method:
#   ... test -only-testing:xherdrTests/SurfaceDecodingTests
#   ... test -only-testing:xherdrTests/SharedLoadsTests/testSomeMethod

# Re-record terminal pixel snapshots (xherdrTests/Snapshots, font-dependent)
TEST_RUNNER_XHERDR_RECORD_SNAPSHOTS=1 xcodebuild ... test -only-testing:xherdrTests/TerminalRenderingTests

# Performance (Release builds, results in build/perf/, compared with docs/perf/*baseline*)
scripts/terminal-bench.sh [--save-baseline]   # decode/layout/draw stage benchmarks
scripts/terminal-e2e.sh                       # live run on its own `xherdr-perf` Herdr session
scripts/workspace-bench.sh                    # WorkspaceFiles ops; XHERDR_BENCH_SSH_TARGET=none skips SSH
```

Benchmarks and trace replay are skipped in normal `test` runs unless their env vars are set (the scripts do this). Pixel snapshots run locally only: CI (`.github/workflows/ci.yml`, macos-26) skips `ViewSnapshotTests` and `TerminalRenderingTests/testSnapshotsMatch` to stay fast. Terminal snapshots also need FiraCode Nerd Font Mono; view snapshots are saved per macOS version (`xherdrTests/Snapshots/Views`, re-record with `TEST_RUNNER_XHERDR_RECORD_SNAPSHOTS=1`). No linter or formatter is configured.

Git, SSH and Herdr socket tests use `WorkspaceGitSandbox` (disposable repos under `/private/tmp/xherdr-tests`, global Git config ignored), a fake `ssh` via `WorkspaceFiles.sshExecutable`, and `FakeHerdrServer`. After changing a dependency, run `scripts/third-party-notices.py` to regenerate `THIRD_PARTY_NOTICES.txt`.

Run the app against an isolated Herdr session, never `default` or the primary one (the app rejects `default`):

```sh
herdr --session xherdr-ui-test server
herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test
herdr --session xherdr-ui-test server stop
```

The Xcode project lists sources explicitly: adding a Swift file requires editing `xherdr.xcodeproj/project.pbxproj`.

## Architecture

**Herdr connection (`HerdrConnection.swift`).** `HerdrStore` (the app's `ObservableObject`) talks to Herdr over two Unix sockets under `~/.config/herdr/sessions/<name>/`:
- `herdr.sock`: newline-delimited JSON. A persistent `events.subscribe` stream (`HerdrEventStream`) triggers a fresh `session.snapshot` on each event; commands (`workspace.create`, `tab.create`, `pane.split`, `server.reload_config`, …) are one-shot requests via `HerdrSocket`. `herdr api schema --json` is the method contract.
- `herdr-client.sock`: binary generation-1 client endpoint for the selected tab — streams terminal surfaces and carries keyboard, paste, mouse and split-resize input. `pane.read` / JSON `pane.send_input` are fallbacks when it is unavailable.

**Terminal pipeline** (details and measurements in `docs/perf/README.md`): `HerdrSurfaceStream` (background thread) → `HerdrSurfaceDecoder` (`HerdrSurface.swift`, full surfaces + incremental patches, follows Herdr's frozen field order) → `HerdrSurfaceMailbox` (keeps only the newest surface, wakes main once) → `HerdrSurfaceFeed` → `TerminalPaneView` (row-reusing layout, draws only changed rows). Surfaces deliberately bypass SwiftUI; only `HerdrStore.surfaceLayout` is published, when panes change. Avoid publishing `@Published` values per frame or per keystroke — a redundant write to `inputError` once cost ~8 ms per key. Tests check the decoder against an independent `ReferenceSurfaceDecoder`.

**Workspace files and Git (`WorkspaceFiles.swift`).** A stateless `enum` of static functions used by the explorer, Git bar, repository panel, diffs, search and document editor. Everything runs through `WorkspaceFiles.run`, for a local path or an SSH machine from Herdr's saved profiles (`WorkspaceFileLocation`). SSH uses a shared ControlMaster socket in `/tmp/xherdr-ssh-<uid>`; local git is resolved via `xcrun --find git` to skip the `/usr/bin/git` shim. `SharedLoads` dedupes concurrent `repository()` loads for 2 s and must be invalidated after any git mutation or explicit refresh. `WorkspaceProcessLog` records every process for metrics.

**UI.** `ContentView` assembles the left sidebar (spaces, agents, session picker), tab row and terminal panes, and the right sidebar (`WorkspaceBrowserView` Files/Changes, `WorkspaceRepositoryView` history/branches/worktrees, `WorkspaceGitBar`). Editor tabs use the vendored CodeEditSourceEditor (`Vendor/`, pinned, SwiftLint plugins stripped). `HerdrConfig` / `HerdrSettingsView` edit the shared `config.toml` (validated with `herdr config check`, conflict-checked, written atomically, then `server.reload_config`); `HerdrShortcuts` implements Herdr's prefix and direct key bindings from the same file.

**Instrumentation env vars** (read by the app): `XHERDR_METRICS_FILE`, `XHERDR_SURFACE_TRACE`, `XHERDR_WINDOW_SIZE`, `XHERDR_TYPING_PROBE*`. Signposts use subsystem `dev.xherdr.terminal`.

## Working here

- Other agents may edit this working tree concurrently: stage only files you changed.
- Test Git worktree operations in a disposable repo under `/private/tmp`; normal removal must reject dirty worktrees.
- For terminal rendering or surface changes, run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh` in addition to unit tests.
- Deferred work is tracked in `TODO.md`; design notes are in `docs/` (`herdr-connection.md`, `git-and-files-research.md`).

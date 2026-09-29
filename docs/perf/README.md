# Terminal pipeline measurements

A Herdr surface travels this path before it is on screen:

1. **Receive and decode** (stream thread, `HerdrSurfaceStream.run` → `HerdrSurfaceDecoder`): a socket frame becomes a complete `HerdrSurface` or patches the current one.
2. **Deliver** (`HerdrSurfaceMailbox` → `HerdrSurfaceFeed`): the stream thread keeps only the newest surface and wakes the main thread once. The feed hands the surface straight to the terminal view. SwiftUI sees only `HerdrStore.surfaceLayout`, which changes when panes do.
3. **Layout** (main thread, `TerminalPaneView.layoutGrid`): cells become fills, glyph runs and underlines, row by row. A row whose cells, cursor and images match a row of the previous grid reuses that row's layout, so scrolled output only lays out new lines.
4. **Draw** (main thread, `HerdrTerminalTextView.draw`): Core Graphics draws only the rows that changed.

Three tools measure it. All of them also check that no information is lost on the way.

## Unit tests: `xherdrTests`

Run them with `xcodebuild test` and the scheme `xherdr`, using the build flags from `AGENTS.md`.

- `SurfaceDecodingTests` encodes synthetic workloads (`SurfaceFixtures.swift`): ASCII, color and Unicode scrolling, typing, and complete frames. After every frame, the app's decoder and an independent `ReferenceSurfaceDecoder` must both produce the expected screen. Stale or baseless patches must be rejected.
- `TerminalRenderingTests` checks the laid-out grid cell by cell. Every visible symbol must have a glyph in its column, and every colored background and underline must be kept. Nothing may be left over from the previous frame. The test also compares 2× pixel snapshots in `xherdrTests/Snapshots`. The snapshots depend on the installed terminal font; re-record them with `TEST_RUNNER_XHERDR_RECORD_SNAPSHOTS=1`.
- `SurfaceTraceReplayTests` runs only from `scripts/terminal-e2e.sh`; see below.

## Stage benchmarks: `scripts/terminal-bench.sh`

This script times decode, layout and draw per frame over the synthetic workloads (200×60, 240 frames) in a Release build. The `burst` stage pushes every frame through all three stages, with no frames coalesced. `layout` reuses rows from the previous sampled state, as the view does, and `layout-cold` lays out every row. Results go to `build/perf/`, and the script compares them with `bench-baseline.jsonl`. Pass `--save-baseline` to replace the baseline.

## End to end: `scripts/terminal-e2e.sh`

This script starts a dedicated `xherdr-perf` Herdr session and opens a Release build on it with `XHERDR_METRICS_FILE` and `XHERDR_SURFACE_TRACE` set. It then runs these workloads in the pane:

- `ascii`, `color` and `unicode`: 250 lines/s for 5 s
- `typing`: 40 characters/s
- `burst`: `cat` of 60,000 lines
- `keys`: 100 letters typed into `cat`, one every 100 ms. The keys go through xherdr's own `keyDown`, sent by the typing probe (`XHERDR_TYPING_PROBE`, triggered with `notifyutil -p dev.xherdr.typing-probe`), so no accessibility access is needed.

For each workload, the script reports:

- frames received and drawn
- revisions never drawn
- main-thread latency from receive to deliver
- layout and draw time
- latency from arrival to draw
- main-thread busy share
- for `keys`, keystroke-to-screen latency, split into:
  - `queue`: from the event's timestamp until `keyDown` runs
  - `send`: from `keyDown` until the input is written to the socket
  - `herdr`: from the write until the echo frame is received (the first frame whose cursor moved)
  - `render`: from receiving that frame until it is drawn

The window's content size is fixed with `XHERDR_E2E_WINDOW` (default 1600x1000), so runs compare the same grid whatever size your own xherdr window was saved at. The live results below before this option used a 311×80 window. `e2e-baseline.json` now uses the fixed size, a 120×48 grid on the machine below.

It compares them with `e2e-baseline.json`. The script then replays the recorded trace through the reference decoder. Every revision the app drew must match what Herdr sent, and the last frame received must have been drawn. The xherdr window must stay visible during the run.

Signposts in the `dev.xherdr.terminal` subsystem (`decode`, `layout`, `draw`) show the same stages in Instruments, with or without the metrics file.

## Results

`bench-before.jsonl` and `e2e-before.json` hold the measurements taken before the optimizations below. `bench-baseline.jsonl` and `e2e-baseline.json` hold the current numbers, so the scripts flag regressions against them. To compare with the old numbers, run `scripts/terminal-perf.py e2e <run>/metrics.jsonl <run>/phases.jsonl --baseline docs/perf/e2e-before.json`.

The optimizations, in order:

1. Coalesced delivery through the mailbox and the feed, instead of one main-thread task and one SwiftUI update per frame.
2. Row reuse across frames and redrawing only the rows that changed.
3. Reuse by direct comparison with the previous grid's rows instead of hashing every row; one colour lookup per distinct colour; one attributed string per row.
4. Single ASCII characters decoded from a table.

Stage benchmarks, 200×60 grid, per frame, 2026-09-29, Mac16,5, FiraCodeNFM 12 pt:

| scenario | decode p50 before → after | layout p50 before → after | cold layout p50 | burst fps before → after |
|---|---|---|---|---|
| ascii-scroll | 0.76 → 0.18 ms | 13.5 → 0.42 ms | 2.7 ms | 63 → 638 |
| color-scroll | 0.75 → 0.19 ms | 15.5 → 0.57 ms | 4.8 ms | 52 → 356 |
| unicode-scroll | 0.77 → 0.21 ms | 14.9 → 0.48 ms | 4.1 ms | 57 → 646 |
| typing (1 cell) | 0.04 → 0.04 ms | 15.7 → 0.26 ms | 4.2 ms | 56 → 554 |
| full-frames | 0.77 → 0.16 ms | 15.9 → 0.33 ms | 4.7 ms | 49 → 354 |

Live, 311×80 window:

| workload | drawn fps / Herdr fps, before → after | revisions never drawn, before → after | arrival→draw p50, before → after | arrival→draw max, before → after | main busy, before → after |
|---|---|---|---|---|---|
| ascii | 16.8 / 43.5 → 42.5 / 42.5 | 177 → 0 | 44 → 2.7 ms | 68 → 7 ms | 65% → 9% |
| color | 14.9 / 43.5 → 42.8 / 42.8 | 189 → 0 | 48 → 3.5 ms | 57 → 15 ms | 65% → 13% |
| unicode | 13.6 / 38.6 → 42.7 / 42.7 | 166 → 0 | 48 → 2.4 ms | 273 → 18 ms | 56% → 9% |
| typing | 18.2 / 30.7 → 30.5 / 30.5 | 83 → 0 | 45 → 2.7 ms | 429 → 5 ms | 56% → 5% |

xherdr now draws every frame Herdr sends. The frame rate is limited by Herdr, not by the app. After a clear or a tab switch, a cold layout of the whole grid takes about 5 ms at 311×80, down from about 28 ms.

### Keystroke to screen

Measured with the `keys` workload on a 120×48 grid:

| | before | after |
|---|---|---|
| p50 | 16.8 ms | 2.5 ms |
| p95 | 22.0 ms | 4.4 ms |
| max | 25.0 ms | 4.8 ms |

Herdr echoes a key in about 0.3 ms. Before the fix, each keystroke wrote `nil` to `HerdrStore.inputError`, a `@Published` property. SwiftUI then updated the whole window, holding the main thread for about 8 ms before the echo frame could be shown. The store now publishes `inputError` only when it changes. What remains is about 0.7 ms to send the input and about 1.3 ms (p50) from the echo frame to the draw, which is mostly waiting for AppKit's next display pass.

# Workspace measurements

The file explorer, Git bar, repository panel, diffs and documents get their data from `WorkspaceFiles`. Every git, SSH or shell command goes through `WorkspaceFiles.run`, which reports it to `WorkspaceProcessLog`. With `XHERDR_METRICS_FILE` set, each command becomes a `proc` event, labeled with its command (for example `git status`) and whether it ran over SSH. User-visible operations become `span` events, from the moment they start until their result is on screen:

- `file-list`
- `git-bar`
- `repository`
- `commit-files`
- `open-file`, `open-change` and `open-commit`
- `diff-patch` and `diff-highlighted`

## Benchmarks: `scripts/workspace-bench.sh`

This script runs `xherdrTests/WorkspaceFilesBenchmarks` in a Release build. Every operation the UI performs is timed and its processes counted. The operations run against two disposable repositories:

- `small`: 40 files, 30 commits.
- `large`: 20,000 files, 400 commits, and a 5,000-line file with a third of its lines changed.

Both repositories are built once and reused. They live under `/private/tmp/xherdr-bench` locally, and under `/tmp/xherdr-bench` on an SSH target. The SSH target is the first enabled Herdr machine that answers; set it with `XHERDR_BENCH_SSH_TARGET`, or set that variable to `none` to skip SSH. Results go to `build/perf/`, and the script compares them with `files-baseline.jsonl`.

## Baseline (2026-09-29, Mac16,5; SSH to an OrbStack VM with a 40 ms handshake)

| operation | processes | local small | local large | SSH small | SSH large |
|---|---|---|---|---|---|
| refresh (file list + Git bar + repository panel) | 13 | 202 ms | 631 ms | 1731 ms | 1775 ms |
| file-list | 3 | — | 302 ms | 412 ms | 403 ms |
| git-bar | 6 | — | 282 ms | 702 ms | 771 ms |
| repository | 4 | 77 ms | 250 ms | 469 ms | 619 ms |
| open-file | 0 local, 1 SSH | — | 0.2 ms | 121 ms | 217 ms |
| open-change (staged and unstaged) | 4 | — | 166 ms | 472 ms | 1162 ms |
| diff-sides | 1–2 | — | 37 ms | 240 ms | 469 ms |
| parse-big-diff, plain / highlighted (CPU) | 0 | | 55 / 482 ms | | |

What the numbers show:

- **Every process costs.** Locally, git runs through `/usr/bin/env git`, which resolves to the `/usr/bin/git` shim. The shim takes about 30 ms per call, against 12 ms for the git it forwards to. Over SSH, each command opens a new connection with no multiplexing, and costs about 120 ms even on a 40 ms VM; a real remote adds its round trips on top.
- **A refresh runs 13 processes, and 4 of them are duplicates.** The Git bar and the repository panel each load `repository()`, and `git rev-parse` runs three times. Over SSH, a refresh takes about 1.8 s, whatever the repository's size.
- **Syntax colors for a large diff take about 0.5 s of CPU.** This work runs off the main thread, after the plain patch is already on screen.
- Opening a local file is immediate. The editor itself (CodeEditSourceEditor) is not measured here.

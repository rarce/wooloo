# Terminal pipeline measurements

A Herdr surface travels this path before it is on screen:

1. **Receive and decode** (stream thread, `HerdrSurfaceStream.run` → `HerdrSurfaceDecoder`): a socket frame becomes a complete `HerdrSurface` or patches the current one.
2. **Deliver** (main thread, `HerdrStore.surface`): each surface is published and SwiftUI updates the views that observe the store.
3. **Layout** (main thread, `TerminalPaneView.layoutGrid`): cells become fills, glyph runs and underlines.
4. **Draw** (main thread, `HerdrTerminalTextView.draw`): Core Graphics draws the grid.

Three tools measure it. All of them also check that no information is lost on the way.

## Unit tests: `xherdrTests`

Run them with `xcodebuild test` and the scheme `xherdr`, using the build flags from `AGENTS.md`.

- `SurfaceDecodingTests` encodes synthetic workloads (`SurfaceFixtures.swift`): ASCII, color and Unicode scrolling, typing, and complete frames. After every frame, the app's decoder and an independent `ReferenceSurfaceDecoder` must both produce the expected screen. Stale or baseless patches must be rejected.
- `TerminalRenderingTests` checks the laid-out grid cell by cell. Every visible symbol must have a glyph in its column, and every colored background and underline must be kept. Nothing may be left over from the previous frame. The test also compares 2× pixel snapshots in `xherdrTests/Snapshots`. The snapshots depend on the installed terminal font; re-record them with `TEST_RUNNER_XHERDR_RECORD_SNAPSHOTS=1`.
- `SurfaceTraceReplayTests` runs only from `scripts/terminal-e2e.sh`; see below.

## Stage benchmarks: `scripts/terminal-bench.sh`

This script times decode, layout and draw per frame over the synthetic workloads (200×60, 240 frames) in a Release build. The `burst` stage pushes every frame through all three stages, as the main thread handles a burst today. Results go to `build/perf/`, and the script compares them with `bench-baseline.jsonl`. Pass `--save-baseline` to replace the baseline.

## End to end: `scripts/terminal-e2e.sh`

This script starts a dedicated `xherdr-perf` Herdr session and opens a Release build on it with `XHERDR_METRICS_FILE` and `XHERDR_SURFACE_TRACE` set. It then runs these workloads in the pane:

- `ascii`, `color` and `unicode`: 250 lines/s for 5 s
- `typing`: 40 characters/s
- `burst`: `cat` of 60,000 lines

For each workload, the script reports:

- frames received and drawn
- revisions never drawn
- main-thread latency from receive to deliver
- layout and draw time
- latency from arrival to draw
- main-thread busy share

It compares them with `e2e-baseline.json`. The script then replays the recorded trace through the reference decoder. Every revision the app drew must match what Herdr sent, and the last frame received must have been drawn. The xherdr window must stay visible during the run.

Signposts in the `dev.xherdr.terminal` subsystem (`decode`, `layout`, `draw`) show the same stages in Instruments, with or without the metrics file.

## Baseline (2026-09-29, Mac16,5, FiraCodeNFM 12 pt)

Stage benchmarks, 200×60 grid, per frame:

| scenario | decode p50 | layout p50 | draw p50 | burst fps |
|---|---|---|---|---|
| ascii-scroll | 0.76 ms | 13.5 ms | 1.1 ms | 63 |
| color-scroll | 0.75 ms | 15.5 ms | 2.4 ms | 52 |
| unicode-scroll | 0.77 ms | 14.9 ms | 1.1 ms | 57 |
| typing (1 cell) | 0.04 ms | 15.7 ms | 1.6 ms | 56 |
| full-frames | 0.77 ms | 15.9 ms | 2.4 ms | 49 |

Live, 311×80 window:

| workload | Herdr fps | drawn fps | revisions never drawn | layout p50 | arrival→draw p50 / p95 | main busy |
|---|---|---|---|---|---|---|
| ascii | 43.5 | 16.8 | 177 of 288 | 29.5 ms | 44 / 54 ms | 65% |
| color | 43.5 | 14.9 | 189 of 288 | 31.7 ms | 48 / 56 ms | 65% |
| unicode | 38.6 | 13.6 | 166 of 256 | 32.1 ms | 48 / 70 ms | 56% |
| typing | 30.7 | 18.2 | 83 of 204 | 26.5 ms | 45 / 57 ms | 56% |

Layout dominates. It rebuilds the whole grid for every revision, even a one-cell patch, and it runs once for every surface delivered.

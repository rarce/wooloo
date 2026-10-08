# Terminal pipeline measurements

A Herdr surface travels this path before it is on screen:

1. **Receive and decode** (stream thread, `HerdrSurfaceStream.run` → `HerdrSurfaceDecoder`): a socket frame becomes a complete `HerdrSurface` or patches the current one. With `surface_scroll`, scrolling output arrives as each pane's row shift plus only the rows that still differ.
2. **Deliver** (`HerdrSurfaceMailbox` → `HerdrSurfaceFeed`): the stream thread keeps only the newest surface and wakes the main thread once. The feed hands the surface straight to the terminal view. SwiftUI sees only `HerdrStore.surfaceLayout`, which changes when panes do.
3. **Layout** (main thread, `TerminalPaneView.layoutGrid`): cells become fills, glyph runs and underlines, row by row. A row whose cells, cursor and images match a row of the previous grid reuses that row's layout, so scrolled output only lays out new lines; row fingerprints find the match. Core Text shapes a new row's text in pieces split at long runs of blanks, and `TerminalShapeCache` keeps each piece's glyphs.
4. **Draw** (main thread, `HerdrTerminalTextView.draw`): Core Graphics draws only the rows that changed.

Three tools measure it. All of them also check that no information is lost on the way.

## Unit tests: `woolooTests`

Run them with `xcodebuild test` and the scheme `wooloo`, using the build flags from `AGENTS.md`.

- `SurfaceDecodingTests` encodes synthetic workloads (`SurfaceFixtures.swift`): ASCII, color and Unicode scrolling, typing, and complete frames. After every frame, the app's decoder and an independent `ReferenceSurfaceDecoder` must both produce the expected screen. Stale or baseless patches must be rejected.
- `TerminalRenderingTests` checks the laid-out grid cell by cell. Every visible symbol must have a glyph in its column, and every colored background and underline must be kept. Nothing may be left over from the previous frame. The test also compares 2× pixel snapshots in `woolooTests/Snapshots`. The snapshots depend on the installed terminal font; re-record them with `TEST_RUNNER_WOOLOO_RECORD_SNAPSHOTS=1`.
- `SurfaceTraceReplayTests` runs only from `scripts/terminal-e2e.sh`; see below.

## Stage benchmarks: `scripts/terminal-bench.sh`

This script times decode, layout and draw per frame over the synthetic workloads (200×60, 240 frames) in a Release build. `scroll-shift` is ASCII output sent as scrolled patches. The `burst` stage pushes every frame through all three stages, with no frames coalesced. `layout` reuses rows from the previous sampled state, as the view does. `layout-cold` lays out every row from text never shaped before, and `layout-seen` lays out every row from text shaped before, as a tab switched back to. Every stage except `layout-seen` starts with an empty shape cache. Results go to `build/perf/`, and the script compares them with `bench-baseline.jsonl`. Pass `--save-baseline` to replace the baseline.

## End to end: `scripts/terminal-e2e.sh`

This script starts a dedicated `wooloo-perf` Herdr session and opens a Release build on it with `WOOLOO_METRICS_FILE` and `WOOLOO_SURFACE_TRACE` set. It then runs these workloads in the pane:

- `ascii`, `color` and `unicode`: 250 lines/s for 5 s
- `graphics`: 100 lines/s for 5 s, every tenth line a different 192×96 PNG shown over 24×4 cells with the Kitty graphics protocol (`q=2`, so the terminal answers nothing), like a notebook or an agent printing plots between output
- `typing`: 40 characters/s
- `burst`: `cat` of 60,000 lines
- `keys`: 100 letters typed into `cat`, one every 100 ms. The keys go through wooloo's own `keyDown`, sent by the typing probe (`WOOLOO_TYPING_PROBE`, triggered with `notifyutil -p dev.wooloo.typing-probe`), so no accessibility access is needed. The probe is compiled only with the `WOOLOO_PROBES` condition, which the script sets.
- `mouse`: splits the pane and turns on SGR mouse reporting in the new pane, whose `cat` echoes the reports Herdr writes for it. The mouse probe, enabled by the same flag, then plays three phases through the view's own mouse handlers: `mouse-click`, 40 clicks, one every 100 ms, in the pane without mouse reporting, after one unrecorded click that selects it (`notifyutil -p dev.wooloo.mouse-probe.click`); `mouse-scroll`, 40 wheel events of 3 lines, alternately up and down, over the mouse-aware pane (`.scroll`); and `mouse-drag`, a 2 s drag of the split 6 cells each way and back, one move every 40 ms (`.drag`). Wheel events enter at `HerdrTerminalTextView.scrollPane`, below `scrollWheel`, because AppKit cannot make a scroll `NSEvent` at a window location.
- `split`: splits the pane and streams the `ascii` output into one pane and the `color` output into the other at the same time, 250 lines/s each for 5 s.
- `selection`: during `ascii` output, drags a text selection diagonally across a pane without mouse reporting, one move every 40 ms for 4 s (`notifyutil -p dev.wooloo.mouse-probe.select`).
- `resize`: during `ascii` output, which starts after a marker the script waits for, changes the window's content size 16 times, one every 400 ms, alternately shrinking it by 240×160 points and restoring it (`dev.wooloo.ui-probe.resize`).
- `tabs`: opens a second tab showing earlier `unicode` output beside the first tab's `color` output, then switches between them 20 times, one every 300 ms, through `HerdrStore.select(tabID:)` as the tab row does (`dev.wooloo.ui-probe.tabs`).

For each workload, the script reports:

- frames received and drawn
- revisions never drawn
- main-thread latency from receive to deliver
- layout and draw time
- latency from arrival to draw
- for workloads that stream (over 15 frames a second), the longest pause between draws of new revisions and the number of pauses over 50 ms, leaving out the first and last 5 draws
- the longest decode; decoding takes well under 1 ms, so a longer one means the stream thread was not running
- latency from arrival to screen, estimated (see below)
- main-thread busy share
- for `keys`, keystroke-to-screen latency, split into:
  - `queue`: from the event's timestamp until `keyDown` runs
  - `send`: from `keyDown` until the input is written to the socket
  - `herdr`: from the write until the echo frame is received (the first frame whose cursor moved)
  - `render`: from receiving that frame until it is drawn
  - `screen`: from the event's timestamp until the estimated refresh that shows the echo
- for the `mouse` phases, `selection`, `resize` and `tabs`, per event:
  - `publishes`: `HerdrStore` change notifications (`publish` events), each of which makes SwiftUI update the window
  - `view updates`: `update` events with `rev: null`, the terminal view's SwiftUI updates
  - `frames`: frames Herdr sent
  - `drawn`: the latency from the event's timestamp to the draw that shows its effect. For clicks, wheel events and split drags, that is the first draw of the next frame Herdr sends, for the events that made Herdr redraw. For `selection`, it is the next draw, since the selection is drawn locally. For `resize`, it is the first frame at a new grid size. For `tabs`, it is the first complete surface, which is the other tab's projection. For `resize`, it is also split into `send` (the event to the new size written to the socket, a `resize` event), `herdr` (from there to the first frame at the new size) and `render` (from that frame to its draw).
  - `screen`: the latency from the same timestamp to the estimated refresh that shows it

**When a draw reaches the screen.** `draw` returns once the view has drawn into its layer. Core Animation commits the layer when the main thread's turn ends; the window server composites the commit at the next display refresh and shows it at the one after. The metrics record a `commit` event on the main thread's next turn after each draw and a `vsync` event for each refresh the terminal view's display link reports (`TerminalVsyncRecorder`, macOS 14 `NSView.displayLink`), with the time that refresh's frame reaches the screen. `terminal-perf.py` takes the first `commit` after a draw, the first refresh at or after it (extrapolated from the refresh period when the display link missed some while the main thread was busy) and that refresh's target time. macOS exposes no commit or presentation callback to an `NSView`, so this is an estimate, good to about one refresh. On the 120 Hz display measured below it adds 12–15 ms at p50 to every draw: about half a refresh waiting for the next one, plus the refresh the window server takes to show it.

`WOOLOO_E2E_LOAD=N` keeps N busy processes (`yes > /dev/null`) running during the workloads, to see how wooloo holds up on a loaded machine. These runs are not compared with the baseline.

The window's content size is fixed with `WOOLOO_E2E_WINDOW` (default 1600x1000), so runs compare the same grid whatever size your own wooloo window was saved at. The live results below before this option used a 311×80 window. `e2e-baseline.json` now uses the fixed size, a 120×48 grid on the machine below.

It compares them with `e2e-baseline.json`. The script then replays the recorded trace through the reference decoder. Every revision the app drew must match what Herdr sent, and the last frame received must have been drawn. The wooloo window must stay visible during the run.

Signposts in the `dev.wooloo.terminal` subsystem (`decode`, `layout`, `draw`) show the same stages in Instruments, with or without the metrics file.

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

wooloo now draws every frame Herdr sends. The frame rate is limited by Herdr, not by the app. After a clear or a tab switch, a cold layout of the whole grid takes about 5 ms at 311×80, down from about 28 ms.

### Keystroke to screen

Measured with the `keys` workload on a 120×48 grid:

| | before | after |
|---|---|---|
| p50 | 16.8 ms | 2.5 ms |
| p95 | 22.0 ms | 4.4 ms |
| max | 25.0 ms | 4.8 ms |

Herdr echoes a key in about 0.3 ms. Before the fix, each keystroke wrote `nil` to `HerdrStore.inputError`, a `@Published` property. SwiftUI then updated the whole window, holding the main thread for about 8 ms before the echo frame could be shown. The store now publishes `inputError` only when it changes. What remains is about 0.7 ms to send the input and about 1.3 ms (p50) from the echo frame to the draw, which is mostly waiting for AppKit's next display pass.

### Mouse events

Measured with the `mouse` workload on a 126×48 grid, on 2026-10-02 under machine load 9–18:

| phase | publishes per event, first run → now | frames per event, first run → now | event to screen, p50 / p95 |
|---|---|---|---|
| mouse-click (40) | 0 → 0 | 1 → 0 | — |
| mouse-scroll (40) | 0 → 0 | 1 → 1 | 1.0 / 3.3 ms |
| mouse-drag (48 moves) | 0.35 → 0 | 1 → 1 | 7.7 / 21.6 ms |

Clicks and wheel events published nothing already, which confirms live the fixes that made clicks, split drags and repeated snapshots publish only changes. The first run found two more costs:

- **Every click sent `pane.focus`, and Herdr answers it with a complete surface** (45 KB here), even for the pane it already focuses, about 100 ms later. `HerdrStore.select(paneID:)` now skips the request when the snapshot shows Herdr already focuses that pane (`HerdrStoreTests.testClicksInTheFocusedPaneDoNotFocusItAgain`).
- **A split drag published the snapshot about 8 times a second**: each ratio change changes only its `layouts`, which the window reads only for panes the live surface does not show. `HerdrStore.receive` now keeps such a snapshot without publishing (`HerdrStoreTests.testLayoutOnlyChangesUnderTheLiveSurfaceDoNotPublish`).

Each drag move that changes the ratio still costs a complete surface from Herdr and a cold layout of it, about 5 ms at the time (0.5–1.4 ms after the changes below).

### Screen time and the window workloads (2026-10-06)

Measured on a 113×48 grid at 120 Hz, under machine load 5–11. The two runs agree to within a few milliseconds.

| workload | arrival→draw p50 | arrival→screen p50 / p95 | drawn fps / Herdr fps |
|---|---|---|---|
| ascii | 1.2 ms | 15.3–15.8 / 19–24 ms | 32–42 / 32–43 |
| keys (event→screen) | 0.8–2.1 ms | 14.3 / 18.5–18.8 ms | — |
| split (two panes streaming) | 2.9–3.3 ms | 16.2–16.6 / 20–21 ms | 43–44 / 43–44 |
| selection drag during output | 0.9–1.2 ms (event→draw) | 14.7–16.6 / 20–21 ms | 56 / 56 |
| resize during output | 25 ms (event→draw) | 38–39 / 46–48 ms | 49–51 / 50–53 |
| tabs | 25–31 ms (event→draw) | 40–45 / 48–55 ms | — |

- **Every draw waits 12–15 ms for the screen.** Arrival-to-draw is 1–3 ms for output, keys and selection drags, so the display refresh dominates what a user sees.
- **Two panes streaming at once** still draw every frame Herdr sends, with layout about 2 ms at p50 and the main thread 10–13% busy.
- **A selection drag during output** costs nothing visible: the next draw shows it about 1 ms after the event, and Herdr's frame rate is unchanged.
- **A resize** takes 25 ms from the window size change to the first frame Herdr sends at the new size being drawn, and 7–12 of about 300 revisions were never drawn during the run. That is mostly Herdr re-laying out and answering with a complete surface.
- **A tab switch** takes 25–31 ms to draw and makes the store publish 3 times and the terminal view update 4 times per switch. Delivery to the main thread reaches 13–19 ms at p95, against 1–7 ms for output, so SwiftUI's updates of the window hold the main thread while the new tab's surface waits.

The graphics workload is not written yet.

### Tab switches (2026-10-06)

The window showed the terminal view only while the live surface's panes were the selected tab's. A switch changed the selected tab at once, but Herdr's surface for the new tab came 2–7 ms later, so in between SwiftUI replaced the terminal view with the pane text. When the surface arrived, its `surfaceLayout` publish made SwiftUI build a new terminal view, lay the surface out again from scratch and wait for another display pass before drawing it. `HerdrStore.showsLiveSurface` now keeps the terminal view, still showing the previous tab, until the new tab's surface arrives, for at most 0.5 s. That first surface no longer publishes, since the window already shows it (`HerdrStoreTests.testTabSwitchKeepsTheLiveSurfaceUntilTheNewTabsArrives`).

| | before | after (3 runs) |
|---|---|---|
| event → draw, p50 | 25–31 ms | 7–13 ms |
| event → screen, p50 | 40–45 ms | 21–28 ms |
| publishes / terminal view updates per switch | 3 / 4 | 2 / 1 |

In the last run, Herdr answered in 2.7–4.2 ms and the surface was drawn 8–10 ms after it arrived. Delivering it waits for the SwiftUI update that the selection's two publishes cause (until about 6.5 ms after the click), and the draw then waits for the next display pass. In another run, three switches waited 114–134 ms for Herdr's answer.

### The stream thread under load (2026-10-06)

The surface stream, a blocking read loop, ran in a `.utility` task. On a loaded machine, the system ran other work first, and the thread stood still for up to 0.4 s while the main thread was idle. A frame read after such a pause was usually replaced in the mailbox by the next one before it was drawn, so arrival-to-draw latency did not show it. The pauses between draws and the keystroke echo did. The stream now runs on its own thread at `.userInteractive` priority (`BlockingWork.run(qualityOfService: .userInteractive, limited: false)`), which also stops it from holding a thread of Swift's cooperative pool. Decoding still takes about 0.1–0.3 ms a frame.

Measured with `WOOLOO_E2E_LOAD=16` on a 16-core machine, with the load average reaching 24–123 because other work was running too:

| phase | before: pauses >50 ms, longest | after: pauses >50 ms, longest | drawn fps, before → after |
|---|---|---|---|
| ascii | 21–29, 163–192 ms | 0–1, 39–108 ms | 17–22 → 22–26 |
| color | 21–22, 394–443 ms | 0–3, 41–72 ms | 26 → 40–42 |
| keys, write → echo received, p50 | 21–32 ms | 0.2 ms | — |

Earlier, a `.userInitiated` task was tried on an idle machine and showed no difference in frame rate, which is expected: priority only matters when the cores are busy.

### Graphics (2026-10-06)

Herdr 0.9.3 turns Kitty images that a program writes into graphics in the surface, and wooloo draws them. In a `graphics` run, 280 of 293 frames placed graphics, up to 4 at once, and the trace replay matched every drawn revision, graphics included. The replay compares surfaces, not pixels.

| | graphics | ascii (baseline, a similar frame rate) |
|---|---|---|
| frames received / drawn per second | 26.7 / 26.6 | 28.1 / 27.1 |
| MB received in the phase | 14.6 | 1.3 |
| decode p50 / p95 | 120 / 201 µs | 96 µs p50 |
| layout p50 | 0.21 ms | 0.39 ms |
| draw p50 / p95 / max | 0.14 / 0.24 / 1.0 ms | 0.08 ms p50 |
| arrival → draw p50 / p95 | 0.85 / 2.3 ms | 0.87 ms p50 |
| main thread busy | 1.2% | 1.6% |

wooloo decodes each image once (`HerdrTerminalTextView.prepareGraphics`) and keeps it while Herdr retains it, so drawing a frame costs little more than drawing text. The cost is in what Herdr sends: while graphics are on screen, every frame is a complete surface (about 39 KB at 113×48) instead of a scrolled patch, and each new image adds its PNG (about 74 KB here). That is 11 times the bytes of the same output without images.

### Window resizes (2026-10-06)

A resize took about 25 ms from the window's size change to the first frame at the new size being drawn. The metrics now record when the new size is written to the socket. In a run under load average 44:

| part | p50 | p95 |
|---|---|---|
| send: window size change → new size written | 4.9 ms | 10.7 ms |
| herdr: new size written → first frame at that size received | 73 ms | 318 ms |
| render: received → drawn | 1.9 ms | 3.9 ms |

wooloo's share is about 7 ms. It writes the new size in the SwiftUI update that reports the new geometry and draws the frame like any other. The rest is Herdr re-laying out the panes and sending a complete surface, which grows with load: an estimated 18 ms under load average 5–11 (the 25 ms measured then, less wooloo's share), 73 ms under 44. The view keeps showing the previous surface until then. Sending the size from the view's own layout would save a few milliseconds at most.

Running `resize` on its own used to start the probe before a new session's shell had run the output command, so the window was resized with no output and the output outlived the app. The script now waits for a start marker and the end marker.

### Layout and scrolled patches (2026-10-06)

Profiles of the layout (`sample` on a benchmark loop) found:

- **Comparing rows copied every cell.** Reusing a scrolled row checks it against the previous grid's row with `RowKey ==`, and the synthesized `ArraySlice ==` copies each `HerdrCell`, retaining and releasing its symbol: 72% of a scrolling frame's layout. Rows now compare field by field in place.
- **A new row compared against every previous row** until one matched. Beside an empty pane, every row shares a long prefix with every other, so a screen of new rows cost about 1 ms extra at 200×60 and 2.5 ms at 311×80. Rows now carry a fingerprint (a hash of each cell's bytes read in place), and only rows with the same fingerprint are compared whole. It costs about 20 µs a frame.
- **Every color lookup copied the theme.** `TerminalPalette` passed one of its own caches `inout` to a method on itself, which made Swift copy the palette and its theme: about 20% of a cold layout.
- **Appending a glyph copied the run's arrays**, because `runs.last` was bound to a constant first.
- **Core Text shaping is half of a cold layout**, and it shaped every blank cell too. Rows are now shaped in pieces split at 8 or more blanks, keeping up to 8 blanks around each piece. In Fira Code no substitution starts at or replaces a space, and none looks further than 6 glyphs (a `calt` rule for Greek capitals uses the space as context), so the pieces get exactly the glyphs the whole row gets. `TerminalRenderingTests.testShapingInPiecesMatchesWholeRows` checks ligatures across 1 to 12 blanks against shaping the whole row. Each piece's glyphs are cached by its text and bold/italic ranges.

Herdr 0.9.3 also offers `surface_scroll`: instead of a patch that rewrites every row of a scrolling pane, it sends the pane's row shift and only the rows that still differ (see `docs/herdr-connection.md`). Its `surface_reuse` and `surface_delta` encodings did not change the frames for scrolling output.

Stage benchmarks, 200×60, the same machine, both runs under load 5–15:

| scenario | layout p50 before → after | cold layout p50 before → after | layout of text seen before | burst fps before → after |
|---|---|---|---|---|
| ascii-scroll | 577 → 206 µs | 3.8 → 2.1 ms | 0.86 ms | 471 → 639 |
| color-scroll | 708 → 308 µs | 5.9 → 3.8 ms | 1.09 ms | 293 → 365 |
| unicode-scroll | 642 → 294 µs | 5.3 → 3.9 ms | 0.94 ms | 502 → 671 |
| typing | 336 → 119 µs | 5.4 → 3.1 ms | 0.92 ms | 449 → 640 |
| full-frames | 405 → 122 µs | 6.1 → 3.8 ms | 1.08 ms | 290 → 375 |

`scroll-shift`, the ascii workload sent as scrolled patches, decodes in 63 µs at p50 against 209 µs for the same output as plain patches.

Live, 113×48 grid. Live numbers vary up to threefold between runs on a loaded machine (load 6–28 during these runs), so the first two columns come from back-to-back runs before and after the layout changes; the bytes received do not depend on load:

| workload | layout p50, before → after layout changes | arrival→draw p50, before → after | main busy, before → after | MB received in the run, plain → scrolled patches |
|---|---|---|---|---|
| ascii | 1.77 → 0.99 ms | 3.05 → 2.31 ms | 9.1% → 6.1% | 8.0 → 1.3 |
| color | 1.87 → 1.16 ms | 4.19 → 3.45 ms | 13.8% → 10.7% | 10.9 → 1.9 |
| unicode | 2.38 → 1.56 ms | 3.93 → 3.25 ms | 13.5% → 10.4% | 5.3 → 0.8 |
| mouse-drag | 6.80 → 1.43 ms | 7.74 → 2.94 ms | 10.7% → 3.3% | 1.95 → 1.95 |

With scrolled patches as well, two later runs decoded ascii frames in 120–240 µs at p50 instead of about 330 µs, and drew them 0.8–2.3 ms after arrival. Keystroke to screen took 0.7–1.1 ms at p50 in those runs. `e2e-baseline.json` holds the slower of the two.

# Workspace measurements

The file explorer, Git bar, repository panel, diffs and documents get their data from `WorkspaceFiles`. Every git, SSH or shell command goes through `WorkspaceFiles.run`, which reports it to `WorkspaceProcessLog`. With `WOOLOO_METRICS_FILE` set, each command becomes a `proc` event, labeled with its command (for example `git status`) and whether it ran over SSH. User-visible operations become `span` events, from the moment they start until their result is on screen:

- `file-list`
- `git-bar`
- `repository`
- `commit-files`
- `open-file`, `open-change` and `open-commit`
- `diff-patch` and `diff-highlighted`

## Benchmarks: `scripts/workspace-bench.sh`

This script runs `woolooTests/WorkspaceFilesBenchmarks` in a Release build. Every operation the UI performs is timed and its processes counted. The operations run against two disposable repositories:

- `small`: 40 files, 30 commits.
- `large`: 20,000 files, 400 commits, and a 5,000-line file with a third of its lines changed.

Both repositories are built once and reused. They live under `/private/tmp/wooloo-bench` locally, and under `/tmp/wooloo-bench` on an SSH target. The SSH target is the first enabled Herdr machine that answers; set it with `WOOLOO_BENCH_SSH_TARGET`, or set that variable to `none` to skip SSH. Results go to `build/perf/`, and the script compares them with `files-baseline.jsonl`.

## Before (2026-09-29, Mac16,5; SSH to an OrbStack VM with a 40 ms handshake)

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

## After sharing SSH connections, loads and the real git

`files-baseline.jsonl` now holds the numbers after three changes:

1. **SSH connections are shared.** `ssh` runs with `ControlMaster=auto` and `ControlPersist=60`, with sockets in `/tmp/wooloo-ssh-<uid>`, a directory only the user can use. Commands after the first skip the handshake. Commands without input also get `/dev/null` as stdin, since SSH would otherwise forward the app's own stdin, which cost about 15 ms per call.
2. **A refresh loads the repository once.** The Git bar and the repository panel share one `repository()` load (`SharedLoads`, kept for 2 s). Git operations the app runs, and every explicit refresh, forget it, so a change is never hidden. `SharedLoadsTests` checks this.
3. **Local git runs without the shim.** `xcrun --find git` is resolved once, and `/usr/bin/git` is used only if it fails.

Measured under heavy machine load (load average 13–25, from parallel builds), so local numbers here are pessimistic:

| operation | processes | local large, before → after | SSH large, before → after |
|---|---|---|---|
| refresh | 13 → 9 | 631 → 197 ms | 1775 → 767 ms |
| repository | 4 | 250 → 47 ms | 619 → 321 ms |
| git-bar | 6 | 282 → 87 ms | 771 → 498 ms |
| open-change | 4 | 166 → 50 ms | 1162 → 327 ms |

Over SSH, a command through the shared connection takes 11–15 ms against a normal `sshd`. The OrbStack VM used here answers through OrbStack's own SSH proxy. After about 60 sessions on one connection, its commands go back to about 80 ms each, so its SSH numbers are noisy. For example, the small repository's refresh took 103 ms in the same run.


## After batching SSH commands

Over SSH, the commands of one load now run as a single remote script (`WorkspaceFiles.gitBatch`). The script prints each command's exit status and the lengths of its output and errors before them, so each command still fails or succeeds on its own. The listing is one script. The Git bar's status and repository are another, and the repository panel shares that result. The work tree root (`git rev-parse --show-toplevel`) is kept for 2 s like the repository, so the listing and the repository load no longer both look it up. Failed SSH commands are logged with their exit status and stderr (subsystem `dev.wooloo.workspace`), and `proc` events carry a `status` field.

Measured on 2026-10-02 under heavy machine load (load average 25–34), against the OrbStack VM, where a single SSH command took about 100 ms in this run:

| operation | processes, SSH | SSH small, before → after | SSH large, before → after | local large, before → after |
|---|---|---|---|---|
| refresh | 10 → 2 | 381 → 81 ms | 1041 → 283 ms | 260 → 254 ms (10 → 9 processes) |
| file-list | 4 → 1 | 389 → 36 ms | 414 → 145 ms | unchanged |
| git-bar | 6 → 1 | 598 → 46 ms | 614 → 128 ms | unchanged |
| repository | 4 → 1 | 391 → 39 ms | 402 → 117 ms | unchanged |

When the repository panel loads before the Git bar, the Git bar reads its status in a script of its own, and a refresh takes 3 round trips instead of 2. The baseline file still holds the earlier numbers.

## One round trip per refresh

Over SSH, the listing, the Git bar and the repository panel now read one remote script (`WorkspaceFiles.remoteRefresh`), with the branch status, the root check, the listing and the repository. Outside a work tree, the failed root check makes the script list the folder with `find`, so a refresh is one round trip there too. The script is shared through `SharedLoads` like the repository: the Git bar, which loads once the listing arrives, and the repository panel reuse a script that ran less than 2 s ago, while the listing, which also follows saves and file operations, joins one that is running but never reuses a finished one. `forgetRecentResults()` forgets it. Locally nothing changed.

Measured on 2026-10-02 under machine load 10–14, against the OrbStack VM, compared with the run above (load 25–34, so the SSH gain is partly the lower load):

| operation | SSH round trips | SSH small, before → after | SSH large, before → after |
|---|---|---|---|
| refresh | 2 → 1 | 81 → 64 ms | 283 → 175 ms |
| file-list alone | 1 | 36 → 67 ms | 145 → 178 ms |
| git-bar alone | 1 | 46 → 70 ms | 128 → 179 ms |
| repository alone | 1 | 39 → 69 ms | 117 → 176 ms |

Each load alone now runs the whole script, so it costs about what a refresh does. In the app the Git bar never loads alone, since it follows the listing; the repository panel does when it is expanded.

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
- for `keys`, keystroke latency, split into the parts below. `total` (the event to its echo drawn into the view's layer) and `screen` (the event to the estimated refresh that shows it) are different measures: `screen` adds the 12–15 ms wait for the display described below.
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

### Keystroke to draw

Measured with the `keys` workload on a 120×48 grid. These are `total` times: from the key event to the echo frame drawn into the view's layer, not to the screen. They predate the screen estimate below, which adds about 12–15 ms at p50 on a 120 Hz display; the screen time of these runs was not recorded.

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

### Drawing what answers the user at once (2026-10-13)

`HerdrSurfaceFeed` marks the surface that answers input just sent, and the first surface of a tab switched to; the terminal view draws those as soon as it has laid them out (`displayIfNeeded()`), instead of in the next display pass. A tab switch also no longer tells SwiftUI about the new selection right away: the store selects the tab at once, so commands act on it, but the window learns of it after the new tab's first surface is drawn, in the next turn of the run loop, or after `HerdrStore.selectionPublishWait` (50 ms) without one. Until then the terminal view still names the previous pane, so typed input for it goes to the new tab's pane; mouse events keep the pane under the pointer (`HerdrStoreTests.testInputDuringATabSwitchGoesToTheNewPane`). Only text, keys and pastes mark the next surface as an answer, and only if it comes within `HerdrSurfaceFeed.answerWindow` (100 ms), so a key that changes nothing does not make a later frame of output draw early. Any other change to the selection while a switch waits is published at once.

Live, 132×48, p50, `main` against the change; the second run of each, after the review fixes, at load 8–10:

| | before | after |
|---|---|---|
| tab switch: surface received → drawn | 8.6 ms | 2.9–4.8 ms |
| tab switch: click → drawn | 12.1–14.3 ms | 8.8–12.9 ms |
| tab switch: click → screen | 23.9–29.4 ms | 17.0–28.7 ms |
| tab switch: click → drawn, p95 | 26.1 ms | 16.6 ms |
| tab switch: publishes per switch | 2 | 1 |
| keys: echo received → drawn | 1.04–2.75 ms | 0.90–1.05 ms |

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

With scrolled patches as well, two later runs decoded ascii frames in 120–240 µs at p50 instead of about 330 µs, and drew them 0.8–2.3 ms after arrival. A keystroke took 0.7–1.1 ms at p50 from the key event to its echo drawn into the layer (`total`) in those runs; that excludes the display. `e2e-baseline.json` holds the slower of the two runs; its `keys` phase has `key_total_p50_ms` 0.82 and an estimated event to screen (`key_screen_p50_ms`) of 13.6 ms at p50 (14.4 ms p95).

### Cells by row (2026-10-13)

A patch is applied on the stream thread to the decoder's copy of the surface while the main thread still holds the surface it showed, so the first change copied the whole cell array (about 1 MB at 311×80). `HerdrSurface.cells` is now a `HerdrCellRows`, an array of rows indexed like the flat array, so a patch copies only the rows it writes. A scroll at least half as wide as the surface swaps whole rows; cells outside the scrolled region, such as the pane's borders, swap back only where the two rows differ there, which they rarely do, so such a scroll copies no row it does not rewrite. A narrower region swaps its own cells in place, copying each of its rows at most once: a 60-column pane scrolling beside a 251-column pane full of text at 311×80, the worst case, decodes in 110 µs at p50 against 100 µs on `main`, which copied the whole array once. A complete surface is read straight into rows of the previous surface's width, or of the width the hello asked for, and regrouped with one copy when the width changed (a new 311×80 surface: 311 µs, against 334 µs on `main`). `SurfaceDecodingTests.testScrollsOfPanesSideBySideKeepTheOtherPane` scrolls panes beside each other against the reference decoder.

Stage benchmarks, 200×60, decode p50: `scroll-shift` 63 → 6.4 µs, `typing` 42 → 1.8 µs; `ascii-scroll` (plain patches that rewrite every row) and `full-frames` are unchanged within noise. Live at 132×48, patches during `ascii`, `color` and `unicode` decoded in 53 µs at p50 (107 µs p95) against 80 (180) µs on `main` in a run just before.

### Layers per row: measured and not taken (2026-10-13)

Scrolling output moves every row, so the view redrew all of them: 1.1–2.3 ms per frame at 200×60 in the stage benchmarks. A branch drew each row on a layer of its own (with the parts of overhanging glyphs from the rows beside it) and moved the layer of a row that only moved. The benchmarks drew a scrolling frame in 0.11–0.22 ms instead, but live it cost more:

| workload, 132×48 | whole view, draw p50 | layer per row, draw p50 (about 7 rows) | main busy, whole view → layers |
|---|---|---|---|
| ascii | 0.17–0.18 ms | 0.42–0.46 ms | 4.3% → 5.6–6.5% |
| unicode | 0.47 ms | 0.60 ms | 7.4% → 8.3% |
| color | 0.81–0.97 ms | 0.66 ms | 7.3% → 7.2% |

Time to screen did not change (15.3–16.0 ms p50 either way). In a window, AppKit records a view's drawing and rasterizes it away from the main thread, so drawing every row costs the main thread little, while every layer drawn costs Core Animation a backing store of its own: about 0.3 ms a row when displayed synchronously, 0.1 ms drawn into an image, 60 µs drawn asynchronously. The stage benchmarks draw into a bitmap on the CPU, which is why they overstate a whole redraw; read their `draw` column as relative, not as main-thread time.

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

## Commands of the refresh script at once

The commands of an SSH batch (`WorkspaceFiles.remoteBatchScript`) now run as background jobs of the remote shell, each into its own temporary files, and the script prints their sections in the original order once all have finished, so a batch costs about its slowest command instead of their sum. A gate (the root check) runs once the commands before it have started, and the commands after it only once it passed; when it fails, the fallback listing runs while the branch status finishes. The output format is unchanged, and the script now always exits 0, so a failing last command no longer fails the whole batch. The script is plain POSIX `sh` and was checked with `dash`, BusyBox `ash`, `mksh` and `bash` on the VM. Its signal trap also covers SIGPIPE: without a terminal, sshd sends no SIGHUP when the client goes away, so a script whose client timed out learns it only when it prints, and `dash` and BusyBox died there without running the EXIT trap, leaving the temporary folder behind.

This is safe because a batch only reads. Its git commands run with `GIT_OPTIONAL_LOCKS=0`, so neither `git status` tries to take `index.lock` to write back a refreshed index; without that variable `git status` also gives up the write quietly when the lock is taken. 100 rounds of all the refresh's commands at once, after touching every file so the index was out of date, printed no error and the same status every time, with and without the variable, on this Mac and on the VM. `WorkspaceFilesRemoteTests` keeps the old script as a reference and checks that both print the same sections, with the system `sh` and `dash`, including failures and a failed root check with and without its fallback, and that concurrent refreshes of a repository with a stale index never fail.

Before the old script was removed, a benchmark switch ran the batches one command after another, to compare. Measured on 2026-10-09 against the OrbStack VM, alternating the two modes twice under machine load 20–35, p50 of 10 repetitions. A single SSH command (`open-file`) took 105–120 ms in these runs, so most of each refresh is the round trip:

| operation | SSH small, one by one → at once | SSH large, one by one → at once |
|---|---|---|
| refresh | 151–153 → 143–146 ms | 205–214 → 192–193 ms |
| file-list alone | 144–146 → 142–147 ms | 208–212 → 191–195 ms |
| repository alone | 145 → 141–145 ms | 207–212 → 194–195 ms |

The script alone, run with `sh` in the large repository without SSH, took 59 → 49 ms at p50 on the VM and 332 → 215 ms on this Mac under load 25–40. A remote with more cores or a slower disk gains more; a single-core remote gains little, since the work is the same.

### At most twice the processor count at once

A refresh starts ten commands. None is redundant: the two `git status` differ (the Git bar's branch status leaves out untracked files, the listing's lists each file), and the `git ls-files` beside the listing's two feed the link check. Each `git status` or `git ls-files` reads the whole index, so on a remote with few processors running them all at once only adds memory. Measured on 2026-10-14 in a 100,000-file repository on the OrbStack VM, with the refresh's commands in a copy of the batch script, CPUs limited with `taskset`, memory as the peak of a cgroup around 9 runs, p50 time:

| CPUs | all at once | twice the CPUs at once |
|---|---|---|
| 1 | 383 ms, 170 MB | 382 ms, 85 MB |
| 2 | 266–271 ms, 164–168 MB | 282–284 ms, 94–96 MB |
| 4 | 226–233 ms, 157–162 MB | 229–236 ms, 150–160 MB |
| 15 | 205–208 ms, 155–167 MB | 207–208 ms, 158–167 MB |

On their own, each `git status` peaked at 49 MB, each `git ls-files` at 27 MB and the other commands at 10 MB; the link check, which tests every listed path in `sh`, took 180 of the 205 ms. One at a time saved a little more memory on one CPU (64 MB) but cost 21 % on 2 CPUs and 41 % on 15; a fixed 4 cost 22 % on 15. The script now starts its commands in groups of twice the remote's processor count (`nproc`, else `getconf _NPROCESSORS_ONLN`, else all at once), each group once the previous one finished. Batches on this Mac already run one command at a time, so nothing changed locally, and the workspace benchmark against the VM (15 CPUs) did not change beyond noise.

## Waiting for a process's exit

Some benchmark runs measured small-repository SSH loads at 130–160 ms instead of 57–77 ms, and timing the process runner showed `ssh` ending 60–90 ms after its output. `ssh` was not late. A kqueue `NOTE_EXIT` watch on each process, with the end of its output and the return of the wait timed beside it, gave this over a whole benchmark run against the OrbStack VM (2026-10-14, Mac16,5, load 6–9):

| | processes | exited more than 30 ms after the end of the output | wait returned more than 30 ms after the exit | wait after the exit, median |
|---|---|---|---|---|
| SSH, `Process.waitUntilExit()` | 250 (46 batches) | 0 | 234 (31 batches) | 63.5 ms |
| SSH, termination handler | 250 (46 batches) | 0 | 0 | 0.02 ms (at most 0.5 ms) |
| local, `Process.waitUntilExit()` | 454 | 0 | 2 | 0.03 ms (at most 445 ms) |
| local, termination handler | 454 | 0 | 0 | 0.02 ms (at most 0.1 ms) |

From the end of its output, `ssh` exited within 0.12 ms at p95 and 2.2 ms at most in both runs.

`waitUntilExit()` waits by running the calling thread's run loop. When the loop has a source, as the main thread's does, it notices the exit only when a turn of the loop ends; without one it returns at once. The benchmarks call `WorkspaceFiles` on the test's main thread, where the waits were late in some stretches of a run and not in others, likely as sources came and went; that, not SSH, made some runs slow. In the runs below, single-process SSH operations such as `open-file` took 100–137 ms instead of 20–27 ms. The ControlMaster session was not involved: run directly, the same batch over the shared connection ended its output, closed it and exited within 1 ms, 40 times out of 40. In a test program, the first wait on a new thread and 2–8 % of the later ones were late by about 135 ms too, so the app's `BlockingWork` threads were also affected, though less often.

`WorkspaceFiles.run` now sets the process's `terminationHandler`, which Foundation calls from a dispatch queue once it has the exit status, and waits on a semaphore it signals. `HerdrConfig.validate` (`herdr config check` when saving settings) and the tests' `WorkspaceGitSandbox.sh` and benchmark setup wait the same way. `WorkspaceFilesIntegrationTests.testResultComesBackWhenTheCommandExits` runs 15 commands on a thread whose run loop has a timer and 15 on one without sources: with `waitUntilExit()` their medians were 67 and 2 ms, with the handler 2 ms each.

Foundation calls the handler on a utility-QoS queue, and a semaphore lends no priority, so a waiting thread of higher QoS depends on utility work. That queue is also where Foundation collects the exit status: right after a kqueue `NOTE_EXIT`, `isRunning` was still true in 185 of 200 runs, so `waitUntilExit()`, or a kqueue or dispatch process source at the caller's QoS, would wait for the same work. Measured in a test program on a `.userInitiated` thread, from the exit to the return of the wait, 300 runs each, under 16 and 32 busy `yes` processes on 16 cores: the handler took 0.75 and 0.03 ms at p95, 3.5 and 17 ms at most, and `waitUntilExit()` 138 and 137 ms at p95.

`run`'s timeout and output limit now follow SIGTERM with SIGKILL 2 s later, so a command that ignores SIGTERM no longer holds its caller and its `BlockingWork` slot until it ends (`testTimedOutCommandThatIgnoresTerminationIsKilled`).

Alternating `waitUntilExit()` and the termination handler twice (p50, 5 repetitions):

| operation | SSH small, `waitUntilExit()` → handler | SSH large, `waitUntilExit()` → handler |
|---|---|---|
| refresh | 63–64 → 59–62 ms | 202–206 → 107–108 ms |
| file-list | 65–66 → 62–70 ms | 210–215 → 105–110 ms |
| git-bar | 63 → 61–62 ms | 208–209 → 106–108 ms |
| repository | 62–69 → 62–67 ms | 202 → 103–106 ms |
| open-file | 100–122 → 21–27 ms | 127–137 → 20–25 ms |
| commit-diff | 103–117 → 24–25 ms | 122–130 → 23 ms |
| open-change | 486–510 → 77–80 ms | 475–505 → 79–80 ms |
| folder-walk, `tree` | 163–167 → 59–65 ms | |

In these runs the small repository's batches happened to be in their fast state with `waitUntilExit()` too, so they did not change; with the handler, the p95 of every SSH operation was within 9 ms of its p50. Local operations did not change beyond noise.

## Syntax colors for diffs

`ParsedDiff` with both sides parsed each whole file with tree-sitter, ran the highlight query over it, and placed every capture on its lines. Sampled on the benchmark's diff, each side spent about 40 % parsing, 35 % in the query (half of it in SwiftTreeSitter building capture names, which the app can't avoid through its API) and 25 % finding each capture's first line with a linear search over the line starts.

1. **Captures find their line by binary search**, and are sorted by length and position instead of being deduplicated in a dictionary. The capture name is looked up once per capture index. One side took about 70 instead of 90 ms.
2. **The old file serves only removed lines.** It is skipped when nothing was removed, and queried with one cursor per run of removed lines (`QueryCursor.setRange`), which even for a run every third line costs less than querying the whole file.
3. **The old file is parsed by editing the new file's tree** at each change, after checking that the text between changes is the same on both sides; otherwise it is parsed whole. How much tree-sitter reuses depends on the grammar: for a 5,000-line file with two one-line edits, JavaScript took 4.7 instead of 22 ms, Rust 3.5 instead of 15 ms, Python 12 instead of 22 ms, Swift 36 instead of 44 ms, and Go 25 ms either way.
4. **The diff view adds colors to the patch it already parsed** (`ParsedDiff.withSides`), which saves the 23 ms the benchmark's plain parse takes.

Running the two sides on two threads made them slower than running them one after the other (two concurrent parses took 110 ms against 37 ms for one), so they stay serial.

`DiffHighlighterTests` checks the colors against the previous implementation, kept as `ReferenceDiffHighlighter`, on the benchmark file, a source file, mixed Unicode, and diffs from `git diff --no-index` that open and close comments and strings or change the first and last lines. Seeded random line edits in Swift, JavaScript, Python, Rust and Go, with and without a final newline and with CRLF, check that the old file parsed by editing the new tree colors every line as a whole parse does, and that querying runs of lines colors them as querying the whole file does.

Measured on 2026-10-09, alternating runs of main and this change (9 repetitions, load 3–10 from other builds):

| operation | local small, before → after | local large, before → after |
|---|---|---|
| parse-big-diff-highlighted | 192–201 → 151 ms | 190–196 → 148 ms |

Three one-line edits in the same 5,000-line Swift file took about 105 ms instead of 180 ms. Parsing is now about half of what remains.

## The walk of a folder outside Git

Outside a work tree, Go to File and the explorer list a folder with `WorkspaceFiles.folderWalk`: in Swift on this Mac, and with a `find` script over SSH. The benchmark walks two folders built beside the repositories (`walk-tree` and `walk-huge` in the results):

- `tree`: 20,000 files in 1,040 folders, with a skipped `node_modules`, read in full within the time limit.
- `huge`: one folder of 150,000 files below the root, read with a 0.05 s limit (1 s over SSH, where the script counts whole seconds).

Locally, the `folder-walk-script` operations run the SSH script with `/bin/sh` instead of the Swift walk. That measures the alternative of one script for both, which was not taken:

| operation | before | after |
|---|---|---|
| tree, Swift on this Mac | 136–137 ms | 37–41 ms |
| tree, the script on this Mac | 247–263 ms | 250–280 ms |
| tree, SSH | 163 ms | 145 ms |
| huge, Swift on this Mac, 0.05 s limit | 730–862 ms, read in full | 55 ms, stopped with 72,704 files |
| huge, SSH | 222 ms | 207 ms, read in full within 1 s |

Measured on 2026-10-09 (Mac16,5, load 8–28 from other builds, 5 repetitions), against the OrbStack VM (dash, GNU find).

1. **The Swift walk reads folders with `readdir`.** `FileManager.contentsOfDirectory` read each folder whole, with resource values for every entry. `readdir` gives the entry type directly, and only folders are asked whether they are packages. The walk looks at the clock every 256 entries, so a huge folder is stopped inside once the time is up.
2. **Over SSH, a watchdog stops the running `find`.** It sleeps for the limit, marks the time as up and stops the `find` whose process ID the batch left for it; the batch checks the mark and ends. A name the stopped `find` printed only in part is dropped. Batches no longer run `date`, which saved a process each, and skipped folders are printed by `find` itself between two marker records rather than through `-exec printf`, which a stopped `find` would leave running.
3. **One script for both was not taken.** Run locally, it took six times as long as the Swift walk on `tree`, and `find` cannot leave out macOS packages. The two implementations follow one specification instead (above `WorkspaceFiles.folderWalkScript`). `WorkspaceFilesRemoteTests` runs both on the same folders, with odd names, links, pipes, unreadable and skipped folders and the depth limit, and requires the same files.
4. **Over SSH, the walk stops at `maximumFiles` names, also in the root.** The root has no time limit, so a remote root with hundreds of thousands of entries printed them all: 400,000 entries with 90-character names made 38 MB, past the 32 MB output limit, and the listing failed. The script's records now go through `head`, with NUL and newline swapped around it by `tr`, which stops the walk after `maximumFiles` names and up to 1,000 markers; a final `wooloo-end` record that did not arrive marks the walk truncated, as on this Mac, and the explorer says the folder has more files. The same root now prints 19 MB in 310 ms instead of 38 MB in 450–470 ms, run on the VM without SSH (2026-10-14). Once `head` is done it marks the walk's temporary folder, and the next `find` ends the walk, also in the folder being read: until `tr` flushes its buffer, writes into the pipe still succeed, so without the mark a walk cut in the root kept reading every level until its time was up. Links are described with one `readlink` each, about 0.6 ms on one CPU, for every link `find` collected: a root of 400,000 links printed over 32 MB and was still running after 2 minutes, and a folder of 150,000 links, read in full, would take about 95 s. The walk now collects links first in each batch, so a cut walk still has those it lists, and keeps only the first 5,000 (`folderWalkMaximumLinks`, about 3 s on one CPU). On one CPU of the VM, the 400,000-link root now prints 18.6 MB in 3.3 s, the 150,000-link folder takes 3.4 s, and a root of 400,000 files with a linked folder prints 19.1 MB in 220 ms, the linked folder listed and described.
5. **Skipped folders no longer count against the files.** `head` counted every record, skipped folders and the two markers each batch printed around them included, so a tree with more than about 1,000 of them was cut, and marked truncated, before `maximumFiles` files. Skipped folders are now collected in a file and printed after `wooloo-end`, between `wooloo-skipped` and `wooloo-files`; the files' `head` stops at `maximumFiles` + 3 records (one name more than the maximum, and the empty record, `wooloo-partial` and `wooloo-end` after it). A second `head` keeps files, linked and skipped folders within `maximumFiles` + 1,003 records, about what the one budget allowed, so the output's bound is unchanged: with 105-byte paths, 201,003 records make 21.1 MB, and the 5,000 links described in full about 1 MB more. Skipped folders it cuts are left out; the files were all read, so the walk is not partial for that. The script runs in the C locale: in a UTF-8 one, BSD `tr` stops at a name that is not UTF-8, and the records after it would run together. On the VM, a root of 2,000 folders, each with a `node_modules` and 100 files, listed 199,193 files and 1,792 skipped folders, truncated, and now lists all 200,000 files, not truncated, and 1,000 skipped folders, in 0.25 instead of 0.28 s on one CPU. The same tree with 60-character folder names, 40-character file names and a folder of 60,000 long-named linked folders printed 21.13 MB before and 21.14 MB now.
6. **Linked folders are described past the first 5,000 links.** Each batch keeps at most 55,000 links instead of counting those collected so far, and the 50,000 after the first 5,000 (`folderWalkMaximumFolderLinks`) are looked at with the shell's `[ -L ]` and `[ -d ]`, about 7 µs each against 0.6–1 ms for a `readlink` (20,000 links: 0.15 s against 15.7 s on one CPU). Those checks stop once the walk's time is up. The linked folders among them are listed before the skipped folders, within the second `head`, and described without a target, so the explorer shows them as folders. On one CPU, a root of 120,000 links, half of them to a folder, lists 27,500 linked folders instead of 2,500, in 4.1 instead of 3.8 s, and prints 13.2 instead of 11.0 MB. Describing every listed link was not taken: it would cost about 1.5 s more for 200,000 links, and no more fits within the output's bound.

Run directly on the VM without SSH, alternating main and this change 15 times each, two rounds (2026-10-14, the Mac at load 14–80 from other work):

| script, p50 | before | after |
|---|---|---|
| `tree`, Go to File (no links) | 40.2–40.8 ms | 41.0–41.4 ms |
| `tree`, explorer (links) | 60.2–62.2 ms | 55.3–56.7 ms |
| `huge`, Go to File, 1 s limit | 88.4–89.8 ms | 90.3–90.7 ms |
| `huge`, explorer, 1 s limit | 118.2–118.8 ms | 116.9–117.0 ms |

With the first version of this change, `scripts/workspace-bench.sh` over SSH gave 68 → 74 ms for `walk-tree` and 146 → 149 ms for `walk-huge` at load 32–68, and a second run of main at load 83 gave 201 and 336 ms, so its walk rows were within the noise of that load.

## Markdown tables

`scripts/markdown-bench.sh` measures the actual SwiftUI Markdown preview in Release: first render (host creation through layout and paint), a resize from 1000×800 to 780×800, a subsequent cached draw, and a scroll to the end (including a 10 ms run-loop turn to build newly visible blocks). It runs three repetitions of prose, ten small tables (80 body rows), one tall table (100 rows), and a wide table (12 columns), in both Theme and Document styles. The fixtures contain alignment, wrapping, links, inline code and Unicode. Ordinary unit tests skip the timing suite.

Results include the exact input SHA-256, viewport, typography, OS, hardware and machine load. A changed document is not compared with the saved one. The table snapshots check alignment, wrapping, borders and alternating row colors in documents containing multiple tables; the existing Markdown preview snapshots retain their original references. `MarkdownPreviewRenderingTests` checks that Find still reaches a table beyond the initial viewport in both styles. The benchmark also runs the checkbox and double-click source-action tests.

```sh
scripts/markdown-bench.sh
scripts/markdown-bench.sh --check
scripts/markdown-bench.sh --baseline docs/perf/markdown-before.jsonl
scripts/markdown-bench.sh --save-baseline
WOOLOO_BENCH_MARKDOWN_FILE=/absolute/path/document.md scripts/markdown-bench.sh
```

`--check` fails for a missing or changed workload, incompatible viewport/typography, or a median increase over both 25% and 10 ms. Run without competing CPU-heavy work when checking a baseline. `WOOLOO_BENCH_REPEAT` changes the repetitions; `WOOLOO_DERIVED_DATA` changes the build directory. An optional local document stays outside the repository; its contents and path are not written to the results. The checked-in baselines cover only the synthetic fixtures.

The preview now constructs top-level blocks on demand instead of building every table before displaying the start of a document. Individual tables still lay out all of their rows, so the tall-table workload also measures the cost of a large visible table. Table text remains native SwiftUI text. GitHub-style borders are painted together from cell bounds, rather than creating a geometry reader, two style reductions and decoration views for every cell. Default tables with no cell decorations skip that geometry entirely. Custom table styles retain their existing decoration path.

Measured on 2026-10-15, Mac16,5, macOS 26.6.2, three repetitions, Document style (median):

| workload | first render before → after | cached draw before → after | resize before → after |
| --- | --- | --- | --- |
| many small tables | 4925 → 135 ms | 2999 → 41 ms | 3114 → 51 ms |
| 100-row table | 5555 → 943 ms | 3298 → 52 ms | 3361 → 138 ms |
| 12-column table | 2219 → 426 ms | 1324 → 47 ms | 1381 → 95 ms |

`markdown-before.jsonl` holds the pre-change measurements and `markdown-baseline.jsonl` the optimized reference, with SHA-256 fingerprints of the renderer sources. The style comparison also avoids expired unsafe buffer pointers, so changing a heading or table color correctly invalidates the environment. The original single-document Markdown snapshots remain unchanged; the new multi-table snapshots verify consistent alternating row colors and independent table geometry.


## Jupyter notebook preview

`scripts/notebook-bench.sh` measures the actual `NotebookPreviewView` in Release, including its 150 ms edit debounce, off-main-thread JSON parsing, WebKit startup, bundled assets, rendered text indexing and the first viewport capture. The source JSON is already in memory; file I/O and Source-editor setup are excluded. A separate `parse` phase measures parsing/projection without WebKit. The other phases match the Markdown suite: resize from 1000×800 to 780×800, cached viewport capture, and scroll to the end of both the page and nested output areas (including horizontal dataframe overflow). Lazy image height changes are included until the final page bottom is reached. WebKit renders in another process, so captures use `WKWebView.takeSnapshot` after layout, fonts and visible image decoding, using its `afterScreenUpdates` paint barrier; AppKit's `cacheDisplay` would not measure the final web content. Capture phases include this synchronization and image-transfer overhead, and are not frame-rate or pure JavaScript timings.

The deterministic format-4.5 fixtures cover 20 Markdown cells, ten Markdown tables, a 100-row HTML dataframe, a 12-column HTML dataframe, 100 mixed math/code/output cells, a multi-megabyte saved stream (display truncation remains active), and twelve saved PNG plots. Every workload runs in both Theme and Document styles, seven times by default to reduce WebKit image-loading variance. The timing test holds a user-initiated, latency-critical activity to avoid App Nap and timer coalescing between windows. The test verifies cell/table/image counts, actual viewport resizing and reaching the bottom, and records input/source SHA-256, cell/DOM-node counts, typography, machine, OS and load. Package resolution stays pinned to the versions in `main`, which are also recorded in the results. It requires neither Python nor a live kernel and does not read private notebooks.

```sh
scripts/notebook-bench.sh
scripts/notebook-bench.sh --check
scripts/notebook-bench.sh --baseline /path/to/reference.jsonl
scripts/notebook-bench.sh --save-baseline
WOOLOO_BENCH_REPEAT=5 scripts/notebook-bench.sh --check
```

The shared preview comparator (`scripts/markdown-perf.py --kind Notebook`) fails `--check` for median increases over both 25% and 10 ms in parsing or synchronous JavaScript range construction. Notebook viewport captures (first render, resize, cached draw, scroll and Find paint) use 25% and 50 ms: unchanged-code controls varied by up to 34 ms in those cross-process captures. Missing/changed workloads or incompatible viewport, typography, renderer or capture protocols also fail. Markdown retains its original 25% / 10 ms gate. Run on the same machine/OS without competing CPU-heavy work. `WOOLOO_DERIVED_DATA` selects the build directory. Notebook rendering/parser/resource tests and the two notebook snapshots run alongside the benchmark; ordinary tests skip timing measurements. A normal interaction test verifies that native Find reaches and expands a collapsed table beyond the first viewport after resizing, then checks the MIME selector.

The stress cases add a compact 5,000-row HTML table with 100, 1,000 and 5,001 Find matches, and a multi-megabyte source cell. Find timings separate synchronous JavaScript range construction (`find-*-ranges`) from the WebKit call through a completed viewport capture (`find-*-paint`). The native `DocumentFindModel` supplies UTF-16 offsets and every resulting highlight is checked against the expected text. This isolates the DOM bottleneck; it excludes the Find-bar event, native regex scan and SwiftUI/coordinator update. The normal interaction tests cover that native update path, collapsed offscreen output, inline-node boundaries, emoji/combining marks and replacement of MIME nodes.

`notebook-before.jsonl` preserves the pre-optimization measurements; `notebook-baseline.jsonl` is the optimized reference. Both use the same fixtures, capture protocol, pinned dependencies and seven repetitions. `notebook-validation.jsonl` repeats the optimized renderer without code changes. The first optimized run raised four image-capture alerts under the initial 10 ms rule; these did not recur. The repeat also moved the 5,001-match Document capture from 21 to 55 ms while synchronous range construction stayed at 6 ms. These controls set the 50 ms capture noise floor; all three runs remain available, including the outliers. The notebook and Markdown suites use different capture paths and must not be compared as equivalent rendering costs. Process memory and CPU usage across WebKit's child processes are not measured here.

Find now indexes each matched group's text leaves once per call and locates match boundaries by binary search. It previously rebuilt and traversed the entire list for every match in a large output. The index remains local to the call so a MIME switch or document render cannot leave stale nodes. MathML accessibility duplicates remain excluded from search.

Text truncation walks only the permitted prefix and reuses the result for the source warning, rather than counting the entire string first (twice for source cells). The 500,000-grapheme limit, suffix and original Source document remain unchanged. Parser tests check below/exact/above-limit inputs, emoji and combining sequences across source, streams, errors, rich output and attachments.

The 150 ms edit debounce, eager cell creation and full rerender on palette changes remain opportunities for separate work. These measurements focus on the verified Find and truncation bottlenecks. Manual local testing also showed that the existing Find reveal logic centers the searchable output group, so an individual selected row in a very tall table can remain offscreen; locating that row is a separate correctness follow-up.

<!-- notebook-measurements -->
Measured on 2026-10-16, Mac16,5 / macOS 26.6.2, seven repetitions (median). Document style unless specified; timings include the activity and synchronization described above. These local wall-clock values remain sensitive to competing host work.

| Operation | Before → optimized |
| --- | ---: |
| Find 100 matches, through capture | 307.4 → 6.4 ms |
| Find 1,000 matches, through capture | 3027.7 → 8.6 ms |
| Find 5,001 matches, through capture | 15100.6 → 21.1 ms |
| Find 5,001 matches, Theme capture | 14874.6 → 64.1 ms |
| Find 5,001 matches, synchronous JS | 14998.0 → 6.0 ms |
| Parse 3.2 MB source cell | 416.0 → 44.7 ms |
| Parse 3.2 MB saved stream | 209.5 → 42.1 ms |

First viewport includes the debounce and parsing; parse is also measured separately and must not be added to it. The following table uses the first optimized run, including its noisier image capture values.

| Workload | First viewport before → after | Parse before → after | Resize after | Cached capture after | Scroll after |
| --- | ---: | ---: | ---: | ---: | ---: |
| 20 Markdown cells | 329.5 → 337.6 ms | 2.5 → 2.8 ms | 4.7 ms | 1.5 ms | 3.3 ms |
| 10 Markdown tables | 349.6 → 394.4 ms | 2.6 → 3.0 ms | 9.2 ms | 1.8 ms | 2.9 ms |
| 100-row HTML table | 336.3 → 393.7 ms | 2.6 → 3.6 ms | 12.9 ms | 3.0 ms | 3.7 ms |
| 12-column HTML table | 336.1 → 362.6 ms | 3.1 → 3.2 ms | 18.1 ms | 2.1 ms | 2.7 ms |
| 100 mixed cells | 448.6 → 467.2 ms | 3.0 → 2.9 ms | 13.7 ms | 2.3 ms | 5.1 ms |
| 3.2 MB saved stream | 667.1 → 525.1 ms | 209.5 → 42.1 ms | 12.8 ms | 1.9 ms | 2.7 ms |
| 12 saved PNG plots | 327.2 → 348.3 ms | 3.1 → 3.9 ms | 19.7 ms | 3.7 ms | 32.7 ms |
<!-- /notebook-measurements -->

## Comparing experiments

All suites now record a protocol version, model, macOS version, architecture, logical CPU count,
Xcode version, pinned package revisions, commit, tracked-dirty flag, load and fixture fingerprint.
Comparisons reject missing metadata, different environments/fixtures and added or missing cases
before printing ratios. Terminal stage comparisons also require the same grid/frame count/font;
workspace comparisons require the same SSH target; previews require the same viewport, fonts,
theme, renderer and capture protocol. Repetition counts and application source revisions may
change. A host load above 75% of logical CPUs prints a warning for either run; repeat idle before
attributing a timing difference to code. Load average is context, not measured application CPU.

Older references are intentionally incompatible: preserve any historical data needed for research,
then run the appropriate `--save-baseline` on the measurement machine. Do not add invented metadata
to an old run. E2E references have a sibling `e2e-baseline.metadata.json`; keep both files together.
A partial E2E workload run needs its own matching reference rather than a comparison against a full
run. Package updates are disabled in benchmark scripts so moving a checkout does not silently
upgrade its dependencies. Preview `--check` retains its timing thresholds; this change does not
add performance timing gates to CI.

Run comparator contract tests with `python3 -m unittest discover -s scripts/tests -v`.

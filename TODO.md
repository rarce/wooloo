# TODO

## UI responsiveness

- [ ] Investigate intermittent input latency when switching tabs quickly. It occurs in both **Files / Changes** and **History / Branches**, so diagnose it as an app-wide responsiveness issue rather than a Repository-specific problem.
  - Reproduce by alternating either pair of tabs rapidly; some clicks appear delayed or do not take effect immediately.
  - Profile the main thread during the delay and check whether live Herdr surface updates, SwiftUI view recomputation, or file and Git refreshes are occupying it. Compare a quiet session with one receiving frequent terminal updates.
  - Keep all Git, filesystem, and SSH work off the main thread, and verify that switching tabs responds consistently under live updates.
  - Since `ee67e20`, live surfaces no longer update SwiftUI on every frame (`HerdrSurfaceFeed`), and the terminal keeps the main thread 5–13% busy under streaming output. Re-check whether the delay remains.

## Terminal performance

Measure every change with `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh`; see `docs/perf/README.md`. xherdr now draws every frame Herdr sends (about 43 fps). Arrival to draw takes about 3 ms at p50 and 15–18 ms at worst.

- [x] Measure keystroke-to-screen latency: the `keys` workload in `terminal-e2e.sh`. Fixing a per-key SwiftUI update brought it from 16.8 to 2.5 ms at p50.
- [ ] Cut the ~1.3 ms (p50, 3 ms p95) between receiving an echo frame and drawing it. Try `displayIfNeeded()` right after a surface that answers recent input, and check that it does not add work under streaming output.
- [ ] Find what else publishes on the main thread per event. Mouse drags, scrolling and selection still go through `HerdrStore` and may update SwiftUI the way `inputError` did. Measure them with the `update` events, which have `rev: null`.
- [ ] Measure when a frame reaches the screen, not only when `draw` returns; the compositor adds up to one display refresh.
- [ ] Add end-to-end workloads for tab switches, resizes, split panes, graphics and a selection drag during output. None of them is covered yet.
- [ ] Cut the cold layout, about 5 ms at 311×80, which runs after a clear, resize or tab switch. Try caching glyphs per character and font for plain rows, keeping Core Text for rows that need shaping. Fira Code ligatures must still render, and the snapshots will show it if they do not.
- [ ] Bound the row matching in `TerminalGrid.row(matching:near:)`. A row with no match compares against every row of the previous grid, so a screen of all-new content costs rows² comparisons; fall back to a hash only for unmatched rows if it shows up in profiles.
- [ ] Cut the full redraw when scrolling, 1–2 ms at 200×60: every row changes position, so the whole view is invalidated. Consider moving the existing pixels (layer copy) and drawing only new rows. Consider a Metal glyph-atlas renderer only if Herdr's frame rate or grid sizes grow enough to need it.
- [ ] Decode, on the stream thread: every patch copies the whole cell array (about 1 MB at 311×80), because the main thread still holds the previous surface. Each frame is also copied from `Data` to `[UInt8]` and allocated anew in `readFrame`. Consider a row-chunked cell store so a patch copies only the rows it touches.
- [ ] Check whether Herdr's optional retained or delta encodings (`surface_reuse` and `surface_delta`, both off in the endpoint hello) reduce the bytes per frame, and what limits Herdr to about 43 fps under streaming output.

## Workspace performance

Measure with `scripts/workspace-bench.sh`; see `docs/perf/README.md`.

- [x] Share SSH connections, load the repository once per refresh, and run git without the `/usr/bin/git` shim. A local refresh of a large repository dropped from 631 to about 200 ms, and over SSH from 1.8 s to about 0.8 s.
- [ ] Batch the SSH commands of one refresh into a single remote script. Each command still costs a round trip, which the local VM hides, but a remote over the internet will not.
- [ ] Cut the `git rev-parse` calls that `listing` and `repository` each make for the same root.
- [ ] Syntax colors for a large diff take about 0.3–0.5 s of CPU (`parse-big-diff-highlighted`). Profile `ParsedDiff` with old and new sides.
- [ ] Once, the first SSH command of a benchmark run failed with its output complete but a nonzero exit, and it did not happen again. If it recurs, log SSH's exit status and stderr, and check how shared connections behave when the master expires.

## Terminal

- [ ] Fix mouse text selection in panes running Claude Code. Selection works in a plain shell (for example after `ls`) but is still unreliable while Claude Code is running.
  - Already in place: rows are pinned to the cell height, each glyph is kerned to its cell width so fallback-font symbols (⏺ ✻ ⎿, emoji, CJK) stay on Herdr's grid, and surface frames are deferred while `NSTextView` tracks a selection drag.
  - Next: confirm whether Claude Code enables mouse reporting for its pane (`mouseReportingPaneIDs`). If it does, clicks are forwarded to Herdr and selection needs Shift+drag or a Herdr-side selection; if it does not, check how selection behaves when frames resume after the drag and when Claude scrolls content under an existing selection.
  - Capture exactly how it fails (no highlight, wrong range, or highlight lost on release), in both windowed and full-screen modes.

## Editor

- [ ] Multiple cursors: ⌥⌘↑/↓ keeps the goal column in UTF-16 offsets, so tabs and wide characters shift it; use the text's display column instead. Also missing from Zed's set: ⌃⌘D (select previous occurrence, taken by macOS's Look Up unless disabled), Option-drag column selection, and ⌘U for selection changes made by clicks or arrows.

## Go to File and command palette

- [ ] Command palette: also list the explorer's own actions (New File, Rename, Copy Path…), as the editor's are, through a target the explorer registers.
- [ ] Symbol search in the open file (⇧⌘O) and across the Space (⌘T), or as `@` and `#` prefixes in Go to File. Postponed until there is a document outline panel to share its symbols with.
- [ ] Go to File without Git walks the whole folder up to `maximumFiles`, which is slow in a large non-repository folder such as `/private/tmp`; consider a time or depth limit, or reading only to the depth already listed.

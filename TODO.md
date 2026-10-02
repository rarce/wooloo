# TODO

## Open-source release

- [x] Review the history and the code for secrets, personal data and build artifacts. None were found apart from the commit email below; a local SSH alias in `docs/perf/files-baseline.jsonl` was replaced with a generic one.
- [x] Ask before reading agent sign-ins: the QUOTAS section is off until the user turns it on, reads this Mac's Keychain in-process, and never shows credential output in errors (`c3defc5`).
- [x] Sign ad hoc by default, so a clone builds without flags or a developer account (`c969796`).
- [x] Compile the typing probe only for `scripts/terminal-e2e.sh`, and create metrics and surface traces with mode 0600 (`249c33d`).
- [x] Keep create, rename, move, delete, discard and paste inside the Space through linked folders (`bb22647`).
- [x] Describe the current features in the README, with a screenshot, and set the GitHub description and topics.
- [ ] Decide whether to rewrite history to hide the personal commit email. Every commit so far is authored with a personal Gmail address, and only a history rewrite removes it. Future commits can use the GitHub noreply address.
- [ ] Check the use of the "herdr" name with Herdr's maintainers before announcing the project.
- [ ] Confirm the bundle identifier `dev.xherdr.app`: it implies the `xherdr.dev` domain. Change it if that domain is not ours.
- [ ] Before shipping binaries, turn on the hardened runtime (`ENABLE_HARDENED_RUNTIME`), sign with a Developer ID and notarize. Check that the test bundle still loads, since library validation may reject an ad hoc signed bundle.

## Terminal performance

Measure every change with `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh`; see `docs/perf/README.md`. xherdr now draws every frame Herdr sends (about 43 fps). Arrival to draw takes about 3 ms at p50 and 15–18 ms at worst.

- [x] Measure keystroke-to-screen latency: the `keys` workload in `terminal-e2e.sh`. Fixing a per-key SwiftUI update brought it from 16.8 to 2.5 ms at p50.
- [ ] Cut the ~1.3 ms (p50, 3 ms p95) between receiving an echo frame and drawing it. Try `displayIfNeeded()` right after a surface that answers recent input, and check that it does not add work under streaming output.
- [x] Find what else publishes on the main thread per event. Every click re-published `selectedPaneID`, a split drag without the endpoint re-published `surfaceError` up to 30 times a second, every Herdr event published its snapshot and a `nil` `errorMessage` even when unchanged, and the pane text poll and endpoint retry re-published each second. All of them now publish only changes (`HerdrStoreTests.testRepeatedEventsThatChangeNothingDoNotPublish`). Scrolling and selection drags did not publish. Checked by reading the code and with the test, not live.
- [x] Add a mouse workload to `terminal-e2e.sh` (clicks, scroll wheel, a split drag) that counts `update` events with `rev: null`, to confirm the fix above live. The `mouse` workload plays 40 same-pane clicks, 40 wheel events and a 2 s split drag through the view's handlers and counts store publishes and `rev: null` updates per event: clicks and wheel events published nothing. It also found that every click sent `pane.focus`, which Herdr answers with a complete 45 KB surface, and that a drag published the snapshot for layout-only changes 0.35 times per move; both are gone (0 publishes and 0 click frames now). Wheel events reach the screen in 1.0 ms at p50, drag moves in 7.7 ms.
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
- [x] Batch the SSH commands of one refresh. Over SSH the listing runs as one remote script, and the Git bar's status and repository as another, which the repository panel shares (`WorkspaceFiles.gitBatch`): 9 SSH commands per refresh became 2, and a large repository's refresh dropped from 1041 to 283 ms against the OrbStack VM.
- [x] Fold the listing into the Git bar's script too, so a refresh is one round trip. The listing, the Git bar and the repository panel share one remote script (`WorkspaceFiles.remoteRefresh`), which also lists a folder outside a repository with `find`: a refresh over SSH is 1 command instead of 2, and took 175 ms instead of 283 ms in the large repository (64 instead of 81 ms in the small one), though under lower machine load than before. Each load alone now runs the whole script.
- [ ] Run the commands of the SSH refresh script concurrently instead of one after another, if the remote's git tolerates two `git status` refreshing the index at once; a refresh would then cost its slowest command instead of their sum.
- [x] Cut the `git rev-parse` calls that `listing` and `repository` each make for the same root. The root is kept for 2 s like the repository (`gitRoots`), so a local refresh runs 9 processes instead of 10.
- [ ] Syntax colors for a large diff take about 0.3–0.5 s of CPU (`parse-big-diff-highlighted`). Profile `ParsedDiff` with old and new sides.
- [x] Log SSH's exit status and stderr. Failed SSH commands go to the unified log (subsystem `dev.xherdr.workspace`, credentials in URLs removed) and to `proc` events as `status`. An expiring `ControlPersist`, a master killed between commands, and 14 concurrent sessions all worked against the OrbStack VM. A master that dies while a command runs gives that command exit 255 with its output complete and nothing on stderr, which matches the failure seen once.

## Editor

- [ ] Multiple cursors: ⌥⌘↑/↓ keeps the goal column in UTF-16 offsets, so tabs and wide characters shift it; use the text's display column instead. Also missing from Zed's set: ⌃⌘D (select previous occurrence, taken by macOS's Look Up unless disabled), Option-drag column selection, and ⌘U for selection changes made by clicks or arrows.

## Go to File and command palette

- [ ] Symbol search in the open file (⇧⌘O) and across the Space (⌘T), or as `@` and `#` prefixes in Go to File. Postponed until there is a document outline panel to share its symbols with.
- [ ] Go to File without Git walks the whole folder up to `maximumFiles`, which is slow in a large non-repository folder such as `/private/tmp`; consider a time or depth limit, or reading only to the depth already listed.

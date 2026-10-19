# Terminal layout worker evaluation

This evaluates preparing a terminal grid on a serial worker. It does not enable a worker in
wooloo, reproduce a reported Claude scroll stall, or establish the cause of that report.
The report came from a version two minor releases behind the version under evaluation.

## Question and scope

Can moving `TerminalPaneView.layoutGrid` off the main thread free enough time for input and
other UI work to justify an additional asynchronous stage?

The current pipeline already reads and decodes surfaces on a dedicated user-interactive
thread. `HerdrSurfaceMailbox` retains the latest surface while main is busy, and
`HerdrSurfaceFeed` delivers it directly to the terminal view without a SwiftUI update per
frame. `HerdrTerminalTextView.show` still composites popups, prepares graphics, builds the
grid, and invalidates changed rows on main. `draw` also runs on main.

This experiment isolates grid layout. It does not offload graphics decoding, popup composition,
view state changes, row invalidation or drawing. Files/Git/SSH already use bounded blocking
workers with independent limits for each machine; adding more Git workers would not move
terminal layout off main or eliminate a main-thread stall.

## Existing app measurements

The merged [E2E reference](e2e-baseline.json) at 140×48 records the following layout costs.
These are earlier real-app measurements, not new worker results or measurements of Claude.
The pipeline microbench uses different fixtures and offscreen drawing; its timings must not
be substituted for these E2E numbers.

| Phase | Layout p50 | Layout p95 | Draw p95 |
| --- | ---: | ---: | ---: |
| ASCII | 0.81 ms | 1.55 ms | 0.31 ms |
| Color | 1.09 ms | 1.54 ms | 2.16 ms |
| Unicode | 1.82 ms | 3.13 ms | 1.15 ms |
| Keyboard echo | 0.32 ms | 0.60 ms | 0.07 ms |
| Synthetic wheel | 0.32 ms | 0.65 ms | 0.14 ms |

This leaves a credible opportunity for Unicode/heavy updates, but does not identify a stall
in the reported user's session. Moving layout cannot remove unrelated main-thread work,
Herdr/Claude response time, line-based trackpad accumulation or compositor delay.

## Reproduce

```sh
WOOLOO_BENCH_FRAMES=60 WOOLOO_BENCH_REPEAT=3 scripts/terminal-layout-eval.sh
# Use a dedicated DerivedData directory or a previously populated one:
# WOOLOO_DERIVED_DATA=/absolute/path/to/DerivedData
```

The opt-in XCTest is skipped in ordinary CI. The script builds Release with pinned packages,
records machine/toolchain/package/font/fixture/source metadata, and verifies the sources and
environment again after measurement. Results go to `build/perf/layout-eval-*.jsonl`.
This experiment has no timing pass/fail threshold and does not replace existing references.

It compares inline layout with a user-interactive serial queue, with exactly one frame in
flight. Each route starts with an empty shape cache and reuses its own preceding grid.
A second case clears both the row and shape caches before every frame: this is deliberately
pessimistic, not typical scrolling. Route order reverses on alternating repetitions.
Fixtures cover scrolled ASCII patches, Unicode/fallback shaping and typing/cursor updates.
Fonts, font-manager conversions and cell metrics are initialized on main before either route.
The worker uses an autorelease pool. It receives immutable input and finishes all Core Text
layout locally; grids contain copied glyph arrays, colors and fonts, not live CTLine/CTRun
objects. Views are only mutated and drawn on main.

A separate untimed paired pass hashes the rendered RGBA pixels of **every frame** and checks equality
between inline and worker preparation. Pixel extraction and hashing do not run in measured passes, since bitmap readback can affect
the next draw even when readback itself is outside a timed span.
This is pixel equivalence on this host, not a portable snapshot reference.

Metrics (microseconds):

- `prepare`: layout duration on the selected thread.
- `main-work`: inline layout plus apply/draw, or worker result apply/draw. This is measured
  execution duration, not total main-thread CPU utilization or an Instruments busy percentage.
- `ready-to-drawn`: from submitting an already-decoded surface to the end of offscreen drawing,
  including worker/continuation scheduling where applicable. This excludes decoding, server
  response, actual input, compositor presentation and time waiting for the initial main turn.
- `main-probe`: delay of one unrelated MainActor task queued immediately before preparation.
  It demonstrates availability in this synthetic scheduling pattern. It is **not** keyboard,
  trackpad, display-link or screen latency; there is no periodic event producer or overload.

The one-frame-at-a-time design intentionally excludes backlog/coalescing and stale-result
handling. Timing is not a production throughput measurement. No Claude process or user session
is accessed. Offscreen 2x bitmap drawing can cost more than dirty-row on-screen drawing.

## Paired results (2026-10-19)

Mac16,5, macOS 26.6.2, Xcode 26.6, arm64, FiraCodeNFM-Reg 12 pt, 2× bitmap drawing,
60 frames per fixture and three measured repetitions after a separate pixel-equivalence pass.
Both sizes passed all six pixel checks: 360 frame pairs per size, 720 total. Source/environment
verification passed. Raw files retain dirty-checkout and fixture/source provenance.

### 200x60

[Verified raw results](layout-evaluation-200x60-20261019.jsonl). Values below are milliseconds, shown as inline → worker.
Each cell is the median of the three per-repetition percentiles, not a pooled percentile.

| Fixture | Main work p50 | Ready→drawn p50 | Ready→drawn p95 |
| --- | ---: | ---: | ---: |
| scroll-shift-reuse | 1.097 → 0.980 | 1.098 → 1.120 | 1.238 → 1.253 |
| scroll-shift-cold | 3.384 → 1.030 | 3.385 → 3.317 | 3.539 → 3.492 |
| unicode-scroll-reuse | 1.052 → 0.894 | 1.053 → 1.076 | 1.158 → 1.174 |
| unicode-scroll-cold | 4.830 → 0.999 | 4.830 → 4.648 | 5.322 → 5.175 |
| typing-reuse | 1.234 → 1.144 | 1.235 → 1.266 | 1.317 → 1.332 |
| typing-cold | 4.484 → 1.236 | 4.486 → 4.364 | 4.589 → 4.489 |

### 311x80

[Verified raw results](layout-evaluation-311x80-20261019.jsonl). Values below are milliseconds, shown as inline → worker.
Each cell is the median of the three per-repetition percentiles, not a pooled percentile.

| Fixture | Main work p50 | Ready→drawn p50 | Ready→drawn p95 |
| --- | ---: | ---: | ---: |
| scroll-shift-reuse | 1.667 → 1.500 | 1.669 → 1.686 | 1.884 → 2.106 |
| scroll-shift-cold | 5.492 → 1.800 | 5.494 → 5.503 | 5.997 → 5.774 |
| unicode-scroll-reuse | 1.653 → 1.424 | 1.655 → 1.641 | 1.796 → 1.807 |
| unicode-scroll-cold | 7.568 → 1.655 | 7.570 → 7.369 | 7.775 → 7.666 |
| typing-reuse | 2.052 → 1.882 | 2.053 → 2.046 | 2.153 → 2.165 |
| typing-cold | 7.210 → 2.116 | 7.211 → 7.085 | 7.402 → 7.337 |

The synthetic main-probe p50 falls from roughly 1.07–7.60 ms inline to 0.012–0.028 ms
with the worker across the two sizes. This is the expected benefit of yielding main during
preparation; it must not be reported as a measured trackpad/keyboard improvement. Conversely,
311×80 reused scroll has a worse ready-to-drawn p95 (1.884 → 2.106 ms), despite less main work.
Small timing differences and cold-layout speedups should be interpreted as host/scheduling
variation, not reductions in the renderer's algorithmic work. Host load stayed below the
suite's 75%-of-logical-CPU warning threshold; these were not deliberate mixed-load tests.

## Decision

**Proceed with a bounded, opt-in production prototype only if testing current Claude under
concurrent UI activity confirms a layout-related stall. Keep the existing app path for now.**
The experiment establishes that grid preparation can run serially off main and produce identical
pixels on this host. It does not establish a visible scroll improvement. The main-thread
execution saved is small with row reuse and substantial with forced cold layout; completing
rendering is not consistently faster. A worker helps UI availability, not the total amount of
layout work, and will still wait for main to apply and draw its result.

This revises the initial recommendation to move layout immediately: the current row/shape
reuse already keeps typical preparation short, while the remaining production state-management
work is material. Treat the reported lag as unconfirmed on the current release. First reproduce
it, then distinguish event dispatch/main stalls, input write, Herdr/Claude response, layout,
draw and presentation. Other main-thread activity (for example opening a very long editor
line) would still delay a worker's final delivery and the processing of native input.

## Production integration requirements

A production implementation would need a bounded mailbox before layout (one running job and
one replaceable pending surface), not a task per frame. A worker must never block on main.
The accepted surface, grid, hit-testing state, selection and popup geometry must advance
together when a result is installed. Receiving newer metadata before its grid is visible can
otherwise send a click to content the user has not seen.

Use an explicit view/session generation and theme/font/geometry version to reject completed
work after a reset, reconnect, tab change, resize, theme change or view destruction. Avoid
starvation during sustained output: invalidating every result merely because a newer revision
arrived can prevent any frame from appearing. Preserve keystroke/tab-switch answer semantics,
including `displayIfNeeded`, and final-frame delivery after output stops.

Extract a renderer with explicit font/color inputs rather than relying on lazy AppKit state
inside an `NSViewRepresentable`. Keep mutable shape-cache state owned by the serial renderer
or protected as it is today. Do not send shared mutable attributed strings or Core Text layout
objects across workers. Retain main-thread ownership of view mutation and drawing.

Before enabling it, test stale completions and burst coalescing deterministically, then run
terminal pipeline benchmarks, reference replay and interactive E2E against an isolated Herdr
session. Add a real trackpad Claude case with output active and idle; record p95/p99 event to
send, server response, surface arrival to draw and main-thread stalls under concurrent editor,
search and workspace refresh activity. Check typing, selection, popup, resize, theme and tab
switches together. A healthy synthetic microbenchmark alone cannot justify changing the app.

## Validation

Signed Release builds passed for both worker evaluations and the existing terminal pipeline
benchmark. `scripts/terminal-bench.sh` accepted the unchanged fixture/reference metadata and
completed comparison successfully; its run-to-run timing differences are not worker speedups,
since app rendering code is unchanged. The signed Debug build and full CI-equivalent suite
passed: 1,020 tests, 12 skipped, zero failures. Font-dependent snapshot groups were excluded as
in CI. The 13 Python tooling contract tests, shell syntax check and `git diff --check` passed.

No production renderer changed, so this evaluation did not rerun terminal E2E or exercise a
worker in a live app window. Real Claude/trackpad reproduction and on-screen worker validation
remain prerequisites for enabling a production implementation, not completed checks.

## Sources

- [Current renderer](../../wooloo/TerminalPaneView.swift): `show`, `layoutGrid`, shape cache and drawing.
- [Surface delivery](../../wooloo/HerdrConnection.swift): stream priority, mailbox and feed.
- [Paired experiment](../../woolooTests/TerminalLayoutEvaluationTests.swift): `testLayoutWorkerEvaluation`.
- [Apple Core Text documentation](https://developer.apple.com/documentation/CoreText): functions
  are thread-safe; fonts can be shared, while layout objects belong to a single operation/queue/thread.
- [Apple Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html):
  AppKit threading constraints and autorelease pools on secondary threads.

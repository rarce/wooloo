# TODO

## UI responsiveness

- [ ] Investigate intermittent input latency when switching tabs quickly. It occurs in both **Files / Changes** and **History / Branches**, so diagnose it as an app-wide responsiveness issue rather than a Repository-specific problem.
  - Reproduce by alternating either pair of tabs rapidly; some clicks appear delayed or do not take effect immediately.
  - Profile the main thread during the delay and check whether live Herdr surface updates, SwiftUI view recomputation, or file and Git refreshes are occupying it. Compare a quiet session with one receiving frequent terminal updates.
  - Keep all Git, filesystem, and SSH work off the main thread, and verify that switching tabs responds consistently under live updates.

## Terminal

- [ ] Fix mouse text selection in panes running Claude Code. Selection works in a plain shell (for example after `ls`) but is still unreliable while Claude Code is running.
  - Already in place: rows are pinned to the cell height, each glyph is kerned to its cell width so fallback-font symbols (⏺ ✻ ⎿, emoji, CJK) stay on Herdr's grid, and surface frames are deferred while `NSTextView` tracks a selection drag.
  - Next: confirm whether Claude Code enables mouse reporting for its pane (`mouseReportingPaneIDs`). If it does, clicks are forwarded to Herdr and selection needs Shift+drag or a Herdr-side selection; if it does not, check how selection behaves when frames resume after the drag and when Claude scrolls content under an existing selection.
  - Capture exactly how it fails (no highlight, wrong range, or highlight lost on release), in both windowed and full-screen modes.

# TODO

## UI responsiveness

- [ ] Investigate intermittent input latency when switching tabs quickly. It occurs in both **Files / Changes** and **History / Branches**, so diagnose it as an app-wide responsiveness issue rather than a Repository-specific problem.
  - Reproduce by alternating either pair of tabs rapidly; some clicks appear delayed or do not take effect immediately.
  - Profile the main thread during the delay and check whether live Herdr surface updates, SwiftUI view recomputation, or file and Git refreshes are occupying it. Compare a quiet session with one receiving frequent terminal updates.
  - Keep all Git, filesystem, and SSH work off the main thread, and verify that switching tabs responds consistently under live updates.

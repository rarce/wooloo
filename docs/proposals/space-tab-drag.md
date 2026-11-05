# Space ordering and terminal tab relocation

## Protocol evidence

Verified against bundled/installed Herdr 0.9.5, protocol 22, and upstream tag
[v0.9.5](https://github.com/herdrdev/herdr/tree/2ecf19a92fc3a7fff75b6ce3655ef04f4625ec01).

- `workspace.move {workspace_id, insert_index}` reorders one Space. The index is a gap
  in the original list (0 through count); selection and IDs survive. Source:
  `src/app/api/workspaces.rs`, `src/app/actions.rs`.
- `tab.move {tab_id, insert_index}` only reorders within the current Space. There is
  no whole-tab relocation across Spaces. Source: `src/api/schema/tabs.rs`,
  `src/app/api/tabs.rs`.
- `pane.move` supports `new_tab {workspace_id, label}` and
  `new_workspace {label, tab_label}` atomically within one server. A single-pane tab
  can therefore move as a new tab, preserving its running terminal. Source:
  `src/api/schema/panes.rs`, `src/app/api/panes.rs`.
- Cross-Space moves change pane/tab IDs, close the emptied tab and possibly its
  Space, and reject zoomed sources via `changed: false`. The new Space derives its
  root from the moved terminal's cwd; worktree metadata is not copied.

A real isolated `wooloo-ui-test` server confirmed gap ordering, existing/new Space
moves, new IDs, and automatic closure of an empty source Space.

## Agreed behavior

Drag a Space to either half of another row to reorder within its destination.
Show an insertion line. Resolve the target row's stable ID against a fresh server
snapshot before computing the gap, so background reordering cannot redirect intent.

Drop a terminal tab onto an existing Space to create a new tab there, or onto the
explicit new-Space drop area below a destination's list to create a Space from it.
Only nonzoomed single-pane tabs qualify. Preserve their label. Multi-pane layouts
have no atomic transfer primitive and are refused with an explanation.

Drops stay within the same window, server connection, session, and machine. A
private pasteboard type and provider nonce identify the drag; revalidate the
connection generation/epoch and source/target at execution. Serialize these sidebar
operations, run socket work off the main thread, and refresh after failures too.
Do not retry uncertain remote mutations automatically.

Use `focus: false`. Follow the returned pane's new IDs only when the original source
tab was selected and selection has not changed while the request was running;
otherwise preserve navigation and repair only invalid selection. Track destination navigation
as well as tab/document/panel selection so switching away and back cancels a pending
follow. Following the moved pane explicitly requests the main terminal view, overriding
any editor document remembered by the destination Space.

Before permitting a last-tab transfer, await document restoration and check all
registered windows for source-Space documents or failed restoration. Also inspect the
persisted session index and orphan backup files without filtering by window claims;
refuse unreadable metadata and buffers left by a window that already closed. Refuse a move
that could strand documents, with guidance to close document tabs or leave another
terminal tab in the source. Recheck current topology before mutation. Other clients
can still change topology between preflight and mutation: Herdr has no conditional
whole-tab transaction. No client can eliminate that race through this API.

## Adversarial review

Astra reviewed the proposal and reached consensus after adding provider nonce
verification, stable reorder anchors, returned-ID selection with a navigation
revision, and the restoration/all-window document guard. These address stale drags,
concurrent ordering changes, navigation theft, and inaccessible document buffers.

## Validation

Focused fake-socket tests cover gap semantics, scope/refusal rules, changed IDs,
unchanged/error responses, stale connections, navigation, and document protection.
Run the signed macOS build and full unit suite, then exercise the sidebar controls
against the isolated server and capture the layout for review.

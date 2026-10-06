# Git and file editing research

## Implementation update

The first version now includes a right Files / Changes sidebar, document and diff tabs beside terminal tabs, a native UTF-8 editor, and a colored unified-diff viewer. Local Spaces use filesystem and Git processes. Saved Herdr SSH profiles are discoverable in the sidebar; selecting one obtains its remote Herdr snapshot and runs bounded, non-interactive SSH commands against the same target for file and Git access. Files are keyed by machine, session, Space and root. There are no saved SSH profiles on this development machine, so the remote path is implemented but has not been tested against a live remote host.

Library review: [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) is an MIT SwiftUI editor package, but its README calls it a work in progress and its manifest brings several packages and language parser binaries. [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) is smaller and MIT, but lacks syntax highlighting and still has dependencies. [lite-edit](https://github.com/arietan/lite-edit) is a maintained MIT application built with AppKit `NSTextView`, not an embeddable library. The current UI uses SwiftUI's native `TextEditor` (backed by AppKit text editing) and a small read-only diff view; these meet the simple-editing scope without new dependencies.

## Explorer synchronization

The visible `WorkspaceBrowserView` owns a cancellable monitoring task for its location.
Local Spaces use one recursive FSEvents stream for the Space root, the actual Git directory,
and the common Git directory of linked worktrees. Paths use POSIX `realpath`, because
Foundation can normalize `/private/tmp` to `/tmp` while FSEvents reports `/private/tmp`.
Git lock files, objects, logs, and changes beneath collapsed ignored folders are filtered.
Events requiring a rescan bypass those filters. Read-only Git batches disable optional locks
so `git status` cannot rewrite the index and cause repeated refreshes.

Changes share a bounded 300 ms batching window. The explorer runs one listing load at a
time and coalesces requests arriving during that load into a follow-up. A location generation
rejects results from a previous Space, including an A → B → A switch. Listing completion
updates Files, Changes, the Git bar, and the repository panel through `listingVersion`.
Caches are invalidated per location; stale in-flight results cannot repopulate them.
Reloading keeps the selected row and expanded folders. Automatic loads wait while an inline
name field is open and resume when it closes.

SSH Spaces poll every 3 seconds while the browser is visible and the app is active, using the
existing shared refresh batch. Local Spaces fall back to the same interval if their event stream
cannot start. Activation reconciles changes, and hiding the browser or changing its location
stops the old stream and pending refresh. SSH polling is covered with an injected listing
reader and the existing local SSH-command fixture, rather than a live remote host.

References: [Zed worktree scanner](https://github.com/zed-industries/zed/blob/main/crates/worktree/src/worktree.rs),
[VS Code explorer](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/explorerService.ts),
[VS Code Git watchers](https://github.com/microsoft/vscode/blob/main/extensions/git/src/repository.ts), and
[Apple FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

## Original API boundary research

xherdr connects one named **local** Herdr session through Unix sockets. It has no machine identity or remote workspace selector. Herdr's JSON `session.snapshot` supplies workspace, tab and pane IDs, plus `workspace.worktree.checkout_path` when a Space is a worktree and `pane.cwd` for ordinary panes. It does not expose Git file status, diffs, directory listings, file contents or file writes. `pane.read` returns terminal screen content, not a file. Herdr's `--machine` CLI forwards API commands over its saved SSH bridge, which likewise has no file API.

Herdr's `machine list --json` is the supported way to discover saved SSH profiles. Each row contains `id`, `label`, `target`, `session`, `enabled` and `selected`. A profile targets one remote session. On this development machine the list is empty, so remote behavior cannot yet be checked against a live host.

## Proposed first version

1. Introduce a Space identity containing session, machine ID (Local or saved profile ID), and workspace ID. Herdr IDs can repeat across machines. Show a machine selector and obtain remote snapshots with `herdr --machine <id> api snapshot` until xherdr has a persistent remote client connection. Keep the existing local terminal path as it is during this stage.
2. Resolve a Space root from `worktree.checkout_path`; otherwise use the selected pane's stable `cwd`, falling back to another pane in that Space. Avoid `foreground_cwd` as the root because an agent can change its foreground process directory. Resolve the root again when the selected Space changes.
3. Use one file service interface for Local and SSH: list files, read a text file with a version token, save only if that version still matches, and run Git status/diff. Return paths relative to the Space root to the UI.
4. Add a compact Files / Changes panel. Changes lists staged, modified and untracked files. Selecting a tracked change shows unstaged and staged diffs; selecting a file opens a simple monospaced text editor. Open untracked files directly. Save with Command-S and show dirty and external-change states.

For Local, use `Process` with Git argument arrays, not shell command strings. `git -C <root> status --porcelain=v1 -z --untracked-files=all` provides machine-readable changes, including names with whitespace; a parser must handle renames with two NUL-terminated names. Use `git diff --no-ext-diff --no-textconv -- <path>` and `git diff --cached --no-ext-diff --no-textconv -- <path>` for the two diff sections. A Space outside a Git repository can still show Files; Changes should explain that no repository was found.

For SSH, reuse the **saved Herdr profile's OpenSSH target**, not a second host configuration. Herdr's bridge only transports its API, so Git and file operations need a separate non-interactive SSH transport. Pass file content over stdin and return data on stdout. Keep remote commands fixed and quote every root/path argument for the remote shell; never interpolate file contents. Support Herdr's SSH host aliases and `ssh://user@host:port` form. Remote Git and file operations should be isolated from the terminal's Herdr socket and should time out independently.

## File safety and limits

- Resolve the canonical Space root and candidate path before access; reject paths that escape the root through `..` or symlinks. Never accept an absolute path supplied by a UI row as authority.
- Start with UTF-8 text only, a bounded file size, and a bounded diff size. Detect binary files and show a clear read-only message.
- Read a version token with the file. Before save, re-read the version and refuse to overwrite if the file changed. Write to a temporary sibling and rename it into place.
- Use `BatchMode=yes` and a connection timeout for SSH so the app does not hang on an authentication prompt. Surface host-key or authentication failures as errors; do not silently fall back to another machine.
- Keep any open editor tied to machine ID, session, Space ID and relative path. Switching Spaces must not redirect an unsaved editor to a same-named path elsewhere.

## Verification gates

Use a temporary local Git repository with staged, unstaged, untracked, renamed and whitespace-containing paths. Verify file save, external-change refusal, symlink escape refusal, binary/size handling and a non-Git Space. For SSH, use a saved **test** machine profile and a disposable remote repository; this environment currently has no saved SSH machines. Do not use or alter the default Herdr session.

Sources: [Herdr Socket API](https://herdr.dev/docs/socket-api/), [Connecting machines](https://herdr.dev/docs/connecting-machines/), and the installed Herdr 0.9.1 schema and CLI source.

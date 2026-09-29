# Git and file editing research

## Current boundary

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

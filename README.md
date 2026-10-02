# xherdr

**A native macOS home for your coding agents.**

xherdr is a Mac app for [Herdr](https://herdr.dev/), the server that runs and organizes coding agent sessions. It is for developers who work with several agents at once, use a mouse alongside the keyboard, and want some of the convenience of an IDE without leaving an environment built around their agents.

Herdr keeps owning the processes, layout and terminal state, so the same sessions stay available from the Herdr TUI. xherdr renders them natively and sends your input back.

> **Status:** early development. Expect rough edges and breaking changes. See [`TODO.md`](TODO.md) for known issues and planned work.

## Features

### Agents and sessions

- Spaces, tabs and split panes follow Herdr's [workspace, tab, pane and agent model](https://herdr.dev/docs/concepts/). Create, rename, close and zoom them from the sidebar, tab row, context menus, menu bar or command palette.
- The Agents section shows every agent with its Space, tab, summary and status, and can be filtered to the selected Space.
- Alerts when an agent finishes or needs input: Herdr's sounds, in-app toasts or system notifications, with unread marks until you look at the pane.
- The connected host's CPU, memory, disk and uptime, local or over SSH.
- Optional Claude Code and Codex plan usage in the sidebar (see [Agent quotas](#agent-quotas)).
- A session picker for any Herdr session on the machine.

### Terminal

- Live terminal surfaces over Herdr's binary client endpoint: colors, text attributes, cursor, alternate-screen apps and Herdr's inline PNG and RGB images, drawn with Core Text at Herdr's frame rate.
- Direct typing with control and option chords, paste, and dropped file paths. Mouse clicks, drags and the wheel reach programs that enable mouse reporting.
- Drag split borders to resize panes, select and copy text, and Command-click links.
- Herdr's prefix (`ctrl+b` by default) and direct key bindings, read from and edited in the same `config.toml`.

### Files and editor

- An explorer for the selected Space, local or on an SSH machine saved in Herdr. It works like Zed's project panel: compact folder chains, Git status colors, ignored files, keyboard navigation, multi-selection, drag and drop, in-place create and rename, trash, and undo and redo of file operations. Repositories with up to 200,000 files are supported.
- Go to File (⌘P) with fuzzy matching and `:line:column`, and a command palette (⇧⌘P) for app, editor and explorer actions.
- Editor tabs built on [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor): syntax highlighting, find and replace, Git change bars beside line numbers, conflict-checked atomic saves, and Zed-style multiple cursors (⌥-click, ⌘D, ⇧⌘L, ⌥⌘↑/↓).
- Markdown preview with Mermaid diagrams.
- Project-wide search and replace.

### Git

- A Changes tree with stage checkboxes, a branch bar and a commit editor.
- Unified or split diffs with syntax colors.
- Repository History (with each commit's files and diffs), branches, and worktrees: add a worktree from a branch, or remove one with Git's normal check that refuses dirty worktrees.

### Settings

- Guided sections for Herdr's terminal defaults, worktrees, appearance, notifications, headless size and shortcuts, plus a full TOML editor. Saving validates with `herdr config check`, refuses to overwrite outside changes, and reloads the running session.
- One theme shared by the interface, editor and terminals, with adjustable text sizes.

## Agent quotas

The QUOTAS section is off until you turn it on. Once on, every two minutes while a window is active, xherdr:

- reads Claude Code's sign-in from `~/.claude/.credentials.json`, or else from the Keychain item `Claude Code-credentials` (macOS asks you to allow xherdr the first time);
- reads Codex's sign-in from `${CODEX_HOME:-~/.codex}/auth.json` and the rate limits in its newest session logs;
- sends those tokens to the usage endpoints that Claude Code (`api.anthropic.com/api/oauth/usage`) and the Codex CLI (`chatgpt.com/backend-api/wham/usage`) use themselves.

When the explorer points at an SSH machine, the files are read there and the requests leave from your Mac. xherdr keeps the tokens in memory only and never refreshes them. Neither endpoint is documented, so the section can break when either service changes. Turn it off from the section's context menu.

## Requirements

- macOS 14 or later
- Xcode 26 (one vendored package needs Swift 6.2)
- [Herdr](https://herdr.dev/) 0.9 or later

There is no prebuilt release yet; build from source.

## Build and run

```sh
git clone https://github.com/rarce/xherdr.git
cd xherdr
xcodebuild -project xherdr.xcodeproj -scheme xherdr -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

The ad hoc signature needs no developer account; keep it, since macOS refuses notification permission to an unsigned app. You can also open `xherdr.xcodeproj` in Xcode and run the `xherdr` scheme on **My Mac**.

xherdr connects to Herdr's `default` session on first launch. To try it without touching your main session, start a separate one and pick it in the sidebar's session picker:

```sh
herdr --session xherdr-ui-test server
herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test
herdr --session xherdr-ui-test server stop   # when finished
```

Replace `build` with `test` to run the unit tests.

## Documentation

- [Herdr connection](docs/herdr-connection.md): sockets, events and the client endpoint
- [Git and file editing](docs/git-and-files-research.md): local and SSH implementation
- [Terminal performance](docs/perf/README.md): pipeline, benchmarks and baselines
- [SwiftTerm evaluation](docs/swiftterm-evaluation.md): why the terminal is drawn natively

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

xherdr is released under the [MIT License](LICENSE). It includes third-party software under their own licenses; see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt), also available in the app under xherdr → Third-Party Notices.

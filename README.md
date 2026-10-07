# wooloo

**A native macOS home for your coding agents.**

![wooloo with agents in the sidebar, a split terminal running Claude Code, and the explorer and repository history on the right](docs/images/main-window.png)

wooloo is a Mac app for [Herdr](https://herdr.dev/), the server that runs and organizes coding agent sessions. It is for developers who work with several agents at once, use a mouse alongside the keyboard, and want some of the convenience of an IDE without leaving an environment built around their agents.

Herdr keeps owning the processes, layout and terminal state, so the same sessions stay available from the Herdr TUI. wooloo renders them natively and sends your input back.

> **Status:** early development. Expect rough edges and breaking changes. See [`TODO.md`](TODO.md) for known issues and planned work.

## Features

### Agents and sessions

- Spaces, tabs and split panes follow Herdr's [workspace, tab, pane and agent model](https://herdr.dev/docs/concepts/). Create, rename, close and zoom them from the sidebar, tab row, context menus, menu bar or command palette.
- The Agents section shows every agent with its Space, tab, summary and status, and can be filtered to the selected Space.
- Alerts when an agent finishes or needs input: Herdr's sounds, in-app toasts or system notifications, with unread marks until you look at the pane.
- The connected host's CPU, memory, disk and uptime, local or over SSH.
- Optional Claude Code and Codex plan usage in the sidebar (see [Agent quotas](#agent-quotas)).
- A session picker for any Herdr session on the machine.
- Remote access from your phone (see [Remote access](#remote-access)).

### Terminal

- Live terminal surfaces over Herdr's binary client endpoint: colors, text attributes, cursor, alternate-screen apps and Herdr's inline PNG and RGB images, drawn with Core Text at Herdr's frame rate.
- Direct typing with control and option chords, paste, and dropped file paths. Mouse clicks, drags and the wheel reach programs that enable mouse reporting.
- Drag split borders to resize panes, select and copy text, and Command-click links.
- Herdr's prefix (`ctrl+b` by default) and direct key bindings, read from and edited in the same `config.toml`.

### Files and editor

- An explorer for the selected Space, local or on an SSH machine saved in Herdr. It works like Zed's project panel: compact folder chains, Git status colors, ignored files, keyboard navigation, multi-selection, drag and drop, in-place create and rename, trash, and undo and redo of file operations. Repositories with up to 200,000 files are supported.
- Go to File (⌘P) with fuzzy matching and `:line:column`, and a command palette (⇧⌘P) for app, editor and explorer actions.
- Editor tabs built on [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor): syntax highlighting, find and replace, Git change bars beside line numbers, conflict-checked atomic saves, and Zed-style multiple cursors (⌥-click, ⌘D, ⇧⌘L, ⌥⌘↑/↓).
- Reopen a Space with its document tabs, order, active editor, selections and scroll position. Unsaved edits and untitled drafts are backed up locally under `~/Library/Application Support/wooloo`, including SSH documents, and restored without saving them into the project. Backups are written after a short pause while editing and completed before quitting; closing a dirty tab still asks before discarding its contents.
- Markdown preview with Mermaid diagrams.
- Native image previews for PNG, JPEG, GIF, WebP, HEIC/HEIF, AVIF, TIFF, BMP, and ICO in local and SSH Spaces, using macOS decoders. Includes zoom, fit, actual size, pixel dimensions, transparency checkerboard, and reload; each tab keeps its zoom and position. Previews are read-only, limited to 50 MiB, and decode at most 4096 pixels per side. Multi-frame images show their first frame.
- Native PDF previews for local and SSH files up to 50 MiB, with page navigation, zoom, page/width fitting, text search (⌘F and ⌘G), password unlocking, and reload. Each tab keeps its page and zoom. PDF previews and form fields are read-only; search uses existing PDF text rather than OCR.
- Project-wide search and replace.

### Git

- A Changes tree with stage checkboxes, a branch bar and a commit editor.
- Unified or split diffs with syntax colors.
- Repository History (with each commit's files and diffs), branches, and worktrees: add a worktree from a branch, or remove one with Git's normal check that refuses dirty worktrees.

### Settings

- Guided sections for Herdr's terminal defaults, worktrees, appearance, notifications, headless size and shortcuts, plus a full TOML editor. Saving validates with `herdr config check`, refuses to overwrite outside changes, and reloads the running session.
- One theme shared by the interface, editor and terminals, with adjustable text sizes.

## Agent quotas

The QUOTAS section is off until you turn it on. Once on, every two minutes while a window is active, wooloo:

- reads Claude Code's sign-in from `~/.claude/.credentials.json`, or else from the Keychain item `Claude Code-credentials` (macOS asks you to allow wooloo the first time);
- reads Codex's sign-in from `${CODEX_HOME:-~/.codex}/auth.json` and the rate limits in its newest session logs;
- sends those tokens to the usage endpoints that Claude Code (`api.anthropic.com/api/oauth/usage`) and the Codex CLI (`chatgpt.com/backend-api/wham/usage`) use themselves.

When the explorer points at an SSH machine, the files are read there and the requests leave from your Mac. wooloo keeps the tokens in memory only and never refreshes them. Neither endpoint is documented, so the section can break when either service changes. Turn it off from the section's context menu.

## Remote access

Settings → Remote Access (also in the command palette) publishes this Mac's SSH server through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/), so an SSH client, on a computer or a phone, can reach the Herdr session from anywhere without opening a port. Clients still sign in with SSH, then run Herdr's own commands (`remote-api-bridge`, `terminal session control`).

- Needs `cloudflared` (`brew install cloudflared`) and Remote Login (System Settings → General → Sharing).
- **Quick tunnel**: no Cloudflare account; a new `*.trycloudflare.com` address on every start. Anyone who learns it reaches your SSH login, so use key authentication.
- **Named tunnel**: create a tunnel in Cloudflare Zero Trust with a public hostname whose service is `ssh://localhost:22`, then paste its hostname and token (kept in the Keychain, passed to `cloudflared` through its environment). It can sit behind Cloudflare Access, with a service token for clients.
- While the tunnel runs, a QR code adds the machine to the companion Android app, prefilled: hostname, user, session, Herdr's path and this Mac's host key fingerprints, so the phone trusts the right server. Other computers use `ssh -o ProxyCommand="cloudflared access ssh --hostname %h" user@host`.
- The tunnel is wooloo's own `cloudflared` process: it stops when wooloo quits, and can start when wooloo opens.

`WOOLOO_CLOUDFLARE_TUNNEL_TEST=1` (as `TEST_RUNNER_WOOLOO_CLOUDFLARE_TUNNEL_TEST=1` for `xcodebuild test`) runs `RemoteAccessTests/testRealQuickTunnelReachesThisMacsSSH` against a real quick tunnel.

## Requirements

- macOS 14 or later
- Xcode 26 (one vendored package needs Swift 6.2)
- Herdr 0.9.3 is included in the app; an existing compatible Herdr installation can also be used.
- Git and coding agent CLIs are optional, installed separately for their respective features.

There is no prebuilt release yet; build from source.

## Build and run

```sh
git clone https://github.com/rarce/wooloo.git
cd wooloo
xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' build
```

The project signs ad hoc ("Sign to Run Locally"), so no developer account is needed. Keep a signature: macOS refuses notification permission to an unsigned app. You can also open `wooloo.xcodeproj` in Xcode and run the `wooloo` scheme on **My Mac**.

The first build downloads the pinned Intel and Apple Silicon Herdr binaries and verifies their SHA-256 hashes. They are cached under `build/herdr/0.9.3` and bundled as a signed universal helper. You can prepare this cache in advance with `sh scripts/bundle-herdr.sh --prepare`; subsequent builds work offline with the package and runtime caches present.

On a fresh install, a setup wizard lets you choose a folder and creates the first Space in an app-managed `wooloo` session. It installs the included Herdr under `~/Library/Application Support/wooloo/runtime/herdr/0.9.3`, so no download, Homebrew, developer tools, or administrator password is needed at runtime. A user launchd job starts the server when wooloo opens and keeps it running when the app quits. It is not registered to start at login. Herdr's normal `config.toml` and named-session storage are used; existing configuration is preserved.

You can instead choose an existing Herdr executable and connect to a running session. Existing wooloo users keep their remembered session. **Set Up Herdr…** in the sidebar session picker opens the wizard again. Runtime updates ship with wooloo; a compatible server already running is reused, and setup never stops its panes.

To try the app without touching your main session, start a separate one and pick it in the sidebar's session picker:

```sh
herdr --session wooloo-ui-test server
herdr --session wooloo-ui-test workspace create --cwd "$PWD" --label wooloo-test
herdr --session wooloo-ui-test server stop   # when finished
```

Replace `build` with `test` to run the unit tests.

To check the bundled runtime and launchd lifecycle with a real server, run `TEST_RUNNER_WOOLOO_RUNTIME_E2E=1 xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' -only-testing:woolooTests/HerdrRuntimeTests test`. It uses temporary config/state/runtime roots and only the `wooloo-ui-test` session. For an interactive isolated setup, launch a test copy with `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and `WOOLOO_RUNTIME_ROOT` pointing under `/private/tmp`, and `WOOLOO_SETUP_SESSION=wooloo-ui-test`.

## Documentation

- [Herdr connection](docs/herdr-connection.md): sockets, events and the client endpoint
- [Herdr plugins](docs/herdr-plugins.md): manifests, lifecycle, APIs and native integration
- [Git and file editing](docs/git-and-files-research.md): local and SSH implementation
- [Terminal performance](docs/perf/README.md): pipeline, benchmarks and baselines
- [SwiftTerm evaluation](docs/swiftterm-evaluation.md): why the terminal is drawn natively

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

wooloo is released under the [MIT License](LICENSE). It includes third-party software under their own licenses; see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt), also available in the app under wooloo → Third-Party Notices.

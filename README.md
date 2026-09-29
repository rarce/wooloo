# xherdr

**A native macOS home for your coding agents.**

xherdr brings the agent management experience of [herdr](https://herdr.dev/) to a Mac app. It is for developers who work with agents, use a mouse alongside the keyboard, and miss some of the convenience of an IDE while still wanting an environment built around their agents.

## The idea

Herdr makes it possible to manage multiple agent sessions in one workspace. xherdr aims to make that workflow feel at home on macOS: a native interface for seeing your agents, moving between their sessions, and working with the project around them.

The direction is simple:

- **Agents first.** Keep multiple agents and their work visible and easy to manage.
- **Native Mac interaction.** Make common actions comfortable with windows, menus, and the mouse, without giving up keyboard driven work.
- **Useful IDE conveniences.** Bring project context and everyday development tools close to the agent sessions.

## Status

xherdr is at the beginning of development. The compact SwiftUI app has a left sidebar for spaces and agents, workspace tabs, and terminal pane layouts. It starts with the dedicated Herdr test session `xherdr-ui-test` and subscribes to server events. Its terminal uses Herdr's generation-1 client endpoint to display live cells, colors, cursor, split panes, and alternate-screen applications. Click a pane and type directly: text, Enter, Backspace, arrows, Tab, Escape, control and option chords, and paste are forwarded to Herdr in order. The session picker lives at the bottom of the sidebar; `default` is excluded by this build. The interface follows Herdr's [workspace, tab, pane, and agent model](https://herdr.dev/docs/concepts/) and the layout shown on [herdr.dev](https://herdr.dev/).

The JSON `pane.read` view remains a fallback while the endpoint is unavailable. Terminal programs that enable mouse reporting receive clicks, drags, and wheel events through the endpoint. Split borders can be dragged to resize panes. Text selection stays active as the live surface changes, and Command-C copies the selected text. The live surface also draws Herdr's native PNG, RGB, and RGBA image placements.

The gear button in the sidebar opens Herdr settings. Guided sections cover terminal defaults, worktrees, appearance, and headless server size; the Advanced TOML section edits the complete local `config.toml`. Saving checks the file with `herdr config check`, refuses to overwrite external changes, then calls `server.reload_config` on the selected named session. The config file is shared by local Herdr sessions; xherdr's own native colors do not yet follow Herdr's terminal theme.

The compact controls mirror Herdr's everyday actions: the plus beside Spaces creates a new workspace, the plus in the tab row creates a tab, Menu collects the same actions and settings, and the sidebar button hides or restores the sidebar. Creation runs through Herdr's socket API in the selected named session.

The Agents section now shows each agent's space and tab above its name and status. When Herdr supplies a summary or title, that appears beneath the name. Custom state labels from the server are used for the visible status.

The right sidebar browses Files and Git Changes for the selected Space. Files open in editable text tabs with CodeEditSourceEditor syntax highlighting, line numbers, and cursor position; changes open as colored unified diffs. Both use icons distinct from Herdr terminal tabs. The Files panel can also select an SSH machine saved by Herdr and browse its Spaces. Editing supports UTF-8 files up to 1 MB, Command-S, conflict detection, and atomic replacement. CodeEditSourceEditor 0.9.1 and CodeEditTextView 0.7.7 are included under `Vendor/` with their MIT licenses; their SwiftLint development plugins are omitted from the local package manifests.

The terminal accepts Herdr's prefix shortcuts (default `ctrl+b`, then an action key) and direct bindings for common tab, space, pane, sidebar, settings, and reload actions. Menu → Keyboard Shortcuts opens the Shortcuts section in settings, where bindings can be edited as Herdr `[keys]` values. Alternatives are separated with commas. The same file configures Herdr; xherdr applies supported shortcuts in its terminal after saving. Other Herdr actions remain available through Advanced TOML and the Herdr TUI.

The server integration is documented in [docs/herdr-connection.md](docs/herdr-connection.md). The [Git and file editing research](docs/git-and-files-research.md) maps the local and SSH implementation. The [SwiftTerm evaluation](docs/swiftterm-evaluation.md) explains when a full terminal view would be useful.

## Run locally

Start an isolated test server with `herdr --session xherdr-ui-test server`. In another terminal, create a test workspace with `herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test`. Then open `xherdr.xcodeproj` in Xcode, select the `xherdr` scheme and **My Mac**, and run the app. The project targets macOS 14 or later. Stop only the test server with `herdr --session xherdr-ui-test server stop` when finished.

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

xherdr is at the beginning of development. The SwiftUI app has a left sidebar for spaces and agents, workspace tabs, and terminal pane layouts. It starts with the dedicated Herdr test session `xherdr-ui-test`, subscribes to server events, reads visible pane text, and can send a line of input to a pane. The toolbar accepts another named session; `default` is excluded by this build. The interface follows Herdr's [workspace, tab, pane, and agent model](https://herdr.dev/docs/concepts/) and the layout shown on [herdr.dev](https://herdr.dev/).

Pane output currently uses `pane.read`, so full terminal colors, cursor behavior, graphics, and key-by-key interaction still require Herdr's terminal surface protocol.

The server integration is documented in [docs/herdr-connection.md](docs/herdr-connection.md). The [SwiftTerm evaluation](docs/swiftterm-evaluation.md) explains when a full terminal view would be useful.

## Run locally

Start an isolated test server with `herdr --session xherdr-ui-test server`. In another terminal, create a test workspace with `herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test`. Then open `xherdr.xcodeproj` in Xcode, select the `xherdr` scheme and **My Mac**, and run the app. The project targets macOS 14 or later. Stop only the test server with `herdr --session xherdr-ui-test server stop` when finished.

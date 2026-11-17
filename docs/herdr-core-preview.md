# herdr-core sessions (preview)

wooloo can connect to [herdr-core](https://herdr.dev/core) (`hc`), the server behind the official Herdr app, as well as to the Herdr TUI. The TUI stays the default and keeps working as before. herdr-core support is a preview and is off until you turn it on.

How it is built, and why, is in the [backend plan](proposals/herdr-core-backend.md). How herdr-core and the app relate to the TUI is in [Herdr app and herdr-core](herdr-app-and-core.md).

## Turning it on

1. Install herdr-core on this Mac with its [official installer](https://herdr.dev/core). wooloo does not bundle or install a local core; Core's own updater keeps it current.
2. In **Settings → Appearance**, turn on **herdr-core (preview)**.
3. Open a session:
   - **First run:** choose **Use herdr-core (preview)**.
   - **Later:** in **Manage Connections**, add a connection with **herdr-core session (preview)** turned on. It can be on this Mac or on an SSH host.

**On an SSH host,** wooloo runs `hc connect` over its own SSH connection. If the host has no herdr-core:
- The host's entry in **Manage Connections** offers **Install herdr-core 0.1.21 on This Host…**. It asks first.
- It downloads the build for the host's platform from `releases.herdr.dev`.
- It checks the download against a SHA-256 built into wooloo.
- It installs it in `~/.local/bin`.
- It never replaces a herdr-core that is already there.

## How a herdr-core session looks

herdr-core keeps terminals, not layout. wooloo keeps its own Spaces, tabs and splits in a `wooloo` document inside the core, so every Mac that connects to that core sees the same arrangement. A change to the arrangement is only written if no one else changed it since it was read; when they did, wooloo reads it again and applies the change on top.

- **Terminals no wooloo tab holds,** such as ones started from the official app, a phone or `hc run`, appear:
  - where the official app's own document places them, in its Spaces;
  - otherwise in the Space their labels name;
  - otherwise in an **Unfiled** Space.
- **The app's Spaces are read only.** wooloo never writes the app's document; its format is not a published contract yet ([herdr-app #43](https://github.com/herdrdev/herdr-app/issues/43)). When you change one of the app's Spaces in wooloo (rename, split, move), wooloo keeps it in its own document from then on.
- **Unread and pinned agents** use the labels every Herdr client shares, so marking an agent read, unread or pinned shows in the official app too.
- **Zoom** belongs to each window.

## What works

| Feature | Herdr TUI | herdr-core (preview) |
| --- | --- | --- |
| Spaces, tabs, splits, zoom, moves | Yes | Yes. Zoom is per window. Moving a tab or pane to another session or machine is not supported. |
| Live terminals | Herdr's cell surfaces | Drawn by wooloo with [libghostty-vt](https://github.com/ghostty-org/ghostty): colours, text attributes, cursor, wide characters |
| Typing, paste, key chords | Yes | Yes, encoded for each program's keyboard modes |
| Mouse reporting to programs | Yes | Yes: clicks, drags and the wheel, encoded for the program's mouse mode |
| Scrollback | Yes | Yes. The wheel scrolls back through the terminal's last 2,000 lines when you connect, plus everything since. Typing returns to the live screen. In full-screen programs that ask for it (mode 1007), the wheel sends arrow keys. |
| Find in terminal | Not in wooloo (the TUI has its own) | **Pane → Find in Terminal** (⌘F while a terminal has the keyboard) searches the screen and scrollback, scrolls to each match and highlights it. Return goes to older matches, Shift-Return to newer ones. |
| Inline images | Herdr's images | Kitty graphics protocol images, including PNG, drawn above or below the text as the program asks and cut to their pane |
| Agent status | Herdr's detection and integrations | Only for programs that report it themselves (OSC 7501) |
| Unread and pinned agents | Unread in wooloo | Shared with every Herdr client (`herdr.seen`, `herdr.pinned`) |
| Notifications | Herdr's sounds, toasts and system notifications | The same, from agent states |
| Resume agents after a reboot | Supported agents | Not available in herdr-core |
| Worktrees from the repository panel | Yes | Not yet |
| Agent views and popups | Yes | Not offered |
| Herdr's `config.toml` settings and reload | Yes | Settings that wooloo keeps itself; no config reload |
| SSH hosts | Herdr's saved profiles and `remote-api-bridge` | Hosts saved in wooloo, with `hc connect` over SSH |
| Files, editor and Git | Yes | Yes, on the connection's machine |
| Mobile companion and Remote Access | Yes | TUI sessions only |
| Terminals on a core's own machines (`machine/t7`) | — | Hidden. wooloo reaches each host directly, so they would show twice. |

## Known limits

- herdr-core support was built against herdr-core 0.1.21.
- A terminal shows the agent state only while the program reports it.
- On SSH, each window holds three connections to the core: commands, the event stream and its live terminals. Each counts against the host's SSH session limit.
- Reaching the same core from two windows, or from two Macs, keeps one arrangement. Each window keeps its own zoom and selection.
- A window that is not active when it connects to a terminal, such as one restored behind others at launch, only watches it. It does not change the terminal's size or type into it, and it follows the size the active window set. It takes over once you bring it to the front.

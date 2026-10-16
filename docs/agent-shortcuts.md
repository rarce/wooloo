# Agent keyboard shortcuts in Wooloo

Reviewed on 2026-10-16 against the official [Codex CLI commands](https://developers.openai.com/codex/cli/slash-commands), [Claude Code interactive mode](https://code.claude.com/docs/en/interactive-mode), and [Claude Code keybindings](https://code.claude.com/docs/en/keybindings). Agent versions and custom keymaps can change these bindings; Codex exposes `/keymap`, and Claude exposes `/keybindings`.

## Conflict and resolution

Herdr's default prefix, Control+B, conflicts with Claude's background-task action and terminal cursor movement. Wooloo previously consumed that key and the next key, so an agent shortcut could appear to hang or disappear.

Wooloo now uses **Control+Command+B** when `[keys].prefix` is absent or invalid. Its action sequence is unchanged: release the prefix, then press the action key (for example, C for a new tab). Native menus continue to use Command shortcuts. This is a Wooloo fallback only; it does not rewrite the shared Herdr configuration or change Herdr's TUI default.

An explicit `[keys].prefix` still wins. For an existing `prefix = "ctrl+b"`, either change it in Settings → Shortcuts to `cmd+ctrl+b`, or press Control+B twice to send one Control+B to the terminal. The same repeat-to-send behavior applies to other prefixes without Command. Repeating a Command prefix cancels it; Command keys remain native app commands. A pending prefix otherwise consumes its next key, with Escape cancelling it. Explicit direct bindings can still conflict with an agent's custom keymap; remove or remap those bindings in Settings.

## Keys to leave available to agents

| Agent | Keys / purpose |
| --- | --- |
| Codex | Control+R: prompt history; Control+O: copy completed response; Control+C: cancel/exit; Tab: queue follow-up; Enter: steer active turn; Escape twice: edit/fork previous message; Option+R: raw scrollback |
| Claude | Control+B: background task; Control+O: transcript; Control+R: history; Control+T: checklist; Control+S: stash prompt; Control+V: image paste; Control+C/D: cancel/exit; Control+Z: suspend |
| Claude | Shift+Tab: permission mode; Shift+Enter: multiline input (terminal dependent); Control+X: prefix for agent chords; Escape: cancel |
| Both | Control and Option editing/navigation chords, Tab, Shift+Tab, Enter, Escape, and arrows belong to the terminal unless explicitly configured as Wooloo shortcuts. |

Tests exercise Control/Option letter chords, agent navigation keys, configured bindings, and the actual terminal input path for Control+B and a repeated custom prefix. They do not assert every possible binding in every agent version. AppKit/system-reserved keys and terminal protocol support remain separate from shortcut matching; see [terminal input](herdr-connection.md).

## Closing the last terminal

Closing the last terminal tab from Command+W, the command palette, middle-click, or the tab context menu now asks whether to close its Space. Closing the last pane from the pane or agent menu uses the same decision. Confirming sends `workspace.close`, rather than `tab.close` or `pane.close`. Keeping the Space returns to its terminal with the same running session; no process is terminated or relaunched while the question is open. Explicit Close Space continues to ask before terminating its terminals. Program exits and closes initiated by other Herdr clients remain server-controlled.

# Demo script

The recording is `docs/images/demo.mp4` (and `demo.gif` for the README), made from this plan in one take of a real session: wooloo 0.3.1 with the Codex CLI on an isolated Herdr session and a throwaway repository. Clicks and typing were played by a script through macOS Accessibility, at a human pace. The wait for the agent is sped up 8×, typing the task 2× and the steps after it 1.5×; the video marks each sped-up stretch. It runs about a minute. Nothing else is edited to look faster than it is.

Use an isolated Herdr session and a throwaway repository, never real credentials, and keep QUOTAS and Remote Access off on screen. The plan it started from:

| Time | Screen | Voice-over / caption |
|---|---|---|
| 0–5 s | The main window: Agents list on the left, a terminal with Claude Code (or Codex) working in the middle, explorer on the right. | "Your coding agents, in one native Mac window." |
| 5–12 s | The agent's status changes to done; the toast or unread mark appears. Click the agent in the sidebar to focus its pane. | "See which agent is working, blocked or done." |
| 12–20 s | In the explorer's Changes tree, the file the agent changed is marked. Click it to open its diff (unified or split). | "Open the file it changed and review the diff." |
| 20–32 s | Open the file itself, fix one line by hand, save with ⌘S. The change bar updates. | "Edit it yourself, right there." |
| 32–40 s | Stage it with the checkbox, type a commit message, commit. | "Stage and commit without leaving the window." |
| 40–45 s | Pull back to the whole window; show the download link. | "wooloo, an early preview. Herdr included. wooloo.dev" |

Before publishing it, check that every step shown works in the release being advertised, and say in the description that the agent CLI and its subscription are separate.

# Early-preview launch checklist

Checks to run on a Mac before announcing a release as an early preview. Record the Mac model, macOS version and wooloo version for each run. Use test accounts and an isolated Herdr session; do not point anything at production machines or real credentials beyond your own test sign-ins.

## Build and automated tests

- [ ] `xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' build` succeeds.
- [ ] `… test` passes, including `AgentQuotaTests`, `RemoteAccessTests`, `WorkspaceDocumentStoreTests` and `WorkspaceSessionPersistenceTests`.
- [ ] `ViewSnapshotTests` pass locally (main window with QUOTAS on still matches).
- [ ] CI is green on the release commit.

## Clean install, no external Herdr

On a Mac user account without Herdr (`~/.config/herdr` absent, no `herdr` on `PATH`) and without wooloo's data (`~/Library/Application Support/wooloo` absent):

- [ ] Download the release zip, check its SHA-256, move the app to /Applications.
- [ ] First launch is blocked by Gatekeeper; **Open Anyway** works as the site and README describe.
- [ ] The setup window offers the included Herdr; choosing a project folder creates the first Space with a terminal. No download, Homebrew or administrator password is asked for.
- [ ] Type in the terminal; resize the window; split a pane.

## First agent

- [ ] Start an installed agent CLI (`claude`, `codex`) in the terminal; it appears in the Agents list with its status.
- [ ] Let it change a file; open the file from the explorer and the Changes tree; review the diff; edit and save; stage and commit.
- [ ] Without the agent CLI installed, the app still works and nothing claims the agent is included.

## Quit and reopen with sessions running

- [ ] With an agent still working, quit wooloo. The agent keeps running (`herdr --session wooloo …` or the TUI shows it).
- [ ] Reopen wooloo: it reconnects to the same session; terminals, tabs and the Agents list are back.
- [ ] Unsaved editor buffers and untitled drafts come back after quitting and after a forced quit (`kill -9`).

## Editing conflicts

- [ ] A clean open file changed by the agent reloads in place.
- [ ] A file with unsaved edits changed on disk shows the banner (Reload / Keep Mine); edits are kept.
- [ ] Saving it asks Overwrite / Reload / Cancel. Each button does what it says; Escape cancels.
- [ ] While that question is shown, change the file again from a terminal; Overwrite then writes nothing and explains why; the next save asks again.
- [ ] Save an inactive tab from its context menu; only that file is written.
- [ ] Make the folder read-only and save: an error shows, the edits stay. Make a file unreadable and Reload: an error shows, the edits stay.

## Quotas

- [ ] Off by default. **Turn On Quotas…** from the button and from the context menu both show the same dialog naming this Mac.
- [ ] Cancel and Escape leave it off; Console/`log stream` and a proxy show no request to `api.anthropic.com` or `chatgpt.com`, and macOS shows no Keychain prompt.
- [ ] Turn On: Keychain prompt (if Claude Code uses the Keychain), then usage appears.
- [ ] Point the explorer at an SSH Space: QUOTAS is off there until agreed for that machine; the dialog names the machine.
- [ ] Upgrading from 0.3.1 with QUOTAS on asks once more.

## Remote Access and updates

- [ ] With password authentication on (macOS default), **Start** shows the "accepts a password" result and publishes nothing until **Start Anyway**; the status then says it runs without verified key-only SSH.
- [ ] With `PasswordAuthentication no` and `KbdInteractiveAuthentication no`, **Start** starts without asking and the settings show the key-only check.
- [ ] With "Start the tunnel when wooloo opens" on and passwords allowed, relaunching does not start the tunnel and says why.
- [ ] wooloo never edits `/etc/ssh`, the firewall or sharing settings.
- [ ] Named tunnel with a token in the Keychain and start at launch: install the next update through **Check for Updates…**. macOS asks for Keychain access to the token; until answered, the tunnel stays down. The release notes and update dialog mention this.
- [ ] Stop the tunnel, quit wooloo: no `cloudflared` process remains.

## Site and documents

- [ ] wooloo.dev on a desktop browser and a phone: download button with "Early preview · Not notarized yet", quick start, links to privacy, Quotas, Remote Access, code and the latest release all work; the screenshot opens at full size and closes with Escape; Tab reaches every link with a visible focus ring.
- [ ] README, site and release notes agree on macOS 14+, Apple silicon and Intel, the included Herdr version and the limitations.
- [ ] Nothing claims notarization, stable status, complete test coverage, offline-only operation, universal compatibility or a published Android app.

# Listening ports per Space

Researched and implemented on 2026-11-16. wooloo shows the TCP ports that processes in a Space listen on, as `HTTP` tags at the end of the Space's sidebar row, and forwards a remote Space's port to this Mac over SSH for a manual check. The design follows [Sheprd](https://github.com/sheprd-labs/sheprd), a native Herdr client compared in [Herdr app and herdr-core](herdr-app-and-core.md); its facts below come from reading its source at commit [`21f2e5a`](https://github.com/sheprd-labs/sheprd/tree/21f2e5a54d5765c35370a5ed4f0d5a4562d685b1). Sheprd was not run.

## What wooloo does

Code: `wooloo/ListeningPorts.swift` (scan, parser, monitor, forwards), `wooloo/ListeningPortsView.swift` (tags), the Space rows in `HerdrDestinationSection` (`wooloo/HerdrDestinations.swift`). Tests: `woolooTests/ListeningPortsTests.swift`.

### Detection

- `ListeningPortScanner.script` is a read-only POSIX sh script. It lists TCP listeners with `ss -ltnp` (Linux) or `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` (macOS), then reads each listening process's environment: `/proc/<pid>/environ` on Linux, `ps -E -ww` on macOS. It prints `N` when neither tool exists, which shows as an error.
- A port belongs to the Space in its process's `HERDR_WORKSPACE_ID`. Herdr sets it in every pane, with `HERDR_SESSION` (empty in the `default` session) and `HERDR_SOCKET_PATH`; checked with Herdr 0.9.5 on Linux, where `HERDR_WORKSPACE_ID=w1` matched the snapshot's `workspace_id`. Listeners of other sessions, and processes not started in a pane, are left out of the Spaces.
- Agent CLIs (Claude Code, Codex and others) listen on loopback ports of their own for IDE and MCP bridges; those are excluded by process name or command line. Claude Code's binary is named after its version (`…/claude/versions/2.1.325`), so the command line decides.
- Only the user's own processes are visible. A port listening on IPv4 and IPv6 shows once, with the wider bind. At most 1,024 listener lines, 128 processes and 32 ports per Space.
- `ListeningPortsMonitor` runs the script on the connection's machine (locally, or over the shared SSH ControlMaster through `WorkspaceFiles.remoteOutput`) every 5 s, or 30 s after a failure, while the connection is up and its window is active. It publishes only when the result changes, and keeps the last ports on screen when a scan fails. One monitor runs per connection section in the sidebar.

### Display

- Each port is a small `HTTP` tag at the end of the Space row, outside the row's button so its click is its own. Up to three tags show; more fold into `+N`, a menu that opens them.
- Hovering shows the port, the process and its state, for example `Port 3000 on Box → localhost:3000 · node`.
- The tag's color says whether the port is forwarded: green when forwarded, amber while the forward starts, red when it failed, gray otherwise (a local port needs no forward).
- Clicking opens the page in the default browser: `http://localhost:<port>/` on this Mac (the bind address when the service listens on one address only), or the forward on `http://127.0.0.1:<local>/` for an SSH Space, starting the forward first.
- The tag's context menu has Open in Browser, Copy URL, and Forward Port to This Mac / Stop Forwarding.

### Forwarding

- `PortForwards.shared` starts one `ssh -N -L 127.0.0.1:<local>:<host>:<port>` process per forward, with `ControlPath=none`, `BatchMode=yes`, `ExitOnForwardFailure=yes`, no agent or X11 forwarding, and keepalives. It is ready once ssh prints the line from `LocalCommand=echo wooloo-forward-ready`, which it runs after connecting and binding the local port; a port probe could be answered by another process. ssh's stderr is dropped, since it can hold secrets.
- `<host>` is `localhost` for services listening on every interface or loopback, and the address otherwise, so a remote service bound to loopback only is still reached.
- The local port is the one the same remote port used last, else the remote number (plus 10,000 below 1024), when free; otherwise one the system picks. A busy port gets one retry on a system-picked port. At most 32 forwards.
- A forward ends when its remote port stops listening (any session on the machine counts), when ssh exits, from Stop Forwarding, or when wooloo quits (`applicationWillTerminate`). It never reconnects; an ended forward shows as not forwarded.
- Why not `ssh -O forward` on wooloo's shared ControlMaster: the master would keep the forward after wooloo stops wanting it, and `ControlPersist=60` would close it once no command uses the connection. Sheprd avoids the user's master for the first reason.

### Tests

`ListeningPortsTests` covers the parser with `ss` and `lsof` output (sessions, the `default` session, IPv4/IPv6 deduplication, link-local zones, malformed lines, the `N` marker, the per-Space cap, agent exclusion), the monitor keeping the last ports after a failure, the forward's ssh arguments, local port choice with a busy port, and forwards started through an injected launcher (reuse, retry, failure, retention, stop all). `testScriptFindsAListenerStartedInAPane` starts `nc -l` with a pane's environment and checks that the script finds it on this Mac directly and over a fake `ssh`, which exercises `lsof` and `ps -E` on the running macOS.

## How Sheprd does it

Paths are relative to [the source at `21f2e5a`](https://github.com/sheprd-labs/sheprd/blob/21f2e5a54d5765c35370a5ed4f0d5a4562d685b1/).

- **Scan.** One long-lived `sh -s` per host runs a POSIX script (`crates/sheprd-gpui/src/listening_ports/scan.rs`, L44–93): `ss -ltnp` on Linux, `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` on macOS, `N` without either. The shell is local or goes through SSH (`listening_ports.rs`, L140–161).
- **Mapping.** The listening PID's environment, from `/proc/<pid>/environ` or `ps -E -ww`, gives `HERDR_WORKSPACE_ID` and `HERDR_SOCKET_PATH` (L70–76; `Daemon::owns`, `session_name`, L109–137). No process tree, cwd or `pane.process_info`.
- **Polling.** Every 5 s, 30 s after a failure, 15 s per step, at most 16 hosts, a thread per host (`listening_ports.rs`, L48–53, L206–231, L362–400), only with `show_listening_ports` on (`window/monitors.rs`, L57).
- **Limits.** TCP LISTEN only; 1,024 lines, 128 PIDs, 32 ports per workspace (`scan.rs`, L19–29, L70); agent sockets excluded (`AgentKind::identify`, L333); IPv4/IPv6 duplicates keep the wider bind (`add`, L369–379); `Bind` is Any, Loopback or Address (L96–133).
- **Display.** A globe and `:3000` chips under the workspace row and in the status bar (`sidebar/render.rs`, L433; `listening_ports/render.rs`, L21–42). A click opens the page in a browser tab inside the workspace. A separate local-only "Ports" section (`local_ports.rs`) can pause, resume and stop processes.
- **Forwards.** A click on a remote port starts `ssh -N -o ControlPath=none -o ExitOnForwardFailure=yes -o PermitLocalCommand=yes -o LocalCommand='echo herdr-forward-ready' -L 127.0.0.1:L:<host>:R` and waits for that line (`listening_ports/tunnel.rs`; `sheprd-client/src/ssh.rs`, L528–573). Local port choice: last used, else the remote number, +10,000 below 1024, else `bind(0)`, one retry (`forward.rs`, L35–40, L153–164, L232–249). At most 32; closed when the port disappears, ssh exits, the feature is off, the window closes or the app quits (L342–355). A manual "Forward port" uses a private master and `ssh -O forward` (`sheprd-client/src/forward.rs`, L310–367).
- **Security.** Local loopback binds, `BatchMode`, `StrictHostKeyChecking=yes`, no agent or X11 forwarding, stderr discarded, environment values validated, `PATH` extended idempotently (Sheprd issue #754).

## Differences from Sheprd

- wooloo shows an `HTTP` tag per port with the port in its tooltip, instead of `:3000` chips, and opens pages in the default browser rather than a tab inside the app.
- wooloo uses the user's host key settings rather than forcing `StrictHostKeyChecking=yes`, like its other SSH commands.
- wooloo scans with a new `sh` each time rather than one long-lived shell per host; over SSH the shared ControlMaster keeps that cheap.
- There is no local "Ports" section to stop processes.

## Not verified yet

- A run of the app on macOS: built and tested only by reading on Linux, where no Swift toolchain is available. The macOS review should check the tags' look and hit area in the Space row, the tooltips, and a real forward to an SSH machine.
- `ps -E -ww` showing other processes' environments on current macOS; `testScriptFindsAListenerStartedInAPane` checks it.
- Panes on remote machines setting `HERDR_WORKSPACE_ID`; it was checked only for a local session on Linux.

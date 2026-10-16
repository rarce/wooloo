# Remote hosts

Open the session/host picker at the bottom of the sidebar and choose **Manage Remote Hosts…** under **Files and changes**.

Add an OpenSSH target (`user@host`, an alias from `~/.ssh/config`, or `ssh://user@host:port`), an optional label and a remote Herdr session. wooloo runs `herdr machine add --remote-session …`; Herdr prepares the remote server and persists its own machine profile. No separate wooloo host database is created. SSH keys, ports and proxies follow OpenSSH configuration.

The manager also delegates rename, enable, disable and remove to `herdr machine`. Disabled hosts remain visible in the manager but are omitted from the picker. Removing a profile does not delete remote files or stop its sessions.

Host selection currently controls the file explorer, repository operations and host information. It does not attach the terminal surface to a remote Herdr session.

Preparation runs without a terminal and has a two-minute timeout. If SSH needs a password, host-key confirmation or other interactive authentication, first connect using SSH in Terminal, then retry. Herdr errors are displayed in the manager.

Validation uses a fake Herdr executable in `WorkspaceHerdrCommandTests`; it does not modify the user's saved machines.

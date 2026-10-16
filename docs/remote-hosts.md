# Remote hosts

Open the session/host picker at the bottom of the sidebar and choose **Manage Remote Hosts…** under **Hosts**.

Add an OpenSSH target (`user@host`, an alias from `~/.ssh/config`, or `ssh://user@host:port`), an optional label and a remote Herdr session. wooloo runs `herdr machine add --remote-session …`; Herdr prepares the remote server and persists its own machine profile. No separate wooloo host database is created. SSH keys, ports and proxies follow OpenSSH configuration.

The manager also delegates rename, enable, disable and remove to `herdr machine`. Disabled hosts remain visible in the manager but are omitted from the picker. Removing a profile does not delete remote files or stop its sessions.

Selecting a host switches the entire session: Spaces, tabs, terminal panes, agents, file explorer, Git operations, host information and quotas. The saved profile’s remote session is used explicitly. New Spaces, tabs and terminal input target that server. Selecting **Local** returns to this Mac’s last selected local session.

The app uses private local sockets and OpenSSH channels to Herdr’s `remote-api-bridge` and `remote-client-bridge`. Herdr must already be installed and prepared on the remote host through the machine manager. Selecting a host does not install software. A failed remote connection stays on that host and shows an error; it never falls back to issuing commands locally. Switching away closes the attachment, leaving the server, shells and agents running.

Open documents, including unsaved edits, are scoped by host, session and Space. Returning to a host restores its documents without mixing identically numbered Spaces from different servers. Herdr configuration editing is available for Local; remote configuration remains managed on its own host. Appearance, notification preferences and this Mac’s Remote Access settings remain app settings.

Preparation runs without a terminal and has a two-minute timeout. If SSH needs a password, host-key confirmation or other interactive authentication, first connect using SSH in Terminal, then retry. Herdr errors are displayed in the manager.

Validation uses a fake Herdr executable in `WorkspaceHerdrCommandTests`, plus isolated API and binary endpoint servers connected through a duplex subprocess bridge in `HerdrStoreTests`. The latter exercises executable discovery, session routing, Spaces, agents, terminal input, tab creation, failed connections and attachment cleanup. `WorkspaceDocumentStoreTests` covers unsaved documents across identically numbered Spaces on different hosts. Tests do not modify the user's saved machines.

The transport follows Herdr 0.9.3’s [saved SSH API and client bridges](https://github.com/herdrdev/herdr/blob/v0.9.3/src/remote/saved.rs).

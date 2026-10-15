# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub's vulnerability reporting](https://github.com/rarce/wooloo/security/advisories/new), not in a public issue. Include the steps to reproduce, the wooloo commit, your macOS version, and whether the Space was local or on an SSH machine.

## Supported versions

wooloo is an early preview (0.x) with no guaranteed response time or support period. Releases are published on [GitHub Releases](https://github.com/rarce/wooloo/releases), and installed copies update themselves from there.

- Security fixes go to the `main` branch and ship in a following release. Reports are assessed against the latest release; fixes for older versions are not promised, so keep wooloo updated.
- Builds are signed ad hoc and not notarized yet. Download them only from this repository's releases and check the SHA-256 in the release notes. Updates are accepted only when signed with the project's EdDSA key.

## Scope

wooloo runs on your Mac and acts on your behalf, so these are the areas where a bug matters most:

- **Commands.** wooloo runs `git`, `herdr` and shell scripts locally, and over SSH on machines saved in Herdr. A file name, branch, commit message or search query that gets executed instead of used as data is a vulnerability.
- **Files.** Reading and saving are limited to the selected Space. A path, symlink or race that reads or writes outside it is a vulnerability.
- **Agent sign-ins.** QUOTAS reads Claude Code's and Codex's tokens only for a machine the user agreed to in its consent dialog, and sends them only to Anthropic's and OpenAI's usage endpoints. A token that is read before that agreement, written to disk, logged, shown in the interface or sent anywhere else is a vulnerability.
- **Remote Access.** The tunnel publishes this Mac's SSH server. A tunnel that starts without the user's action, without the sign-in check described in the README, or without the confirmation that check asks for, or a tunnel token that leaves the Keychain other than through `cloudflared`'s environment, is a vulnerability. Weak SSH settings on the Mac itself are not: wooloo reports them but does not change them.
- **Herdr sockets.** wooloo talks to Herdr over Unix sockets in `~/.config/herdr`. It trusts that local server.

Vulnerabilities in Herdr itself, in SSH, or in Git belong to those projects.

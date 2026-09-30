# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub's vulnerability reporting](https://github.com/rarce/xherdr/security/advisories/new), not in a public issue. Include the steps to reproduce, the xherdr commit, your macOS version, and whether the Space was local or on an SSH machine.

xherdr is in early development and has no releases yet; fixes go to the `main` branch.

## Scope

xherdr runs on your Mac and acts on your behalf, so these are the areas where a bug matters most:

- **Commands.** xherdr runs `git`, `herdr` and shell scripts locally, and over SSH on machines saved in Herdr. A file name, branch, commit message or search query that gets executed instead of used as data is a vulnerability.
- **Files.** Reading and saving are limited to the selected Space. A path, symlink or race that reads or writes outside it is a vulnerability.
- **Herdr sockets.** xherdr talks to Herdr over Unix sockets in `~/.config/herdr`. It trusts that local server.

Vulnerabilities in Herdr itself, in SSH, or in Git belong to those projects.

<!-- Draft for the next release. Rename to vX.Y.Z.md (the tag) before tagging; the workflow then
     uses it as the release notes and the update dialog's text, and appends the Keychain note. -->

## Quotas

- **One consent for every way in.** Turning QUOTAS on, from the section's button or its context menu, now opens the same dialog, which lists what is read (Claude Code's and Codex's sign-ins and Codex's session logs), where (this Mac, or the SSH machine the explorer shows), and where the tokens go (`api.anthropic.com` and `chatgpt.com`, unofficial endpoints that can change). Cancel leaves it off and reads nothing. Before, the context menu turned it on without that explanation.
- **Per machine.** Agreeing for this Mac no longer reads an SSH machine's sign-ins when the explorer moves there. **Turn Off Quotas** turns it off everywhere.
- Copies that had QUOTAS on are asked once more.

## Remote Access

- **Checks SSH before publishing it.** wooloo asks this Mac's SSH server which sign-in methods it offers. Key-only servers start at once; one that accepts passwords, or that could not be checked, publishes nothing until you choose **Start Anyway**, and the status then says the tunnel runs without verified key-only SSH. A server that lets anyone in is never published. wooloo still never changes SSH settings.
- **Start at launch** happens only after a key-only check.
- The settings say exactly what is published (this Mac's SSH server, for every account allowed to use SSH) and what is not checked.

## Editor

- **No unseen overwrite.** If the file changes on disk again while the Overwrite / Reload / Cancel question is shown, Overwrite now writes nothing and says why; the next save asks about the newer file.

## Website and documentation

- wooloo.dev leads with what the app does, marks downloads as an early preview that is not notarized, adds a quick start, links to privacy, Quotas, Remote Access, security and the latest release, and opens the screenshot at full size.
- SECURITY.md describes releases and supported versions. The performance notes now tell keystroke-to-draw times (about 1 ms) apart from the estimated time to the screen (about 14 ms at p50 on a 120 Hz display).

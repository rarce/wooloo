# Mobile access to local and remote sessions

## Plan

The existing QR opens herdroid's host editor with `transport=cloudflare`, this Mac's
username, local Herdr path and local SSH host fingerprints. It never authorizes a
phone key. When settings are opened from a remote session, the QR still describes
the Mac and falls back to its last local session.

1. Carry the selected `HerdrMachineProfile` into settings. Resolve its SSH alias
   with `ssh -G`; read the username, home, Herdr executable and public host keys
   through the existing authenticated connection. Keep that target immutable for
   the lifetime of an authorization operation.
2. For a remote session, generate `herdroid://add-host?transport=ssh` with the
   remote session, user, host, port, executable and fingerprints. Let the user
   correct the phone-facing hostname and port, since aliases, jump hosts and VPN
   routes on the Mac do not establish reachability from a phone. Do not start or
   require a Cloudflare process for this path. Keep the existing local tunnel.
3. Accept the phone's shared OpenSSH public key. Reject private keys, commands,
   options, multiple keys and malformed blobs. Show the fingerprint, machine,
   account and absolute `authorized_keys` path before an explicit authorization.
   Explain that this grants SSH access to the account, across its sessions.
4. Install through the existing SSH connection (or locally for a local session),
   off the main thread. Preserve existing entries and restrictions, recognize a
   key independently of its comment, use 0700/0600 permissions and refuse symbolic
   links. Never transfer a private key or use sudo.
5. Add direct-link, alias, remote-identity and disposable-home installation tests.
   Build and run the wooloo suite. In herdroid, add a public-key copy action and
   remove instructions that require Cloudflare for every QR; validate those UI
   changes and the existing direct-link parser.

## Acceptance criteria

- A remote session's QR describes that server and that session, never this Mac.
- A publicly reachable SSH server works without `cloudflared` installed locally.
- Authorization names the destination and the SSH access being granted before
  changing anything. Errors do not fall back to writing on the Mac.
- Existing keys, comments and per-key restrictions survive authorization. A second
  authorization does not duplicate a key or remove its existing restrictions.
- Public host fingerprints come from the selected server. When unavailable,
  the phone's normal host-key verification remains necessary.
- A phone on a different network must be able to reach the advertised hostname
  and SSH port. A domain alone does not prove that its SSH service is public.

## Scope

The connection QR contains connection details and server identity. The phone's
public key returns through its copy/share action and is pasted into wooloo.
Automatic bidirectional pairing, remote tunnel management, SSH daemon changes,
custom `AuthorizedKeysFile` locations and revocation are outside this change.

## Implementation and validation

wooloo branch: `feat/mobile-ssh-remote-access`, based on freshly fetched
`origin/main` at `550573e`. Companion branch: `feat/mobile-remote-access` in
herdroid, based on `1f0d2ab`. Both use isolated worktrees.

- `MobileSSHAccess` resolves the saved SSH endpoint, reads remote identity and
  finds a compatible Herdr executable using the same locations as the bridge.
  `MobileSSHAccessView` shows the connection QR and a separate authorization
  review. Existing local tunnels remain independently stoppable from a remote
  session's settings.
- The key installer passes the validated public key through stdin. It locks
  wooloo authorizations, preserves existing content during atomic replacement,
  and recognizes entries with quoted options without widening their access.
- Build: passed with ad hoc signing; `codesign --verify` passed. Package versions
  remain unchanged, including swift-collections 1.7.1.
- Targeted final validation: 14 new behavior tests and the new remote settings
  snapshot passed (15/15). The QR also decodes to its exact link using CoreImage.
- Full macOS suite: 1,034 tests, 11 skipped, 4 failures. The failures are existing
  document snapshots: `testDocumentChangedOnDisk`, `testMarkdownPreview`,
  `testNotebookPreviewDocument`, and `testNotebookPreview`. All four were rerun
  on a clean worktree of base `550573e`, with identical pixel difference counts
  (12,383; 1,863; 9,531; 9,597 respectively). Their baselines were left intact.
- Native UI: a separately signed copy with a separate bundle identity connected
  to `wooloo-ui-test` using temporary XDG and editor-session directories. Invalid
  input disabled review; a fixture public key displayed its fingerprint and the
  authorization dialog named the account, path, scope and permissions. Cancel
  returned to settings. No key was installed and no tunnel was started. The app
  was closed and the isolated server stopped afterward.
- Android: the companion agent built debug and minified release, passed coverage
  gates and lint (0 errors; existing warnings), ran 183 passing JVM tests with 7
  opt-in skips and 11 passing device tests. The updated APK is installed on the
  isolated API 36.1 emulator. Its scanner imported the actual Swift-generated QR
  image through the photo picker, preserving transport, host, port, user, session,
  Herdr path and host fingerprint. Copy public key was checked against the system
  clipboard. See the companion's `docs/review-2026-10-17/remote-access/README.md`.

The new macOS layout is captured in
[`settings-remote-access-macOS26.6.png`](../woolooTests/Snapshots/Views/settings-remote-access-macOS26.6.png).
Logs and the interoperable fixture QR are in the worktree's ignored `build/`
directory. A full phone-to-public-server SSH connection was not exercised;
authorization tests use disposable directories and a controlled SSH adapter.

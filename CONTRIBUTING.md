# Contributing to wooloo

Thanks for helping. Bug reports, ideas and pull requests are all welcome. For a larger change, open an issue first so we can agree on the approach. `TODO.md` lists work that is already planned.

## Set up

You need macOS 15.6 or later with Xcode 26 (one vendored package needs Swift 6.2; the app itself runs on macOS 14), Git, and [Herdr](https://herdr.dev/) 0.9 or later.

The project signs ad hoc ("Sign to Run Locally"), so no developer account is needed:

```sh
xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' build
```

Keep a signature: with `CODE_SIGNING_ALLOWED=NO` the app lacks its bundle identity and macOS refuses its notification permission. For interactive checks, open the project in Xcode and run the `wooloo` scheme on My Mac.

Develop against a separate Herdr session, never your main one:

```sh
herdr --session wooloo-ui-test server
herdr --session wooloo-ui-test workspace create --cwd "$PWD" --label wooloo-test
herdr --session wooloo-ui-test server stop   # when finished
```

## Tests

Run the unit tests by replacing `build` with `test` in the command above. Add `-only-testing:woolooTests/ClassName` to run one class. The Git, SSH and Herdr socket tests create disposable repositories and sockets under `/private/tmp/wooloo-tests` and remove them afterwards; they ignore your global Git config.

- **Terminal rendering or surface changes:** also run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh`, and compare with the baselines described in `docs/perf/README.md`. Pixel snapshots are compared only where FiraCode Nerd Font Mono is installed; re-record them with `TEST_RUNNER_WOOLOO_RECORD_SNAPSHOTS=1` when a change is intended.
- **Git worktree changes:** try them in a disposable repository under `/private/tmp`, and confirm that normal removal still rejects dirty worktrees.
- **UI changes:** exercise the affected controls in the app against the isolated Herdr session.
- **Bundled runtime and launchd lifecycle:** `TEST_RUNNER_WOOLOO_RUNTIME_E2E=1 xcodebuild -project wooloo.xcodeproj -scheme wooloo -configuration Debug -destination 'platform=macOS' -only-testing:woolooTests/HerdrRuntimeTests test` runs them against a real server, with temporary config, state and runtime roots and only the `wooloo-ui-test` session. For an interactive isolated setup, launch a test copy with `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `WOOLOO_RUNTIME_ROOT` pointing under `/private/tmp`, and `WOOLOO_SETUP_SESSION=wooloo-ui-test`.
- **Remote access:** `TEST_RUNNER_WOOLOO_CLOUDFLARE_TUNNEL_TEST=1` runs `RemoteAccessTests/testRealQuickTunnelReachesThisMacsSSH` against a real quick tunnel (`WOOLOO_CLOUDFLARE_TUNNEL_TEST=1` outside `xcodebuild test`).

CI runs the build and unit tests on every pull request.

## Code

- Swift with four-space indentation, following the existing SwiftUI style: `UpperCamelCase` types, `lowerCamelCase` members, descriptive names such as `WorkspaceRepositoryView`.
- Keep process, file and SSH work off the main thread. Pass command arguments as arrays, quote anything sent to a shell with `WorkspaceFiles.quote`, and validate paths before reading or writing.
- The Xcode project lists its sources explicitly: add new Swift files to `wooloo.xcodeproj/project.pbxproj`.
- After adding or updating a dependency, build once and run `scripts/third-party-notices.py` to refresh `THIRD_PARTY_NOTICES.txt`. When updating the bundled Herdr, first run `scripts/herdr-notices.py` on a Herdr checkout of the new tag.

## Commits and pull requests

Use short imperative commit subjects, for example `Filter explorer to modified files`, and keep each commit focused. A pull request should describe the user-visible change, the build and manual checks you ran, and any local or SSH limitation. Include screenshots for layout changes and link related issues or `TODO.md` items.

By contributing, you agree that your contributions are licensed under the MIT License in `LICENSE`.

## Releases

Maintainers release by tag; `.github/workflows/release.yml` does the rest.

1. Raise `MARKETING_VERSION` in `wooloo.xcodeproj/project.pbxproj` (both configurations of the app target) and merge it. The build number follows it, and Sparkle compares versions by it, so versions are plain `X.Y.Z`: no prerelease suffixes, and a broken release is replaced by the next patch version, never rebuilt under the same one.
2. Optionally write the notes in `docs/releases/vX.Y.Z.md`; otherwise GitHub generates them from the merged pull requests. They appear in the release and in the update dialog.
3. Once CI has passed on that commit of `main`, push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. The workflow refuses a commit that is not on `main` or has not passed CI.

The workflow builds the universal app, publishes `wooloo-X.Y.Z.zip` and `appcast.xml`, and installed copies find the update through `https://github.com/rarce/wooloo/releases/latest/download/appcast.xml`. Every release must therefore carry `appcast.xml`; do not publish releases by hand. A fix to an older line (0.2.1 after 0.3.0) is published without becoming the latest release, so it does not replace the feed.

Only Release builds check for updates (`WOOLOO_UPDATES` compilation condition): Debug builds and tests never do, and `WOOLOO_DISABLE_UPDATES=1` turns the updater off in a Release build, as `scripts/terminal-e2e.sh` does.

The archive and the feed are signed with an EdDSA key whose public half is `SUPublicEDKey` in `wooloo/Info.plist`. The private key is the `SPARKLE_PRIVATE_KEY` repository secret, with a copy in the maintainer's Keychain (account `wooloo`, Sparkle's `generate_keys`). Losing it means installed copies can no longer be updated; `scripts/release-appcast.sh` signs a local build with the Keychain copy to try a release without CI.

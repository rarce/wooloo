# Contributing to xherdr

Thanks for helping. Bug reports, ideas and pull requests are all welcome. For a larger change, open an issue first so we can agree on the approach. `TODO.md` lists work that is already planned.

## Set up

You need macOS 14 or later, Xcode 26 (one vendored package needs Swift 6.2), Git, and [Herdr](https://herdr.dev/) 0.9 or later.

The project signs ad hoc ("Sign to Run Locally"), so no developer account is needed:

```sh
xcodebuild -project xherdr.xcodeproj -scheme xherdr -configuration Debug -destination 'platform=macOS' build
```

Keep a signature: with `CODE_SIGNING_ALLOWED=NO` the app lacks its bundle identity and macOS refuses its notification permission. For interactive checks, open the project in Xcode and run the `xherdr` scheme on My Mac.

Develop against a separate Herdr session, never your main one:

```sh
herdr --session xherdr-ui-test server
herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test
herdr --session xherdr-ui-test server stop   # when finished
```

## Tests

Run the unit tests by replacing `build` with `test` in the command above. Add `-only-testing:xherdrTests/ClassName` to run one class. The Git, SSH and Herdr socket tests create disposable repositories and sockets under `/private/tmp/xherdr-tests` and remove them afterwards; they ignore your global Git config.

- **Terminal rendering or surface changes:** also run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh`, and compare with the baselines described in `docs/perf/README.md`. Pixel snapshots are compared only where FiraCode Nerd Font Mono is installed; re-record them with `TEST_RUNNER_XHERDR_RECORD_SNAPSHOTS=1` when a change is intended.
- **Git worktree changes:** try them in a disposable repository under `/private/tmp`, and confirm that normal removal still rejects dirty worktrees.
- **UI changes:** exercise the affected controls in the app against the isolated Herdr session.

CI runs the build and unit tests on every pull request.

## Code

- Swift with four-space indentation, following the existing SwiftUI style: `UpperCamelCase` types, `lowerCamelCase` members, descriptive names such as `WorkspaceRepositoryView`.
- Keep process, file and SSH work off the main thread. Pass command arguments as arrays, quote anything sent to a shell with `WorkspaceFiles.quote`, and validate paths before reading or writing.
- The Xcode project lists its sources explicitly: add new Swift files to `xherdr.xcodeproj/project.pbxproj`.
- After adding or updating a dependency, build once and run `scripts/third-party-notices.py` to refresh `THIRD_PARTY_NOTICES.txt`. When updating the bundled Herdr, first run `scripts/herdr-notices.py` on a Herdr checkout of the new tag.

## Commits and pull requests

Use short imperative commit subjects, for example `Filter explorer to modified files`, and keep each commit focused. A pull request should describe the user-visible change, the build and manual checks you ran, and any local or SSH limitation. Include screenshots for layout changes and link related issues or `TODO.md` items.

By contributing, you agree that your contributions are licensed under the MIT License in `LICENSE`.

# Repository Guidelines

## Project Structure & Module Organization

The macOS app lives in `xherdr/`; `xherdr.xcodeproj` defines the `xherdr` scheme and includes Swift files explicitly. `ContentView.swift` assembles the interface, `HerdrConnection.swift` and `HerdrSurface.swift` handle the server and terminal surface, and `WorkspaceFiles.swift` handles local and SSH file and Git operations. Keep related views beside these files. Update `project.pbxproj` when adding a Swift source file. `Assets.xcassets` contains the app icon, `docs/` contains implementation research, `Vendor/` contains pinned CodeEdit packages and licenses, and `TODO.md` tracks deferred work. `xherdrTests` holds the unit tests and terminal pipeline benchmarks, and `scripts/` the measurement scripts described in `docs/perf/README.md`.

## Build, Test, and Development Commands

Run `xcodebuild -project xherdr.xcodeproj -scheme xherdr -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` to compile with an ad hoc signature and no developer account. Keep the signature: with `CODE_SIGNING_ALLOWED=NO` the app lacks its bundle identity and macOS refuses its notification permission. Open the project in Xcode and run the `xherdr` scheme on My Mac for interactive checks. For server testing, start `herdr --session xherdr-ui-test server`, then create a Space with `herdr --session xherdr-ui-test workspace create --cwd "$PWD" --label xherdr-test`. Stop that instance with `herdr --session xherdr-ui-test server stop`. Do not use the primary Herdr session for development checks.

## Coding Style & Naming Conventions

Use four spaces for Swift indentation. Follow the existing SwiftUI style: `UpperCamelCase` for types, `lowerCamelCase` for properties and functions, and descriptive view and service names such as `WorkspaceRepositoryView` and `WorkspaceFiles`. Keep process and SSH work off the main thread, pass command arguments as arrays, and validate paths before reading or writing files. No repository-wide formatter or lint command is configured.

## Testing Guidelines

Run the unit tests with the build command above, replacing `build` with `test`; CI (`.github/workflows/ci.yml`) runs the same command on every push and pull request. There is no coverage threshold. Pixel snapshots are compared only where FiraCode Nerd Font Mono is installed. For terminal rendering or surface changes, also run `scripts/terminal-bench.sh` and `scripts/terminal-e2e.sh`; the second uses its own `xherdr-perf` Herdr session. Build after Swift or project changes, then exercise affected controls in the app against the isolated Herdr session. Test Git worktree operations in a disposable repository under `/private/tmp`; confirm that normal removal rejects dirty worktrees. Name tests for the behavior they verify.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects, for example `Filter explorer to modified files`. Keep each commit focused. Pull requests should describe the user-visible change, the build and manual checks performed, and any local or SSH limitations. Include screenshots for layout changes and link relevant issues or TODO items.

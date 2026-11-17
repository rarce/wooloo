# libghostty-vt for herdr-core terminals

`WoolooTerminalEngine` wraps [libghostty-vt](https://github.com/ghostty-org/ghostty/tree/vt-1.0.1), the terminal emulator of Ghostty and of the official Herdr app. wooloo uses it to draw herdr-core terminals, whose output arrives as raw bytes (decision D1 in `docs/proposals/herdr-core-backend.md`).

- **Pinned binary:** `Package.swift` fetches the published `ghostty-vt-1.0.1.xcframework.zip` (static libraries for macOS arm64 and x86_64, with the `GhosttyVt` C module). SwiftPM checks the SHA-256 that the release lists in `SHA256SUMS`. Nothing is built from source, and no Zig toolchain is needed.
- **Updating:**
  1. Change the URL and checksum (from the new release's `SHA256SUMS`).
  2. Rebuild `LICENSES.txt` from the release's source and dependency tarballs (`deps/libghostty-vt-third-party.json`, entries with `"use": "linked"`).
  3. Run `scripts/third-party-notices.py`.
- **Checking on another OS:** `VTTerminal.swift` imports only `GhosttyVt` and Foundation. It can be type-checked anywhere by building a library target against the xcframework's `Headers` folder, without linking.

// swift-tools-version: 5.9
import PackageDescription

// libghostty-vt, the terminal emulator of the official Herdr app and of Ghostty, pinned to a
// published release and checked by its SHA-256 (from the release's SHA256SUMS). Decision D1 of
// docs/proposals/herdr-core-backend.md. `WoolooTerminalEngine` is wooloo's Swift wrapper.
let package = Package(
    name: "WoolooTerminalEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WoolooTerminalEngine", targets: ["WoolooTerminalEngine"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"
        ),
        .target(
            name: "WoolooTerminalEngine",
            dependencies: ["GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)

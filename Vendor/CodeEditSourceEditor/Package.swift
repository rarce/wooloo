// swift-tools-version: 5.9

import PackageDescription

// CodeEditSourceEditor 0.9.1 (b0688fa), vendored under its MIT license.
// The upstream SwiftLint build plugin is omitted because it is only used
// during package development and requires a separate binary download.
let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodeEditSourceEditor", targets: ["CodeEditSourceEditor"])
    ],
    dependencies: [
        .package(path: "../CodeEditTextView"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", exact: "0.9.0")
    ],
    targets: [
        .target(name: "CodeEditSourceEditor", dependencies: [
            "CodeEditTextView", "CodeEditLanguages", "TextFormation"
        ])
    ]
)

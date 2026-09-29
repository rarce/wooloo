// swift-tools-version: 6.2
import PackageDescription

// Vendored MarkdownView without the LaTeX trait: SwiftMath and its math fonts are omitted,
// so ENABLE_MATH_RENDERING stays undefined and math renders as plain text.
let package = Package(
    name: "MarkdownView",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MarkdownView", targets: ["MarkdownView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/LiYanan2004/RichText.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MarkdownView",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "RichText", package: "RichText"),
            ]
        ),
    ]
)

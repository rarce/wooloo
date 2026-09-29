// swift-tools-version: 5.9
import PackageDescription

// Vendored BeautifulMermaid library target; the playground executable and tests are omitted.
let package = Package(
    name: "BeautifulMermaid",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "BeautifulMermaid", targets: ["BeautifulMermaid"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lukilabs/elk-swift", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "BeautifulMermaid",
            dependencies: [.product(name: "ElkSwift", package: "elk-swift")],
            path: "Sources/BeautifulMermaidSwift"
        ),
    ]
)

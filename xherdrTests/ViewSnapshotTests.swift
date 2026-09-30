import AppKit
import SwiftUI
import XCTest
@testable import xherdr

/// Pixel snapshots of a few key screens, to catch layout regressions. Rendering depends on the
/// macOS version and its fonts, so each snapshot is saved per macOS version: a missing one is
/// recorded and the test skipped. CI does not run these. Set `XHERDR_RECORD_SNAPSHOTS=1` to
/// record them again after an intended change.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Snapshots/Views")
    private static let theme = XherdrTheme.named(XherdrTheme.fallbackID)!
    private var recorded: [String] = []

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS\(version.majorVersion).\(version.minorVersion)"
    }

    /// Renders a view at a fixed size in the theme's appearance, as ContentView sets it, waiting
    /// until asynchronous loads settle:
    /// two captures in a row must match.
    private func render<Content: View>(_ content: Content, size: NSSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content
            .environment(\.xherdrTheme, Self.theme)
            .environment(\.xherdrTypography, XherdrTypography())
            .preferredColorScheme(Self.theme.colorScheme)
            .frame(width: size.width, height: size.height)
            // Views that leave their background to the window, such as the settings sheet.
            .background(SwiftUI.Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: Self.theme.isDark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }

        func capture() -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        var previous = capture()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let next = capture()
            if next.tiffRepresentation == previous.tiffRepresentation { return next }
            previous = next
        }
        return previous
    }

    /// Compares with the saved snapshot, allowing for a few antialiased pixels.
    private func assertSnapshot(_ bitmap: NSBitmapImageRep, named name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.directory.appendingPathComponent("\(name)-\(Self.systemVersion).png")
        let record = ProcessInfo.processInfo.environment["XHERDR_RECORD_SNAPSHOTS"] == "1"
        if record || !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            recorded.append(url.lastPathComponent)
            return
        }
        let expected = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        let actual = try XCTUnwrap(TerminalRenderHarness.pixels(of: bitmap))
        let saved = try XCTUnwrap(TerminalRenderHarness.pixels(of: expected))
        guard actual.width == saved.width, actual.height == saved.height else {
            return XCTFail("\(name): \(actual.width)×\(actual.height) instead of \(saved.width)×\(saved.height)",
                           file: file, line: line)
        }
        var differing = 0
        for index in stride(from: 0, to: actual.bytes.count, by: 4)
            where (0..<4).contains(where: { abs(Int(actual.bytes[index + $0]) - Int(saved.bytes[index + $0])) > 8 }) {
            differing += 1
        }
        if differing > actual.width * actual.height / 1000 {
            let failure = FileManager.default.temporaryDirectory.appendingPathComponent("xherdr-\(name)-actual.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: failure)
            XCTFail("\(name): \(differing) pixels differ from \(url.lastPathComponent); actual image at \(failure.path)",
                    file: file, line: line)
        }
    }

    /// Skips a test that recorded snapshots instead of comparing them.
    private func skipIfRecorded() throws {
        if !recorded.isEmpty { throw XCTSkip("Recorded snapshots: \(recorded.joined(separator: ", "))") }
    }

    func testThemePicker() throws {
        let view = ThemeSettingsView(name: .constant("tokyo-night"), autoSwitch: .constant(true),
                                     lightName: .constant("catppuccin-latte"), darkName: .constant("tokyo-night"))
            .padding(20)
        try assertSnapshot(render(view, size: NSSize(width: 760, height: 940)), named: "theme-picker")
        try skipIfRecorded()
    }

    /// Settings as they open for a config with a few values set, in two sections.
    func testSettings() throws {
        let config = try TemporaryHerdrConfig("""
            [ui.sound]
            enabled = false

            [ui.toast]
            delivery = "herdr"

            [keys]
            prefix = "ctrl+a"
            """)
        defer { config.restore() }
        let defaults = UserDefaults.standard
        let keys = [XherdrTypography.baseKey, XherdrTypography.codeKey, HerdrNotifier.dockBadgeKey, HerdrNotifier.bounceDockKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject(forKey:))

        let size = NSSize(width: 800, height: 540)
        try assertSnapshot(render(HerdrSettingsView(socketPath: "/nonexistent.sock", sessionName: "work"), size: size),
                           named: "settings-terminal")
        try assertSnapshot(render(HerdrSettingsView(socketPath: "/nonexistent.sock", sessionName: "work",
                                                    showShortcuts: true), size: size),
                           named: "settings-shortcuts")
        try skipIfRecorded()
    }

    func testDiff() throws {
        let patch = """
            diff --git a/src/greeting.swift b/src/greeting.swift
            --- a/src/greeting.swift
            +++ b/src/greeting.swift
            @@ -1,6 +1,7 @@
             import Foundation

            -func greet(_ name: String) -> String {
            -    "Hello, " + name
            +/// Greets someone by name.
            +func greet(_ name: String, excited: Bool = false) -> String {
            +    "Hello, \\(name)" + (excited ? "!" : ".")
             }

             print(greet("world"))
            """
        let location = WorkspaceFileLocation(machine: nil, session: "test", workspaceID: "w", workspaceLabel: "w",
                                             root: "/private/tmp/xherdr-tests/no-such-repo")
        let source = DiffSource(location: location, path: "src/greeting.swift", originalPath: nil, commit: nil, scope: .all)
        for mode in DiffDisplayMode.allCases {
            try assertSnapshot(render(WorkspaceDiffView(text: patch, source: source, mode: mode),
                                      size: NSSize(width: 820, height: 300)),
                               named: "diff-\(mode.rawValue.lowercased())")
        }
        try skipIfRecorded()
    }

    /// The Git bar with its commit editor, over a repository with one changed file.
    func testGitBar() throws {
        let sandbox = try WorkspaceGitSandbox()
        defer { sandbox.tearDown() }
        let repo = try sandbox.repository("repo", files: ["README.md": "one\n"])
        try sandbox.write(["README.md": "two\n"], in: "repo")
        let changes = [WorkspaceFileChange(path: "README.md", indexStatus: " ", worktreeStatus: "M", originalPath: nil)]
        let bar = WorkspaceGitBar(location: repo, reloadToken: 0, changes: changes, onChange: {},
                                  onOpenWorktree: nil, onError: { XCTFail($0) })
        try assertSnapshot(render(bar, size: NSSize(width: 300, height: 150)), named: "git-bar")
        try skipIfRecorded()
    }
}

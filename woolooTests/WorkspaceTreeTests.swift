import AppKit
import SwiftUI
import XCTest
import Markdown
@testable import wooloo

/// The explorer's folder tree: folders first, single-folder chains on one row, only expanded
/// folders' children visible.
final class WorkspaceTreeTests: XCTestCase {
    private let paths = ["README.md", "src/app/main.swift", "src/app/util.swift", "docs/a.md", "b.txt",
                         "file10.txt", "file2.txt", "/etc/passwd", "../outside", "a/./b", "a/../b"]

    private func rows(expanded: Set<String> = []) -> [(path: String, name: String, depth: Int, folder: Bool)] {
        WorkspaceTree(paths: paths).visibleRows(expanded: expanded, identity: "space")
            .map { ($0.node.path, $0.node.displayName, $0.depth, $0.node.isDirectory) }
    }

    func testFoldersComeFirstAndNamesSortNaturally() {
        let top = rows()
        XCTAssertEqual(top.map(\.name), ["docs", "src / app", "b.txt", "file2.txt", "file10.txt", "README.md"])
        XCTAssertEqual(top.map(\.folder), [true, true, false, false, false, false])
        XCTAssertEqual(Set(top.map(\.depth)), [1])
    }

    /// `src` holds only `app`, so they share one row that opens `src/app`; `docs` holds a file and stays.
    func testSingleFolderChainsCollapseIntoOneRow() {
        let top = rows()
        XCTAssertEqual(top[1].path, "src/app")
        XCTAssertEqual(top[0].path, "docs")
    }

    func testExpandedFoldersShowTheirChildren() {
        let expanded = rows(expanded: ["space|src/app"])
        XCTAssertEqual(expanded.map(\.path),
                       ["docs", "src/app", "src/app/main.swift", "src/app/util.swift", "b.txt", "file2.txt", "file10.txt", "README.md"])
        XCTAssertEqual(expanded[2].depth, 2)

        // Expansion is remembered per Space.
        XCTAssertEqual(rows(expanded: ["other|src/app"]).count, 6)
    }

    /// Folders inside a chain shown on one row are still folders, for the file shortcuts.
    func testDirectoriesIncludeEveryFolder() {
        let tree = WorkspaceTree(paths: paths, directories: ["empty"])
        XCTAssertEqual(tree.directories, ["docs", "src", "src/app", "empty"])
    }

    /// The tree is built once; walking it with more folders open does not change it.
    func testRowsComeFromTheBuiltTree() {
        let tree = WorkspaceTree(paths: paths)
        XCTAssertEqual(tree.visibleRows(expanded: [], identity: "space").count, 6)
        XCTAssertEqual(tree.visibleRows(expanded: ["space|src/app", "space|docs"], identity: "space").count, 9)
        XCTAssertTrue(WorkspaceTree(paths: []).isEmpty)
    }

    func testSymbolicLinkFoldersKeepTheirOwnRowWhenExpanded() {
        let link = WorkspaceSymbolicLink(target: "../elsewhere", isDirectory: true)
        let tree = WorkspaceTree(paths: ["parent/link/child/file.txt"], directories: ["parent/link"],
                                 symbolicLinks: ["parent/link": link])
        let rows = tree.visibleRows(expanded: ["space|parent", "space|parent/link"], identity: "space")
        XCTAssertEqual(rows.map(\.node.path), ["parent", "parent/link", "parent/link/child"])
        XCTAssertEqual(rows[1].node.symbolicLink, link)
        XCTAssertEqual(rows[1].node.displayName, "link")
    }

    func testPathsOutsideTheSpaceAreIgnored() {
        let all = rows(expanded: ["space|docs", "space|src/app"]).map(\.path)
        XCTAssertFalse(all.contains { $0.contains("etc") || $0.contains("outside") || $0.hasPrefix("a") })
    }
}

/// Links and images in a Markdown preview resolve inside the Space, relative to the document.
final class MarkdownSpaceLinksTests: XCTestCase {
    private func resolve(_ target: String) -> String? {
        MarkdownSpaceLinks.resolve(target, documentPath: "docs/guide/readme.md")
    }

    func testRelativeAndRootedTargets() {
        XCTAssertEqual(resolve("img.png"), "docs/guide/img.png")
        XCTAssertEqual(resolve("./x/../y.png"), "docs/guide/y.png")
        XCTAssertEqual(resolve("../../top.md"), "top.md")
        XCTAssertEqual(resolve("/assets/logo.png"), "assets/logo.png")
        XCTAssertEqual(resolve("other.md#install"), "docs/guide/other.md")
        XCTAssertEqual(resolve("other.md?plain=1"), "docs/guide/other.md")
    }

    func testTargetsLeavingTheSpaceOrWithoutAFileAreRejected() {
        XCTAssertNil(resolve("../../../etc/passwd"))
        XCTAssertNil(resolve("..%2F..%2F..%2Fetc%2Fpasswd"))
        XCTAssertNil(resolve("#section"))
        XCTAssertNil(resolve(""))
    }

    /// `#` and `?` inside an encoded file name belong to the name, not to a fragment or query.
    func testPercentEncodedNamesKeepTheirCharacters() {
        XCTAssertEqual(resolve("my%20file.md"), "docs/guide/my file.md")
        XCTAssertEqual(resolve("notes%20%231.md"), "docs/guide/notes #1.md")
        XCTAssertEqual(resolve("what%3F.md#top"), "docs/guide/what?.md")
    }

    func testImagesPointAtTheSpaceScheme() {
        let markdown = """
        ![logo](img/logo.png "Logo") and ![remote](https://example.com/a.png)
        ![spaced](<my image.png>)
        ```
        ![code](not/rewritten.png)
        ```
        ![escape](../../../secret.png)
        """
        let rewritten = MarkdownSpaceLinks.rewritingImages(in: markdown, documentPath: "docs/guide/readme.md")
        XCTAssertEqual(rewritten, """
        ![logo](wooloo-space:///docs/guide/img/logo.png "Logo") and ![remote](https://example.com/a.png)
        ![spaced](wooloo-space:///docs/guide/my%20image.png)
        ```
        ![code](not/rewritten.png)
        ```
        ![escape](../../../secret.png)
        """)
    }
}

/// Task list checkboxes clicked in the preview edit only their own `[ ]` in the source.
final class MarkdownTasksTests: XCTestCase {
    private let markdown = """
        # Plan

        - [ ] write
        - [x] review
          * [X] nested
        1. [ ] ordered
        2) [x] parenthesis
        > - [ ] quoted
        >> + [ ] twice quoted

        ```
        - [ ] in code
        ```
        - [~] not applicable
        """

    private func toggled(_ line: Int, _ checked: Bool) -> String? {
        MarkdownTasks.toggle(line: line, checked: checked, in: markdown).map {
            (markdown as NSString).replacingCharacters(in: $0.range, with: $0.text)
        }
    }

    private func line(_ number: Int, of text: String?) -> String? {
        text.map { $0.components(separatedBy: "\n")[number - 1] }
    }

    func testTogglesTheBoxOnTheGivenLine() {
        XCTAssertEqual(line(3, of: toggled(3, true)), "- [x] write")
        XCTAssertEqual(line(4, of: toggled(4, false)), "- [ ] review")
        XCTAssertEqual(line(5, of: toggled(5, false)), "  * [ ] nested")
        XCTAssertEqual(line(6, of: toggled(6, true)), "1. [x] ordered")
        XCTAssertEqual(line(7, of: toggled(7, false)), "2) [ ] parenthesis")
        XCTAssertEqual(line(8, of: toggled(8, true)), "> - [x] quoted")
        XCTAssertEqual(line(9, of: toggled(9, true)), ">> + [x] twice quoted")
        // Nothing else changes.
        XCTAssertEqual(toggled(3, true)?.replacingOccurrences(of: "- [x] write", with: "- [ ] write"), markdown)
    }

    /// A stale preview (the source changed under it) or a line without a task is left alone.
    func testRejectsLinesNotInTheExpectedState() {
        XCTAssertNil(toggled(3, false), "already not done")
        XCTAssertNil(toggled(4, true), "already done")
        XCTAssertNil(toggled(1, true), "a heading")
        XCTAssertNil(toggled(15, true), "an unknown marker")
        XCTAssertNil(toggled(99, true), "past the end")
    }

    /// The lines the renderer reports are the parser's list item lines; code is never a task.
    /// swift-markdown's cmark-gfm reads no tasks inside block quotes, so those render as text.
    func testParsedTaskItemsMapToTheirLines() {
        var lines: [Int] = []
        func collect(_ markup: any Markup) {
            if let item = markup as? ListItem, item.checkbox != nil, let line = item.range?.lowerBound.line {
                lines.append(line)
            }
            for child in markup.children { collect(child) }
        }
        collect(Document(parsing: markdown))
        XCTAssertEqual(lines, [3, 4, 5, 6, 7])
        for line in lines {
            XCTAssertNotNil(MarkdownTasks.toggle(line: line, checked: line == 3 || line == 6, in: markdown), "line \(line)")
        }
    }
}

/// Clicks in a hosted preview reach the checkbox and the double-click handler, in both styles.
@MainActor
final class MarkdownPreviewInteractionTests: XCTestCase {
    /// Previews compare by what they render, never by their callbacks, so a parent's update
    /// does not parse and build a long document again.
    func testPreviewsCompareByWhatTheyRender() {
        let location = WorkspaceFileLocation(machine: nil, session: "s", workspaceID: "w", workspaceLabel: "w", root: "/r")
        func preview(_ text: String = "# A", path: String = "A.md", focus: MarkdownFindFocus? = nil,
                     toggles: Bool = true) -> MarkdownPreviewView {
            MarkdownPreviewView(text: text, path: path, location: location, onOpenFile: { _ in }, focus: focus,
                                onToggleTask: toggles ? { _, _ in } : nil, onRevealLine: { _ in })
        }
        XCTAssertEqual(preview(), preview(), "New callbacks alone are no change")
        XCTAssertNotEqual(preview(), preview("# B"))
        XCTAssertNotEqual(preview(), preview(path: "B.md"))
        XCTAssertNotEqual(preview(), preview(focus: MarkdownFindFocus(block: 1, match: 0)))
        XCTAssertNotEqual(preview(), preview(toggles: false), "Read-only checkboxes are a change")
    }

    private var toggles: [(line: Int, checked: Bool)] = []
    private var reveals: [Int] = []

    private func host(_ style: MarkdownPreviewStyle) -> (NSWindow, NSView) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MarkdownPreviewStyle.storageKey)
        addTeardownBlock { defaults.set(saved, forKey: MarkdownPreviewStyle.storageKey) }
        defaults.set(style.rawValue, forKey: MarkdownPreviewStyle.storageKey)
        let view = MarkdownPreviewView(
            text: "# Title\n\n- [ ] first\n- [x] second\n\nA paragraph of plain text to double-click.\n",
            path: "README.md", location: WorkspaceFileLocation(machine: nil, session: "s", workspaceID: "w", workspaceLabel: "w", root: "/private/tmp"), onOpenFile: { _ in },
            onToggleTask: { [unowned self] in toggles.append(($0, $1)) },
            onRevealLine: { [unowned self] in reveals.append($0) })
        let host = NSHostingView(rootView: view.frame(width: 700, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return (window, host)
    }

    /// The center of the blue pixels, in window coordinates: the checked box is the only element
    /// drawn in the tint, which is blue in both styles. Bitmaps carry the display's color profile,
    /// so the test looks for a hue rather than the exact color.
    private func checkedBox(in host: NSView) -> NSPoint? {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var sum = NSPoint.zero, count = 0.0
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y),
                      color.blueComponent > 0.5, color.blueComponent - color.redComponent > 0.25 else { continue }
                sum.x += CGFloat(x); sum.y += CGFloat(y); count += 1
            }
        }
        guard count > 20 else { return nil }
        // Bitmap rows run top-down; the window's y axis runs bottom-up.
        return NSPoint(x: sum.x / count / scale, y: host.bounds.height - sum.y / count / scale)
    }

    private func click(_ point: NSPoint, in window: NSWindow, clicks: Int = 1) {
        func event(_ type: NSEvent.EventType, _ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        for count in 1...clicks {
            // A control tracks the mouse after mouse-down until it reads the mouse-up from the queue;
            // views that don't track get it sent directly.
            let up = event(.leftMouseUp, count)
            NSApp.postEvent(up, atStart: false)
            // Through the app, as real clicks are, so local event monitors see it.
            NSApp.sendEvent(event(.leftMouseDown, count))
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                window.sendEvent(queued)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testClickingACheckboxTogglesItsLine() throws {
        // The checkbox is a SwiftUI button, whose action runs in SwiftUI's display updates; with
        // every display asleep, as on an idle Mac, those wait and the click never reaches it.
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "SwiftUI buttons need an awake display")
        for style in MarkdownPreviewStyle.allCases {
            toggles = []
            let (window, host) = host(style)
            guard let box = checkedBox(in: host) else { return XCTFail("No checked box drawn in \(style)") }
            click(box, in: window)
            XCTAssertEqual(toggles.map(\.line), [4], "\(style)")
            XCTAssertEqual(toggles.map(\.checked), [false], "\(style)")
        }
    }

    func testDoubleClickingABlockRevealsItsLine() {
        for style in MarkdownPreviewStyle.allCases {
            reveals = []
            let (window, host) = host(style)
            guard let box = checkedBox(in: host) else { return XCTFail("No checked box drawn in \(style)") }
            // The paragraph is the next block below the second task.
            let paragraph = NSPoint(x: box.x + 60, y: box.y - (style == .theme ? 30 : 42))
            click(paragraph, in: window, clicks: 2)
            XCTAssertEqual(reveals, [6], "\(style)")
            XCTAssertTrue(toggles.isEmpty, "\(style)")
        }
    }
}

/// Theme data: every name Herdr accepts resolves, and light/dark pairs are consistent.
final class WoolooThemeTests: XCTestCase {
    func testThemesAreComplete() {
        XCTAssertEqual(Set(WoolooTheme.all.map(\.id)).count, WoolooTheme.all.count, "Theme ids must be unique")
        for theme in WoolooTheme.all {
            XCTAssertEqual(theme.ansi.count, 16, theme.id)
            XCTAssertFalse(theme.highlighterName.isEmpty, theme.id)
        }
        XCTAssertNotNil(WoolooTheme.named(WoolooTheme.fallbackID))
    }

    func testAliasesResolveToThemes() {
        for alias in ["catppuccin-mocha", "latte", "light", "tokyonight", "tokyo-day", "tokyonight-day", "gruvbox-dark",
                      "onedark", "onelight", "solarized-dark", "lotus", "rosepine", "rosepine-dawn", "dawn", "  Catppuccin "] {
            XCTAssertNotNil(WoolooTheme.named(alias), alias)
        }
        XCTAssertNil(WoolooTheme.named("no-such-theme"))
    }

    /// Agent states and change kinds use Herdr's palette, and agent states look different
    /// from each other wherever the palette allows it.
    func testStatusColorsFollowThePalette() {
        for theme in WoolooTheme.all {
            let states = ["working", "blocked", "done", "idle"].map(theme.agentStatus)
            let palette = [theme.herdr.yellow, theme.herdr.red, theme.herdr.teal, theme.herdr.green]
            XCTAssertEqual(states, palette.map { WoolooTheme.color($0) }, theme.id)
            XCTAssertEqual(Set(palette).count, 4, "\(theme.id): agent states share a color")
            XCTAssertEqual(theme.agentStatus(nil), theme.muted, theme.id)
            XCTAssertEqual(theme.agentStatus("unknown"), theme.muted, theme.id)

            XCTAssertEqual(theme.vcs(.added), theme.success, theme.id)
            XCTAssertEqual(theme.vcs(.deleted), theme.error, theme.id)
            XCTAssertEqual(theme.vcs(.conflicted), theme.error, theme.id)
            XCTAssertEqual(theme.vcs(.untracked), theme.success, "\(theme.id): new files are green, like staged ones")
            XCTAssertEqual(theme.vcs(.modified), WoolooTheme.color(theme.herdr.yellow), theme.id)
            XCTAssertEqual(theme.vcs(.renamed), WoolooTheme.color(theme.herdr.blue), theme.id)
        }
    }

    /// The editor uses the terminal's colors, and its current-line highlight is visible even
    /// when Herdr's dim surface is the background itself.
    func testEditorThemeMatchesTheTerminal() {
        for theme in WoolooTheme.all {
            let editor = theme.editorTheme
            XCTAssertEqual(editor.background, theme.terminalBackground, theme.id)
            XCTAssertEqual(editor.text, theme.terminalForeground, theme.id)
            XCTAssertEqual(editor.keywords, WoolooTheme.nsColor(theme.herdr.mauve), theme.id)
            XCTAssertEqual(editor.comments, WoolooTheme.nsColor(theme.herdr.overlay0), theme.id)
            XCTAssertNotEqual(editor.lineHighlight.withAlphaComponent(1), editor.background, theme.id)
        }
    }

    func testLightAndDarkSiblingsPairUp() {
        for theme in WoolooTheme.all {
            guard let sibling = theme.sibling else { continue }
            XCTAssertNotEqual(sibling.isDark, theme.isDark, theme.id)
            XCTAssertEqual(sibling.sibling?.id, theme.id, theme.id)
        }
    }
}

/// `ThemeStore` follows `[theme]` in config.toml.
@MainActor
final class ThemeStoreTests: XCTestCase {
    private var directory: String!
    private var savedPath: String?

    override func setUpWithError() throws {
        directory = "/private/tmp/wooloo-tests/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        savedPath = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
        setenv("HERDR_CONFIG_PATH", directory + "/config.toml", 1)
    }

    override func tearDown() {
        if let savedPath { setenv("HERDR_CONFIG_PATH", savedPath, 1) } else { unsetenv("HERDR_CONFIG_PATH") }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func store(_ config: String) throws -> ThemeStore {
        try config.write(toFile: directory + "/config.toml", atomically: true, encoding: .utf8)
        return ThemeStore()
    }

    func testNamedThemeAndFallback() throws {
        XCTAssertEqual(try store("[theme]\nname = \"tokyonight\"\n").theme.id, "tokyo-night")
        XCTAssertEqual(try store("[theme]\nname = \"unknown\"\n").theme.id, WoolooTheme.fallbackID)
        XCTAssertEqual(try store("").theme.id, WoolooTheme.fallbackID)
    }

    func testAutoSwitchFollowsTheSystemAppearance() throws {
        let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let explicit = try store("[theme]\nname = \"gruvbox\"\nauto_switch = true\nlight_name = \"one-light\"\ndark_name = \"one-dark\"\n")
        XCTAssertEqual(explicit.theme.id, systemDark ? "one-dark" : "one-light")

        let sibling = try store("[theme]\nname = \"gruvbox\"\nauto_switch = true\n")
        XCTAssertEqual(sibling.theme.isDark, systemDark)
        XCTAssertTrue(["gruvbox", "gruvbox-light"].contains(sibling.theme.id))
    }
}

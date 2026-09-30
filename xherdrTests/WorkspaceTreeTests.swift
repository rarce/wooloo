import XCTest
@testable import xherdr

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
        ![logo](xherdr-space:///docs/guide/img/logo.png "Logo") and ![remote](https://example.com/a.png)
        ![spaced](xherdr-space:///docs/guide/my%20image.png)
        ```
        ![code](not/rewritten.png)
        ```
        ![escape](../../../secret.png)
        """)
    }
}

/// Theme data: every name Herdr accepts resolves, and light/dark pairs are consistent.
final class XherdrThemeTests: XCTestCase {
    func testThemesAreComplete() {
        XCTAssertEqual(Set(XherdrTheme.all.map(\.id)).count, XherdrTheme.all.count, "Theme ids must be unique")
        for theme in XherdrTheme.all {
            XCTAssertEqual(theme.ansi.count, 16, theme.id)
            XCTAssertFalse(theme.highlighterName.isEmpty, theme.id)
        }
        XCTAssertNotNil(XherdrTheme.named(XherdrTheme.fallbackID))
    }

    func testAliasesResolveToThemes() {
        for alias in ["catppuccin-mocha", "latte", "light", "tokyonight", "tokyo-day", "tokyonight-day", "gruvbox-dark",
                      "onedark", "onelight", "solarized-dark", "lotus", "rosepine", "rosepine-dawn", "dawn", "  Catppuccin "] {
            XCTAssertNotNil(XherdrTheme.named(alias), alias)
        }
        XCTAssertNil(XherdrTheme.named("no-such-theme"))
    }

    /// Agent states and change kinds use Herdr's palette, and agent states look different
    /// from each other wherever the palette allows it.
    func testStatusColorsFollowThePalette() {
        for theme in XherdrTheme.all {
            let states = ["working", "blocked", "done", "idle"].map(theme.agentStatus)
            XCTAssertEqual(states, [theme.herdr.yellow, theme.herdr.red, theme.herdr.blue, theme.herdr.green].map { XherdrTheme.color($0) }, theme.id)
            // Herdr's Rosé Pine palettes use pine for both green and blue, so done and idle
            // agents look alike there, as they do in Herdr itself.
            let expected = theme.id.hasPrefix("rose-pine") ? 3 : 4
            XCTAssertEqual(Set([theme.herdr.yellow, theme.herdr.red, theme.herdr.blue, theme.herdr.green]).count, expected,
                           "\(theme.id): agent states share a color")
            XCTAssertEqual(theme.agentStatus(nil), theme.muted, theme.id)
            XCTAssertEqual(theme.agentStatus("unknown"), theme.muted, theme.id)

            XCTAssertEqual(theme.vcs(.added), theme.success, theme.id)
            XCTAssertEqual(theme.vcs(.deleted), theme.error, theme.id)
            XCTAssertEqual(theme.vcs(.conflicted), theme.error, theme.id)
            XCTAssertEqual(theme.vcs(.untracked), theme.success, "\(theme.id): new files are green, like staged ones")
            XCTAssertEqual(theme.vcs(.modified), XherdrTheme.color(theme.herdr.yellow), theme.id)
            XCTAssertEqual(theme.vcs(.renamed), XherdrTheme.color(theme.herdr.blue), theme.id)
        }
    }

    /// The editor uses the terminal's colors, and its current-line highlight is visible even
    /// when Herdr's dim surface is the background itself.
    func testEditorThemeMatchesTheTerminal() {
        for theme in XherdrTheme.all {
            let editor = theme.editorTheme
            XCTAssertEqual(editor.background, theme.terminalBackground, theme.id)
            XCTAssertEqual(editor.text, theme.terminalForeground, theme.id)
            XCTAssertEqual(editor.keywords, XherdrTheme.nsColor(theme.herdr.mauve), theme.id)
            XCTAssertEqual(editor.comments, XherdrTheme.nsColor(theme.herdr.overlay0), theme.id)
            XCTAssertNotEqual(editor.lineHighlight.withAlphaComponent(1), editor.background, theme.id)
        }
    }

    func testLightAndDarkSiblingsPairUp() {
        for theme in XherdrTheme.all {
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
        directory = "/private/tmp/xherdr-tests/\(UUID().uuidString)"
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
        XCTAssertEqual(try store("[theme]\nname = \"unknown\"\n").theme.id, XherdrTheme.fallbackID)
        XCTAssertEqual(try store("").theme.id, XherdrTheme.fallbackID)
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

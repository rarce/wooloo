import AppKit
import CodeEditTextView
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
    /// The view `render` is drawing, for `ready` conditions that look inside AppKit views.
    private var rendered: NSView?

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS\(version.majorVersion).\(version.minorVersion)"
    }

    /// Renders a view at a fixed size in the theme's appearance, as ContentView sets it, waiting
    /// until asynchronous loads settle: once `ready`, `settle` captures in a row, 0.1 s apart,
    /// must match the one before. A spinner drawn offscreen does not move, so views that show
    /// one while loading pass a `ready` that checks their model.
    private func render<Content: View>(_ content: Content, size: NSSize, settle: Int = 1,
                                       ready: () -> Bool = { true }) -> NSBitmapImageRep {
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
        rendered = host
        defer { window.close(); rendered = nil }

        func capture() -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        var previous = capture()
        var matches = 0
        for _ in 0..<60 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let next = capture()
            matches = ready() && next.tiffRepresentation == previous.tiffRepresentation ? matches + 1 : 0
            if matches >= settle { return next }
            previous = next
        }
        XCTAssertTrue(ready(), "The view did not finish loading")
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

    /// A repository with three dated commits, a few branches, a worktree and every kind of
    /// change, in a sandbox with a fixed path so the worktree paths shown do not change.
    private func snapshotRepository() throws -> (sandbox: WorkspaceGitSandbox, location: WorkspaceFileLocation) {
        let sandbox = try WorkspaceGitSandbox(name: "view-snapshots")
        try sandbox.sh("git init -q -b main repo")
        try sandbox.sh("git config user.name 'Ada Lovelace' && git config user.email ada@example.com", in: "repo")
        func commit(_ message: String, _ date: String) throws {
            try sandbox.sh("git add -A && GIT_AUTHOR_DATE='\(date)' GIT_COMMITTER_DATE='\(date)' git commit -q -m '\(message)'",
                           in: "repo")
        }
        try sandbox.write([
            ".gitignore": "build/\n",
            "README.md": "# Greeter\n",
            "Package.swift": "// swift-tools-version:5.9\n",
            "Sources/App/main.swift": "print(greet())\n",
            "Sources/App/Greeting.swift": "func greet() -> String { \"Hello\" }\n",
            "Sources/Core/Model.swift": "struct Model {}\n",
            "docs/guide.md": "# Guide\n",
            "docs/old-notes.md": "Notes\n",
        ], in: "repo")
        try commit("Initial", "2024-03-01T09:00:00+0000")
        try sandbox.write(["Tests/AppTests/GreetingTests.swift": "import XCTest\n"], in: "repo")
        try commit("Add greeting tests", "2024-03-12T14:30:00+0000")
        try sandbox.write([
            "Sources/App/Greeting.swift": "func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}\n",
            "Sources/App/main.swift": "print(greet(\"world\"))\n",
            "Sources/Core/Person.swift": "struct Person {\n    let name: String\n}\n",
        ], in: "repo")
        try sandbox.sh("rm docs/old-notes.md", in: "repo")
        try commit("Greet people by name", "2024-03-14T16:45:00+0000")
        try sandbox.sh("""
            git branch feature/search HEAD~1
            git branch fix-typo
            git update-ref refs/remotes/origin/main HEAD~1
            git worktree add -q ../repo-docs fix-typo
            """, in: "repo")
        // One staged change, one staged new file, one unstaged change, one untracked and one ignored file.
        try sandbox.write([
            "README.md": "# Greeter\n\nGreets people.\n",
            "Sources/Core/Store.swift": "final class Store {}\n",
        ], in: "repo")
        try sandbox.sh("git add README.md Sources/Core/Store.swift", in: "repo")
        try sandbox.write([
            "Sources/App/Greeting.swift": "func greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\n",
            "docs/notes.md": "Ideas\n",
            "build/output.log": "ok\n",
        ], in: "repo")
        return (sandbox, sandbox.location("repo"))
    }

    /// Relative commit ages are measured from a fixed day, a day after the last commit.
    private func fixClock() -> () -> Void {
        let saved = WorkspaceCommit.now
        WorkspaceCommit.now = { Date(timeIntervalSince1970: 1_710_504_000) } // 2024-03-15 12:00 UTC
        return { WorkspaceCommit.now = saved }
    }

    /// The explorer's Files and Changes trees with a few folders open and a file selected, over
    /// staged, unstaged, untracked and ignored files. The repository panel is collapsed here.
    func testExplorer() throws {
        let (sandbox, repo) = try snapshotRepository()
        defer { sandbox.tearDown() }
        let defaults = UserDefaults.standard
        let savedCollapsed = defaults.object(forKey: "RepositoryCollapsed")
        defer { defaults.set(savedCollapsed, forKey: "RepositoryCollapsed") }
        defaults.set(true, forKey: "RepositoryCollapsed")
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "workspaces": [["workspace_id": "repo", "label": "repo"]],
            "tabs": [["tab_id": "repo:t1", "workspace_id": "repo", "label": "1"]],
            "panes": [["pane_id": "p1", "workspace_id": "repo", "tab_id": "repo:t1", "cwd": repo.root]],
            "agents": [], "layouts": [], "focused_pane_id": "p1",
        ] as [String: Any]))
        let location = try XCTUnwrap(WorkspaceFiles.location(snapshot: snapshot, workspaceID: "repo",
                                                             session: "test", machine: nil))

        for (name, changes, folders, selected) in [
            ("explorer-files", false, ["Sources", "Sources/App", "docs", "build"], "Sources/App/Greeting.swift"),
            ("explorer-changes", true, ["Sources", "Sources/App", "Sources/Core", "docs"], "Sources/App/Greeting.swift"),
        ] {
            let model = WorkspaceExplorerModel()
            model.showsChanges = changes
            let identity = model.treeIdentity(location)
            for folder in folders { model.tree.expand(folder, in: identity) }
            model.tree.selected = identity + "|" + selected
            let view = WorkspaceBrowserView(localSnapshot: snapshot, localWorkspaceID: "repo", localSession: "test",
                                            machine: nil, refreshVersion: 0,
                                            onOpenFile: { _, _, _ in }, onOpenDiff: { _, _, _ in }, onNewTab: { _ in },
                                            onNewSpace: { _, _ in }, onLocationChange: { _ in },
                                            onFindInFolder: { _, _ in }, onOpenWorktree: { _, _ in },
                                            onOpenCommitFile: { _, _, _ in }, model: model)
            // The Git bar under the tree loads its branch after the listing, out of the model's sight.
            try assertSnapshot(render(view, size: NSSize(width: 300, height: 600), settle: 5) {
                model.listing != nil && !model.isLoading
            }, named: name)
            XCTAssertNil(model.error)
        }
        try skipIfRecorded()
    }

    /// The repository panel's history, a commit's files, and its branches and worktrees.
    func testRepository() throws {
        let (sandbox, repo) = try snapshotRepository()
        defer { sandbox.tearDown() }
        let restoreClock = fixClock()
        defer { restoreClock() }
        let head = try XCTUnwrap(WorkspaceFiles.repository(at: repo).commits.first)
        XCTAssertEqual(head.subject, "Greet people by name")

        func snapshot(tab: Int = 0, commit: WorkspaceCommit? = nil, height: CGFloat = 340) -> NSBitmapImageRep {
            let model = WorkspaceRepositoryModel()
            let panel = WorkspaceRepositoryView(location: repo, refreshVersion: 0, isCollapsed: .constant(false),
                                                onChange: {}, onNewSpace: nil, onOpenCommitFile: { _, _, _ in },
                                                model: model, selectedTab: tab, selectedCommit: commit)
            return render(panel, size: NSSize(width: 300, height: height), settle: 2) {
                model.listing != nil && !model.isLoading && (commit == nil || model.commitFiles != nil)
            }
        }
        try assertSnapshot(snapshot(), named: "repository-history")
        try assertSnapshot(snapshot(commit: head), named: "repository-commit")
        try assertSnapshot(snapshot(tab: 1, height: 420), named: "repository-branches")
        try skipIfRecorded()
    }

    /// A committed repository with a few Swift sources and a README, at a fixed path, for the
    /// search results and the document editor.
    private func snapshotSources() throws -> (sandbox: WorkspaceGitSandbox, location: WorkspaceFileLocation) {
        let sandbox = try WorkspaceGitSandbox(name: "view-snapshots")
        let location = try sandbox.repository("repo", files: [
            "Sources/App/Greeter.swift": """
                import Foundation

                /// Greets people by name, politely or with some excitement.
                struct Greeter {
                    enum Tone: String, CaseIterable {
                        case polite, excited
                    }

                    let tone: Tone
                    var greetings = 0

                    init(tone: Tone = .polite) {
                        self.tone = tone
                    }

                    mutating func greet(_ name: String) -> String {
                        greetings += 1
                        switch tone {
                        case .polite: return "Hello, \\(name)."
                        case .excited: return "Hi \\(name)!" + String(repeating: "!", count: 2)
                        }
                    }

                    // Everyone in the list, one line each.
                    mutating func greetAll(_ names: [String]) -> [String] {
                        names.map { greet($0) }
                    }
                }

                """,
            "Sources/App/main.swift": """
                var greeter = Greeter(tone: .excited)
                for name in CommandLine.arguments.dropFirst() {
                    print(greeter.greet(name))
                }

                """,
            "Sources/Core/Person.swift": """
                struct Person: Hashable {
                    let name: String
                    var nickname: String?

                    var displayName: String { nickname ?? name }
                }

                """,
            "README.md": """
                # Greeter

                A tiny command line tool that **greets people** by name. See `Sources/App` for the code.

                ## Usage

                1. Build it with `swift build`.
                2. Run it with the names to greet:

                ```sh
                swift run greeter Ada Grace
                ```

                | Tone | Output |
                | --- | --- |
                | polite | Hello, Ada. |
                | excited | Hi Ada!!! |

                > Greetings are counted, so a greeter knows how many people it met.

                """,
        ])
        return (sandbox, location)
    }

    /// Project search results for a query in three files, and the same with the replace field.
    func testSearch() throws {
        let (sandbox, repo) = try snapshotSources()
        defer { sandbox.tearDown() }
        for (name, replace) in [("search-results", false), ("search-replace", true)] {
            let model = WorkspaceSearchModel()
            model.options.query = "name"
            model.showsReplace = replace
            model.replacement = replace ? "fullName" : ""
            model.setLocation(repo)
            let view = WorkspaceSearchView(model: model, onOpen: { _, _, _, _ in })
            try assertSnapshot(render(view, size: NSSize(width: 820, height: 480), settle: 2) {
                model.result != nil && !model.isSearching
            }, named: name)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.matches.count, 15)
        }
        try skipIfRecorded()
    }

    /// A loaded document as ContentView shows it, with its text already read.
    private func loadedDocument(_ path: String, at location: WorkspaceFileLocation) throws -> Binding<WorkspaceDocument> {
        let contents = try WorkspaceFiles.read(path, at: location)
        var document = WorkspaceDocument(location: location, path: path, kind: .file)
        document.text = contents.text
        document.savedText = contents.text
        document.version = contents.version
        document.isLoading = false
        return Binding(get: { document }, set: { document = $0 })
    }

    /// The editor's text view once tree-sitter has colored it: its text has several colors.
    /// Its caret, the system insertion indicator, fades in and out on its own even offscreen,
    /// so it is hidden.
    private func highlightedEditor() -> TextView? {
        func find(_ view: NSView) -> TextView? {
            if let textView = view as? TextView { return textView }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let host = rendered, let textView = find(host) else { return nil }
        for case let caret as NSTextInsertionIndicator in textView.subviews { caret.displayMode = .hidden }
        let storage = textView.textStorage!
        var colors = Set<NSColor>()
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        return colors.count >= 4 ? textView : nil
    }

    /// A Swift file in the editor, highlighted, then with the find bar open on a query.
    func testDocumentEditor() throws {
        let (sandbox, repo) = try snapshotSources()
        defer { sandbox.tearDown() }
        let size = NSSize(width: 820, height: 560)
        let path = "Sources/App/Greeter.swift"

        let plain = WorkspaceDocumentView(document: try loadedDocument(path, at: repo), onSave: {})
        try assertSnapshot(render(plain, size: size, settle: 3) { highlightedEditor() != nil },
                           named: "editor-swift")

        // The find bar is opened once the view is up, as ⌘F does, so it searches the loaded text.
        let find = DocumentFindModel()
        find.options.query = "greet"
        let searching = WorkspaceDocumentView(document: try loadedDocument(path, at: repo), onSave: {}, find: find)
        DispatchQueue.main.async { find.open(replace: false, query: nil) }
        try assertSnapshot(render(searching, size: size, settle: 3) {
            guard let textView = highlightedEditor(), find.current == 0 else { return false }
            let layers = textView.layer?.sublayers?.filter { $0.cornerRadius == 2 && $0.backgroundColor != nil }
            return layers?.count == find.count
        }, named: "editor-find")
        XCTAssertEqual(find.count, 7)
        try skipIfRecorded()
    }

    /// A README in the document's rendered Markdown preview.
    func testMarkdownPreview() throws {
        let (sandbox, repo) = try snapshotSources()
        defer { sandbox.tearDown() }
        let view = WorkspaceDocumentView(document: try loadedDocument("README.md", at: repo), onSave: {})
        try assertSnapshot(render(view, size: NSSize(width: 820, height: 560), settle: 3), named: "markdown-preview")
        try skipIfRecorded()
    }
}

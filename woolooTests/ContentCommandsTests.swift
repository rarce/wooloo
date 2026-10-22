import XCTest
@testable import wooloo

/// Shortcuts, menu commands and the window's rename, close and search decisions, against a fake
/// Herdr server and documents in a disposable repository.
@MainActor
final class ContentCommandsTests: XCTestCase {
    /// The server's state; the responder reads it on the server's threads.
    private final class State {
        let lock = NSLock()
        var tabs: [[String: Any]] = [["tab_id": "w1:t1", "workspace_id": "w1", "label": "one"],
                                     ["tab_id": "w1:t2", "workspace_id": "w1", "label": "two"],
                                     ["tab_id": "w1:t3", "workspace_id": "w1", "label": "three"]]
        /// The pane's directory `pane.get` answers, after a `cd` the snapshot has not seen.
        var paneDirectory = "/tmp/project"

        func update(_ change: (State) -> Void) {
            lock.withLock { change(self) }
        }

        func snapshot() -> [String: Any] {
            ["result": ["snapshot": [
                "workspaces": [["workspace_id": "w1", "label": "project", "active_tab_id": "w1:t1"]],
                "tabs": tabs,
                "panes": [["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "cwd": "/tmp/project"],
                          ["pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "w1:t2"],
                          ["pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "w1:t3"]],
                "agents": [], "layouts": [],
                "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1"
            ] as [String: Any]]]
        }
    }

    func testSessionPickerFromRemoteUsesTheLastLocalSession() {
        let previousSSH = WorkspaceFiles.sshExecutable
        let previousSession = UserDefaults.standard.string(forKey: "HerdrLastSession")
        defer {
            WorkspaceFiles.sshExecutable = previousSSH
            UserDefaults.standard.set(previousSession, forKey: "HerdrLastSession")
        }
        WorkspaceFiles.sshExecutable = "/usr/bin/false"
        UserDefaults.standard.set("wooloo-ui-test", forKey: "HerdrLastSession")
        herdr.connect(to: HerdrMachineProfile(id: "remote", label: "Remote", target: "absent",
                                             session: "agents", enabled: true))
        commands.perform("switch_session")
        XCTAssertEqual(window.requestedSessionName, "wooloo-ui-test")
        XCTAssertEqual(herdr.sessionName, "agents")
        XCTAssertTrue(window.showsSessionPicker)
    }

    private let state = State()
    private var root: URL!
    private var savedRoot: URL!
    private var server: FakeHerdrServer!
    private var herdr: HerdrStore!
    private var sandbox: WorkspaceGitSandbox!
    private var repo: WorkspaceFileLocation!
    private var window: ContentWindowModel!
    private var documents: WorkspaceDocumentStore!
    private var search: WorkspaceSearchModel!
    private var copied: [String] = []
    private var revealed: [String] = []
    private var beeps = 0
    private var appConfigReloads = 0
    private var updateChecks = 0
    private var canCheckForUpdates = true
    private var fileResultsForgotten = 0
    private var lineWrappingToggles = 0

    override func setUp() async throws {
        // Short, so socket paths stay under the 104-byte limit.
        root = URL(fileURLWithPath: "/private/tmp/wooloo-tests/\(UUID().uuidString.prefix(8))")
        savedRoot = HerdrStore.sessionRoot
        HerdrStore.sessionRoot = root
        herdr = HerdrStore()
        server = try FakeHerdrServer(path: herdr.socketPath) { [state] method, _ in
            state.lock.lock()
            defer { state.lock.unlock() }
            switch method {
            case "session.snapshot": return state.snapshot()
            case "pane.read": return ["result": ["read": ["text": ""]]]
            case "pane.get":
                return ["result": ["pane": ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
                                            "cwd": state.paneDirectory]]]
            case "server.reload_config": return ["result": ["status": "applied"]]
            case "workspace.create": return ["result": ["workspace": ["workspace_id": "w1"]]]
            case "tab.create": return ["result": ["tab": ["tab_id": "w1:t1"]]]
            default: return ["result": [:]]
            }
        }
        sandbox = try WorkspaceGitSandbox()
        repo = try sandbox.repository("repo", files: ["a.txt": "one\n"])
        window = ContentWindowModel()
        documents = WorkspaceDocumentStore()
        search = WorkspaceSearchModel()
    }

    override func tearDown() async throws {
        herdr.stop()
        server.stop()
        HerdrStore.sessionRoot = savedRoot
        try? FileManager.default.removeItem(at: root)
        sandbox.tearDown()
    }

    private var commands: ContentCommands {
        ContentCommands(window: window, herdr: herdr, documents: documents, search: search,
                        explorerLocation: repo,
                        effects: ContentCommandEffects(
                            reloadAppConfig: { self.appConfigReloads += 1 },
                            forgetRecentFileResults: { self.fileResultsForgotten += 1 },
                            toggleLineWrapping: { self.lineWrappingToggles += 1 },
                            copy: { self.copied.append($0) },
                            reveal: { self.revealed.append($0) },
                            beep: { self.beeps += 1 },
                            canCheckForUpdates: { self.canCheckForUpdates },
                            checkForUpdates: { self.updateChecks += 1 }))
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
    }

    private func connect() async {
        herdr.start()
        await waitUntil("connected") { herdr.isConnected && herdr.selectedTabID == "w1:t1" }
    }

    private func requests(_ method: String) -> [FakeHerdrServer.Request] {
        server.requests.filter { $0.method == method }
    }

    /// Opens a.txt and, when `edited`, gives it unsaved edits.
    private func openDocument(edited: Bool = false) async throws -> String {
        documents.open(.file, path: "a.txt", at: repo)
        await waitUntil("loaded") { documents.documents.first?.isLoading == false }
        let id = try XCTUnwrap(documents.documents.first?.id)
        if edited { documents.documents[0].text = "edited\n" }
        return id
    }

    // MARK: Terminal links

    /// A Command-clicked path starts from the pane's directory now, opens inside the Space at its
    /// line, or on its own outside it; a folder shows in Finder, and a missing path beeps.
    func testTerminalPathsOpenInTheSpaceOrOnTheirOwn() async throws {
        await connect()
        try sandbox.write(["nested/c.txt": "c\n"], in: "repo")
        try sandbox.write(["b.txt": "b\n"], in: "other")
        state.update { $0.paneDirectory = repo.root + "/nested" }

        await commands.openTerminalFile(TerminalFileReference(path: "../a.txt", line: 1, column: 3), paneID: "w1:p1").value
        let inside = try XCTUnwrap(documents.documents.last)
        XCTAssertEqual(inside.location, repo)
        XCTAssertEqual(inside.path, "a.txt")
        XCTAssertEqual(inside.reveal?.line, 1)
        XCTAssertEqual(inside.reveal?.range, NSRange(location: 2, length: 0))

        await commands.openTerminalFile(TerminalFileReference(path: sandbox.path("other/b.txt")), paneID: "w1:p1").value
        let outside = try XCTUnwrap(documents.documents.last)
        XCTAssertEqual(outside.location.root, sandbox.path("other"))
        XCTAssertEqual(outside.location.workspaceID, repo.workspaceID)
        XCTAssertEqual(outside.path, "b.txt")
        XCTAssertEqual(documents.activeID, outside.id)

        await commands.openTerminalFile(TerminalFileReference(path: "."), paneID: "w1:p1").value
        XCTAssertEqual(revealed, [repo.root + "/nested"])
        await commands.openTerminalFile(TerminalFileReference(path: "missing.txt"), paneID: "w1:p1").value
        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(documents.documents.count, 2)
    }

    func testHoverUsesCurrentDirectoryWithoutANewSnapshotAndClickReusesIt() async throws {
        await connect()
        try sandbox.write(["sub/a.txt": "hello"], in: "repo")
        state.update { $0.paneDirectory = repo.root + "/sub" }
        let file = TerminalFileReference(path: "a.txt", line: 4)
        var answered = false
        XCTAssertNil(herdr.terminalFileLinks.exists(file, paneID: "w1:p1") { answered = true })
        for _ in 0..<200 where !answered { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(answered)
        XCTAssertEqual(herdr.terminalFileLinks.known(file, paneID: "w1:p1"), true)
        // A different server directory must not affect the already resolved click.
        state.update { $0.paneDirectory = "/missing" }
        var opening: Task<Void, Never>?
        XCTAssertTrue(herdr.terminalFileLinks.open(file, paneID: "w1:p1") { resolved in
            opening = self.commands.openTerminalFile(file, paneID: "w1:p1", resolved: resolved)
        })
        await opening?.value
        XCTAssertEqual(documents.documents.last?.path, "sub/a.txt")
        XCTAssertEqual(beeps, 0)
    }

    // MARK: Tabs

    func testPreviousAndNextTabWrapAroundTheSpace() async {
        await connect()
        documents.activeID = "doc"
        commands.perform("previous_tab")
        XCTAssertEqual(herdr.selectedTabID, "w1:t3", "Previous from the first tab wraps to the last")
        XCTAssertNil(documents.activeID, "Switching tabs shows the terminal")
        commands.perform("next_tab")
        XCTAssertEqual(herdr.selectedTabID, "w1:t1", "Next from the last tab wraps to the first")
        commands.perform("next_tab")
        XCTAssertEqual(herdr.selectedTabID, "w1:t2")
        commands.perform("previous_tab")
        XCTAssertEqual(herdr.selectedTabID, "w1:t1")
    }

    func testSwitchTabSelectsByPositionAndIgnoresMissingOnes() async {
        await connect()
        documents.activeID = "doc"
        commands.perform("switch_tab_9")
        XCTAssertEqual(herdr.selectedTabID, "w1:t1")
        XCTAssertEqual(documents.activeID, "doc", "An absent tab leaves the main panel alone")
        commands.perform("switch_tab_3")
        XCTAssertEqual(herdr.selectedTabID, "w1:t3")
        XCTAssertEqual(herdr.selectedPaneID, "w1:p3")
        XCTAssertNil(documents.activeID)
    }

    func testNewSpaceAndTabShowTheTerminalAndAskHerdr() async {
        await connect()
        documents.activeID = "doc"
        commands.perform("new_tab")
        XCTAssertNil(documents.activeID)
        documents.activeID = "doc"
        commands.perform("new_workspace")
        XCTAssertNil(documents.activeID)
        await waitUntil("created") { !requests("tab.create").isEmpty && !requests("workspace.create").isEmpty }
        XCTAssertEqual(requests("tab.create").first?.params["workspace_id"] as? String, "w1")
    }

    // MARK: Without a selection

    func testSelectionCommandsDoNothingBeforeASpaceIsSelected() {
        documents.activeID = "doc"
        for action in ["previous_tab", "next_tab", "switch_tab_1", "rename_workspace", "close_workspace",
                       "rename_tab", "close_tab", "close_pane", "copy_pane_cwd", "reveal_pane_cwd",
                       "not_a_command"] {
            commands.perform(action)
        }
        XCTAssertNil(window.renameTarget)
        XCTAssertEqual(window.renameText, "")
        XCTAssertNil(window.closeTarget)
        XCTAssertEqual(documents.activeID, "doc")
        XCTAssertEqual(copied + revealed, [])
    }

    // MARK: Rename and close

    func testRenameAndCloseAskAboutTheSelection() async {
        await connect()
        commands.perform("rename_workspace")
        XCTAssertEqual(window.renameTarget, .workspace("w1"))
        XCTAssertEqual(window.renameText, "project")
        commands.perform("rename_tab")
        XCTAssertEqual(window.renameTarget, .tab("w1:t1"))
        XCTAssertEqual(window.renameText, "one")
        commands.perform("close_workspace")
        XCTAssertEqual(window.closeTarget, .workspace("w1", "project"))
        commands.perform("close_tab")
        XCTAssertEqual(window.closeTarget, .tab("w1:t1", "one"))
        commands.perform("close_pane")
        XCTAssertEqual(window.closeTarget, .pane("w1:p1"))
        XCTAssertTrue(server.requests.allSatisfy { !$0.method.hasSuffix(".close") && !$0.method.hasSuffix(".rename") },
                      "Nothing changes before confirmation")
    }

    func testTheOnlyTabAsksToCloseItsSpaceAndCancellationKeepsTheSession() async {
        state.update { $0.tabs.removeLast(2) }
        await connect()
        commands.perform("close_tab")
        XCTAssertEqual(window.closeTarget, .lastTab("w1", "project"))
        documents.activeID = "doc"
        commands.cancelClose()
        XCTAssertNil(window.closeTarget)
        XCTAssertNil(documents.activeID)
        XCTAssertEqual(herdr.selectedTabID, "w1:t1")
        XCTAssertEqual(herdr.selectedPaneID, "w1:p1")
        XCTAssertTrue(server.requests.allSatisfy { !$0.method.hasSuffix(".close") && $0.method != "tab.create" },
                      "Keeping the Space must preserve the exact running session")
    }

    func testConfirmingLastTabClosesWorkspaceInsteadOfTab() async {
        state.update { $0.tabs.removeLast(2) }
        await connect()
        commands.perform("close_current_tab")
        XCTAssertEqual(window.closeTarget, .lastTab("w1", "project"))
        commands.commitClose()
        await waitUntil("space closed") { !requests("workspace.close").isEmpty }
        XCTAssertEqual(requests("workspace.close").first?.params["workspace_id"] as? String, "w1")
        XCTAssertTrue(requests("tab.close").isEmpty)
    }

    func testLastPaneAsksAboutSpaceButSplitPaneClosesOnlyPane() async {
        await connect()
        commands.requestClosePane("w1:p1")
        XCTAssertEqual(window.closeTarget, .pane("w1:p1"))
        let previous = try! XCTUnwrap(herdr.snapshot)
        herdr.receive(HerdrSnapshot(workspaces: previous.workspaces, tabs: [previous.tabs[0]],
                                    panes: [previous.panes[0]], agents: [], layouts: [],
                                    focusedWorkspaceID: "w1", focusedTabID: "w1:t1", focusedPaneID: "w1:p1"))
        commands.requestClosePane("w1:p1")
        XCTAssertEqual(window.closeTarget, .lastTab("w1", "project"))
    }

    func testCommitRenameTrimsTheNameAndSkipsEmptyOnes() async {
        await connect()
        window.renameTarget = .workspace("w1")
        window.renameText = "   "
        commands.commitRename()
        XCTAssertNil(window.renameTarget)
        window.renameTarget = .tab("w1:t2")
        window.renameText = "\n"
        commands.commitRename()
        window.renameTarget = .workspace("w1")
        window.renameText = "  renamed \n"
        commands.commitRename()
        XCTAssertNil(window.renameTarget)
        window.renameTarget = .tab("w1:t2")
        window.renameText = "two"
        commands.commitRename()
        await waitUntil("renamed") { !requests("workspace.rename").isEmpty && !requests("tab.rename").isEmpty }
        XCTAssertEqual(requests("workspace.rename").count, 1, "An empty name does not rename a Space")
        XCTAssertEqual(requests("workspace.rename").first?.params["label"] as? String, "renamed")
        XCTAssertEqual(requests("tab.rename").count, 1, "An empty name does not rename a tab")
        XCTAssertEqual(requests("tab.rename").first?.params["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(requests("tab.rename").first?.params["label"] as? String, "two",
                       "An unchanged name is still sent")
    }

    func testAnEmptyAgentNameRestoresTheDetectedName() async {
        await connect()
        window.renameTarget = .agent("w1:p1")
        window.renameText = " "
        commands.commitRename()
        window.renameTarget = .agent("w1:p2")
        window.renameText = " reviewer "
        commands.commitRename()
        XCTAssertNil(window.renameTarget)
        await waitUntil("renamed") { requests("agent.rename").count == 2 }
        let renames = requests("agent.rename").sorted { ($0.params["target"] as? String ?? "") < ($1.params["target"] as? String ?? "") }
        XCTAssertEqual(renames[0].params["target"] as? String, "w1:p1")
        XCTAssertTrue(renames[0].params["name"] is NSNull)
        XCTAssertEqual(renames[1].params["name"] as? String, "reviewer")
    }

    func testCommitRenameWithoutATargetDoesNothing() async {
        await connect()
        window.renameText = "name"
        commands.commitRename()
        commands.commitClose()
        window.closeTarget = .pane("w1:p2")
        commands.commitClose()
        await waitUntil("closed") { !requests("pane.close").isEmpty }
        XCTAssertTrue(server.requests.allSatisfy { !$0.method.hasSuffix(".rename") })
    }

    func testCommitCloseClosesTheTargetAndClearsIt() async {
        await connect()
        documents.activeID = "doc"
        window.closeTarget = .tab("w1:t2", "two")
        commands.commitClose()
        XCTAssertNil(window.closeTarget)
        XCTAssertEqual(documents.activeID, "doc")
        window.closeTarget = .pane("w1:p3")
        commands.commitClose()
        window.closeTarget = .workspace("w1", "project")
        commands.commitClose()
        XCTAssertNil(window.closeTarget)
        XCTAssertNil(documents.activeID, "Closing a Space shows the terminal")
        await waitUntil("closed") {
            !requests("tab.close").isEmpty && !requests("pane.close").isEmpty && !requests("workspace.close").isEmpty
        }
        XCTAssertEqual(requests("tab.close").first?.params["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(requests("pane.close").first?.params["pane_id"] as? String, "w1:p3")
        XCTAssertEqual(requests("workspace.close").first?.params["workspace_id"] as? String, "w1")
    }

    // MARK: Close current tab

    func testCloseCurrentTabClosesSearchThenDocumentsThenTheTerminalTab() async throws {
        await connect()
        let id = try await openDocument()
        commands.openSearch(replace: false)
        commands.perform("close_current_tab")
        XCTAssertFalse(window.showsSearchTab)
        XCTAssertNil(documents.activeID)
        XCTAssertEqual(documents.documents.count, 1, "Closing search keeps documents open")

        documents.activeID = id
        commands.perform("close_current_tab")
        XCTAssertTrue(documents.documents.isEmpty)
        XCTAssertNil(window.closeTarget)

        commands.perform("close_current_tab")
        XCTAssertEqual(window.closeTarget, .tab("w1:t1", "one"))
    }

    func testClosingAnEditedDocumentAsksFirst() async throws {
        let id = try await openDocument(edited: true)
        commands.perform("close_current_tab")
        XCTAssertEqual(window.pendingCloseDocumentID, id)
        XCTAssertEqual(documents.documents.count, 1)
        commands.closeDocument(id, force: true)
        XCTAssertTrue(documents.documents.isEmpty)
    }

    func testClosingSearchWhileADocumentIsShownKeepsTheDocument() async throws {
        let id = try await openDocument()
        commands.openSearch(replace: false)
        documents.activeID = id
        commands.closeSearch()
        XCTAssertFalse(window.showsSearchTab)
        XCTAssertEqual(documents.activeID, id)
    }

    func testImageTabsDisableTextEditingAndFindCommands() async throws {
        try ImageFixtures.data().write(to: URL(fileURLWithPath: repo.absolutePath("sample.png")))
        documents.open(.file, path: "sample.png", at: repo)
        for _ in 0..<300 where documents.documents.contains(where: \.isLoading) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(documents.documents.first?.image)
        let available = commands.availability
        XCTAssertTrue(available.hasReadOnlyDocument)
        for command in ["editor_save", "editor_find", "editor_find_next", "editor_find_previous", "editor_find_replace"] {
            XCTAssertFalse(try XCTUnwrap(WoolooCommandItem.named(command)).isAvailable(available), command)
        }
    }

    // MARK: Untitled files

    /// New Untitled File opens an empty tab at the explorer's location; saving it asks where,
    /// then refreshes the explorer and leaves the file's own tab.
    func testNewUntitledFileSavesWhereTheSheetSays() async throws {
        commands.perform("new_untitled_file")
        let id = try XCTUnwrap(documents.activeID)
        XCTAssertEqual(documents.document(id)?.title, "Untitled-1")
        XCTAssertEqual(documents.document(id)?.location.identity, repo.identity)
        XCTAssertTrue(commands.availability.hasFileDocument, "Editor commands apply to an untitled file")

        documents.documents[0].text = "hello\n"
        commands.saveDocument(id)
        XCTAssertEqual(window.saveAsDocumentID, id, "Saving an untitled file asks for a path")
        XCTAssertEqual(window.fileRefreshVersion, 0)

        let refused = await commands.saveUntitled(as: "a.txt")
        XCTAssertNotNil(refused)
        XCTAssertEqual(window.saveAsDocumentID, id, "The sheet stays open on an error")

        let error = await commands.saveUntitled(as: "hello.txt")
        XCTAssertNil(error)
        XCTAssertNil(window.saveAsDocumentID)
        XCTAssertEqual(window.fileRefreshVersion, 1)
        XCTAssertEqual(try sandbox.read("hello.txt", in: "repo"), "hello\n")
        XCTAssertEqual(documents.activeID.flatMap(documents.document)?.path, "hello.txt")
    }

    func testNewUntitledFileNeedsTheExplorersLocation() {
        let commands = ContentCommands(window: window, herdr: herdr, documents: documents, search: search)
        commands.perform("new_untitled_file")
        XCTAssertTrue(documents.documents.isEmpty)
        XCTAssertFalse(WoolooCommandItem.named("new_untitled_file")!.isAvailable(commands.availability))
    }

    // MARK: Search

    func testOpenSearchShowsTheSearchTabOnTheExplorersLocation() {
        commands.perform("project_search")
        XCTAssertTrue(window.showsSearchTab)
        XCTAssertFalse(search.showsReplace)
        XCTAssertEqual(documents.activeID, WorkspaceSearchModel.tabID)
        XCTAssertEqual(search.location?.identity, repo.identity)
        XCTAssertEqual(search.focusRequest, 1)

        commands.perform("project_replace")
        XCTAssertTrue(search.showsReplace)
        XCTAssertEqual(search.focusRequest, 2)
        commands.perform("project_search")
        XCTAssertTrue(search.showsReplace, "Find keeps the replace field once shown")
        XCTAssertEqual(search.focusRequest, 3)
    }

    func testSearchSeesUnsavedEditsAndReloadsReplacedFiles() async throws {
        _ = try await openDocument(edited: true)
        XCTAssertFalse(search.hasUnsavedEdits(repo, "a.txt"), "Hooks are installed when search opens")
        commands.openSearch(replace: true)
        XCTAssertTrue(search.hasUnsavedEdits(repo, "a.txt"))
        XCTAssertFalse(search.hasUnsavedEdits(repo, "b.txt"))
        search.didModifyFiles(repo, ["a.txt"])
        XCTAssertEqual(window.fileRefreshVersion, 1)
        XCTAssertEqual(documents.documents.first?.text, "edited\n", "Unsaved edits are not reloaded")
    }

    /// Overwrite, from the alert a save over a newer file shows, writes through the store and
    /// refreshes the explorer.
    func testOverwritingANewerFileSavesTheBufferAndRefreshes() async throws {
        let id = try await openDocument(edited: true)
        try sandbox.write(["a.txt": "theirs\n"], in: "repo")
        commands.saveDocument(id)
        await waitUntil("asks") { documents.documents.first?.asksToOverwrite == true }
        commands.overwriteDocument(id)
        await waitUntil("saved") { window.fileRefreshVersion == 1 }
        XCTAssertEqual(try sandbox.read("a.txt", in: "repo"), "edited\n")
        XCTAssertEqual(documents.documents.first?.asksToOverwrite, false)
    }

    // MARK: Window and effects

    func testWindowCommandsChangeTheWindowsState() async {
        await connect()
        commands.perform("help")
        XCTAssertTrue(window.showsSettings)
        XCTAssertTrue(window.settingsShowShortcuts)
        window.showsSettings = false
        commands.perform("settings")
        XCTAssertTrue(window.showsSettings)
        XCTAssertFalse(window.settingsShowShortcuts)
        window.showsSettings = false
        commands.perform("remote_access")
        XCTAssertTrue(window.showsSettings)
        XCTAssertTrue(window.settingsShowRemoteAccess)
        XCTAssertFalse(window.settingsShowShortcuts)

        commands.perform("toggle_sidebar")
        XCTAssertFalse(window.showsSidebar)
        commands.perform("toggle_files_sidebar")
        XCTAssertFalse(window.showsFilesSidebar)
        commands.perform("toggle_files_sidebar")
        XCTAssertTrue(window.showsFilesSidebar)

        commands.perform("switch_session")
        XCTAssertTrue(window.showsSidebar, "The session picker lives in the sidebar")
        XCTAssertTrue(window.showsSessionPicker)
        XCTAssertEqual(window.requestedSessionName, herdr.sessionName)

        commands.perform("refresh_files")
        XCTAssertEqual(fileResultsForgotten, 1)
        XCTAssertEqual(window.fileRefreshVersion, 1)
    }

    func testWrapLinesTurnsTheAppWideSettingOverWithOrWithoutADocument() throws {
        XCTAssertTrue(WoolooCommandItem.named("toggle_wrap_lines")?.isAvailable(commands.availability) == true)
        commands.perform("toggle_wrap_lines")
        XCTAssertEqual(lineWrappingToggles, 1)

        let suite = "ContentCommandsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: EditorLineWrapping.storageKey), "off until turned on")
        EditorLineWrapping.toggle(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: EditorLineWrapping.storageKey))
        EditorLineWrapping.toggle(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: EditorLineWrapping.storageKey))
    }

    func testReloadConfigReloadsTheAppAndHerdr() async {
        await connect()
        commands.perform("reload_config")
        XCTAssertEqual(appConfigReloads, 1)
        await waitUntil("reloaded") { !requests("server.reload_config").isEmpty }
    }

    func testCheckForUpdatesFollowsTheUpdaterWithoutHerdr() {
        let item = WoolooCommandItem.named("check_for_updates")!
        XCTAssertTrue(item.isAvailable(commands.availability), "No Herdr connection is needed")
        commands.perform("check_for_updates")
        XCTAssertEqual(updateChecks, 1)

        // Debug builds, tests, and a check under way: the menu item is disabled, so the palette is too.
        canCheckForUpdates = false
        XCTAssertFalse(item.isAvailable(commands.availability))
        commands.perform("check_for_updates")
        XCTAssertEqual(updateChecks, 1)
    }

    func testPaneCommandsGoToTheSelectedPane() async {
        await connect()
        commands.perform("focus_pane_right")
        commands.perform("split_horizontal")
        commands.perform("zoom")
        await waitUntil("sent") {
            !requests("pane.focus_direction").isEmpty && !requests("pane.split").isEmpty && !requests("pane.zoom").isEmpty
        }
        XCTAssertEqual(requests("pane.focus_direction").first?.params["direction"] as? String, "right")
        XCTAssertEqual(requests("pane.split").first?.params["direction"] as? String, "down")
        XCTAssertEqual(requests("pane.zoom").first?.params["pane_id"] as? String, "w1:p1")
    }

    func testPaneDirectoryIsCopiedOrRevealedWhenKnown() async {
        await connect()
        commands.perform("copy_pane_cwd")
        commands.perform("reveal_pane_cwd")
        XCTAssertEqual(copied, ["/tmp/project"])
        XCTAssertEqual(revealed, ["/tmp/project"])
        commands.perform("switch_tab_2")
        commands.perform("copy_pane_cwd")
        XCTAssertEqual(copied, ["/tmp/project"], "A pane without a directory copies nothing")
    }
}

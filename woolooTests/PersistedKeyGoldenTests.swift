import XCTest
@testable import wooloo

/// Pins the formats of identifiers wooloo persists, so the backend-neutral model and the
/// herdr-core backend (docs/proposals/herdr-core-backend.md) cannot change them by accident.
/// A failure here means existing users would lose restored windows, document backups or
/// panel layouts. Change a golden value only together with a migration.
@MainActor
final class PersistedKeyGoldenTests: XCTestCase {
    private let machine = HerdrMachineProfile(id: "box-1", label: "Box", target: "dev@box.example:2222",
                                              session: "agents", enabled: true)
    private let remoteContext = "ssh:box-1|agents|target:af5b478ea0f82ad4e0d63d3cf518cbb6"

    func testRemoteContextIDFormat() {
        XCTAssertEqual(machine.contextID(session: "agents"), remoteContext)
    }

    func testLocalStoreContextIDIsTheSessionName() {
        let store = HerdrStore()
        XCTAssertNil(store.machine)
        XCTAssertEqual(store.contextID, store.sessionName)
        XCTAssertEqual(store.legacyContextID, store.sessionName)
    }

    func testFileLocationIdentityFormat() {
        let local = WorkspaceFileLocation(machine: nil, session: "agents", workspaceID: "w1",
                                          workspaceLabel: "repo", root: "/src/repo")
        XCTAssertEqual(local.identity, "local|agents|w1|/src/repo")
        let remote = WorkspaceFileLocation(machine: machine, session: "agents", workspaceID: "w1",
                                           workspaceLabel: "repo", root: "/srv/repo")
        XCTAssertEqual(remote.identity, "\(remoteContext)|w1|/srv/repo")
    }

    func testWindowConnectionIDs() {
        XCTAssertEqual(HerdrWindowConnection(session: "agents").id, "agents")
        XCTAssertEqual(HerdrWindowConnection(session: "agents", machine: machine).id, remoteContext)
    }

    /// A herdr-core connection keeps its own namespace; TUI connections keep theirs and omit the
    /// backend field when saved.
    func testCoreWindowConnectionsAreScopedAndSavedWithTheirBackend() throws {
        let core = HerdrWindowConnection(session: "agents", backend: .core)
        XCTAssertEqual(core.id, "core:agents")
        XCTAssertEqual(HerdrWindowConnection(session: "agents", backend: .tui).id, "agents")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(core), as: UTF8.self),
                       #"{"backend":"core","session":"agents","spaces":[]}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(HerdrWindowConnection(session: "agents")), as: UTF8.self),
                       #"{"session":"agents","spaces":[]}"#)
        let decoded = try JSONDecoder().decode(HerdrWindowConnection.self, from: Data(#"{"session":"agents","spaces":[]}"#.utf8))
        XCTAssertEqual(decoded.backendKind, .tui)
    }

    func testDocumentSessionKeys() {
        XCTAssertEqual(WorkspaceSessionPersistence.key(for: nil),
                       "2f23e841e448e200fd6a93f331ec1a6b945fb030f2314f7a07a8aa0ec89c4f36")
        XCTAssertEqual(WorkspaceSessionPersistence.key(for: "agents|w1"),
                       "023ec718aa9ec41ddadcf2f6e048d64bde5b9248601e940c1a7bf2a58bb8c333")
        XCTAssertEqual(WorkspaceSessionPersistence.key(for: "\(remoteContext)|w1"),
                       "53dd0f08ff45ba6d7fe32d3cae971231d19e8343738397db65c1d150a1205f8f")
        // The pre-target remote namespace that `restoreDestination` imports from.
        XCTAssertEqual(WorkspaceSessionPersistence.key(for: "ssh:box-1|agents|w1"),
                       "a7fbdf082f92fd1a41fdc6fcbb9261d268f7e2f19058486c8f22a4693c4b3539")
    }

    /// Saved by builds before the backend split; it must keep decoding unchanged.
    private let savedWindowState = """
    {"opened":[{"session":"agents","spaces":["agents|w1"]},\
    {"machine":{"enabled":true,"id":"box-1","label":"Box","session":"agents","target":"dev@box.example:2222"},\
    "session":"agents","spaces":["ssh:box-1|agents|target:af5b478ea0f82ad4e0d63d3cf518cbb6|w2"]}],\
    "retired":[],"root":"/Users/me/.config/herdr","selected":"agents","version":1}
    """

    func testSavedWindowStateDecodes() throws {
        let state = try JSONDecoder().decode(HerdrConnectionWindowState.self, from: Data(savedWindowState.utf8))
        XCTAssertEqual(state.version, 1)
        XCTAssertEqual(state.root, "/Users/me/.config/herdr")
        XCTAssertEqual(state.selected, "agents")
        XCTAssertEqual(state.opened, [
            HerdrWindowConnection(session: "agents", spaces: ["agents|w1"]),
            HerdrWindowConnection(session: "agents", machine: machine, spaces: ["\(remoteContext)|w2"]),
        ])
        XCTAssertTrue(state.retired.isEmpty)
    }

    func testWindowStateEncodesToTheSavedFormat() throws {
        let state = try JSONDecoder().decode(HerdrConnectionWindowState.self, from: Data(savedWindowState.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(state), as: UTF8.self), savedWindowState)
    }
}

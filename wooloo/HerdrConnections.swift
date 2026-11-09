import AppKit
import Combine
import Foundation

enum HerdrSessionName {
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name != "." && name != ".."
            && name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
}

struct HerdrLocalSession: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let running: Bool
    let connectionError: String?
    var id: String { name }
    var isVerifiedStopped: Bool { !running && connectionError == nil }
    var status: String { connectionError != nil ? "State not verified" : running ? "Server running" : "Server stopped" }
    enum CodingKeys: String, CodingKey {
        case name, running
        case connectionError = "connection_error"
    }
}

/// Positive window membership is independent of Herdr's saved/enabled profile catalog.
/// Retired entries remember editor namespaces, never a second host configuration database.
struct HerdrWindowConnection: Codable, Equatable, Identifiable {
    let session: String
    let machine: HerdrMachineProfile?
    var spaces: [String] = []
    var id: String { machine?.contextID(session: session) ?? session }
    var label: String { "\(machine?.label ?? "Local") · \(session)" }

    @MainActor
    init(_ store: HerdrStore) {
        session = store.sessionName
        machine = store.machine
        spaces = Array(Set((store.snapshot ?? store.cachedSnapshot)?.workspaces.map {
            "\(store.contextID)|\($0.workspaceID)"
        } ?? [] )).sorted()
        if let selected = store.selectedWorkspaceID {
            let key = "\(store.contextID)|\(selected)"
            if !spaces.contains(key) { spaces.append(key) }
        }
    }

    init(session: String, machine: HerdrMachineProfile? = nil, spaces: [String] = []) {
        self.session = session
        self.machine = machine
        self.spaces = spaces
    }
}

struct HerdrConnectionWindowState: Codable {
    var version = 1
    var root: String
    var opened: [HerdrWindowConnection]
    var retired: [HerdrWindowConnection]
    var selected: String?
}

/// Read-only discovery never prepares SSH servers or starts a stopped local session.
/// All windows observe one ordered catalog; failures keep the previous inventory.
@MainActor
final class HerdrConnectionCatalog: ObservableObject {
    static let shared = HerdrConnectionCatalog()
    @Published private(set) var machines: [HerdrMachineProfile] = []
    @Published private(set) var sessions: [HerdrLocalSession] = []
    @Published private(set) var machinesLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private var refreshTask: Task<Void, Never>?
    private var revision = UUID()
    @Published private(set) var generation = UUID()
    private var users = 0
    private var mutating = false
    private var poll: Task<Void, Never>?
    private let refreshesInventory: Bool

    init(machines: [HerdrMachineProfile] = [], sessions: [HerdrLocalSession] = [], refreshesInventory: Bool = true) {
        self.machines = machines
        self.sessions = sessions
        self.refreshesInventory = refreshesInventory
        machinesLoaded = !refreshesInventory
    }

    func acquire() {
        users += 1
        guard users == 1 else { return }
        refresh()
        // Re-read through Herdr rather than depending on its private catalog file format.
        // Also observes atomic replacements, and installed CLI/config selection changes.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                if NSApp.isActive && !busy { refresh() }
            }
        }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 {
            poll?.cancel()
            poll = nil
            refreshTask?.cancel()
            refreshTask = nil
            revision = UUID()
            busy = false
        }
    }

    func refresh() {
        guard refreshesInventory, !mutating else { return }
        refreshTask?.cancel()
        let request = UUID()
        revision = request
        busy = true
        refreshTask = Task {
            let result = await BlockingWork.run {
                Optional((Result { try WorkspaceFiles.machines(includeDisabled: true) },
                          Result { try WorkspaceFiles.localSessions() }))
            }
            guard !Task.isCancelled, revision == request else { return }
            busy = false
            var failures: [String] = []
            if let result {
                switch result.0 {
                case .success(let profiles): machines = profiles; machinesLoaded = true; generation = request
                case .failure(let failure): failures.append(failure.localizedDescription)
                }
                switch result.1 {
                case .success(let values): sessions = values
                case .failure(let failure): failures.append(failure.localizedDescription)
                }
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    func freshMachines() async -> [HerdrMachineProfile]? {
        let previous = generation
        refresh()
        await refreshTask?.value
        return generation != previous ? machines : nil
    }

    func manage(_ arguments: [String], expected: HerdrMachineProfile? = nil) async throws {
        guard !mutating else { throw WorkspaceFileError.message("Another profile change is still running.") }
        mutating = true
        // Invalidate any older read before the mutation; publish its authoritative result
        // immediately, without waiting for a sheet to close or the next poll.
        revision = UUID()
        refreshTask?.cancel()
        busy = true
        defer { busy = false; mutating = false }
        let result = await BlockingWork.run {
            Result {
                if let expected, !(try WorkspaceFiles.machines(includeDisabled: true)).contains(expected) {
                    throw WorkspaceFileError.message("The SSH profile changed. Refresh and confirm the updated profile.")
                }
                try WorkspaceFiles.manageMachine(arguments)
                return try WorkspaceFiles.machines(includeDisabled: true)
            }
        }
        machines = try result.get()
        machinesLoaded = true
        generation = UUID()
        error = nil
    }
}

import Foundation

/// SSH hosts wooloo keeps itself, for herdr-core connections, which need no Herdr TUI and so
/// no `herdr machine` catalog (docs/proposals/herdr-core-backend.md, §3). Saved in wooloo's
/// support folder, readable by this user only. TUI connections keep using Herdr's profiles.
enum WoolooHostProfiles {
    static let idPrefix = "wooloo-"
    static var fileURL: URL { HerdrRuntimePaths.supportRoot.appendingPathComponent("hosts.json") }

    static func isOwned(_ profile: HerdrMachineProfile) -> Bool { profile.id.hasPrefix(idPrefix) }

    static func load(at url: URL = fileURL) -> [HerdrMachineProfile] {
        guard let data = try? Data(contentsOf: url),
              let hosts = try? JSONDecoder().decode([HerdrMachineProfile].self, from: data) else { return [] }
        return hosts.filter(isOwned)
    }

    static func save(_ hosts: [HerdrMachineProfile], at url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Saves a host, or returns the saved one with the same target and session.
    @discardableResult
    static func add(target: String, label: String?, session: String, at url: URL = fileURL) throws -> HerdrMachineProfile {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = WorkspaceFiles.SSHEndpoint(target)
        guard !endpoint.destination.isEmpty, !endpoint.destination.hasPrefix("-"),
              !target.contains(where: \.isNewline) else {
            throw WorkspaceFileError.message("Use an SSH alias, user@host, or ssh://user@host:port.")
        }
        guard session.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw WorkspaceFileError.message("Use a session named with 1–64 letters, numbers, hyphens or underscores.")
        }
        var hosts = load(at: url)
        if let existing = hosts.first(where: { $0.target == target && $0.session == session }) { return existing }
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = HerdrMachineProfile(id: idPrefix + UUID().uuidString.lowercased(),
                                       label: name?.isEmpty == false ? name! : endpoint.destination,
                                       target: target, session: session, enabled: true)
        hosts.append(host)
        try save(hosts, at: url)
        return host
    }

    static func remove(id: String, at url: URL = fileURL) throws {
        try save(load(at: url).filter { $0.id != id }, at: url)
    }
}

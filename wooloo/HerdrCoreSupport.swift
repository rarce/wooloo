import Foundation

/// herdr-core connections, a preview behind a setting that is off by default
/// (docs/proposals/herdr-core-backend.md, Phase 3). wooloo uses a herdr-core the user installed,
/// or asked wooloo to install (decision D3), and never installs or starts one as a side effect
/// of looking for it.
enum HerdrCoreSupport {
    static let settingKey = "WoolooHerdrCoreConnections"

    /// Whether the Connections window offers herdr-core sessions.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Where `hc` is usually installed; an app started from Finder does not inherit the shell's PATH.
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = path + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.nix-profile/bin"]
        return directories.flatMap { ["\($0)/hc", "\($0)/herdr-core"] }
    }

    /// The first `hc` on this Mac. Only checks for the file: running anything here could start a core.
    static func locateLocal(fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// How to reach `session` on this Mac, or on `machine` over SSH.
    static func target(session: String, machine: HerdrMachineProfile?) throws -> CoreTarget {
        guard session.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw WorkspaceFileError.message("Use a herdr-core session named with 1–64 letters, numbers, hyphens or underscores.")
        }
        if let machine {
            let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
            guard !endpoint.destination.isEmpty, !endpoint.destination.hasPrefix("-") else {
                throw WorkspaceFileError.message("Invalid remote host")
            }
            return CoreTarget(executable: WorkspaceFiles.sshExecutable,
                              arguments: HerdrRemoteBridge.coreArguments(machine, session: session),
                              banner: CoreTarget.banner)
        }
        guard let hc = locateLocal() else {
            throw WorkspaceFileError.message("herdr-core (hc) is not installed on this Mac. Install it from herdr.dev/core, then connect again.")
        }
        return .local(hc: hc, session: session)
    }
}

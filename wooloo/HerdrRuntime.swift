import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum HerdrRuntimePaths {
    static let version = "0.9.3"
    static let completedKey = "HerdrSetupCompleted"
    static let executableKey = "HerdrSetupExecutable"
    static let managedSessionKey = "HerdrManagedSession"

    static var configRoot: URL {
        if let path = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("herdr")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")
    }

    static var supportRoot: URL {
        if let path = ProcessInfo.processInfo.environment["WOOLOO_RUNTIME_ROOT"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wooloo")
    }

    static var bundledExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/herdr")
    }

    static func installedExecutable(in root: URL) -> URL {
        root.appendingPathComponent("runtime/herdr/\(version)/herdr")
    }

    static var externalCandidates: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
         "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
    }

    static var executableCandidates: [String] {
        let chosen = UserDefaults.standard.string(forKey: executableKey).map { [$0] } ?? []
        return chosen + externalCandidates + [installedExecutable(in: supportRoot).path, bundledExecutable.path]
    }

    static func validateSession(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 64,
              name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw HerdrRuntimeError.message("Use 1–64 letters, numbers, hyphens, or underscores for the session name.")
        }
    }

    static func socket(in root: URL, session: String) -> String {
        let directory = session == "default" ? root : root.appendingPathComponent("sessions/\(session)")
        return directory.appendingPathComponent("herdr.sock").path
    }
}

enum HerdrRuntimeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// One actor serializes installation and launch across all windows. Socket and process work
/// never runs on the main actor. launchd owns the server after the app exits.
actor HerdrRuntimeService {
    typealias Launcher = @Sendable (URL, String, [String: String], URL, URL) throws -> Void
    let supportRoot: URL
    let configRoot: URL
    let bundledExecutable: URL
    private let environment: [String: String]
    private let launcher: Launcher

    init(supportRoot: URL = HerdrRuntimePaths.supportRoot,
         configRoot: URL = HerdrRuntimePaths.configRoot,
         bundledExecutable: URL = HerdrRuntimePaths.bundledExecutable,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         launcher: @escaping Launcher = { try HerdrRuntimeService.launchServer(executable: $0, session: $1,
                                                                              environment: $2, configRoot: $3, supportRoot: $4) }) {
        self.supportRoot = supportRoot
        self.configRoot = configRoot
        self.bundledExecutable = bundledExecutable
        self.environment = environment
        self.launcher = launcher
    }

    func installBundledExecutable() throws -> URL {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: bundledExecutable.path) else {
            throw HerdrRuntimeError.message("This copy of wooloo is missing its bundled Herdr. Rebuild or reinstall wooloo.")
        }
        let source = try Data(contentsOf: bundledExecutable, options: .mappedIfSafe)
        let destination = HerdrRuntimePaths.installedExecutable(in: supportRoot)
        if let installed = try? Data(contentsOf: destination, options: .mappedIfSafe),
           SHA256.hash(data: installed) == SHA256.hash(data: source) {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return destination
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy through a temporary sibling, retaining the helper's embedded code signature.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: bundledExecutable, to: temporary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw HerdrRuntimeError.message("Could not install Herdr: \(String(cString: strerror(errno)))")
        }
        return destination
    }

    static func validateHealth(_ data: Data) throws {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], result["type"] as? String == "pong",
              let capabilities = result["capabilities"] as? [String: Any],
              capabilities["endpoint_protocol_generation"] as? Int == 1 else {
            throw HerdrRuntimeError.message("This Herdr server does not support wooloo's terminal endpoint. Update it and restart the session when its terminals can be stopped.")
        }
    }

    func ensureServer(executable: URL, session: String, folder: URL? = nil,
                      mayStart: Bool = true) async throws {
        try HerdrRuntimePaths.validateSession(session)
        let selectedFolder = try folder.map(Self.validateFolder)
        let path = HerdrRuntimePaths.socket(in: configRoot, session: session)
        if let health = try? HerdrSocket.request(path: path, method: "ping") {
            try Self.validateHealth(health)
        } else {
            guard mayStart else {
                throw HerdrRuntimeError.message("The selected session is not running. Start it with Herdr, or choose the included Herdr to create a session.")
            }
            // A reachable but unresponsive server may still own live terminals. Never replace it.
            if let fd = try? HerdrSocket.open(path: path) {
                close(fd)
                throw HerdrRuntimeError.message("Herdr is reachable but is not responding. Retry when the server is ready.")
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw HerdrRuntimeError.message("The Herdr executable is missing. Run setup again to repair it.")
            }
            try createInitialConfig()
            try launcher(executable, session, serverEnvironment(executable: executable), configRoot, supportRoot)
            let deadline = Date().addingTimeInterval(12)
            var nextLaunchCheck = Date().addingTimeInterval(1)
            var ready = false
            while Date() < deadline {
                try Task.checkCancellation()
                if let health = try? HerdrSocket.request(path: path, method: "ping") {
                    try Self.validateHealth(health)
                    ready = true
                    break
                }
                if Date() >= nextLaunchCheck {
                    // A previous job may have been exiting when setup began. Recheck without
                    // killing it, and bootstrap the current helper only once it has exited.
                    try launcher(executable, session, serverEnvironment(executable: executable), configRoot, supportRoot)
                    nextLaunchCheck = Date().addingTimeInterval(1)
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            guard ready else {
                throw HerdrRuntimeError.message("Herdr did not become ready. See \(supportRoot.appendingPathComponent("runtime/logs").path) for its startup log, then retry.")
            }
        }
        let snapshot = try HerdrSocket.snapshot(path: path)
        if snapshot.workspaces.isEmpty, let selectedFolder {
            _ = try HerdrSocket.createWorkspace(path: path, sourceWorkspaceID: nil,
                                               cwd: selectedFolder.path, label: selectedFolder.lastPathComponent)
            _ = try HerdrSocket.snapshot(path: path)
        }
    }

    static func validateFolder(_ folder: URL) throws -> URL {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard resolved.isFileURL, resolved.path.hasPrefix("/"), !resolved.path.contains("\0"),
              FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw HerdrRuntimeError.message("Choose an existing, readable folder for your first Space.")
        }
        return resolved
    }

    private func createInitialConfig() throws {
        let path = environment["HERDR_CONFIG_PATH"].map { URL(fileURLWithPath: $0) }
            ?? configRoot.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            if errno == EEXIST { return }
            throw HerdrRuntimeError.message("Could not create Herdr's configuration: \(String(cString: strerror(errno)))")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // The native wizard handles first-run setup; managed binaries update with wooloo.
        try file.write(contentsOf: Data("onboarding = false\n[update]\nversion_check = false\n".utf8))
        try file.close()
    }

    func serverEnvironment(executable: URL) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SSH_AUTH_SOCK",
                    "XDG_CONFIG_HOME", "XDG_STATE_HOME", "HERDR_CONFIG_PATH"] {
            if let value = environment[key] { result[key] = value }
        }
        let shell = environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/sh"
        result["SHELL"] = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/sh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [executable.deletingLastPathComponent().path, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                     environment["PATH"] ?? "", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        result["PATH"] = paths.filter { !$0.isEmpty }.joined(separator: ":")
        return result
    }

    static func launchServer(executable: URL, session: String, environment: [String: String],
                             configRoot: URL, supportRoot: URL) throws {
        let manager = FileManager.default
        let services = supportRoot.appendingPathComponent("runtime/services")
        let logs = supportRoot.appendingPathComponent("runtime/logs")
        try manager.createDirectory(at: services, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identity = SHA256.hash(data: Data((configRoot.path + "|" + session).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let label = "dev.wooloo.herdr.\(identity)"
        let domain = "gui/\(getuid())"
        let plist = services.appendingPathComponent(label + ".plist")
        let log = logs.appendingPathComponent(label + ".log").path
        let properties: [String: Any] = [
            "Label": label, "ProgramArguments": [executable.path, "--session", session, "server"],
            "EnvironmentVariables": environment, "RunAtLoad": true,
            "WorkingDirectory": manager.homeDirectoryForCurrentUser.path,
            "StandardOutPath": log, "StandardErrorPath": log, "Umask": 0o077
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let job = domain + "/" + label
        if let status = try? WorkspaceFiles.run("/bin/launchctl", ["print", job], limit: 64_000) {
            if String(decoding: status, as: UTF8.self).contains("state = running") {
                return // Another launch may still be becoming ready. Leave its processes alone.
            }
            // Unload only an exited job so the next start uses the current versioned helper.
            _ = try WorkspaceFiles.run("/bin/launchctl", ["bootout", job], limit: 16_000)
        }
        _ = try WorkspaceFiles.run("/bin/launchctl", ["bootstrap", domain, plist.path], limit: 16_000)
    }
}

@MainActor
final class HerdrRuntimeModel: ObservableObject {
    static let shared = HerdrRuntimeModel()
    @Published var showsSetup: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?
    @Published private(set) var connectedSession: String?
    @Published private(set) var isStartingServer = false
    @Published private(set) var serverStartError: String?
    private let defaults: UserDefaults
    private let service: HerdrRuntimeService
    private var startup: Task<Bool, Never>?

    init(defaults: UserDefaults = .standard, service: HerdrRuntimeService = HerdrRuntimeService()) {
        self.defaults = defaults
        self.service = service
        // Preserve the session of existing installations. Fresh installs get the wizard.
        showsSetup = !defaults.bool(forKey: HerdrRuntimePaths.completedKey)
            && (defaults.string(forKey: "HerdrLastSession") ?? "").isEmpty
    }

    var managedSessionName: String {
        defaults.string(forKey: HerdrRuntimePaths.managedSessionKey)
            ?? ProcessInfo.processInfo.environment["WOOLOO_SETUP_SESSION"] ?? "wooloo"
    }

    var canDismissSetup: Bool {
        defaults.bool(forKey: HerdrRuntimePaths.completedKey)
            || !(defaults.string(forKey: "HerdrLastSession") ?? "").isEmpty
    }

    func prepare(session: String) async -> Bool {
        guard !showsSetup else { return false }
        guard defaults.string(forKey: HerdrRuntimePaths.managedSessionKey) == session else { return true }
        if let startup { return await startup.value }
        let operation = Task { () -> Bool in
            isBusy = true
            progress = "Starting Herdr…"
            defer { isBusy = false; startup = nil }
            do {
                let executable = try await service.installBundledExecutable()
                try await service.ensureServer(executable: executable, session: session)
                defaults.set(executable.path, forKey: HerdrRuntimePaths.executableKey)
                error = nil
                return true
            } catch {
                self.error = error.localizedDescription
                showsSetup = true
                return false
            }
        }
        startup = operation
        return await operation.value
    }

    /// Starts a session whose server is not running, with the user's Herdr or else the included
    /// one. launchd keeps it running after wooloo quits; the store reconnects on its own.
    func startServer(session: String) async {
        guard !isBusy, !isStartingServer else { return }
        isStartingServer = true
        serverStartError = nil
        defer { isStartingServer = false }
        do {
            let bundled = HerdrRuntimePaths.bundledExecutable.path
            let executable: URL
            if let path = HerdrRuntimePaths.executableCandidates.first(where: {
                $0 != bundled && FileManager.default.isExecutableFile(atPath: $0)
            }) {
                executable = URL(fileURLWithPath: path)
            } else {
                executable = try await service.installBundledExecutable()
            }
            try await service.ensureServer(executable: executable, session: session)
        } catch {
            serverStartError = error.localizedDescription
        }
    }

    func clearServerStartError() {
        serverStartError = nil
    }

    func finish(useBundled: Bool, executable: URL?, session: String, folder: URL?) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        progress = useBundled ? "Preparing Herdr…" : "Checking your Herdr session…"
        defer { isBusy = false }
        do {
            try HerdrRuntimePaths.validateSession(session)
            let selected: URL
            if useBundled {
                guard let folder else { throw HerdrRuntimeError.message("Choose a folder for your first Space.") }
                _ = try HerdrRuntimeService.validateFolder(folder)
                selected = try await service.installBundledExecutable()
            } else {
                guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw HerdrRuntimeError.message("Choose your Herdr executable.")
                }
                selected = executable
                // Exercise the selected binary without starting or stopping any session.
                _ = try await BlockingWork.run {
                    try WorkspaceFiles.run(executable.path, ["api", "schema", "--json"], limit: 8_000_000)
                }
            }
            progress = "Connecting to Herdr…"
            try await service.ensureServer(executable: selected, session: session,
                                           folder: useBundled ? folder : nil, mayStart: useBundled)
            defaults.set(selected.path, forKey: HerdrRuntimePaths.executableKey)
            defaults.set(useBundled ? session : nil, forKey: HerdrRuntimePaths.managedSessionKey)
            defaults.set(session, forKey: "HerdrLastSession")
            defaults.set(true, forKey: HerdrRuntimePaths.completedKey)
            connectedSession = session
            showsSetup = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

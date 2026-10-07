import Foundation
import XCTest
@testable import wooloo

/// Disposable directories and Git repositories under /private/tmp for tests that run real git.
/// Git reads no global or system config while it exists, so the user's signing, hooks or diff
/// settings cannot change the results.
final class WorkspaceGitSandbox {
    let base: String
    private let savedEnvironment: [String: String?]

    /// `name` is the sandbox folder; a fixed one keeps paths shown in snapshots stable.
    init(name: String = UUID().uuidString) throws {
        base = "/private/tmp/wooloo-tests/\(name)"
        try? FileManager.default.removeItem(atPath: base)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let isolated = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        savedEnvironment = isolated.keys.reduce(into: [:]) { $0.updateValue(ProcessInfo.processInfo.environment[$1], forKey: $1) }
        for (key, value) in isolated { setenv(key, value, 1) }
        WorkspaceFiles.forgetRecentResults()
    }

    func tearDown() {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(atPath: base)
    }

    func path(_ name: String) -> String { base + "/" + name }

    func location(_ name: String) -> WorkspaceFileLocation {
        WorkspaceFileLocation(machine: nil, session: "test", workspaceID: name, workspaceLabel: name, root: path(name))
    }

    /// Runs a shell script in `name` (the sandbox itself when nil) and returns its output.
    @discardableResult
    func sh(_ script: String, in name: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -e\n" + script]
        process.currentDirectoryURL = URL(fileURLWithPath: name.map(path) ?? base)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw WorkspaceFileError.message("Script failed (\(process.terminationStatus)): \(text)")
        }
        // Changes made here bypass WorkspaceFiles, so shared loads must not hide them.
        WorkspaceFiles.forgetRecentResults()
        return text
    }

    /// Creates a repository on branch `main` with the given files committed as "Initial".
    @discardableResult
    func repository(_ name: String, files: [String: String] = ["a.txt": "one\n"]) throws -> WorkspaceFileLocation {
        try sh("git init -q -b main \(WorkspaceFiles.quote(name))")
        try configure(name)
        try write(files, in: name)
        try sh("git add -A && git commit -q -m Initial", in: name)
        return location(name)
    }

    func configure(_ name: String) throws {
        try sh("git config user.name 'Test Author' && git config user.email test@example.com", in: name)
    }

    func write(_ files: [String: String], in name: String) throws {
        for (file, contents) in files {
            let url = URL(fileURLWithPath: path(name)).appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    func read(_ file: String, in name: String) throws -> String {
        try String(contentsOfFile: path(name) + "/" + file, encoding: .utf8)
    }
}

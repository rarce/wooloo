import Foundation

enum HerdrConfigError: LocalizedError {
    case changedOnDisk
    case herdrUnavailable
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk: return "config.toml changed outside xherdr. Reload it before saving."
        case .herdrUnavailable: return "The Herdr executable was not found; configuration cannot be validated."
        case .validation(let message): return message
        }
    }
}

enum HerdrConfigFile {
    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/config.toml")
    }

    static func read(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func validate(_ text: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/herdr").path,
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw HerdrConfigError.herdrUnavailable
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("xherdr-config-\(UUID().uuidString).toml")
        try text.write(to: temporary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["config", "check"]
        var environment = ProcessInfo.processInfo.environment
        environment["HERDR_CONFIG_PATH"] = temporary.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrConfigError.validation(message?.isEmpty == false ? message! : "Herdr rejected config.toml")
        }
    }

    static func save(_ text: String, original: String, at url: URL) throws {
        guard try read(at: url) == original else { throw HerdrConfigError.changedOnDisk }
        try validate(text)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func reloadServer(socketPath: String) throws -> String {
        let data = try HerdrSocket.request(path: socketPath, method: "server.reload_config")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            throw HerdrConfigError.validation("Unexpected response from Herdr reload")
        }
        let diagnostics = result["diagnostics"] as? [String] ?? []
        let details = diagnostics.joined(separator: "\n")
        switch result["status"] as? String {
        case "applied": return "Saved and reloaded the selected Herdr session."
        case "partial": return "Saved; some settings need a restart. \(details)"
        case "failed": return "Saved, but Herdr could not apply the config. \(details)"
        default: throw HerdrConfigError.validation("Unexpected response from Herdr reload")
        }
    }
}

/// Edits one scalar in a TOML section while keeping unrelated tables and comments intact.
struct HerdrConfigDocument {
    var text: String

    func scalar(section: String, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(section, in: lines) else { return nil }
        guard let line = lines[range].first(where: { assignment($0, key: key) }) else { return nil }
        let raw = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        return valueWithoutComment(raw).trimmingCharacters(in: .whitespaces)
    }

    func string(section: String, key: String, default fallback: String) -> String {
        guard let raw = scalar(section: section, key: key), raw.hasPrefix("\"") else { return fallback }
        if let data = "[\(raw)]".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String],
           let value = decoded.first { return value }
        return fallback
    }

    func bool(section: String, key: String, default fallback: Bool) -> Bool {
        switch scalar(section: section, key: key) {
        case "true": return true
        case "false": return false
        default: return fallback
        }
    }

    func integer(section: String, key: String, default fallback: Int) -> Int {
        Int(scalar(section: section, key: key) ?? "") ?? fallback
    }

    mutating func setString(_ value: String, section: String, key: String) {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        let quoted = String(data: data, encoding: .utf8)!.dropFirst().dropLast()
        set(String(quoted), section: section, key: key)
    }

    mutating func setBool(_ value: Bool, section: String, key: String) {
        set(value ? "true" : "false", section: section, key: key)
    }

    mutating func setInteger(_ value: Int, section: String, key: String) {
        set(String(value), section: section, key: key)
    }

    private mutating func set(_ value: String, section: String, key: String) {
        var lines = text.components(separatedBy: "\n")
        if let range = sectionRange(section, in: lines) {
            if let index = range.first(where: { assignment(lines[$0], key: key) }) {
                let suffix = commentSuffix(lines[index].split(separator: "=", maxSplits: 1).last.map(String.init) ?? "")
                lines[index] = "\(key) = \(value)\(suffix)"
            } else {
                lines.insert("\(key) = \(value)", at: range.upperBound)
            }
        } else {
            let childIndex = lines.firstIndex {
                let header = $0.trimmingCharacters(in: .whitespaces)
                return header.hasPrefix("[\(section).") || header.hasPrefix("[[\(section).")
            }
            if let childIndex {
                lines.insert(contentsOf: ["[\(section)]", "\(key) = \(value)", ""], at: childIndex)
            } else {
                while lines.last == "" { lines.removeLast() }
                if !lines.isEmpty { lines.append("") }
                lines += ["[\(section)]", "\(key) = \(value)"]
            }
        }
        text = lines.joined(separator: "\n") + (lines.last == "" ? "" : "\n")
    }

    private func sectionRange(_ section: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }) else {
            return nil
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
        return (start + 1)..<end
    }

    private func assignment(_ line: String, key: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        return line[..<equals].trimmingCharacters(in: .whitespaces) == key
    }

    private func valueWithoutComment(_ value: String) -> String {
        var inString = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\" && inString && !escaped { escaped = true; continue }
            if character == "\"" && !escaped { inString.toggle() }
            if character == "#" && !inString { return String(value[..<index]) }
            escaped = false
        }
        return value
    }

    private func commentSuffix(_ value: String) -> String {
        let withoutValue = value.dropFirst(valueWithoutComment(value).count)
        return withoutValue.isEmpty ? "" : " " + withoutValue.trimmingCharacters(in: .whitespaces)
    }
}

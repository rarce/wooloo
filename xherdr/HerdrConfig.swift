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
        guard let executable = WorkspaceFiles.herdrCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
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

    /// Saves a validated config and asks the running session to reload it. Returns what to
    /// tell the user; a session that cannot reload does not undo the save.
    static func saveAndReload(_ text: String, original: String, at url: URL,
                              socketPath: String, session: String) throws -> String {
        try save(text, original: original, at: url)
        do {
            return try reloadServer(socketPath: socketPath)
        } catch {
            return "Saved config.toml, but \(session) could not reload: \(error.localizedDescription)"
        }
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

    func bindings(_ key: String, default fallback: [String]) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange("keys", in: lines),
              let index = range.first(where: { assignment(lines[$0], key: key) }) else { return fallback }
        let raw = lines[index].split(separator: "=", maxSplits: 1).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if raw.hasPrefix("[") {
            let end = arrayEnd(startingAt: index, in: lines) ?? index
            let value = ([raw] + (end > index ? Array(lines[(index + 1)...end]) : [])).joined(separator: "\n")
            return quotedStrings(in: value) ?? fallback
        }
        if raw.hasPrefix("'") {
            let literal = valueWithoutComment(raw).trimmingCharacters(in: .whitespaces)
            if literal.count >= 2, literal.hasSuffix("'") {
                return [String(literal.dropFirst().dropLast())]
            }
        }
        return [string(section: "keys", key: key, default: "")]
    }

    /// Writes a TOML basic string. JSON escapes are valid TOML except `\/`, which is turned off.
    mutating func setString(_ value: String, section: String, key: String) {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let quoted = String(data: data, encoding: .utf8)!.dropFirst().dropLast()
        set(String(quoted), section: section, key: key)
    }

    mutating func setBool(_ value: Bool, section: String, key: String) {
        set(value ? "true" : "false", section: section, key: key)
    }

    mutating func setInteger(_ value: Int, section: String, key: String) {
        set(String(value), section: section, key: key)
    }

    mutating func setBindings(_ values: [String], key: String) {
        let data = try! JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes)
        let array = String(data: data, encoding: .utf8)!
        if values.count == 1 {
            setString(values[0], section: "keys", key: key)
        } else {
            set(array, section: "keys", key: key)
        }
    }

    /// Removes `key` from `section`, including a multi-line array value.
    mutating func remove(section: String, key: String) {
        var lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(section, in: lines),
              let index = range.first(where: { assignment(lines[$0], key: key) }) else { return }
        let end = arrayEnd(startingAt: index, in: lines) ?? index
        lines.removeSubrange(index...end)
        text = lines.joined(separator: "\n")
    }

    private mutating func set(_ value: String, section: String, key: String) {
        var lines = text.components(separatedBy: "\n")
        if let range = sectionRange(section, in: lines) {
            if let index = range.first(where: { assignment(lines[$0], key: key) }) {
                let end = arrayEnd(startingAt: index, in: lines) ?? index
                let suffix = commentSuffix(lines[index].split(separator: "=", maxSplits: 1).last.map(String.init) ?? "")
                lines[index] = "\(key) = \(value)\(suffix)"
                if end > index { lines.removeSubrange((index + 1)...end) }
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
        guard let start = lines.firstIndex(where: {
            let header = $0.trimmingCharacters(in: .whitespaces)
            return header == "[\(section)]" || header.hasPrefix("[\(section)] #")
        }) else {
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

    private func arrayEnd(startingAt start: Int, in lines: [String]) -> Int? {
        guard let equals = lines[start].firstIndex(of: "=") else { return nil }
        let first = String(lines[start][lines[start].index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("[") else { return nil }
        var depth = 0
        var quote: Character?
        var escaped = false
        for index in start..<lines.count {
            let characters = index == start ? first : lines[index]
            for character in characters {
                if let current = quote {
                    if character == "\\" && current == "\"" && !escaped { escaped = true; continue }
                    if character == current && !escaped { quote = nil }
                    escaped = false
                    continue
                }
                if character == "#" { break }
                if character == "\"" || character == "'" { quote = character; continue }
                if character == "[" { depth += 1 }
                if character == "]" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
        }
        return nil
    }

    private func quotedStrings(in array: String) -> [String]? {
        var values: [String] = []
        var index = array.startIndex
        while index < array.endIndex {
            let character = array[index]
            if character == "#" {
                while index < array.endIndex, array[index] != "\n" {
                    index = array.index(after: index)
                }
                continue
            }
            guard character == "\"" || character == "'" else {
                index = array.index(after: index)
                continue
            }
            let quote = character
            let start = index
            index = array.index(after: index)
            var escaped = false
            while index < array.endIndex {
                let current = array[index]
                if current == "\\" && quote == "\"" && !escaped {
                    escaped = true
                    index = array.index(after: index)
                    continue
                }
                if current == quote && !escaped { break }
                escaped = false
                index = array.index(after: index)
            }
            guard index < array.endIndex else { return nil }
            let raw = String(array[start...index])
            if quote == "'" {
                values.append(String(raw.dropFirst().dropLast()))
            } else {
                guard let data = "[\(raw)]".data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String],
                      let value = decoded.first else { return nil }
                values.append(value)
            }
            index = array.index(after: index)
        }
        return values
    }
}

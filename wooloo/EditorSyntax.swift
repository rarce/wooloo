import Foundation
import CodeEditLanguages

/// Stable identifiers are shared by session overrides, file associations, editors and diffs.
struct EditorSyntax: Identifiable, Equatable {
    let id: String
    let name: String
    let language: CodeLanguage

    static let plainText = Self(id: "plaintext", name: "Plain Text", language: .default)
    static let ini = Self(id: "ini", name: "INI", language: .default)
    static let properties = Self(id: "properties", name: "Properties", language: .default)
    var isConfiguration: Bool { id == Self.ini.id || id == Self.properties.id }

    static let all: [Self] = {
        let names = ["bash": "Shell Script", "cpp": "C++", "cSharp": "C#", "goMod": "Go Modules",
                     "jsx": "JavaScript JSX", "tsx": "TypeScript TSX", "objc": "Objective-C",
                     "ocamlInterface": "OCaml Interface", "markdownInline": "Markdown Inline",
                     "jsdoc": "JSDoc", "json": "JSON", "css": "CSS", "html": "HTML", "php": "PHP",
                     "sql": "SQL", "toml": "TOML", "yaml": "YAML", "javascript": "JavaScript",
                     "typescript": "TypeScript", "ocaml": "OCaml"]
        // These catalog entries have parsers but no highlighting queries in our pinned package.
        let unavailable: Set<String> = ["agda", "julia", "perl", "verilog"]
        return ([plainText, ini, properties] + CodeLanguage.allLanguages.compactMap { language in
            let id = language.id.rawValue
            guard !unavailable.contains(id) else { return nil }
            return Self(id: id, name: names[id] ?? id.capitalized, language: language)
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func named(_ id: String?) -> Self? { all.first { $0.id == id } }

    static func resolve(path: String, text: String, override: String? = nil,
                        associations: [SyntaxAssociation] = []) -> Self {
        if let syntax = named(override) { return syntax }
        if let syntax = SyntaxAssociation.match(path, in: associations) { return syntax }
        if NotebookDocument.supports(path) { return named("json")! }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        if url.pathExtension.lowercased() == "ini" { return .ini }
        if ["conf", "cfg", "properties", "directory", "repo"].contains(url.pathExtension.lowercased())
            || [".gitconfig", ".gitmodules", ".editorconfig", "gitconfig"].contains(name)
            || [".git/config", ".config/git/config"].contains(path)
            || path.hasSuffix("/.git/config") || path.hasSuffix("/.config/git/config") {
            return .properties
        }
        let detected = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(512)),
                                                       suffixBuffer: String(text.suffix(512)))
        return named(detected.id.rawValue) ?? .plainText
    }
}

struct SyntaxAssociation: Codable, Equatable, Identifiable {
    static let storageKey = "EditorSyntaxAssociations"
    var pattern: String
    var syntaxID: String
    var id: String { pattern }

    static func decode(_ value: String) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: Data(value.utf8))) ?? []
    }

    static func encode(_ values: [Self]) -> String {
        (try? String(decoding: JSONEncoder().encode(values), as: UTF8.self)) ?? "[]"
    }

    /// More specific rules win; later entries break ties. Patterns with / match workspace-relative
    /// paths, others match filenames. Support *, ?, and ** (including zero directories for **/).
    static func match(_ path: String, in values: [Self]) -> EditorSyntax? {
        let matches = values.enumerated().filter { _, value in
            guard EditorSyntax.named(value.syntaxID) != nil, !value.pattern.isEmpty else { return false }
            let target = value.pattern.contains("/") ? path : (path as NSString).lastPathComponent
            return target.range(of: regex(value.pattern), options: .regularExpression) != nil
        }
        let best = matches.max { lhs, rhs in
            func specificity(_ pattern: String) -> Int { pattern.filter { $0 != "*" && $0 != "?" }.count }
            let a = specificity(lhs.element.pattern), b = specificity(rhs.element.pattern)
            return a == b ? lhs.offset < rhs.offset : a < b
        }
        return EditorSyntax.named(best?.element.syntaxID)
    }

    private static func regex(_ pattern: String) -> String {
        let characters = Array(pattern)
        var result = "^", index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        result += "(?:.*/)?"
                        index += 1
                    } else { result += ".*" }
                } else { result += "[^/]*" }
            } else if character == "?" { result += "[^/]" }
            else { result += NSRegularExpression.escapedPattern(for: String(character)) }
            index += 1
        }
        return result + "$"
    }
}

import Foundation
import CoreFoundation

/// A display projection. The document store keeps the original JSON for editing and saving.
struct NotebookDocument: Encodable, Sendable {
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumCells = 4_096
    static let maximumTextCharacters = 500_000
    static let maximumImageBytes = 16 * 1024 * 1024
    static let maximumImagePixels = 16_000_000

    let identity = UUID()
    private(set) var previewJSON = ""

    let cells: [Cell]
    let language: String
    let kernel: String?
    let warnings: [String]
    // Image data is served lazily by the resource handler, not copied into page scripts.
    let images: [String: Image]

    struct Cell: Encodable, Sendable {
        let id: String
        let kind: String
        let source: String
        let executionCount: Int?
        let outputs: [Output]
        let attachments: [String: [Representation]]
    }

    struct Output: Encodable, Sendable {
        let kind: String
        let text: String
        let executionCount: Int?
        let representations: [Representation]
    }

    struct Representation: Encodable, Sendable {
        let mime: String
        let text: String
        let imageID: String?
    }

    struct Image: Sendable {
        let base64: String
        let mime: String
    }

    enum CodingKeys: String, CodingKey { case cells, language, kernel, warnings }

    static func supports(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "ipynb"
    }

    enum ParseError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    static func parse(_ text: String) throws -> NotebookDocument {
        guard text.utf8.count <= maximumFileBytes else {
            throw ParseError.message("Notebook exceeds the 20 MiB preview limit. Open a smaller notebook.")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        catch { throw ParseError.message("Invalid notebook JSON. Correct it in Source view to preview it.") }
        guard let root = object as? [String: Any], let major = integer(root["nbformat"]),
              let minor = integer(root["nbformat_minor"]), minor >= 0,
              let rawCells = root["cells"] as? [[String: Any]], root["metadata"] is [String: Any] else {
            throw ParseError.message("Not a notebook: expected format versions, metadata, and a cells array.")
        }
        guard major == 4 else {
            throw ParseError.message("Notebook format \(major) is unsupported. Source view remains available.")
        }
        guard rawCells.count <= maximumCells else {
            throw ParseError.message("Notebook exceeds the \(maximumCells)-cell preview limit.")
        }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let languageInfo = metadata["language_info"] as? [String: Any] ?? [:]
        let kernelInfo = metadata["kernelspec"] as? [String: Any] ?? [:]
        let language = languageInfo["name"] as? String ?? kernelInfo["language"] as? String ?? "plaintext"
        var warnings: [String] = minor > 5 ? ["Newer notebook minor version \(minor): supported content is shown."] : []
        var images: [String: Image] = [:]
        var identifiers = Set<String>()
        var outputCount = 0

        func bounded(_ value: String) -> String {
            guard value.count > maximumTextCharacters else { return value }
            return String(value.prefix(maximumTextCharacters)) + "\n… Preview truncated; full data remains in Source view."
        }

        func representations(_ data: [String: Any]) -> [Representation] {
            data.keys.sorted().map { mime in
                let value = data[mime]!
                if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
                   let encoded = multiline(value), encoded.utf8.count <= maximumImageBytes * 4 / 3 + 4_096 {
                    let id = "image-\(images.count)"
                    images[id] = Image(base64: encoded, mime: mime)
                    return Representation(mime: mime, text: "", imageID: id)
                }
                let result: String
                if mime == "application/json" || mime.hasSuffix("+json") {
                    if let bytes = try? JSONSerialization.data(withJSONObject: value,
                                                              options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]),
                       let string = String(data: bytes, encoding: .utf8) { result = string }
                    else { result = "Invalid JSON output" }
                } else { result = multiline(value) ?? "Unsupported output encoding" }
                return Representation(mime: mime, text: bounded(result), imageID: nil)
            }
        }

        let cells = try rawCells.enumerated().map { index, raw -> Cell in
            guard let kind = raw["cell_type"] as? String, let source = multiline(raw["source"]),
                  raw["metadata"] is [String: Any] else {
                throw ParseError.message("Cell \(index + 1) has invalid type, metadata, or source. Correct it in Source view.")
            }
            let originalID = raw["id"] as? String
            let validID = originalID.flatMap { id in
                id.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil ? id : nil
            }
            let id: String
            if let validID, identifiers.insert(validID).inserted { id = validID }
            else {
                // Prefix is outside the schema's ID alphabet, so it cannot collide with a valid ID.
                id = "@cell-\(index)"
                if minor >= 5 { warnings.append("Cell \(index + 1) has a missing, invalid, or duplicate ID; a display ID was assigned.") }
            }
            if !["markdown", "code", "raw"].contains(kind) {
                warnings.append("Cell \(index + 1) has unsupported type \(kind); its source is shown.")
            }
            if source.count > maximumTextCharacters { warnings.append("Cell \(index + 1) source is truncated in the preview.") }
            let rawOutputs = raw["outputs"] as? [[String: Any]] ?? []
            if kind == "code", raw["outputs"] as? [[String: Any]] == nil {
                warnings.append("Cell \(index + 1) has invalid outputs; its source is shown.")
            }
            outputCount += rawOutputs.count
            guard outputCount <= 20_000 else { throw ParseError.message("Notebook exceeds the output count limit.") }
            let outputs = rawOutputs.map { output -> Output in
                let type = output["output_type"] as? String ?? "unknown"
                switch type {
                case "stream":
                    return Output(kind: output["name"] as? String == "stderr" ? "stderr" : "stdout",
                                  text: bounded(multiline(output["text"]) ?? "Invalid stream output"),
                                  executionCount: nil, representations: [])
                case "error":
                    let traceback = (output["traceback"] as? [String])?.joined(separator: "\n") ?? ""
                    let label = [output["ename"] as? String, output["evalue"] as? String].compactMap { $0 }.joined(separator: ": ")
                    return Output(kind: "error", text: bounded(traceback.isEmpty ? label : traceback),
                                  executionCount: nil, representations: [])
                case "display_data", "execute_result":
                    return Output(kind: type, text: "", executionCount: integer(output["execution_count"]),
                                  representations: representations(output["data"] as? [String: Any] ?? [:]))
                default:
                    return Output(kind: "unsupported", text: "Unsupported output type: \(type)",
                                  executionCount: nil, representations: [])
                }
            }
            var attachments: [String: [Representation]] = [:]
            for (name, data) in raw["attachments"] as? [String: Any] ?? [:] {
                if let bundle = data as? [String: Any] { attachments[name] = representations(bundle) }
            }
            return Cell(id: id, kind: kind, source: bounded(source), executionCount: integer(raw["execution_count"]),
                        outputs: outputs, attachments: attachments)
        }
        var document = NotebookDocument(cells: cells, language: String(language.prefix(100)),
                                        kernel: (kernelInfo["display_name"] as? String).map { String($0.prefix(200)) },
                                        warnings: Array(warnings.prefix(100)), images: images)
        document.previewJSON = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        return document
    }

    static func multiline(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let lines = value as? [String] { return lines.joined() }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
}

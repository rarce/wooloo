import Foundation

/// Two versions of a notebook compared cell by cell rather than as JSON: cells are matched by
/// their IDs, or where a cell has none by identical type and source, and the cells left between
/// two matches are paired in order when their types agree. Each cell lists what changed (source,
/// outputs, metadata, attachments, execution count, type) with line diffs of its source and of
/// a text summary of its outputs. Images are summarized by size and a checksum, so a changed
/// plot shows as changed without its base64 text.
struct NotebookDiff {
    enum Status: Equatable { case unchanged, added, removed, modified }

    enum Aspect: String, CaseIterable, Equatable {
        case kind = "type"
        case source
        case outputs
        case executionCount = "execution count"
        case metadata
        case attachments
    }

    struct Line: Equatable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        let text: String
    }

    struct Cell: Identifiable, Equatable {
        let id: Int
        let status: Status
        let kind: String
        /// Positions in the old and new notebook, from 0.
        let oldIndex: Int?
        let newIndex: Int?
        let aspects: [Aspect]
        let source: [Line]
        /// Empty unless the outputs changed.
        let outputs: [Line]
    }

    let cells: [Cell]
    /// Whether the notebook's own metadata or format version changed.
    let metadataChanged: Bool

    var changedCount: Int { cells.filter { $0.status != .unchanged }.count }

    /// Nil unless both sides are notebooks this can read; a missing side (a file added or
    /// deleted) counts as a notebook without cells. With `patch`, a side counts as missing only
    /// where the patch shows `/dev/null`: otherwise a nil side is one that could not be read
    /// (too large, not UTF-8, or a failed read), and the JSON patch is shown instead.
    static func compare(old: String?, new: String?, patch: String? = nil) -> NotebookDiff? {
        if let patch {
            let lines = patch.split(separator: "\n", maxSplits: 8).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            if old == nil, !lines.contains("--- /dev/null") { return nil }
            if new == nil, !lines.contains("+++ /dev/null") { return nil }
        }
        guard old != nil || new != nil,
              let before = Side(old), let after = Side(new) else { return nil }
        var cells: [Cell] = []
        func append(_ status: Status, _ old: Int?, _ new: Int?) {
            let left = old.map { before.cells[$0] }, right = new.map { after.cells[$0] }
            var aspects: [Aspect] = []
            if let left, let right {
                if left.kind != right.kind { aspects.append(.kind) }
                if left.source != right.source { aspects.append(.source) }
                if left.outputsKey != right.outputsKey { aspects.append(.outputs) }
                if left.executionCount != right.executionCount { aspects.append(.executionCount) }
                if left.metadata != right.metadata { aspects.append(.metadata) }
                if left.attachments != right.attachments { aspects.append(.attachments) }
            }
            let resolved: Status = status == .unchanged && !aspects.isEmpty ? .modified : status
            let source = lineDiff(left.map { lines($0.source) } ?? [], right.map { lines($0.source) } ?? [])
            let outputsChanged = aspects.contains(.outputs) || (left == nil) != (right == nil)
            let outputs = outputsChanged ? lineDiff(left?.outputs ?? [], right?.outputs ?? []) : []
            cells.append(Cell(id: cells.count, status: resolved, kind: (right ?? left)!.kind, oldIndex: old,
                              newIndex: new, aspects: aspects, source: source,
                              outputs: outputs.contains { $0.kind != .context } ? outputs : []))
        }

        let difference = after.cells.difference(from: before.cells) { $0.matches($1) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var oldIndex = 0, newIndex = 0
        while oldIndex < before.cells.count || newIndex < after.cells.count {
            var gapOld: [Int] = [], gapNew: [Int] = []
            while oldIndex < before.cells.count, removed.contains(oldIndex) { gapOld.append(oldIndex); oldIndex += 1 }
            while newIndex < after.cells.count, inserted.contains(newIndex) { gapNew.append(newIndex); newIndex += 1 }
            // Cells replaced in place are edits of one cell when their types agree: each old cell
            // pairs with the next new cell of its type, and new cells skipped over were added.
            var next = 0
            for old in gapOld {
                guard let match = gapNew[next...].firstIndex(where: { before.cells[old].kind == after.cells[$0].kind }) else {
                    append(.removed, old, nil)
                    continue
                }
                gapNew[next..<match].forEach { append(.added, nil, $0) }
                append(.modified, old, gapNew[match])
                next = match + 1
            }
            gapNew[next...].forEach { append(.added, nil, $0) }
            guard oldIndex < before.cells.count, newIndex < after.cells.count else {
                if gapOld.isEmpty && gapNew.isEmpty { break }
                continue
            }
            append(.unchanged, oldIndex, newIndex)
            oldIndex += 1; newIndex += 1
        }
        // An added or deleted notebook has no metadata of its own to compare.
        return NotebookDiff(cells: cells, metadataChanged: old != nil && new != nil && before.metadata != after.metadata)
    }

    /// One side's cells, reduced to what is compared.
    private struct Side {
        struct Summary {
            let id: String?
            let kind: String
            let source: String
            let executionCount: String
            let metadata: String
            let attachments: String
            /// The outputs as compared (canonical JSON) and as shown (text lines).
            let outputsKey: String
            let outputs: [String]

            func matches(_ other: Summary) -> Bool {
                if let id, let otherID = other.id { return id == otherID }
                return kind == other.kind && source == other.source
            }
        }

        let cells: [Summary]
        let metadata: String

        init?(_ text: String?) {
            guard let text else { cells = []; metadata = ""; return }
            guard text.utf8.count <= NotebookDocument.maximumFileBytes,
                  let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let rawCells = root["cells"] as? [[String: Any]], rawCells.count <= NotebookDocument.maximumCells else {
                return nil
            }
            metadata = canonical(["metadata": root["metadata"] ?? NSNull(), "nbformat": root["nbformat"] ?? NSNull(),
                                  "nbformat_minor": root["nbformat_minor"] ?? NSNull()])
            var seen = Set<String>()
            cells = rawCells.map { raw in
                // A duplicate ID cannot match one cell on the other side, so it matches by content.
                let id = (raw["id"] as? String).flatMap { seen.insert($0).inserted ? $0 : nil }
                let outputs = raw["outputs"] as? [Any] ?? []
                return Summary(id: id, kind: raw["cell_type"] as? String ?? "unknown",
                               source: NotebookDocument.multiline(raw["source"]) ?? "",
                               executionCount: canonical(raw["execution_count"] ?? NSNull()),
                               metadata: canonical(raw["metadata"] ?? [:]),
                               attachments: canonical(raw["attachments"] ?? [:]),
                               outputsKey: canonical(outputs),
                               outputs: outputs.flatMap { describe($0) })
            }
        }
    }

    // MARK: Text

    static let maximumOutputLines = 400
    static let maximumLineCharacters = 2_000

    private static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // Split on UTF-16 units: as a Character, "\r\n" is not "\n".
        var result = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.utf16.last == 0x0A { result.removeLast() }
        return result
    }

    /// An output as lines of text: its type, then its stream text, error or the representations
    /// it was saved in, with text shown and images reduced to their size and checksum.
    private static func describe(_ value: Any) -> [String] {
        guard let output = value as? [String: Any] else { return ["(invalid output)"] }
        let type = output["output_type"] as? String ?? "unknown"
        var result: [String]
        switch type {
        case "stream":
            result = ["[\(output["name"] as? String ?? "stream")]"] + lines(NotebookDocument.multiline(output["text"]) ?? "")
        case "error":
            result = ["[error] " + [output["ename"] as? String, output["evalue"] as? String].compactMap { $0 }.joined(separator: ": ")]
        case "display_data", "execute_result":
            let count = (output["execution_count"] as? NSNumber).map { " \($0)" } ?? ""
            result = ["[\(type)\(count)]"]
            let data = output["data"] as? [String: Any] ?? [:]
            for mime in data.keys.sorted() {
                let value = data[mime]!
                if mime.hasPrefix("image/"), mime != "image/svg+xml", let encoded = NotebookDocument.multiline(value) {
                    let bytes = encoded.filter { !$0.isWhitespace }.utf8.count * 3 / 4
                    result.append("\(mime): \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), checksum \(checksum(encoded))")
                } else if mime == "application/json" || mime.hasSuffix("+json") {
                    result.append("\(mime):")
                    result += lines(canonical(value))
                } else {
                    result.append("\(mime):")
                    result += lines(NotebookDocument.multiline(value) ?? canonical(value))
                }
            }
        default:
            result = ["[\(type)]"]
        }
        if result.count > maximumOutputLines {
            result = Array(result.prefix(maximumOutputLines)) + ["… \(result.count - maximumOutputLines) more lines"]
        }
        return result.map { $0.count > maximumLineCharacters ? String($0.prefix(maximumLineCharacters)) + "…" : $0 }
    }

    /// FNV-1a of the text, as eight hexadecimal digits.
    private static func checksum(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 where byte > 0x20 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// The lines of `new` against those of `old`, in order, as a unified diff shows them.
    static func lineDiff(_ old: [String], _ new: [String]) -> [Line] {
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var oldIndex = 0, newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            let start = (oldIndex, newIndex)
            while oldIndex < old.count, removed.contains(oldIndex) {
                result.append(Line(kind: .removed, text: old[oldIndex])); oldIndex += 1
            }
            while newIndex < new.count, inserted.contains(newIndex) {
                result.append(Line(kind: .added, text: new[newIndex])); newIndex += 1
            }
            guard oldIndex < old.count, newIndex < new.count else {
                if start == (oldIndex, newIndex) { break }
                continue
            }
            result.append(Line(kind: .context, text: new[newIndex]))
            oldIndex += 1; newIndex += 1
        }
        return result
    }
}

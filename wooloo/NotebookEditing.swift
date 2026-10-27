import Foundation

/// A structured change to one notebook cell, as the preview's cell toolbar asks for it. Cells
/// are counted from 0 in the order of the notebook's `cells` array.
enum NotebookEdit: Equatable {
    case setSource(cell: Int, text: String)
    case setKind(cell: Int, kind: String)
    case insert(at: Int, kind: String)
    case delete(cell: Int)
    /// Moves a cell one place up (-1) or down (+1).
    case move(cell: Int, offset: Int)

    static let kinds = ["code", "markdown", "raw"]

    /// The name Edit > Undo shows.
    var actionName: String {
        switch self {
        case .setSource: "Edit Cell"
        case .setKind: "Change Cell Type"
        case .insert: "Insert Cell"
        case .delete: "Delete Cell"
        case .move: "Move Cell"
        }
    }
}

/// Applies `NotebookEdit`s to a notebook's JSON as one replacement of the text they change, so
/// every other byte, including other cells, metadata, attachments, outputs and the file's own
/// formatting, stays as it was. New values are written in the file's indentation, or compactly
/// when the file is minified, with keys in the sorted order Jupyter writes.
enum NotebookEditing {
    struct Replacement: Equatable {
        /// UTF-16 range of the original text.
        let range: NSRange
        let text: String
    }

    enum Failure: LocalizedError, Equatable {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }

    /// The replacement that makes `edit`, or nil when it changes nothing. `makeID` names new
    /// cells in notebooks whose format (4.5 and later) gives cells an ID.
    static func replacement(for edit: NotebookEdit, in text: String,
                            makeID: () -> String = randomID) throws -> Replacement? {
        let units = Array(text.utf16)
        var parser = JSONScanner(units: units)
        let root = try parser.document(depth: 3)
        guard case .object(let rootMembers) = root.kind,
              let cellsMember = rootMembers.first(where: { $0.key == "cells" }),
              case .array(let cells) = cellsMember.value.kind else {
            throw Failure.message("Not a notebook: expected a cells array.")
        }
        let format = Format(units: units, root: root, cells: cellsMember)
        func cell(_ index: Int) throws -> JSONNode {
            guard cells.indices.contains(index) else { throw Failure.message("The notebook changed; try again.") }
            return cells[index]
        }

        switch edit {
        case .setSource(let index, let source):
            let cellNode = try cell(index)
            guard let member = cellNode.member("source") else {
                throw Failure.message("Cell \(index + 1) has no source.")
            }
            let indent = format.indent(atLineOf: member.keyRange.location)
            let value: String
            if case .string = member.value.kind { value = jsonString(source) }
            else { value = format.lines(source, indent: indent) }
            guard value != format.string(member.value.range) else { return nil }
            return Replacement(range: member.value.range, text: value)

        case .setKind(let index, let kind):
            guard NotebookEdit.kinds.contains(kind) else { throw Failure.message("Unknown cell type \(kind).") }
            let cellNode = try cell(index)
            guard let current = cellNode.member("cell_type") else {
                throw Failure.message("Cell \(index + 1) has no type.")
            }
            guard format.string(current.value.range) != jsonString(kind) else { return nil }
            var cellText = format.string(cellNode.range)
            var operations: [(inout String) throws -> Void] = [{ text in
                try Self.replaceValue(of: "cell_type", with: jsonString(kind), in: &text, format: format)
            }]
            if kind == "code" {
                if let attachments = cellNode.member("attachments") {
                    // Values this deep are scanned without their members, so check the text.
                    guard case .object = attachments.value.kind,
                          format.string(attachments.value.range).filter({ !$0.isWhitespace }) == "{}" else {
                        throw Failure.message("Code cells cannot keep attachments. Remove cell \(index + 1)'s attachments in Source view first.")
                    }
                    operations.append { try Self.removeMember("attachments", from: &$0, format: format) }
                }
                operations.append { try Self.addMember("execution_count", value: "null", to: &$0, format: format) }
                operations.append { try Self.addMember("outputs", value: "[]", to: &$0, format: format) }
            } else {
                operations.append { try Self.removeMember("execution_count", from: &$0, format: format) }
                operations.append { try Self.removeMember("outputs", from: &$0, format: format) }
            }
            for operation in operations { try operation(&cellText) }
            return Replacement(range: cellNode.range, text: cellText)

        case .insert(let index, let kind):
            guard NotebookEdit.kinds.contains(kind) else { throw Failure.message("Unknown cell type \(kind).") }
            guard (0...cells.count).contains(index) else { throw Failure.message("The notebook changed; try again.") }
            var id: String?
            if format.usesCellIDs {
                let used = Set(cells.compactMap { $0.member("id").map { format.string($0.value.range) } })
                repeat { id = makeID() } while used.contains(jsonString(id!))
            }
            let cellIndent = format.elementIndent
            let newCell = format.newCell(kind: kind, id: id, indent: cellIndent)
            if cells.isEmpty {
                let arrayRange = cellsMember.value.range
                let closing = format.indent(atLineOf: cellsMember.keyRange.location)
                let body = format.isCompact ? "[\(newCell)]" : "[\(format.newline)\(cellIndent)\(newCell)\(format.newline)\(closing)]"
                return Replacement(range: arrayRange, text: body)
            }
            let separator = format.elementSeparator
            if index < cells.count {
                return Replacement(range: NSRange(location: cells[index].range.location, length: 0),
                                   text: newCell + separator)
            }
            return Replacement(range: NSRange(location: NSMaxRange(cells[cells.count - 1].range), length: 0),
                               text: separator + newCell)

        case .delete(let index):
            _ = try cell(index)
            if cells.count == 1 { return Replacement(range: cellsMember.value.range, text: "[]") }
            if index < cells.count - 1 {
                return Replacement(range: NSRange(location: cells[index].range.location,
                                                  length: cells[index + 1].range.location - cells[index].range.location),
                                   text: "")
            }
            let start = NSMaxRange(cells[index - 1].range)
            return Replacement(range: NSRange(location: start, length: NSMaxRange(cells[index].range) - start), text: "")

        case .move(let index, let offset):
            _ = try cell(index)
            let other = index + offset
            guard offset == -1 || offset == 1 else { throw Failure.message("Cells move one place at a time.") }
            guard cells.indices.contains(other) else { return nil }
            let first = cells[min(index, other)], second = cells[max(index, other)]
            let between = format.string(NSRange(location: NSMaxRange(first.range),
                                                length: second.range.location - NSMaxRange(first.range)))
            let range = NSRange(location: first.range.location, length: NSMaxRange(second.range) - first.range.location)
            return Replacement(range: range, text: format.string(second.range) + between + format.string(first.range))
        }
    }

    /// An ID as Jupyter makes them: eight hexadecimal digits of a random UUID.
    static func randomID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    // MARK: Members of a cell

    private static func object(_ text: String) throws -> (units: [UInt16], members: [JSONMember]) {
        let units = Array(text.utf16)
        var parser = JSONScanner(units: units)
        guard case .object(let members) = try parser.document(depth: 1).kind else {
            throw Failure.message("A cell is not an object.")
        }
        return (units, members)
    }

    private static func replaceValue(of key: String, with value: String, in text: inout String, format: Format) throws {
        let (_, members) = try object(text)
        guard let member = members.first(where: { $0.key == key }) else { return }
        text = (text as NSString).replacingCharacters(in: member.value.range, with: value)
    }

    private static func removeMember(_ key: String, from text: inout String, format: Format) throws {
        let (_, members) = try object(text)
        guard let index = members.firstIndex(where: { $0.key == key }) else { return }
        let range: NSRange
        if index < members.count - 1 {
            range = NSRange(location: members[index].keyRange.location,
                            length: members[index + 1].keyRange.location - members[index].keyRange.location)
        } else if index > 0 {
            let start = NSMaxRange(members[index - 1].value.range)
            range = NSRange(location: start, length: NSMaxRange(members[index].value.range) - start)
        } else {
            range = NSRange(location: members[index].keyRange.location,
                            length: NSMaxRange(members[index].value.range) - members[index].keyRange.location)
        }
        text = (text as NSString).replacingCharacters(in: range, with: "")
    }

    /// Adds `"key": value` where Jupyter's sorted keys put it, unless the cell has the key.
    private static func addMember(_ key: String, value: String, to text: inout String, format: Format) throws {
        let (units, members) = try object(text)
        guard !members.contains(where: { $0.key == key }) else { return }
        let pair = jsonString(key) + format.colon + value
        guard let last = members.last else {
            let range = NSRange(location: 0, length: units.count)
            text = (text as NSString).replacingCharacters(in: range, with: "{\(pair)}")
            return
        }
        let separator: String
        if members.count > 1 {
            separator = String(utf16CodeUnits: Array(units[NSMaxRange(members[0].value.range)..<members[1].keyRange.location]),
                               count: members[1].keyRange.location - NSMaxRange(members[0].value.range))
        } else {
            separator = format.isCompact ? "," : "," + format.newline + format.elementIndent + format.unit
        }
        if let next = members.first(where: { $0.key > key }) {
            text = (text as NSString).replacingCharacters(in: NSRange(location: next.keyRange.location, length: 0),
                                                          with: pair + separator)
        } else {
            text = (text as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(last.value.range), length: 0),
                                                          with: separator + pair)
        }
    }

    // MARK: Writing

    /// A JSON string as Python's `json.dumps(ensure_ascii=False)` writes it, which is how
    /// Jupyter saves notebooks.
    static func jsonString(_ value: String) -> String {
        var result = "\""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) }
                else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    /// How the file is laid out, to write new values the way the rest of it is written.
    private struct Format {
        let units: [UInt16]
        /// One level of indentation; empty in a minified file.
        let unit: String
        let isCompact: Bool
        /// The file's line break, "\r\n" in a notebook saved with Windows line endings.
        let newline: String
        let colon: String
        let usesCellIDs: Bool
        /// The indentation of a cell's opening brace, and what goes between two cells.
        let elementIndent: String
        let elementSeparator: String

        init(units: [UInt16], root: JSONNode, cells: JSONMember) {
            self.units = units
            guard case .object(let members) = root.kind, let first = members.first else {
                unit = " "; isCompact = false; newline = "\n"; colon = ": "; usesCellIDs = false
                elementIndent = "  "; elementSeparator = ",\n  "
                return
            }
            // In UTF-16 units: as a Character, "\r\n" is not "\n".
            let leading = units[(root.range.location + 1)..<first.keyRange.location]
            let lineEnd = leading.lastIndex(of: 0x0A)
            isCompact = lineEnd == nil
            newline = lineEnd.map { $0 > leading.startIndex && units[$0 - 1] == 0x0D } == true ? "\r\n" : "\n"
            unit = lineEnd.map { Self.string(units, NSRange(location: $0 + 1, length: first.keyRange.location - $0 - 1)) } ?? ""
            colon = Self.string(units, NSRange(location: NSMaxRange(first.keyRange),
                                               length: first.value.range.location - NSMaxRange(first.keyRange)))
            let major = members.first { $0.key == "nbformat" }.flatMap { Int(Self.string(units, $0.value.range)) } ?? 4
            let minor = members.first { $0.key == "nbformat_minor" }.flatMap { Int(Self.string(units, $0.value.range)) } ?? 0
            usesCellIDs = major > 4 || (major == 4 && minor >= 5)
            let keyIndent = isCompact ? "" : Self.indent(units, atLineOf: cells.keyRange.location)
            elementIndent = isCompact ? "" : keyIndent + unit
            if case .array(let elements) = cells.value.kind, elements.count > 1 {
                elementSeparator = Self.string(units, NSRange(location: NSMaxRange(elements[0].range),
                                                              length: elements[1].range.location - NSMaxRange(elements[0].range)))
            } else {
                elementSeparator = isCompact ? "," : "," + newline + elementIndent
            }
        }

        func string(_ range: NSRange) -> String { Self.string(units, range) }

        func indent(atLineOf offset: Int) -> String { isCompact ? "" : Self.indent(units, atLineOf: offset) }

        static func string(_ units: [UInt16], _ range: NSRange) -> String {
            String(utf16CodeUnits: Array(units[range.location..<NSMaxRange(range)]), count: range.length)
        }

        static func indent(_ units: [UInt16], atLineOf offset: Int) -> String {
            var start = offset
            while start > 0 && units[start - 1] != 0x0A { start -= 1 }
            var end = start
            while end < units.count && (units[end] == 0x20 || units[end] == 0x09) { end += 1 }
            return string(units, NSRange(location: start, length: end - start))
        }

        /// A source as Jupyter saves it: an array of its lines, each with its line break.
        func lines(_ text: String, indent: String) -> String {
            var lines: [String] = []
            var current = ""
            for character in text {
                current.append(character)
                if character == "\n" || character == "\r\n" { lines.append(current); current = "" }
            }
            if !current.isEmpty { lines.append(current) }
            guard !lines.isEmpty else { return "[]" }
            let items = lines.map(jsonString)
            if isCompact { return "[" + items.joined(separator: ",") + "]" }
            let inner = indent + unit
            return "[" + newline + items.map { inner + $0 }.joined(separator: "," + newline) + newline + indent + "]"
        }

        func newCell(kind: String, id: String?, indent: String) -> String {
            var pairs: [(String, String)] = [("cell_type", jsonString(kind))]
            if kind == "code" { pairs.append(("execution_count", "null")) }
            if let id { pairs.append(("id", jsonString(id))) }
            pairs.append(("metadata", "{}"))
            if kind == "code" { pairs.append(("outputs", "[]")) }
            pairs.append(("source", "[]"))
            let items = pairs.map { jsonString($0.0) + colon + $0.1 }
            if isCompact { return "{" + items.joined(separator: ",") + "}" }
            let inner = indent + unit
            return "{" + newline + items.map { inner + $0 }.joined(separator: "," + newline) + newline + indent + "}"
        }
    }
}

// MARK: - Scanning

/// A JSON value and where it is in the text, in UTF-16 offsets. Containers deeper than the
/// scan asked for keep only their range.
struct JSONNode {
    enum Kind {
        case object([JSONMember])
        case array([JSONNode])
        case string
        case other
    }

    var kind: Kind
    var range: NSRange

    func member(_ key: String) -> JSONMember? {
        guard case .object(let members) = kind else { return nil }
        return members.first { $0.key == key }
    }
}

struct JSONMember {
    let key: String
    let keyRange: NSRange
    let value: JSONNode
}

/// A strict JSON scanner that records ranges rather than building values, so a notebook with
/// megabytes of saved output costs one pass over its text.
struct JSONScanner {
    let units: [UInt16]
    private var position = 0

    init(units: [UInt16]) { self.units = units }

    private static func failure(_ position: Int) -> NotebookEditing.Failure {
        .message("Invalid notebook JSON near offset \(position). Correct it in Source view.")
    }

    /// The whole text as one value, keeping containers down to `depth` levels.
    mutating func document(depth: Int) throws -> JSONNode {
        position = 0
        skipSpace()
        let node = try value(depth: depth)
        skipSpace()
        guard position == units.count else { throw Self.failure(position) }
        return node
    }

    private mutating func skipSpace() {
        while position < units.count {
            switch units[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    private mutating func expect(_ unit: UInt16) throws {
        guard position < units.count, units[position] == unit else { throw Self.failure(position) }
        position += 1
    }

    private mutating func value(depth: Int) throws -> JSONNode {
        guard position < units.count else { throw Self.failure(position) }
        let start = position
        switch units[position] {
        case 0x7B: // {
            position += 1
            var members: [JSONMember] = []
            skipSpace()
            if position < units.count, units[position] == 0x7D {
                position += 1
                return JSONNode(kind: .object([]), range: NSRange(location: start, length: position - start))
            }
            while true {
                skipSpace()
                let keyStart = position
                let key = try string(decode: depth > 0)
                let keyRange = NSRange(location: keyStart, length: position - keyStart)
                skipSpace()
                try expect(0x3A)
                skipSpace()
                let member = try value(depth: depth - 1)
                if depth > 0 { members.append(JSONMember(key: key, keyRange: keyRange, value: member)) }
                skipSpace()
                guard position < units.count else { throw Self.failure(position) }
                if units[position] == 0x2C { position += 1; continue }
                try expect(0x7D)
                break
            }
            return JSONNode(kind: .object(members), range: NSRange(location: start, length: position - start))
        case 0x5B: // [
            position += 1
            var elements: [JSONNode] = []
            skipSpace()
            if position < units.count, units[position] == 0x5D {
                position += 1
                return JSONNode(kind: .array([]), range: NSRange(location: start, length: position - start))
            }
            while true {
                skipSpace()
                let element = try value(depth: depth - 1)
                if depth > 0 { elements.append(element) }
                skipSpace()
                guard position < units.count else { throw Self.failure(position) }
                if units[position] == 0x2C { position += 1; continue }
                try expect(0x5D)
                break
            }
            return JSONNode(kind: .array(elements), range: NSRange(location: start, length: position - start))
        case 0x22:
            _ = try string(decode: false)
            return JSONNode(kind: .string, range: NSRange(location: start, length: position - start))
        default:
            while position < units.count, !Self.ends(units[position]) { position += 1 }
            // Numbers and literals are only skipped: the preview parsed the same text first.
            guard position > start else { throw Self.failure(start) }
            switch units[start] {
            case 0x2D, 0x30...0x39, 0x74, 0x66, 0x6E: break
            default: throw Self.failure(start)
            }
            return JSONNode(kind: .other, range: NSRange(location: start, length: position - start))
        }
    }

    private static func ends(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D: true
        default: false
        }
    }

    /// Scans a string, returning its value when `decode` is set (for keys) and "" otherwise.
    private mutating func string(decode: Bool) throws -> String {
        let start = position
        try expect(0x22)
        var escaped = false
        while position < units.count {
            let unit = units[position]
            if unit == 0x5C { escaped = true; position += 2; continue }
            if unit < 0x20 { throw Self.failure(position) }
            position += 1
            if unit == 0x22 {
                guard decode else { return "" }
                let raw = Array(units[start..<position])
                if !escaped { return String(utf16CodeUnits: Array(raw.dropFirst().dropLast()), count: raw.count - 2) }
                let data = Data(String(utf16CodeUnits: raw, count: raw.count).utf8)
                guard let value = try? JSONDecoder().decode(String.self, from: data) else { throw Self.failure(start) }
                return value
            }
        }
        throw Self.failure(start)
    }
}

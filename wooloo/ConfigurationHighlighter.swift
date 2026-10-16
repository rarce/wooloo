import Foundation
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

/// INI/Properties have line-oriented syntax. UTF-16 spans also feed the diff renderer, so
/// comments, sections, keys and values use identical colors in both views.
enum ConfigurationSyntax {
    static func highlights(_ text: String) -> [HighlightRange] {
        let source = text as NSString
        var result: [HighlightRange] = []
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range) as NSString
            result += highlights(line: line).map {
                HighlightRange(range: NSRange(location: range.location + $0.range.location, length: $0.range.length),
                               capture: $0.capture)
            }
            offset = NSMaxRange(range)
        }
        return result
    }

    private static let number = try! NSRegularExpression(pattern: #"^[+-]?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)$"#)

    private static func highlights(line: NSString) -> [HighlightRange] {
        var result: [HighlightRange] = []
        var count = line.length
        while count > 0 && [10, 13].contains(line.character(at: count - 1)) { count -= 1 }
        func whitespace(_ index: Int) -> Bool { [9, 10, 13, 32].contains(line.character(at: index)) }
        func append(_ start: Int, _ end: Int, _ capture: CaptureName) {
            if end > start { result.append(.init(range: NSRange(location: start, length: end - start), capture: capture)) }
        }
        var index = 0
        while index < count && whitespace(index) { index += 1 }
        guard index < count else { return [] }
        if [35, 59, 33].contains(line.character(at: index)) { // # ; !
            append(index, count, .comment)
            return result
        }
        if line.character(at: index) == 91, let end = (index + 1..<count).first(where: { line.character(at: $0) == 93 }) {
            append(index, end + 1, .type)
            index = end + 1
        } else {
            let start = index
            // Escaped separators and spaces belong to a Properties key.
            while index < count {
                let character = line.character(at: index)
                if character == 92 { index = min(index + 2, count); continue }
                if character == 61 || character == 58 || whitespace(index) { break }
                index += 1
            }
            append(start, index, .keyword)
            while index < count && whitespace(index) { index += 1 }
            if index < count, [61, 58].contains(line.character(at: index)) { index += 1 }
        }
        while index < count {
            if whitespace(index) { index += 1; continue }
            let start = index, character = line.character(at: index)
            // Inline comments start after whitespace; URLs and unquoted # within values survive.
            if [35, 59].contains(character), index == 0 || whitespace(index - 1) {
                append(index, count, .comment)
                break
            }
            if character == 34 || character == 39 {
                index += 1
                while index < count {
                    let current = line.character(at: index)
                    index += 1
                    if current == 92 { index = min(index + 1, count) }
                    else if current == character { break }
                }
                append(start, index, .string)
            } else {
                while index < count && !whitespace(index) {
                    if line.character(at: index) == 92 { index = min(index + 2, count) }
                    else { index += 1 }
                }
                let value = line.substring(with: NSRange(location: start, length: index - start))
                let range = NSRange(location: 0, length: (value as NSString).length)
                let capture: CaptureName = ["true", "false", "yes", "no", "on", "off"].contains(value.lowercased())
                    ? .boolean : (number.firstMatch(in: value, range: range) != nil ? .number : .string)
                append(start, index, capture)
            }
        }
        return result
    }
}

final class ConfigurationHighlightProvider: HighlightProviding {
    func setUp(textView: TextView, codeLanguage: CodeLanguage) { }

    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        let length = textView.textStorage.length
        let start = min(range.location, length)
        let changed = NSRange(location: start, length: min(max(0, range.length + delta), length - start))
        let lines = (textView.string as NSString).lineRange(for: changed)
        completion(.success(IndexSet(integersIn: lines.location..<NSMaxRange(lines))))
    }

    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void) {
        let source = textView.string as NSString
        guard range.location <= source.length else { completion(.success([])); return }
        let bounded = NSRange(location: range.location, length: min(range.length, source.length - range.location))
        let lines = source.lineRange(for: bounded)
        let highlights = ConfigurationSyntax.highlights(source.substring(with: lines)).compactMap { span -> HighlightRange? in
            let absolute = NSRange(location: lines.location + span.range.location, length: span.range.length)
            guard let intersection = absolute.intersection(bounded), intersection.length > 0 else { return nil }
            return HighlightRange(range: intersection, capture: span.capture)
        }
        completion(.success(highlights))
    }
}

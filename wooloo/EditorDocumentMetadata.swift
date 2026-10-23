import Foundation

/// Rebuilt only on document edits. Cursor movement uses a binary search over UTF-16 line starts.
struct EditorDocumentMetadata {
    private(set) var lineStarts = [0]
    private(set) var utf16Length = 0
    private(set) var lineEndings = "No EOL"

    init(_ text: String = "") {
        var kinds = Set<String>()
        var previousWasCR = false
        for (index, unit) in text.utf16.enumerated() {
            utf16Length = index + 1
            if unit == 10, previousWasCR {
                lineStarts[lineStarts.count - 1] = index + 1
                kinds.insert("CRLF")
            } else {
                if previousWasCR { kinds.insert("CR") }
                switch unit {
                case 13: lineStarts.append(index + 1)
                case 10: kinds.insert("LF"); lineStarts.append(index + 1)
                case 0x85: kinds.insert("NEL"); lineStarts.append(index + 1)
                case 0x2028: kinds.insert("LS"); lineStarts.append(index + 1)
                case 0x2029: kinds.insert("PS"); lineStarts.append(index + 1)
                default: break
                }
            }
            previousWasCR = unit == 13
        }
        if previousWasCR { kinds.insert("CR") }
        lineEndings = kinds.count > 1 ? "Mixed EOL" : kinds.first ?? "No EOL"
    }

    func position(at offset: Int) -> (line: Int, column: Int) {
        let offset = offset == NSNotFound ? 0 : min(max(offset, 0), utf16Length)
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let index = max(low - 1, 0)
        return (index + 1, offset - lineStarts[index] + 1)
    }

    /// The contents of a 1-based editor line, excluding its original line terminator.
    func contentRange(ofLine line: Int, in text: NSString) -> NSRange? {
        guard line > 0, line <= lineStarts.count, text.length == utf16Length else { return nil }
        let start = lineStarts[line - 1]
        var end = line < lineStarts.count ? lineStarts[line] : utf16Length
        if line < lineStarts.count {
            end -= 1
            if text.character(at: end) == 10, end > start, text.character(at: end - 1) == 13 {
                end -= 1
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Counts user-perceived characters in selected ranges; ranges are supplied in UTF-16.
    static func selectedCharacters(in text: String, ranges: [NSRange]) -> Int {
        ranges.reduce(0) { count, range in
            guard range.length > 0, let valid = Range(range, in: text) else { return count }
            return count + text[valid].count
        }
    }
}

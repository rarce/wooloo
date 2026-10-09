import Foundation

/// Display columns of a line as a monospaced editor draws it: a tab advances to the next tab
/// stop, East Asian wide characters and emoji take two columns, and combining marks none, as part
/// of their grapheme cluster. Offsets are UTF-16, as in `NSString` and the editor's ranges.
/// Terminal popup titles follow Herdr's own layout instead (`HerdrTitle`). (`wcwidth` is no
/// substitute: it answers -1 for anything non-ASCII in the app's C locale.)
enum DisplayColumns {
    /// The display column of `offset` within its line, counting only the grapheme clusters that
    /// end at or before it.
    static func column(of offset: Int, in text: NSString, tabWidth: Int) -> Int {
        let offset = min(max(offset, 0), text.length)
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        // An offset inside a cluster (say, a ⌘D match on the "e" of a decomposed "é") counts
        // from the start of that cluster.
        let end = offset < NSMaxRange(line)
            ? max(text.rangeOfComposedCharacterSequence(at: offset).location, line.location) : offset
        let prefix = text.substring(with: NSRange(location: line.location, length: end - line.location))
        return column(ofUTF16Offset: end - line.location, in: prefix, tabWidth: tabWidth)
    }

    /// The display column at UTF-16 `offset` in `line`, counting only whole grapheme clusters
    /// before it.
    static func column(ofUTF16Offset offset: Int, in line: String, tabWidth: Int) -> Int {
        var column = 0
        var utf16 = 0
        forEachCluster(in: line, tabWidth: tabWidth) { length, width in
            guard utf16 + length <= offset else { return false }
            column += width
            utf16 += length
            return true
        }
        return column
    }

    /// The UTF-16 offset in `line` (without its line break) that shows at display `column`, clamped
    /// to the line's end. A column inside a tab or a wide character goes to the nearer side of
    /// it, and to the far side when both are equally near, as VS Code does; the offset is always
    /// on a grapheme cluster boundary.
    static func offset(forColumn target: Int, in line: String, tabWidth: Int) -> Int {
        var column = 0
        var utf16 = 0
        var inside: Int?
        forEachCluster(in: line, tabWidth: tabWidth) { length, width in
            guard column < target else { return false }
            let next = column + width
            if next > target {
                inside = target - column < next - target ? utf16 : utf16 + length
                return false
            }
            column = next
            utf16 += length
            return true
        }
        return inside ?? utf16
    }

    /// The columns `character` takes when it starts at display `column`.
    static func width(of character: Character, at column: Int, tabWidth: Int) -> Int {
        if character == "\t" { return tabStop(after: column, tabWidth: tabWidth) - column }
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .control:
            return 0 // CR LF is one cluster of two controls.
        case .nonspacingMark, .enclosingMark, .format:
            // Alone they draw nothing; a prepended format character (U+0600) leads a visible cluster.
            if scalars.count == 1 { return 0 }
        default:
            break
        }
        let properties = first.properties
        // U+FE0E asks for the narrow text glyph of an emoji, even one shown as emoji by default.
        if properties.isEmoji, scalars.contains("\u{FE0E}") { return 1 }
        // Emoji shown as emoji by default (flags among them), then text-default emoji turned into
        // emoji by U+FE0F, keycaps, ZWJ sequences and a skin tone on a text-default base (✌🏻).
        if isWide(first) || properties.isEmojiPresentation { return 2 }
        if scalars.count > 1, properties.isEmoji,
           scalars.contains(where: { [0xFE0F, 0x20E3, 0x200D].contains($0.value) }) {
            return 2
        }
        if properties.isEmojiModifierBase, scalars.dropFirst().first?.properties.isEmojiModifier == true {
            return 2
        }
        return 1
    }

    private static func tabStop(after column: Int, tabWidth: Int) -> Int {
        let tabWidth = max(tabWidth, 1)
        return (column / tabWidth + 1) * tabWidth
    }

    /// Calls `visit` with the UTF-16 length and display width of each grapheme cluster of `line`,
    /// in order, until it returns false. All-ASCII lines (most code, and minified files with very
    /// long lines) skip grapheme breaking, which is several times slower; `line` holds no line
    /// break, so CR LF never appears as two clusters.
    private static func forEachCluster(in line: String, tabWidth: Int, _ visit: (_ length: Int, _ width: Int) -> Bool) {
        var column = 0
        if line.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in line.utf8 {
                let width = byte == 0x09 ? tabStop(after: column, tabWidth: tabWidth) - column
                    : byte < 0x20 || byte == 0x7F ? 0 : 1
                guard visit(1, width) else { return }
                column += width
            }
            return
        }
        for character in line {
            let width = width(of: character, at: column, tabWidth: tabWidth)
            guard visit(character.utf16.count, width) else { return }
            column += width
        }
    }

    /// East Asian Wide and Fullwidth ranges (Unicode 16's EastAsianWidth.txt, W and F), coarsely:
    /// unassigned code points inside a range count as wide, and combining marks within them are
    /// caught earlier by their category.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x3247,
             0x3250...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x16FE0...0x18DFF, 0x1AFF0...0x1B2FF, 0x1F200...0x1F2FF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

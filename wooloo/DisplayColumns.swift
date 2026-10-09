import Foundation

/// Display columns of a line as a monospaced editor draws it: a tab advances to the next tab
/// stop, East Asian wide characters and emoji take two columns, and combining marks none, as part
/// of their grapheme cluster. Offsets are UTF-16, as in `NSString` and the editor's ranges.
/// The terminal sizes popup titles with `terminalWidth(of:)` instead, which follows Herdr's own
/// chrome. (`wcwidth` is no substitute: it answers -1 for anything non-ASCII in the app's C locale.)
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

    /// The cells Herdr gives `character` in a popup title. Herdr draws titles with ratatui, which
    /// drops a cluster holding a control character and otherwise takes the `unicode-width` 0.2
    /// width of each grapheme cluster as a string: the sum of its characters' widths, except for
    /// the emoji sequences that string width treats as one (see `terminalStep`). So a lone
    /// regional indicator takes one cell, U+FE0E narrows only emoji that have a text variation,
    /// a keycap or ZWJ sequence without U+FE0F is as wide as its parts (`1⃣` 1, `🏳‍🌈` 3), and a
    /// spacing mark adds a cell (Thai `กำ` 2), while lone Hangul vowels and trailing consonants
    /// take none. Halfwidth kana with a sound mark (`ｶﾞ`) take one cell, as in ratatui-core 0.1.0,
    /// which Herdr uses; ratatui-core 0.1.2 gives them two. The editor keeps
    /// `width(of:at:tabWidth:)`, closer to how it draws these clusters.
    static func terminalWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let only = scalars.first, only.value >= 0x20, only.value < 0x7F { return 1 }
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return 0 }
        var width = 0
        var next = TerminalWidthState.none
        for scalar in scalars.reversed() {
            let step = terminalStep(scalar, before: next)
            width += step.width
            next = step.state
        }
        return max(width, 0)
    }

    /// What follows a character in `unicode-width`'s right-to-left pass over a string
    /// (`WidthInfo`), limited to the states a single grapheme cluster can reach: the script
    /// ligatures it also tracks (Arabic lam-alef, Khmer coeng and others) join separate clusters,
    /// which ratatui measures one by one.
    private enum TerminalWidthState: Equatable {
        case none, textVariation, emojiVariation, quoteVariation
        case emojiModifier, regionalIndicator, severalRegionalIndicators, emojiPresentation
        /// After a ZWJ (and maybe a keycap) that continues an emoji sequence, before or after its U+FE0F.
        case zwjEmoji(keycap: Bool, emojiVariation: Bool)
        case regionalIndicatorZWJ, evenRegionalIndicatorZWJ, oddRegionalIndicatorZWJ
        /// After a cancel tag that follows a ZWJ, with the tag letters and digits seen before it.
        case tagEnd(letters: Int, digits: Int)
        case kiratRaiE, kiratRaiAI

        var isEmojiVariation: Bool {
            switch self {
            case .emojiVariation, .zwjEmoji(_, true): return true
            default: return false
            }
        }
    }

    /// One step of `unicode-width` 0.2's `width_in_str`: the width `scalar` adds before `next`
    /// (it can be negative) and the state it leaves for the scalar before it.
    private static func terminalStep(_ scalar: Unicode.Scalar, before next: TerminalWidthState)
        -> (width: Int, state: TerminalWidthState) {
        let value = scalar.value
        var next = next
        if next.isEmojiVariation {
            if startsEmojiPresentationSequence(scalar) {
                if case .zwjEmoji = next { return (0, .emojiPresentation) }
                return (2, .emojiPresentation)
            }
            next = .none
        }
        if value <= 0xA0 { return (1, .none) }
        if next != .none {
            switch value {
            case 0xFE0F:
                if case .zwjEmoji(let keycap, _) = next { return (0, .zwjEmoji(keycap: keycap, emojiVariation: true)) }
                return (0, .emojiVariation)
            case 0xFE01: return (0, .quoteVariation)
            case 0xFE0E: return (0, .textVariation)
            default: break
            }
            if next == .textVariation {
                if startsTextPresentationSequence(scalar) { return (1, .none) }
                next = .none
            } else if next == .quoteVariation {
                if [0x2018, 0x2019, 0x201C, 0x201D].contains(value) { return (2, .none) }
                next = .none
            }
            let regionalIndicator = (0x1F1E6...0x1F1FF).contains(value)
            switch next {
            case .emojiModifier where scalar.properties.isEmojiModifierBase:
                return (0, .emojiPresentation)
            case .regionalIndicator where regionalIndicator, .severalRegionalIndicators where regionalIndicator:
                return (1, .severalRegionalIndicators)
            case .emojiPresentation, .severalRegionalIndicators, .evenRegionalIndicatorZWJ,
                 .oddRegionalIndicatorZWJ, .emojiModifier:
                if value == 0x200D { return (0, .zwjEmoji(keycap: false, emojiVariation: false)) }
            case .zwjEmoji(false, false):
                if value == 0x20E3 { return (0, .zwjEmoji(keycap: true, emojiVariation: false)) }
                if regionalIndicator { return (1, .regionalIndicatorZWJ) }
                if (0x1F3FB...0x1F3FF).contains(value) { return (0, .emojiModifier) }
                if value == 0xE007F { return (0, .tagEnd(letters: 0, digits: 0)) }
                if terminalLookup(scalar).state == .emojiPresentation { return (0, .emojiPresentation) }
            case .regionalIndicatorZWJ where regionalIndicator, .oddRegionalIndicatorZWJ where regionalIndicator:
                return (-1, .evenRegionalIndicatorZWJ)
            case .evenRegionalIndicatorZWJ where regionalIndicator:
                return (3, .oddRegionalIndicatorZWJ)
            case .tagEnd(let letters, let digits):
                if (0xE0061...0xE007A).contains(value), digits == 0, letters < 6 {
                    return (0, .tagEnd(letters: letters + 1, digits: 0))
                }
                if (0xE0030...0xE0039).contains(value), digits < 3, digits > 0 || letters < 5 {
                    return (0, .tagEnd(letters: letters, digits: digits + 1))
                }
                if value == 0x1F3F4, digits == 0 ? letters >= 3 : digits == 3 { return (0, .emojiPresentation) }
            case .kiratRaiE:
                switch value {
                case 0x16D63, 0x16D69: return (0, .none)
                case 0x16D67: return (0, .kiratRaiAI)
                case 0x16D68: return (1, .kiratRaiE)
                default: break
                }
            case .kiratRaiAI where value == 0x16D63:
                return (0, .none)
            default:
                break
            }
        }
        return terminalLookup(scalar)
    }

    /// A scalar's own `unicode-width` 0.2 width and the state it starts, from its Unicode
    /// properties where the crate's tables follow them, and the crate's exceptions otherwise.
    private static func terminalLookup(_ scalar: Unicode.Scalar) -> (width: Int, state: TerminalWidthState) {
        let value = scalar.value
        switch value {
        case 0xFE01: return (0, .quoteVariation)
        case 0xFE0E: return (0, .textVariation)
        case 0xFE0F: return (0, .emojiVariation)
        case 0x16D67: return (1, .kiratRaiE)
        case 0x16D68: return (1, .kiratRaiAI)
        case 0x1F1E6...0x1F1FF: return (1, .regionalIndicator)
        case 0x1F3FB...0x1F3FF: return (2, .emojiModifier)
        case 0x115F, 0x17A4: return (2, .none)
        case 0x17D8: return (3, .none)
        case 0x2D7F: return (1, .none)
        // Prepended concatenation marks that draw nothing, other prepended characters, and the
        // Devanagari caret.
        case 0x605, 0x70F, 0x890...0x891, 0x8E2, 0xD4E, 0xA8FA, 0x111C2...0x111C3, 0x113D1, 0x1193F,
             0x11941, 0x11A84...0x11A89, 0x11D46, 0x11F02:
            return (0, .none)
        // Hangul vowel and trailing consonant jamo.
        case 0x1160...0x11FF, 0xD7B0...0xD7FF:
            return (0, .none)
        default:
            break
        }
        let properties = scalar.properties
        if properties.isDefaultIgnorableCodePoint || properties.isGraphemeExtend { return (0, .none) }
        if properties.isEmojiPresentation { return (2, .emojiPresentation) }
        switch value {
        // Wide since Unicode 16: Yijing symbols, trigrams and monograms, Tai Xuan Jing and
        // counting rod numerals.
        case 0x2630...0x2637, 0x268A...0x268F, 0x4DC0...0x4DFF, 0x1D300...0x1D356, 0x1D360...0x1D376:
            return (2, .none)
        default:
            return (isWide(scalar) ? 2 : 1, .none)
        }
    }

    /// Whether `scalar` followed by U+FE0F is an emoji presentation sequence: text-default emoji,
    /// and the emoji-default ones with a text variation.
    private static func startsEmojiPresentationSequence(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isEmoji && (!properties.isEmojiPresentation || hasTextVariation(scalar))
    }

    /// Whether U+FE0E narrows `scalar` to one cell: an emoji-default character with a text
    /// variation, outside the Enclosed Ideographic Supplement.
    private static func startsTextPresentationSequence(_ scalar: Unicode.Scalar) -> Bool {
        !(0x1F200...0x1F2FF).contains(scalar.value) && hasTextVariation(scalar)
    }

    /// Emoji-default characters with a text variation sequence (Unicode 17's
    /// emoji-variation-sequences.txt, as `unicode-width` 0.2.2 lists them).
    private static func hasTextVariation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x231A...0x231B, 0x23E9...0x23EC, 0x23F0, 0x23F3, 0x25FD...0x25FE, 0x2614...0x2615,
             0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
             0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A...0x270B,
             0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF,
             0x2B1B...0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F21A, 0x1F22F, 0x1F30D...0x1F30F, 0x1F315,
             0x1F31C, 0x1F378, 0x1F393, 0x1F3A7, 0x1F3AC...0x1F3AE, 0x1F3C2, 0x1F3C4, 0x1F3C6, 0x1F3CA,
             0x1F3E0, 0x1F3ED, 0x1F408, 0x1F415, 0x1F41F, 0x1F426, 0x1F442, 0x1F446...0x1F449,
             0x1F44D...0x1F44E, 0x1F453, 0x1F46A, 0x1F47D, 0x1F4A3, 0x1F4B0, 0x1F4B3, 0x1F4BB, 0x1F4BF,
             0x1F4CB, 0x1F4DA, 0x1F4DF, 0x1F4E4...0x1F4E6, 0x1F4EA...0x1F4ED, 0x1F4F7, 0x1F4F9...0x1F4FB,
             0x1F508, 0x1F50D, 0x1F512...0x1F513, 0x1F550...0x1F567, 0x1F610, 0x1F687, 0x1F68D, 0x1F691,
             0x1F694, 0x1F698, 0x1F6AD, 0x1F6B2, 0x1F6B9...0x1F6BA, 0x1F6BC:
            return true
        default:
            return false
        }
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

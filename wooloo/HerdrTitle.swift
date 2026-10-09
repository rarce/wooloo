import Foundation
import os

/// Popup titles laid out as Herdr's own client draws them: a ratatui-core 0.1.0 `Block` title,
/// split into grapheme clusters by `unicode-segmentation` 1.13 (Herdr 0.9.3 bundles 1.13.1, whose
/// tables and whole-string rules equal 1.13.3's) and sized by `unicode-width` 0.2.2. Herdr sends
/// only the title text, so wooloo repeats that layout here, from the crates'
/// own tables (`HerdrTitleTables.swift`, written by `scripts/herdr-title-tables.sh`) rather than
/// the system's Unicode data, which differs between macOS versions. The editor keeps
/// `DisplayColumns`, closer to how it draws these clusters.
enum HerdrTitle {
    struct Cell: Equatable {
        var symbol: String
        /// Hidden behind the wide cluster to its left.
        var covered = false
    }

    /// The title cells in a row of `room` cells, nil where the border stays. ratatui-core 0.1.0
    /// makes the title a `Line` of one span per line of text (`str::lines`, so line breaks are
    /// removed), and ratatui-widgets 0.3.0's `render_left_titles` gives that line at most its
    /// string width: the spans' `UnicodeWidthStr` widths, which count other controls and join
    /// ligatures across clusters (Arabic lam-alef, Khmer coeng). Each span starts its string
    /// width after the previous one, and `Span::render` draws its clusters until one does not
    /// fit, leaves out a cluster with a control character, and adds a zero-width cluster to the
    /// symbol of the cell before it.
    ///
    /// One deliberate difference: ratatui gives a zero-width cluster that starts a span a cell of
    /// its own, which the next cluster then joins, so a title starting with U+0301 would shape a
    /// combining mark with no base. Here such a cluster joins the cell before it, or is left out
    /// at the start of the title (or after a cell the title leaves blank); the visible clusters
    /// keep their cells. The last layout is kept, since a popup's title rarely changes while
    /// frames stream in.
    static func cells(of title: String, room: Int) -> [Cell?] {
        if let last = lastLayout.withLock({ $0 }), last.title == title, last.room == room { return last.cells }
        let cells = layOut(title, room: room)
        lastLayout.withLock { $0 = (title, room, cells) }
        return cells
    }

    private static let lastLayout = OSAllocatedUnfairLock<(title: String, room: Int, cells: [Cell?])?>(initialState: nil)

    private static func layOut(_ title: String, room: Int) -> [Cell?] {
        let spans = lines(of: Array(title.unicodeScalars))
        let widths = spans.map(stringWidth)
        let areaWidth = min(widths.reduce(0, +), max(room, 0))
        var cells = [Cell?](repeating: nil, count: areaWidth)
        var spanX = 0
        for (span, spanWidth) in zip(spans, widths) where spanWidth > 0 {
            guard spanX < areaWidth else { break }
            let scalars = Array(span)
            var x = spanX
            for range in clusterRanges(scalars) {
                let cluster = scalars[range]
                if cluster.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) { continue }
                var symbol = ""
                symbol.unicodeScalars.append(contentsOf: cluster)
                let width = stringWidth(cluster)
                if width == 0 {
                    if x > 0 { cells[x - 1]?.symbol += symbol }
                    continue
                }
                let next = x + width
                if next > areaWidth { break }
                cells[x] = Cell(symbol: symbol)
                for hidden in (x + 1)..<next {
                    cells[hidden] = Cell(symbol: "", covered: true)
                }
                x = next
            }
            spanX += spanWidth
        }
        return cells
    }

    /// Rust's `str::lines`: split at LF, drop a CR before it and the empty text after a final LF.
    private static func lines(of scalars: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
        var lines: [ArraySlice<Unicode.Scalar>] = []
        var start = 0
        for (index, scalar) in scalars.enumerated() where scalar.value == 0x0A {
            let end = index > start && scalars[index - 1].value == 0x0D ? index - 1 : index
            lines.append(scalars[start..<end])
            start = index + 1
        }
        if start < scalars.count { lines.append(scalars[start...]) }
        return lines
    }

    /// For tests and comparisons with the crates only (the app lays out titles through
    /// `cells(of:room:)`): the grapheme clusters of `text` as `unicode-segmentation` splits them,
    /// the `UnicodeWidthStr` width of each, and the string width of the whole text.
    static func measure(_ text: String) -> (clusters: [String], widths: [Int], width: Int) {
        let scalars = Array(text.unicodeScalars)
        let ranges = clusterRanges(scalars)
        let clusters = ranges.map { range in
            var cluster = ""
            cluster.unicodeScalars.append(contentsOf: scalars[range])
            return cluster
        }
        return (clusters, ranges.map { stringWidth(scalars[$0]) }, stringWidth(scalars[...]))
    }

    // MARK: - Grapheme clusters (unicode-segmentation 1.13.3)

    /// `GraphemeCat`, in the crate's order.
    private enum GraphemeCategory: UInt32 {
        case any, cr, control, extend, extendedPictographic, conjunctConsonant, l, lf, lv, lvt,
             prepend, regionalIndicator, spacingMark, t, v, zwj
    }

    private static func category(_ scalar: Unicode.Scalar) -> GraphemeCategory {
        GraphemeCategory(rawValue: runValue(graphemeRuns, scalar.value)) ?? .any
    }

    /// The crate's `check_pair` and the look-behind it asks for (GB9c conjuncts, GB11 emoji ZWJ
    /// sequences, GB12/13 regional indicator pairs), in one forward pass.
    private static func clusterRanges(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var previous: GraphemeCategory?
        var regionalIndicators = 0
        var pictographicRun = false
        var zwjAfterPictographic = false
        enum Conjunct { case none, consonant, linked }
        var conjunct = Conjunct.none
        for (index, scalar) in scalars.enumerated() {
            let current = category(scalar)
            if let before = previous {
                let isBreak: Bool
                switch (before, current) {
                case (.cr, .lf): isBreak = false                                    // GB3
                case (.control, _), (.cr, _), (.lf, _): isBreak = true              // GB4
                case (_, .control), (_, .cr), (_, .lf): isBreak = true              // GB5
                case (.l, .l), (.l, .v), (.l, .lv), (.l, .lvt): isBreak = false     // GB6
                case (.lv, .v), (.lv, .t), (.v, .v), (.v, .t): isBreak = false      // GB7
                case (.lvt, .t), (.t, .t): isBreak = false                          // GB8
                case (_, .extend), (_, .zwj): isBreak = false                       // GB9
                case (_, .spacingMark): isBreak = false                             // GB9a
                case (.prepend, _): isBreak = false                                 // GB9b
                case (_, .conjunctConsonant): isBreak = conjunct != .linked         // GB9c
                case (.zwj, .extendedPictographic): isBreak = !zwjAfterPictographic // GB11
                case (.regionalIndicator, .regionalIndicator):                      // GB12, GB13
                    isBreak = regionalIndicators % 2 == 0
                default: isBreak = true                                             // GB999
                }
                if isBreak {
                    ranges.append(start..<index)
                    start = index
                }
            }
            regionalIndicators = current == .regionalIndicator ? regionalIndicators + 1 : 0
            zwjAfterPictographic = current == .zwj && pictographicRun
            pictographicRun = current == .extendedPictographic || (current == .extend && pictographicRun)
            if inSet(conjunctLinkers, scalar.value) {
                conjunct = conjunct == .none ? .none : .linked
            } else if !inSet(conjunctExtends, scalar.value) {
                conjunct = current == .conjunctConsonant ? .consonant : .none
            }
            previous = current
        }
        if start < scalars.count { ranges.append(start..<scalars.count) }
        return ranges
    }

    // MARK: - Widths (unicode-width 0.2.2)

    /// `WidthInfo`: what follows a character in the right-to-left pass over a string.
    private enum Info {
        static let none: UInt16 = 0
        static let lineFeed: UInt16 = 0x0001
        static let emojiModifier: UInt16 = 0x0002
        static let regionalIndicator: UInt16 = 0x0003
        static let severalRegionalIndicator: UInt16 = 0x0004
        static let emojiPresentation: UInt16 = 0x0005
        static let zwjEmojiPresentation: UInt16 = 0x1006
        static let vs16ZwjEmojiPresentation: UInt16 = 0x9006
        static let keycapZwjEmojiPresentation: UInt16 = 0x1007
        static let vs16KeycapZwjEmojiPresentation: UInt16 = 0x9007
        static let regionalIndicatorZwjPresentation: UInt16 = 0x0009
        static let evenRegionalIndicatorZwjPresentation: UInt16 = 0x000A
        static let oddRegionalIndicatorZwjPresentation: UInt16 = 0x000B
        static let tagEndZwjEmojiPresentation: UInt16 = 0x0010
        static let tagD1EndZwjEmojiPresentation: UInt16 = 0x0011
        static let tagD2EndZwjEmojiPresentation: UInt16 = 0x0012
        static let tagD3EndZwjEmojiPresentation: UInt16 = 0x0013
        static let tagA1EndZwjEmojiPresentation: UInt16 = 0x0019
        static let tagA6EndZwjEmojiPresentation: UInt16 = 0x001E
        static let kiratRaiVowelSignE: UInt16 = 0x0020
        static let kiratRaiVowelSignAI: UInt16 = 0x0021
        static let variationSelector1To3: UInt16 = 0x0200
        static let variationSelector15: UInt16 = 0x4000
        static let variationSelector16: UInt16 = 0x8000
        static let joiningGroupAlef: UInt16 = 0x30FF
        static let zwjHebrewLetterLamed: UInt16 = 0x3C00
        static let zwjBugineseLetterYa: UInt16 = 0x3C01
        static let bugineseVowelSignIZwjLetterYa: UInt16 = 0x3C02
        static let tifinaghConsonant: UInt16 = 0x3803
        static let zwjTifinaghConsonant: UInt16 = 0x3C03
        static let tifinaghJoinerConsonant: UInt16 = 0x3C04
        static let lisuToneLetterMyaNaJeu: UInt16 = 0x3C05
        static let zwjOldTurkicLetterOrkhonI: UInt16 = 0x3C06
        static let khmerCoengEligibleLetter: UInt16 = 0x3C07
        static let ligatureTransparentMask: UInt16 = 0x2000

        static func isLigatureTransparent(_ info: UInt16) -> Bool { info & 0x0800 == 0x0800 }
        static func isEmojiPresentation(_ info: UInt16) -> Bool { info & variationSelector16 == variationSelector16 }
        static func isZwjEmojiPresentation(_ info: UInt16) -> Bool { info & 0xB000 == 0x9000 }
        static func isTextPresentation(_ info: UInt16) -> Bool { info & variationSelector15 == variationSelector15 }
        static func isVariationSelector1To3(_ info: UInt16) -> Bool { info & variationSelector1To3 == variationSelector1To3 }
        static func hasLigatureMask(_ info: UInt16) -> Bool { info & ligatureTransparentMask == ligatureTransparentMask }

        static func setEmojiPresentation(_ info: UInt16) -> UInt16 {
            // The crate's `|` binds after its `&`s, so this only sets the top bit.
            hasLigatureMask(info) || info & 0x9000 == 0x1000 ? info | variationSelector16 : variationSelector16
        }
        static func unsetEmojiPresentation(_ info: UInt16) -> UInt16 {
            hasLigatureMask(info) ? info & ~variationSelector16 : none
        }
        static func setTextPresentation(_ info: UInt16) -> UInt16 {
            hasLigatureMask(info) ? info | variationSelector15 : variationSelector15
        }
        static func setVariationSelector1To3(_ info: UInt16) -> UInt16 {
            hasLigatureMask(info) ? info | variationSelector1To3 : variationSelector1To3
        }
    }

    /// `str_width`: right to left, each character's width depending on what follows it.
    private static func stringWidth(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        var width = 0
        var next = Info.none
        for scalar in scalars.reversed() {
            let step = widthInString(scalar, before: next)
            width += step.width
            next = step.info
        }
        return max(width, 0)
    }

    /// `lookup_width`: a character's own width and the `WidthInfo` it starts.
    private static func lookup(_ value: UInt32) -> (width: Int, info: UInt16) {
        let entry = widthClasses[Int(runValue(widthRuns, value))]
        return (Int(entry & 0xFF), UInt16(entry >> 8))
    }

    private static func isTransparentZeroWidth(_ value: UInt32) -> Bool {
        lookup(value).width == 0 && !inSet(nonTransparentZeroWidths, value)
    }

    private static func isLigatureTransparentCharacter(_ value: UInt32) -> Bool {
        switch value {
        case 0x34F, 0x17B4...0x17B5, 0x180B...0x180D, 0x180F, 0x200D, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: return false
        }
    }

    /// `width_in_str`, case by case.
    private static func widthInString(_ scalar: Unicode.Scalar, before following: UInt16) -> (width: Int, info: UInt16) {
        let c = scalar.value
        var next = following
        if Info.isEmojiPresentation(next) {
            if inSet(emojiPresentationStarts, c) {
                return (Info.isZwjEmojiPresentation(next) ? 0 : 2, Info.emojiPresentation)
            }
            next = Info.unsetEmojiPresentation(next)
        }
        if c <= 0xA0 {
            if c == 0x0A { return (1, Info.lineFeed) }
            if c == 0x0D, next == Info.lineFeed { return (0, Info.none) }
            return (1, Info.none)
        }
        if next != Info.none {
            if c == 0xFE0F { return (0, Info.setEmojiPresentation(next)) }
            if c == 0xFE01 { return (0, Info.setVariationSelector1To3(next)) }
            if c == 0xFE0E { return (0, Info.setTextPresentation(next)) }
            if Info.isTextPresentation(next) {
                if inSet(textPresentationStarts, c) { return (1, Info.none) }
                next &= ~Info.variationSelector15
            } else if Info.isVariationSelector1To3(next) {
                if [0x2018, 0x2019, 0x201C, 0x201D].contains(c) { return (2, Info.none) }
                next &= ~Info.variationSelector1To3
            }
            if Info.isLigatureTransparent(next) {
                if c == 0x200D { return (0, next | 0x0400) }
                if isLigatureTransparentCharacter(c) { return (0, next) }
            }
            let regionalIndicator = (0x1F1E6...0x1F1FF).contains(c)
            switch next {
            case Info.joiningGroupAlef:
                // Arabic lam-alef.
                if c == 0x644 || (0x6B5...0x6B8).contains(c) || [0x76A, 0x8A6, 0x8C7].contains(c) { return (0, Info.none) }
                if isTransparentZeroWidth(c) { return (0, Info.joiningGroupAlef) }
            case Info.zwjHebrewLetterLamed where c == 0x5D0:
                return (0, Info.none)
            case Info.khmerCoengEligibleLetter where c == 0x17D2:
                return (-1, Info.none)
            case Info.zwjBugineseLetterYa where c == 0x1A17:
                return (0, Info.bugineseVowelSignIZwjLetterYa)
            case Info.bugineseVowelSignIZwjLetterYa where c == 0x1A15:
                return (0, Info.none)
            case Info.tifinaghConsonant, Info.zwjTifinaghConsonant, Info.tifinaghJoinerConsonant:
                let consonant = (0x2D31...0x2D65).contains(c) || c == 0x2D6F
                if next != Info.tifinaghJoinerConsonant, c == 0x2D7F { return (1, Info.tifinaghJoinerConsonant) }
                if next == Info.zwjTifinaghConsonant, consonant { return (0, Info.none) }
                if next == Info.tifinaghJoinerConsonant, consonant { return (-1, Info.none) }
            case Info.lisuToneLetterMyaNaJeu where (0xA4F8...0xA4FB).contains(c):
                return (0, Info.none)
            case Info.zwjOldTurkicLetterOrkhonI where c == 0x10C32:
                return (0, Info.none)
            default:
                break
            }
            if next == Info.emojiModifier, inSet(emojiModifierBases, c) { return (0, Info.emojiPresentation) }
            if (next == Info.regionalIndicator || next == Info.severalRegionalIndicator), regionalIndicator {
                return (1, Info.severalRegionalIndicator)
            }
            if [Info.emojiPresentation, Info.severalRegionalIndicator, Info.evenRegionalIndicatorZwjPresentation,
                Info.oddRegionalIndicatorZwjPresentation, Info.emojiModifier].contains(next), c == 0x200D {
                return (0, Info.zwjEmojiPresentation)
            }
            if next == Info.zwjEmojiPresentation, c == 0x20E3 { return (0, Info.keycapZwjEmojiPresentation) }
            if next == Info.vs16ZwjEmojiPresentation, inSet(emojiPresentationStarts, c) { return (0, Info.emojiPresentation) }
            if next == Info.vs16KeycapZwjEmojiPresentation, (0x30...0x39).contains(c) || c == 0x23 || c == 0x2A {
                return (0, Info.emojiPresentation)
            }
            if next == Info.zwjEmojiPresentation, regionalIndicator { return (1, Info.regionalIndicatorZwjPresentation) }
            if (next == Info.regionalIndicatorZwjPresentation || next == Info.oddRegionalIndicatorZwjPresentation),
               regionalIndicator {
                return (-1, Info.evenRegionalIndicatorZwjPresentation)
            }
            if next == Info.evenRegionalIndicatorZwjPresentation, regionalIndicator {
                return (3, Info.oddRegionalIndicatorZwjPresentation)
            }
            if next == Info.zwjEmojiPresentation, (0x1F3FB...0x1F3FF).contains(c) { return (0, Info.emojiModifier) }
            if next == Info.zwjEmojiPresentation, c == 0xE007F { return (0, Info.tagEndZwjEmojiPresentation) }
            let tagLetter = (0xE0061...0xE007A).contains(c), tagDigit = (0xE0030...0xE0039).contains(c)
            // Tag letters: TAG_END, then A1 to A6 (0x19 to 0x1E).
            if tagLetter, next == Info.tagEndZwjEmojiPresentation { return (0, Info.tagA1EndZwjEmojiPresentation) }
            if tagLetter, (Info.tagA1EndZwjEmojiPresentation..<Info.tagA6EndZwjEmojiPresentation).contains(next) {
                return (0, next + 1)
            }
            // Tag digits after TAG_END or A1 to A4: D1 to D3 (0x11 to 0x13).
            if tagDigit, next == Info.tagEndZwjEmojiPresentation || (0x19...0x1C).contains(next) {
                return (0, Info.tagD1EndZwjEmojiPresentation)
            }
            if tagDigit, next == Info.tagD1EndZwjEmojiPresentation || next == Info.tagD2EndZwjEmojiPresentation {
                return (0, next + 1)
            }
            if c == 0x1F3F4, (0x1B...0x1E).contains(next) || next == Info.tagD3EndZwjEmojiPresentation {
                return (0, Info.emojiPresentation)
            }
            if next == Info.zwjEmojiPresentation, lookup(c).info == Info.emojiPresentation {
                return (0, Info.emojiPresentation)
            }
            if next == Info.kiratRaiVowelSignE {
                switch c {
                case 0x16D63, 0x16D69: return (0, Info.none)
                case 0x16D67: return (0, Info.kiratRaiVowelSignAI)
                case 0x16D68: return (1, Info.kiratRaiVowelSignE)
                default: break
                }
            }
            if next == Info.kiratRaiVowelSignAI, c == 0x16D63 { return (0, Info.none) }
        }
        return lookup(c)
    }

    // MARK: - Tables

    /// The value of the run holding `value` in a `start << 8 | value` table.
    private static func runValue(_ runs: [UInt32], _ value: UInt32) -> UInt32 {
        var low = 0, high = runs.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if runs[middle] >> 8 <= value { low = middle } else { high = middle - 1 }
        }
        return runs[low] & 0xFF
    }

    /// Whether `value` is in a table of flattened inclusive ranges.
    private static func inSet(_ ranges: [UInt32], _ value: UInt32) -> Bool {
        var low = 0, high = ranges.count / 2 - 1
        while low <= high {
            let middle = (low + high) / 2
            if value < ranges[2 * middle] { high = middle - 1 }
            else if value > ranges[2 * middle + 1] { low = middle + 1 }
            else { return true }
        }
        return false
    }
}

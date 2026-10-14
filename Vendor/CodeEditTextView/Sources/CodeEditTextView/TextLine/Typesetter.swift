//
//  Typesetter.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import Foundation
import CoreText

final class Typesetter {
    var typesetter: CTTypesetter?
    var string: NSAttributedString!
    var lineFragments = TextLineStorage<LineFragment>()
    /// wooloo patch: the string's characters, read one UTF-16 unit at a time while looking for breaks.
    private var characters: NSString = ""

    // MARK: - Init & Prepare

    init() { }

    func typeset(
        _ string: NSAttributedString,
        displayData: TextLine.DisplayData,
        breakStrategy: LineBreakStrategy,
        markedRanges: MarkedTextManager.MarkedRanges?
    ) {
        lineFragments.removeAll()
        if let markedRanges {
            let mutableString = NSMutableAttributedString(attributedString: string)
            for markedRange in markedRanges.ranges {
                mutableString.addAttributes(markedRanges.attributes, range: markedRange)
            }
            self.string = mutableString
        } else {
            self.string = string
        }
        characters = self.string.string as NSString
        self.typesetter = CTTypesetterCreateWithAttributedString(self.string)
        generateLines(
            // wooloo patch: narrower than a line is tall, as before the editor has its width or beside a gutter that
            // leaves a few points, there is no room to wrap in: keep the line in one row. Upstream broke it after
            // every character, two million rows for a 2 MB line, laid out again once there was room. Upstream 0.12
            // sets a line as one empty row when the width is not positive.
            maxWidth: displayData.maxWidth >= displayData.estimatedLineHeight
                ? displayData.maxWidth : .greatestFiniteMagnitude,
            lineHeightMultiplier: displayData.lineHeightMultiplier,
            estimatedLineHeight: displayData.estimatedLineHeight,
            breakStrategy: breakStrategy
        )
    }

    // MARK: - Generate lines

    /// Generate line fragments.
    /// - Parameters:
    ///   - maxWidth: The maximum width the line can be.
    ///   - lineHeightMultiplier: The multiplier to apply to an empty line's height.
    ///   - estimatedLineHeight: The estimated height of an empty line.
    private func generateLines(
        maxWidth: CGFloat,
        lineHeightMultiplier: CGFloat,
        estimatedLineHeight: CGFloat,
        breakStrategy: LineBreakStrategy
    ) {
        guard let typesetter else { return }
        var lines: [TextLineStorage<LineFragment>.BuildItem] = []
        var height: CGFloat = 0
        if string.length == 0 {
            // Insert an empty fragment
            let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0))
            let fragment = LineFragment(
                ctLine: ctLine,
                width: 0,
                height: estimatedLineHeight/lineHeightMultiplier,
                descent: 0,
                lineHeightMultiplier: lineHeightMultiplier
            )
            lines = [.init(data: fragment, length: 0, height: fragment.scaledHeight)]
        } else {
            var startIndex = 0
            while startIndex < string.length {
                let lineBreak = suggestLineBreak(
                    using: typesetter,
                    strategy: breakStrategy,
                    startingOffset: startIndex,
                    constrainingWidth: maxWidth
                )
                let lineFragment = typesetLine(
                    range: NSRange(start: startIndex, end: lineBreak),
                    lineHeightMultiplier: lineHeightMultiplier
                )
                lines.append(.init(
                    data: lineFragment,
                    length: lineBreak - startIndex,
                    height: lineFragment.scaledHeight
                ))
                startIndex = lineBreak
                height = lineFragment.scaledHeight
            }
        }
        // Use an efficient tree building algorithm rather than adding lines sequentially
        lineFragments.build(from: lines, estimatedLineHeight: height)
    }

    /// Typeset a new fragment.
    /// - Parameters:
    ///   - range: The range of the fragment.
    ///   - lineHeightMultiplier: The multiplier to apply to the line's height.
    /// - Returns: A new line fragment.
    private func typesetLine(range: NSRange, lineHeightMultiplier: CGFloat) -> LineFragment {
        let ctLine = CTTypesetterCreateLine(typesetter!, CFRangeMake(range.location, range.length))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let height = ascent + descent + leading
        return LineFragment(
            ctLine: ctLine,
            width: width,
            height: height,
            descent: descent,
            lineHeightMultiplier: lineHeightMultiplier
        )
    }

    // MARK: - Line Breaks

    /// Suggest a line break for the given line break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - strategy: The strategy that determines a valid line break.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    private func suggestLineBreak(
        using typesetter: CTTypesetter,
        strategy: LineBreakStrategy,
        startingOffset: Int,
        constrainingWidth: CGFloat
    ) -> Int {
        switch strategy {
        case .character:
            return suggestLineBreakForCharacter(
                using: typesetter,
                startingOffset: startingOffset,
                constrainingWidth: constrainingWidth
            )
        case .word:
            return suggestLineBreakForWord(
                using: typesetter,
                startingOffset: startingOffset,
                constrainingWidth: constrainingWidth
            )
        }
    }

    /// Suggest a line break for the character break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    private func suggestLineBreakForCharacter(
        using typesetter: CTTypesetter,
        startingOffset: Int,
        constrainingWidth: CGFloat
    ) -> Int {
        var breakIndex: Int
        breakIndex = startingOffset + CTTypesetterSuggestClusterBreak(typesetter, startingOffset, constrainingWidth)
        guard breakIndex < string.length else {
            return breakIndex
        }
        // wooloo patch: compare UTF-16 units rather than a substring made for each row.
        if isCRLF(at: breakIndex - 1) {
            // Breaking in the middle of the clrf line ending
            return breakIndex + 1
        }
        return breakIndex
    }

    /// Suggest a line break for the word break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    private func suggestLineBreakForWord(
        using typesetter: CTTypesetter,
        startingOffset: Int,
        constrainingWidth: CGFloat
    ) -> Int {
        var breakIndex = startingOffset + CTTypesetterSuggestClusterBreak(typesetter, startingOffset, constrainingWidth)

        let isBreakAtEndOfString = breakIndex >= string.length

        let isNextCharacterCarriageReturn = checkIfLineBreakOnCRLF(breakIndex)
        if isNextCharacterCarriageReturn {
            breakIndex += 1
        }

        let canLastCharacterBreak = (breakIndex - 1 > 0 && ensureCharacterCanBreakLine(at: breakIndex - 1))

        if isBreakAtEndOfString || canLastCharacterBreak {
            // Breaking either at the end of the string, or on a whitespace.
            return breakIndex
        } else if breakIndex - 1 > 0 {
            // Try to walk backwards until we hit a whitespace or punctuation
            var index = breakIndex - 1

            while breakIndex - index < 100 && index > startingOffset {
                if ensureCharacterCanBreakLine(at: index) {
                    return index + 1
                }
                index -= 1
            }
        }

        return breakIndex
    }

    /// Ensures the character at the given index can break a line.
    /// - Parameter index: The index to check at.
    /// - Returns: True, if the character is a whitespace or punctuation character.
    private func ensureCharacterCanBreakLine(at index: Int) -> Bool {
        // wooloo patch: look the UTF-16 unit up in one set made once. Upstream made a substring and a
        // `CharacterSet` from it for each candidate and compared sets, most of the time spent wrapping long lines.
        // A lone surrogate is in neither set, as upstream's set of U+FFFD was not.
        guard let scalar = Unicode.Scalar(characters.character(at: index)) else { return false }
        return Self.breakingCharacters.contains(scalar)
    }

    /// wooloo patch: whitespace, newlines and punctuation, where a word wrap can break.
    private static let breakingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    /// wooloo patch: whether a `\r\n` starts at `index`.
    private func isCRLF(at index: Int) -> Bool {
        index >= 0 && index + 1 < characters.length
            && characters.character(at: index) == 0x0D && characters.character(at: index + 1) == 0x0A
    }

    /// Check if the break index is on a CRLF (`\r\n`) character, indicating a valid break position.
    /// - Parameter breakIndex: The index to check in the string.
    /// - Returns: True, if the break index lies after the `\n` character in a `\r\n` sequence.
    private func checkIfLineBreakOnCRLF(_ breakIndex: Int) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex + 1 <= string.length else {
            return false
        }
        return isCRLF(at: breakIndex - 1) // wooloo patch
    }

    deinit {
        lineFragments.removeAll()
    }
}

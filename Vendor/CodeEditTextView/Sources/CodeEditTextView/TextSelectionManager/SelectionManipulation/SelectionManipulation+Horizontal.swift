//
//  SelectionManipulation+Horizontal.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 5/11/24.
//

import Foundation

package extension TextSelectionManager {
    /// Extends a selection from the given offset determining the length by the destination.
    ///
    /// Returns a new range that needs to be merged with an existing selection range using `NSRange.formUnion`
    ///
    /// - Parameters:
    ///   - offset: The location to start extending the selection from.
    ///   - destination: Determines how far the selection is extended.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    ///   - decomposeCharacters: Set to `true` to treat grapheme clusters as individual characters.
    /// - Returns: A new range to merge with a selection.
    func extendSelectionHorizontal(
        from offset: Int,
        destination: Destination,
        delta: Int,
        decomposeCharacters: Bool = false
    ) -> NSRange {
        guard let string = textStorage?.string as NSString? else { return NSRange(location: offset, length: 0) }

        switch destination {
        case .character:
            return extendSelectionCharacter(
                string: string,
                from: offset,
                delta: delta,
                decomposeCharacters: decomposeCharacters
            )
        case .word:
            return extendSelectionWord(string: string, from: offset, delta: delta)
        case .line:
            return extendSelectionLine(string: string, from: offset, delta: delta)
        case .lineBoundary, .visualLine:
            let target = horizontalLineBoundary(from: offset, forward: delta > 0, visual: destination == .visualLine)
            return NSRange(start: min(offset, target.offset), end: max(offset, target.offset))
        case .document:
            if delta > 0 {
                return NSRange(start: offset, end: string.length)
            } else {
                return NSRange(location: 0, length: offset)
            }
        case .page: // Not a valid destination horizontally.
            return NSRange(location: offset, length: 0)
        }
    }

    // MARK: - Horizontal Methods

    /// Extends the selection by a single character.
    ///
    /// The range returned from this method can be longer than `1` character if the character in the extended direction
    /// is a member of a grapheme cluster.
    ///
    /// - Parameters:
    ///   - string: The reference string to use.
    ///   - offset: The location to start extending the selection from.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    ///   - decomposeCharacters: Set to `true` to treat grapheme clusters as individual characters.
    /// - Returns: The range of the extended selection.
    private func extendSelectionCharacter(
        string: NSString,
        from offset: Int,
        delta: Int,
        decomposeCharacters: Bool
    ) -> NSRange {
        let range = delta > 0 ? NSRange(location: offset, length: 1) : NSRange(location: offset - 1, length: 1)
        if delta > 0 && offset == string.length {
            return NSRange(location: offset, length: 0)
        } else if delta < 0 && offset == 0 {
            return NSRange(location: 0, length: 0)
        }

        return decomposeCharacters ? range : string.rangeOfComposedCharacterSequences(for: range)
    }

    /// Extends the selection by one "word".
    ///
    /// Words in this case begin after encountering an alphanumeric character, and extend until either a whitespace
    /// or punctuation character.
    ///
    /// - Parameters:
    ///   - string: The reference string to use.
    ///   - offset: The location to start extending the selection from.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    /// - Returns: The range of the extended selection.
    private func extendSelectionWord(string: NSString, from offset: Int, delta: Int) -> NSRange {
        var enumerationOptions: NSString.EnumerationOptions = .byCaretPositions
        if delta < 0 {
            enumerationOptions.formUnion(.reverse)
        }
        var rangeToDelete = NSRange(location: offset, length: 0)

        var hasFoundValidWordChar = false
        string.enumerateSubstrings(
            in: NSRange(location: delta > 0 ? offset : 0, length: delta > 0 ? string.length - offset : offset),
            options: enumerationOptions
        ) { substring, _, _, stop in
            guard let substring = substring else {
                stop.pointee = true
                return
            }

            if hasFoundValidWordChar && CharacterSet.punctuationCharacters
                .union(.whitespacesAndNewlines)
                .isSuperset(of: CharacterSet(charactersIn: substring)) {
                stop.pointee = true
                return
            } else if CharacterSet.alphanumerics.isSuperset(of: CharacterSet(charactersIn: substring)) {
                hasFoundValidWordChar = true
            }
            rangeToDelete.length += substring.count

            if delta < 0 {
                rangeToDelete.location -= substring.count
            }
        }

        return rangeToDelete
    }

    /// Resolves a physical or visual line boundary, preserving the trailing edge at a soft wrap.
    func horizontalLineBoundary(
        from offset: Int, forward: Bool, visual: Bool, affinity: TextSelection.VisualCaret? = nil
    ) -> (offset: Int, caret: TextSelection.VisualCaret?) {
        guard let layoutManager, let line = layoutManager.textLineForOffset(offset),
              let string = textStorage?.string as NSString?, !line.range.isEmpty else {
            return (offset, nil)
        }
        let end = contentEnd(of: line.range, in: string)
        guard visual else { return (forward ? end : line.range.location, nil) }

        if line.data.lineFragments.isEmpty {
            _ = layoutManager.rectForOffset(offset)
        }
        let lastUnit = line.range.max - 1
        let lookup = if let affinity, affinity.edge == .trailing, affinity.anchorOffset == offset - 1 {
            affinity.anchorOffset
        } else {
            min(offset, lastUnit)
        }
        guard let fragment = line.data.lineFragments.getLine(atOffset: lookup - line.range.location) else {
            return (offset, nil)
        }

        if forward {
            let fragmentEnd = line.range.location + fragment.range.max
            let target = min(fragmentEnd, end)
            // Keep the insertion point on this row when the same offset starts the next row.
            return (target, fragmentEnd < end ? .init(anchorOffset: target - 1, edge: .trailing) : nil)
        }

        let start = line.range.location + fragment.range.location
        let range = _extendSelectionLine(string: string, lineBound: start, offset: offset, delta: -1)
        return (range.location, nil)
    }

    private func contentEnd(of range: NSRange, in string: NSString) -> Int {
        let last = string.character(at: range.max - 1)
        if last == 0x0A, range.length >= 2, string.character(at: range.max - 2) == 0x0D {
            return range.max - 2
        }
        switch last {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
            return range.max - 1
        default:
            return range.max
        }
    }

    /// Extends the selection by one real line in the direction specified.
    ///
    /// If extending backwards, this method will return the beginning of the leading non-whitespace characters
    /// in the line. If the offset is located in the leading whitespace it will return the real line beginning.
    ///
    /// - Parameters:
    ///   - string: The reference string to use.
    ///   - offset: The location to start extending the selection from.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    /// - Returns: The range of the extended selection.
    private func extendSelectionLine(string: NSString, from offset: Int, delta: Int) -> NSRange {
        guard let line = layoutManager?.textLineForOffset(offset),
              let lineText = textStorage?.substring(from: line.range) else {
            return NSRange(location: offset, length: 0)
        }
        let lineBound = delta > 0
        ? line.range.max - (LineEnding(line: lineText)?.length ?? 0)
        : line.range.location

        return _extendSelectionLine(string: string, lineBound: lineBound, offset: offset, delta: delta)
    }

    /// Common code for `extendSelectionLine` and `extendSelectionVisualLine`
    private func _extendSelectionLine(
        string: NSString,
        lineBound: Int,
        offset: Int,
        delta: Int
    ) -> NSRange {
        var foundRange = NSRange(
            start: min(lineBound, offset),
            end: max(lineBound, offset)
        )
        let originalFoundRange = foundRange

        // Only do this if we're going backwards.
        if delta < 0 {
            foundRange = findBeginningOfLineText(string: string, initialRange: foundRange)
        }

        return foundRange.length == 0 ? originalFoundRange : foundRange
    }

    /// Finds the beginning of text in a line not including whitespace.
    /// - Parameters:
    ///   - string: The string to look in.
    ///   - initialRange: The range to begin looking from.
    /// - Returns: A new range to replace the given range for the line.
    private func findBeginningOfLineText(string: NSString, initialRange: NSRange) -> NSRange {
        var foundRange = initialRange
        string.enumerateSubstrings(in: foundRange, options: .byCaretPositions) { substring, _, _, stop in
            if let substring = substring as String? {
                if CharacterSet
                    .whitespacesAndNewlines.subtracting(.newlines)
                    .isSuperset(of: CharacterSet(charactersIn: substring)) {
                    foundRange.location += 1
                    foundRange.length -= 1
                } else {
                    stop.pointee = true
                }
            } else {
                stop.pointee = true
            }
        }
        return foundRange
    }
}

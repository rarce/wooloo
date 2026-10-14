//
//  TextLine.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import Foundation
import AppKit

/// Represents a displayable line of text.
public final class TextLine: Identifiable, Equatable {
    public let id: UUID = UUID()
    private var needsLayout: Bool = true
    var maxWidth: CGFloat?
    private(set) var typesetter: Typesetter = Typesetter()

    /// The line fragments contained by this text line.
    public var lineFragments: TextLineStorage<LineFragment> {
        typesetter.lineFragments
    }

    /// wooloo patch: the rows as laid out last, kept by ``setNeedsLayoutKeepingRows()`` until the line is laid out
    /// again or the next layout pass ends. The typesetter is kept, since its rows are removed when it goes away.
    private var dropped: Typesetter?

    /// Marks this line as needing layout and clears all typesetting data.
    public func setNeedsLayout() {
        needsLayout = true
        typesetter = Typesetter()
        dropped = nil // wooloo patch
    }

    /// wooloo patch: as ``setNeedsLayout()``, but keeps the rows for ``lastRow(atPosition:height:)``, for the line at the
    /// view's top when the highlighter applies a new font.
    func setNeedsLayoutKeepingRows() {
        let rows = typesetter.lineFragments.isEmpty ? dropped : typesetter
        setNeedsLayout()
        dropped = rows
    }

    /// wooloo patch: lets go of the rows ``setNeedsLayoutKeepingRows()`` kept.
    func dropKeptRows() {
        dropped = nil
    }

    /// wooloo patch: the row at `y` as laid out last, also after ``setNeedsLayoutKeepingRows()`` while those rows are
    /// still `height` tall: its first character in the line, and how far into the row `y` is, as a share of its height.
    func lastRow(atPosition y: CGFloat, height: CGFloat) -> (offset: Int, share: CGFloat)? {
        var rows = typesetter.lineFragments
        if rows.isEmpty, let dropped, abs(dropped.lineFragments.height - height) < 0.01 { rows = dropped.lineFragments }
        guard let row = rows.getLine(atPosition: y) else { return nil }
        return (row.range.location, row.height > 0 ? (y - row.yPos) / row.height : 0)
    }

    /// Determines if the line needs to be laid out again.
    /// - Parameter maxWidth: The new max width to check.
    /// - Returns: True, if this line has been marked as needing layout using ``TextLine/setNeedsLayout()`` or if the
    ///            line needs to find new line breaks due to a new constraining width.
    func needsLayout(maxWidth: CGFloat) -> Bool {
        needsLayout || maxWidth != self.maxWidth
    }

    /// Prepares the line for display, generating all potential line breaks and calculating the real height of the line.
    /// - Parameters:
    ///   - displayData: Information required to display a text line.
    ///   - range: The range this text range represents in the entire document.
    ///   - stringRef: A reference to the string storage for the document.
    ///   - markedRanges: Any marked ranges in the line.
    ///   - breakStrategy: Determines how line breaks are calculated.
    func prepareForDisplay(
        displayData: DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedTextManager.MarkedRanges?,
        breakStrategy: LineBreakStrategy
    ) {
        let string = stringRef.attributedSubstring(from: range)
        self.maxWidth = displayData.maxWidth
        typesetter.typeset(
            string,
            displayData: displayData,
            breakStrategy: breakStrategy,
            markedRanges: markedRanges
        )
        needsLayout = false
        dropped = nil // wooloo patch
    }

    public static func == (lhs: TextLine, rhs: TextLine) -> Bool {
        lhs.id == rhs.id
    }

    /// Contains all required data to perform a typeset and layout operation on a text line.
    struct DisplayData {
        let maxWidth: CGFloat
        let lineHeightMultiplier: CGFloat
        let estimatedLineHeight: CGFloat
    }
}

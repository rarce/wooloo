//
//  TextLayoutManager+Invalidation.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/24/24.
//

import Foundation

extension TextLayoutManager {
    /// Invalidates layout for the given rect.
    /// - Parameter rect: The rect to invalidate.
    public func invalidateLayoutForRect(_ rect: NSRect) {
        let top = viewTop
        for linePosition in lineStorage.linesStartingAt(rect.minY, until: rect.maxY) {
            setNeedsLayout(linePosition, top: top)
        }
        layoutLines()
    }

    /// Invalidates layout for the given range of text.
    /// - Parameter range: The range of text to invalidate.
    public func invalidateLayoutForRange(_ range: NSRange) {
        let top = viewTop
        for linePosition in lineStorage.linesInRange(range) {
            setNeedsLayout(linePosition, top: top)
        }

        layoutLines()
    }

    /// wooloo patch: the line the view's top is in keeps its rows until the next pass, so that the pass finds the row
    /// that was at the top, as when the highlighter applies a new font; the others drop theirs.
    private func setNeedsLayout(_ linePosition: TextLineStorage<TextLine>.TextLinePosition, top: CGFloat?) {
        if let top, linePosition.yPos < top, top < linePosition.yPos + linePosition.height {
            if lineKeepingRows !== linePosition.data { lineKeepingRows?.dropKeptRows() }
            linePosition.data.setNeedsLayoutKeepingRows()
            lineKeepingRows = linePosition.data
        } else {
            linePosition.data.setNeedsLayout()
        }
    }

    public func setNeedsLayout() {
        needsLayout = true
        visibleLineIds.removeAll(keepingCapacity: true)
    }
}

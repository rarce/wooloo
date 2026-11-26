//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

extension TextView {
    fileprivate typealias TextSelection = TextSelectionManager.TextSelection

    /// Scrolls the lowest selection to the visible rect if `scrollView` is not `nil`.
    public func scrollSelectionToVisible() {
        guard !layoutManager.isInTransaction else { return }
        guard scrollView != nil, let selection = getSelection() else {
            return
        }

        // There's a bit of a chicken-and-the-egg issue going on here. We need to know the rect to scroll to, but we
        // can't know the exact rect to make visible without laying out the text. Then, once text is laid out the
        // selection rect may be different again. To solve this, we loop until the frame doesn't change after a layout
        // pass and scroll to that rect.

        var lastFrame: CGRect = .zero
        // wooloo patch: at most 20 passes, in case the rect never settles (upstream has no limit).
        var passes = 0
        while passes < 20, let boundingRect = selectionManager.activeCaretRect(for: selection),
              lastFrame != boundingRect {
            passes += 1
            lastFrame = boundingRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            selectionManager.drawSelections(in: visibleRect)
            // wooloo patch: scroll inside the loop, as upstream does since 0.11.3. Scrolling lays out the lines that come
            // into view, which with wrapping grow taller than estimated and move the rect; scrolling once after the
            // loop left a far selection off screen.
            if lastFrame != .zero {
                scrollCaretToVisible(lastFrame)
            }
        }
    }

    /// Get the selection that should be scrolled to visible for the current text selection.
    /// - Returns: The the selection to scroll to.
    private func getSelection() -> TextSelection? {
        selectionManager
            .textSelections
            .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
            .first
    }

    /// Reveals an insertion edge in the text area beside the floating line-number gutter.
    public func scrollCaretToVisible(_ rect: CGRect, verticalPadding: CGFloat = 0) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        var target = rect.insetBy(dx: 0, dy: -verticalPadding)
        if !layoutManager.wrapLines {
            // The actual caret is at the origin, including for tabs and RTL glyphs.
            // The gutter covers the left edge of the clip view as it scrolls.
            let gutter = min(edgeInsets.left, max(0, clip.bounds.width - 2))
            target.origin.x = rect.origin.x - gutter
            target.size.width = gutter + 2
        }
        clip.scrollToVisible(target)
        scrollView.reflectScrolledClipView(clip)
    }
}

//
//  TextViewController+StyleViews.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/3/24.
//

import AppKit

extension TextViewController {
    package func generateParagraphStyle() -> NSMutableParagraphStyle {
        // swiftlint:disable:next force_cast
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.tabStops.removeAll()
        paragraph.defaultTabInterval = CGFloat(tabWidth) * fontCharWidth
        return paragraph
    }

    /// wooloo patch: rebuilds the paragraph style for the current font and tab width and applies it
    /// to the text and to typed text, so tabs stop every `tabWidth` spaces.
    package func applyParagraphStyle() {
        paragraphStyle = generateParagraphStyle()
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        textView.textStorage.addAttribute(.paragraphStyle, value: paragraphStyle,
                                          range: NSRange(location: 0, length: textView.textStorage.length))
        textView.layoutManager.setNeedsLayout()
    }

    /// Style the text view.
    package func styleTextView() {
        textView.selectionManager.selectionBackgroundColor = theme.selection
        textView.selectionManager.selectedLineBackgroundColor = getThemeBackground()
        textView.selectionManager.highlightSelectedLine = isEditable
        textView.selectionManager.insertionPointColor = theme.insertionPoint
        textView.typingAttributes = attributesFor(nil)
        applyParagraphStyle() // wooloo patch: also to text set before the style
    }

    /// Finds the preferred use theme background.
    /// - Returns: The background color to use.
    private func getThemeBackground() -> NSColor {
        if useThemeBackground {
            return theme.lineHighlight
        }

        if systemAppearance == .darkAqua {
            return NSColor.quaternaryLabelColor
        }

        return NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
    }

    /// Style the gutter view.
    package func styleGutterView() {
        gutterView.frame.origin.y = -scrollView.contentInsets.top
        gutterView.selectedLineColor = useThemeBackground ? theme.lineHighlight : systemAppearance == .darkAqua
        ? NSColor.quaternaryLabelColor
        : NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
        gutterView.highlightSelectedLines = isEditable
        gutterView.font = font.rulerFont
        gutterView.backgroundColor = useThemeBackground ? theme.background : .textBackgroundColor
        if self.isEditable == false {
            gutterView.selectedLineTextColor = nil
            gutterView.selectedLineColor = .clear
        }
    }

    /// Style the scroll view.
    package func styleScrollView() {
        guard let scrollView = view as? NSScrollView else { return }
        scrollView.drawsBackground = useThemeBackground
        scrollView.backgroundColor = useThemeBackground ? theme.background : .clear
        // wooloo patch: the gutter unclips its floating container, so the scroll view clips instead;
        // otherwise the gutter background draws over the views above the editor when scrolled.
        scrollView.clipsToBounds = true
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        if let contentInsets {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = contentInsets
        } else {
            scrollView.automaticallyAdjustsContentInsets = true
        }
        scrollView.contentInsets.bottom = (contentInsets?.bottom ?? 0) + bottomContentInsets
    }
}

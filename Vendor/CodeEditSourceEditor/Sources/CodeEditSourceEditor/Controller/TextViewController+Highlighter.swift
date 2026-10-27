//
//  TextViewController+Highlighter.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/14/23.
//

import AppKit
import SwiftTreeSitter

extension TextViewController {
    internal func setUpHighlighter() {
        if let highlighter {
            textView.removeStorageDelegate(highlighter)
            self.highlighter = nil
        }

        let highlighter = Highlighter(
            textView: textView,
            providers: highlightProviders,
            attributeProvider: self,
            language: language
        )
        textView.addStorageDelegate(highlighter)
        self.highlighter = highlighter
    }
}

extension TextViewController: ThemeAttributesProviding {
    public func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] {
        var syntaxFont = font
        if capture == .textTitle || capture == .textStrong || capture == .textStrongEmphasis {
            syntaxFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if capture == .textEmphasis || capture == .textStrongEmphasis {
            syntaxFont = NSFontManager.shared.convert(syntaxFont, toHaveTrait: .italicFontMask)
        }
        return [
            .font: syntaxFont,
            .foregroundColor: theme.colorFor(capture),
            .kern: textView.kern,
            // wooloo patch: tab stops every `tabWidth` spaces, which upstream builds but never applies.
            .paragraphStyle: paragraphStyle
        ]
    }
}

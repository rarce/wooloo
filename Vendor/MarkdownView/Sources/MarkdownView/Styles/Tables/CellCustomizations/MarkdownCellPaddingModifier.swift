//
//  MarkdownCellPaddingModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/20.
//

import SwiftUI

extension View {
    nonisolated func _markdownCellPadding(_ padding: MarkdownTableCellPadding) -> some View {
        modifier(MarkdownCellPaddingModifier(padding: padding))
    }
}

struct MarkdownCellPaddingModifier: ViewModifier {
    var padding: MarkdownTableCellPadding
    
    func body(content: Content) -> some View {
        // wooloo patch: one inset layout per cell instead of four nested layouts.
        // Keep the directional edges and safe-area behavior used by custom table styles.
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            content.safeAreaPadding(EdgeInsets(top: padding[.top], leading: padding[.leading],
                                               bottom: padding[.bottom], trailing: padding[.trailing]))
        } else {
            content
                .contentPadding(.top, padding[.top])
                .contentPadding(.bottom, padding[.bottom])
                .contentPadding(.leading, padding[.leading])
                .contentPadding(.trailing, padding[.trailing])
        }
    }
}

//
//  SearchHighlightModifier.swift
//  MarkdownView
//
//  wooloo patch: highlights find matches in rendered text and anchors top-level blocks.
//

import SwiftUI
import Markdown

/// Find matches to highlight in rendered text (wooloo patch).
public struct MarkdownSearchHighlight: Hashable, Sendable {
    public struct Match: Hashable, Sendable {
        /// UTF-16 range within the node's plain text.
        public let range: Range<Int>
        /// Position among all matches of the document.
        public let index: Int

        public init(range: Range<Int>, index: Int) {
            self.range = range
            self.index = index
        }
    }

    /// Matches by `Text` or `InlineCode` node, keyed by ``key(for:)``.
    public var matches: [String: [Match]]
    public var current: Int?
    public var color: Color
    public var currentColor: Color

    public init(matches: [String: [Match]], current: Int?, color: Color, currentColor: Color) {
        self.matches = matches
        self.current = current
        self.color = color
        self.currentColor = currentColor
    }

    /// A node's path from the document root, stable for documents parsed from the same text.
    public static func key(for markup: any Markup) -> String {
        var indices: [Int] = []
        var node: (any Markup)? = markup
        while let current = node, current.parent != nil {
            indices.append(current.indexInParent)
            node = current.parent
        }
        return indices.reversed().map(String.init).joined(separator: ".")
    }

    func apply(to string: String, of markup: any Markup, in attributed: inout AttributedString) {
        guard let matches = matches[Self.key(for: markup)] else { return }
        let length = string.utf16.count
        for match in matches where match.range.upperBound <= length {
            let lower = String.Index(utf16Offset: match.range.lowerBound, in: string)
            let upper = String.Index(utf16Offset: match.range.upperBound, in: string)
            guard let start = AttributedString.Index(lower, within: attributed),
                  let end = AttributedString.Index(upper, within: attributed) else { continue }
            attributed[start..<end].backgroundColor = match.index == current ? currentColor : color
        }
    }
}

/// Identifies a top-level block of the document for `ScrollViewReader` (wooloo patch).
public struct MarkdownBlockAnchor: Hashable, Sendable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

extension View {
    /// Highlights find matches in the rendered document (wooloo patch).
    nonisolated public func markdownSearchHighlight(_ highlight: MarkdownSearchHighlight?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.searchHighlight = highlight
        }
    }
}

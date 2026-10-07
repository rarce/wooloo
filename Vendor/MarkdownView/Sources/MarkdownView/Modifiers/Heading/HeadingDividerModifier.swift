//
//  HeadingDividerModifier.swift
//  MarkdownView
//
//  wooloo patch: draws a rule under headings, as GitHub does for h1 and h2.
//

import SwiftUI

/// A rule under headings of the given levels (wooloo patch).
public struct MarkdownHeadingDivider: Hashable, Sendable {
    public var levels: Set<Int>
    public var color: Color
    /// Space between the heading text and the rule.
    public var spacing: CGFloat

    public init(levels: Set<Int>, color: Color, spacing: CGFloat) {
        self.levels = levels
        self.color = color
        self.spacing = spacing
    }
}

struct MarkdownHeadingDividerEnvironmentKey: EnvironmentKey {
    static let defaultValue: MarkdownHeadingDivider? = nil
}

extension EnvironmentValues {
    var markdownHeadingDivider: MarkdownHeadingDivider? {
        get { self[MarkdownHeadingDividerEnvironmentKey.self] }
        set { self[MarkdownHeadingDividerEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Draws a one-point rule under headings of the given levels; nil draws none (wooloo patch).
    nonisolated public func markdownHeadingDivider(_ divider: MarkdownHeadingDivider?) -> some View {
        environment(\.markdownHeadingDivider, divider)
    }
}

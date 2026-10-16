//
//  MarkdownRendererConfiguration.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Foundation
import SwiftUI

struct MarkdownRendererConfiguration: Hashable, AllowingModifyThroughKeyPath, Sendable {
    var preferredBaseURL: URL?
    var componentSpacing: CGFloat = 8
    var blockSpacing: CGFloat = 8
    /// Build top-level blocks only as the containing ScrollView needs them (wooloo patch).
    var lazyBlocks = false
    
    var tintColors: [MarkdownTintableComponent : Color] = [:]
    var underlineLinks: Bool = false
    var listConfiguration: MarkdownListConfiguration = MarkdownListConfiguration()
    /// Find matches to highlight (wooloo patch).
    var searchHighlight: MarkdownSearchHighlight?

    func resolvedMarkdownURL(for destination: String) -> URL? {
        URL(string: destination, relativeTo: preferredBaseURL)
    }
}

// MARK: - SwiftUI Environment

struct MarkdownRendererConfigurationKey: EnvironmentKey {
    static let defaultValue: MarkdownRendererConfiguration = .init()
}

extension EnvironmentValues {
    var markdownRendererConfiguration: MarkdownRendererConfiguration {
        get { self[MarkdownRendererConfigurationKey.self] }
        set { self[MarkdownRendererConfigurationKey.self] = newValue }
    }
}

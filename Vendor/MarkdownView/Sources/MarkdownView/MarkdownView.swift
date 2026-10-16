//
//  MarkdownView.swift
//  MarkdownView
//

import SwiftUI
import Markdown

/// A view that renders markdown content.
public struct MarkdownView: View {
    private var content: MarkdownContent
    
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownMathContext) private var mathContext
    @Environment(\.markdownElementRenderers) private var elementRenderers
    @Environment(\.markdownFontGroup) private var fonts
    
    /// Creates a view that renders given markdown string.
    /// 
    /// - Parameter text: The markdown source to render.
    public init(_ text: String) {
        self.content = .rawText(text)
    }

    /// Creates a view that renders a parsed markdown result.
    ///
    /// - Parameter parseResult: The parsed markdown result to render.
    public init(_ parseResult: MarkdownParseResult) {
        self.content = .parsedDocument(parseResult)
    }
    
    public var body: some View {
        let parseResult = content.parse(
            with: MarkdownDocumentParsingOptions(
                mathContext: mathContext,
                elementRenderers: elementRenderers
            )
        )
        
        Group {
            if configuration.lazyBlocks {
                MarkdownDocumentBlocks(document: parseResult.document, configuration: configuration,
                                       mathContext: parseResult.mathContext, elementRenderers: elementRenderers)
            } else {
                MarkdownViewRenderer(configuration: configuration, mathContext: parseResult.mathContext,
                                     elementRenderers: elementRenderers)
                    .makeBody(for: parseResult.document)
            }
        }
        .font(fonts.body._swiftUIFont)
    }
}

// wooloo patch: do not wrap the lazy stack in MarkdownNodeView's fixedSize modifier,
// which asks for the whole document's ideal height and defeats deferred block layout.
private struct MarkdownDocumentBlocks: View {
    let document: Markdown.Document
    let configuration: MarkdownRendererConfiguration
    let mathContext: MarkdownMathContext?
    let elementRenderers: [MarkdownElementRendererRegistration]

    private struct Block: Identifiable {
        let markup: any Markup
        var id: MarkdownBlockAnchor { MarkdownBlockAnchor(index: markup.indexInParent) }
    }

    var body: some View {
        AnyView(LazyVStack(alignment: .leading, spacing: configuration.blockSpacing) {
            ForEach(document.children.map { Block(markup: $0) }) { block in
                content(for: block)
            }
        })
        .environment(\.markdownMathContext, mathContext)
        .environment(\.markdownElementRenderers, elementRenderers)
    }

    private func content(for block: Block) -> some View {
        var renderer = MarkdownViewRenderer(configuration: configuration, mathContext: mathContext,
                                            elementRenderers: elementRenderers)
        let node = renderer.visit(block.markup)
        // Keep the same per-block erasure and modifiers as visitDocument; only the stack is lazy.
        return MarkdownNodeView {
            node.modifier(MarkdownRevealSourceGesture(line: block.markup.range?.lowerBound.line))
                .id(block.id)
        }.body
    }

}

extension View {
    /// Defers top-level block construction until it is needed by a containing ScrollView.
    /// Blocks retain their source and find anchors; individual tables still lay out every row.
    nonisolated public func markdownLazyBlocks(_ enabled: Bool = true) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { $0.lazyBlocks = enabled }
    }
}

// MARK: - Preview

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
#Preview {
    ScrollView {
        MarkdownView(
            """
            # MarkdownView

            A view-based markdown renderer for SwiftUI.

            > Block quotes are useful for callouts and quoted prose.

            ## Features

            - Emphasis with **bold** and *italic* text
            - Links such as [MarkdownView](https://github.com/liyanan2004/MarkdownView)
            - Inline code like `MarkdownText("Hello")`

            ```swift
            MarkdownView("Hello **World**")
            ```
            """
        )
        .padding()
    }
    .markdownLinksUnderlined()
    .scrollBounceBehavior(.basedOnSize)
    #if os(macOS) || os(iOS)
    .textSelection(.enabled)
    #endif
}

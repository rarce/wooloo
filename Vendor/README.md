# CodeEdit editor packages

These packages are copies of the upstream `Sources/` trees, with their MIT licenses:

| Package | Version | Upstream commit |
| --- | --- | --- |
| [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) | 0.9.1 | `b0688fa59fb8060840fb013afb4d6e6a96000f14` |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) | 0.7.7 | `509d7b2e86460e8ec15b0dd5410cbc8e8c05940f` |

Their source files are unchanged. The local `Package.swift` files keep the runtime dependencies and omit test targets and SwiftLint build plugins. Those plugins download a separate binary and are unnecessary when building xherdr. Update the versions together after checking the editor API and running an xherdr build.

# Markdown preview packages

| Package | Version | Upstream commit | License |
| --- | --- | --- | --- |
| [MarkdownView](https://github.com/LiYanan2004/MarkdownView) | 3.0.0 | `6f452b55635246224a3329362e4e11cd3d592a30` | MIT |
| [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift) | 1.0.4 | `6a23a29e91af8f5b3e9fc09945332ca193bd69ec` | MIT |

`MarkdownView/Sources/MarkdownView/Documentation.docc` is omitted. Source changes, marked "xherdr patch":

- MarkdownView: `markdownBlockSpacing(_:)` sets the spacing between top-level blocks, which upstream fixes at 8 pt.
- MarkdownView: `markdownSearchHighlight(_:)` colors find matches in `Text` and `InlineCode` nodes (`Modifiers/SearchHighlightModifier.swift`), and each top-level block carries a `MarkdownBlockAnchor` id so find can scroll to it. Because of the anchors, adjacent paragraphs are separate views spaced by the block spacing instead of one text joined with blank lines.
- BeautifulMermaid: the AppKit paths in `ImageRenderer.swift` flip the bitmap context before drawing; upstream renders diagrams upside down on macOS.

The local `Package.swift` files drop test targets, examples, and MarkdownView's default `LaTeX` trait, so SwiftMath and its ~7 MB of math fonts are not linked and `ENABLE_MATH_RENDERING` stays undefined.

Remote runtime dependencies resolve through Swift Package Manager: swift-markdown and RichText (MarkdownView), Highlightr (MarkdownView, highlight.js under BSD-3-Clause), and [elk-swift](https://github.com/lukilabs/elk-swift) (BeautifulMermaid). elk-swift is licensed under EPL-2.0: linking it is fine, but modified elk-swift source files must be published under EPL-2.0, and its license notice must ship with xherdr.

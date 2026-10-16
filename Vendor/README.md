# CodeEdit editor packages

These packages are copies of the upstream `Sources/` trees, with their MIT licenses:

| Package | Version | Upstream commit |
| --- | --- | --- |
| [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) | 0.9.1 | `b0688fa59fb8060840fb013afb4d6e6a96000f14` |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) | 0.7.7 | `509d7b2e86460e8ec15b0dd5410cbc8e8c05940f` |

Their source files are unchanged except for these changes in CodeEditSourceEditor, marked "wooloo patch":

- `styleScrollView()` clips the scroll view, because `GutterView` turns off clipping on its floating container and its background otherwise covers the tabs and header above the editor when the text scrolls.
- `GutterView.lineChanges` draws Git change bars (added, modified, deleted, staged as outlines) at the gutter's leading edge, and `TextViewController.gutterView` is public so the app can set them.
- Tabs stop every `tabWidth` spaces: `attributesFor` includes the paragraph style upstream builds but never applies, and `applyParagraphStyle()` rebuilds it and sets it on the text when the view loads and when the font or tab width changes. Upstream draws tabs at AppKit's default 28 pt stops.

And in CodeEditTextView, for multiple cursors (`wooloo/EditorMultiCursor.swift` adds the commands):

- Option-click adds a cursor, or removes the selection under it when there are several (`TextView+Mouse.swift`).
- `TextSelectionManager.didReplaceCharacters` shifts later selections by the change in length and keeps untouched selections. Upstream shifted by the replacement length and collapsed every selection, which misplaced cursors when typing over several selections.
- An edit at several cursors is one undo step (`TextView+ReplaceCharacters.swift`).
- Copy writes the selections joined by newlines plus a `dev.wooloo.editor.selections` list; paste with as many cursors puts one piece at each (`TextView+CopyPaste.swift`).

And in CodeEditTextView, for line wrapping:

- `TextLayoutManager.layoutLine` returns the whole line's height, as upstream does since 0.10.0, while still placing views only for the rows inside the layout rect; a line that stays visible gets views for its rows as they scroll in (`placeFragmentViews`). It returned the height of the rows it placed, so a wrapped line starting above the rect got part of its height; the pass then moved the scroll position by the difference, which laid out again from inside the same line, until the stack overflowed. Upstream places every row instead, which for a 2 MB minified line means tens of thousands of views.
- `scrollSelectionToVisible()` scrolls on each pass of its loop rather than once after it, as upstream does since 0.11.3, so a far selection lands on screen although the wrapped lines scrolled past grow taller than estimated. It stops after 20 passes; upstream has no limit.
- `TextLayoutManager.layoutLines` keeps the row at the top when lines rewrap to another width (a resize, a sidebar, Markdown's split view, the width settling after a restore) or wrapping is turned on or off: at the start of the pass that rewraps (or the first pass after the toggle) it notes the character at the top and how far into its row the view starts, and after the pass scrolls back to it, again while the lines that come into view move it, at most 20 times (`keepTop(_:)`); the anchor is not kept beyond that pass. The same character is kept across further widths while it is still at the top and the text is not edited or replaced, so going to another width and back does not drift to the start of a row. Upstream left the top wherever the rewrapped lines above it pushed it.
- `TextLayoutManager.layoutLines` moves the view by how much every line above its top changed height in a pass (the view's top, also in a pass over another rect, as Shift-Page Up or Down makes), not only the line starting above the layout rect (350 points above the view), as upstream does; for the line the top is in, so that the row that was at the top is there again, as far into it in proportion to its height, or, when the line has no rows from before (an estimated height), so that the same share of the line stays above the top. When the highlighter's attribute change (a new font) invalidates the line the view's top is in, that line keeps the rows it drops (the typesetter, whose rows go away with it) until the next layout pass, one line at a time, and the pass uses them while they add up to the line's height (`TextLine.setNeedsLayoutKeepingRows`, `lastRow`); other lines, and a wrapping toggle, drop theirs as before. The passes those adjustments cause adjust from where the view was meant to be, not where the scroll view put it, aligned to the display's pixels, so on a 1x display the half points do not add up. Upstream let the lines between the layout rect and the top move the text in view: after a font or line height change, or scrolling up through several wrapped lines not laid out yet at a time.
- Turning wrapping on or off gives every line the estimated height again and drops the layout of those laid out (`TextLineStorage.resetHeights`, one pass over the tree without typesetting). Upstream kept the heights lines were laid out at until they came into view, so after turning wrapping off the document was taller than it is.
- The typesetter keeps a line in one row when the width is less than a line is tall, as before the editor has its width or beside a gutter that leaves a few points, whatever the line starts with; upstream broke it after every character, two million rows for a 2 MB line, laid out again once there was room (upstream 0.12 sets a line as one empty row when the width is not positive). It looks break candidates up as UTF-16 units in one character set made once, rather than making a substring and a `CharacterSet` for each. Wrapping a 2 MB single line took about 15 s on the main thread, and takes about 0.1 s.

The local `Package.swift` files keep the runtime dependencies and omit test targets and SwiftLint build plugins. Those plugins download a separate binary and are unnecessary when building wooloo. Update the versions together after checking the editor API and running an wooloo build.

# Markdown preview packages

| Package | Version | Upstream commit | License |
| --- | --- | --- | --- |
| [MarkdownView](https://github.com/LiYanan2004/MarkdownView) | 3.0.0 | `6f452b55635246224a3329362e4e11cd3d592a30` | MIT |
| [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift) | 1.0.4 | `6a23a29e91af8f5b3e9fc09945332ca193bd69ec` | MIT |

`MarkdownView/Sources/MarkdownView/Documentation.docc` is omitted. Source changes, marked "wooloo patch":

- MarkdownView: `markdownBlockSpacing(_:)` sets the spacing between top-level blocks, which upstream fixes at 8 pt.
- MarkdownView: `markdownSearchHighlight(_:)` colors find matches in `Text` and `InlineCode` nodes (`Modifiers/SearchHighlightModifier.swift`), and each top-level block carries a `MarkdownBlockAnchor` id so find can scroll to it. Because of the anchors, adjacent paragraphs are separate views spaced by the block spacing instead of one text joined with blank lines.
- MarkdownView: `markdownHeadingDivider(_:)` draws a rule under headings of chosen levels (`Modifiers/Heading/HeadingDividerModifier.swift`, applied in `MarkdownHeading`), for the GitHub-style document preview.
- MarkdownView: `markdownTaskToggle(_:)` makes task list checkboxes buttons that report the item's 1-based source line and new state, and `markdownRevealSource(_:)` reports double-clicks on top-level blocks with their first line (`Modifiers/SourceActionsModifier.swift`, applied in `MarkdownList` and `MarkdownViewRenderer.visitDocument`). The host edits the source; the renderer stays read-only.
- MarkdownView: `markdownLazyBlocks()` lets the preview construct top-level blocks as they enter its scroll view, retaining their find anchors and source-line actions. Source-action monitors ignore hidden/clipped views and handle each event once, including when lazy layout keeps duplicate background views alive. Other package consumers keep eager rendering by default.
- MarkdownView: the built-in GitHub table draws its row backgrounds and grid in canvases from cell anchors, retaining native text cells and keeping each table’s geometry independent. Unstyled default tables skip cell geometry; custom table decorations retain their original preference path. `scripts/markdown-bench.sh` measures first render, resize, cached drawing and scrolling, and the view snapshots guard table layout, wrapping and row colors.
- MarkdownView: the `AnyShapeStyle` identity comparison keeps both unsafe buffer borrows alive and compares their bytes directly; upstream returned expired buffers and compared hashes, which could treat different colors as equal and suppress style updates.
- BeautifulMermaid: the AppKit paths in `ImageRenderer.swift` flip the bitmap context before drawing; upstream renders diagrams upside down on macOS.

The local `Package.swift` files drop test targets, examples, and MarkdownView's default `LaTeX` trait, so SwiftMath and its ~7 MB of math fonts are not linked and `ENABLE_MATH_RENDERING` stays undefined.

Remote runtime dependencies resolve through Swift Package Manager: swift-markdown and RichText (MarkdownView), Highlightr (MarkdownView, highlight.js under BSD-3-Clause), and [elk-swift](https://github.com/lukilabs/elk-swift) (BeautifulMermaid). elk-swift is licensed under EPL-2.0: linking it is fine, but modified elk-swift source files must be published under EPL-2.0, and its license notice must ship with wooloo.

# Notices

Herdr 0.9.3 is bundled as a universal macOS helper. `scripts/bundle-herdr.sh` downloads the pinned official release assets, checks their SHA-256 hashes, combines the Intel and Apple Silicon binaries, and signs the helper before the app is signed. The binary cache is under the ignored `build/herdr` directory; `Vendor/Herdr/LICENSE` retains its Apache-2.0 license. Update the script's hashes and `HerdrRuntimePaths.version` together when upgrading the runtime.

`THIRD_PARTY_NOTICES.txt` at the repository root collects the licenses of every package above, their SwiftPM dependencies, and the tree-sitter grammars built into CodeEditLanguages. It is copied into the app bundle and opened from wooloo → Third-Party Notices. After changing a dependency, build wooloo and run `scripts/third-party-notices.py`.

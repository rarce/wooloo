# Local patch validation

This inventory complements [README.md](README.md), which records pinned versions and describes the patches. It identifies existing checks, not a guarantee that every behavior is covered. Snapshot comparisons are excluded from CI and depend on the installed fonts; benchmarks require their opt-in scripts.

The upstream column is a local assessment, not a report of current upstream status. No upstream issue or PR was opened for this inventory. Before contributing or upgrading, compare the pinned sources with the intended upstream revision; historical version references in README are not enough to decide that a patch can be removed.

## Editor

`MC` below means [EditorMultiCursorTests](../woolooTests/EditorMultiCursorTests.swift); `VS` means [ViewSnapshotTests](../woolooTests/ViewSnapshotTests.swift). Method names identify concrete checks within those suites.

| Local patch | Existing validation and gaps | Upstream assessment |
| --- | --- | --- |
| Native text rasterization and device-pixel baselines | Editor and gutter inherit AppKit smoothing instead of the private smoothing-style override; baselines are rounded in the drawing context’s device space. Visual comparison across 1x/2x displays remains manual. | Local appearance policy; preserve when updating vendors. |
| Scroll-view clipping | VS `testDocumentEditor`, `testMainWindowEditing` are indirect visual coverage; no dedicated clipping regression identified. | Small correctness candidate after a direct regression. |
| Gutter change bars and public accessor | [EditorLineChangesTests](../woolooTests/EditorLineChangesTests.swift): `testRecreatedSplitEditorRestoresCachedGutterColorsAndChanges`, `testStagedHunksAreMarked`. | Reusable feature requiring API discussion. |
| Tab stops and paragraph style | MC `testTheEditorDrawsTabsEveryTabWidthSpacesForEveryFontSize`. | Focused correctness candidate. |
| Vertical anchor geometry and layout reuse | MC `testRevealingAnAlreadyLaidOutWrappedLineReusesItsRows`; `scripts/editor-bench.sh` measures large-line cost. | Performance candidate; include benchmark evidence. |
| Bidirectional block geometry and selection fills | MC `testOptionDragSelectsScreenColumnsInRightToLeftRowsWithAndWithoutWrapping`, `testOptionDragAcrossMixedDirectionsKeepsDisjointRangesAndUndo`, `testBidirectionalBlockKeepsWholeEmojiCombiningMarksAndLigatureCarets`, `testBidirectionalVerticalBlockIncludesEmptyRowsAtTheLeftEdge`, `testVerticalRTLBlockPreservesCaretsOnTheirSoftWrappedRows`, `testVerticalMixedDirectionBlockPreservesSecondaryCaretEdgesAndHistory`. | Preserve Core Text caret affinities, grapheme boundaries and disjoint screen intervals. |
| Option-click adds/removes cursors | No dedicated test of the vendored add/remove behavior identified; app Option-drag tests are not equivalent. | Add a direct regression before proposing the feature. |
| Selection offsets and multi-cursor undo grouping | MC `testCommandDTwiceThenTypingReplacesBothOccurrencesAsOneUndoStep`, `testAddCursorBelowThenTypeOnEachLine`. | Correctness candidates with existing behavioral checks. |
| Multi-selection clipboard | MC `testCopyingSelectionsPastesOnePieceAtEachCursor`. | Reusable feature; generalize the wooloo-specific pasteboard identifier. |
| Whole wrapped-line height and visible fragment placement | MC `testALongWrappedLineHasViewsOnlyForTheRowsAroundTheViewAndDrawsEveryRowOnScreen`. | Compare upstream's height fix separately from viewport-only placement. |
| Iterative reveal and bounded passes | MC `testRevealingALineScrollsItOnScreenInWrappedText`, `testAFindMatchTheFindBarStepsToIsOnScreenInWrappedText`. | Compare upstream reveal behavior and the local iteration bound separately. |
| Top-row preservation through hidden edits and grouped undo/redo | MC `testAnInsertionInHiddenWrappedRowsKeepsTheTopThroughUndoAndRedo`, `testMultipleHiddenWrappedEditsKeepTheTopAcrossGroupedUndoAndRedo`, `testASkippedLayoutKeepsTheHiddenEditAnchorUntilTheOuterTransactionEnds`, `testScrollingAwayAndBackCancelsAHiddenEditAnchorWaitingForLayout`, `testCallerManagedTransactionsPublishFinalSelectionsAndTextOnceIncludingUndo`; existing resize/wrapping/session tests. | Document-anchor mapping, transaction boundaries and explicit cancellation rules must remain together. |
| Top-row preservation across resize and wrapping | MC `testAWrappedEditorKeepsTheRowAtTheTopWhenItsWidthChanges`, `testTurningWrappingOffAndOnAtOnceKeepsTheRowAtTheTop`. | Candidate with substantial layout semantics to preserve. |
| Height compensation and retained old rows | MC `testChangingTheFontKeepsTheRowAtTheTop`, `testChangingTheLineHeightKeepsTheRowAtTheTop`, `testScrollingUpSeveralRowsAtATimeThroughWrappedLinesNotLaidOutKeepsTheTextInPlace`. | Candidate requiring scroll and selection review. |
| Height reset when wrapping toggles | MC `testTurningWrappingOffOrOnKeepsTheRowAtTheTopAndEstimatesTheOtherLinesAgain`. | Focused correctness candidate. |
| Narrow-width typesetting and break lookup | MC `testAnEditorWithNoRoomToWrapInKeepsALineInOneRow`, `testATwoMegabyteLineWrapsAtTheEditorsWidth`, `testWrappedRowsBreakAfterWhitespaceOrPunctuationAndKeepCRLFTogether`, `testResizingPreservesUnicodeRowsAndAttributesAgainstFreshLayout`, `testReflowMatchesFreshLayoutAfterEditsUndoAndMarkedTextChanges`. | Correctness/performance candidate. |
| Deferred fragment UUID allocation | `scripts/editor-bench.sh` measures first render, edit and resize of a 2 MB wrapped line; MC `testALongWrappedLineHasViewsOnlyForTheRowsAroundTheViewAndDrawsEveryRowOnScreen`, `testResizingPreservesUnicodeRowsAndAttributesAgainstFreshLayout`, `testReflowMatchesFreshLayoutAfterEditsUndoAndMarkedTextChanges` guard visible rows and exact layout. | Measured edit and resize improvement; preserve stable identities when first accessed. See `docs/perf/README.md`. |
| Highlight-provider replacement identity | [EditorSyntaxTests](../woolooTests/EditorSyntaxTests.swift): `testChangingConfigurationSyntaxRetainsTextViewSelectionAndUndoHistory`, `testSwitchingFromConfigurationToTagSyntaxRestoresClosingTagsAndNewlines`. | Reusable correctness/API candidate. |
| JSON capture mapping | [DiffHighlighterTests](../woolooTests/DiffHighlighterTests.swift): `testJSONKeysAndLiteralsHaveColors`, `testPaletteMapsCapturesToThemeColors`. | Small correctness candidate. |

### Text rendering rationale

The editor and gutter use Core Text in AppKit's drawing context. Their local patch removes
`ContextSetHiddenSmoothingStyle` and forced smoothing/quantization overrides, retaining native
rasterization and fractional glyph placement. Baseline rounding uses device coordinates rather
than whole logical points, including the view's translation at Retina scales. No custom glyph
atlas, bitmap scaling, synthetic stroke thickening, or gamma adjustment is introduced.

References reviewed on 2026-10-22:

- [Zed's rendering architecture](https://zed.dev/blog/videogame): Core Text shaping/rasterization and subpixel glyph variants, composed with a GPU atlas.
- [VS Code terminal appearance](https://code.visualstudio.com/docs/terminal/appearance): GPU acceleration targets frame cost; fonts, ligatures and custom terminal glyphs are separate concerns.
- [Ghostty configuration](https://ghostty.org/docs/config/reference): font fallbacks, optional stroke thickening and alpha-blending policy affect appearance independently.

The app now uses the terminal's font descriptor for code at the configured code size, including
SwiftUI diffs and search snippets so measured widths and displayed glyphs agree. UI labels retain
the system UI font. Cross-display visual QA is still needed on both 1x and 2x hardware.

## Markdown and Mermaid

| Local patch | Existing validation and gaps | Upstream assessment |
| --- | --- | --- |
| Block spacing and heading dividers | VS `testMarkdownPreview`, `testMarkdownPreviewDocument`; indirect visual coverage. | Optional styling APIs. |
| Find highlighting and block anchors | [DocumentFindTests](../woolooTests/DocumentFindTests.swift) checks rendered-text matching; `MarkdownPreviewRenderingTests.testFindScrollsToATableOutsideTheInitialViewport` in [MarkdownTableBenchmarks.swift](../woolooTests/MarkdownTableBenchmarks.swift) checks scrolling. These do not directly assert rendered highlight colors. | Reusable API; add direct visual assertions if changing drawing. |
| Task toggles and source reveal | `MarkdownPreviewInteractionTests.testClickingACheckboxTogglesItsLine` and `testDoubleClickingABlockRevealsItsLine` in [WorkspaceTreeTests.swift](../woolooTests/WorkspaceTreeTests.swift), plus task source-line parsing tests there. | Reusable callback API. |
| Lazy blocks and source-action monitors | Offscreen table find test above and existing interaction tests. No dedicated hidden/duplicate-monitor regression identified. | Candidate after closing that event-delivery gap. |
| Synchronous plain-text rendering | `MarkdownTableBenchmarks.testPreviewRendering` and VS Markdown snapshots. No dedicated inline-HTML cancellation/input-change regression identified. | Performance candidate; protect the asynchronous HTML path separately. |
| Canvas-backed tables | VS `testMarkdownTables`, `testMarkdownTablesDocument`; `scripts/markdown-bench.sh`. | Performance candidate; retain custom-decoration behavior. |
| `AnyShapeStyle` buffer lifetime and comparison | `MarkdownPreviewRenderingTests.testDifferentShapeStylesAreNotEqual` in [MarkdownTableBenchmarks.swift](../woolooTests/MarkdownTableBenchmarks.swift). | Prioritize as a small correctness candidate. |
| Mermaid macOS bitmap orientation | No dedicated orientation regression identified. | Add an orientation check before contributing or removing the fix. |

## Updating a dependency

1. Compare each applicable patch with the proposed upstream revision and record whether it remains, is adapted, or is removed because equivalent behavior is verified.
2. Run the mapped behavioral suites and build the app. Run the relevant opt-in benchmark for performance changes, and visual comparisons for layout changes.
3. Keep gaps above explicit; passing an unrelated test is not coverage for the missing behavior.
4. Update pinned versions, this inventory, README, and license notices together. Record upstream issue/PR links only when they actually exist.

Manifest changes that omit tests, plugins, examples, or default LaTeX support are application packaging choices, not automatically upstream contribution candidates.

//
//  MarkdownTableCellStyleTransformer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/18.
//

import SwiftUI

struct MarkdownTableStylePreferenceSynchronizer: ViewModifier {
    var row: Int
    var column: Int
    
    @Environment(\.markdownTableStyle) private var tableStyle
    @Environment(\.markdownTableUsesCellAnchors) private var usesCellAnchors
    @Environment(\.markdownTableCellBackgroundStyle) private var cellBackgroundStyle
    @Environment(\.markdownTableCellBackgroundShape) private var cellBackgroundShape
    @Environment(\.markdownTableCellOverlayContent) private var overlayContent
    
    @Environment(\.markdownTableRowBackgroundStyle) private var rowBackgroundStyle
    @Environment(\.markdownTableRowBackgroundShape) private var rowBackgroundShape
    
    // wooloo patch: plain tables need no geometry; GitHub tables resolve their cell
    // anchors together instead of running a GeometryReader and two style reductions per cell.
    func body(content: Content) -> some View {
        if usesCellAnchors {
            content.anchorPreference(key: MarkdownTableCellBoundsPreference.self, value: .bounds) {
                [MarkdownTableCellStyle.Position(column: column, row: row): $0]
            }
        } else if cellBackgroundStyle != nil || overlayContent != nil || rowBackgroundStyle != nil
            || !(tableStyle is DefaultMarkdownTableStyle) {
            content.overlay {
                GeometryReader { proxy in
                    let rect = proxy.frame(in: .named(MarkdownTable.CoordinateSpaceName))
                    Rectangle()
                        .fill(.clear)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .transformPreference(
                            MarkdownTableRowStyleCollectionPreference.self
                        ) { rowStyleCollection in
                            let position = MarkdownTableRowStyle.Position(
                                column: column,
                                row: row
                            )
                            var tableRowStyle = MarkdownTableRowStyle(
                                position: position,
                                minY: rect.minY,
                                maxY: rect.maxY
                            )
                            tableRowStyle.backgroundStyle = rowBackgroundStyle
                            tableRowStyle.backgroundShape = rowBackgroundShape
                            rowStyleCollection[position] = tableRowStyle
                        }
                        .transformPreference(
                            MarkdownTableCellStyleCollectionPreference.self
                        ) { styleCollection in
                            let position = MarkdownTableCellStyle.Position(
                                column: column,
                                row: row
                            )
                            var tableCellStyle = MarkdownTableCellStyle(
                                position: position,
                                rect: rect
                            )
                            tableCellStyle.backgroundStyle = cellBackgroundStyle
                            tableCellStyle.backgroundShape = cellBackgroundShape
                            tableCellStyle.overlayContent = overlayContent
                            styleCollection[tableCellStyle.position] = tableCellStyle
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        } else {
            content
        }
    }
}

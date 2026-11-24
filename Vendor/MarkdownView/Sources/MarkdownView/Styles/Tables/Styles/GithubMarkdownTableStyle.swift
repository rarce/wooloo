//
//  GithubMarkdownTableStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import SwiftUI

/// A markdown table style that matches the style of table in GitHub.
public struct GithubMarkdownTableStyle: MarkdownTableStyle {
    public func makeBody(configuration: Configuration) -> some View {
        GithubMarkdownTable(
            configuration: configuration
        )
    }
}

extension MarkdownTableStyle where Self == GithubMarkdownTableStyle {
    /// A markdown table style that matches the style of table in GitHub.
    @preconcurrency
    @MainActor
    static public var github: GithubMarkdownTableStyle { .init() }
}

fileprivate struct GithubMarkdownTable: View {
    var configuration: MarkdownTableStyleConfiguration
    
    init(configuration: MarkdownTableStyleConfiguration) {
        self.configuration = configuration
    }
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.markdownTableCellBackgroundStyle) private var cellBackgroundStyle
    
    /* Spacing values derived from GitHub's CSS table styles */
    private var horizontalSpacing: CGFloat = 13
    private var verticalSpacing: CGFloat = 6
    private var backgroundColor: Color {
        if colorScheme == .dark {
            Color(red: 14 / 255, green: 17 / 255, blue: 22 / 255)
        } else {
            Color(red: 255 / 255, green: 255 / 255, blue: 255 / 255)
        }
    }
    private var borderColor: Color {
        if colorScheme == .dark {
            Color(red: 61 / 255, green: 68 / 255, blue: 67 / 255)
        } else {
            Color(red: 209 / 255, green: 217 / 255, blue: 224 / 255)
        }
    }
    private var alternativeRowColor: Color {
        if colorScheme == .dark {
            Color(red: 21 / 255, green: 27 / 255, blue: 35 / 255)
        } else {
            Color(red: 246 / 255, green: 248 / 255, blue: 250 / 255)
        }
    }
    
    // wooloo patch: keep the custom cell-background path, but draw the built-in
    // backgrounds and grid together, using cell bounds in table-local coordinates.
    var body: some View {
        if cellBackgroundStyle != nil {
            styledCells
        } else {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                configuration.table.header
                ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { _, row in
                    row
                }
            }
            .environment(\.markdownTableMeasuresCellBounds, true)
            .markdownTableCellPadding(.vertical, verticalSpacing)
            .markdownTableCellPadding(.horizontal, horizontalSpacing)
            .backgroundPreferenceValue(MarkdownTableCellBoundsPreference.self) { rects in
                Canvas { context, size in
                    let bounds = MarkdownTableDrawingBounds(rects: rects, width: size.width)
                    for row in bounds.rows {
                        let color = row.index > 0 && row.index.isMultiple(of: 2) ? alternativeRowColor : backgroundColor
                        context.fill(Path(row.rect), with: .color(color))
                    }
                    var grid = Path()
                    for rect in bounds.cells {
                        // SwiftUI shapes align their layout bounds to display pixels.
                        // Do the same before stroking in Canvas, especially after text wrapping.
                        let left = (rect.minX * displayScale).rounded() / displayScale
                        let top = (rect.minY * displayScale).rounded() / displayScale
                        let right = (rect.maxX * displayScale).rounded() / displayScale
                        let bottom = (rect.maxY * displayScale).rounded() / displayScale
                        grid.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top)
                            .insetBy(dx: 0.5, dy: 0.5))
                    }
                    context.stroke(grid, with: .color(borderColor.opacity(0.5)), lineWidth: 1)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay {
                Rectangle().strokeBorder(borderColor).opacity(0.5).allowsHitTesting(false)
            }
        }
    }

    private var styledCells: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            configuration.table.header

            ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { (index, row) in
                let backgroundStyle = index % 2 == 0 ? AnyShapeStyle(backgroundColor) : AnyShapeStyle(alternativeRowColor)
                row
                    .markdownTableRowBackgroundStyle(backgroundStyle)
            }
        }
        .markdownTableRowBackgroundStyle(backgroundColor)
        .markdownTableCellOverlay {
            Rectangle()
                .strokeBorder(borderColor)
                .opacity(0.5)
        }
        .markdownTableCellPadding(.vertical, verticalSpacing)
        .markdownTableCellPadding(.horizontal, horizontalSpacing)
        .overlay {
            Rectangle()
                .strokeBorder(borderColor)
                .opacity(0.5)
        }
    }
}

// Cell positions are relative to the table, so scrolling does not change the decoration input.
private struct MarkdownTableMeasuresCellBoundsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownTableMeasuresCellBounds: Bool {
        get { self[MarkdownTableMeasuresCellBoundsKey.self] }
        set { self[MarkdownTableMeasuresCellBoundsKey.self] = newValue }
    }
}

struct MarkdownTableCellBoundsPreference: PreferenceKey {
    static var defaultValue: [MarkdownTableCellStyle.Position: CGRect] { [:] }

    static func reduce(value: inout [MarkdownTableCellStyle.Position: CGRect],
                       nextValue: () -> [MarkdownTableCellStyle.Position: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct MarkdownTableDrawingBounds {
    var rows: [(index: Int, rect: CGRect)] = []
    var cells: [CGRect] = []

    init(rects: [MarkdownTableCellStyle.Position: CGRect], width: CGFloat) {
        var columns: [Int: CGRect] = [:]
        var rowBounds: [Int: CGRect] = [:]
        for (position, rect) in rects {
            columns[position.column] = columns[position.column].map { $0.union(rect) } ?? rect
            rowBounds[position.row] = rowBounds[position.row].map { $0.union(rect) } ?? rect
        }
        // Include any gap before the next column/row, as the original cell styles do.
        let columnIndices = columns.keys.sorted()
        for (offset, index) in columnIndices.enumerated() {
            if offset + 1 < columnIndices.count {
                columns[index]!.size.width = columns[columnIndices[offset + 1]]!.minX - columns[index]!.minX
            }
        }
        let rowIndices = rowBounds.keys.sorted()
        for (offset, index) in rowIndices.enumerated() {
            if offset + 1 < rowIndices.count {
                rowBounds[index]!.size.height = rowBounds[rowIndices[offset + 1]]!.minY - rowBounds[index]!.minY
            }
            let row = rowBounds[index]!
            rows.append((index, CGRect(x: 0, y: row.minY, width: width, height: row.height)))
        }
        for position in rects.keys.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            let column = columns[position.column]!
            let row = rowBounds[position.row]!
            cells.append(CGRect(x: column.minX, y: row.minY, width: column.width, height: row.height))
        }
    }
}

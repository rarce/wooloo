//
//  LineFragment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/29/23.
//

import AppKit

/// A ``LineFragment`` represents a subrange of characters in a line. Every text line contains at least one line
/// fragments, and any lines that need to be broken due to width constraints will contain more than one fragment.
public final class LineFragment: Identifiable, Equatable {
    // wooloo patch: offscreen wrapped rows need their geometry, but only displayed rows need a view identity.
    public private(set) lazy var id = UUID()
    private(set) public var ctLine: CTLine
    public let width: CGFloat
    public let height: CGFloat
    public let descent: CGFloat
    public let scaledHeight: CGFloat

    /// wooloo patch: caret geometry stays with this immutable shaped row. Its indices are relative to the
    /// logical line, so moving that line elsewhere in the document does not invalidate the cache.
    public struct VisualCluster {
        public var range: NSRange
        public var leadingX: CGFloat
        public var trailingX: CGFloat
        public var minX: CGFloat
        public var maxX: CGFloat
    }

    public lazy var hasRightToLeftText: Bool = {
        (CTLineGetGlyphRuns(ctLine) as! [CTRun]).contains { CTRunGetStatus($0).contains(.rightToLeft) }
    }()
    private var cachedVisualClusters: [VisualCluster]?

    /// The screen extent of each whole grapheme, in visual order. Core Text supplies both edges at a bidi
    /// boundary; querying only a string index's primary caret would join unrelated parts of the row.
    public func visualClusters(in text: NSString, lineOffset: Int) -> [VisualCluster] {
        if let cachedVisualClusters { return cachedVisualClusters }
        var clusters: [NSRange: VisualCluster] = [:]
        func append(start: Int, end: Int, leadingX: CGFloat, trailingX: CGFloat) {
            guard start >= 0, end >= start, lineOffset + end < text.length else { return }
            let composed = text.rangeOfComposedCharacterSequences(
                for: NSRange(location: lineOffset + start, length: end - start + 1))
            let range = NSRange(location: composed.location - lineOffset, length: composed.length)
            var cluster = clusters[range] ?? VisualCluster(range: range, leadingX: leadingX, trailingX: trailingX,
                                                           minX: min(leadingX, trailingX), maxX: max(leadingX, trailingX))
            cluster.minX = min(cluster.minX, leadingX, trailingX)
            cluster.maxX = max(cluster.maxX, leadingX, trailingX)
            if start == range.location { cluster.leadingX = leadingX }
            if end == NSMaxRange(range) - 1 { cluster.trailingX = trailingX }
            clusters[range] = cluster
        }
        var leading: [(index: Int, x: CGFloat)] = [], trailing: [(index: Int, x: CGFloat)] = []
        CTLineEnumerateCaretOffsets(ctLine) { x, index, isLeading, _ in
            if isLeading { leading.append((index, x)) } else { trailing.append((index, x)) }
        }
        leading.sort { $0.index < $1.index }
        trailing.sort { $0.index < $1.index }
        // A trailing edge names the last UTF-16 unit of its caret unit, which can include zero-width
        // formatting characters following the visible character. Pair edges before expanding graphemes.
        if leading.count == trailing.count,
           zip(leading, trailing).allSatisfy({ $0.0.index <= $0.1.index }),
           zip(trailing, leading.dropFirst()).allSatisfy({ $0.0.index < $0.1.index }) {
            for (start, end) in zip(leading, trailing) {
                append(start: start.index, end: end.index, leadingX: start.x, trailingX: end.x)
            }
        } else {
            // If a font supplies incomplete caret data, conservatively keep whole shaped glyph clusters.
            // This avoids guessing a primary caret across a bidi boundary or splitting a ligature.
            for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                let runRange = CTRunGetStringRange(run)
                let boundaries = Array(Set(indices + [runRange.location + runRange.length])).sorted()
                let ends = Dictionary(uniqueKeysWithValues: zip(boundaries, boundaries.dropFirst()).map { ($0.0, $0.1) })
                let rtl = CTRunGetStatus(run).contains(.rightToLeft)
                for index in 0..<count {
                    guard let end = ends[indices[index]] else { continue }
                    let left = positions[index].x, right = left + advances[index].width
                    append(start: indices[index], end: end - 1,
                           leadingX: rtl ? right : left, trailingX: rtl ? left : right)
                }
            }
        }
        let result = clusters.values.sorted {
            $0.minX == $1.minX ? $0.range.location < $1.range.location : $0.minX < $1.minX
        }
        cachedVisualClusters = result
        return result
    }

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    init(
        ctLine: CTLine,
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        lineHeightMultiplier: CGFloat
    ) {
        self.ctLine = ctLine
        self.width = width
        self.height = height
        self.descent = descent
        self.scaledHeight = height * lineHeightMultiplier
    }

    public static func == (lhs: LineFragment, rhs: LineFragment) -> Bool {
        lhs.id == rhs.id
    }
}

//
//  TreeSitterClient+Highlight.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    func queryHighlightsForRange(range: NSRange) -> [HighlightRange] {
        guard let state = self.state else { return [] }

        // Markdown's inline injection covers heading text too. Keep block captures as a
        // fallback, then let narrower inline/code captures override them.
        if state.primaryLayer.id == .markdown {
            var captures = queryLayerHighlights(layer: state.layers[0], range: range)
            for layer in state.layers.dropFirst() {
                for layerRange in layer.ranges {
                    if let intersection = range.intersection(layerRange) {
                        captures += queryLayerHighlights(layer: layer, range: intersection)
                    }
                }
            }
            return flattenedDocumentHighlights(captures)
        }

        var highlights: [HighlightRange] = []
        var injectedSet = IndexSet(integersIn: range)

        for layer in state.layers where layer.id != state.primaryLayer.id {
            // Query injected only if a layer's ranges intersects with `range`
            for layerRange in layer.ranges {
                if let rangeIntersection = range.intersection(layerRange) {
                    let queryResult = queryLayerHighlights(
                        layer: layer,
                        range: rangeIntersection
                    )

                    highlights.append(contentsOf: queryResult)
                    injectedSet.remove(integersIn: rangeIntersection)
                }
            }
        }

        // Query primary for any ranges that weren't used in the injected layers.
        for range in injectedSet.rangeView {
            let queryResult = queryLayerHighlights(
                layer: state.layers[0],
                range: NSRange(range)
            )
            highlights.append(contentsOf: queryResult)
        }

        return highlights
    }

    /// The storage consumes disjoint runs. Resolve nesting before handing it document captures.
    private func flattenedDocumentHighlights(_ captures: [HighlightRange]) -> [HighlightRange] {
        var starts: [Int: [Int]] = [:]
        var ends: [Int: [Int]] = [:]
        for (index, capture) in captures.enumerated() {
            starts[capture.range.location, default: []].append(index)
            ends[capture.range.upperBound, default: []].append(index)
        }
        let boundaries = Set(starts.keys).union(ends.keys).sorted()
        var active = Set<Int>()
        var result: [HighlightRange] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
            for index in ends[lower] ?? [] { active.remove(index) }
            for index in starts[lower] ?? [] { active.insert(index) }
            // Narrower captures style nested elements; later layers win equal ranges.
            guard let index = active.min(by: {
                let lhs = captures[$0].range.length, rhs = captures[$1].range.length
                return lhs == rhs ? $0 > $1 : lhs < rhs
            }) else { continue }
            var capture = captures[index].capture
            if capture == .textStrong || capture == .textEmphasis {
                let hasStrong = active.contains { captures[$0].capture == .textStrong || captures[$0].capture == .textTitle }
                let hasEmphasis = active.contains { captures[$0].capture == .textEmphasis }
                if hasStrong && hasEmphasis { capture = .textStrongEmphasis }
            }
            result.append(HighlightRange(range: NSRange(location: lower, length: upper - lower), capture: capture))
        }
        return result
    }

    /// Queries the given language layer for any highlights.
    /// - Parameters:
    ///   - layer: The layer to query.
    ///   - range: The range to query for.
    /// - Returns: Any ranges to highlight.
    internal func queryLayerHighlights(
        layer: LanguageLayer,
        range: NSRange
    ) -> [HighlightRange] {
        guard let tree = layer.tree,
              let rootNode = tree.rootNode else {
            return []
        }

        // This needs to be on the main thread since we're going to use the `textProvider` in
        // the `highlightsFromCursor` method, which uses the textView's text storage.
        guard let queryCursor = layer.languageQuery?.execute(node: rootNode, in: tree) else {
            return []
        }
        queryCursor.setRange(range)
        queryCursor.matchLimit =  Constants.matchLimit

        var highlights: [HighlightRange] = []

        // See https://github.com/CodeEditApp/CodeEditSourceEditor/pull/228
        if layer.id == .jsdoc {
            highlights.append(HighlightRange(range: range, capture: .comment))
        }

        highlights += highlightsFromCursor(cursor: queryCursor, includedRange: range)

        return highlights
    }

    /// Resolves a query cursor to the highlight ranges it contains.
    /// **Must be called on the main thread**
    /// - Parameters:
    ///     - cursor: The cursor to resolve.
    ///     - includedRange: The range to include highlights from.
    /// - Returns: Any highlight ranges contained in the cursor.
    internal func highlightsFromCursor(
        cursor: QueryCursor,
        includedRange: NSRange
    ) -> [HighlightRange] {
        guard let readCallback else { return [] }
        var ranges: [NSRange: Int] = [:]
        return cursor
            .resolve(with: .init(textProvider: readCallback)) // Resolve our cursor against the query
            .flatMap { $0.captures }
            .reversed() // SwiftTreeSitter returns captures in the reverse order of what we need to filter with.
            .compactMap { capture in
                let range = capture.range
                let index = capture.index

                // Lower indexed captures are favored over higher, this is why we reverse it above
                if let existingLevel = ranges[range], existingLevel <= index {
                    return nil
                }

                guard let captureName = CaptureName.fromString(capture.name) else {
                    return nil
                }

                // Update the filter level to the current index since it's lower and a 'valid' capture
                ranges[range] = index

                // Validate range and capture name
                let intersectionRange = range.intersection(includedRange) ?? .zero
                guard intersectionRange.length > 0 else {
                    return nil
                }

                return HighlightRange(range: intersectionRange, capture: captureName)
            }
    }
}

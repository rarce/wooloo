//
//  TextSelection.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/20/24.
//

import Foundation
import AppKit

public extension TextSelectionManager {
    class TextSelection: Hashable, Equatable {
        public var range: NSRange {
            didSet { visualCaret = nil }
        }
        /// wooloo patch: retain a visual edge without storing coordinates that become stale on reflow.
        /// Leading anchors name the first UTF-16 unit; trailing anchors name the last unit of the caret cluster.
        public struct VisualCaret: Equatable {
            public enum Edge { case leading, trailing }
            public var anchorOffset: Int
            public var edge: Edge

            public init(anchorOffset: Int, edge: Edge) {
                self.anchorOffset = anchorOffset
                self.edge = edge
            }
        }
        public internal(set) var visualCaret: VisualCaret?
        weak var view: NSView?
        var boundingRect: CGRect = .zero
        var suggestedXPos: CGFloat?
        /// The position this selection should 'rotate' around when modifying selections.
        var pivot: Int?

        init(range: NSRange, view: CursorView? = nil) {
            self.range = range
            self.view = view
        }

        var isCursor: Bool {
            range.length == 0
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(range)
        }

        public static func == (lhs: TextSelection, rhs: TextSelection) -> Bool {
            lhs.range == rhs.range
        }
    }
}

private extension TextSelectionManager.TextSelection {
    func didInsertText(length: Int, retainLength: Bool = false) {
        if !retainLength {
            range.length = 0
        }
        range.location += length
    }
}

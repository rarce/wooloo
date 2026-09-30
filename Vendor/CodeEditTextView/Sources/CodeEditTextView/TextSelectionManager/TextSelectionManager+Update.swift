//
//  TextSelectionManager+Update.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    public func didReplaceCharacters(in range: NSRange, replacementLength: Int) {
        // xherdr patch: shift later selections by the change in length, and keep the length of selections the edit
        // does not touch. Upstream shifted by the replacement length alone and collapsed every selection, so typing
        // over several non-empty selections (edited last to first) left the cursors in the wrong places.
        let delta = replacementLength - range.length
        for textSelection in self.textSelections {
            if textSelection.range.intersection(range) != nil
                || textSelection.range == range
                || (textSelection.range.isEmpty && textSelection.range.location > range.location
                    && textSelection.range.location <= range.max) {
                textSelection.range.location = range.location + replacementLength
                textSelection.range.length = 0
            } else if textSelection.range.location >= range.max {
                textSelection.range.location = max(0, textSelection.range.location + delta)
            }
        }

        // Clean up duplicate selection ranges
        var allRanges: Set<NSRange> = []
        for (idx, selection) in self.textSelections.enumerated().reversed() {
            if allRanges.contains(selection.range) {
                self.textSelections.remove(at: idx)
            } else {
                allRanges.insert(selection.range)
            }
        }
    }

    func notifyAfterEdit() {
        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }
}

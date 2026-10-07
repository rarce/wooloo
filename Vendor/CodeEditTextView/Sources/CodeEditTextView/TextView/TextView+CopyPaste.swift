//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    /// wooloo patch: holds one string per selection, so pasting at as many cursors gives each its own text.
    public static let selectionsPasteboardType = NSPasteboard.PasteboardType("dev.wooloo.editor.selections")

    /// wooloo patch: copies the selections in document order joined by newlines, and each one separately.
    /// Upstream wrote one pasteboard item per selection, so other apps only pasted the first.
    @objc open func copy(_ sender: AnyObject) {
        let strings = selectionManager.textSelections
            .map(\.range)
            .sorted { $0.location < $1.location }
            .map { textStorage.attributedSubstring(from: $0).string }
        guard !strings.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(strings.joined(separator: "\n"), forType: .string)
        if strings.count > 1 {
            NSPasteboard.general.setPropertyList(strings, forType: Self.selectionsPasteboardType)
        }
    }

    /// wooloo patch: text copied from N selections pastes one piece at each cursor when there are N cursors,
    /// as in Zed and VS Code.
    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        let ranges = selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
        if isEditable, ranges.count > 1,
           let pieces = NSPasteboard.general.propertyList(forType: Self.selectionsPasteboardType) as? [String],
           pieces.count == ranges.count, pieces.joined(separator: "\n") == stringContents {
            unmarkText()
            // Last to first so earlier ranges stay valid; the first edit starts the undo group, the rest join it.
            var groups = false
            for (range, piece) in zip(ranges, pieces).reversed() {
                replaceCharacters(in: range, with: piece)
                if !groups, let undoManager = _undoManager, !undoManager.isGrouping {
                    undoManager.beginGrouping()
                    groups = true
                }
            }
            if groups { _undoManager?.endGrouping() }
            return
        }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc open func cut(_ sender: AnyObject) {
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }
}

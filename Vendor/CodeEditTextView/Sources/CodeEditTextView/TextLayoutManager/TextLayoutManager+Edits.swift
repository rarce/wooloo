//
//  TextLayoutManager+Edits.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

// MARK: - Edits

extension TextLayoutManager: NSTextStorageDelegate {
    /// Notifies the layout manager of an edit.
    ///
    /// Used by the `TextView` to tell the layout manager about any edits that will happen.
    /// Use this to keep the layout manager's line storage in sync with the text storage.
    ///
    /// - Parameters:
    ///   - range: The range of the edit.
    ///   - string: The string to replace in the given range.
    public func willReplaceCharactersInRange(range: NSRange, with string: String) {
        mapTopThroughEdit(range: range, replacementLength: (string as NSString).length)
        // The previous character is valid again only after the mapped anchor is actually kept.
        keptTop = nil
        pendingTop = nil
        pendingEditTop = nil
        // Loop through each line being replaced in reverse, updating and removing where necessary.
         for linePosition in lineStorage.linesInRange(range).reversed() {
            // Two cases: Updated line, deleted line entirely
            guard let intersection = linePosition.range.intersection(range), !intersection.isEmpty else { continue }
            if intersection == linePosition.range && linePosition.range.max != lineStorage.length {
                // Delete line
                lineStorage.delete(lineAt: linePosition.range.location)
            } else if intersection.max == linePosition.range.max,
                      let nextLine = lineStorage.getLine(atOffset: linePosition.range.max) {
                // Need to merge line with one after it after updating this line to remove the end of the line
                lineStorage.delete(lineAt: nextLine.range.location)
                let delta = -intersection.length + nextLine.range.length
                if delta != 0 {
                    lineStorage.update(atIndex: linePosition.range.location, delta: delta, deltaHeight: 0)
                }
            } else {
                lineStorage.update(atIndex: linePosition.range.location, delta: -intersection.length, deltaHeight: 0)
            }
        }

        // Loop through each line being inserted, inserting & splitting where necessary
        if !string.isEmpty {
            var index = 0
            while let nextLine = (string as NSString).getNextLine(startingAt: index) {
                let lineRange = NSRange(start: index, end: nextLine.max)
                applyLineInsert((string as NSString).substring(with: lineRange) as NSString, at: range.location + index)
                index = nextLine.max
            }

            if index < (string as NSString).length {
                // Get the last line.
                applyLineInsert(
                    (string as NSString).substring(from: index) as NSString,
                    at: range.location + index
                )
            }
        }
        setNeedsLayout()
        if !isInTransaction { finishEditTopTransaction() }
    }

    /// Capture once, including when the first range in a descending replacement is visible.
    private func captureEditTopIfNeeded() {
        guard !capturedEditTop else { return }
        capturedEditTop = true
        if let pendingEditTop {
            editTop = pendingEditTop
            return
        }
        guard wrapLines, let top = viewTop,
              let position = textLineForPosition(top + 1),
              let row = position.data.lineFragments.getLine(atPosition: top + 1 - position.yPos),
              let anchor = topAnchor() else { return }
        editTop = EditTop(anchor: anchor, rowStart: position.range.location + row.range.location,
                          lineStart: position.range.location, viewportTop: top)
    }

    private func mapTopThroughEdit(range: NSRange, replacementLength: Int) {
        cancelTopAfterScrolling()
        captureEditTopIfNeeded()
        guard var top = editTop else { return }

        // A character kept across reflow may now be inside the top row. Typing before it in
        // that visible row must keep the inserted text there, not follow the displaced character.
        if range.location >= top.rowStart && range.location <= top.anchor.offset {
            top.anchor = TopAnchor(offset: top.rowStart, dy: top.anchor.dy)
        }
        let offset = top.anchor.offset
        if !range.isEmpty, range.location <= offset, offset < range.max {
            editTop = nil // The character was replaced; never collapse a whole-document edit to zero.
            return
        }

        let affectsHiddenPrefix = range.isEmpty
            ? top.lineStart <= range.location && range.location < top.rowStart
            : range.location < top.rowStart && range.max <= offset && range.max >= top.lineStart
        top.shouldKeep = top.shouldKeep || affectsHiddenPrefix
        let delta = replacementLength - range.length
        func mappedBoundary(_ boundary: Int) -> Int {
            if range.isEmpty { return range.location < boundary ? boundary + delta : boundary }
            if range.max <= boundary { return boundary + delta }
            if range.location <= boundary { return range.location }
            return boundary
        }
        top.anchor = TopAnchor(offset: mappedBoundary(offset), dy: top.anchor.dy)
        top.rowStart = mappedBoundary(top.rowStart)
        top.lineStart = mappedBoundary(top.lineStart)
        editTop = top
    }

    /// Commit once after the outer transaction. Retain its mapping state if layout has to wait.
    func finishEditTopTransaction() {
        if let top = editTop, top.shouldKeep {
            pendingTop = top.anchor
            pendingEditTop = top
        }
        editTop = nil
        capturedEditTop = false
    }

    /// Applies a line insert to the internal line storage tree.
    /// - Parameters:
    ///   - insertedString: The string being inserted.
    ///   - location: The location the string is being inserted into.
    private func applyLineInsert(_ insertedString: NSString, at location: Int) {
        if LineEnding(line: insertedString as String) != nil {
            if location == textStorage?.length ?? 0 {
                // Insert a new line at the end of the document, need to insert a new line 'cause there's nothing to
                // split. Also, append the new text to the last line.
                lineStorage.update(atIndex: location, delta: insertedString.length, deltaHeight: 0.0)
                lineStorage.insert(
                    line: TextLine(),
                    atOffset: location + insertedString.length,
                    length: 0,
                    height: estimateLineHeight()
                )
            } else {
                // Need to split the line inserting into and create a new line with the split section of the line
                guard let linePosition = lineStorage.getLine(atOffset: location) else { return }
                let splitLocation = location + insertedString.length
                let splitLength = linePosition.range.max - location
                let lineDelta = insertedString.length - splitLength // The difference in the line being edited
                if lineDelta != 0 {
                    lineStorage.update(atIndex: location, delta: lineDelta, deltaHeight: 0.0)
                }

                lineStorage.insert(
                    line: TextLine(),
                    atOffset: splitLocation,
                    length: splitLength,
                    height: estimateLineHeight()
                )
            }
        } else {
            lineStorage.update(atIndex: location, delta: insertedString.length, deltaHeight: 0.0)
        }
    }

    /// This method is to simplify keeping the layout manager in sync with attribute changes in the storage object.
    /// This does not handle cases where characters have been inserted or removed from the storage.
    /// For that, see the `willPerformEdit` method.
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        if editedMask.contains(.editedAttributes) && delta == 0 {
            invalidateLayoutForRange(editedRange)
        }
    }
}

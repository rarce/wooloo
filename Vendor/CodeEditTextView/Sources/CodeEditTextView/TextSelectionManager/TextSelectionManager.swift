//
//  TextSelectionManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/23.
//

import AppKit

public protocol TextSelectionManagerDelegate: AnyObject {
    var visibleTextRange: NSRange? { get }

    func setNeedsDisplay()
    func estimatedLineHeight() -> CGFloat
}

/// Manages an array of text selections representing cursors (0-length ranges) and selections (>0-length ranges).
///
/// Draws selections using a draw method similar to the `TextLayoutManager` class, and adds cursor views when
/// appropriate.
public class TextSelectionManager: NSObject {
    // MARK: - Properties

    // swiftlint:disable:next line_length
    public static let selectionChangedNotification: Notification.Name = Notification.Name("com.CodeEdit.TextSelectionManager.TextSelectionChangedNotification")

    public var insertionPointColor: NSColor = NSColor.labelColor {
        didSet {
            textSelections.compactMap({ $0.view as? CursorView }).forEach { $0.color = insertionPointColor }
        }
    }
    public var highlightSelectedLine: Bool = true
    public var selectedLineBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
    public var selectionBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor
    public var useSystemCursor: Bool = false {
        didSet {
            updateSelectionViews()
        }
    }

    internal(set) public var textSelections: [TextSelection] = []
    weak var layoutManager: TextLayoutManager?
    weak var textStorage: NSTextStorage?
    weak var textView: TextView?
    weak var delegate: TextSelectionManagerDelegate?
    var cursorTimer: CursorTimer

    init(
        layoutManager: TextLayoutManager,
        textStorage: NSTextStorage,
        textView: TextView?,
        delegate: TextSelectionManagerDelegate?,
        useSystemCursor: Bool = false
    ) {
        self.layoutManager = layoutManager
        self.textStorage = textStorage
        self.textView = textView
        self.delegate = delegate
        self.cursorTimer = CursorTimer()
        super.init()
        textSelections = []
        updateSelectionViews()
    }

    // MARK: - Selected Ranges

    /// Set the selected ranges to a single range. Overrides any existing selections.
    /// - Parameter range: The range to set.
    public func setSelectedRange(_ range: NSRange) {
        textSelections.forEach { $0.view?.removeFromSuperview() }
        let selection = TextSelection(range: range)
        selection.suggestedXPos = layoutManager?.rectForOffset(range.location)?.minX
        textSelections = [selection]
        if textView?.isFirstResponder ?? false {
            updateSelectionViews()
            NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        }
    }

    /// Set the selected ranges to new ranges. Overrides any existing selections.
    /// - Parameter range: The selected ranges to set.
    public func setSelectedRanges(_ ranges: [NSRange], visualCarets: [Int: TextSelection.VisualCaret] = [:]) {
        textSelections.forEach { $0.view?.removeFromSuperview() }
        // Remove duplicates, invalid ranges, update suggested X position.
        textSelections = Set(ranges)
            .filter {
                (0...(textStorage?.length ?? 0)).contains($0.location)
                && (0...(textStorage?.length ?? 0)).contains($0.max)
            }
            .map {
                let selection = TextSelection(range: $0)
                selection.visualCaret = $0.isEmpty ? visualCarets[$0.location] : nil
                selection.suggestedXPos = caretRect(for: selection)?.minX
                return selection
            }
        if textView?.isFirstResponder ?? false {
            updateSelectionViews()
            NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        }
    }

    /// Append a new selected range to the existing ones.
    /// - Parameter range: The new range to add.
    public func addSelectedRange(_ range: NSRange) {
        let newTextSelection = TextSelection(range: range)
        var didHandle = false
        for textSelection in textSelections {
            if textSelection.range == newTextSelection.range {
                // Duplicate range, ignore
                return
            } else if (range.length > 0 && textSelection.range.intersection(range) != nil)
                        || textSelection.range.max == range.location {
                // Range intersects existing range, modify this range to be the union of both and don't add the new
                // selection
                textSelection.range = textSelection.range.union(range)
                didHandle = true
            }
        }
        if !didHandle {
            textSelections.append(newTextSelection)
        }

        if textView?.isFirstResponder ?? false {
            updateSelectionViews()
            NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        }
    }

    // MARK: - Selection Views

    /// Resolve a chosen visual edge in the current layout. Ordinary selections retain the default caret affinity.
    public func caretRect(for selection: TextSelection) -> CGRect? {
        guard let layoutManager else { return nil }
        if selection.range.isEmpty, let caret = selection.visualCaret, let textStorage,
           caret.anchorOffset >= 0, caret.anchorOffset < textStorage.length {
            // Lay out the anchor's row first, then reread its position because layout may change row heights.
            _ = layoutManager.rectForOffset(caret.anchorOffset)
            if let line = layoutManager.textLineForOffset(caret.anchorOffset),
               let fragment = line.data.lineFragments.getLine(atOffset: caret.anchorOffset - line.range.location),
               let cluster = fragment.data.visualClusters(in: textStorage.string as NSString,
                                                         lineOffset: line.range.location).first(where: {
                   NSLocationInRange(caret.anchorOffset - line.range.location, $0.range)
               }) {
                let leading = caret.edge == .leading
                let boundary = line.range.location + (leading ? cluster.range.location : cluster.range.max)
                if boundary == selection.range.location {
                    return CGRect(x: layoutManager.edgeInsets.left + (leading ? cluster.leadingX : cluster.trailingX),
                                  y: line.yPos + fragment.yPos, width: 0, height: fragment.height)
                }
            }
        }
        return layoutManager.rectForOffset(selection.range.location)
    }

    /// Update all selection cursors. Placing them in the correct position for each text selection and reseting the
    /// blink timer.
    func updateSelectionViews() {
        guard layoutManager?.isInTransaction != true else { return }
        var didUpdate: Bool = false

        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                let rect = caretRect(for: textSelection) ?? .zero
                let cursorOrigin = rect.origin

                var doesViewNeedReposition: Bool

                // If using the system cursor, macOS will change the origin and height by about 0.5, so we do an
                // approximate equals in that case to avoid extra updates.
                if useSystemCursor, #available(macOS 14.0, *) {
                    doesViewNeedReposition = !textSelection.boundingRect.origin.approxEqual(cursorOrigin)
                    || !textSelection.boundingRect.height.approxEqual(layoutManager?.estimateLineHeight() ?? 0)
                } else {
                    doesViewNeedReposition = textSelection.boundingRect.origin != cursorOrigin
                    || textSelection.boundingRect.height != layoutManager?.estimateLineHeight() ?? 0
                }

                if textSelection.view == nil || doesViewNeedReposition {
                    let cursorView: NSView

                    if let existingCursorView = textSelection.view {
                        cursorView = existingCursorView
                    } else {
                        textSelection.view?.removeFromSuperview()
                        textSelection.view = nil

                        if useSystemCursor, #available(macOS 14.0, *) {
                            let systemCursorView = NSTextInsertionIndicator(frame: .zero)
                            cursorView = systemCursorView
                            systemCursorView.displayMode = .automatic
                        } else {
                            let internalCursorView = CursorView(color: insertionPointColor)
                            cursorView = internalCursorView
                            cursorTimer.register(internalCursorView)
                        }

                        textView?.addSubview(cursorView)
                    }

                    cursorView.frame.origin = cursorOrigin
                    cursorView.frame.size.height = textSelection.visualCaret == nil
                        ? heightForCursorAt(textSelection.range) ?? 0 : rect.height

                    textSelection.view = cursorView
                    textSelection.boundingRect = cursorView.frame

                    didUpdate = true
                }
            } else if !textSelection.range.isEmpty && textSelection.view != nil {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil
                didUpdate = true
            }
        }

        if didUpdate {
            delegate?.setNeedsDisplay()
            cursorTimer.resetTimer()
            resetSystemCursorTimers()
        }
    }

    private func resetSystemCursorTimers() {
        guard #available(macOS 14, *) else { return }
        for cursorView in textSelections.compactMap({ $0.view as? NSTextInsertionIndicator }) {
            let frame = cursorView.frame
            cursorView.frame = .zero
            cursorView.frame = frame
        }
    }

    /// Get the height for a cursor placed at the beginning of the given range.
    /// - Parameter range: The range the cursor is at.
    /// - Returns: The height the cursor should be to match the text at that location.
    fileprivate func heightForCursorAt(_ range: NSRange) -> CGFloat? {
        guard let selectedLine = layoutManager?.textLineForOffset(range.location) else {
            return layoutManager?.estimateLineHeight()
        }
        return selectedLine
            .data
            .lineFragments
            .getLine(atOffset: range.location - (selectedLine.range.location))?
            .height
        ?? layoutManager?.estimateLineHeight()

    }

    /// Removes all cursor views and stops the cursor blink timer.
    func removeCursors() {
        cursorTimer.stopTimer()
        for textSelection in textSelections {
            textSelection.view?.removeFromSuperview()
        }
    }

    // MARK: - Draw

    /// Draws line backgrounds and selection rects for each selection in the given rect.
    /// - Parameter rect: The rect to draw in.
    func drawSelections(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        var highlightedLines: Set<UUID> = []
        // For each selection in the rect
        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                drawHighlightedLine(
                    in: rect,
                    for: textSelection,
                    context: context,
                    highlightedLines: &highlightedLines
                )
            } else {
                drawSelectedRange(in: rect, for: textSelection, context: context)
            }
        }
        context.restoreGState()
    }

    /// Draws a highlighted line in the given rect.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - textSelection: The selection to draw.
    ///   - context: The context to draw in.
    ///   - highlightedLines: The set of all lines that have already been highlighted, used to avoid highlighting lines
    ///                       twice and updated if this function comes across a new line id.
    private func drawHighlightedLine(
        in rect: NSRect,
        for textSelection: TextSelection,
        context: CGContext,
        highlightedLines: inout Set<UUID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(textSelection.range.location),
              !highlightedLines.contains(linePosition.data.id) else {
            return
        }
        highlightedLines.insert(linePosition.data.id)
        context.saveGState()
        let selectionRect = CGRect(
            x: rect.minX,
            y: linePosition.yPos,
            width: rect.width,
            height: linePosition.height
        )
        if selectionRect.intersects(rect) {
            context.setFillColor(selectedLineBackgroundColor.cgColor)
            context.fill(selectionRect)
        }
        context.restoreGState()
    }

    /// Draws a selected range in the given context.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - range: The range to highlight.
    ///   - context: The context to draw in.
    private func drawSelectedRange(in rect: NSRect, for textSelection: TextSelection, context: CGContext) {
        context.saveGState()

        let fillColor = (textView?.isFirstResponder ?? false)
        ? selectionBackgroundColor.cgColor
        : selectionBackgroundColor.grayscale.cgColor

        context.setFillColor(fillColor)

        let fillRects = getFillRects(in: rect, for: textSelection)

        let minX = fillRects.min(by: { $0.origin.x < $1.origin.x })?.origin.x ?? 0
        let minY = fillRects.min(by: { $0.origin.y < $1.origin.y })?.origin.y ?? 0
        let max = fillRects.max(by: { $0.maxY < $1.maxY }) ?? .zero
        let origin = CGPoint(x: minX, y: minY)
        let size = CGSize(width: max.maxX - minX, height: max.maxY - minY)
        textSelection.boundingRect = CGRect(origin: origin, size: size)

        context.fill(fillRects)
        context.restoreGState()
    }
}

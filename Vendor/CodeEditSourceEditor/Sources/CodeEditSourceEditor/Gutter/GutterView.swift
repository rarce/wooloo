//
//  GutterView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/22/23.
//

import AppKit
import CodeEditTextView
import CodeEditTextViewObjC

public protocol GutterViewDelegate: AnyObject {
    func gutterViewWidthDidUpdate(newWidth: CGFloat)
}

/// The gutter view displays line numbers that match the text view's line indexes.
/// This view is used as a scroll view's ruler view. It sits on top of the text view so text scrolls underneath the
/// gutter if line wrapping is disabled.
///
/// If the gutter needs more space (when the number of digits in the numbers increases eg. adding a line after line 99),
/// it will notify it's delegate via the ``GutterViewDelegate/gutterViewWidthDidUpdate(newWidth:)`` method. In
/// `CodeEditSourceEditor`, this notifies the ``TextViewController``, which in turn updates the textview's edge insets
/// to adjust for the new leading inset.
///
/// This view also listens for selection updates, and draws a selected background on selected lines to keep the illusion
/// that the gutter's line numbers are inline with the line itself.
///
/// The gutter view has insets of it's own that are relative to the widest line index. By default, these insets are 20px
/// leading, and 12px trailing. However, this view also has a ``GutterView/backgroundEdgeInsets`` property, that pads
/// the rect that has a background drawn. This allows the text to be scrolled under the gutter view for 8px before being
/// overlapped by the gutter. It should help the textview keep the cursor visible if the user types while the cursor is
/// off the leading edge of the editor.
///
public class GutterView: NSView {
    // xherdr patch: Git change bars at the leading edge of the gutter, as in VS Code and Zed.
    public struct LineChange: Equatable {
        public enum Kind: Equatable {
            case added, modified
            /// Lines removed above `line`, drawn as a wedge on that line's top edge.
            case deleted
        }

        /// Zero-based index of the first changed line.
        public var line: Int
        /// Changed lines; zero for `.deleted`.
        public var count: Int
        public var kind: Kind
        /// Staged in the Git index: drawn as an outline instead of a filled bar.
        public var isStaged: Bool

        public init(line: Int, count: Int, kind: Kind, isStaged: Bool) {
            self.line = line
            self.count = count
            self.kind = kind
            self.isStaged = isStaged
        }
    }

    /// Sorted by `line`.
    public var lineChanges: [LineChange] = [] {
        didSet { if lineChanges != oldValue { needsDisplay = true } }
    }
    public var lineChangeColors: (added: NSColor, modified: NSColor, deleted: NSColor)
        = (.systemGreen, .systemYellow, .systemRed) {
        didSet { needsDisplay = true }
    }
    public var lineChangeWidth: CGFloat = 3

    struct EdgeInsets: Equatable, Hashable {
        let leading: CGFloat
        let trailing: CGFloat

        var horizontal: CGFloat {
            leading + trailing
        }
    }

    @Invalidating(.display)
    var textColor: NSColor = .secondaryLabelColor

    @Invalidating(.display)
    var font: NSFont = .systemFont(ofSize: 13)

    @Invalidating(.display)
    var edgeInsets: EdgeInsets = EdgeInsets(leading: 20, trailing: 12)

    @Invalidating(.display)
    var backgroundEdgeInsets: EdgeInsets = EdgeInsets(leading: 0, trailing: 8)

    @Invalidating(.display)
    var backgroundColor: NSColor? = NSColor.controlBackgroundColor

    @Invalidating(.display)
    var highlightSelectedLines: Bool = true

    @Invalidating(.display)
    var selectedLineTextColor: NSColor? = .textColor

    @Invalidating(.display)
    var selectedLineColor: NSColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)

    /// The required width of the entire gutter, including padding.
    private(set) public var gutterWidth: CGFloat = 0

    private weak var textView: TextView?
    private weak var delegate: GutterViewDelegate?
    private var maxWidth: CGFloat = 0
    /// The maximum number of digits found for a line number.
    private var maxLineLength: Int = 0

    override public var isFlipped: Bool {
        true
    }

    public init(
        font: NSFont,
        textColor: NSColor,
        textView: TextView,
        delegate: GutterViewDelegate? = nil
    ) {
        self.font = font
        self.textColor = textColor
        self.textView = textView
        self.delegate = delegate

        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true

        NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the width of the gutter if needed.
    func updateWidthIfNeeded() {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let originalMaxWidth = maxWidth
        // Reserve at least 3 digits of space no matter what
        let lineStorageDigits = max(3, String(textView.layoutManager.lineCount).count)

        if maxLineLength < lineStorageDigits {
            // Update the max width
            let maxCtLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(repeating: "0", count: lineStorageDigits), attributes: attributes)
            )
            let width = CTLineGetTypographicBounds(maxCtLine, nil, nil, nil)
            maxWidth = max(maxWidth, width)
            maxLineLength = lineStorageDigits
        }

        if originalMaxWidth != maxWidth {
            gutterWidth = maxWidth + edgeInsets.horizontal
            delegate?.gutterViewWidthDidUpdate(newWidth: maxWidth + edgeInsets.horizontal)
        }
    }

    private func drawBackground(_ context: CGContext) {
        guard let backgroundColor else { return }
        let xPos = backgroundEdgeInsets.leading
        let width = gutterWidth - backgroundEdgeInsets.trailing

        context.saveGState()
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: xPos, y: 0, width: width, height: frame.height))
        context.restoreGState()
    }

    private func drawSelectedLines(_ context: CGContext) {
        guard let textView = textView,
              let selectionManager = textView.selectionManager,
              let visibleRange = textView.visibleTextRange,
              highlightSelectedLines else {
            return
        }
        context.saveGState()

        var highlightedLines: Set<UUID> = []
        context.setFillColor(selectedLineColor.cgColor)

        let xPos = backgroundEdgeInsets.leading
        let width = gutterWidth - backgroundEdgeInsets.trailing

        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  visibleRange.intersection(line.range) != nil || selection.range.location == textView.length,
                  !highlightedLines.contains(line.data.id) else {
                continue
            }
            highlightedLines.insert(line.data.id)
            context.fill(
                CGRect(
                    x: xPos,
                    y: line.yPos,
                    width: width,
                    height: line.height
                )
            )
        }

        context.restoreGState()
    }

    private func drawLineNumbers(_ context: CGContext) {
        guard let textView = textView else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]

        var selectionRangeMap = IndexSet()
        textView.selectionManager?.textSelections.forEach {
            if $0.range.isEmpty {
                selectionRangeMap.insert($0.range.location)
            } else {
                selectionRangeMap.insert(range: $0.range)
            }
        }

        context.saveGState()

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        ContextSetHiddenSmoothingStyle(context, 16)

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in textView.layoutManager.visibleLines() {
            if selectionRangeMap.intersects(integersIn: linePosition.range) {
                attributes[.foregroundColor] = selectedLineTextColor ?? textColor
            } else {
                attributes[.foregroundColor] = textColor
            }

            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(linePosition.index + 1)", attributes: attributes)
            )
            let fragment: LineFragment? = linePosition.data.lineFragments.first?.data
            var ascent: CGFloat = 0
            let lineNumberWidth = CTLineGetTypographicBounds(ctLine, &ascent, nil, nil)

            let yPos = linePosition.yPos + ascent + (fragment?.heightDifference ?? 0)/2
            // Leading padding + (width - linewidth)
            let xPos = edgeInsets.leading + (maxWidth - lineNumberWidth)

            context.textPosition = CGPoint(x: xPos, y: yPos).pixelAligned
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    // xherdr patch
    private func drawLineChanges(_ context: CGContext) {
        guard let textView, !lineChanges.isEmpty else { return }
        let visible = Array(textView.layoutManager.visibleLines())
        guard let firstLine = visible.first?.index, let lastLine = visible.last?.index else { return }
        let lineCount = textView.layoutManager.lineCount
        // Changes are sorted and don't overlap, so the first visible one is found by binary search.
        var low = 0, high = lineChanges.count
        while low < high {
            let middle = (low + high) / 2
            let change = lineChanges[middle]
            if change.line + max(change.count, 1) <= firstLine { low = middle + 1 } else { high = middle }
        }
        let xPos = backgroundEdgeInsets.leading
        context.saveGState()
        for change in lineChanges[low...] {
            guard change.line <= lastLine + 1 else { break }
            let color: NSColor
            switch change.kind {
            case .added: color = lineChangeColors.added
            case .modified: color = lineChangeColors.modified
            case .deleted: color = lineChangeColors.deleted
            }
            if change.kind == .deleted {
                // A deletion at the end of the text sits on the last line's bottom edge.
                let edge: CGFloat
                if change.line < lineCount, let line = textView.layoutManager.textLineForIndex(change.line) {
                    edge = line.yPos
                } else if let line = textView.layoutManager.textLineForIndex(min(change.line, lineCount) - 1) {
                    edge = line.yPos + line.height
                } else {
                    continue
                }
                let size = lineChangeWidth * 2
                context.beginPath()
                context.move(to: CGPoint(x: xPos, y: edge - size))
                context.addLine(to: CGPoint(x: xPos + size, y: edge))
                context.addLine(to: CGPoint(x: xPos, y: edge + size))
                context.closePath()
                context.setFillColor(color.withAlphaComponent(change.isStaged ? 0.5 : 1).cgColor)
                context.fillPath()
                continue
            }
            let first = max(change.line, firstLine)
            let last = min(change.line + change.count - 1, lastLine, lineCount - 1)
            guard first <= last,
                  let top = textView.layoutManager.textLineForIndex(first),
                  let bottom = textView.layoutManager.textLineForIndex(last) else { continue }
            let rect = CGRect(x: xPos, y: top.yPos, width: lineChangeWidth, height: bottom.yPos + bottom.height - top.yPos)
            if change.isStaged {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            } else {
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
        }
        context.restoreGState()
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        CATransaction.begin()
        superview?.clipsToBounds = false
        superview?.layer?.masksToBounds = false
        updateWidthIfNeeded()
        drawBackground(context)
        drawSelectedLines(context)
        drawLineChanges(context)
        drawLineNumbers(context)
        CATransaction.commit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        delegate = nil
        textView = nil
    }
}

//
//  LineFragmentView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/14/23.
//

import AppKit
import CodeEditTextViewObjC

/// Displays a line fragment.
final class LineFragmentView: NSView {
    private weak var lineFragment: LineFragment?

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Prepare the view for reuse, clears the line fragment reference.
    override func prepareForReuse() {
        super.prepareForReuse()
        lineFragment = nil
    }

    /// Set a new line fragment for this view, updating view size.
    /// - Parameter newFragment: The new fragment to use.
    public func setLineFragment(_ newFragment: LineFragment) {
        self.lineFragment = newFragment
        self.frame.size = CGSize(width: newFragment.width, height: newFragment.scaledHeight)
    }

    /// Draws the line fragment in the graphics context.
    override func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()

        // wooloo: inherit AppKit's native smoothing policy, as the terminal does.
        // Private smoothing overrides produced a different stroke weight here.
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)

        context.textMatrix = .init(scaleX: 1, y: -1)
        let baseline = CGPoint(
            x: 0,
            y: lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
        )
        // Align in device pixels, including the fragment's translated origin.
        let deviceBaseline = context.convertToDeviceSpace(baseline)
        context.textPosition = context.convertToUserSpace(
            CGPoint(x: deviceBaseline.x.rounded(), y: deviceBaseline.y.rounded())
        )

        CTLineDraw(lineFragment.ctLine, context)
        context.restoreGState()
    }
}

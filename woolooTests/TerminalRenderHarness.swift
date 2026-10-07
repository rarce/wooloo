import AppKit
@testable import wooloo

/// Builds the terminal view the way `TerminalPaneView.makeNSView` does and draws it offscreen.
@MainActor
enum TerminalRenderHarness {
    static let theme = WoolooTheme.named(WoolooTheme.fallbackID)!

    static func makeView(width: Int, height: Int) -> HerdrTerminalTextView {
        let view = HerdrTerminalTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.drawsBackground = false
        view.font = TerminalPaneView.terminalFont
        view.textColor = theme.terminalForeground
        view.textContainerInset = NSSize(width: 10, height: 9)
        // A live surface keeps the view at the grid's size, as `configureScrolling` does.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.frame = NSRect(x: 0, y: 0,
                            width: ceil(CGFloat(width) * TerminalPaneView.cellWidth) + 20,
                            height: ceil(CGFloat(height) * TerminalPaneView.cellHeight) + 18)
        return view
    }

    /// Hands a surface to the view as the live surface feed does.
    static func show(_ surface: HerdrSurface, in view: HerdrTerminalTextView) {
        view.theme = theme
        view.show(surface)
    }

    static func makeBitmap(for view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
        let size = view.bounds.size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(ceil(size.width * scale)),
                                      pixelsHigh: Int(ceil(size.height * scale)),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        return bitmap
    }

    /// Draws the view over the theme's terminal background, as the scroll view shows it.
    static func draw(_ view: NSView, into bitmap: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        theme.terminalBackground.setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func render(_ surface: HerdrSurface) -> NSBitmapImageRep {
        let view = makeView(width: surface.width, height: surface.height)
        show(surface, in: view)
        let bitmap = makeBitmap(for: view)
        draw(view, into: bitmap)
        return bitmap
    }

    /// Premultiplied RGBA bytes, so bitmaps from different sources compare byte for byte.
    static func pixels(of bitmap: NSBitmapImageRep) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let image = bitmap.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? (image.width, image.height, bytes) : nil
    }
}

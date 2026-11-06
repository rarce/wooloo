import AppKit
import BeautifulMermaid
import SwiftUI

/// One vector image shared by the inline preview and viewer; gestures never parse or lay out again.
enum MermaidVectorImage {
    static func render(source: String, theme: DiagramTheme) async throws -> NSImage {
        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            guard let prepared = try MermaidImageRenderer(theme: theme).prepare(from: source) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = NSMutableData()
            var bounds = prepared.bounds
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            context.beginPDFPage(nil)
            context.setFillColor(theme.background.cgColor)
            context.fill(bounds)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            prepared.render(context, bounds)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }.value
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
}

/// Coordinates use a top-left origin. Offset is the diagram center relative to the viewport center.
struct MermaidViewport {
    let contentSize: CGSize
    private(set) var size = CGSize.zero
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGSize.zero
    private(set) var isFitted = true
    private let margin: CGFloat = 24

    var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return min(1, max(1, size.width - margin * 2) / contentSize.width,
                   max(1, size.height - margin * 2) / contentSize.height)
    }

    var minimumScale: CGFloat { min(0.1, fitScale) }
    var maximumScale: CGFloat { 8 }

    var imageRect: CGRect {
        CGRect(x: (size.width - contentSize.width * scale) / 2 + offset.width,
               y: (size.height - contentSize.height * scale) / 2 + offset.height,
               width: contentSize.width * scale, height: contentSize.height * scale)
    }

    mutating func resize(_ newSize: CGSize) {
        size = newSize
        if isFitted { fit() } else { clampOffset() }
    }

    mutating func fit() {
        scale = fitScale
        offset = .zero
        isFitted = true
    }

    mutating func zoom(to proposed: CGFloat, anchor: CGPoint? = nil) {
        guard proposed.isFinite, proposed > 0 else { return }
        let next = min(maximumScale, max(minimumScale, proposed))
        let point = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let relative = CGSize(width: point.x - size.width / 2, height: point.y - size.height / 2)
        offset = CGSize(width: relative.width - (relative.width - offset.width) * next / scale,
                        height: relative.height - (relative.height - offset.height) * next / scale)
        scale = next
        isFitted = false
        clampOffset()
    }

    mutating func pan(_ delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        clampOffset()
    }

    private mutating func clampOffset() {
        let x = max(0, (contentSize.width * scale - size.width) / 2 + margin)
        let y = max(0, (contentSize.height * scale - size.height) / 2 + margin)
        offset.width = min(x, max(-x, offset.width))
        offset.height = min(y, max(-y, offset.height))
    }
}

struct MermaidDiagramViewer: View {
    let image: NSImage
    let theme: WoolooTheme
    let onClose: () -> Void
    @State private var viewport: MermaidViewport

    init(image: NSImage, theme: WoolooTheme, onClose: @escaping () -> Void) {
        self.image = image
        self.theme = theme
        self.onClose = onClose
        _viewport = State(initialValue: MermaidViewport(contentSize: image.size))
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                toolbar(labels: true)
                toolbar(labels: false)
            }
            .padding(8)
            .background(theme.sidebarBackground)
            MermaidCanvas(image: image, viewport: $viewport, onClose: onClose)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport.resize($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(theme.contentBackground)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .environment(\.colorScheme, theme.colorScheme)
        .onExitCommand(perform: onClose)
    }

    private func toolbar(labels: Bool) -> some View {
        HStack(spacing: 8) {
            if labels { Text("Mermaid").font(.headline); Spacer(minLength: 0) }
            Button { viewport.zoom(to: viewport.scale / 1.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (−)")
            .accessibilityLabel("Zoom out")
            .disabled(viewport.scale <= viewport.minimumScale)
            Text(viewport.scale < 0.01 ? String(format: "%.1f%%", viewport.scale * 100)
                 : "\(Int((viewport.scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 42)
                .accessibilityLabel("Zoom")
                .accessibilityValue(String(format: "%.1f percent", viewport.scale * 100))
            Button { viewport.zoom(to: viewport.scale * 1.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (+)")
            .accessibilityLabel("Zoom in")
            .disabled(viewport.scale >= viewport.maximumScale)
            Button("100%") { viewport.zoom(to: 1) }
                .help("Actual size (0)")
            Button { viewport.fit() } label: {
                if labels { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                else { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
            }
            .help("Fit diagram to panel (F)")
            .accessibilityLabel("Fit diagram to panel")
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Close diagram (Escape)")
                .accessibilityLabel("Close diagram")
                .accessibilityIdentifier("mermaid-close")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

private struct MermaidCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var viewport: MermaidViewport
    let onClose: () -> Void

    func makeNSView(context: Context) -> MermaidCanvasView { MermaidCanvasView() }

    func updateNSView(_ view: MermaidCanvasView, context: Context) {
        view.image = image
        view.imageRect = viewport.imageRect
        view.onPan = { viewport.pan($0) }
        view.onZoom = { factor, point in viewport.zoom(to: viewport.scale * factor, anchor: point) }
        view.onFit = { viewport.fit() }
        view.onActualSize = { viewport.zoom(to: 1) }
        view.onClose = onClose
        view.needsDisplay = true
    }
}

/// Draws only the visible viewport. Zoom never allocates a diagram-sized bitmap or view.
final class MermaidCanvasView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            let data = (image?.representations.first { $0 is NSPDFImageRep } as? NSPDFImageRep)?.pdfRepresentation
            pdfPage = data.flatMap { CGDataProvider(data: $0 as CFData) }
                .flatMap { CGPDFDocument($0)?.page(at: 1) }
        }
    }
    private var pdfPage: CGPDFPage?
    var imageRect = CGRect.zero
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((CGFloat, CGPoint?) -> Void)?
    var onFit: (() -> Void)?
    var onActualSize: (() -> Void)?
    var onClose: (() -> Void)?
    private weak var previousResponder: NSResponder?
    private var dragPoint = CGPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Mermaid diagram. Drag or scroll to pan; pinch or use plus and minus to zoom.")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window?.firstResponder === self {
            window?.makeFirstResponder(previousResponder)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfPage, let context = NSGraphicsContext.current?.cgContext else { return }
        let page = pdfPage.getBoxRect(.mediaBox)
        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: imageRect.minX, y: imageRect.maxY)
        context.scaleBy(x: imageRect.width / page.width, y: -imageRect.height / page.height)
        context.drawPDFPage(pdfPage)
        context.restoreGState()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPan?(CGSize(width: point.x - dragPoint.x, height: point.y - dragPoint.y))
        dragPoint = point
    }

    override func scrollWheel(with event: NSEvent) {
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        onPan?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(max(0.01, 1 + event.magnification), convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()
        case 123: onPan?(CGSize(width: 40, height: 0))
        case 124: onPan?(CGSize(width: -40, height: 0))
        case 125: onPan?(CGSize(width: 0, height: -40))
        case 126: onPan?(CGSize(width: 0, height: 40))
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "+", "=": onZoom?(1.25, nil)
            case "-": onZoom?(1 / 1.25, nil)
            case "0": onActualSize?()
            case "f": onFit?()
            default: super.keyDown(with: event)
            }
        }
    }
}

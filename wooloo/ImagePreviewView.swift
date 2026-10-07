import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Decode on a worker using the same bounded local/SSH reads as other documents.
enum WorkspaceImage {
    static let maximumFileBytes = 50 * 1_024 * 1_024
    static let maximumPreviewDimension = 4_096
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "webp", "heic", "heif", "avif", "tif", "tiff", "bmp", "ico"]

    static func supports(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    struct Contents {
        let image: CGImage
        let size: CGSize
        let byteCount: Int
        let frameCount: Int
        let format: String
        let version: String
        var isDownsampled: Bool { size.width > CGFloat(image.width) || size.height > CGFloat(image.height) }
    }

    static func read(_ path: String, at location: WorkspaceFileLocation) throws -> Contents {
        let data = try WorkspaceFiles.readData(path, at: location, limit: maximumFileBytes)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Contents {
        guard data.count <= maximumFileBytes else { throw WorkspaceFileError.message("Image file is too large (maximum 50 MiB)") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw WorkspaceFileError.message("This file is not a readable image")
        }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 100_000, h <= 100_000 else {
            throw WorkspaceFileError.message("This image has invalid dimensions")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPreviewDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WorkspaceFileError.message("This image format could not be decoded by macOS")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let format = type?.preferredFilenameExtension?.uppercased() ?? "Image"
        return Contents(image: image, size: size, byteCount: data.count, frameCount: CGImageSourceGetCount(source),
                        format: format, version: WorkspaceFiles.gitBlobHash(data))
    }
}

/// Zoom and the visible center belong to the tab, so changing tabs does not reset the preview.
@MainActor
final class ImagePreviewModel: ObservableObject {
    @Published private(set) var contents: WorkspaceImage.Contents
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var fitsWindow = true
    private weak var view: ImageScrollView?
    private var center = CGPoint(x: 0.5, y: 0.5)

    init(contents: WorkspaceImage.Contents) { self.contents = contents }

    func replace(with next: WorkspaceImage.Contents) {
        capturePosition()
        contents = next
        view?.canvas.image = NSImage(cgImage: next.image, size: next.size)
        layout()
    }

    func attach(_ view: ImageScrollView) {
        self.view = view
        view.canvas.image = NSImage(cgImage: contents.image, size: contents.size)
        layout()
    }

    func detach(_ view: ImageScrollView) {
        guard self.view === view else { return }
        capturePosition()
        self.view = nil
    }

    func zoom(_ factor: CGFloat) {
        capturePosition()
        fitsWindow = false
        scale = (scale * factor).clamped(to: 0.01...16)
        layout()
    }

    func actualSize() {
        capturePosition()
        fitsWindow = false
        scale = 1
        layout()
    }

    func fitWindow() {
        fitsWindow = true
        center = CGPoint(x: 0.5, y: 0.5)
        layout()
    }

    func capturePosition() {
        guard let view, view.canvas.imageRect.width > 0, view.canvas.imageRect.height > 0 else { return }
        let visible = view.contentView.bounds
        let rect = view.canvas.imageRect
        center = CGPoint(x: ((visible.midX - rect.minX) / rect.width).clamped(to: 0...1),
                         y: ((visible.midY - rect.minY) / rect.height).clamped(to: 0...1))
    }

    func layout() {
        guard let view else { return }
        let viewport = view.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        if fitsWindow {
            let next = min(1, max(1, viewport.width - 48) / contents.size.width,
                           max(1, viewport.height - 48) / contents.size.height)
            if scale != next { scale = next }
        }
        let size = CGSize(width: contents.size.width * scale, height: contents.size.height * scale)
        view.canvas.setFrameSize(CGSize(width: max(viewport.width, size.width + 48),
                                       height: max(viewport.height, size.height + 48)))
        let rect = CGRect(x: (view.canvas.bounds.width - size.width) / 2,
                          y: (view.canvas.bounds.height - size.height) / 2, width: size.width, height: size.height)
        view.canvas.imageRect = rect
        view.canvas.needsDisplay = true
        let origin = CGPoint(x: rect.minX + center.x * rect.width - viewport.width / 2,
                             y: rect.minY + center.y * rect.height - viewport.height / 2)
        view.contentView.scroll(to: view.contentView.constrainBoundsRect(CGRect(origin: origin, size: viewport)).origin)
        view.reflectScrolledClipView(view.contentView)
    }
}

struct ImagePreviewView: View {
    @Environment(\.woolooTheme) private var theme
    @Environment(\.woolooTypography) private var typography
    @ObservedObject var model: ImagePreviewModel
    let focusRequest: UUID?
    let onFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(Int(model.contents.size.width)) × \(Int(model.contents.size.height)) px")
                    .monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: Int64(model.contents.byteCount), countStyle: .file))
                    .foregroundStyle(theme.subtext)
                Spacer(minLength: 8)
                Button { model.zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out").accessibilityLabel("Zoom Out")
                    .disabled(model.scale <= 0.01)
                Text("\(Int((model.scale * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 44)
                Button { model.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In").accessibilityLabel("Zoom In")
                    .disabled(model.scale >= 16)
                Button("Actual Size") { model.actualSize() }
                    .help("Show one image pixel per point")
                Button("Fit") { model.fitWindow() }
                    .help("Fit the image inside the window")
            }
            .font(.system(size: typography.body))
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()
            ImageNativeView(model: model, background: NSColor(theme.contentBackground),
                            focusRequest: focusRequest, onFocus: onFocus)
            if model.contents.frameCount > 1 || model.contents.isDownsampled {
                Text(model.contents.frameCount > 1
                     ? "First frame of \(model.contents.frameCount)\(model.contents.isDownsampled ? " · Reduced resolution preview" : "")"
                     : "Reduced resolution preview")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                    .padding(6)
            }
        }
    }
}

struct ImageNativeView: NSViewRepresentable {
    let model: ImagePreviewModel
    let background: NSColor
    let focusRequest: UUID?
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.hasHorizontalScroller = true
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = true
        view.backgroundColor = background
        view.documentView = view.canvas
        view.onWillResize = { [weak model] in model?.capturePosition() }
        view.onResize = { [weak model] in model?.layout() }
        model.attach(view)
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.backgroundColor = background
        if let focusRequest, context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                onFocus()
            }
        }
    }

    static func dismantleNSView(_ view: ImageScrollView, coordinator: Coordinator) {
        coordinator.model.detach(view)
        view.onResize = nil
        view.onWillResize = nil
    }

    final class Coordinator {
        let model: ImagePreviewModel
        var focusRequest: UUID?
        init(model: ImagePreviewModel) { self.model = model }
    }
}

final class ImageScrollView: NSScrollView {
    let canvas = ImageCanvasView()
    var onResize: (() -> Void)?
    var onWillResize: (() -> Void)?
    private var lastViewport = CGSize.zero
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize, frame.width > 0, frame.height > 0 { onWillResize?() }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        if contentView.bounds.size != lastViewport {
            lastViewport = contentView.bounds.size
            onResize?()
        }
    }
}

final class ImageCanvasView: NSView {
    var image: NSImage?
    var imageRect = CGRect.zero
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image preview")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, imageRect.width > 0, imageRect.height > 0 else { return }
        let visible = dirtyRect.intersection(imageRect)
        guard !visible.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        imageRect.clip()
        NSColor(white: 0.9, alpha: 1).setFill()
        visible.fill()
        let cell: CGFloat = 12
        let firstX = Int(floor((visible.minX - imageRect.minX) / cell))
        let lastX = Int(ceil((visible.maxX - imageRect.minX) / cell))
        let firstY = Int(floor((visible.minY - imageRect.minY) / cell))
        let lastY = Int(ceil((visible.maxY - imageRect.minY) / cell))
        NSColor(white: 0.75, alpha: 1).setFill()
        for row in firstY..<lastY {
            for column in firstX..<lastX where (row + column) % 2 == 0 {
                CGRect(x: imageRect.minX + CGFloat(column) * cell,
                       y: imageRect.minY + CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

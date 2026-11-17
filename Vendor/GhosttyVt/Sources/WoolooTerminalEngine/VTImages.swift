import Foundation
import GhosttyVt
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// An image a program placed with the kitty graphics protocol, where the viewport shows it.
public struct TerminalImage: Equatable, Sendable {
    public enum Format: Sendable { case rgb, rgba }

    /// Changes whenever the image's pixels change; a cache key with the image's id.
    public let identity: String
    public let width: Int
    public let height: Int
    public let format: Format
    public let pixels: Data
    /// The top-left cell in the viewport; negative when the image starts above it.
    public let column: Int
    public let row: Int
    public let cols: Int
    public let rows: Int
    public let offsetX: Int
    public let offsetY: Int
    public let sourceX: Int
    public let sourceY: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// Whether it is drawn below the text, as the program asked with a negative z-index.
    public let belowText: Bool
    public let z: Int

    public init(identity: String, width: Int, height: Int, format: Format, pixels: Data, column: Int, row: Int,
                cols: Int, rows: Int, offsetX: Int = 0, offsetY: Int = 0, sourceX: Int = 0, sourceY: Int = 0,
                sourceWidth: Int, sourceHeight: Int, belowText: Bool = false, z: Int = 0) {
        self.identity = identity
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
        self.column = column
        self.row = row
        self.cols = cols
        self.rows = rows
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.belowText = belowText
        self.z = z
    }
}

/// Process-wide hooks libghostty-vt needs from the platform, set once before the first terminal.
enum VTSystem {
    static let installed: Void = {
        #if canImport(ImageIO)
        // PNG payloads of the kitty graphics protocol are decoded with ImageIO into the
        // straight RGBA libghostty-vt stores.
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, length > 0, let out,
                  let source = CGImageSourceCreateWithData(Data(bytes: data, count: length) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let width = image.width, height = image.height
            guard width > 0, height > 0, width <= 10_000, height <= 10_000 else { return false }
            let count = width * height * 4
            guard let buffer = ghostty_alloc(allocator, count) else { return false }
            guard let context = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                ghostty_free(allocator, buffer, count)
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Core Graphics draws premultiplied; the protocol's pixels are straight alpha.
            for pixel in stride(from: 0, to: count, by: 4) {
                let alpha = Int(buffer[pixel + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    buffer[pixel + channel] = UInt8(min(255, (Int(buffer[pixel + channel]) * 255 + alpha / 2) / alpha))
                }
            }
            out.pointee = GhosttySysImage(width: UInt32(width), height: UInt32(height), data: buffer, data_len: count)
            return true
        }
        _ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
        #endif
    }()
}

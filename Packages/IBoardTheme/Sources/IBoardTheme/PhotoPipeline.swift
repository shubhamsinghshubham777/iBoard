import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pixel size the keyboard draws a photo backdrop at, for one orientation.
public struct PhotoTarget: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public init(pixelWidth: Int, pixelHeight: Int) { self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight }

    /// Exact pixel size from the keyboard's point size and the display scale (rounded, at least 1).
    public static func keyboard(widthPoints: Double, heightPoints: Double, scale: Double) -> PhotoTarget {
        PhotoTarget(pixelWidth: max(1, Int((widthPoints * scale).rounded())),
                    pixelHeight: max(1, Int((heightPoints * scale).rounded())))
    }
}

public enum PhotoPipelineError: Error, Equatable, Sendable {
    case unreadableImage
    case invalidTarget
    case encodeFailed
    case tooLargeSource(pixels: Int)
}

public enum PhotoOrientation: String, Sendable, CaseIterable {
    case portrait, landscape
    var suffix: String { self == .portrait ? "p" : "l" }
}

/// Photo backdrop pipeline (M8-02). Pure function from encoded image bytes to a JPEG at the keyboard's exact pixel
/// size: the keyboard never decodes anything larger than it draws (memory budget P-21). The source is decoded with
/// ImageIO's thumbnail API so the full-size bitmap is never materialised.
public enum PhotoPipeline {
    /// Hard cap on the source pixel count (decompression-bomb guard), 100 MP.
    public static let maxSourcePixels = 100_000_000
    public static let maxTargetPixels = 4096 * 4096

    /// Asset file name for a photo token and orientation. The theme's `photoAsset` holds only the token.
    public static func assetName(token: String, orientation: PhotoOrientation) -> String {
        "\(token)-\(orientation.suffix).jpg"
    }

    /// Returns JPEG data of exactly `target.pixelWidth x target.pixelHeight`, aspect-fill centre-cropped.
    public static func process(_ source: Data, target: PhotoTarget, quality: Double = 0.8) throws -> Data {
        guard target.pixelWidth > 0, target.pixelHeight > 0,
              target.pixelWidth * target.pixelHeight <= maxTargetPixels else { throw PhotoPipelineError.invalidTarget }
        guard let src = CGImageSourceCreateWithData(source as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { throw PhotoPipelineError.unreadableImage }
        guard w * h <= maxSourcePixels else { throw PhotoPipelineError.tooLargeSource(pixels: w * h) }

        // Scale so the image covers the target; the thumbnail API applies EXIF orientation and downsamples cheaply.
        let tw = Double(target.pixelWidth), th = Double(target.pixelHeight)
        let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let sw = Double(rotated ? h : w), sh = Double(rotated ? w : h)
        let scale = max(tw / sw, th / sh)
        let maxDim = Int((max(sw, sh) * min(scale, 1)).rounded(.up))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDim, 1),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw PhotoPipelineError.unreadableImage
        }

        // Draw aspect-fill, centred, into an opaque sRGB bitmap of the exact target size.
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: target.pixelWidth, height: target.pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PhotoPipelineError.encodeFailed }
        ctx.interpolationQuality = .high
        let iw = Double(thumb.width), ih = Double(thumb.height)
        let fill = max(tw / iw, th / ih)
        let dw = iw * fill, dh = ih * fill
        ctx.draw(thumb, in: CGRect(x: (tw - dw) / 2, y: (th - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage() else { throw PhotoPipelineError.encodeFailed }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoPipelineError.encodeFailed
        }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1)] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoPipelineError.encodeFailed }
        return data as Data
    }

    /// Pixel size of encoded image data (nil when unreadable).
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

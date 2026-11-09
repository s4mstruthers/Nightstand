import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = downsample(source, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Re-encodes any image as JPEG or PNG, capped at `maxPixel` on its longest side.
    static func encode(_ data: Data, as type: UTType, maxPixel: Int = 2000) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsample(source, maxPixel: maxPixel) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Decodes cover thumbnails off the main thread and keeps them in memory.
final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func image(at url: URL, key: String, maxPixel: Int) async -> NSImage? {
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            ImageTools.thumbnail(at: url, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

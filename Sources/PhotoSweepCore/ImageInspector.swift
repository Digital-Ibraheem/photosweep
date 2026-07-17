import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers: dimensions and orientation-corrected thumbnails without decoding full images.
public enum ImageInspector {
    /// Display dimensions (after applying EXIF orientation), read from the header only.
    public static func dimensions(path: String) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// Decodes a downscaled, orientation-corrected image whose longest side is at most `maxPixelSize`.
    /// ImageIO uses embedded thumbnails or subsampled decoding where possible, so the full-size
    /// bitmap is never allocated for large JPEG/HEIC files.
    public static func thumbnail(path: String, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Writes a JPEG thumbnail for the report. Returns false if the image cannot be decoded.
    public static func writeThumbnail(from path: String, to destination: URL, maxPixelSize: Int = 480) -> Bool {
        autoreleasepool {
            guard let image = thumbnail(path: path, maxPixelSize: maxPixelSize),
                  let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
    }
}

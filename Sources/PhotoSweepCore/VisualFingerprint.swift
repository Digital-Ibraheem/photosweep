import CoreGraphics
import Foundation

/// Difference hash (dHash) visual fingerprint.
///
/// 1. Decode an orientation-corrected thumbnail (ImageIO applies EXIF orientation).
/// 2. Reduce it to a 9 × 8 grayscale grid. The image is first drawn at 72 × 64 and each
///    8 × 8 block is averaged, which behaves like an area filter rather than point sampling.
/// 3. For each row, compare each cell with its right neighbour: 8 rows × 8 comparisons = 64 bits.
///
/// Similar images have fingerprints that differ in few bits (small Hamming distance).
/// The fingerprint ignores aspect ratio and is not robust to crops, rotation or mirroring.
public struct VisualFingerprint: Hashable, Sendable {
    /// Bump whenever the algorithm or its normalization changes; cached fingerprints from other
    /// versions are recomputed.
    public static let algorithmVersion = 1

    public var bits: UInt64
    /// True when the image has almost no gradient structure (e.g. a flat colour). Such fingerprints
    /// are mostly zero bits and would "match" every other flat image, so they are not used for matching.
    public var lowDetail: Bool

    public init(bits: UInt64, lowDetail: Bool = false) {
        self.bits = bits
        self.lowDetail = lowDetail
    }

    public func distance(to other: VisualFingerprint) -> Int { (bits ^ other.bits).nonzeroBitCount }

    public var hex: String {
        let s = String(bits, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }

    static let gridWidth = 9, gridHeight = 8, oversample = 8
    /// Mean absolute neighbour difference (0–255 scale) below which an image counts as low detail.
    static let lowDetailThreshold = 1.5

    /// Computes the fingerprint of an image file, or nil if it cannot be decoded.
    public static func compute(path: String) -> VisualFingerprint? {
        autoreleasepool {
            guard let thumb = ImageInspector.thumbnail(path: path, maxPixelSize: 256) else { return nil }
            return compute(image: thumb)
        }
    }

    public static func compute(image: CGImage) -> VisualFingerprint? {
        let w = gridWidth * oversample, h = gridHeight * oversample
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // Composite transparent images onto white so transparency does not read as black.
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Box-average each oversample × oversample block into the 9 × 8 grid.
        var grid = [Double](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            for gx in 0..<gridWidth {
                var sum = 0
                for y in (gy * oversample)..<((gy + 1) * oversample) {
                    let row = y * w
                    for x in (gx * oversample)..<((gx + 1) * oversample) { sum += Int(pixels[row + x]) }
                }
                grid[gy * gridWidth + gx] = Double(sum) / Double(oversample * oversample)
            }
        }

        var bits: UInt64 = 0
        var totalDifference = 0.0
        for y in 0..<gridHeight {
            for x in 0..<(gridWidth - 1) {
                let left = grid[y * gridWidth + x], right = grid[y * gridWidth + x + 1]
                bits <<= 1
                if left > right { bits |= 1 }
                totalDifference += abs(left - right)
            }
        }
        let meanDifference = totalDifference / Double(gridHeight * (gridWidth - 1))
        return VisualFingerprint(bits: bits, lowDetail: meanDifference < lowDetailThreshold)
    }
}

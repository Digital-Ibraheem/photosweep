import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoSweepCore

/// A temporary directory removed when the value is deinitialized.
final class TempDir {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appendingPathComponent("photosweep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file.path
    }

    func file(_ relative: String) -> String { url.appendingPathComponent(relative).path }
}

/// Deterministic pseudo-random generator for reproducible test images.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum TestImages {
    /// A photo-like image: smooth random blobs on a gradient, unique per seed.
    static func make(seed: UInt64, width: Int = 320, height: Int = 240) -> CGImage {
        var rng = SplitMix64(state: seed)
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func rand() -> CGFloat { CGFloat(Double(rng.next() % 10_000) / 10_000) }
        ctx.setFillColor(red: rand(), green: rand(), blue: rand(), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<14 {
            ctx.setFillColor(red: rand(), green: rand(), blue: rand(), alpha: 0.85)
            let w = CGFloat(width) * (0.15 + rand() * 0.5)
            let h = CGFloat(height) * (0.15 + rand() * 0.5)
            ctx.fillEllipse(in: CGRect(x: rand() * CGFloat(width) - w / 2, y: rand() * CGFloat(height) - h / 2, width: w, height: h))
        }
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType = .jpeg, quality: Double = 0.9, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func jpeg(seed: UInt64, width: Int = 320, height: Int = 240) -> Data {
        encode(make(seed: seed, width: width, height: height))
    }
}

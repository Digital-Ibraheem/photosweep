import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Generates a larger, photo-sized collection for benchmarks from the fixture sources.
///
/// Each image is a source photo upscaled to `longSide` pixels with a deterministic crop offset,
/// brightness change and grain, so every unique image has distinct content and realistic JPEG size.
/// About 10% of files are byte-identical copies and 10% are resized near-duplicates.
public struct BenchmarkData {
    public var sourcesDirectory: URL
    public var outputDirectory: URL
    public var count: Int
    public var longSide: Int

    public init(sourcesDirectory: URL, outputDirectory: URL, count: Int, longSide: Int = 2400) {
        self.sourcesDirectory = sourcesDirectory
        self.outputDirectory = outputDirectory
        self.count = count
        self.longSide = longSide
    }

    public struct Summary: Sendable {
        public var files: Int
        public var bytes: Int64
    }

    public func generate() throws -> Summary {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDirectory.path) { try fm.removeItem(at: outputDirectory) }
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sources = try fm.contentsOfDirectory(atPath: sourcesDirectory.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let images = sources.compactMap { ImageTransforms.load(sourcesDirectory.appendingPathComponent($0).path) }

        let uniqueCount = Int(Double(count) * 0.8)
        let out = outputDirectory
        let side = longSide
        // Unique images, generated in parallel.
        DispatchQueue.concurrentPerform(iterations: uniqueCount) { i in
            autoreleasepool {
                var rng = SeededRandom(seed: UInt64(i) &* 0x9E37_79B9 &+ 17)
                let base = images[i % images.count]
                let img = Self.variant(of: base, longSide: side, rng: &rng)
                let folder = String(format: "Year%d/Album%02d", 2015 + i % 10, i / 100 % 40)
                try? ImageTransforms.write(img, to: out.appendingPathComponent("\(folder)/IMG_\(String(format: "%05d", i)).jpg").path, quality: 0.85)
            }
        }
        // Exact copies and resized near-duplicates of the first unique images.
        let extra = count - uniqueCount
        for j in 0..<extra {
            let i = j / 2
            let folder = String(format: "Year%d/Album%02d", 2015 + i % 10, i / 100 % 40)
            let original = out.appendingPathComponent("\(folder)/IMG_\(String(format: "%05d", i)).jpg")
            if j % 2 == 0 {
                let dest = out.appendingPathComponent("Backups/\(folder)/IMG_\(String(format: "%05d", i)) copy.jpg")
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: dest)
            } else if let img = ImageTransforms.load(original.path) {
                try ImageTransforms.write(ImageTransforms.resized(img, scale: 0.5),
                    to: out.appendingPathComponent("Shared/IMG_\(String(format: "%05d", i))-small.jpg").path, quality: 0.75)
            }
        }
        var total: Int64 = 0, files = 0
        for case let path as String in fm.enumerator(atPath: out.path)! where path.hasSuffix(".jpg") {
            files += 1
            total += (try? fm.attributesOfItem(atPath: out.appendingPathComponent(path).path)[.size] as? Int64) ?? 0
        }
        return Summary(files: files, bytes: total)
    }

    static func variant(of base: CGImage, longSide: Int, rng: inout SeededRandom) -> CGImage {
        let aspect = Double(base.height) / Double(base.width)
        let w = base.width >= base.height ? longSide : Int(Double(longSide) / aspect)
        let h = base.width >= base.height ? Int(Double(longSide) * aspect) : longSide
        let ctx = ImageTransforms.context(w, h)
        ctx.interpolationQuality = .high
        // Zoom and pan so every unique image differs visibly from others made from the same source.
        let zoom = 1.15 + rng.unit() * 0.6
        let dw = Double(w) * zoom, dh = Double(h) * zoom
        ctx.draw(base, in: CGRect(x: -rng.unit() * (dw - Double(w)), y: -rng.unit() * (dh - Double(h)), width: dw, height: dh))
        // Tint and grain so files have realistic entropy (and size).
        ctx.setFillColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.12)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                let n = Int(rng.next() % 17) - 8
                for c in 0..<3 { data[o + c] = UInt8(clamping: Int(data[o + c]) + n) }
            }
        }
        return ctx.makeImage()!
    }
}

/// Small deterministic PRNG (SplitMix64).
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

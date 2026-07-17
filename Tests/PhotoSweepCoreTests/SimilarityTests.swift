import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PhotoSweepCore

@Suite struct FingerprintTests {
    func fingerprint(_ data: Data, in dir: TempDir, name: String) throws -> VisualFingerprint {
        let path = try dir.write(name, data)
        return try #require(VisualFingerprint.compute(path: path))
    }

    @Test func resizedAndRecompressedCopiesAreClose() throws {
        let dir = try TempDir()
        let original = TestImages.make(seed: 42, width: 640, height: 480)
        let a = try fingerprint(TestImages.encode(original), in: dir, name: "a.jpg")
        let small = TestImages.make(seed: 42, width: 320, height: 240)
        let b = try fingerprint(TestImages.encode(small, quality: 0.3), in: dir, name: "b.jpg")
        let c = try fingerprint(TestImages.encode(original, type: .png), in: dir, name: "c.png")
        #expect(a.distance(to: b) <= 4)
        #expect(a.distance(to: c) <= 2)
    }

    @Test func unrelatedImagesAreFar() throws {
        let dir = try TempDir()
        var distances: [Int] = []
        let fps = try (0..<8).map { try fingerprint(TestImages.jpeg(seed: UInt64(1000 + $0)), in: dir, name: "\($0).jpg") }
        for i in fps.indices { for j in fps.indices where j > i { distances.append(fps[i].distance(to: fps[j])) } }
        #expect(distances.min()! > SimilarityMatcher.defaultThreshold)
    }

    @Test func orientationMetadataIsNormalized() throws {
        let dir = try TempDir()
        let upright = TestImages.make(seed: 5, width: 400, height: 300)
        // Store the pixels rotated 90° clockwise, tagged with orientation 8 (rotate 90° CCW to display).
        let rotated = rotateClockwise(upright)
        let a = try fingerprint(TestImages.encode(upright), in: dir, name: "a.jpg")
        let tagged = try fingerprint(TestImages.encode(rotated, orientation: 8), in: dir, name: "tagged.jpg")
        let untagged = try fingerprint(TestImages.encode(rotated), in: dir, name: "untagged.jpg")
        #expect(a.distance(to: tagged) <= 4)
        #expect(a.distance(to: untagged) > SimilarityMatcher.defaultThreshold) // documented limitation
        #expect(ImageInspector.dimensions(path: dir.file("tagged.jpg"))! == (400, 300))
    }

    @Test func flatImagesAreLowDetail() throws {
        let dir = try TempDir()
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let fp = try fingerprint(TestImages.encode(ctx.makeImage()!), in: dir, name: "flat.jpg")
        #expect(fp.lowDetail)
        #expect(try !fingerprint(TestImages.jpeg(seed: 9), in: dir, name: "busy.jpg").lowDetail)
    }

    @Test func undecodableFileHasNoFingerprint() throws {
        let dir = try TempDir()
        let path = try dir.write("bad.jpg", Data("not an image".utf8))
        #expect(VisualFingerprint.compute(path: path) == nil)
    }

    func rotateClockwise(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }
}

@Suite struct MatcherTests {
    func item(_ name: String, _ bits: UInt64, pixels: Int = 100) -> VisualItem {
        VisualItem(path: "/r/\(name)", fingerprint: VisualFingerprint(bits: bits), pixelCount: pixels, size: 1)
    }

    @Test func chainsAreNotMergedThroughIntermediates() {
        // A ~ B (8 bits) and B ~ C (8 bits) but A and C differ by 16 bits.
        let a = item("a", 0, pixels: 300), b = item("b", 0xFF, pixels: 200), c = item("c", 0xFFFF, pixels: 100)
        let groups = SimilarityMatcher.group([a, b, c], threshold: 10)
        #expect(groups.count == 1)
        #expect(groups[0].map(\.item) == [0, 1])
        #expect(groups[0].map(\.distance) == [0, 8])
    }

    @Test func everyMemberMatchesItsRepresentative() {
        var rng = SplitMix64(state: 7)
        let items = (0..<400).map { i in item("\(i)", rng.next() & 0xFFFF_0000_0000_FFFF, pixels: Int(rng.next() % 1000)) }
        for group in SimilarityMatcher.group(items, threshold: 12) {
            let rep = items[group[0].item].fingerprint
            for m in group { #expect(items[m.item].fingerprint.distance(to: rep) <= 12) }
        }
    }

    @Test func bkTreeMatchesLinearScan() {
        var rng = SplitMix64(state: 99)
        // Clustered fingerprints so that searches return non-trivial neighbour sets.
        let centers = (0..<30).map { _ in rng.next() }
        let items = (0..<3000).map { i -> VisualItem in
            var bits = centers[Int(rng.next() % 30)]
            for _ in 0..<Int(rng.next() % 12) { bits ^= 1 << (rng.next() % 64) }
            return item("\(i)", bits, pixels: Int(rng.next() % 5000))
        }
        let linear = LinearIndex(items), tree = BKTreeIndex(items)
        for radius in [0, 4, 10, 16] {
            for q in items.prefix(200) {
                #expect(Set(linear.neighbors(of: q.fingerprint, within: radius)) == Set(tree.neighbors(of: q.fingerprint, within: radius)))
            }
        }
        let g1 = SimilarityMatcher.group(items, threshold: 10, index: LinearIndex.self)
        let g2 = SimilarityMatcher.group(items, threshold: 10, index: BKTreeIndex.self)
        #expect(g1.map { $0.map(\.item) } == g2.map { $0.map(\.item) })
    }
}

@Suite struct VisualScanTests {
    @Test func scanFindsSimilarGroupsSeparatelyFromExact() async throws {
        let dir = try TempDir()
        let big = TestImages.make(seed: 11, width: 800, height: 600)
        try dir.write("lake.jpg", TestImages.encode(big))
        try dir.write("copies/lake.jpg", TestImages.encode(big))           // exact copy
        try dir.write("small/lake.jpg", TestImages.encode(TestImages.make(seed: 11, width: 400, height: 300), quality: 0.5))
        try dir.write("other.jpg", TestImages.jpeg(seed: 12))
        let m = try await Scanner(options: ScanOptions(root: dir.url)).run()
        #expect(m.exactGroups.count == 1)
        #expect(m.similarGroups.count == 1)
        let g = m.similarGroups[0]
        #expect(g.members.count == 2)
        #expect(g.keep.hasSuffix("/lake.jpg") && !g.keep.contains("small"))
        #expect(g.keepReason == "Highest resolution")
        #expect(g.members.allSatisfy { m.files[$0.path]?.sha256 != nil })
        #expect(g.members.first { $0.path == g.keep }?.exactGroupId == m.exactGroups[0].id)
    }

    @Test func secondScanDecodesNothingAndFailuresAreRetried() async throws {
        let dir = try TempDir(), cacheDir = try TempDir()
        for i in 0..<5 { try dir.write("\(i).jpg", TestImages.jpeg(seed: UInt64(i))) }
        try dir.write("broken.jpg", Data("garbage".utf8))
        let opts = ScanOptions(root: dir.url, cacheURL: cacheDir.url.appendingPathComponent("c.json"))
        let first = try await Scanner(options: opts).run()
        #expect(first.summary.fingerprintsComputed == 6)
        #expect(first.summary.decodeFailures == 1)
        let second = try await Scanner(options: opts).run()
        #expect(second.summary.fingerprintsComputed == 1) // only the previous failure is retried
        #expect(second.summary.cacheHits == 5)
    }

    @Test func fingerprintVersionChangeInvalidatesCache() async throws {
        let dir = try TempDir(), cacheDir = try TempDir()
        for i in 0..<3 { try dir.write("\(i).jpg", TestImages.jpeg(seed: UInt64(i))) }
        let url = cacheDir.url.appendingPathComponent("c.json")
        let opts = ScanOptions(root: dir.url, cacheURL: url)
        _ = try await Scanner(options: opts).run()
        // Simulate a cache written by an older algorithm version.
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"fingerprintVersion\":\(VisualFingerprint.algorithmVersion)", with: "\"fingerprintVersion\":0")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let rescanned = try await Scanner(options: opts).run()
        #expect(rescanned.summary.fingerprintsComputed == 3)
    }
}

import Foundation
import Testing
@testable import PhotoSweepCore

@Suite struct CacheTests {
    /// 8 images, each with one copy: 16 files, all of which need hashing.
    func makeLibrary() throws -> TempDir {
        let dir = try TempDir()
        for i in 0..<8 {
            let data = TestImages.jpeg(seed: UInt64(100 + i))
            try dir.write("a/img\(i).jpg", data)
            try dir.write("b/img\(i) copy.jpg", data)
        }
        return dir
    }

    func options(_ dir: TempDir, cache: URL, workers: Int = 4, verify: Bool = false) -> ScanOptions {
        ScanOptions(root: dir.url, workers: workers, cacheURL: cache, verify: verify, cacheSaveEvery: 1)
    }

    @Test func secondScanReusesEverything() async throws {
        let dir = try makeLibrary(), cacheDir = try TempDir()
        let cache = cacheDir.url.appendingPathComponent("cache.json")
        let first = try await Scanner(options: options(dir, cache: cache)).run()
        #expect(first.summary.hashesComputed == 16)
        #expect(first.summary.cacheHits == 0)
        let second = try await Scanner(options: options(dir, cache: cache)).run()
        #expect(second.summary.hashesComputed == 0)
        #expect(second.summary.cacheHits == 16)
        #expect(second.exactGroups.map(\.sha256).sorted() == first.exactGroups.map(\.sha256).sorted())
    }

    @Test func editedFileIsRecomputed() async throws {
        let dir = try makeLibrary(), cacheDir = try TempDir()
        let cache = cacheDir.url.appendingPathComponent("cache.json")
        _ = try await Scanner(options: options(dir, cache: cache)).run()
        // Replace one copy with different bytes of the same length (size alone would not reveal it).
        let path = dir.file("b/img3 copy.jpg")
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        data[data.count - 3] ^= 0x55
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)

        let second = try await Scanner(options: options(dir, cache: cache)).run()
        #expect(second.summary.hashesComputed == 1)
        #expect(second.summary.cacheHits == 15)
        #expect(second.exactGroups.count == 7)
    }

    @Test func verifyRecomputesEverything() async throws {
        let dir = try makeLibrary(), cacheDir = try TempDir()
        let cache = cacheDir.url.appendingPathComponent("cache.json")
        _ = try await Scanner(options: options(dir, cache: cache)).run()
        let verified = try await Scanner(options: options(dir, cache: cache, verify: true)).run()
        #expect(verified.summary.hashesComputed == 16)
        #expect(verified.summary.cacheHits == 0)
    }

    @Test func interruptedScanKeepsCompletedWork() async throws {
        let dir = try makeLibrary(), cacheDir = try TempDir()
        let cache = cacheDir.url.appendingPathComponent("cache.json")
        let flag = CancellationFlag()
        await #expect(throws: ScanCancelled.self) {
            _ = try await Scanner(options: options(dir, cache: cache, workers: 1)).run(cancellation: flag) { event in
                if case .processing(let done, _) = event, done == 5 { flag.cancel() }
            }
        }
        let resumed = try await Scanner(options: options(dir, cache: cache)).run()
        #expect(resumed.summary.cacheHits == 5)
        #expect(resumed.summary.hashesComputed == 11)
        #expect(resumed.exactGroups.count == 8)
    }

    @Test func missingFilesArePrunedAndOtherRootsIgnored() async throws {
        let dir = try makeLibrary(), cacheDir = try TempDir()
        let cache = cacheDir.url.appendingPathComponent("cache.json")
        _ = try await Scanner(options: options(dir, cache: cache)).run()
        try FileManager.default.removeItem(atPath: dir.file("b/img0 copy.jpg"))
        _ = try await Scanner(options: options(dir, cache: cache)).run()
        let reloaded = ScanCache(url: cache, root: dir.url.path)
        #expect(await reloaded.count == 15)
        #expect(await reloaded.entry(for: dir.file("b/img0 copy.jpg")) == nil)
        let otherRoot = ScanCache(url: cache, root: "/elsewhere")
        #expect(await otherRoot.count == 0)
    }

    @Test func hardLinksAreHashedOnce() async throws {
        let dir = try TempDir()
        let a = try dir.write("a.jpg", TestImages.jpeg(seed: 1))
        #expect(link(a, dir.file("b.jpg")) == 0)
        try dir.write("c.jpg", Data(contentsOf: URL(fileURLWithPath: a)))
        let m = try await Scanner(options: ScanOptions(root: dir.url)).run()
        #expect(m.summary.hashesComputed == 2)
        #expect(m.exactGroups.count == 1)
        #expect(m.exactGroups[0].paths.count == 3)
        #expect(m.exactGroups[0].distinctFileCount == 2)
    }
}

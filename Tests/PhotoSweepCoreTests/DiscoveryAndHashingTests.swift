import Foundation
import Testing
@testable import PhotoSweepCore

@Suite struct DiscoveryTests {
    @Test func findsSupportedFilesAndSkipsOthers() throws {
        let dir = try TempDir()
        try dir.write("a.jpg", Data([1]))
        try dir.write("nested/b.PNG", Data([2]))
        try dir.write("c.HEIC", Data([3]))
        try dir.write("notes.txt", Data([4]))
        try dir.write(".hidden.jpg", Data([5]))
        try dir.write("\(PhotoSweep.quarantineDirectoryName)/old.jpg", Data([6]))
        try FileManager.default.createSymbolicLink(atPath: dir.file("link.jpg"), withDestinationPath: dir.file("a.jpg"))

        let result = try FileDiscovery(root: dir.url).discover()
        let names = result.files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(names == ["a.jpg", "c.HEIC", "b.PNG"])
        #expect(result.skippedCount == 2) // notes.txt and the symlink
    }

    @Test func recordsHardLinkIdentity() throws {
        let dir = try TempDir()
        let a = try dir.write("a.jpg", Data([1, 2, 3]))
        #expect(link(a, dir.file("b.jpg")) == 0)
        let files = try FileDiscovery(root: dir.url).discover().files
        #expect(files.count == 2)
        #expect(files[0].metadata.identity == files[1].metadata.identity)
        #expect(files[0].metadata.linkCount == 2)
    }

    @Test func rejectsMissingRoot() {
        #expect(throws: PhotoSweepError.self) {
            try FileDiscovery(root: URL(fileURLWithPath: "/nonexistent-\(UUID())")).discover()
        }
    }
}

@Suite struct HashingTests {
    @Test func hashesAcrossChunkBoundaries() throws {
        let dir = try TempDir()
        // Slightly more than two chunks, so the streaming path is exercised.
        let bytes = Data((0..<(ContentHasher.chunkSize * 2 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let path = try dir.write("big.jpg", bytes)
        let streamed = try ContentHasher.sha256(path: path)
        let expected = SHA256Reference.hex(bytes)
        #expect(streamed == expected)
    }

    @Test func emptyFileHash() throws {
        let dir = try TempDir()
        let path = try dir.write("empty.jpg", Data())
        #expect(try ContentHasher.sha256(path: path) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func rejectsFileChangedSinceDiscovery() throws {
        let dir = try TempDir()
        let path = try dir.write("a.jpg", Data([1, 2, 3]))
        let meta = try readMetadata(path: path)
        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: path))
        #expect(throws: PhotoSweepError.changedDuringRead(path)) {
            try ContentHasher.sha256(path: path, expected: meta)
        }
    }
}

import CryptoKit
enum SHA256Reference {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

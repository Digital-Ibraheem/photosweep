import Foundation
import Testing
@testable import PhotoSweepCore

@Suite struct ExactMatcherTests {
    func file(_ path: String, size: Int64, inode: UInt64, mtime: Int64 = 0) -> DiscoveredFile {
        DiscoveredFile(path: path, metadata: FileMetadata(
            size: size, mtimeNanos: mtime, identity: FileIdentity(device: 1, inode: inode), linkCount: 1))
    }

    @Test func onlySharedSizesNeedHashing() {
        let files = [file("/r/a.jpg", size: 10, inode: 1), file("/r/b.jpg", size: 10, inode: 2), file("/r/c.jpg", size: 11, inode: 3)]
        #expect(ExactMatcher.pathsNeedingHash(files) == ["/r/a.jpg", "/r/b.jpg"])
    }

    @Test func groupsByHashAndComputesRecoverableSpace() {
        let files = [
            file("/r/a.jpg", size: 100, inode: 1),
            file("/r/a copy.jpg", size: 100, inode: 2),
            file("/r/sub/a.jpg", size: 100, inode: 3),
            file("/r/other.jpg", size: 100, inode: 4),
        ]
        let hashes = ["/r/a.jpg": "h1", "/r/a copy.jpg": "h1", "/r/sub/a.jpg": "h1", "/r/other.jpg": "h2"]
        let groups = ExactMatcher.group(files: files, hashes: hashes, policy: KeepPolicy())
        #expect(groups.count == 1)
        #expect(groups[0].keep == "/r/a.jpg")
        #expect(groups[0].paths.first == "/r/a.jpg")
        #expect(groups[0].recoverableBytes == 200)
        #expect(groups[0].distinctFileCount == 3)
    }

    @Test func hardLinksAreNotRecoverableSpace() {
        let files = [
            file("/r/a.jpg", size: 100, inode: 1),
            file("/r/b.jpg", size: 100, inode: 1), // hard link to a.jpg
            file("/r/c.jpg", size: 100, inode: 2),
        ]
        let hashes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, "h") })
        let group = ExactMatcher.group(files: files, hashes: hashes, policy: KeepPolicy())[0]
        #expect(group.distinctFileCount == 2)
        #expect(group.recoverableBytes == 100)
    }

    @Test func hardLinksOnlyFreeNothing() {
        let files = [file("/r/a.jpg", size: 100, inode: 1), file("/r/b.jpg", size: 100, inode: 1)]
        let hashes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, "h") })
        #expect(ExactMatcher.group(files: files, hashes: hashes, policy: KeepPolicy())[0].recoverableBytes == 0)
    }
}

@Suite struct KeepPolicyTests {
    typealias C = KeepPolicy.Candidate

    @Test func preferredFolderWins() {
        let policy = KeepPolicy(preferredFolders: ["/r/Keep"])
        let s = policy.suggestForExactGroup([C(path: "/r/a.jpg", size: 1, mtimeNanos: 0), C(path: "/r/Keep/deep/a copy.jpg", size: 1, mtimeNanos: 5)])
        #expect(s.path == "/r/Keep/deep/a copy.jpg")
        #expect(s.reason.contains("preferred folder"))
    }

    @Test func avoidsCopyLikeNames() {
        let s = KeepPolicy().suggestForExactGroup([C(path: "/r/IMG_1 copy.jpg", size: 1, mtimeNanos: 0), C(path: "/r/x/IMG_1.jpg", size: 1, mtimeNanos: 9)])
        #expect(s.path == "/r/x/IMG_1.jpg")
    }

    @Test func copyNamePatterns() {
        for name in ["a copy.jpg", "a copy 2.jpg", "a (1).jpg", "a_copy.jpg"] {
            #expect(KeepPolicy.looksLikeCopy("/r/" + name), "\(name)")
        }
        for name in ["IMG_1234.jpg", "IMG_1.jpg", "beach.jpg", "2024-05-01.jpg"] {
            #expect(!KeepPolicy.looksLikeCopy("/r/" + name), "\(name)")
        }
    }

    @Test func similarPrefersResolution() {
        let s = KeepPolicy().suggestForSimilarGroup([
            C(path: "/r/small.jpg", size: 900, mtimeNanos: 0, pixelCount: 100),
            C(path: "/r/big.jpg", size: 500, mtimeNanos: 0, pixelCount: 400),
        ])
        #expect(s == .init(path: "/r/big.jpg", reason: "Highest resolution"))
    }
}

@Suite struct SimilarKeepTests {
    @Test func preferredFolderBeatsLargerFileAtSameResolution() {
        let policy = KeepPolicy(preferredFolders: ["/r/Originals"])
        let s = policy.suggestForSimilarGroup([
            .init(path: "/r/Converted/a.png", size: 900, mtimeNanos: 0, pixelCount: 100),
            .init(path: "/r/Originals/a.jpg", size: 300, mtimeNanos: 0, pixelCount: 100),
        ])
        #expect(s.path == "/r/Originals/a.jpg")
        #expect(s.reason.contains("preferred folder"))
    }
}

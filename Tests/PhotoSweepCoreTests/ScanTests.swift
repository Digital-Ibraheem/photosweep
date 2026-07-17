import Foundation
import Testing
@testable import PhotoSweepCore

@Suite struct ExactScanTests {
    /// Milestone 1 completion check: originals, renamed copies, unrelated photos and a corrupted duplicate.
    @Test func findsRenamedCopiesAndCorruptDuplicates() throws {
        let dir = try TempDir()
        let beach = TestImages.jpeg(seed: 1)
        try dir.write("Originals/beach.jpg", beach)
        try dir.write("Exports/beach copy.jpg", beach)
        try dir.write("Exports/renamed/IMG_9999.jpg", beach)
        try dir.write("Originals/forest.jpg", TestImages.jpeg(seed: 2))
        try dir.write("Originals/city.jpg", TestImages.jpeg(seed: 3))
        // A truncated JPEG that cannot be decoded, plus a byte-identical copy.
        let corrupt = TestImages.jpeg(seed: 4).prefix(500)
        try dir.write("broken.jpg", corrupt)
        try dir.write("old/broken.jpg", corrupt)
        // Same size as the corrupt file but different bytes: must not be grouped.
        var sameSize = Data(corrupt)
        sameSize[sameSize.count - 1] ^= 0xFF
        try dir.write("decoy.jpg", sameSize)

        let manifest = try Scanner(options: ScanOptions(root: dir.url)).run()
        let groups = manifest.exactGroups.map { Set($0.paths.map { $0.replacingOccurrences(of: dir.path + "/", with: "") }) }
        #expect(Set(groups) == [
            ["Originals/beach.jpg", "Exports/beach copy.jpg", "Exports/renamed/IMG_9999.jpg"],
            ["broken.jpg", "old/broken.jpg"],
        ])
        #expect(manifest.summary.filesScanned == 8)
        #expect(manifest.summary.recoverableBytes == Int64(beach.count * 2 + corrupt.count))
        let beachGroup = manifest.exactGroups.first { $0.paths.count == 3 }!
        #expect(beachGroup.keep == dir.file("Originals/beach.jpg"))
    }

    @Test func reportEscapesFileNames() throws {
        let dir = try TempDir()
        let img = TestImages.jpeg(seed: 7)
        try dir.write("<script>alert(1)</script>.jpg", img)
        try dir.write("a&b \"quoted\".jpg", img)
        let manifest = try Scanner(options: ScanOptions(root: dir.url)).run()
        let out = try TempDir()
        let report = ReportGenerator(outputDirectory: out.url)
        let written = try report.write(manifest)
        let html = try String(contentsOf: report.htmlURL, encoding: .utf8)
        #expect(!html.contains("<script>alert(1)"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;.jpg"))
        #expect(html.contains("a&amp;b &quot;quoted&quot;.jpg"))
        #expect(written.files.values.allSatisfy { $0.thumbnail != nil })
        #expect(FileManager.default.fileExists(atPath: report.manifestURL.path))
    }
}

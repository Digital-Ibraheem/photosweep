import Foundation
import Testing
@testable import PhotoSweepCore
import PhotoSweepFixtures

/// Runs the labeled-fixture evaluation so CI catches regressions in matching quality.
@Suite struct FixtureEvaluationTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sources")

    @Test func defaultThresholdIsPreciseAndRecoversSimpleEdits() throws {
        let out = try TempDir()
        let labels = try FixtureGenerator(sourcesDirectory: Self.sources, outputDirectory: out.url).generate()
        let evaluation = SimilarityEvaluation(root: out.url, labels: labels)
        let result = evaluation.evaluate(threshold: SimilarityMatcher.defaultThreshold)
        #expect(result.precision >= 0.99)
        #expect(result.unrelatedPairs == 0)
        let families = evaluation.variantCounts["resized"]!
        for variant in ["resized", "recompressed", "png", "heic", "warmer", "exif-rotated"] {
            #expect(result.variantRecovered[variant] == families, "\(variant)")
        }
    }

    @Test func scannerFindsGeneratedDuplicates() async throws {
        let out = try TempDir()
        let labels = try FixtureGenerator(sourcesDirectory: Self.sources, outputDirectory: out.url).generate()
        let manifest = try await Scanner(options: ScanOptions(root: out.url)).run()
        let exactCopies = labels.files.filter { $0.variant == .exactCopy }.count
        // One group per exact-copied source, plus the damaged file and its backup.
        #expect(manifest.exactGroups.count == exactCopies + 1)
        #expect(manifest.similarGroups.count >= exactCopies)
    }
}

import ArgumentParser
import Foundation
import PhotoSweepCore
import PhotoSweepFixtures

@main
struct DevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photosweep-dev",
        abstract: "Developer tools: fixtures, evaluation and benchmarks for PhotoSweep.",
        subcommands: [MakeFixtures.self, Evaluate.self, MakeBenchData.self, Touch.self]
    )
}

struct MakeFixtures: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate the labeled fixture library from Fixtures/sources.")

    @Option(help: "Folder containing the CC0 source photos and sources.json.")
    var sources = "Fixtures/sources"

    @Option(name: .shortAndLong, help: "Output folder (replaced if it exists).")
    var output = "Fixtures/generated"

    func run() throws {
        let labels = try FixtureGenerator(
            sourcesDirectory: URL(fileURLWithPath: sources), outputDirectory: URL(fileURLWithPath: output)
        ).generate()
        print("Generated \(labels.files.count) files in \(output) (labels in \(output)/labels.json)")
    }
}

struct Evaluate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evaluate visual matching thresholds against labeled fixtures.")

    @Option(help: "Generated fixture folder containing labels.json.")
    var fixtures = "Fixtures/generated"

    @Option(parsing: .upToNextOption, help: "Thresholds to evaluate.")
    var thresholds: [Int] = [4, 6, 8, 10, 12, 14, 16]

    func run() throws {
        let root = URL(fileURLWithPath: fixtures)
        let labels = try JSONDecoder().decode(FixtureLabels.self, from: Data(contentsOf: root.appendingPathComponent("labels.json")))
        print(SimilarityEvaluation(root: root, labels: labels).markdownReport(thresholds: thresholds))
    }
}

struct MakeBenchData: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate a large photo-sized collection for benchmarks.")

    @Option(help: "Number of files.") var count = 2000
    @Option(help: "Long side in pixels.") var longSide = 2400
    @Option(help: "Folder containing the CC0 source photos.") var sources = "Fixtures/sources"
    @Option(name: .shortAndLong, help: "Output folder (replaced if it exists).") var output = "bench-data/photos"

    func run() throws {
        let start = Date()
        let s = try BenchmarkData(sourcesDirectory: URL(fileURLWithPath: sources), outputDirectory: URL(fileURLWithPath: output),
                                  count: count, longSide: longSide).generate()
        print("Generated \(s.files) files, \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)) in \(Int(Date().timeIntervalSince(start)))s")
    }
}

/// Modifies a deterministic subset of files so the next scan has to recompute them.
struct Touch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Modify every Nth photo (appends a byte; images stay decodable).")

    @Argument var folder: String
    @Option(help: "Modify one in every N files.") var every = 100

    func run() throws {
        let fm = FileManager.default
        let files = (fm.enumerator(atPath: folder)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
        var n = 0
        for (i, f) in files.enumerated() where i % every == 0 {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: folder).appendingPathComponent(f))
            try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
            n += 1
        }
        print("Modified \(n) of \(files.count) files")
    }
}

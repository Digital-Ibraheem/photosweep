import ArgumentParser
import Foundation
import PhotoSweepCore
import PhotoSweepFixtures

@main
struct DevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photosweep-dev",
        abstract: "Developer tools: fixtures, evaluation and benchmarks for PhotoSweep.",
        subcommands: [MakeFixtures.self, Evaluate.self]
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

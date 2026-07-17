import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Labels describing every generated fixture file.
public struct FixtureLabels: Codable, Sendable {
    public struct File: Codable, Sendable, Hashable {
        /// Path relative to the fixture root.
        public var path: String
        /// Source photo (file name in Fixtures/sources) this file derives from.
        public var source: String
        /// Subject group shared by different photos of the same thing, if any.
        public var subject: String?
        public var variant: Variant
    }

    public var files: [File]
}

public enum Variant: String, Codable, Sendable, CaseIterable {
    case original
    case exactCopy = "exact-copy"
    case resized
    case recompressed
    case png
    case heic
    case brighter
    case warmer
    case contrast
    case exifRotated = "exif-rotated"
    case rotated90 = "rotated-90"
    case cropped
    case corrupt

    /// Variants the user would consider "the same photo". A good visual matcher should group
    /// these with the original. Rotation and cropping are included even though dHash is
    /// expected to miss them, so the evaluation reports that limitation instead of hiding it.
    public var isDuplicateOfSource: Bool { self != .original && self != .corrupt }
}

/// Builds a messy, labeled photo folder from the CC0 source photos.
public struct FixtureGenerator {
    public var sourcesDirectory: URL
    public var outputDirectory: URL

    public init(sourcesDirectory: URL, outputDirectory: URL) {
        self.sourcesDirectory = sourcesDirectory
        self.outputDirectory = outputDirectory
    }

    struct SourceInfo: Decodable {
        var file: String
        var subject: String?
    }

    /// Generates the fixture set and writes `labels.json`. Output is deterministic for a given OS version.
    @discardableResult
    public func generate() throws -> FixtureLabels {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDirectory.path) { try fm.removeItem(at: outputDirectory) }
        for dir in ["Originals", "Exports"] {
            try fm.createDirectory(at: outputDirectory.appendingPathComponent(dir), withIntermediateDirectories: true)
        }

        let info = try JSONDecoder().decode(
            [SourceInfo].self, from: Data(contentsOf: sourcesDirectory.appendingPathComponent("sources.json")))
        var files: [FixtureLabels.File] = []

        func out(_ relative: String) -> String { outputDirectory.appendingPathComponent(relative).path }
        func add(_ relative: String, _ source: SourceInfo, _ variant: Variant) {
            files.append(.init(path: relative, source: source.file, subject: source.subject, variant: variant))
        }

        for source in info {
            let stem = (source.file as NSString).deletingPathExtension
            let srcPath = sourcesDirectory.appendingPathComponent(source.file).path
            try fm.copyItem(atPath: srcPath, toPath: out("Originals/\(source.file)"))
            add("Originals/\(source.file)", source, .original)

            // Photos with a subject group are the "different photo of the same thing" cases; they
            // get no edited variants so the evaluation measures only distinct-shot confusion.
            guard source.subject == nil, let image = ImageTransforms.load(srcPath) else { continue }

            try fm.copyItem(atPath: srcPath, toPath: out("Exports/\(stem) copy.jpg"))
            add("Exports/\(stem) copy.jpg", source, .exactCopy)

            let edits: [(String, Variant, () throws -> Void)] = [
                ("Exports/Web/\(stem)-small.jpg", .resized, {
                    try ImageTransforms.write(ImageTransforms.resized(image, scale: 0.5), to: out("Exports/Web/\(stem)-small.jpg"), quality: 0.8) }),
                ("Exports/Web/\(stem)-lowq.jpg", .recompressed, {
                    try ImageTransforms.write(image, to: out("Exports/Web/\(stem)-lowq.jpg"), quality: 0.3) }),
                ("Converted/\(stem).png", .png, {
                    try ImageTransforms.write(image, to: out("Converted/\(stem).png"), type: .png) }),
                ("Converted/\(stem).heic", .heic, {
                    try ImageTransforms.write(image, to: out("Converted/\(stem).heic"), type: .heic, quality: 0.6) }),
                ("Edits/\(stem)-brighter.jpg", .brighter, {
                    try ImageTransforms.write(ImageTransforms.colorControls(image, brightness: 0.1), to: out("Edits/\(stem)-brighter.jpg")) }),
                ("Edits/\(stem)-warm.jpg", .warmer, {
                    try ImageTransforms.write(ImageTransforms.warmer(image), to: out("Edits/\(stem)-warm.jpg")) }),
                ("Edits/\(stem)-contrast.jpg", .contrast, {
                    try ImageTransforms.write(ImageTransforms.colorControls(image, contrast: 1.25, saturation: 1.2), to: out("Edits/\(stem)-contrast.jpg")) }),
                ("Phone/\(stem)-exif-rotated.jpg", .exifRotated, {
                    // Pixels stored rotated, with an EXIF orientation that displays them upright.
                    try ImageTransforms.write(ImageTransforms.rotatedClockwise(image), to: out("Phone/\(stem)-exif-rotated.jpg"), orientation: 8) }),
                ("Edits/\(stem)-rotated.jpg", .rotated90, {
                    try ImageTransforms.write(ImageTransforms.rotatedClockwise(image), to: out("Edits/\(stem)-rotated.jpg")) }),
                ("Edits/\(stem)-crop.jpg", .cropped, {
                    try ImageTransforms.write(ImageTransforms.centerCropped(image, keep: 0.8), to: out("Edits/\(stem)-crop.jpg")) }),
            ]
            for (path, variant, make) in edits {
                try make()
                add(path, source, variant)
            }
        }

        // A truncated (undecodable) file and a byte-identical copy of it.
        if let first = info.first(where: { $0.subject == nil }) {
            let data = try Data(contentsOf: sourcesDirectory.appendingPathComponent(first.file))
            let truncated = data.prefix(data.count / 3)
            for path in ["Damaged/truncated.jpg", "Damaged/Backup/truncated.jpg"] {
                try fm.createDirectory(atPath: (out(path) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try truncated.write(to: URL(fileURLWithPath: out(path)))
                add(path, first, .corrupt)
            }
        }

        let labels = FixtureLabels(files: files.sorted { $0.path < $1.path })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(labels).write(to: outputDirectory.appendingPathComponent("labels.json"))
        return labels
    }
}

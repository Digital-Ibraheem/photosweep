import Foundation

/// Everything the report and the cleanup commands need to know about one scan.
/// Written to `<report>/scan.json`. Cleanup only ever acts on files recorded here.
public struct ScanManifest: Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var scanId: String
    public var root: String
    public var createdAt: Date
    public var toolVersion: String
    public var summary: ScanSummary
    /// Files that appear in any group, keyed by absolute path.
    public var files: [String: ManifestFile]
    public var exactGroups: [ExactGroup]
    public var similarGroups: [SimilarGroup]
    public var issues: [ScanIssue]

    public init(
        scanId: String = UUID().uuidString.lowercased(), root: String, createdAt: Date = Date(),
        summary: ScanSummary, files: [String: ManifestFile], exactGroups: [ExactGroup],
        similarGroups: [SimilarGroup], issues: [ScanIssue]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.scanId = scanId
        self.root = root
        self.createdAt = createdAt
        self.toolVersion = PhotoSweep.version
        self.summary = summary
        self.files = files
        self.exactGroups = exactGroups
        self.similarGroups = similarGroups
        self.issues = issues
    }

    public static func load(from url: URL) throws -> ScanManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONCoding.decoder.decode(ScanManifest.self, from: data)
        guard manifest.formatVersion == currentFormatVersion else {
            throw PhotoSweepError.invalidInput("Unsupported scan manifest version \(manifest.formatVersion); re-run the scan.")
        }
        return manifest
    }

    public func write(to url: URL) throws {
        try JSONCoding.encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct ManifestFile: Codable, Hashable, Sendable {
    public var size: Int64
    public var mtimeNanos: Int64
    public var identity: FileIdentity
    public var sha256: String?
    public var width: Int?
    public var height: Int?
    /// Report-relative thumbnail path, if one was generated.
    public var thumbnail: String?

    public var pixelCount: Int? {
        guard let width, let height else { return nil }
        return width * height
    }
}

public struct SimilarGroup: Codable, Hashable, Sendable {
    public struct Member: Codable, Hashable, Sendable {
        public var path: String
        /// Hamming distance to the representative's fingerprint (0 for the representative).
        public var distance: Int
    }

    public var id: String
    public var representative: String
    /// Members sorted with the suggested keeper first.
    public var members: [Member]
    public var keep: String
    public var keepReason: String
}

public struct ScanSummary: Codable, Hashable, Sendable {
    public var filesScanned = 0
    public var bytesScanned: Int64 = 0
    public var exactGroupCount = 0
    public var exactDuplicateFiles = 0
    public var similarGroupCount = 0
    public var recoverableBytes: Int64 = 0
    public var hashesComputed = 0
    public var fingerprintsComputed = 0
    public var cacheHits = 0
    public var decodeFailures = 0
    public var errorCount = 0
    public var skippedFiles = 0
    public var durationSeconds = 0.0
    public var workers = 1
    public var similarityThreshold = 0

    public init() {}
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

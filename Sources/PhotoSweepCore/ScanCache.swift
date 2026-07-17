import CryptoKit
import Foundation

/// Cached results for one file. Valid only while size, mtime and identity are unchanged.
public struct CacheEntry: Codable, Hashable, Sendable {
    public var size: Int64
    public var mtimeNanos: Int64
    public var identity: FileIdentity
    public var sha256: String?
    /// Visual fingerprint as 16 hex digits.
    public var fingerprint: String?
    public var fingerprintVersion: Int?
    public var lowDetail: Bool?
    public var width: Int?
    public var height: Int?
    /// True when the last decode attempt failed. Failures are retried on the next scan.
    public var decodeFailed: Bool

    public init(metadata: FileMetadata) {
        size = metadata.size
        mtimeNanos = metadata.mtimeNanos
        identity = metadata.identity
        decodeFailed = false
    }

    public var metadata: FileMetadata {
        FileMetadata(size: size, mtimeNanos: mtimeNanos, identity: identity, linkCount: 1)
    }

    /// The cached fingerprint, if it was produced by the current algorithm.
    public var currentFingerprint: VisualFingerprint? {
        guard fingerprintVersion == VisualFingerprint.algorithmVersion, !decodeFailed,
              let fingerprint, let bits = UInt64(fingerprint, radix: 16) else { return nil }
        return VisualFingerprint(bits: bits, lowDetail: lowDetail ?? false)
    }

    mutating func setFingerprint(_ fp: VisualFingerprint?, width: Int?, height: Int?) {
        fingerprint = fp?.hex
        lowDetail = fp?.lowDetail
        fingerprintVersion = VisualFingerprint.algorithmVersion
        decodeFailed = fp == nil
        self.width = width
        self.height = height
    }
}

struct CacheFile: Codable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    var root: String
    var updatedAt: Date
    var entries: [String: CacheEntry]
}

/// Persistent per-root cache of hashes and fingerprints, stored as versioned JSON.
///
/// All mutation goes through this actor so concurrent workers never race on the cache.
/// Results are flushed periodically with atomic file replacement; an interrupted scan therefore
/// loses at most the work done since the last flush.
public actor ScanCache {
    public nonisolated let url: URL?
    private let root: String
    private var entries: [String: CacheEntry]
    private var dirty = 0
    private var lastSave = Date()
    private let saveEvery: Int
    private let saveInterval: TimeInterval
    public private(set) var saveCount = 0

    /// Default location: `~/Library/Caches/PhotoSweep/<hash of root>.json`.
    public static func defaultURL(forRoot root: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let key = SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("PhotoSweep/\(key).json")
    }

    /// Loads the cache. A missing, unreadable or incompatible file starts an empty cache.
    /// - Parameter url: nil disables persistence.
    public init(url: URL?, root: String, saveEvery: Int = 500, saveInterval: TimeInterval = 2) {
        self.url = url
        self.root = root
        self.saveEvery = saveEvery
        self.saveInterval = saveInterval
        var loaded: [String: CacheEntry] = [:]
        if let url, let data = try? Data(contentsOf: url),
           let file = try? JSONCoding.decoder.decode(CacheFile.self, from: data),
           file.formatVersion == CacheFile.currentFormatVersion, file.root == root {
            loaded = file.entries
        }
        entries = loaded
    }

    public var count: Int { entries.count }

    /// Keeps only entries for the given files whose metadata is unchanged, and returns them.
    /// Entries for missing or modified files are dropped.
    public func retainValidEntries(for files: [DiscoveredFile]) -> [String: CacheEntry] {
        var kept: [String: CacheEntry] = [:]
        for f in files {
            if let e = entries[f.path], e.metadata.sameContentSignature(as: f.metadata) {
                kept[f.path] = e
            }
        }
        entries = kept
        return kept
    }

    public func entry(for path: String) -> CacheEntry? { entries[path] }

    /// Records a result and flushes to disk if enough work has accumulated.
    public func record(_ entry: CacheEntry, for path: String) {
        entries[path] = entry
        dirty += 1
        if dirty >= saveEvery || Date().timeIntervalSince(lastSave) >= saveInterval {
            try? save()
        }
    }

    public func save() throws {
        guard let url else { dirty = 0; return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = CacheFile(formatVersion: CacheFile.currentFormatVersion, root: root, updatedAt: Date(), entries: entries)
        try JSONCoding.compactEncoder.encode(file).write(to: url, options: .atomic)
        dirty = 0
        lastSave = Date()
        saveCount += 1
    }
}

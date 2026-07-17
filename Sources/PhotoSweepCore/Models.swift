import Foundation

public enum PhotoSweep {
    public static let version = "0.1.0"
    /// File extensions treated as photos (lowercased).
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    /// Name of the quarantine directory created inside a scanned root. Always excluded from scans.
    public static let quarantineDirectoryName = ".photosweep-quarantine"
}

/// Filesystem identity of a file. Two paths with the same identity are hard links to the same bytes.
public struct FileIdentity: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Metadata captured for one discovered file.
public struct FileMetadata: Codable, Hashable, Sendable {
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var mtimeNanos: Int64
    public var identity: FileIdentity
    public var linkCount: UInt32

    public init(size: Int64, mtimeNanos: Int64, identity: FileIdentity, linkCount: UInt32) {
        self.size = size
        self.mtimeNanos = mtimeNanos
        self.identity = identity
        self.linkCount = linkCount
    }

    /// True when size, modification time and identity are unchanged.
    /// Link count is ignored: adding a hard link elsewhere does not change content.
    public func sameContentSignature(as other: FileMetadata) -> Bool {
        size == other.size && mtimeNanos == other.mtimeNanos && identity == other.identity
    }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: Double(mtimeNanos) / 1_000_000_000)
    }
}

/// A supported file found during discovery.
public struct DiscoveredFile: Hashable, Sendable {
    /// Absolute, standardized path.
    public var path: String
    public var metadata: FileMetadata

    public init(path: String, metadata: FileMetadata) {
        self.path = path
        self.metadata = metadata
    }
}

public enum PhotoSweepError: Error, CustomStringConvertible, Equatable {
    case notADirectory(String)
    case statFailed(path: String, errno: Int32)
    case readFailed(path: String, message: String)
    case changedDuringRead(String)
    case decodeFailed(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .notADirectory(let p): return "Not a directory: \(p)"
        case .statFailed(let p, let e): return "Cannot read metadata for \(p): \(String(cString: strerror(e)))"
        case .readFailed(let p, let m): return "Cannot read \(p): \(m)"
        case .changedDuringRead(let p): return "File changed while it was being read: \(p)"
        case .decodeFailed(let p): return "Cannot decode image: \(p)"
        case .invalidInput(let m): return m
        }
    }
}

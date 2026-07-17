import Foundation

/// Reads filesystem metadata without following symlinks.
public func readMetadata(path: String) throws -> FileMetadata {
    var st = stat()
    guard lstat(path, &st) == 0 else { throw PhotoSweepError.statFailed(path: path, errno: errno) }
    let nanos = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    return FileMetadata(
        size: Int64(st.st_size),
        mtimeNanos: nanos,
        identity: FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino)),
        linkCount: UInt32(st.st_nlink)
    )
}

public struct DiscoveryResult: Sendable {
    public var files: [DiscoveredFile]
    /// Paths that matched a supported extension but could not be read.
    public var errors: [ScanIssue]
    /// Count of non-photo files, symlinks and other entries ignored.
    public var skippedCount: Int
}

public struct ScanIssue: Codable, Hashable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Enumerates supported photos below a root folder.
///
/// Hidden files and folders, symlinks and the quarantine directory are skipped.
/// Results are sorted by path so scans are deterministic.
public struct FileDiscovery: Sendable {
    public var root: URL
    public var excludedDirectoryNames: Set<String>

    public init(root: URL, excludedDirectoryNames: Set<String> = [PhotoSweep.quarantineDirectoryName]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.excludedDirectoryNames = excludedDirectoryNames
    }

    public func discover() throws -> DiscoveryResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw PhotoSweepError.notADirectory(root.path)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw PhotoSweepError.notADirectory(root.path) }

        var files: [DiscoveredFile] = []
        var errors: [ScanIssue] = []
        var skipped = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if excludedDirectoryNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isSymbolicLink != true, values?.isRegularFile == true,
                  PhotoSweep.supportedExtensions.contains(url.pathExtension.lowercased())
            else { skipped += 1; continue }
            let path = url.standardizedFileURL.path
            do {
                files.append(DiscoveredFile(path: path, metadata: try readMetadata(path: path)))
            } catch {
                errors.append(ScanIssue(path: path, message: "\(error)"))
            }
        }
        files.sort { $0.path < $1.path }
        return DiscoveryResult(files: files, errors: errors, skippedCount: skipped)
    }
}

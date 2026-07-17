import Foundation

public struct ScanOptions: Sendable {
    public var root: URL
    public var preferredFolders: [String]

    public init(root: URL, preferredFolders: [String] = []) {
        self.root = root
        self.preferredFolders = preferredFolders
    }
}

/// Progress events, for display only.
public enum ScanProgress: Sendable {
    case discovered(files: Int)
    case hashing(done: Int, total: Int)
}

/// Runs the scan pipeline: discover, hash files that share a size, and group duplicates.
public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions) { self.options = options }

    public func run(progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanManifest {
        let start = Date()
        let discovery = FileDiscovery(root: options.root)
        let found = try discovery.discover()
        progress(.discovered(files: found.files.count))

        var issues = found.errors
        var summary = ScanSummary()
        summary.filesScanned = found.files.count
        summary.bytesScanned = found.files.reduce(0) { $0 + $1.metadata.size }
        summary.skippedFiles = found.skippedCount

        // Hash once per distinct file: hard links share an identity and therefore bytes.
        let needHash = ExactMatcher.pathsNeedingHash(found.files)
        let toHash = found.files.filter { needHash.contains($0.path) }
        var hashByIdentity: [FileIdentity: String] = [:]
        var hashes: [String: String] = [:]
        for (i, file) in toHash.enumerated() {
            if let known = hashByIdentity[file.metadata.identity] {
                hashes[file.path] = known
            } else {
                do {
                    let digest = try ContentHasher.sha256(path: file.path, expected: file.metadata)
                    hashByIdentity[file.metadata.identity] = digest
                    hashes[file.path] = digest
                    summary.hashesComputed += 1
                } catch {
                    issues.append(ScanIssue(path: file.path, message: "\(error)"))
                }
            }
            progress(.hashing(done: i + 1, total: toHash.count))
        }

        let policy = KeepPolicy(preferredFolders: options.preferredFolders)
        let exactGroups = ExactMatcher.group(files: found.files, hashes: hashes, policy: policy)

        let byPath = Dictionary(uniqueKeysWithValues: found.files.map { ($0.path, $0) })
        var manifestFiles: [String: ManifestFile] = [:]
        for path in exactGroups.flatMap(\.paths) {
            let f = byPath[path]!
            let dims = ImageInspector.dimensions(path: path)
            manifestFiles[path] = ManifestFile(
                size: f.metadata.size, mtimeNanos: f.metadata.mtimeNanos, identity: f.metadata.identity,
                sha256: hashes[path], width: dims?.width, height: dims?.height)
        }

        summary.exactGroupCount = exactGroups.count
        summary.exactDuplicateFiles = exactGroups.reduce(0) { $0 + $1.paths.count - 1 }
        summary.recoverableBytes = exactGroups.reduce(0) { $0 + $1.recoverableBytes }
        summary.errorCount = issues.count
        summary.durationSeconds = Date().timeIntervalSince(start)

        return ScanManifest(
            root: discovery.root.path, summary: summary, files: manifestFiles,
            exactGroups: exactGroups, similarGroups: [], issues: issues.sorted { $0.path < $1.path })
    }
}

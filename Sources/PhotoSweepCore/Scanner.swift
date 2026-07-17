import Foundation

public struct ScanOptions: Sendable {
    public var root: URL
    public var preferredFolders: [String]
    /// Number of concurrent hashing/decoding workers.
    public var workers: Int
    /// Cache file location; nil disables the persistent cache.
    public var cacheURL: URL?
    /// Ignore cached results and recompute everything (the cache is still rewritten).
    public var verify: Bool
    /// Flush the cache after this many new results (or every `cacheSaveInterval` seconds).
    public var cacheSaveEvery: Int
    public var cacheSaveInterval: TimeInterval

    public init(
        root: URL, preferredFolders: [String] = [], workers: Int = 4, cacheURL: URL? = nil,
        verify: Bool = false, cacheSaveEvery: Int = 500, cacheSaveInterval: TimeInterval = 2
    ) {
        self.root = root
        self.preferredFolders = preferredFolders
        self.workers = workers
        self.cacheURL = cacheURL
        self.verify = verify
        self.cacheSaveEvery = cacheSaveEvery
        self.cacheSaveInterval = cacheSaveInterval
    }
}

/// Progress events, for display only.
public enum ScanProgress: Sendable {
    case discovered(files: Int)
    case processing(done: Int, total: Int)
}

public struct ScanCancelled: Error, CustomStringConvertible {
    public var completedJobs: Int
    public var description: String { "Scan interrupted after \(completedJobs) files; completed work was saved to the cache." }
}

/// Work for one distinct file (hard links share a job).
struct FileJob: Sendable {
    var file: DiscoveredFile
    var cached: CacheEntry?
    var needHash: Bool
}

struct FileJobResult: Sendable {
    var file: DiscoveredFile
    var entry: CacheEntry
    var hashComputed: Bool
    var error: ScanIssue?
}

/// Runs the scan pipeline: discover, reuse cached results, hash what is needed with a fixed number
/// of workers, and group duplicates.
public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions) { self.options = options }

    public func run(
        cancellation: CancellationFlag? = nil,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanManifest {
        let start = Date()
        let discovery = FileDiscovery(root: options.root)
        let found = try discovery.discover()
        progress(.discovered(files: found.files.count))

        var issues = found.errors
        var summary = ScanSummary()
        summary.filesScanned = found.files.count
        summary.bytesScanned = found.files.reduce(0) { $0 + $1.metadata.size }
        summary.skippedFiles = found.skippedCount
        summary.workers = options.workers

        let cache = ScanCache(
            url: options.cacheURL, root: discovery.root.path,
            saveEvery: options.cacheSaveEvery, saveInterval: options.cacheSaveInterval)
        let valid = options.verify ? [:] : await cache.retainValidEntries(for: found.files)

        // Plan one job per distinct file identity.
        let needHash = ExactMatcher.pathsNeedingHash(found.files)
        var jobs: [FileJob] = []
        var aliases: [FileIdentity: [DiscoveredFile]] = [:]
        var entries: [String: CacheEntry] = [:]
        for file in found.files {
            if aliases[file.metadata.identity] != nil {
                aliases[file.metadata.identity]!.append(file)
                continue
            }
            aliases[file.metadata.identity] = [file]
            let cached = valid[file.path]
            let job = FileJob(file: file, cached: cached, needHash: needHash.contains(file.path))
            if Self.isSatisfied(job) {
                entries[file.path] = cached!
                summary.cacheHits += 1
            } else {
                jobs.append(job)
            }
        }

        // Process with bounded concurrency; record each result through the cache actor.
        var completed = 0
        await forEachBounded(jobs, workers: options.workers, cancellation: cancellation, body: Self.process) { result in
            completed += 1
            if result.hashComputed { summary.hashesComputed += 1 }
            if let error = result.error { issues.append(error) } else {
                entries[result.file.path] = result.entry
                await cache.record(result.entry, for: result.file.path)
            }
            progress(.processing(done: completed, total: jobs.count))
        }
        // Hard links reuse their sibling's result.
        for (_, files) in aliases where files.count > 1 {
            guard let first = entries[files[0].path] else { continue }
            for alias in files.dropFirst() {
                var e = first
                e.identity = alias.metadata.identity
                e.mtimeNanos = alias.metadata.mtimeNanos
                entries[alias.path] = e
                await cache.record(e, for: alias.path)
            }
        }
        try await cache.save()
        if cancellation?.isCancelled == true { throw ScanCancelled(completedJobs: completed) }

        let hashes = entries.compactMapValues(\.sha256)
        let policy = KeepPolicy(preferredFolders: options.preferredFolders)
        let exactGroups = ExactMatcher.group(files: found.files, hashes: hashes, policy: policy)

        let byPath = Dictionary(uniqueKeysWithValues: found.files.map { ($0.path, $0) })
        var manifestFiles: [String: ManifestFile] = [:]
        for path in exactGroups.flatMap(\.paths) {
            let f = byPath[path]!
            let e = entries[path]
            let dims = e?.width != nil ? (e!.width!, e!.height!) : ImageInspector.dimensions(path: path)
            manifestFiles[path] = ManifestFile(
                size: f.metadata.size, mtimeNanos: f.metadata.mtimeNanos, identity: f.metadata.identity,
                sha256: hashes[path], width: dims?.0, height: dims?.1)
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

    static func isSatisfied(_ job: FileJob) -> Bool {
        guard let cached = job.cached else { return false }
        return !job.needHash || cached.sha256 != nil
    }

    /// Does the work for one file. Runs on a worker; must not touch shared state.
    @Sendable static func process(_ job: FileJob) -> FileJobResult {
        var entry = job.cached ?? CacheEntry(metadata: job.file.metadata)
        var hashComputed = false
        do {
            if job.needHash && entry.sha256 == nil {
                entry.sha256 = try ContentHasher.sha256(path: job.file.path, expected: job.file.metadata)
                hashComputed = true
            }
            return FileJobResult(file: job.file, entry: entry, hashComputed: hashComputed)
        } catch {
            return FileJobResult(file: job.file, entry: entry, hashComputed: false,
                                 error: ScanIssue(path: job.file.path, message: "\(error)"))
        }
    }
}

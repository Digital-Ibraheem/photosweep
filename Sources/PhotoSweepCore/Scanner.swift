import CryptoKit
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
    /// Compute visual fingerprints and find similar images.
    public var findSimilar: Bool
    /// Maximum Hamming distance (out of 64 bits) between a similar image and its group representative.
    public var similarityThreshold: Int

    public init(
        root: URL, preferredFolders: [String] = [], workers: Int = 4, cacheURL: URL? = nil,
        verify: Bool = false, cacheSaveEvery: Int = 500, cacheSaveInterval: TimeInterval = 2,
        findSimilar: Bool = true, similarityThreshold: Int = SimilarityMatcher.defaultThreshold
    ) {
        self.findSimilar = findSimilar
        self.similarityThreshold = similarityThreshold
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
    case hashingCandidates(done: Int, total: Int)
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
    var needFingerprint: Bool
}

struct FileJobResult: Sendable {
    var file: DiscoveredFile
    var entry: CacheEntry
    var hashComputed: Bool
    var fingerprintComputed = false
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
            let job = FileJob(
                file: file, cached: cached, needHash: needHash.contains(file.path),
                needFingerprint: options.findSimilar)
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
            if result.fingerprintComputed {
                summary.fingerprintsComputed += 1
                if result.entry.decodeFailed {
                    summary.decodeFailures += 1
                    issues.append(ScanIssue(
                        path: result.file.path,
                        message: "Could not decode image; only exact duplicate detection applies"))
                }
            }
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
        if cancellation?.isCancelled == true {
            try await cache.save()
            throw ScanCancelled(completedJobs: completed)
        }

        let policy = KeepPolicy(preferredFolders: options.preferredFolders)
        let byPath = Dictionary(uniqueKeysWithValues: found.files.map { ($0.path, $0) })
        let exactGroups = ExactMatcher.group(
            files: found.files, hashes: entries.compactMapValues(\.sha256), policy: policy)

        var similarGroups: [SimilarGroup] = []
        if options.findSimilar {
            similarGroups = Self.similarGroups(
                files: found.files, entries: entries, exactGroups: exactGroups,
                threshold: options.similarityThreshold, policy: policy)

            // Cleanup re-verifies content by hash, so every grouped file needs one.
            let missing = similarGroups.flatMap(\.members).map(\.path)
                .filter { entries[$0]?.sha256 == nil }
                .compactMap { byPath[$0] }
                .map { FileJob(file: $0, cached: entries[$0.path], needHash: true, needFingerprint: false) }
            var done = 0
            await forEachBounded(missing, workers: options.workers, cancellation: cancellation, body: Self.process) { result in
                done += 1
                if result.hashComputed { summary.hashesComputed += 1 }
                if let error = result.error { issues.append(error) } else {
                    entries[result.file.path] = result.entry
                    await cache.record(result.entry, for: result.file.path)
                }
                progress(.hashingCandidates(done: done, total: missing.count))
            }
        }
        try await cache.save()
        if cancellation?.isCancelled == true { throw ScanCancelled(completedJobs: completed) }

        var manifestFiles: [String: ManifestFile] = [:]
        let groupedPaths = exactGroups.flatMap(\.paths) + similarGroups.flatMap { $0.members.map(\.path) }
        for path in groupedPaths {
            let f = byPath[path]!
            let e = entries[path]
            let dims = e?.width.flatMap { w in e?.height.map { (w, $0) } } ?? ImageInspector.dimensions(path: path)
            manifestFiles[path] = ManifestFile(
                size: f.metadata.size, mtimeNanos: f.metadata.mtimeNanos, identity: f.metadata.identity,
                sha256: e?.sha256, width: dims?.0, height: dims?.1)
        }

        summary.exactGroupCount = exactGroups.count
        summary.exactDuplicateFiles = exactGroups.reduce(0) { $0 + $1.paths.count - 1 }
        summary.recoverableBytes = exactGroups.reduce(0) { $0 + $1.recoverableBytes }
        summary.similarGroupCount = similarGroups.count
        summary.similarityThreshold = options.similarityThreshold
        summary.errorCount = issues.count
        summary.durationSeconds = Date().timeIntervalSince(start)

        return ScanManifest(
            root: discovery.root.path, summary: summary, files: manifestFiles,
            exactGroups: exactGroups, similarGroups: similarGroups, issues: issues.sorted { $0.path < $1.path })
    }

    /// Builds visual groups over distinct content: each exact-duplicate group contributes only its
    /// suggested keeper, so similar groups never just repeat exact duplicates.
    static func similarGroups(
        files: [DiscoveredFile], entries: [String: CacheEntry], exactGroups: [ExactGroup],
        threshold: Int, policy: KeepPolicy
    ) -> [SimilarGroup] {
        var exactGroupOf: [String: ExactGroup] = [:]
        for g in exactGroups { for p in g.paths { exactGroupOf[p] = g } }
        var items: [VisualItem] = []
        for f in files {
            if let g = exactGroupOf[f.path], g.keep != f.path { continue }
            guard let e = entries[f.path], let fp = e.currentFingerprint, !fp.lowDetail else { continue }
            items.append(VisualItem(
                path: f.path, fingerprint: fp, pixelCount: (e.width ?? 0) * (e.height ?? 0), size: f.metadata.size))
        }
        return SimilarityMatcher.group(items, threshold: threshold).map { raw in
            let members = raw.map { (item: items[$0.item], distance: $0.distance) }
            let suggestion = policy.suggestForSimilarGroup(members.map {
                .init(path: $0.item.path, size: $0.item.size, mtimeNanos: 0, pixelCount: $0.item.pixelCount)
            })
            let sorted = members.sorted { a, b in
                if (a.item.path == suggestion.path) != (b.item.path == suggestion.path) { return a.item.path == suggestion.path }
                return (a.distance, a.item.path) < (b.distance, b.item.path)
            }
            let rep = members[0].item.path
            return SimilarGroup(
                id: "s-" + SHA256.hash(data: Data(rep.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined(),
                representative: rep,
                members: sorted.map { .init(path: $0.item.path, distance: $0.distance, exactGroupId: exactGroupOf[$0.item.path]?.id) },
                keep: suggestion.path, keepReason: suggestion.reason)
        }
    }

    static func isSatisfied(_ job: FileJob) -> Bool {
        guard let cached = job.cached else { return false }
        // Decode failures have no current fingerprint, so they are retried on every scan.
        return (!job.needHash || cached.sha256 != nil) && (!job.needFingerprint || cached.currentFingerprint != nil)
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
            var fingerprintComputed = false
            if job.needFingerprint && entry.currentFingerprint == nil {
                let before = try readMetadata(path: job.file.path)
                guard before.sameContentSignature(as: job.file.metadata) else {
                    throw PhotoSweepError.changedDuringRead(job.file.path)
                }
                let dims = ImageInspector.dimensions(path: job.file.path)
                let fp = VisualFingerprint.compute(path: job.file.path)
                let after = try readMetadata(path: job.file.path)
                guard after.sameContentSignature(as: before) else { throw PhotoSweepError.changedDuringRead(job.file.path) }
                entry.setFingerprint(fp, width: dims?.width, height: dims?.height)
                fingerprintComputed = true
            }
            return FileJobResult(
                file: job.file, entry: entry, hashComputed: hashComputed, fingerprintComputed: fingerprintComputed)
        } catch {
            return FileJobResult(file: job.file, entry: entry, hashComputed: false,
                                 error: ScanIssue(path: job.file.path, message: "\(error)"))
        }
    }
}

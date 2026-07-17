import Foundation

public struct ExactGroup: Codable, Hashable, Sendable {
    public var id: String
    public var sha256: String
    public var size: Int64
    /// Paths sorted with the suggested keeper first.
    public var paths: [String]
    public var keep: String
    public var keepReason: String
    /// Number of distinct files (inodes). Lower than `paths.count` when some paths are hard links.
    public var distinctFileCount: Int
    /// Bytes freed by removing every path except the keeper's file. Hard links free nothing.
    public var recoverableBytes: Int64
}

/// Groups files with identical content.
public enum ExactMatcher {
    /// Returns the paths whose content must be hashed: every file sharing its byte size with another path.
    public static func pathsNeedingHash(_ files: [DiscoveredFile]) -> Set<String> {
        var bySize: [Int64: [String]] = [:]
        for f in files { bySize[f.metadata.size, default: []].append(f.path) }
        return Set(bySize.values.filter { $0.count > 1 }.joined())
    }

    /// Groups files by SHA-256. Files without a hash are ignored.
    public static func group(
        files: [DiscoveredFile], hashes: [String: String], policy: KeepPolicy
    ) -> [ExactGroup] {
        var byHash: [String: [DiscoveredFile]] = [:]
        for f in files {
            if let h = hashes[f.path] { byHash[h, default: []].append(f) }
        }
        var groups: [ExactGroup] = []
        for (hash, members) in byHash where members.count > 1 {
            let suggestion = policy.suggestForExactGroup(members.map {
                .init(path: $0.path, size: $0.metadata.size, mtimeNanos: $0.metadata.mtimeNanos)
            })
            let keeper = members.first { $0.path == suggestion.path }!
            let identities = Set(members.map(\.metadata.identity))
            let removableIdentities = identities.subtracting([keeper.metadata.identity])
            let paths = [keeper.path] + members.map(\.path).filter { $0 != keeper.path }.sorted()
            groups.append(ExactGroup(
                id: "x-" + hash.prefix(12),
                sha256: hash,
                size: keeper.metadata.size,
                paths: paths,
                keep: suggestion.path,
                keepReason: suggestion.reason,
                distinctFileCount: identities.count,
                recoverableBytes: Int64(removableIdentities.count) * keeper.metadata.size
            ))
        }
        // Largest potential savings first.
        return groups.sorted {
            ($0.recoverableBytes, $0.paths.count, $1.keep) > ($1.recoverableBytes, $1.paths.count, $0.keep)
        }
    }
}

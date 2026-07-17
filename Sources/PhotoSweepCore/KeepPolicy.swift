import Foundation

/// Chooses which file in a group to suggest keeping, and explains why.
public struct KeepPolicy: Sendable {
    /// Folders whose files are preferred, in priority order (absolute, standardized paths).
    public var preferredFolders: [String]

    public init(preferredFolders: [String] = []) {
        self.preferredFolders = preferredFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    public struct Candidate: Sendable {
        public var path: String
        public var size: Int64
        public var mtimeNanos: Int64
        public var pixelCount: Int?

        public init(path: String, size: Int64, mtimeNanos: Int64, pixelCount: Int? = nil) {
            self.path = path
            self.size = size
            self.mtimeNanos = mtimeNanos
            self.pixelCount = pixelCount
        }
    }

    public struct Suggestion: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    /// Suggestion for byte-identical files. Tie-breakers, in order: preferred folder, a name
    /// that does not look like a copy, shallower path, earliest modification time, path order.
    public func suggestForExactGroup(_ candidates: [Candidate]) -> Suggestion {
        precondition(!candidates.isEmpty)
        let ranked = candidates.sorted { a, b in
            let pa = preferredRank(a.path), pb = preferredRank(b.path)
            if pa != pb { return pa < pb }
            let ca = Self.looksLikeCopy(a.path), cb = Self.looksLikeCopy(b.path)
            if ca != cb { return !ca }
            let da = Self.depth(a.path), db = Self.depth(b.path)
            if da != db { return da < db }
            if a.mtimeNanos != b.mtimeNanos { return a.mtimeNanos < b.mtimeNanos }
            return a.path < b.path
        }
        let best = ranked[0], runnerUp = ranked.count > 1 ? ranked[1] : nil
        let reason: String
        if let folder = preferredFolder(for: best.path),
           runnerUp.map({ preferredRank($0.path) > preferredRank(best.path) }) ?? true {
            reason = "In preferred folder \(folder)"
        } else if let r = runnerUp, !Self.looksLikeCopy(best.path) && Self.looksLikeCopy(r.path) {
            reason = "Other names look like copies"
        } else if let r = runnerUp, Self.depth(best.path) < Self.depth(r.path) {
            reason = "Shallowest folder"
        } else if let r = runnerUp, best.mtimeNanos < r.mtimeNanos {
            reason = "Oldest copy"
        } else {
            reason = "First by path (copies are otherwise equivalent)"
        }
        return Suggestion(path: best.path, reason: reason)
    }

    /// Suggestion for visually similar files: highest resolution, then largest file.
    /// This is only a suggestion: similar images are never pre-selected for removal.
    public func suggestForSimilarGroup(_ candidates: [Candidate]) -> Suggestion {
        precondition(!candidates.isEmpty)
        let ranked = candidates.sorted { a, b in
            let pa = a.pixelCount ?? 0, pb = b.pixelCount ?? 0
            if pa != pb { return pa > pb }
            let fa = preferredRank(a.path), fb = preferredRank(b.path)
            if fa != fb { return fa < fb }
            let ca = Self.looksLikeCopy(a.path), cb = Self.looksLikeCopy(b.path)
            if ca != cb { return !ca }
            if a.size != b.size { return a.size > b.size }
            return a.path < b.path
        }
        let best = ranked[0], runnerUp = ranked[1...].first
        let reason: String
        if let r = runnerUp, (best.pixelCount ?? 0) > (r.pixelCount ?? 0) {
            reason = "Highest resolution"
        } else if let folder = preferredFolder(for: best.path),
                  runnerUp.map({ preferredRank($0.path) > preferredRank(best.path) }) ?? true {
            reason = "Same resolution, in preferred folder \(folder)"
        } else if let r = runnerUp, !Self.looksLikeCopy(best.path) && Self.looksLikeCopy(r.path) {
            reason = "Same resolution, other names look like copies"
        } else if let r = runnerUp, best.size > r.size {
            reason = "Same resolution, largest file (least compressed)"
        } else {
            reason = "Equivalent resolution and size"
        }
        return Suggestion(path: best.path, reason: reason)
    }

    private func preferredRank(_ path: String) -> Int {
        preferredFolders.firstIndex { path.hasPrefix($0 + "/") } ?? preferredFolders.count
    }

    private func preferredFolder(for path: String) -> String? {
        preferredFolders.first { path.hasPrefix($0 + "/") }
    }

    static func depth(_ path: String) -> Int { path.split(separator: "/").count }

    /// Matches common copy naming: "IMG_1 copy.jpg", "IMG_1 copy 2.jpg", "IMG_1 (1).jpg", "IMG_1_copy.jpg".
    static func looksLikeCopy(_ path: String) -> Bool {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let patterns = [#" copy( \d+)?$"#, #" ?\(\d+\)$"#, #"[-_ ]copy$"#]
        return patterns.contains { stem.range(of: $0, options: .regularExpression) != nil }
    }
}

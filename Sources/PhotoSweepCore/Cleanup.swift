import Foundation

/// A validated plan to move selected files into quarantine.
public struct QuarantinePlan: Sendable {
    public struct Move: Sendable, Hashable {
        public var source: String
        public var destination: String
        public var sha256: String
        public var size: Int64
    }

    public struct Rejection: Sendable, Hashable {
        public var path: String
        public var reason: String
    }

    public var operationId: String
    public var root: String
    public var scanId: String
    public var quarantineDirectory: String
    public var moves: [Move]
    public var rejections: [Rejection]

    public var totalBytes: Int64 { moves.reduce(0) { $0 + $1.size } }
}

/// Validates selections against the recorded scan and the current filesystem, then performs and
/// reverses quarantine moves through a journal.
public struct Cleanup: Sendable {
    public var stateDirectory: URL

    public init(stateDirectory: URL = OperationJournal.stateDirectory()) {
        self.stateDirectory = stateDirectory
    }

    public static func newOperationId(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    /// Checks every selection. Files that fail any check are rejected individually; a group is never
    /// left without at least one verified, unselected copy.
    public func plan(selections: SelectionFile, manifest: ScanManifest, operationId: String = newOperationId()) throws -> QuarantinePlan {
        guard selections.scanId == manifest.scanId else {
            throw PhotoSweepError.invalidInput(
                "Selections belong to scan \(selections.scanId), but the manifest is from scan \(manifest.scanId). Export selections from the matching report.")
        }
        let root = manifest.root
        let quarantineDir = root + "/" + PhotoSweep.quarantineDirectoryName + "/" + operationId
        var rejections: [QuarantinePlan.Rejection] = []
        func reject(_ path: String, _ reason: String) { rejections.append(.init(path: path, reason: reason)) }

        // Groups each path belongs to, for membership and retention checks.
        var groupsOf: [String: Set<String>] = [:]
        var membersOf: [String: [String]] = [:]
        for g in manifest.exactGroups {
            membersOf[g.id] = g.paths
            for p in g.paths { groupsOf[p, default: []].insert(g.id) }
        }
        for g in manifest.similarGroups {
            membersOf[g.id] = g.members.map(\.path)
            for m in g.members { groupsOf[m.path, default: []].insert(g.id) }
        }

        // 1–3: membership, location, and current content.
        var candidates: [QuarantinePlan.Move] = []
        var seen = Set<String>()
        for selection in selections.selections {
            let path = selection.path
            guard seen.insert(path).inserted else { continue }
            guard let recorded = manifest.files[path], let groups = groupsOf[path], groups.contains(selection.groupId) else {
                reject(path, "Not part of the recorded scan's groups"); continue
            }
            guard Self.isInside(path, root: root) else { reject(path, "Outside the scanned folder \(root)"); continue }
            guard !path.contains("/\(PhotoSweep.quarantineDirectoryName)/") else { reject(path, "Already in quarantine"); continue }
            guard let expectedHash = recorded.sha256 else { reject(path, "No content hash recorded; re-run the scan"); continue }
            switch Self.verify(path: path, size: recorded.size, sha256: expectedHash) {
            case .failure(let reason): reject(path, reason); continue
            case .success: break
            }
            let relative = String(path.dropFirst(root.count + 1))
            let destination = quarantineDir + "/" + relative
            if FileManager.default.fileExists(atPath: destination) { reject(path, "Quarantine destination already exists"); continue }
            candidates.append(.init(source: path, destination: destination, sha256: expectedHash, size: recorded.size))
        }

        // 4: every touched group must keep at least one unselected copy that still verifies.
        var selected = Set(candidates.map(\.source))
        var verifiedKeepers: [String: Bool] = [:]
        func hasVerifiedKeeper(_ groupId: String) -> Bool {
            for member in membersOf[groupId] ?? [] where !selected.contains(member) {
                if let ok = verifiedKeepers[member] { if ok { return true } else { continue } }
                guard let rec = manifest.files[member], let hash = rec.sha256 else { verifiedKeepers[member] = false; continue }
                let ok = if case .success = Self.verify(path: member, size: rec.size, sha256: hash) { true } else { false }
                verifiedKeepers[member] = ok
                if ok { return true }
            }
            return false
        }
        var moves: [QuarantinePlan.Move] = []
        for move in candidates {
            let groups = groupsOf[move.source] ?? []
            if let bad = groups.sorted().first(where: { !hasVerifiedKeeper($0) }) {
                // Keep this file instead so the group still has a copy.
                selected.remove(move.source)
                verifiedKeepers[move.source] = true
                reject(move.source, "Would leave group \(bad) without an unselected, unchanged copy; kept this file")
            } else {
                moves.append(move)
            }
        }

        // Same-volume requirement: rename(2) cannot cross devices, and copying is not atomic.
        if let rootDevice = try? readMetadata(path: root).identity.device {
            moves.removeAll { move in
                guard let dev = try? readMetadata(path: move.source).identity.device, dev == rootDevice else {
                    reject(move.source, "On a different volume from the scanned folder"); return true
                }
                return false
            }
        }

        return QuarantinePlan(
            operationId: operationId, root: root, scanId: manifest.scanId, quarantineDirectory: quarantineDir,
            moves: moves.sorted { $0.source < $1.source }, rejections: rejections.sorted { $0.path < $1.path })
    }

    /// Performs the plan, journaling each move. Returns the final journal.
    @discardableResult
    public func execute(_ plan: QuarantinePlan, beforeMove: (QuarantinePlan.Move) throws -> Void = { _ in }) throws -> OperationJournal {
        var journal = OperationJournal(
            operationId: plan.operationId, createdAt: Date(), root: plan.root, scanId: plan.scanId,
            quarantineDirectory: plan.quarantineDirectory, entries: [])
        try journal.save(state: stateDirectory)
        for move in plan.moves {
            journal.entries.append(.init(
                original: move.source, destination: move.destination, sha256: move.sha256, size: move.size, status: .pending))
            try journal.save(state: stateDirectory)
            let i = journal.entries.count - 1
            do {
                try beforeMove(move)
                // Re-check immediately before moving: the file may have changed since planning.
                if case .failure(let reason) = Self.verify(path: move.source, size: move.size, sha256: move.sha256) {
                    throw PhotoSweepError.invalidInput(reason)
                }
                try FileManager.default.createDirectory(
                    atPath: (move.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try renameExclusive(from: move.source, to: move.destination)
                journal.entries[i].status = .moved
            } catch {
                journal.entries[i].status = .notMoved
                journal.entries[i].message = "\(error)"
            }
            try journal.save(state: stateDirectory)
        }
        return journal
    }

    public struct UndoResult: Sendable {
        public var journal: OperationJournal
        public var restored: Int
        public var failures: [(path: String, reason: String)]
        public var reconciled: Int
    }

    /// Moves quarantined files back. Never overwrites a file that now exists at the original path.
    public func undo(operationId: String) throws -> UndoResult {
        var journal = try OperationJournal.load(id: operationId, state: stateDirectory)
        let reconciled = journal.reconcile()
        if reconciled > 0 { try journal.save(state: stateDirectory) }
        var restored = 0
        var failures: [(String, String)] = []
        for i in journal.entries.indices where journal.entries[i].status == .moved {
            let entry = journal.entries[i]
            if FileManager.default.fileExists(atPath: entry.original) {
                journal.entries[i].message = "A file now exists at the original path; not overwritten"
                failures.append((entry.original, journal.entries[i].message!))
                continue
            }
            if case .failure(let reason) = Self.verify(path: entry.destination, size: entry.size, sha256: entry.sha256) {
                journal.entries[i].message = "Quarantined file changed: \(reason)"
                failures.append((entry.original, journal.entries[i].message!))
                continue
            }
            journal.entries[i].status = .restoring
            try journal.save(state: stateDirectory)
            do {
                try FileManager.default.createDirectory(
                    atPath: (entry.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try renameExclusive(from: entry.destination, to: entry.original)
                journal.entries[i].status = .restored
                journal.entries[i].message = nil
                restored += 1
            } catch {
                journal.entries[i].status = .moved
                journal.entries[i].message = "\(error)"
                failures.append((entry.original, "\(error)"))
            }
            try journal.save(state: stateDirectory)
        }
        if !journal.entries.contains(where: { $0.status == .moved }) {
            journal.undoneAt = Date()
            Self.removeEmptyDirectories(under: journal.quarantineDirectory)
        }
        try journal.save(state: stateDirectory)
        return UndoResult(journal: journal, restored: restored, failures: failures, reconciled: reconciled)
    }

    /// Finishes reconciliation for an interrupted operation without undoing it.
    public func reconcile(operationId: String) throws -> OperationJournal {
        var journal = try OperationJournal.load(id: operationId, state: stateDirectory)
        if journal.reconcile() > 0 { try journal.save(state: stateDirectory) }
        return journal
    }

    enum Verification { case success, failure(String) }

    static func verify(path: String, size: Int64, sha256: String) -> Verification {
        guard let meta = try? readMetadata(path: path) else { return .failure("File no longer exists") }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .failure("No longer a regular file") }
        guard meta.size == size else { return .failure("File changed since the scan (size differs)") }
        guard let current = try? ContentHasher.sha256(path: path, expected: meta) else { return .failure("Could not re-read file") }
        guard current == sha256 else { return .failure("File changed since the scan (content differs)") }
        return .success
    }

    /// True when `path` is strictly inside `root` after resolving symlinks in its parent folders.
    static func isInside(_ path: String, root: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path, path.hasPrefix(root + "/") else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == root || parent.hasPrefix(root + "/")
    }

    static func removeEmptyDirectories(under directory: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return }
        let dirs = enumerator.compactMap { $0 as? String }.map { directory + "/" + $0 }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            .sorted { $0.count > $1.count }
        for d in dirs + [directory] where (try? fm.contentsOfDirectory(atPath: d))?.isEmpty == true {
            try? fm.removeItem(atPath: d)
        }
        let parent = (directory as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == PhotoSweep.quarantineDirectoryName,
           (try? fm.contentsOfDirectory(atPath: parent))?.isEmpty == true {
            try? fm.removeItem(atPath: parent)
        }
    }
}

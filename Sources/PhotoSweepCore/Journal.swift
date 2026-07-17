import Foundation

/// A durable record of one quarantine operation and, later, its undo.
///
/// Each entry is written as `pending` before its file is moved and updated to `moved` afterwards
/// (and `restoring` → `restored` for undo). The journal is replaced atomically on every change, so
/// after a crash the on-disk state of each pending entry can be reconciled by looking at which of
/// the two paths exists.
public struct OperationJournal: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// About to be moved into quarantine.
        case pending
        /// In quarantine.
        case moved
        /// The move did not happen (file left in place).
        case notMoved = "not-moved"
        /// About to be moved back.
        case restoring
        /// Back at its original path.
        case restored
        /// Both or neither path exists; needs a human.
        case conflict
    }

    public struct Entry: Codable, Sendable, Hashable {
        public var original: String
        public var destination: String
        public var sha256: String
        public var size: Int64
        public var status: Status
        public var message: String?
    }

    public var operationId: String
    public var createdAt: Date
    public var root: String
    public var scanId: String
    public var quarantineDirectory: String
    public var entries: [Entry]
    public var undoneAt: Date?

    /// Where journals are stored: `$PHOTOSWEEP_STATE_DIR` or `~/Library/Application Support/PhotoSweep`.
    public static func stateDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["PHOTOSWEEP_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoSweep")
    }

    static func operationsDirectory(state: URL) -> URL { state.appendingPathComponent("operations") }

    public static func url(for id: String, state: URL = stateDirectory()) -> URL {
        operationsDirectory(state: state).appendingPathComponent("\(id).json")
    }

    public static func load(id: String, state: URL = stateDirectory()) throws -> OperationJournal {
        guard id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw PhotoSweepError.invalidInput("Invalid operation id: \(id)")
        }
        let url = url(for: id, state: state)
        guard let data = try? Data(contentsOf: url) else {
            throw PhotoSweepError.invalidInput("No operation \(id) (looked in \(url.path))")
        }
        return try JSONCoding.decoder.decode(OperationJournal.self, from: data)
    }

    public static func list(state: URL = stateDirectory()) -> [OperationJournal] {
        let dir = operationsDirectory(state: state)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? JSONCoding.decoder.decode(OperationJournal.self, from: Data(contentsOf: dir.appendingPathComponent($0))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(state: URL = stateDirectory()) throws {
        let url = Self.url(for: operationId, state: state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Resolves entries left `pending` or `restoring` by an interrupted run, using the filesystem
    /// as the source of truth. Returns the number of entries changed.
    @discardableResult
    public mutating func reconcile() -> Int {
        let fm = FileManager.default
        var changed = 0
        for i in entries.indices where entries[i].status == .pending || entries[i].status == .restoring {
            let atOriginal = fm.fileExists(atPath: entries[i].original)
            let atDestination = fm.fileExists(atPath: entries[i].destination)
            let before = entries[i].status
            switch (atOriginal, atDestination) {
            case (false, true): entries[i].status = .moved
            case (true, false): entries[i].status = before == .pending ? .notMoved : .restored
            default:
                entries[i].status = .conflict
                entries[i].message = atOriginal
                    ? "Files exist at both the original and quarantine paths; resolve manually."
                    : "File is missing from both the original and quarantine paths."
            }
            if entries[i].status != before {
                changed += 1
                entries[i].message = entries[i].message ?? "Reconciled after an interrupted run"
            }
        }
        return changed
    }

    public var counts: [Status: Int] { Dictionary(grouping: entries, by: \.status).mapValues(\.count) }
}

/// Renames without ever replacing an existing file (atomic on one volume).
func renameExclusive(from source: String, to destination: String) throws {
    if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
        let code = errno
        if code == EEXIST {
            throw PhotoSweepError.invalidInput("Refusing to overwrite existing file: \(destination)")
        }
        throw PhotoSweepError.readFailed(path: source, message: "move to \(destination) failed: \(String(cString: strerror(code)))")
    }
}

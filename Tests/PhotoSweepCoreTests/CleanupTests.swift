import Foundation
import Testing
@testable import PhotoSweepCore

@Suite struct CleanupTests {
    struct Fixture {
        let dir: TempDir
        let state: TempDir
        let manifest: ScanManifest
        var cleanup: Cleanup { Cleanup(stateDirectory: state.url) }
        var group: ExactGroup { manifest.exactGroups[0] }

        func selections(_ paths: [String], groupId: String? = nil) -> SelectionFile {
            SelectionFile(scanId: manifest.scanId, root: manifest.root, manifest: "/unused",
                          selections: paths.map { .init(path: $0, groupId: groupId ?? group.id) })
        }
    }

    /// Three identical copies of one photo plus an unrelated photo.
    func makeFixture() async throws -> Fixture {
        let dir = try TempDir()
        let img = TestImages.jpeg(seed: 21)
        try dir.write("Originals/sunset.jpg", img)
        try dir.write("Exports/sunset copy.jpg", img)
        try dir.write("Exports/Old/sunset.jpg", img)
        try dir.write("other.jpg", TestImages.jpeg(seed: 22))
        let manifest = try await Scanner(options: ScanOptions(root: dir.url, findSimilar: false)).run()
        return Fixture(dir: dir, state: try TempDir(), manifest: manifest)
    }

    @Test func quarantineAndUndoRoundTrip() async throws {
        let f = try await makeFixture()
        let targets = [f.dir.file("Exports/sunset copy.jpg"), f.dir.file("Exports/Old/sunset.jpg")]
        let plan = try f.cleanup.plan(selections: f.selections(targets), manifest: f.manifest)
        #expect(plan.rejections.isEmpty)
        #expect(plan.moves.count == 2)
        let journal = try f.cleanup.execute(plan)
        #expect(journal.entries.allSatisfy { $0.status == .moved })
        for t in targets { #expect(!FileManager.default.fileExists(atPath: t)) }
        // Relative layout is preserved inside the quarantine folder.
        #expect(FileManager.default.fileExists(atPath: plan.quarantineDirectory + "/Exports/Old/sunset.jpg"))

        // Quarantined files are excluded from later scans.
        let rescan = try await Scanner(options: ScanOptions(root: f.dir.url, findSimilar: false)).run()
        #expect(rescan.summary.filesScanned == 2)

        let undo = try f.cleanup.undo(operationId: plan.operationId)
        #expect(undo.restored == 2)
        #expect(undo.failures.isEmpty)
        for t in targets { #expect(FileManager.default.fileExists(atPath: t)) }
        #expect(!FileManager.default.fileExists(atPath: f.dir.file(PhotoSweep.quarantineDirectoryName)))
        #expect(try OperationJournal.load(id: plan.operationId, state: f.state.url).undoneAt != nil)
    }

    @Test func changedFilesAreRejected() async throws {
        let f = try await makeFixture()
        let target = f.dir.file("Exports/sunset copy.jpg")
        var data = try Data(contentsOf: URL(fileURLWithPath: target))
        data[data.count / 2] ^= 0x01 // same size, different content
        try data.write(to: URL(fileURLWithPath: target))
        let plan = try f.cleanup.plan(selections: f.selections([target]), manifest: f.manifest)
        #expect(plan.moves.isEmpty)
        #expect(plan.rejections.first?.reason.contains("content differs") == true)
    }

    @Test func fileChangedAfterPlanningIsNotMoved() async throws {
        let f = try await makeFixture()
        let target = f.dir.file("Exports/sunset copy.jpg")
        let plan = try f.cleanup.plan(selections: f.selections([target]), manifest: f.manifest)
        let journal = try f.cleanup.execute(plan) { move in
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: move.source))
        }
        #expect(journal.entries[0].status == .notMoved)
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test func groupAlwaysKeepsOneCopy() async throws {
        let f = try await makeFixture()
        let plan = try f.cleanup.plan(selections: f.selections(f.group.paths), manifest: f.manifest)
        #expect(plan.moves.count == 2)
        #expect(plan.rejections.count == 1)
        #expect(plan.rejections[0].reason.contains("without an unselected"))
    }

    @Test func keeperThatChangedDoesNotCount() async throws {
        let f = try await makeFixture()
        // The only unselected copy was edited after the scan, so it cannot be relied on.
        try Data([9, 9, 9]).write(to: URL(fileURLWithPath: f.dir.file("Originals/sunset.jpg")))
        let selected = [f.dir.file("Exports/sunset copy.jpg"), f.dir.file("Exports/Old/sunset.jpg")]
        let plan = try f.cleanup.plan(selections: f.selections(selected), manifest: f.manifest)
        #expect(plan.moves.count == 1)
    }

    @Test func rejectsPathsOutsideRootOrNotInScan() async throws {
        let f = try await makeFixture()
        let outside = try TempDir()
        let foreign = try outside.write("x.jpg", Data([1]))
        let plan = try f.cleanup.plan(
            selections: f.selections([foreign, f.dir.file("other.jpg"), f.dir.file("Exports/../../etc/passwd")]),
            manifest: f.manifest)
        #expect(plan.moves.isEmpty)
        #expect(plan.rejections.count == 3)
        #expect(plan.rejections.allSatisfy { $0.reason.contains("Not part of the recorded scan") })

        // Even if a manifest were edited to include an outside path, containment is checked.
        #expect(!Cleanup.isInside("/etc/passwd", root: f.manifest.root))
        #expect(!Cleanup.isInside(f.manifest.root + "/../x.jpg", root: f.manifest.root))
        #expect(Cleanup.isInside(f.manifest.root + "/a/b.jpg", root: f.manifest.root))
    }

    @Test func rejectsSelectionsFromAnotherScan() async throws {
        let f = try await makeFixture()
        var s = f.selections([f.dir.file("Exports/sunset copy.jpg")])
        s.scanId = "different"
        #expect(throws: PhotoSweepError.self) { try f.cleanup.plan(selections: s, manifest: f.manifest) }
    }

    @Test func undoNeverOverwritesANewFile() async throws {
        let f = try await makeFixture()
        let target = f.dir.file("Exports/sunset copy.jpg")
        let plan = try f.cleanup.plan(selections: f.selections([target]), manifest: f.manifest)
        try f.cleanup.execute(plan)
        try Data("new file".utf8).write(to: URL(fileURLWithPath: target))
        let undo = try f.cleanup.undo(operationId: plan.operationId)
        #expect(undo.restored == 0)
        #expect(undo.failures.count == 1)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new file")
        #expect(FileManager.default.fileExists(atPath: plan.moves[0].destination))
        // Once the path is free again, undo can finish.
        try FileManager.default.removeItem(atPath: target)
        #expect(try f.cleanup.undo(operationId: plan.operationId).restored == 1)
    }

    @Test func renameExclusiveRefusesToReplace() throws {
        let dir = try TempDir()
        let a = try dir.write("a.jpg", Data([1])), b = try dir.write("b.jpg", Data([2]))
        #expect(throws: PhotoSweepError.self) { try renameExclusive(from: a, to: b) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: b)) == Data([2]))
    }

    @Test func interruptedOperationIsReconciled() async throws {
        let f = try await makeFixture()
        let moved = f.dir.file("Exports/sunset copy.jpg"), untouched = f.dir.file("Exports/Old/sunset.jpg")
        let plan = try f.cleanup.plan(selections: f.selections([moved, untouched]), manifest: f.manifest)
        // Simulate a crash: both entries written as pending, but only the first file was moved.
        var journal = OperationJournal(
            operationId: plan.operationId, createdAt: Date(), root: plan.root, scanId: plan.scanId,
            quarantineDirectory: plan.quarantineDirectory,
            entries: plan.moves.map { .init(original: $0.source, destination: $0.destination, sha256: $0.sha256, size: $0.size, status: .pending) })
        try journal.save(state: f.state.url)
        let first = plan.moves.first { $0.source == moved }!
        try FileManager.default.createDirectory(atPath: (first.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try renameExclusive(from: first.source, to: first.destination)

        journal = try f.cleanup.reconcile(operationId: plan.operationId)
        #expect(journal.entries.first { $0.original == moved }?.status == .moved)
        #expect(journal.entries.first { $0.original == untouched }?.status == .notMoved)

        let undo = try f.cleanup.undo(operationId: plan.operationId)
        #expect(undo.restored == 1)
        #expect(FileManager.default.fileExists(atPath: moved))
    }

    @Test func listsOperations() async throws {
        let f = try await makeFixture()
        let plan = try f.cleanup.plan(selections: f.selections([f.dir.file("Exports/sunset copy.jpg")]), manifest: f.manifest)
        try f.cleanup.execute(plan)
        #expect(OperationJournal.list(state: f.state.url).map(\.operationId) == [plan.operationId])
        #expect(throws: PhotoSweepError.self) { try OperationJournal.load(id: "../escape", state: f.state.url) }
    }
}

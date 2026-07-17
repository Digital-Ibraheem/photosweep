import ArgumentParser
import Foundation
import PhotoSweepCore

struct Quarantine: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the files chosen in a report into a quarantine folder (reversible with 'undo').")

    @Argument(help: "selections.json exported from the report.", completion: .file(extensions: ["json"]))
    var selections: String

    @Option(help: "Scan manifest (default: the scan.json recorded in the selections file).")
    var manifest: String?

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "Validate and show the plan without moving anything.")
    var dryRun = false

    func run() throws {
        let selectionURL = URL(fileURLWithPath: absolutePath(selections))
        let file = try SelectionFile.load(from: selectionURL)
        let manifestURL = try resolveManifest(file, selectionURL: selectionURL)
        let scan = try ScanManifest.load(from: manifestURL)

        print("Checking \(file.selections.count) selected files against scan \(scan.scanId.prefix(8)) and current disk contents...")
        let cleanup = Cleanup()
        let plan = try cleanup.plan(selections: file, manifest: scan)

        if !plan.rejections.isEmpty {
            print("\nSkipping \(plan.rejections.count) file(s):")
            for r in plan.rejections { print("  ✗ \(display(r.path, root: plan.root)) — \(r.reason)") }
        }
        guard !plan.moves.isEmpty else {
            print("\nNothing to move.")
            throw ExitCode(plan.rejections.isEmpty ? 0 : 1)
        }
        print("\nWill move \(plan.moves.count) file(s), \(bytes(plan.totalBytes)), into:\n  \(plan.quarantineDirectory)\n")
        for m in plan.moves { print("  → \(display(m.source, root: plan.root))") }

        if dryRun { print("\nDry run: nothing was moved."); return }
        if !yes {
            print("\nProceed? [y/N] ", terminator: "")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled; nothing was moved.")
                return
            }
        }

        let journal = try cleanup.execute(plan)
        let moved = journal.entries.filter { $0.status == .moved }
        let failed = journal.entries.filter { $0.status != .moved }
        print("\nMoved \(moved.count) file(s) (\(bytes(moved.reduce(0) { $0 + $1.size }))) to quarantine.")
        for f in failed { print("  ✗ \(display(f.original, root: plan.root)) — \(f.message ?? f.status.rawValue)") }
        print("Operation id: \(journal.operationId)")
        print("Undo with:    photosweep undo \(journal.operationId)")
        if !failed.isEmpty { throw ExitCode(1) }
    }

    func resolveManifest(_ file: SelectionFile, selectionURL: URL) throws -> URL {
        if let manifest { return URL(fileURLWithPath: absolutePath(manifest)) }
        let candidates = [
            URL(fileURLWithPath: file.manifest),
            selectionURL.deletingLastPathComponent().appendingPathComponent("scan.json"),
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ValidationError("Cannot find the scan manifest \(file.manifest). Pass it with --manifest.")
        }
        return found
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore the files moved by a quarantine operation.")

    @Argument(help: "Operation id printed by 'quarantine' (see 'photosweep operations').")
    var operationId: String

    func run() throws {
        let result = try Cleanup().undo(operationId: operationId)
        if result.reconciled > 0 { print("Reconciled \(result.reconciled) entries left by an interrupted run.") }
        print("Restored \(result.restored) file(s).")
        for f in result.failures { print("  ✗ \(display(f.path, root: result.journal.root)) — \(f.reason)") }
        let remaining = result.journal.entries.filter { $0.status == .moved }.count
        if remaining > 0 {
            print("\(remaining) file(s) remain in \(result.journal.quarantineDirectory). Resolve the issues above and run undo again.")
            throw ExitCode(1)
        }
    }
}

struct Operations: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List quarantine operations and their status.")

    func run() throws {
        let journals = OperationJournal.list()
        guard !journals.isEmpty else { print("No operations recorded in \(OperationJournal.stateDirectory().path)"); return }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        for j in journals {
            let c = j.counts
            var parts: [String] = []
            for (status, label) in [(OperationJournal.Status.moved, "in quarantine"), (.restored, "restored"), (.notMoved, "not moved"),
                                    (.pending, "pending"), (.restoring, "restoring"), (.conflict, "conflict")] {
                if let n = c[status], n > 0 { parts.append("\(n) \(label)") }
            }
            print("\(j.operationId)  \(f.string(from: j.createdAt))  \(j.root)\n    \(parts.joined(separator: ", "))\(j.undoneAt != nil ? " · undone" : "")")
        }
    }
}

func display(_ path: String, root: String) -> String {
    path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

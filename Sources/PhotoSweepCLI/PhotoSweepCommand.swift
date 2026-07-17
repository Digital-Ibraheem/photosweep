import ArgumentParser
import Foundation
import PhotoSweepCore

@main
struct PhotoSweepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photosweep",
        abstract: "Find duplicate and similar photos, review them, and safely quarantine copies.",
        version: PhotoSweep.version,
        subcommands: [Scan.self]
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan a folder and write an HTML review report.")

    @Argument(help: "Folder to scan.", completion: .directory)
    var folder: String

    @Option(name: .shortAndLong, help: "Report output folder.")
    var output: String = "./photosweep-report"

    @Option(name: .customLong("prefer"), help: "Prefer keeping copies inside this folder (repeatable, highest priority first).")
    var preferredFolders: [String] = []

    func run() throws {
        let root = URL(fileURLWithPath: folder)
        let options = ScanOptions(root: root, preferredFolders: preferredFolders.map(absolutePath))
        let progress = ProgressLine()
        let manifest = try Scanner(options: options).run { event in progress.update(event) }
        progress.finish()

        let report = ReportGenerator(outputDirectory: URL(fileURLWithPath: absolutePath(output)))
        try report.write(manifest)
        printSummary(manifest.summary)
        print("Report: \(report.htmlURL.path)")
    }
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

func printSummary(_ s: ScanSummary) {
    let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    print("""
    Scanned \(s.filesScanned) photos (\(bytes(s.bytesScanned))) in \(String(format: "%.2f", s.durationSeconds))s
      Exact duplicate groups: \(s.exactGroupCount) (\(s.exactDuplicateFiles) extra copies, \(bytes(s.recoverableBytes)) recoverable)
      Hashes computed: \(s.hashesComputed)
      Errors: \(s.errorCount), skipped non-photo files: \(s.skippedFiles)
    """)
}

/// Single-line progress on stderr, only when attached to a terminal.
final class ProgressLine: @unchecked Sendable {
    private let enabled = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var last = Date.distantPast

    func update(_ event: ScanProgress) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1 else { return }
        last = now
        let text: String
        switch event {
        case .discovered(let n): text = "Found \(n) photos"
        case .hashing(let done, let total): text = "Hashing \(done)/\(total)"
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K\(text)".utf8))
    }

    func finish() {
        guard enabled else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

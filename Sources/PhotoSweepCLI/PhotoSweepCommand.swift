import ArgumentParser
import Foundation
import PhotoSweepCore

@main
struct PhotoSweepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photosweep",
        abstract: "Find duplicate and similar photos, review them, and safely quarantine copies.",
        version: PhotoSweep.version,
        subcommands: [Scan.self]
    )
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan a folder and write an HTML review report.")

    @Argument(help: "Folder to scan.", completion: .directory)
    var folder: String

    @Option(name: .shortAndLong, help: "Report output folder.")
    var output: String = "./photosweep-report"

    @Option(name: .customLong("prefer"), help: "Prefer keeping copies inside this folder (repeatable, highest priority first).")
    var preferredFolders: [String] = []

    @Option(help: "Number of concurrent hashing/decoding workers.")
    var workers: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8)

    @Option(help: "Cache file (default: ~/Library/Caches/PhotoSweep/<root hash>.json).")
    var cache: String?

    @Flag(help: "Do not read or write the persistent cache.")
    var noCache = false

    @Flag(help: "Ignore cached results and recompute every hash and fingerprint.")
    var verify = false

    func validate() throws {
        guard workers >= 1 else { throw ValidationError("--workers must be at least 1") }
    }

    func run() async throws {
        let root = URL(fileURLWithPath: absolutePath(folder)).resolvingSymlinksInPath()
        let cacheURL: URL? = noCache ? nil : cache.map { URL(fileURLWithPath: absolutePath($0)) }
            ?? ScanCache.defaultURL(forRoot: root.path)
        let options = ScanOptions(
            root: root, preferredFolders: preferredFolders.map(absolutePath), workers: workers,
            cacheURL: cacheURL, verify: verify)
        let progress = ProgressLine()
        let interrupt = InterruptHandler()
        let manifest: ScanManifest
        do {
            manifest = try await Scanner(options: options).run(cancellation: interrupt.flag) { progress.update($0) }
        } catch let cancelled as ScanCancelled {
            progress.finish()
            print(cancelled.description)
            throw ExitCode(130)
        }
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
      Cache hits: \(s.cacheHits), hashes computed: \(s.hashesComputed), workers: \(s.workers)
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
        case .processing(let done, let total): text = "Processing \(done)/\(total)"
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K\(text)".utf8))
    }

    func finish() {
        guard enabled else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

/// Turns the first Ctrl-C into a graceful stop (finish in-flight files, save the cache).
/// A second Ctrl-C exits immediately.
final class InterruptHandler: @unchecked Sendable {
    let flag = CancellationFlag()
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [flag] in
            if flag.isCancelled { exit(130) }
            flag.cancel()
            FileHandle.standardError.write(Data("\nStopping after in-flight files; press Ctrl-C again to quit now.\n".utf8))
        }
        source.resume()
    }
}

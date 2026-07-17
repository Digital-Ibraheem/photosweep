import CryptoKit
import Foundation

/// Writes `scan.json`, thumbnails and a self-contained `index.html` into a report folder.
public struct ReportGenerator: Sendable {
    public var outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory.standardizedFileURL
    }

    public var manifestURL: URL { outputDirectory.appendingPathComponent("scan.json") }
    public var htmlURL: URL { outputDirectory.appendingPathComponent("index.html") }

    /// Generates thumbnails, then writes the manifest and HTML. Returns the manifest with thumbnail paths filled in.
    @discardableResult
    public func write(_ input: ScanManifest) throws -> ScanManifest {
        var manifest = input
        let fm = FileManager.default
        let thumbs = outputDirectory.appendingPathComponent("thumbs")
        try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)

        for path in manifest.files.keys.sorted() {
            let name = Self.thumbnailName(for: path)
            let dest = thumbs.appendingPathComponent(name)
            if ImageInspector.writeThumbnail(from: path, to: dest) {
                manifest.files[path]?.thumbnail = "thumbs/" + name
            }
        }
        try manifest.write(to: manifestURL)
        try Data(renderHTML(manifest).utf8).write(to: htmlURL, options: .atomic)
        return manifest
    }

    static func thumbnailName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    func renderHTML(_ m: ScanManifest) -> String {
        let e = HTML.escape
        var cards = ""
        for group in m.exactGroups {
            var items = ""
            for path in group.paths {
                let f = m.files[path]
                let thumb = f?.thumbnail.map { "<img src=\"\(e(HTML.urlPath($0)))\" alt=\"\">" } ?? "<div class=\"noimg\">No preview</div>"
                let dims = f.flatMap { f in f.width.map { "\($0) × \(f.height ?? 0)" } } ?? "unknown size"
                let rel = relativePath(path, root: m.root)
                items += """
                <figure class="\(path == group.keep ? "keep" : "")">\(thumb)
                <figcaption><div class="path" title="\(e(path))">\(e(rel))</div>
                <div class="meta">\(dims) · \(HTML.bytes(f?.size ?? 0))</div>
                \(path == group.keep ? "<div class=\"badge\">Keep: \(e(group.keepReason))</div>" : "")</figcaption></figure>
                """
            }
            cards += """
            <section class="card"><h3>\(group.paths.count) identical files · \(HTML.bytes(group.recoverableBytes)) recoverable</h3>
            <div class="items">\(items)</div></section>

            """
        }
        let s = m.summary
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PhotoSweep Report</title>
        <style>
        body{font:14px -apple-system,system-ui,sans-serif;margin:24px;background:#f6f6f4;color:#222}
        .card{background:#fff;border-radius:10px;padding:16px;margin:16px 0;box-shadow:0 1px 3px rgba(0,0,0,.08)}
        .items{display:flex;flex-wrap:wrap;gap:12px}
        figure{margin:0;width:240px} figure img,.noimg{width:240px;height:180px;object-fit:contain;background:#eee;border-radius:6px}
        .noimg{display:flex;align-items:center;justify-content:center;color:#888}
        figure.keep img{outline:3px solid #2a8a4a}
        .path{word-break:break-all;font-weight:600}.meta{color:#666}.badge{color:#2a8a4a}
        </style></head><body>
        <h1>PhotoSweep</h1>
        <p>\(e(m.root)) · \(s.filesScanned) files scanned · \(s.exactGroupCount) exact duplicate groups · \(HTML.bytes(s.recoverableBytes)) recoverable · \(s.errorCount) errors</p>
        \(cards.isEmpty ? "<p>No duplicates found.</p>" : cards)
        </body></html>
        """
    }

    func relativePath(_ path: String, root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}

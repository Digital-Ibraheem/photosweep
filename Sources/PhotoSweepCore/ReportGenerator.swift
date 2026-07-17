import CryptoKit
import Foundation

/// Writes `scan.json`, thumbnails and a self-contained `index.html` into a report folder.
///
/// The page has no external assets and needs no server: it is opened from disk, the user ticks
/// unwanted copies, and the page downloads a `selections.json` for `photosweep quarantine`.
public struct ReportGenerator: Sendable {
    public var outputDirectory: URL
    public var workers: Int

    public init(outputDirectory: URL, workers: Int = 4) {
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.workers = workers
    }

    public var manifestURL: URL { outputDirectory.appendingPathComponent("scan.json") }
    public var htmlURL: URL { outputDirectory.appendingPathComponent("index.html") }

    /// Generates thumbnails, then writes the manifest and HTML. Returns the manifest with thumbnail paths filled in.
    @discardableResult
    public func write(_ input: ScanManifest) async throws -> ScanManifest {
        var manifest = input
        let fm = FileManager.default
        let thumbs = outputDirectory.appendingPathComponent("thumbs")
        try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)

        let paths = manifest.files.keys.sorted()
        await forEachBounded(paths, workers: workers, body: { path -> (String, String?) in
            let name = Self.thumbnailName(for: path)
            let ok = ImageInspector.writeThumbnail(from: path, to: thumbs.appendingPathComponent(name))
            return (path, ok ? "thumbs/" + name : nil)
        }, onResult: { result in
            manifest.files[result.0]?.thumbnail = result.1
        })
        try manifest.write(to: manifestURL)
        try Data(renderHTML(manifest).utf8).write(to: htmlURL, options: .atomic)
        return manifest
    }

    static func thumbnailName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    // MARK: - HTML

    func renderHTML(_ m: ScanManifest) -> String {
        let e = HTML.escape
        let s = m.summary
        let rootName = URL(fileURLWithPath: m.root).lastPathComponent
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let exactCards = m.exactGroups.enumerated().map { exactCard($1, index: $0 + 1, m) }.joined(separator: "\n")
        let similarCards = m.similarGroups.enumerated().map { similarCard($1, index: $0 + 1, m) }.joined(separator: "\n")
        let issueRows = m.issues.map { "<tr><td class=\"mono\">\(e(relative($0.path, m.root)))</td><td>\(e($0.message))</td></tr>" }.joined()

        let tiles: [(String, String, String)] = [
            ("Photos scanned", "\(s.filesScanned)", HTML.bytes(s.bytesScanned)),
            ("Exact duplicate groups", "\(s.exactGroupCount)", "\(s.exactDuplicateFiles) extra \(s.exactDuplicateFiles == 1 ? "copy" : "copies")"),
            ("Recoverable from exact copies", HTML.bytes(s.recoverableBytes), "hard links excluded"),
            ("Visual match candidates", "\(s.similarGroupCount)", s.similarityThreshold > 0 ? "threshold \(s.similarityThreshold)/64 bits" : "visual matching off"),
            ("Cache hits", "\(s.cacheHits)", "\(s.hashesComputed) hashed · \(s.fingerprintsComputed) decoded"),
            ("Errors & skipped", "\(s.errorCount)", "\(s.skippedFiles) non-photo files skipped"),
        ]
        let tileHTML = tiles.map { "<div class=\"tile\"><div class=\"tile-label\">\(e($0.0))</div><div class=\"tile-value\">\(e($0.1))</div><div class=\"tile-sub\">\(e($0.2))</div></div>" }.joined()

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PhotoSweep · \(e(rootName))</title>
        <style>\(Self.css)</style>
        </head>
        <body data-scan-id="\(e(m.scanId))" data-root="\(e(m.root))" data-manifest="\(e(manifestURL.path))">
        <header class="page-head">
          <div class="brand">PhotoSweep</div>
          <h1>\(e(rootName))</h1>
          <p class="sub"><span class="mono">\(e(m.root))</span> · scanned \(e(dateFormatter.string(from: m.createdAt))) in \(String(format: "%.1f", s.durationSeconds))s</p>
        </header>

        <section class="tiles">\(tileHTML)</section>

        <section class="howto">
          <ol>
            <li><b>Review</b> each group. The <span class="keep-chip">Keep</span> photo is only a suggestion.</li>
            <li><b>Tick</b> the copies you don’t need. Nothing is deleted: files are moved to a quarantine folder you can undo.</li>
            <li><b>Export selections</b>, then run the command shown. PhotoSweep re-checks every file before moving it.</li>
          </ol>
        </section>

        <nav class="tabs">
          <a href="#exact">Exact duplicates <span class="count">\(m.exactGroups.count)</span></a>
          <a href="#similar">Visually similar <span class="count">\(m.similarGroups.count)</span></a>
          <a href="#issues">Issues <span class="count">\(m.issues.count)</span></a>
        </nav>

        <section id="exact" class="section">
          <h2>Exact duplicates</h2>
          <p class="section-note">Byte-for-byte identical files (same SHA-256). Removing any copy except one loses nothing.</p>
          \(exactCards.isEmpty ? "<p class=\"empty\">No exact duplicates found.</p>" : exactCards)
        </section>

        <section id="similar" class="section">
          <h2>Visually similar</h2>
          <p class="section-note">These look alike but are <b>not identical</b>: different size, compression or edits. Compare before selecting. Nothing here is pre-selected.</p>
          \(similarCards.isEmpty ? "<p class=\"empty\">No visual matches found.</p>" : similarCards)
        </section>

        <section id="issues" class="section">
          <h2>Issues</h2>
          \(issueRows.isEmpty ? "<p class=\"empty\">No errors.</p>" : "<table class=\"issues\"><thead><tr><th>File</th><th>Problem</th></tr></thead><tbody>\(issueRows)</tbody></table>")
        </section>

        <div class="bar" role="region" aria-label="Selection">
          <div class="bar-status"><span id="sel-count">0 files selected</span><span id="sel-size" class="muted"></span><span id="sel-warning" class="warn" hidden></span></div>
          <div class="bar-actions">
            <button type="button" id="clear" class="ghost">Clear</button>
            <button type="button" id="export" class="primary" disabled>Export selections</button>
          </div>
        </div>

        <dialog id="done">
          <h3>Selections exported</h3>
          <p>Your browser saved <b>selections.json</b> (usually in Downloads). To move the selected files into quarantine, run:</p>
          <pre id="cmd" class="mono"></pre>
          <p class="muted">You’ll see the full list and be asked to confirm. Every move can be reversed with <span class="mono">photosweep undo &lt;operation-id&gt;</span>.</p>
          <div class="dialog-actions">
            <button type="button" id="copy-json" class="ghost">Copy JSON instead</button>
            <button type="button" id="copy-cmd" class="ghost">Copy command</button>
            <button type="button" id="close" class="primary">Done</button>
          </div>
        </dialog>

        <script>\(Self.javascript)</script>
        </body>
        </html>
        """
    }

    func exactCard(_ g: ExactGroup, index: Int, _ m: ScanManifest) -> String {
        let e = HTML.escape
        let hardLinksOnly = g.distinctFileCount == 1
        let title = hardLinksOnly
            ? "\(g.paths.count) paths to the same file (hard links)"
            : "\(g.paths.count) identical copies"
        let detail = hardLinksOnly ? "nothing to recover" : "\(HTML.bytes(g.recoverableBytes)) recoverable · \(HTML.bytes(g.size)) each"
        var identityCounts: [FileIdentity: Int] = [:]
        for p in g.paths { if let f = m.files[p] { identityCounts[f.identity, default: 0] += 1 } }
        let photos = g.paths.map { path in
            let hardLinked = (m.files[path].map { identityCounts[$0.identity] ?? 0 } ?? 0) > 1
            return photo(path: path, group: g.id, isKeep: path == g.keep, keepReason: g.keepReason,
                         extra: hardLinked ? "<div class=\"chip\">Hard link: shares storage with another path</div>" : "", m)
        }.joined()
        return """
        <article class="card" data-group="\(e(g.id))" data-kind="exact">
          <header class="card-head">
            <div><span class="idx">#\(index)</span> <b>\(e(title))</b> <span class="muted">· \(e(detail))</span></div>
            <button type="button" class="ghost small" data-select-others="\(e(g.id))">Select all except Keep</button>
          </header>
          <div class="group-warning" hidden>Every copy in this group is selected. Leave at least one unticked.</div>
          <div class="photos">\(photos)</div>
        </article>
        """
    }

    func similarCard(_ g: SimilarGroup, index: Int, _ m: ScanManifest) -> String {
        let e = HTML.escape
        let photos = g.members.map { member -> String in
            var extra = ""
            if member.path != g.representative {
                extra += "<div class=\"meta\">\(e(Self.closeness(member.distance))) · \(member.distance)/64 bits differ</div>"
            } else {
                extra += "<div class=\"meta\">Reference image for this group</div>"
            }
            if member.exactGroupId != nil { extra += "<div class=\"chip\">Also has exact copies (see Exact duplicates)</div>" }
            return photo(path: member.path, group: g.id, isKeep: member.path == g.keep, keepReason: g.keepReason, extra: extra, m)
        }.joined()
        return """
        <article class="card" data-group="\(e(g.id))" data-kind="similar">
          <header class="card-head">
            <div><span class="idx">#\(index)</span> <b>\(g.members.count) similar photos</b> <span class="muted">· not identical — compare before selecting</span></div>
          </header>
          <div class="group-warning" hidden>Every photo in this group is selected. Leave at least one unticked.</div>
          <div class="photos">\(photos)</div>
        </article>
        """
    }

    func photo(path: String, group: String, isKeep: Bool, keepReason: String, extra: String, _ m: ScanManifest) -> String {
        let e = HTML.escape
        let f = m.files[path]
        let rel = relative(path, m.root)
        let name = (rel as NSString).lastPathComponent
        let folder = (rel as NSString).deletingLastPathComponent
        let dims = f.flatMap { f in f.width.map { "\($0) × \(f.height ?? 0)" } } ?? "unknown dimensions"
        let date = f.map { DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double($0.mtimeNanos) / 1e9), dateStyle: .medium, timeStyle: .none) } ?? ""
        let img = f?.thumbnail.map { "<img loading=\"lazy\" src=\"\(e(HTML.urlPath($0)))\" alt=\"\(e(name))\">" }
            ?? "<div class=\"noimg\">No preview<br><small>(could not decode)</small></div>"
        let fileURL = URL(fileURLWithPath: path).absoluteString
        let identity = f.map { "\($0.identity.device):\($0.identity.inode)" } ?? ""
        return """
        <label class="photo\(isKeep ? " keep" : "")">
          <div class="thumb">\(img)\(isKeep ? "<span class=\"keep-chip\">Keep</span>" : "")</div>
          <div class="info">
            <div class="name" title="\(e(path))">\(e(name))</div>
            <div class="folder mono" title="\(e(path))">\(e(folder.isEmpty ? "(top level)" : folder + "/"))</div>
            <div class="meta">\(e(dims)) · \(HTML.bytes(f?.size ?? 0)) · \(e(date))</div>
            \(isKeep ? "<div class=\"reason\">Suggested keep: \(e(keepReason))</div>" : "")
            \(extra)
            <div class="actions">
              <span class="check"><input type="checkbox" data-path="\(e(path))" data-group="\(e(group))" data-size="\(f?.size ?? 0)" data-inode="\(e(identity))"\(isKeep ? " data-keep" : "")> Move to quarantine</span>
              <a class="open" href="\(e(fileURL))" target="_blank" rel="noopener">Open</a>
            </div>
          </div>
        </label>
        """
    }

    static func closeness(_ d: Int) -> String {
        switch d {
        case 0...2: return "Near-identical"
        case 3...6: return "Very similar"
        default: return "Similar"
        }
    }

    func relative(_ path: String, _ root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    // MARK: - Assets (inline so the report is self-contained)

    static let css = """
    :root{--bg:#f5f4f0;--surface:#fff;--ink:#1d1d1b;--muted:#6b6a65;--line:#e3e1da;--accent:#2f6f4f;--accent-ink:#fff;--accent-soft:#e3efe8;--sel:#b4442c;--sel-soft:#f8e6e1;--warn:#9a5b00;--shadow:0 1px 2px rgba(0,0,0,.05),0 2px 8px rgba(0,0,0,.04)}
    @media (prefers-color-scheme:dark){:root{--bg:#161615;--surface:#21211f;--ink:#ecebe6;--muted:#a3a29b;--line:#34332f;--accent:#6cbf92;--accent-ink:#0d1f15;--accent-soft:#1e3328;--sel:#f08a70;--sel-soft:#3a231d;--warn:#f0b35a;--shadow:none}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;padding:32px clamp(16px,4vw,48px) 120px}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.86em}
    .muted{color:var(--muted)}
    .brand{font-weight:700;letter-spacing:.08em;text-transform:uppercase;font-size:12px;color:var(--accent)}
    h1{margin:4px 0 2px;font-size:30px;letter-spacing:-.01em}
    .sub{margin:0;color:var(--muted);word-break:break-all}
    .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:24px 0}
    .tile{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;box-shadow:var(--shadow)}
    .tile-label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
    .tile-value{font-size:26px;font-weight:650;margin-top:4px;font-variant-numeric:tabular-nums}
    .tile-sub{font-size:13px;color:var(--muted)}
    .howto{background:var(--accent-soft);border-radius:12px;padding:12px 20px;margin-bottom:20px}
    .howto ol{margin:0;padding-left:20px}.howto li{margin:4px 0}
    .tabs{position:sticky;top:0;z-index:5;display:flex;gap:6px;flex-wrap:wrap;padding:10px 0;background:var(--bg);border-bottom:1px solid var(--line)}
    .tabs a{color:var(--ink);text-decoration:none;padding:6px 12px;border-radius:999px;border:1px solid var(--line);background:var(--surface);font-weight:550}
    .tabs a:hover{border-color:var(--accent)}
    .count{color:var(--muted);font-weight:400;margin-left:2px}
    .section{padding-top:16px;scroll-margin-top:60px}
    h2{font-size:21px;margin:12px 0 2px}
    .section-note{color:var(--muted);margin:0 0 12px}
    .empty{color:var(--muted);font-style:italic}
    .card{background:var(--surface);border:1px solid var(--line);border-radius:14px;margin:14px 0;box-shadow:var(--shadow);overflow:hidden}
    .card-head{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
    .idx{color:var(--muted);font-variant-numeric:tabular-nums}
    .group-warning{background:var(--sel-soft);color:var(--sel);padding:8px 16px;font-weight:550}
    .card.invalid{border-color:var(--sel)}
    .photos{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px;padding:16px}
    .photo{display:flex;flex-direction:column;border:2px solid transparent;border-radius:10px;cursor:pointer;transition:border-color .12s,background .12s}
    .photo:hover{background:color-mix(in srgb,var(--bg) 60%,transparent)}
    .photo.keep{border-color:var(--accent)}
    .photo.selected{border-color:var(--sel);background:var(--sel-soft)}
    .thumb{position:relative;aspect-ratio:4/3;background:var(--bg);border-radius:8px 8px 0 0;display:flex;align-items:center;justify-content:center;overflow:hidden}
    .thumb img{width:100%;height:100%;object-fit:contain}
    .photo.selected .thumb img{opacity:.55}
    .noimg{color:var(--muted);text-align:center}
    .keep-chip{display:inline-block;background:var(--accent);color:var(--accent-ink);font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:2px 8px;border-radius:999px}
    .thumb .keep-chip{position:absolute;top:8px;left:8px}
    .info{padding:10px 10px 12px;min-width:0}
    .name{font-weight:650;overflow-wrap:anywhere}
    .folder{color:var(--muted);overflow-wrap:anywhere}
    .meta{color:var(--muted);font-size:13px;margin-top:2px}
    .reason{color:var(--accent);font-size:13px;margin-top:4px;font-weight:550}
    .chip{display:inline-block;margin-top:6px;font-size:12px;padding:2px 8px;border-radius:6px;background:var(--bg);color:var(--muted)}
    .actions{display:flex;justify-content:space-between;align-items:center;margin-top:10px}
    .check{display:inline-flex;align-items:center;gap:6px;font-weight:550}
    .check input{width:18px;height:18px;accent-color:var(--sel)}
    .open{font-size:13px;color:var(--muted)}
    table.issues{width:100%;border-collapse:collapse;background:var(--surface);border-radius:10px;overflow:hidden}
    .issues th,.issues td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}
    button{font:inherit;border-radius:8px;padding:8px 16px;cursor:pointer;border:1px solid var(--line);background:var(--surface);color:var(--ink)}
    button.small{padding:4px 10px;font-size:13px}
    button.primary{background:var(--accent);color:var(--accent-ink);border-color:var(--accent);font-weight:650}
    button:disabled{opacity:.45;cursor:not-allowed}
    .bar{position:fixed;left:0;right:0;bottom:0;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;padding:12px clamp(16px,4vw,48px);background:var(--surface);border-top:1px solid var(--line);box-shadow:0 -4px 16px rgba(0,0,0,.06)}
    .bar-status{display:flex;gap:12px;flex-wrap:wrap;align-items:baseline}
    #sel-count{font-weight:650}
    .warn{color:var(--sel);font-weight:550}
    .bar-actions{display:flex;gap:8px}
    dialog{border:1px solid var(--line);border-radius:14px;background:var(--surface);color:var(--ink);max-width:640px;width:calc(100% - 32px);padding:20px 24px}
    dialog::backdrop{background:rgba(0,0,0,.35)}
    dialog h3{margin-top:0}
    pre{background:var(--bg);padding:12px;border-radius:8px;white-space:pre-wrap;word-break:break-all}
    .dialog-actions{display:flex;justify-content:flex-end;gap:8px;flex-wrap:wrap}
    """

    static let javascript = """
    (function(){
      const body=document.body, scanId=body.dataset.scanId, storeKey='photosweep:'+scanId;
      const boxes=[...document.querySelectorAll('input[type=checkbox][data-path]')];
      const exportBtn=document.getElementById('export');
      const fmt=n=>{const u=['bytes','KB','MB','GB','TB'];let i=0;while(n>=1000&&i<u.length-1){n/=1000;i++}return (i?n.toFixed(1):n)+' '+u[i]};
      function save(){try{localStorage.setItem(storeKey,JSON.stringify(boxes.filter(b=>b.checked).map(b=>b.dataset.group+'\\n'+b.dataset.path)))}catch(e){}}
      function restore(){try{const s=new Set(JSON.parse(localStorage.getItem(storeKey)||'[]'));boxes.forEach(b=>{b.checked=s.has(b.dataset.group+'\\n'+b.dataset.path)})}catch(e){}}
      function update(){
        let count=0,invalid=0;const inodes=new Map();
        document.querySelectorAll('.card').forEach(card=>{
          const bs=[...card.querySelectorAll('input[data-path]')];
          const all=bs.length>0&&bs.every(b=>b.checked);
          card.classList.toggle('invalid',all);card.querySelector('.group-warning').hidden=!all;
          if(all)invalid++;
        });
        const seen=new Set();
        boxes.forEach(b=>{
          b.closest('.photo').classList.toggle('selected',b.checked);
          if(!b.checked||seen.has(b.dataset.path))return;
          seen.add(b.dataset.path);count++;inodes.set(b.dataset.inode,+b.dataset.size);
        });
        const bytes=[...inodes.values()].reduce((a,b)=>a+b,0);
        document.getElementById('sel-count').textContent=count+(count===1?' file':' files')+' selected';
        document.getElementById('sel-size').textContent=count?'up to '+fmt(bytes)+' freed':'';
        const w=document.getElementById('sel-warning');w.hidden=!invalid;
        w.textContent=invalid?invalid+(invalid===1?' group has':' groups have')+' every copy selected':'';
        exportBtn.disabled=!count||invalid>0;
      }
      // Keep the same file's checkboxes in sync when it appears in an exact and a similar group.
      boxes.forEach(b=>b.addEventListener('change',()=>{
        boxes.forEach(o=>{if(o!==b&&o.dataset.path===b.dataset.path)o.checked=b.checked});save();update();
      }));
      document.querySelectorAll('[data-select-others]').forEach(btn=>btn.addEventListener('click',()=>{
        const card=btn.closest('.card');
        card.querySelectorAll('input[data-path]').forEach(b=>{b.checked=!('keep' in b.dataset)});
        card.querySelectorAll('input[data-path]').forEach(b=>b.dispatchEvent(new Event('change')));
      }));
      document.getElementById('clear').addEventListener('click',()=>{boxes.forEach(b=>b.checked=false);save();update()});
      function payload(){
        const seen=new Set(),selections=[];
        boxes.forEach(b=>{if(b.checked&&!seen.has(b.dataset.path)){seen.add(b.dataset.path);selections.push({path:b.dataset.path,groupId:b.dataset.group})}});
        return JSON.stringify({format:'photosweep-selections',version:1,scanId:scanId,root:body.dataset.root,manifest:body.dataset.manifest,createdAt:new Date().toISOString(),selections:selections},null,2);
      }
      const dlg=document.getElementById('done'),cmd='photosweep quarantine ~/Downloads/selections.json';
      exportBtn.addEventListener('click',()=>{
        const url=URL.createObjectURL(new Blob([payload()],{type:'application/json'}));
        const a=document.createElement('a');a.href=url;a.download='selections.json';document.body.appendChild(a);a.click();a.remove();
        setTimeout(()=>URL.revokeObjectURL(url),1000);
        document.getElementById('cmd').textContent=cmd;
        if(dlg.showModal)dlg.showModal();
      });
      function copy(text,btn){navigator.clipboard&&navigator.clipboard.writeText(text).then(()=>{const t=btn.textContent;btn.textContent='Copied';setTimeout(()=>btn.textContent=t,1200)})}
      document.getElementById('copy-cmd').addEventListener('click',e=>copy(cmd,e.target));
      document.getElementById('copy-json').addEventListener('click',e=>{copy(payload(),e.target);document.getElementById('cmd').textContent='pbpaste > selections.json\\nphotosweep quarantine selections.json'});
      document.getElementById('close').addEventListener('click',()=>dlg.close());
      restore();update();
    })();
    """
}

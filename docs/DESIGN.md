# PhotoSweep design notes

PhotoSweep is a folder-based duplicate finder with three properties that drive most of the design:

1. **Repeat scans are cheap.** Hashes and fingerprints are cached and reused only when it is safe.
2. **Memory is bounded.** Work is streamed through a fixed number of workers; files are hashed in
   chunks and images are decoded as small thumbnails.
3. **Cleanup never acts on stale results.** Every move is re-validated against the disk immediately
   before it happens, journaled, and reversible without ever overwriting a file.

```
Sources/PhotoSweepCore
  FileDiscovery      enumerate photos, lstat metadata (size, mtime ns, device/inode, link count)
  ContentHasher      chunked SHA-256 with before/after metadata checks
  VisualFingerprint  dHash on an orientation-corrected thumbnail
  ScanCache          versioned JSON cache, owned by an actor, flushed atomically
  WorkerPool         bounded TaskGroup ("at most N in flight")
  ExactMatcher       size → hash grouping, hard-link-aware savings
  SimilarityMatcher  representative-based grouping; BK-tree and linear indexes
  Scanner            the pipeline
  ReportGenerator    thumbnails, scan.json, self-contained index.html
  Cleanup, Journal   validation, quarantine, undo, crash reconciliation
```

## Scan pipeline

1. **Discover.** Enumerate supported files (`jpg/jpeg/png/heic/heif`), skipping hidden entries,
   symlinks, packages and `.photosweep-quarantine`. Record size, nanosecond mtime, device/inode.
2. **Plan.** Group paths by device/inode: hard links are one *file* with several *paths*, so each is
   hashed and decoded once. A file needs a SHA-256 only if another path has the same byte size.
   Every file needs a visual fingerprint unless `--exact-only` is set.
3. **Reuse the cache.** A cache entry is reused only if size, mtime and inode all match. A cached
   fingerprint is reused only if its `fingerprintVersion` equals the current algorithm version and
   the previous decode succeeded (so decode failures are retried every scan).
4. **Work.** Remaining jobs run through `forEachBounded` with `--workers` tasks in flight. Each job
   re-checks metadata before and after reading. If the file changed mid-read, the result is
   discarded and reported as an error, never cached.
5. **Group.** Exact groups come from SHA-256. Visual groups are built over *distinct content*: each
   exact group contributes only its suggested keeper, so similar groups don't repeat exact copies.
6. **Hash candidates.** Similar-group members without a hash (unique sizes) are hashed now, so
   cleanup can verify every file it might move.
7. **Report.** Write thumbnails (bounded workers), `scan.json` and `index.html`.

## Cache invalidation

The cache is one JSON file per scanned root (`~/Library/Caches/PhotoSweep/<sha256(root)>.json`, or
`--cache`). It has a format version (an incompatible file is ignored) and records the root it
belongs to.

| Change | Effect |
|---|---|
| Size, mtime or inode differs | Entry dropped; hash and fingerprint recomputed |
| File missing | Entry pruned on the next save |
| `fingerprintVersion` differs | Fingerprint recomputed; the hash is kept |
| Previous decode failed | Retried |
| `--verify` | Cache ignored for reading; everything recomputed and rewritten |

**Metadata is a shortcut, not proof.** A tool that rewrites bytes and restores the mtime, or a
same-size edit within the filesystem's timestamp resolution (APFS records nanoseconds), would be
missed. `--verify` exists for that case. Cleanup does not trust the cache at all (see below).

**Interruption.** Results are recorded through the `ScanCache` actor, which flushes to disk every
500 results or 2 seconds using atomic replacement (`Data.write(options: .atomic)`, i.e. write to a
temporary file and rename). The first Ctrl-C stops scheduling new work, lets in-flight files finish,
and saves; a hard kill loses at most the last flush interval. A test cancels a scan after 5 files
and checks the restart reuses exactly those 5.

## Bounded memory

- Hashing reads 1 MiB chunks into an incremental `SHA256`; file size doesn't matter.
- Fingerprints decode via `CGImageSourceCreateThumbnailAtIndex` with a 256 px maximum and
  `kCGImageSourceShouldCache = false`. ImageIO subsamples JPEG/HEIC during decode, so a full-size
  bitmap is never allocated.
- At most `--workers` files are open or decoded at once. One task per image would let thousands of
  decodes be in flight at once.
- What does grow with collection size is per-file metadata: the discovered file list, cache entries
  and the manifest, a few hundred bytes per file. `docs/benchmarks.md` measures peak RSS at
  several collection sizes.

## Visual matching and its limits

**dHash.** Decode an orientation-corrected thumbnail (`kCGImageSourceCreateThumbnailWithTransform`
applies EXIF orientation). Draw it into a 72 × 64 grayscale bitmap, box-average 8 × 8 blocks into a
9 × 8 grid, and set one bit per row-neighbor comparison (`left > right`), giving 64 bits. Distance is
`popcount(a ^ b)`. Images with almost no gradient (mean neighbor difference < 1.5 gray levels) are
marked *low detail* and excluded from visual matching: they hash to mostly-zero fingerprints that
would "match" every other flat image.

**No transitive chains.** Similarity isn't transitive: A ~ B and B ~ C doesn't imply A ~ C.
Merging connected components would let a chain of small edits pull unrelated photos into one group.
Instead, items are visited in descending resolution order. Each unassigned item becomes a
*representative*, and only unassigned items within the threshold **of that representative** join
its group. A test builds an explicit A–B–C chain and checks that A and C are not grouped.

**Index.** `LinearIndex` is the reference implementation. `BKTreeIndex` (a Burkhard–Keller tree:
child edges labelled by Hamming distance, pruned by the triangle inequality) is the default. A test
compares neighbor sets for 200 queries at four radii on 3,000 clustered fingerprints, and the
resulting groups, against the linear scan.

**Known blind spots:** true 90° rotations and crops (both measured in [evaluation.md](evaluation.md)),
plus mirroring and heavy edits, which dHash cannot be expected to handle either. Different photos of the same subject were not grouped at the default
threshold, which is the intended behavior. Visual groups are *review candidates* only: nothing in
them is pre-selected, and their keep suggestion (highest resolution, then preferred folder, then a
non-copy name, then larger file) is advisory.

## Cleanup and recovery

The report is a static page; it can't move files. It exports `selections.json`, which contains the
scan ID, root, manifest path and the selected `(path, groupId)` pairs. `photosweep quarantine` then
validates **every** selection against the manifest and the current disk:

1. The selections' scan ID matches `scan.json`, and the path is a member of the named group.
2. The path is strictly inside the scanned root after resolving symlinks in its parent folders,
   and is not already in quarantine.
3. It is still a regular file with the recorded size **and SHA-256** (recomputed, never from cache).
4. Every group it belongs to keeps at least one *unselected* member that also still matches its
   recorded hash. If a selection would empty a group, that file is kept and the rejection says why.
5. It is on the same volume as the root, and the quarantine destination does not exist.

The plan (moves plus per-file rejection reasons) is printed, and nothing happens until the user
confirms (`--yes` skips the prompt, `--dry-run` stops after the plan).

**Moves** go to `<root>/.photosweep-quarantine/<operation-id>/<relative path>`. Keeping them on the
same volume means a move is a `rename`, which is atomic. They use `renamex_np(..., RENAME_EXCL)`,
which fails instead of replacing an existing destination, so there is no check-then-act race.
Each file is verified once more just before its move.

**Journal.** `~/Library/Application Support/PhotoSweep/operations/<id>.json` (or
`$PHOTOSWEEP_STATE_DIR`). For each file: append a `pending` entry and save atomically, then move,
then mark `moved` (or `not-moved` with the reason) and save. Undo uses `restoring` → `restored` the
same way. If the process dies between steps, `reconcile()` uses the filesystem as the source of truth:

| Journal says | Original exists | Quarantine copy exists | Resolved to |
|---|---|---|---|
| pending | no | yes | moved |
| pending | yes | no | not-moved |
| restoring | yes | no | restored |
| restoring | no | yes | moved |
| either | both / neither | | conflict (left for a human) |

**Undo** reconciles first, then restores each `moved` entry with the same exclusive rename. If a
file has appeared at the original path since the move, that entry is skipped, reported, and left in
quarantine; nothing is overwritten. Undo can be re-run after the user resolves the conflict. When
nothing remains, empty quarantine folders are removed.

## Deliberate non-goals (v1)

The Apple Photos library, RAW/video/Live Photos, scene-level similarity, a native UI, distributed
processing, and SQLite (the JSON cache is ~340 bytes per file; revisit if measurements show
load/save time matters).

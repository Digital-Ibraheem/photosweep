import Foundation
import PhotoSweepCore

/// Measures how well visual grouping recovers known near-duplicates in a labeled fixture set.
///
/// Mirrors the scanner: byte-identical copies are excluded (they are found by hashing),
/// low-detail and undecodable images are excluded, and groups are built with
/// `SimilarityMatcher` around representatives.
public struct SimilarityEvaluation {
    public struct Unit {
        public var label: FixtureLabels.File
        public var item: VisualItem
    }

    public struct ThresholdResult: Codable, Sendable {
        public var threshold: Int
        public var groups: Int
        /// Pairs placed in the same group.
        public var proposedPairs: Int
        /// Proposed pairs that derive from the same source photo.
        public var correctPairs: Int
        /// Known same-source pairs.
        public var knownPairs: Int
        /// Incorrect pairs that are different photos of the same subject (e.g. burst shots).
        public var sameSubjectPairs: Int
        /// Incorrect pairs of unrelated photos.
        public var unrelatedPairs: Int
        /// Per variant: number of sources where the variant was grouped with its original.
        public var variantRecovered: [String: Int]
        public var precision: Double { proposedPairs == 0 ? 1 : Double(correctPairs) / Double(proposedPairs) }
        public var recall: Double { knownPairs == 0 ? 0 : Double(correctPairs) / Double(knownPairs) }
    }

    public var units: [Unit]
    public var excluded: [(path: String, reason: String)]

    /// Fingerprints every labeled file under `root`.
    public init(root: URL, labels: FixtureLabels) {
        var units: [Unit] = []
        var excluded: [(String, String)] = []
        for label in labels.files {
            let path = root.appendingPathComponent(label.path).path
            if label.variant == .exactCopy { excluded.append((label.path, "byte-identical copy (exact match)")); continue }
            // Truncated JPEGs often decode partially (grey lower half). They are matched by hash, not visually.
            if label.variant == .corrupt { excluded.append((label.path, "damaged file (exact match only)")); continue }
            guard let fp = VisualFingerprint.compute(path: path) else { excluded.append((label.path, "undecodable")); continue }
            if fp.lowDetail { excluded.append((label.path, "low detail")); continue }
            let dims = ImageInspector.dimensions(path: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            units.append(Unit(label: label, item: VisualItem(
                path: path, fingerprint: fp, pixelCount: (dims?.width ?? 0) * (dims?.height ?? 0), size: size)))
        }
        self.units = units
        self.excluded = excluded
    }

    public var variantCounts: [String: Int] {
        Dictionary(grouping: units.filter { $0.label.variant != .original }, by: { $0.label.variant.rawValue }).mapValues(\.count)
    }

    /// Hamming distance from each variant to its original.
    public func distancesToOriginal() -> [Variant: [Int]] {
        var originals: [String: VisualFingerprint] = [:]
        for u in units where u.label.variant == .original { originals[u.label.source] = u.item.fingerprint }
        var result: [Variant: [Int]] = [:]
        for u in units where u.label.variant != .original {
            if let o = originals[u.label.source] { result[u.label.variant, default: []].append(u.item.fingerprint.distance(to: o)) }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Distances between different photos of the same subject, and the smallest distance between unrelated photos.
    public func originalDistances() -> (sameSubject: [Int], unrelatedMin: Int) {
        let originals = units.filter { $0.label.variant == .original }
        var same: [Int] = [], unrelatedMin = 64
        for i in originals.indices {
            for j in originals.indices where j > i {
                let a = originals[i], b = originals[j]
                let d = a.item.fingerprint.distance(to: b.item.fingerprint)
                if let s = a.label.subject, s == b.label.subject { same.append(d) } else { unrelatedMin = min(unrelatedMin, d) }
            }
        }
        return (same.sorted(), unrelatedMin)
    }

    public func evaluate(threshold: Int) -> ThresholdResult {
        let groups = SimilarityMatcher.group(units.map(\.item), threshold: threshold)
        var proposed = 0, correct = 0, sameSubject = 0, unrelated = 0
        var recovered: [String: Int] = [:]
        for group in groups {
            let members = group.map { units[$0.item].label }
            for i in members.indices {
                for j in members.indices where j > i {
                    let a = members[i], b = members[j]
                    proposed += 1
                    if a.source == b.source {
                        correct += 1
                        if a.variant == .original { recovered[b.variant.rawValue, default: 0] += 1 }
                        if b.variant == .original { recovered[a.variant.rawValue, default: 0] += 1 }
                    } else if let s = a.subject, s == b.subject {
                        sameSubject += 1
                    } else {
                        unrelated += 1
                    }
                }
            }
        }
        let bySource = Dictionary(grouping: units, by: \.label.source).mapValues(\.count)
        let known = bySource.values.reduce(0) { $0 + $1 * ($1 - 1) / 2 }
        return ThresholdResult(
            threshold: threshold, groups: groups.count, proposedPairs: proposed, correctPairs: correct,
            knownPairs: known, sameSubjectPairs: sameSubject, unrelatedPairs: unrelated, variantRecovered: recovered)
    }

    /// A Markdown report covering several thresholds.
    public func markdownReport(thresholds: [Int]) -> String {
        let results = thresholds.map(evaluate)
        let originals = units.filter { $0.label.variant == .original }.count
        let families = Set(units.filter { $0.label.variant != .original }.map(\.label.source)).count
        var md = """
        Evaluated \(units.count) decodable images: \(originals) originals, of which \(families) have edited variants.
        Excluded \(excluded.count) files: \(Dictionary(grouping: excluded, by: \.reason).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")).

        A *pair* is two images placed in the same visual group. A pair is **correct** when both images derive
        from the same source photo. **Precision** = correct pairs ÷ proposed pairs. **Recall** = correct pairs ÷
        all same-source pairs (including hard cases such as rotation and cropping).

        | Threshold | Groups | Proposed pairs | Correct | Precision | Recall | Wrong: same subject | Wrong: unrelated |
        |---:|---:|---:|---:|---:|---:|---:|---:|

        """
        for r in results {
            md += "| \(r.threshold) | \(r.groups) | \(r.proposedPairs) | \(r.correctPairs) | \(pct(r.precision)) | \(pct(r.recall)) | \(r.sameSubjectPairs) | \(r.unrelatedPairs) |\n"
        }
        let counts = variantCounts
        md += "\n**Variants grouped with their original** (out of \(families) sources)\n\n| Variant | " + thresholds.map { "T=\($0)" }.joined(separator: " | ") + " |\n|---|" + thresholds.map { _ in "---:" }.joined(separator: "|") + "|\n"
        for v in Variant.allCases where v.isDuplicateOfSource && counts[v.rawValue] != nil {
            md += "| \(v.rawValue) | " + results.map { "\($0.variantRecovered[v.rawValue] ?? 0)/\(counts[v.rawValue]!)" }.joined(separator: " | ") + " |\n"
        }
        md += "\n**Hamming distance from each variant to its original** (64-bit dHash)\n\n| Variant | Min | Median | Max |\n|---|---:|---:|---:|\n"
        for (v, ds) in distancesToOriginal().sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            md += "| \(v.rawValue) | \(ds.first!) | \(ds[ds.count / 2]) | \(ds.last!) |\n"
        }
        let od = originalDistances()
        md += "\nDifferent photos of the same subject: distances \(od.sameSubject.map(String.init).joined(separator: ", ")). "
        md += "Closest pair of unrelated originals: \(od.unrelatedMin).\n"
        return md
    }

    func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}

import Foundation

/// One unit of distinct content considered for visual matching.
public struct VisualItem: Sendable, Hashable {
    public var path: String
    public var fingerprint: VisualFingerprint
    public var pixelCount: Int
    public var size: Int64

    public init(path: String, fingerprint: VisualFingerprint, pixelCount: Int, size: Int64) {
        self.path = path
        self.fingerprint = fingerprint
        self.pixelCount = pixelCount
        self.size = size
    }
}

/// Finds items within a Hamming distance of a query fingerprint.
public protocol NeighborIndex {
    init(_ items: [VisualItem])
    /// Indices of items within `radius` of `query` (including exact matches), in any order.
    func neighbors(of query: VisualFingerprint, within radius: Int) -> [Int]
}

/// Compares the query against every item. O(n) per query; the reference implementation.
public struct LinearIndex: NeighborIndex {
    let bits: [UInt64]
    public init(_ items: [VisualItem]) { bits = items.map(\.fingerprint.bits) }
    public func neighbors(of query: VisualFingerprint, within radius: Int) -> [Int] {
        bits.indices.filter { (bits[$0] ^ query.bits).nonzeroBitCount <= radius }
    }
}

/// Burkhard–Keller tree over Hamming distance. Each child edge is labelled with its distance to
/// the parent; by the triangle inequality a search for radius r only visits edges in
/// [d - r, d + r], which prunes most of the tree for small radii.
public struct BKTreeIndex: NeighborIndex {
    struct Node {
        var bits: UInt64
        var items: [Int]                 // all item indices sharing this exact fingerprint
        var children: [Int: Int] = [:]   // distance -> node index
    }
    var nodes: [Node] = []

    public init(_ items: [VisualItem]) {
        for (i, item) in items.enumerated() { insert(item.fingerprint.bits, index: i) }
    }

    mutating func insert(_ bits: UInt64, index: Int) {
        guard !nodes.isEmpty else { nodes.append(Node(bits: bits, items: [index])); return }
        var current = 0
        while true {
            let d = (nodes[current].bits ^ bits).nonzeroBitCount
            if d == 0 { nodes[current].items.append(index); return }
            if let child = nodes[current].children[d] {
                current = child
            } else {
                nodes.append(Node(bits: bits, items: [index]))
                nodes[current].children[d] = nodes.count - 1
                return
            }
        }
    }

    public func neighbors(of query: VisualFingerprint, within radius: Int) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var result: [Int] = []
        var stack = [0]
        while let n = stack.popLast() {
            let node = nodes[n]
            let d = (node.bits ^ query.bits).nonzeroBitCount
            if d <= radius { result.append(contentsOf: node.items) }
            for (edge, child) in node.children where edge >= d - radius && edge <= d + radius {
                stack.append(child)
            }
        }
        return result
    }
}

/// Groups visually similar items around representatives.
///
/// Similarity is not transitive: A ~ B and B ~ C does not imply A ~ C. Instead of merging
/// connected chains, each group has a representative and every member must be within the
/// threshold of that representative. Items are visited in descending resolution order, so the
/// representative is usually the best-quality copy; an item joins the first group whose
/// representative it matches.
public enum SimilarityMatcher {
    public static let defaultThreshold = 10

    public static func group<Index: NeighborIndex>(
        _ items: [VisualItem], threshold: Int, index: Index.Type
    ) -> [[(item: Int, distance: Int)]] {
        let order = items.indices.sorted { a, b in
            let x = items[a], y = items[b]
            if x.pixelCount != y.pixelCount { return x.pixelCount > y.pixelCount }
            if x.size != y.size { return x.size > y.size }
            return x.path < y.path
        }
        let idx = Index(items)
        var assigned = [Bool](repeating: false, count: items.count)
        var groups: [[(item: Int, distance: Int)]] = []
        for rep in order where !assigned[rep] {
            let fp = items[rep].fingerprint
            let members = idx.neighbors(of: fp, within: threshold)
                .filter { $0 != rep && !assigned[$0] }
                .map { (item: $0, distance: items[$0].fingerprint.distance(to: fp)) }
                .sorted { ($0.distance, items[$0.item].path) < ($1.distance, items[$1.item].path) }
            guard !members.isEmpty else { continue }
            assigned[rep] = true
            for m in members { assigned[m.item] = true }
            groups.append([(item: rep, distance: 0)] + members)
        }
        return groups
    }

    public static func group(_ items: [VisualItem], threshold: Int) -> [[(item: Int, distance: Int)]] {
        group(items, threshold: threshold, index: BKTreeIndex.self)
    }
}

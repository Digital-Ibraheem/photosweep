import Foundation

/// Runs `body` over `items` with at most `workers` items in flight, delivering results as they finish.
///
/// This deliberately avoids one task per image: only `workers` child tasks exist at any time, so the
/// number of open files and decoded thumbnails in memory is bounded regardless of collection size.
public func forEachBounded<Item: Sendable, Result: Sendable>(
    _ items: [Item],
    workers: Int,
    cancellation: CancellationFlag? = nil,
    body: @escaping @Sendable (Item) -> Result,
    onResult: (Result) async -> Void
) async {
    let limit = max(1, workers)
    await withTaskGroup(of: Result.self) { group in
        var next = 0
        func startNext() -> Bool {
            guard next < items.count, cancellation?.isCancelled != true else { return false }
            let item = items[next]
            next += 1
            group.addTask { autoreleasepool { body(item) } }
            return true
        }
        for _ in 0..<limit where !startNext() { break }
        while let result = await group.next() {
            await onResult(result)
            _ = startNext()
        }
    }
}

/// A thread-safe flag used to stop scheduling new work (for example on Ctrl-C).
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

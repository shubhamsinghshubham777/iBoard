/// Fixed-capacity ring buffer of durations (nanoseconds) with percentile queries.
/// Stores numbers only; never any typed text.
public struct DurationRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [UInt64]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [UInt64](repeating: 0, count: capacity)
    }

    /// Allocation-free once constructed.
    public mutating func record(_ nanoseconds: UInt64) {
        storage[head] = nanoseconds
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    public mutating func removeAll() { head = 0; count = 0 }

    /// Recorded values, oldest first.
    public var values: [UInt64] {
        guard count == capacity else { return Array(storage[0..<count]) }
        return Array(storage[head...] + storage[..<head])
    }

    /// Nearest-rank percentile (p in 0...100); nil when empty.
    public func percentile(_ p: Double) -> UInt64? {
        guard count > 0 else { return nil }
        let sorted = storage[0..<count].sorted()
        let clamped = min(max(p, 0), 100)
        let rank = Int((clamped / 100 * Double(count)).rounded(.up))
        return sorted[min(max(rank, 1), count) - 1]
    }

    public var p50: UInt64? { percentile(50) }
    public var p95: UInt64? { percentile(95) }
}

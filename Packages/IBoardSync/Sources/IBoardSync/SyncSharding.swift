import Foundation

/// Splits a state into pieces that each stay below CloudKit's ~1 MB record limit. Pieces are disjoint by key, so
/// merging them reproduces the original state. Deterministic for a given state.
public enum SyncSharding {
    /// Plaintext budget per shard (record limit is 1 MB; leaves room for GCM overhead and CloudKit metadata).
    public static let defaultMaxShardBytes = 700_000

    public static func name(device: String, index: Int) -> String { "shard-\(device)-\(index)" }

    public static func index(of recordName: String, device: String) -> Int? {
        let prefix = "shard-\(device)-"
        guard recordName.hasPrefix(prefix) else { return nil }
        return Int(recordName.dropFirst(prefix.count))
    }

    /// Rough JSON size of one counter key with its slots.
    static func cost(key: String, slots: [String: CounterSlot]) -> Int {
        key.utf8.count + 16 + slots.reduce(0) { $0 + $1.key.utf8.count + 90 }
    }

    /// Always returns at least one piece. A single key larger than the budget (impossible within validation limits)
    /// still gets its own piece.
    public static func split(_ state: SyncState, maxBytes: Int = defaultMaxShardBytes) throws -> [SyncState] {
        guard maxBytes > 0 else { return [state] }
        var pieces: [SyncState] = []
        var counters: [String: [String: CounterSlot]] = [:]
        var floors: [String: SyncStamp] = [:]
        var flags: [String: LWWFlag] = [:]
        var size = 0
        func flush() {
            guard !counters.isEmpty || !floors.isEmpty || !flags.isEmpty else { return }
            pieces.append(SyncState(schemaVersion: state.schemaVersion, counters: counters, forgetFloors: floors, neverCorrect: flags))
            counters = [:]; floors = [:]; flags = [:]; size = 0
        }
        func room(_ n: Int) { if size > 0, size + n > maxBytes { flush() }; size += n }
        for k in state.counters.keys.sorted() {
            let slots = state.counters[k]!
            room(cost(key: k, slots: slots)); counters[k] = slots
        }
        for k in state.forgetFloors.keys.sorted() { room(k.utf8.count + 80); floors[k] = state.forgetFloors[k] }
        for k in state.neverCorrect.keys.sorted() { room(k.utf8.count + 90); flags[k] = state.neverCorrect[k] }
        flush()
        return pieces.isEmpty ? [state] : pieces
    }
}

import Foundation

// Sync merge model v1 (M12-01). Pure values; no CloudKit, no engine dependency. See docs/SYNC.md.
//
// SyncState is a state-based CRDT: `merged(with:)` is commutative, associative and idempotent, so replicas converge
// regardless of delivery order or duplication.

/// Total order for conflict resolution: wall-clock milliseconds, then device id. Local mutators keep each device's
/// own stamps strictly increasing, so the order is total across devices.
public struct SyncStamp: Sendable, Hashable, Codable, Comparable {
    public var time: UInt64
    public var device: String
    public init(time: UInt64, device: String) { self.time = time; self.device = device }
    public static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        a.time != b.time ? a.time < b.time : a.device < b.device
    }
}

/// One device's contribution to a counter. Only the owning device writes its slot. Within a forget epoch the value
/// only grows; the stamp makes later writes win on merge (and lets a forget reset it).
public struct CounterSlot: Sendable, Hashable, Codable {
    public var value: UInt64
    public var stamp: SyncStamp
    public init(value: UInt64, stamp: SyncStamp) { self.value = value; self.stamp = stamp }

    /// Deterministic max by (stamp, value).
    static func merge(_ a: CounterSlot, _ b: CounterSlot) -> CounterSlot {
        if a.stamp != b.stamp { return a.stamp > b.stamp ? a : b }
        return a.value >= b.value ? a : b
    }
}

/// Last-writer-wins presence flag. `present == false` is a tombstone and is kept so a stale add cannot resurrect it.
public struct LWWFlag: Sendable, Hashable, Codable {
    public var present: Bool
    public var stamp: SyncStamp
    public init(present: Bool, stamp: SyncStamp) { self.present = present; self.stamp = stamp }

    /// Higher stamp wins; an exact stamp tie (not produced by honest devices) resolves to the tombstone.
    static func merge(_ a: LWWFlag, _ b: LWWFlag) -> LWWFlag {
        if a.stamp != b.stamp { return a.stamp > b.stamp ? a : b }
        return a.present ? b : a
    }
}

public enum SyncValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case keyTooLong
    case tooManyKeys
    case tooManyDevices
}

public struct SyncState: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1
    public static let maxKeyBytes = 128
    public static let maxKeys = 200_000
    public static let maxDevicesPerKey = 16

    public var schemaVersion: Int
    /// item key -> device id -> slot. Item keys are opaque (callers may hash them; see docs/SYNC.md).
    public private(set) var counters: [String: [String: CounterSlot]]
    /// item key -> forget floor. Slots with `stamp <= floor` are dead. Max-merged (grow-only), so a forget can
    /// never be undone and later learning is unaffected.
    public private(set) var forgetFloors: [String: SyncStamp]
    /// "Never correct" set as LWW flags with tombstones.
    public private(set) var neverCorrect: [String: LWWFlag]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        counters = [:]; forgetFloors = [:]; neverCorrect = [:]
    }

    // MARK: Reads

    /// Sum over devices of live slots (slots newer than the forget floor).
    public func count(_ key: String) -> UInt64 {
        guard let slots = counters[key] else { return 0 }
        let floor = forgetFloors[key]
        var total: UInt64 = 0
        for s in slots.values where floor == nil || s.stamp > floor! {
            let (r, o) = total.addingReportingOverflow(s.value)
            total = o ? UInt64.max : r
        }
        return total
    }

    public func isNeverCorrect(_ key: String) -> Bool { neverCorrect[key]?.present ?? false }
    public func isForgotten(_ key: String) -> Bool { forgetFloors[key] != nil && count(key) == 0 }
    public var liveKeys: [String] { counters.keys.filter { count($0) > 0 }.sorted() }

    // MARK: Local mutations (called only for the local device; `now` is wall-clock ms)

    /// Next stamp for `device` that is strictly after anything it has stamped for `key` and after the forget floor.
    private func nextStamp(key: String, device: String, now: UInt64) -> SyncStamp {
        var t = now
        if let s = counters[key]?[device] { t = max(t, s.stamp.time + 1) }
        if let f = forgetFloors[key] { t = max(t, f.time + 1) }
        return SyncStamp(time: t, device: device)
    }

    public mutating func increment(_ key: String, by n: UInt64 = 1, device: String, now: UInt64) {
        let stamp = nextStamp(key: key, device: device, now: now)
        let floor = forgetFloors[key]
        let prior = counters[key]?[device]
        let base: UInt64 = (prior != nil && (floor == nil || prior!.stamp > floor!)) ? prior!.value : 0
        let (v, o) = base.addingReportingOverflow(n)
        counters[key, default: [:]][device] = CounterSlot(value: o ? UInt64.max : v, stamp: stamp)
    }

    /// Forget a key everywhere: raises the floor above every slot this replica has seen.
    public mutating func forget(_ key: String, device: String, now: UInt64) {
        var t = now
        if let f = forgetFloors[key] { t = max(t, f.time + 1) }
        for s in counters[key]?.values ?? [:].values { t = max(t, s.stamp.time + 1) }
        let floor = SyncStamp(time: t, device: device)
        forgetFloors[key] = max(forgetFloors[key] ?? floor, floor)
        // Dead slots carry no information any more; dropping them is safe because the floor masks them anyway.
        counters[key] = counters[key]?.filter { $0.value.stamp > floor }
        if counters[key]?.isEmpty == true { counters[key] = nil }
    }

    public mutating func setNeverCorrect(_ key: String, present: Bool, device: String, now: UInt64) {
        var t = now
        if let f = neverCorrect[key] { t = max(t, f.stamp.time + 1) }
        neverCorrect[key] = LWWFlag(present: present, stamp: SyncStamp(time: t, device: device))
    }

    // MARK: Merge

    public func merged(with other: SyncState) -> SyncState {
        var r = SyncState()
        r.schemaVersion = max(schemaVersion, other.schemaVersion)
        r.forgetFloors = forgetFloors.merging(other.forgetFloors) { max($0, $1) }
        r.neverCorrect = neverCorrect.merging(other.neverCorrect, uniquingKeysWith: LWWFlag.merge)
        var c = counters
        for (k, slots) in other.counters {
            c[k] = (c[k] ?? [:]).merging(slots, uniquingKeysWith: CounterSlot.merge)
        }
        // Canonicalise: drop slots masked by the merged floor so equal logical states are equal values.
        for (k, slots) in c {
            if let f = r.forgetFloors[k] {
                let live = slots.filter { $0.value.stamp > f }
                c[k] = live.isEmpty ? nil : live
            }
        }
        r.counters = c
        return r
    }

    public static func merge(_ states: [SyncState]) -> SyncState {
        states.reduce(SyncState()) { $0.merged(with: $1) }
    }

    /// Drops tombstones (absent LWW flags) older than `cutoffMs`. Only safe once every device has synced past the
    /// cutoff (a device offline longer than that must full-resync instead of merging); see docs/SYNC.md.
    public func compacted(tombstonesOlderThan cutoffMs: UInt64) -> SyncState {
        var r = self
        r.neverCorrect = neverCorrect.filter { $0.value.present || $0.value.stamp.time >= cutoffMs }
        return r
    }

    // MARK: Validation (for data received from iCloud)

    public func validate() throws {
        guard schemaVersion >= 1, schemaVersion <= Self.currentSchemaVersion else {
            throw SyncValidationError.unsupportedVersion(schemaVersion)
        }
        let allKeys = Array(counters.keys) + Array(forgetFloors.keys) + Array(neverCorrect.keys)
        guard allKeys.count <= Self.maxKeys * 3 else { throw SyncValidationError.tooManyKeys }
        for k in allKeys where k.utf8.count > Self.maxKeyBytes || k.isEmpty { throw SyncValidationError.keyTooLong }
        for slots in counters.values where slots.count > Self.maxDevicesPerKey { throw SyncValidationError.tooManyDevices }
    }

    public static func decode(_ data: Data) throws -> SyncState {
        let s = try JSONDecoder().decode(SyncState.self, from: data)
        try s.validate()
        return s
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

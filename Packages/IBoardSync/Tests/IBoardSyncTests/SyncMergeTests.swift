import Foundation
import Testing
@testable import IBoardSync

/// Deterministic generator so failures reproduce.
struct LCG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
}

private let devices = ["A", "B", "C"]
private let keys = ["k0", "k1", "k2", "k3"]

private enum Op: Sendable {
    case inc(String, UInt64, String, UInt64)
    case forget(String, String, UInt64)
    case never(String, Bool, String, UInt64)

    func apply(to s: inout SyncState) {
        switch self {
        case let .inc(k, n, d, t): s.increment(k, by: n, device: d, now: t)
        case let .forget(k, d, t): s.forget(k, device: d, now: t)
        case let .never(k, p, d, t): s.setNeverCorrect(k, present: p, device: d, now: t)
        }
    }
}

/// Each device performs a random op sequence on its own replica, merging in other replicas at random points.
private func randomReplicas(seed: UInt64, opsPerDevice: Int = 25) -> [SyncState] {
    var rng = LCG(s: seed)
    var reps = Dictionary(uniqueKeysWithValues: devices.map { ($0, SyncState()) })
    var clock: [String: UInt64] = [:]
    for _ in 0..<(opsPerDevice * devices.count) {
        let d = devices.randomElement(using: &rng)!
        clock[d, default: 1000] += UInt64.random(in: 0...5, using: &rng)   // skewed, sometimes stalled clocks
        let t = clock[d]!
        let k = keys.randomElement(using: &rng)!
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...5: Op.inc(k, UInt64.random(in: 1...3, using: &rng), d, t).apply(to: &reps[d]!)
        case 6: Op.forget(k, d, t).apply(to: &reps[d]!)
        case 7, 8: Op.never(k, Bool.random(using: &rng), d, t).apply(to: &reps[d]!)
        default:
            let other = devices.randomElement(using: &rng)!
            reps[d] = reps[d]!.merged(with: reps[other]!)
        }
    }
    return devices.map { reps[$0]! }
}

@Test func mergeIsCommutativeAssociativeIdempotent() {
    for seed in 1...200 {
        let r = randomReplicas(seed: UInt64(seed))
        let (a, b, c) = (r[0], r[1], r[2])
        #expect(a.merged(with: b) == b.merged(with: a), "commutative seed \(seed)")
        #expect(a.merged(with: b).merged(with: c) == a.merged(with: b.merged(with: c)), "associative seed \(seed)")
        #expect(a.merged(with: a) == a.merged(with: a).merged(with: a))
        let ab = a.merged(with: b)
        #expect(ab.merged(with: a) == ab && ab.merged(with: b) == ab, "idempotent/absorbing seed \(seed)")
    }
}

@Test func anyDeliveryOrderConverges() {
    for seed in 1...100 {
        let r = randomReplicas(seed: UInt64(seed) &+ 10_000)
        let reference = SyncState.merge(r)
        var rng = LCG(s: UInt64(seed))
        for _ in 0..<6 {
            var order = r + r             // duplicates too
            order.shuffle(using: &rng)
            #expect(SyncState.merge(order) == reference, "seed \(seed)")
        }
        // Observable reads agree as well.
        for k in keys { #expect(SyncState.merge(r.reversed()).count(k) == reference.count(k)) }
    }
}

@Test func countersMergeBySumAcrossDevices() {
    var a = SyncState(), b = SyncState()
    a.increment("hello", by: 3, device: "A", now: 10)
    a.increment("hello", device: "A", now: 11)
    b.increment("hello", by: 5, device: "B", now: 12)
    #expect(a.merged(with: b).count("hello") == 9)
    #expect(a.merged(with: b).merged(with: a).count("hello") == 9)   // no double counting on re-delivery
}

@Test func forgetBeatsOlderCountersButNotNewerLearning() {
    var a = SyncState(), b = SyncState()
    a.increment("w", by: 4, device: "A", now: 100)
    b.increment("w", by: 2, device: "B", now: 101)
    let synced = a.merged(with: b)
    var a2 = synced
    a2.forget("w", device: "A", now: 200)
    #expect(a2.count("w") == 0)
    // B, offline, learns again before seeing the forget, at a time before the forget: forgotten.
    var b2 = synced
    b2.increment("w", device: "B", now: 150)
    #expect(a2.merged(with: b2).count("w") == 0)
    // After the forget propagates, new learning counts from zero.
    var b3 = a2
    b3.increment("w", by: 7, device: "B", now: 300)
    #expect(b3.count("w") == 7)
    #expect(b3.merged(with: a2).merged(with: b2).count("w") == 7)
    // A stale replica cannot resurrect the forgotten word.
    #expect(a2.merged(with: synced).count("w") == 0)
}

@Test func forgetWithSkewedClockStillBeatsSeenData() {
    var a = SyncState()
    a.increment("w", by: 4, device: "A", now: 5_000)
    a.forget("w", device: "B", now: 10)          // B's clock is far behind; floor still exceeds the seen slot
    #expect(a.count("w") == 0)
}

@Test func neverCorrectIsLastWriterWinsWithTombstones() {
    var a = SyncState(), b = SyncState()
    a.setNeverCorrect("teh", present: true, device: "A", now: 10)
    b.setNeverCorrect("teh", present: false, device: "B", now: 20)
    #expect(!a.merged(with: b).isNeverCorrect("teh"))
    #expect(!b.merged(with: a).isNeverCorrect("teh"))
    var c = a
    c.setNeverCorrect("teh", present: true, device: "A", now: 30)
    #expect(c.merged(with: b).isNeverCorrect("teh"))
    // Tombstone is retained until compacted, then dropped.
    #expect(a.merged(with: b).neverCorrect["teh"] != nil)
    #expect(a.merged(with: b).compacted(tombstonesOlderThan: 100).neverCorrect["teh"] == nil)
    #expect(c.compacted(tombstonesOlderThan: 100).isNeverCorrect("teh"))
}

@Test func localStampsAreStrictlyMonotonicUnderStalledClock() {
    var s = SyncState()
    for _ in 0..<5 { s.increment("k", device: "A", now: 50) }
    #expect(s.count("k") == 5)
    #expect(s.counters["k"]!["A"]!.stamp.time == 54)
}

@Test func codableRoundTripAndValidation() throws {
    var s = SyncState()
    s.increment("a", by: 2, device: "A", now: 1)
    s.setNeverCorrect("b", present: true, device: "B", now: 2)
    s.forget("c", device: "A", now: 3)
    let data = try s.encoded()
    #expect(try SyncState.decode(data) == s)
    #expect(try s.encoded() == data)

    var future = s; future.schemaVersion = 2
    #expect(throws: SyncValidationError.unsupportedVersion(2)) { try future.validate() }
    var long = SyncState()
    long.increment(String(repeating: "x", count: 200), device: "A", now: 1)
    #expect(throws: SyncValidationError.keyTooLong) { try long.validate() }
    var many = SyncState()
    for d in 0..<17 { many.increment("k", device: "D\(d)", now: 1) }
    #expect(throws: SyncValidationError.tooManyDevices) { try many.validate() }
}

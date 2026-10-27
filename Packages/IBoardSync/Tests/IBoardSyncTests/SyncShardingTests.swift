import Testing
import Foundation
@testable import IBoardSync

@Suite struct SyncShardingTests {
    func big(_ n: Int) -> SyncState {
        var s = SyncState()
        for i in 0..<n { s.increment("u:word\(i)", by: UInt64(i + 1), device: "A", now: 5000) }
        s.forget("u:word3", device: "A", now: 6000)
        s.setNeverCorrect("nc1", present: true, device: "A", now: 5000)
        return s
    }

    @Test func splitIsDisjointAndMergesBack() throws {
        let s = big(500)
        let parts = try SyncSharding.split(s, maxBytes: 8_000)
        #expect(parts.count > 3)
        for p in parts { #expect(try p.encoded().count < 8_000 * 3) }
        #expect(SyncState.merge(parts) == s)
        #expect(try SyncSharding.split(s, maxBytes: 8_000) == parts)
    }

    @Test func smallStateIsOneShard() throws {
        #expect(try SyncSharding.split(big(5)).count == 1)
        #expect(try SyncSharding.split(SyncState()).count == 1)
    }

    @Test func engineUploadsMultipleShardsAndRoundTrips() async throws {
        let store = InMemorySyncStore()
        let key = SyncCrypto.generateKeyData()
        let a = SyncEngine(store: store, crypto: SyncCrypto(keyData: key), deviceID: "A", maxShardBytes: 8_000)
        let b = SyncEngine(store: store, crypto: SyncCrypto(keyData: key), deviceID: "B")
        await a.setEnabled(true); await b.setEnabled(true)
        let s = big(500)
        _ = await a.sync(local: s)
        let shards = await store.rawShards()
        #expect(shards.count > 3)
        #expect(shards.allSatisfy { $0.payload.count < 1_000_000 })
        let out = await b.sync(local: SyncState())
        #expect(out.skippedShards == 0)
        #expect(out.merged == s)
    }

    @Test func shrinkingBlanksLeftoverShards() async throws {
        let store = InMemorySyncStore()
        let key = SyncCrypto.generateKeyData()
        let a = SyncEngine(store: store, crypto: SyncCrypto(keyData: key), deviceID: "A", maxShardBytes: 8_000)
        await a.setEnabled(true)
        _ = await a.sync(local: big(500))
        let many = await store.rawShards().count
        // Same device with a large budget: shard 0 holds everything, leftovers are blanked, result is unchanged.
        let a2 = SyncEngine(store: store, crypto: SyncCrypto(keyData: key), deviceID: "A")
        await a2.setEnabled(true)
        let out = await a2.sync(local: SyncState())
        #expect(await store.rawShards().count == many)
        #expect(out.merged == big(500))
        let out2 = await a2.sync(local: out.merged)
        #expect(out2.merged == out.merged)
    }

    @Test func tombstoneCompaction() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var s = SyncState()
        s.setNeverCorrect("old", present: false, device: "A", now: 1_000)
        s.setNeverCorrect("fresh", present: false, device: "A", now: UInt64(now.timeIntervalSince1970 * 1000) - 1000)
        s.setNeverCorrect("kept", present: true, device: "A", now: 1_000)
        let store = InMemorySyncStore()
        let e = SyncEngine(store: store, crypto: SyncCrypto(keyData: SyncCrypto.generateKeyData()), deviceID: "A",
                           now: { now }, tombstoneRetentionDays: 30)
        await e.setEnabled(true)
        let out = await e.sync(local: s)
        #expect(out.merged.neverCorrect["old"] == nil)
        #expect(out.merged.neverCorrect["fresh"] != nil)
        #expect(out.merged.isNeverCorrect("kept"))
    }
}

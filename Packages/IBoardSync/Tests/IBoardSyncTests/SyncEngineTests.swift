import Testing
import Foundation
@testable import IBoardSync

@Suite struct SyncEngineTests {
    let keyData = SyncCrypto.generateKeyData()
    func engine(_ store: InMemorySyncStore, device: String, key: Data? = nil) -> SyncEngine {
        // Clock near the tiny test stamps so tombstone compaction (real-time based) does not drop them.
        SyncEngine(store: store, crypto: SyncCrypto(keyData: key ?? keyData), deviceID: device,
                   now: { Date(timeIntervalSince1970: 1) })
    }
    func state(_ device: String, _ words: [String: UInt64], now: UInt64 = 1000) -> SyncState {
        var s = SyncState()
        for (w, n) in words { s.increment(w, by: n, device: device, now: now) }
        return s
    }

    @Test func offByDefaultAndNoTraffic() async throws {
        let store = InMemorySyncStore()
        let e = engine(store, device: "A")
        #expect(await e.status == .off)
        let out = await e.sync(local: state("A", ["hi": 1]))
        #expect(!out.uploaded)
        #expect(await store.saveCount == 0)
    }

    @Test func twoDevicesConverge() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"), b = engine(store, device: "B")
        await a.setEnabled(true); await b.setEnabled(true)
        let la = state("A", ["namaste": 3, "kya": 1]), lb = state("B", ["namaste": 2])
        _ = await a.sync(local: la)
        let ob = await b.sync(local: lb)
        let oa = await a.sync(local: la)
        #expect(ob.merged.count("namaste") == 5)
        #expect(oa.merged == ob.merged)
        let again = await a.sync(local: oa.merged)
        #expect(again.merged.count("namaste") == 5)
    }

    @Test func payloadIsEncrypted() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"); await a.setEnabled(true)
        _ = await a.sync(local: state("A", ["secretpassword": 1]))
        let raw = await store.rawShards()
        #expect(raw.count == 1)
        #expect(raw[0].payload.range(of: Data("secretpassword".utf8)) == nil)
    }

    @Test func wrongKeyAndCorruptShardsAreSkipped() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"); await a.setEnabled(true)
        _ = await a.sync(local: state("A", ["x": 1]))
        let other = engine(store, device: "B", key: SyncCrypto.generateKeyData()); await other.setEnabled(true)
        let o = await other.sync(local: state("B", ["y": 1]))
        #expect(o.skippedShards == 1)
        #expect(o.merged.count("x") == 0 && o.merged.count("y") == 1)
        await store.corrupt("shard-A-0")
        let o2 = await a.sync(local: state("A", ["x": 1]))
        #expect(o2.skippedShards == 2 && o2.merged.count("x") == 1)
    }

    @Test func shardCannotBeReplayedUnderAnotherName() throws {
        let c = SyncCrypto(keyData: keyData)
        let sealed = try c.seal(Data("p".utf8), bindingTo: "shard-A-0")
        #expect(throws: SyncCryptoError.authenticationFailed) { try c.open(sealed, bindingTo: "shard-B-0") }
    }

    @Test func forgetPropagatesAndStaleDeviceCannotResurrect() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"), b = engine(store, device: "B")
        await a.setEnabled(true); await b.setEnabled(true)
        var la = state("A", ["oops": 4])
        _ = await a.sync(local: la)
        var lb = (await b.sync(local: SyncState())).merged
        lb.forget("oops", device: "B", now: 5000)
        _ = await b.sync(local: lb)
        la = (await a.sync(local: la)).merged
        #expect(la.count("oops") == 0)
        #expect(la.isForgotten("oops"))
    }

    @Test func neverCorrectConflictLastWriterWins() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"), b = engine(store, device: "B")
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(), lb = SyncState()
        la.setNeverCorrect("iboard", present: true, device: "A", now: 100)
        lb.setNeverCorrect("iboard", present: false, device: "B", now: 200)
        _ = await a.sync(local: la); _ = await b.sync(local: lb)
        let oa = await a.sync(local: la)
        #expect(!oa.merged.isNeverCorrect("iboard"))
    }

    @Test func failuresSurfaceAndRecover() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"); await a.setEnabled(true)
        let l = state("A", ["k": 1])
        await store.setFailNext(.networkUnavailable)
        var o = await a.sync(local: l)
        #expect(!o.uploaded && o.merged == l)
        #expect(await a.status == .failed("No network"))
        await store.setAccountOK(false)
        o = await a.sync(local: l)
        #expect(await a.status == .failed("iCloud account unavailable"))
        await store.setAccountOK(true)
        o = await a.sync(local: l)
        #expect(o.uploaded)
    }

    @Test func disableDeletesCloudData() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"); await a.setEnabled(true)
        _ = await a.sync(local: state("A", ["k": 1]))
        await a.disable(deleteCloudData: true)
        #expect(await store.rawShards().isEmpty)
        #expect(await a.status == .off)
    }

    @Test func newerSchemaShardIsIgnored() async throws {
        let store = InMemorySyncStore()
        let a = engine(store, device: "A"); await a.setEnabled(true)
        try await store.save(SyncShard(recordName: "shard-Z-0", device: "Z", schemaVersion: 99, payload: Data(), updatedAt: Date()))
        let o = await a.sync(local: SyncState())
        #expect(o.skippedShards == 1 && o.uploaded)
    }
}

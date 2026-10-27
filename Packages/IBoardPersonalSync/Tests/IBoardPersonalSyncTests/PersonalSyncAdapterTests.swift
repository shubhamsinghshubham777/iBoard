import Testing
import Foundation
import IBoardSync
@testable import IBoardPersonalSync
import IBoardEngine

@Suite struct PersonalSyncAdapterTests {
    struct Device {
        let store: PersonalStore
        let engine: SyncEngine
        var memory = PersonalSyncMemory()
    }

    let cloud = InMemorySyncStore()
    let key = SyncCrypto.generateKeyData()
    let clock = ManualPersonalClock()

    func device(_ id: String) async -> Device {
        let store = PersonalStore(storage: InMemoryPersonalStorage(), clock: clock)
        let engine = SyncEngine(store: cloud, crypto: SyncCrypto(keyData: key), deviceID: id,
                                now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await engine.setEnabled(true)
        return Device(store: store, engine: engine)
    }

    func sync(_ d: inout Device, ms: UInt64) async -> PersonalSyncAdapter.Result {
        let r = await PersonalSyncAdapter.run(store: d.store, engine: d.engine, memory: d.memory, nowMs: ms)
        if r.outcome.uploaded { d.memory = r.memory }
        return r
    }

    @Test func learningFlowsBetweenDevicesWithoutDoubleCounting() async throws {
        var a = await device("A"), b = await device("B")
        for _ in 0..<3 { await a.store.learn(word: "namaste", context: ["kya"], increment: 1) }
        await b.store.learn(word: "namaste", increment: 1)
        _ = await sync(&a, ms: 1_700_000_001_000)
        _ = await sync(&b, ms: 1_700_000_002_000)
        #expect(await b.store.uses(of: "namaste") >= 4 - 3 + 1) // own 1 + remote folded
        let before = await b.store.uses(of: "namaste")
        #expect(await b.store.exportState().bigrams.count == 1)
        // Repeated syncs are stable: nothing re-applied, nothing re-exported as local learning.
        for i in 0..<3 {
            _ = await sync(&b, ms: 1_700_000_003_000 + UInt64(i) * 1000)
            _ = await sync(&a, ms: 1_700_000_004_000 + UInt64(i) * 1000)
        }
        #expect(await b.store.uses(of: "namaste") == before)
        #expect(b.memory.state.count("u:namaste") == 4)
        #expect(a.memory.state.count("u:namaste") == 4)
        #expect(b.memory.ledger.own["u:namaste"] == 1)
        #expect(a.memory.ledger.own["u:namaste"] == 3)
    }

    @Test func forgetPropagatesAndNgramsDoNotResurrect() async throws {
        var a = await device("A"), b = await device("B")
        await a.store.learn(word: "oops", context: ["say"], increment: 1)
        await a.store.learn(word: "keep", increment: 1)
        _ = await sync(&a, ms: 1_700_000_001_000)
        _ = await sync(&b, ms: 1_700_000_002_000)
        #expect(await b.store.uses(of: "oops") > 0)
        await b.store.forget("oops")
        _ = await sync(&b, ms: 1_700_000_003_000)
        _ = await sync(&a, ms: 1_700_000_004_000)
        #expect(await a.store.isForgotten("oops"))
        #expect(await a.store.uses(of: "oops") == 0)
        #expect(await a.store.exportState().bigrams.isEmpty)
        #expect(await a.store.uses(of: "keep") > 0)
        _ = await sync(&b, ms: 1_700_000_005_000)
        #expect(await b.store.uses(of: "oops") == 0)
    }

    @Test func neverCorrectAddAndRemove() async throws {
        var a = await device("A"), b = await device("B")
        await a.store.addNeverCorrect("iboard")
        _ = await sync(&a, ms: 1_700_000_001_000)
        _ = await sync(&b, ms: 1_700_000_002_000)
        #expect(await b.store.isNeverCorrect("iboard"))
        await b.store.removeNeverCorrect("iboard")
        _ = await sync(&b, ms: 1_700_000_003_000)
        _ = await sync(&a, ms: 1_700_000_004_000)
        #expect(await !a.store.isNeverCorrect("iboard"))
    }

    @Test func shardContainsNoPlaintextWords() async throws {
        var a = await device("A")
        let secrets = ["hunter2password", "chandrashekhar", "mortgagearrears"]
        for w in secrets { await a.store.learn(word: w, context: ["my", "secret"], increment: 1) }
        await a.store.addNeverCorrect("zxqvlitmus")
        await a.store.forget(secrets[0])
        let r = await sync(&a, ms: 1_700_000_001_000)
        #expect(r.outcome.uploaded)
        // Sanity: the unencrypted state does contain the words, so the check below is meaningful.
        let plain = String(decoding: try r.memory.state.encoded(), as: UTF8.self)
        #expect(plain.contains("chandrashekhar") && plain.contains("zxqvlitmus"))
        let shards = await cloud.rawShards()
        #expect(!shards.isEmpty)
        for s in shards {
            let blob = s.payload + Data(s.recordName.utf8) + Data(s.device.utf8)
            for w in secrets + ["zxqvlitmus", "secret"] {
                #expect(blob.range(of: Data(w.utf8)) == nil, "plaintext \(w) in shard")
                #expect(blob.range(of: Data(w.capitalized.utf8)) == nil)
            }
            // And a wrong key cannot read it.
            #expect((try? SyncCrypto(keyData: SyncCrypto.generateKeyData()).open(s.payload, bindingTo: s.recordName)) == nil)
        }
    }

    @Test func prunedKeysDoNotBreakCounting() async throws {
        var a = await device("A")
        await a.store.learn(word: "alpha", increment: 1)
        _ = await sync(&a, ms: 1_700_000_001_000)
        await a.store.learn(word: "alpha", increment: 1)
        _ = await sync(&a, ms: 1_700_000_002_000)
        #expect(a.memory.state.count("u:alpha") == 2)
        _ = await sync(&a, ms: 1_700_000_003_000)
        #expect(a.memory.state.count("u:alpha") == 2)
    }
}

import Testing
import Foundation
@testable import IBoardSync

private func eng(_ store: SyncStore, _ id: String, _ crypto: SyncCrypto, maxShard: Int = SyncSharding.defaultMaxShardBytes) -> SyncEngine {
    SyncEngine(store: store, crypto: crypto, deviceID: id, now: { Date(timeIntervalSince1970: 1) }, maxShardBytes: maxShard)
}

private final class KeyCounter: @unchecked Sendable {
    var n: UInt8 = 0
    func next() -> Data { n += 1; return Data(repeating: n, count: 32) }
}

// MARK: Two devices with separate local state, exchanging only through the cloud store

@Suite struct TwoDeviceMergeTests {
    let key = SyncCrypto(keyData: SyncCrypto.generateKeyData())

    @Test func offlineConcurrentEditsConvergeInAnyOrder() async throws {
        for order in [["A", "B", "A"], ["B", "A", "B"], ["A", "A", "B", "B", "A", "B"]] {
            let cloud = InMemorySyncStore()
            var local = ["A": SyncState(), "B": SyncState()]
            var engines: [String: SyncEngine] = [:]
            for d in ["A", "B"] { engines[d] = eng(cloud, d, key); await engines[d]!.setEnabled(true) }
            local["A"]!.increment("u:hello", by: 3, device: "A", now: 10)
            local["B"]!.increment("u:hello", by: 4, device: "B", now: 11)
            local["A"]!.setNeverCorrect("iboard", present: true, device: "A", now: 12)
            local["B"]!.setNeverCorrect("iboard", present: false, device: "B", now: 13)
            for d in order { local[d] = await engines[d]!.sync(local: local[d]!).merged }
            for d in ["A", "B"] { local[d] = await engines[d]!.sync(local: local[d]!).merged }
            #expect(local["A"] == local["B"])
            #expect(local["A"]!.count("u:hello") == 7)
            #expect(!local["A"]!.isNeverCorrect("iboard"))
        }
    }

    @Test func staleShardReplayDoesNotRegress() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key), b = eng(cloud, "B", key)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(); la.increment("u:x", by: 2, device: "A", now: 10)
        la = await a.sync(local: la).merged
        let old = await cloud.rawShards()
        la.increment("u:x", by: 5, device: "A", now: 20)
        la = await a.sync(local: la).merged
        for s in old { try await cloud.save(s) }   // CloudKit serves an old version of A's shard
        let lb = await b.sync(local: SyncState()).merged
        #expect(lb.count("u:x") == 2)
        la = await a.sync(local: la).merged
        #expect(la.count("u:x") == 7)
        let lb2 = await b.sync(local: lb).merged
        #expect(lb2.count("u:x") == 7)
    }

    @Test func idempotentReapply() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key), b = eng(cloud, "B", key)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(); la.increment("u:x", by: 2, device: "A", now: 10)
        la.setNeverCorrect("n", present: true, device: "A", now: 11)
        la = await a.sync(local: la).merged
        var lb = SyncState()
        var prev: SyncState?
        for _ in 0..<5 {
            lb = await b.sync(local: lb).merged
            if let p = prev { #expect(p == lb) }
            prev = lb
        }
        #expect(lb.count("u:x") == 2)
        #expect(lb.merged(with: lb) == lb)
        #expect(lb.merged(with: la) == lb.merged(with: la).merged(with: la))
    }

    @Test func forgetNeverCorrectAndLaterRelearnAcrossDevices() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key), b = eng(cloud, "B", key)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(), lb = SyncState()
        la.increment("u:oops", by: 3, device: "A", now: 10)
        la.setNeverCorrect("keepme", present: true, device: "A", now: 10)
        la = await a.sync(local: la).merged
        lb = await b.sync(local: lb).merged
        lb.forget("u:oops", device: "B", now: 20)
        lb = await b.sync(local: lb).merged
        la.increment("u:oops", by: 1, device: "A", now: 15)   // A had not seen the forget; older clock
        la = await a.sync(local: la).merged
        #expect(la.count("u:oops") == 0 && la.isForgotten("u:oops"))
        la.increment("u:oops", by: 2, device: "A", now: 30)   // genuine later re-learn
        la = await a.sync(local: la).merged
        lb = await b.sync(local: lb).merged
        #expect(la.count("u:oops") == 2 && lb.count("u:oops") == 2)
        #expect(lb.isNeverCorrect("keepme"))
    }

    @Test func threeDevicesConverge() async throws {
        let cloud = InMemorySyncStore()
        var devs: [String: (SyncEngine, SyncState)] = [:]
        for d in ["A", "B", "C"] { let e = eng(cloud, d, key); await e.setEnabled(true); devs[d] = (e, SyncState()) }
        devs["A"]!.1.increment("k", by: 1, device: "A", now: 5)
        devs["B"]!.1.increment("k", by: 1, device: "B", now: 6)
        devs["C"]!.1.increment("k", by: 1, device: "C", now: 7)
        for _ in 0..<2 { for d in ["A", "B", "C"] { let (e, s) = devs[d]!; devs[d]!.1 = await e.sync(local: s).merged } }
        #expect(devs["A"]!.1.count("k") == 3)
        #expect(devs["A"]!.1 == devs["C"]!.1)
    }
}

// MARK: CloudKit record limits

@Suite struct SyncLimitTests {
    let key = SyncCrypto(keyData: SyncCrypto.generateKeyData())
    static let ckRecordLimit = 1_000_000   // CloudKit: 1 MB per record (all fields)
    static let ckModifyBatch = 400         // CloudKit: 400 records per modify operation

    func worst(keys n: Int, devices: Int, deviceIDLen: Int) -> SyncState {
        var s = SyncState()
        let devs = (0..<devices).map { i in String(repeating: "d", count: deviceIDLen - 2) + String(format: "%02d", i) }
        for i in 0..<n {
            let k = "t:" + String(repeating: "x", count: 100) + String(i)
            for d in devs { s.increment(k, by: 1_234_567, device: d, now: 1_700_000_000_000 + UInt64(i)) }
        }
        return s
    }

    @Test func costEstimateStaysNearRealSize() throws {
        let s = worst(keys: 300, devices: 4, deviceIDLen: 36)
        for piece in try SyncSharding.split(s, maxBytes: 50_000) {
            #expect(try piece.encoded().count <= 50_000 + 2_000, "piece exceeds budget")
        }
    }

    @Test func everySealedRecordFitsCloudKitLimit() async throws {
        let s = worst(keys: 12_000, devices: 4, deviceIDLen: 36)
        let parts = try SyncSharding.split(s)
        #expect(parts.count > 1)
        for (i, p) in parts.enumerated() {
            let sealed = try key.seal(try p.encoded(), bindingTo: SyncSharding.name(device: "d", index: i))
            #expect(sealed.count < Self.ckRecordLimit, "shard \(i) is \(sealed.count) bytes")
        }
        let cloud = InMemorySyncStore()
        let e = eng(cloud, "d", key); await e.setEnabled(true)
        let o = await e.sync(local: s)
        #expect(o.uploaded)
        for sh in await cloud.rawShards() { #expect(sh.payload.count < Self.ckRecordLimit) }
        #expect(SyncSharding.name(device: String(repeating: "u", count: 36), index: 999).utf8.count < 255)
    }

    @Test func maxKeysProjectionWithinRecordBatchLimit() throws {
        var s = SyncState()
        let n = 20_000
        for i in 0..<n { s.increment("t:" + String(repeating: "k", count: 120) + String(i), device: "dev", now: 1_700_000_000_000) }
        let parts = try SyncSharding.split(s)
        let projected = Int((Double(parts.count) / Double(n) * Double(SyncState.maxKeys)).rounded(.up))
        #expect(projected < Self.ckModifyBatch, "projected \(projected) shards for maxKeys")
        for p in parts { #expect(try p.encoded().count < Self.ckRecordLimit) }
    }

    @Test func oversizedKeyRejectedAndHostileShardSkipped() async throws {
        var s = SyncState(); s.increment(String(repeating: "x", count: SyncState.maxKeyBytes + 1), device: "A", now: 1)
        #expect(throws: SyncValidationError.keyTooLong) { try SyncState.decode(try s.encoded()) }
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key); await a.setEnabled(true)
        let bad = try key.seal(try s.encoded(), bindingTo: "shard-Z-0")
        try await cloud.save(SyncShard(recordName: "shard-Z-0", device: "Z", schemaVersion: 1, payload: bad, updatedAt: Date()))
        let o = await a.sync(local: SyncState())
        #expect(o.skippedShards == 1 && o.uploaded)
    }

    @Test func quotaExceededSurfacesAndKeepsLocal() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key); await a.setEnabled(true)
        var l = SyncState(); l.increment("k", device: "A", now: 1)
        await cloud.setFailNext(.quotaExceeded)
        let o = await a.sync(local: l)
        #expect(!o.uploaded && o.merged == l)
        #expect(await a.status == .failed("iCloud storage full"))
    }
}

// MARK: Key lifecycle

@Suite struct SyncKeyTests {
    @Test func firstEnableCreatesKeyOnlyWhenCloudIsEmpty() async throws {
        let kc = InMemoryKeychain()
        let kcount = KeyCounter()
        let m = SyncKeyManager(keychain: kc, generate: { kcount.next() })
        #expect(try await m.prepare(cloudHasShards: true) == .keyMissingCloudHasData)
        #expect(await kc.raw() == nil)
        #expect(await m.crypto == nil)
        #expect(try await m.prepare(cloudHasShards: false) == .ready)
        #expect(await kc.raw() != nil)
        #expect(try await SyncKeyManager(keychain: kc).prepare(cloudHasShards: true) == .ready)
    }

    @Test func keySharedThroughKeychainDecryptsOtherDevicesShards() async throws {
        let shared = InMemoryKeychain()
        let cloud = InMemorySyncStore()
        let ma = SyncKeyManager(keychain: shared), mb = SyncKeyManager(keychain: shared)
        _ = try await ma.prepare(cloudHasShards: false)
        let a = eng(cloud, "A", await ma.crypto!); await a.setEnabled(true)
        var la = SyncState(); la.increment("w", by: 2, device: "A", now: 1)
        _ = await a.sync(local: la)
        _ = try await mb.prepare(cloudHasShards: true)
        let b = eng(cloud, "B", await mb.crypto!); await b.setEnabled(true)
        #expect(await b.sync(local: SyncState()).merged.count("w") == 2)
    }

    @Test func keyLossIsDetectedAndRecoveredByStartOver() async throws {
        let cloud = InMemorySyncStore()
        let ma = SyncKeyManager(keychain: InMemoryKeychain())
        _ = try await ma.prepare(cloudHasShards: false)
        let a = eng(cloud, "A", await ma.crypto!); await a.setEnabled(true)
        var la = SyncState(); la.increment("w", by: 2, device: "A", now: 1)
        _ = await a.sync(local: la)
        let mb = SyncKeyManager(keychain: InMemoryKeychain())
        #expect(try await mb.prepare(cloudHasShards: true) == .keyMissingCloudHasData)
        let wrong = eng(cloud, "B", SyncCrypto(keyData: SyncCrypto.generateKeyData())); await wrong.setEnabled(true)
        let o = await wrong.sync(local: SyncState())
        #expect(o.keyMismatch && o.skippedShards == 1)
        try await mb.startOver()
        let b = eng(cloud, "B", await mb.crypto!); await b.setEnabled(true)
        await b.disable(deleteCloudData: true); await b.setEnabled(true)
        var lb = SyncState(); lb.increment("v", device: "B", now: 2)
        let ob = await b.sync(local: lb)
        #expect(ob.uploaded && !ob.keyMismatch && ob.merged.count("w") == 0)
        #expect(await a.sync(local: la).keyMismatch)
    }

    @Test func corruptKeychainItemTreatedAsMissingNotOverwritten() async throws {
        let kc = InMemoryKeychain(blob: Data("garbage".utf8))
        let m = SyncKeyManager(keychain: kc)
        #expect(try await m.prepare(cloudHasShards: true) == .keyMissingCloudHasData)
        #expect(await kc.raw() == Data("garbage".utf8))
        await kc.setRaw(try JSONEncoder().encode(SyncKeyring(keys: [Data(repeating: 1, count: 5)], generation: 1)))
        #expect(try await m.prepare(cloudHasShards: true) == .keyMissingCloudHasData)
    }

    @Test func keychainFailureSurfacesAndLeavesStateUntouched() async throws {
        let kc = InMemoryKeychain()
        let kcount = KeyCounter()
        let m = SyncKeyManager(keychain: kc, generate: { kcount.next() })
        await kc.setFailNext(true)
        await #expect(throws: SyncKeychainError.unavailable) { _ = try await m.prepare(cloudHasShards: false) }
        #expect(await m.crypto == nil)
        _ = try await m.prepare(cloudHasShards: false)
        await kc.setFailNext(true)
        await #expect(throws: SyncKeychainError.unavailable) { try await m.rotate() }
        #expect(await m.keyring?.generation == 1)
    }

    @Test func rotationKeepsOldDataReadableAndReencryptsOnNextSync() async throws {
        let shared = InMemoryKeychain(), cloud = InMemorySyncStore()
        let kcount = KeyCounter()
        let ma = SyncKeyManager(keychain: shared, generate: { kcount.next() }), mb = SyncKeyManager(keychain: shared)
        _ = try await ma.prepare(cloudHasShards: false); _ = try await mb.prepare(cloudHasShards: true)
        let a = eng(cloud, "A", await ma.crypto!), b = eng(cloud, "B", await mb.crypto!)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(), lb = SyncState()
        la.increment("w", by: 1, device: "A", now: 1); lb.increment("w", by: 1, device: "B", now: 2)
        la = await a.sync(local: la).merged; lb = await b.sync(local: lb).merged

        try await ma.rotate()
        await a.setCrypto(await ma.crypto!)
        la = await a.sync(local: la).merged
        #expect(la.count("w") == 2)
        let stale = await b.sync(local: lb)
        #expect(stale.skippedShards == 1 && stale.uploaded && !stale.keyMismatch)
        #expect(try await mb.refresh())
        await b.setCrypto(await mb.crypto!)
        lb = await b.sync(local: lb).merged
        #expect(lb.count("w") == 2)
        #expect(await mb.keyring?.generation == 2)
        try await ma.retireOldKeys()
        let after = await ma.crypto!
        for s in await cloud.rawShards() { _ = try after.open(s.payload, bindingTo: s.recordName) }
    }

    @Test func rotationKeyringIsBounded() async throws {
        let kcount = KeyCounter()
        let m = SyncKeyManager(keychain: InMemoryKeychain(), generate: { kcount.next() })
        _ = try await m.prepare(cloudHasShards: false)
        for _ in 0..<6 { try await m.rotate() }
        #expect(await m.keyring!.keys.count == 1 + SyncKeyring.maxPrevious)
        #expect(await m.keyring!.generation == 7)
    }
}

// MARK: Delete iCloud data

@Suite struct DeleteCloudDataTests {
    let key = SyncCrypto(keyData: SyncCrypto.generateKeyData())

    @Test func deleteRemovesEveryDeviceShardAndOffMeansNoTraffic() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key, maxShard: 400), b = eng(cloud, "B", key)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(); for i in 0..<50 { la.increment("key\(i)", device: "A", now: 1) }
        var lb = SyncState(); lb.increment("b", device: "B", now: 1)
        _ = await a.sync(local: la); _ = await b.sync(local: lb)
        #expect(await cloud.rawShards().count > 2)
        await a.disable(deleteCloudData: true)
        #expect(await cloud.rawShards().isEmpty)
        #expect(await a.status == .off)
        let saves = await cloud.saveCount
        let o = await a.sync(local: la)
        #expect(!o.uploaded)
        #expect(await cloud.saveCount == saves)
    }

    @Test func disableWithoutDeleteKeepsCloudData() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key); await a.setEnabled(true)
        var la = SyncState(); la.increment("k", device: "A", now: 1)
        _ = await a.sync(local: la)
        await a.disable(deleteCloudData: false)
        #expect(await cloud.rawShards().count == 1)
    }

    @Test func failedDeleteReportsErrorAndStaysDisabled() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key); await a.setEnabled(true)
        var la = SyncState(); la.increment("k", device: "A", now: 1)
        _ = await a.sync(local: la)
        await cloud.setFailNext(.networkUnavailable)
        await a.disable(deleteCloudData: true)
        #expect(await a.status == .failed("No network"))
        #expect(await a.enabled == false)
        #expect(await cloud.rawShards().count == 1)
        await a.disable(deleteCloudData: true)
        #expect(await cloud.rawShards().isEmpty)
    }

    @Test func otherEnabledDeviceRepopulatesAfterDelete() async throws {
        let cloud = InMemorySyncStore()
        let a = eng(cloud, "A", key), b = eng(cloud, "B", key)
        await a.setEnabled(true); await b.setEnabled(true)
        var la = SyncState(), lb = SyncState()
        la.increment("k", by: 2, device: "A", now: 1); lb.increment("m", device: "B", now: 2)
        la = await a.sync(local: la).merged; lb = await b.sync(local: lb).merged
        await a.disable(deleteCloudData: true)
        #expect(await cloud.rawShards().isEmpty)
        lb = await b.sync(local: lb).merged
        #expect(lb.count("m") == 1 && lb.count("k") == 2)
        #expect(await cloud.rawShards().count == 1)
        await a.setEnabled(true)
        #expect(await a.sync(local: SyncState()).merged.count("k") == 2)
    }

    @Test func deleteThenKeyForgottenLeavesNothingReadable() async throws {
        let cloud = InMemorySyncStore(), kc = InMemoryKeychain()
        let m = SyncKeyManager(keychain: kc)
        _ = try await m.prepare(cloudHasShards: false)
        let a = eng(cloud, "A", await m.crypto!); await a.setEnabled(true)
        var la = SyncState(); la.increment("k", device: "A", now: 1)
        _ = await a.sync(local: la)
        await a.disable(deleteCloudData: true)
        try await m.forgetKey()
        #expect(await cloud.rawShards().isEmpty)
        #expect(await kc.raw() == nil)
        #expect(await m.crypto == nil)
        #expect(try await m.prepare(cloudHasShards: false) == .ready)
    }
}

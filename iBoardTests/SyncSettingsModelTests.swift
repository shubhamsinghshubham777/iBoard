import Foundation
import Testing
import IBoardSync
import IBoardEngine
@testable import iBoard

@MainActor
struct SyncSettingsModelTests {
    private func make(store: InMemorySyncStore, keychain: InMemoryKeychain, device: String = "dev-a") -> SyncSettingsModel {
        let dir = FileManager.default.temporaryDirectory.appending(path: "iboard-sync-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: "iboard.test.\(UUID().uuidString)")!
        return SyncSettingsModel(store: store, keychain: keychain, deviceID: device, defaults: suite,
                                 memoryURL: dir.appending(path: "mem.json"),
                                 personalStore: { PersonalStore(storage: FilePersonalStorage(directory: dir.appending(path: "p"), mode: .appGroup)) })
    }

    @Test func enablingWithEmptyCloudCreatesKeyAndSyncs() async {
        let store = InMemorySyncStore(), kc = InMemoryKeychain()
        let m = make(store: store, keychain: kc)
        await m.setEnabled(true)
        #expect(m.keyState == .ok)
        #expect(await kc.raw() != nil)
        #expect(await store.saveCount > 0)
    }

    @Test func keyMissingWhenCloudHasDataAndNoKey() async {
        let store = InMemorySyncStore()
        let a = make(store: store, keychain: InMemoryKeychain(), device: "dev-a")
        await a.setEnabled(true)
        let kcB = InMemoryKeychain()
        let b = make(store: store, keychain: kcB, device: "dev-b")
        await b.setEnabled(true)
        #expect(b.keyState == .keyMissing)
        #expect(await kcB.raw() == nil)   // never auto-creates a key over existing cloud data
        #expect(await store.rawShards().allSatisfy { $0.device == "dev-a" })
    }

    @Test func mismatchedKeySurfacesAndStartOverRecovers() async {
        let store = InMemorySyncStore()
        let a = make(store: store, keychain: InMemoryKeychain(), device: "dev-a")
        await a.setEnabled(true)
        let kcB = InMemoryKeychain()
        _ = try? await SyncKeyManager(keychain: kcB).prepare(cloudHasShards: false)   // device b already has its own, different key
        let b = make(store: store, keychain: kcB, device: "dev-b")
        await b.setEnabled(true)
        #expect(b.keyState == .keyMismatch)
        await b.startOver()
        #expect(b.keyState == .ok)
        #expect(await store.rawShards().allSatisfy { $0.device == "dev-b" })   // unreadable old data erased
    }

    @Test func deleteCloudDataTurnsSyncOffAndKeepsKey() async {
        let store = InMemorySyncStore(), kc = InMemoryKeychain()
        let m = make(store: store, keychain: kc)
        await m.setEnabled(true)
        await m.deleteCloudData()
        #expect(!m.enabled)
        #expect(await store.rawShards().isEmpty)
        #expect(await kc.raw() != nil)
    }
}

import SwiftUI
import Security
import IBoardSync
import IBoardPersonalSync
import IBoardEngine

enum SyncKeyState: Equatable {
    case ok
    /// iCloud has encrypted data but this device has no key yet (iCloud Keychain has not delivered it, or it was lost).
    case keyMissing
    /// This device's key cannot open what is in iCloud (a different key was used).
    case keyMismatch
}

/// Opt-in iCloud sync settings (M12-02/03). The keyboard never syncs; only this app talks to CloudKit, only after the
/// owner turns it on. Needs the iCloud/CloudKit entitlement + container `iCloud.app.iBoard` on a real device.
@MainActor @Observable
final class SyncSettingsModel {
    private static let enabledKey = "iboard.sync.enabled"
    private(set) var statusText = "Off"
    private(set) var busy = false
    private(set) var keyState: SyncKeyState = .ok
    var enabled: Bool { didSet { if oldValue != enabled { defaults.set(enabled, forKey: Self.enabledKey) } } }
    private var engine: SyncEngine?
    private let store: SyncStore
    private let keys: SyncKeyManager
    private let deviceID: String
    private let defaults: UserDefaults
    private let memoryURL: URL
    private let personalStore: @MainActor () -> PersonalStore?

    init(store: SyncStore = CloudKitSyncStore(),
         keychain: SyncKeychain = SyncKeychainItem(),
         deviceID: String = Keychain.deviceID(),
         defaults: UserDefaults = .standard,
         memoryURL: URL = LocalSyncFile.url,
         personalStore: @escaping @MainActor () -> PersonalStore? = { SyncSettingsModel.appGroupStore() }) {
        self.store = store; self.keys = SyncKeyManager(keychain: keychain); self.deviceID = deviceID
        self.defaults = defaults; self.memoryURL = memoryURL; self.personalStore = personalStore
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Resolves the key (creating one only when iCloud holds no data) and builds the engine. Returns nil, with
    /// `keyState`/`statusText` set, when sync cannot proceed.
    private func readyEngine() async -> SyncEngine? {
        do {
            let hasShards = try await !store.fetchAllShards().isEmpty
            switch try await keys.prepare(cloudHasShards: hasShards) {
            case .keyMissingCloudHasData:
                keyState = .keyMissing
                statusText = "Waiting for your encryption key"
                return nil
            case .ready:
                guard let crypto = await keys.crypto else { statusText = "Encryption key unavailable"; return nil }
                if keyState == .keyMissing { keyState = .ok }
                if let engine { await engine.setCrypto(crypto); return engine }
                let e = SyncEngine(store: store, crypto: crypto, deviceID: deviceID)
                engine = e
                return e
            }
        } catch {
            statusText = "Could not reach iCloud or Keychain"
            return nil
        }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            enabled = true
            await syncNow()
        } else {
            enabled = false
            await engine?.setEnabled(false)
            keyState = .ok
            statusText = "Off"
        }
    }

    /// The personal model in the App Group (written by the keyboard with Full Access). The app only touches it while a
    /// sync runs. Without the shared container there is nothing to sync.
    static func appGroupStore() -> PersonalStore? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.iBoard") else { return nil }
        let dir = root.appendingPathComponent("personal", isDirectory: true)
        return PersonalStore(storage: FilePersonalStorage(directory: dir, mode: .appGroup))
    }

    /// Removes this account's iBoard data from iCloud and turns sync off. Local data and the key are kept.
    func deleteCloudData() async {
        busy = true; defer { busy = false }
        enabled = false
        keyState = .ok
        if let engine {
            await engine.disable(deleteCloudData: true)
            if case .failed = await engine.status { statusText = "Could not delete iCloud data. Try again."; return }
        } else {
            do { try await store.deleteAll() } catch { statusText = "Could not delete iCloud data. Try again."; return }
        }
        statusText = "Off. iCloud data deleted."
    }

    /// Recovery when the key is gone for good: erase the (now unreadable) iCloud data, make a new key, and upload this
    /// device's data again. Other devices must pick up the new key through iCloud Keychain.
    func startOver() async {
        busy = true
        do {
            try await store.deleteAll()
            try await keys.startOver()
            keyState = .ok
            busy = false
            await syncNow()
        } catch {
            busy = false
            statusText = "Could not start over. Nothing was changed."
        }
    }

    func syncNow() async {
        guard enabled else { return }
        busy = true; defer { busy = false }
        guard let engine = await readyEngine() else { return }
        await engine.setEnabled(true)
        guard let personal = personalStore() else { statusText = "Personal data unavailable"; return }
        let memory = PersonalSyncMemory.load(from: memoryURL)
        let result = await PersonalSyncAdapter.run(store: personal, engine: engine, memory: memory)
        if result.outcome.keyMismatch {
            keyState = .keyMismatch
            statusText = "This device's key does not match iCloud"
            return
        }
        keyState = .ok
        if result.outcome.uploaded { result.memory.save(to: memoryURL) }
        switch await engine.status {
        case .off: statusText = "Off"
        case .syncing: statusText = "Syncing"
        case .failed(let m): statusText = m
        case .idle(let d): statusText = d.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Ready"
        }
    }
}

/// Device-local sync memory (last merged state + ledger of what has been exported/applied). No backup.
enum LocalSyncFile {
    static var url: URL { URL.applicationSupportDirectory.appending(path: "sync-memory.json") }
}

/// Per-device (non-synchronizable) identifier. The encryption key is handled by `SyncKeyManager` + `SyncKeychainItem`.
enum Keychain {
    private static func read(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.iBoard.sync",
                                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    private static func write(_ account: String, _ data: Data, synchronizable: Bool) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.iBoard.sync",
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrSynchronizable as String: synchronizable,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func deviceID() -> String {
        if let d = read("device"), let s = String(data: d, encoding: .utf8) { return s }
        let s = UUID().uuidString
        write("device", Data(s.utf8), synchronizable: false)
        return s
    }
}

struct SyncSettingsView: View {
    @State private var model = SyncSettingsModel()
    @State private var confirmDelete = false
    @State private var confirmStartOver = false

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: Binding(get: { model.enabled }, set: { v in Task { await model.setEnabled(v) } }))
                if model.enabled {
                    LabeledContent("Status", value: model.statusText)
                    Button("Sync now") { Task { await model.syncNow() } }.disabled(model.busy)
                }
            } footer: {
                Text("Off by default. Your learned words are encrypted on this device before they go to your private iCloud; the key stays in iCloud Keychain. The keyboard itself never uses the network.")
            }
            if model.enabled, model.keyState != .ok { keyProblemSection }
            Section {
                Button("Delete iCloud data", role: .destructive) { confirmDelete = true }.disabled(model.busy)
            } footer: {
                Text("Turns sync off and removes everything iBoard stored in your iCloud. Data on this device is kept.")
            }
        }
        .navigationTitle("iCloud sync")
        .confirmationDialog("Delete iBoard data from iCloud?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete and turn off", role: .destructive) { Task { await model.deleteCloudData() } }
        }
        .confirmationDialog("Start over with a new key?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Erase iCloud data and start over", role: .destructive) { Task { await model.startOver() } }
        } message: {
            Text("The words already in iCloud cannot be read without the old key, so they will be erased. This device's words are kept and uploaded again with a new key.")
        }
    }

    @ViewBuilder private var keyProblemSection: some View {
        Section {
            Text(model.keyState == .keyMissing
                 ? "Your iCloud holds iBoard data, but this device does not have its encryption key yet. Make sure iCloud Keychain is on and signed in to the same Apple ID, then check again. The key can take a few minutes to arrive."
                 : "The key on this device does not open the data in iCloud, so nothing was merged. This can happen if the key was replaced. Check again after iCloud Keychain finishes syncing.")
            Button("Check again") { Task { await model.syncNow() } }.disabled(model.busy)
            Button("I lost the key: start over", role: .destructive) { confirmStartOver = true }.disabled(model.busy)
        } header: {
            Text(model.keyState == .keyMissing ? "Encryption key missing" : "Encryption key mismatch")
        } footer: {
            Text("Start over erases the unreadable iCloud data and creates a new key. Nothing on this device is lost.")
        }
    }
}

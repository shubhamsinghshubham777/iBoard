import SwiftUI
import Security
import IBoardSync
import IBoardEngine

/// Opt-in iCloud sync settings (M12-02/03). The keyboard never syncs; only this app talks to CloudKit, only after the
/// owner turns it on. Needs the iCloud/CloudKit entitlement + container `iCloud.app.iBoard` on a real device.
@MainActor @Observable
final class SyncSettingsModel {
    private static let enabledKey = "iboard.sync.enabled"
    private(set) var statusText = "Off"
    private(set) var busy = false
    var enabled: Bool { didSet { if oldValue != enabled { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } } }
    private var engine: SyncEngine?

    init() { enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private func makeEngine() -> SyncEngine {
        if let engine { return engine }
        let e = SyncEngine(store: CloudKitSyncStore(), crypto: SyncCrypto(keyData: Keychain.syncKey()), deviceID: Keychain.deviceID())
        engine = e
        return e
    }

    func setEnabled(_ on: Bool) async {
        if on {
            enabled = true
            await makeEngine().setEnabled(true)
            await syncNow()
        } else {
            enabled = false
            await makeEngine().setEnabled(false)
            statusText = "Off"
        }
    }

    /// The personal model in the App Group (written by the keyboard with Full Access). The app only touches it while a
    /// sync runs. Without the shared container there is nothing to sync.
    private static func personalStore() -> PersonalStore? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.iBoard") else { return nil }
        let dir = root.appendingPathComponent("personal", isDirectory: true)
        return PersonalStore(storage: FilePersonalStorage(directory: dir, mode: .appGroup))
    }

    func deleteCloudData() async {
        busy = true; defer { busy = false }
        enabled = false
        await makeEngine().disable(deleteCloudData: true)
        statusText = "Off. iCloud data deleted."
    }

    func syncNow() async {
        guard enabled else { return }
        busy = true; defer { busy = false }
        let engine = makeEngine()
        guard let store = Self.personalStore() else { statusText = "Personal data unavailable"; return }
        let memory = PersonalSyncMemory.load(from: LocalSyncFile.url)
        let result = await PersonalSyncAdapter.run(store: store, engine: engine, memory: memory)
        if result.outcome.uploaded { result.memory.save(to: LocalSyncFile.url) }
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
    /// Encryption key: synchronizable Keychain item, so iCloud Keychain shares it between the owner's devices.
    static func syncKey() -> Data {
        if let d = read("key") { return d }
        let d = SyncCrypto.generateKeyData()
        write("key", d, synchronizable: true)
        return d
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
    }
}

import Foundation
import Security
import IBoardSync

/// Production `SyncKeychain`: the keyring lives in ONE synchronizable generic-password item, so iCloud Keychain
/// carries it to the owner's other devices. Key material is never logged; errors carry only the OSStatus code.
/// App target only. The keyboard extension must not use or link this (audit-privacy EXT-SYNC).
struct SyncKeychainItem: SyncKeychain {
    let service: String
    let account: String
    /// `false` only for tests that must not touch iCloud Keychain.
    let synchronizable: Bool

    init(service: String = "app.iBoard.sync", account: String = "keyring", synchronizable: Bool = true) {
        self.service = service; self.account = account; self.synchronizable = synchronizable
    }

    struct Failure: Error, Equatable { let status: OSStatus }

    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: synchronizable]
    }

    func read() async throws -> Data? {
        var q = match
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw Failure(status: st) }
        return out as? Data
    }

    func write(_ data: Data) async throws {
        let update: [String: Any] = [kSecValueData as String: data]
        var st = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if st == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw Failure(status: st) }
    }

    func delete() async throws {
        let st = SecItemDelete(match as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw Failure(status: st) }
    }
}

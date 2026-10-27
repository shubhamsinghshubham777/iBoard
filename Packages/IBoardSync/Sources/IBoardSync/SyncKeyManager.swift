import Foundation

/// Keychain access abstracted so key handling is testable. The production implementation (app target) stores the
/// keyring as one synchronizable generic-password item (iCloud Keychain); tests use `InMemoryKeychain`.
public protocol SyncKeychain: Sendable {
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    func delete() async throws
}

public enum SyncKeychainError: Error, Equatable, Sendable { case unavailable }

public actor InMemoryKeychain: SyncKeychain {
    private var blob: Data?
    public var failNext = false
    public init(blob: Data? = nil) { self.blob = blob }
    public func setFailNext(_ v: Bool) { failNext = v }
    public func raw() -> Data? { blob }
    public func setRaw(_ d: Data?) { blob = d }
    private func check() throws { if failNext { failNext = false; throw SyncKeychainError.unavailable } }
    public func read() async throws -> Data? { try check(); return blob }
    public func write(_ data: Data) async throws { try check(); blob = data }
    public func delete() async throws { try check(); blob = nil }
}

/// Ordered keys: `keys[0]` seals, all open. Stored as JSON in the keychain item.
public struct SyncKeyring: Codable, Equatable, Sendable {
    public static let maxPrevious = 2
    public var keys: [Data]
    public var generation: Int
    var isValid: Bool { !keys.isEmpty && keys.allSatisfy { $0.count == 32 } && generation >= 1 }
}

public enum SyncKeyResolution: Equatable, Sendable {
    /// Key found (or safely created because the cloud holds no data).
    case ready
    /// No usable key here but the cloud has encrypted data: never auto-create (that would orphan it). The user chooses
    /// to wait for iCloud Keychain to deliver the key, or to `startOver()`.
    case keyMissingCloudHasData
}

/// Key lifecycle: create, load, rotate, recover from loss. Keys only ever live in the keychain, never in CloudKit.
public actor SyncKeyManager {
    private let keychain: SyncKeychain
    private let generate: @Sendable () -> Data
    public private(set) var keyring: SyncKeyring?

    public init(keychain: SyncKeychain, generate: @escaping @Sendable () -> Data = { SyncCrypto.generateKeyData() }) {
        self.keychain = keychain; self.generate = generate
    }

    public var crypto: SyncCrypto? { keyring.map { SyncCrypto(keys: $0.keys) } }

    private func load() async throws -> SyncKeyring? {
        guard let d = try await keychain.read() else { return nil }
        // A damaged item counts as missing rather than crashing or silently replacing data.
        guard let r = try? JSONDecoder().decode(SyncKeyring.self, from: d), r.isValid else { return nil }
        return r
    }

    private func persist(_ r: SyncKeyring) async throws {
        try await keychain.write(try JSONEncoder().encode(r)); keyring = r
    }

    /// Call when enabling sync. `cloudHasShards` comes from the store (any record present).
    public func prepare(cloudHasShards: Bool) async throws -> SyncKeyResolution {
        if let r = try await load() { keyring = r; return .ready }
        keyring = nil
        if cloudHasShards { return .keyMissingCloudHasData }
        try await persist(SyncKeyring(keys: [generate()], generation: 1))
        return .ready
    }

    /// Re-read the keychain (e.g. after iCloud Keychain delivered the key from another device).
    public func refresh() async throws -> Bool {
        keyring = try await load()
        return keyring != nil
    }

    /// New sealing key; older keys stay readable (bounded) until `retireOldKeys()`. Persist before use: if the
    /// keychain write fails nothing changes.
    public func rotate() async throws {
        guard let cur = try await load() ?? keyring else { throw SyncKeychainError.unavailable }
        let keys = Array(([generate()] + cur.keys).prefix(1 + SyncKeyring.maxPrevious))
        try await persist(SyncKeyring(keys: keys, generation: cur.generation + 1))
    }

    /// Drop previous keys once every device has re-uploaded under the newest one.
    public func retireOldKeys() async throws {
        guard var r = keyring else { return }
        r.keys = Array(r.keys.prefix(1))
        try await persist(r)
    }

    /// Key lost for good: new key, caller must also wipe the cloud (`SyncEngine.disable(deleteCloudData:)`) and
    /// re-upload local state. Old cloud data is unrecoverable by design.
    public func startOver() async throws {
        try await persist(SyncKeyring(keys: [generate()], generation: (keyring?.generation ?? 0) + 1))
    }

    /// User turned sync off and chose to remove the key too.
    public func forgetKey() async throws { try await keychain.delete(); keyring = nil }
}

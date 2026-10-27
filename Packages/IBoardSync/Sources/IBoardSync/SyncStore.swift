import Foundation

/// One encrypted record owned by a device. The store never sees plaintext.
public struct SyncShard: Sendable, Equatable {
    public var recordName: String
    public var device: String
    public var schemaVersion: Int
    public var payload: Data
    public var updatedAt: Date
    public init(recordName: String, device: String, schemaVersion: Int, payload: Data, updatedAt: Date) {
        self.recordName = recordName; self.device = device; self.schemaVersion = schemaVersion
        self.payload = payload; self.updatedAt = updatedAt
    }
}

public enum SyncStoreError: Error, Equatable, Sendable {
    case accountUnavailable, networkUnavailable, quotaExceeded, serverRejected(String)
}

/// Transport abstraction. CloudKit implements it; tests use `InMemorySyncStore`.
public protocol SyncStore: Sendable {
    func accountAvailable() async throws -> Bool
    func fetchAllShards() async throws -> [SyncShard]
    func save(_ shard: SyncShard) async throws
    /// Deletes every record in the zone (user turned sync off with "delete iCloud data").
    func deleteAll() async throws
}

/// Test double. Optionally fails the next call or simulates a missing account.
public actor InMemorySyncStore: SyncStore {
    private var shards: [String: SyncShard] = [:]
    public var accountOK = true
    public var failNext: SyncStoreError?
    public private(set) var saveCount = 0
    public init() {}

    public func setAccountOK(_ v: Bool) { accountOK = v }
    public func setFailNext(_ e: SyncStoreError?) { failNext = e }
    public func rawShards() -> [SyncShard] { Array(shards.values) }
    public func corrupt(_ name: String) { shards[name]?.payload = Data([1, 2, 3]) }

    private func maybeFail() throws { if let e = failNext { failNext = nil; throw e } }
    public func accountAvailable() async throws -> Bool { try maybeFail(); return accountOK }
    public func fetchAllShards() async throws -> [SyncShard] { try maybeFail(); return Array(shards.values) }
    public func save(_ shard: SyncShard) async throws { try maybeFail(); saveCount += 1; shards[shard.recordName] = shard }
    public func deleteAll() async throws { try maybeFail(); shards = [:] }
}

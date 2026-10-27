import Foundation

public enum SyncStatus: Sendable, Equatable {
    case off
    case idle(lastSync: Date?)
    case syncing
    case failed(String)
}

public struct SyncOutcome: Sendable, Equatable {
    public var merged: SyncState
    /// Undecryptable, invalid or newer-schema shards that were ignored.
    public var skippedShards: Int
    public var uploaded: Bool
    /// Shards existed but none could be decrypted: the encryption key is missing/different on this device.
    public var keyMismatch: Bool = false
}

/// App-side sync. Opt-in: every call is a no-op while `enabled == false`. The keyboard never links or calls this.
/// Protocol: download all shards -> decrypt + validate -> merge with local -> upload only this device's shard.
public actor SyncEngine {
    private let store: SyncStore
    private var crypto: SyncCrypto
    public nonisolated let deviceID: String
    private let now: @Sendable () -> Date
    private let maxShardBytes: Int
    private let tombstoneRetention: TimeInterval
    public private(set) var enabled = false
    public private(set) var status: SyncStatus = .off
    private var lastSync: Date?

    public init(store: SyncStore, crypto: SyncCrypto, deviceID: String, now: @escaping @Sendable () -> Date = { Date() },
                maxShardBytes: Int = SyncSharding.defaultMaxShardBytes, tombstoneRetentionDays: Double = 180) {
        self.store = store; self.crypto = crypto; self.deviceID = deviceID; self.now = now
        self.maxShardBytes = maxShardBytes; self.tombstoneRetention = tombstoneRetentionDays * 86_400
    }

    public var shardName: String { SyncSharding.name(device: deviceID, index: 0) }

    /// Swap the key (after rotation or key recovery). Next sync re-uploads this device's shards under it.
    public func setCrypto(_ c: SyncCrypto) { crypto = c }

    public func setEnabled(_ on: Bool) {
        enabled = on
        status = on ? .idle(lastSync: lastSync) : .off
    }

    /// Merges remote state into `local` and uploads this device's contribution. Returns the merged state, which the
    /// caller applies to the personal model. Per-shard corruption is skipped and counted, never fatal.
    public func sync(local: SyncState) async -> SyncOutcome {
        guard enabled else { return SyncOutcome(merged: local, skippedShards: 0, uploaded: false) }
        status = .syncing
        do {
            guard try await store.accountAvailable() else {
                status = .failed("iCloud account unavailable")
                return SyncOutcome(merged: local, skippedShards: 0, uploaded: false)
            }
            var merged = local
            var skipped = 0
            let fetched = try await store.fetchAllShards()
            let ownShards = fetched.filter { $0.device == deviceID }
            for shard in fetched {
                guard shard.schemaVersion <= SyncState.currentSchemaVersion,
                      let plain = try? crypto.open(shard.payload, bindingTo: shard.recordName),
                      let remote = try? SyncState.decode(plain) else { skipped += 1; continue }
                merged = merged.merged(with: remote)
            }
            let cutoffMs = UInt64(max(0, now().timeIntervalSince1970 - tombstoneRetention) * 1000)
            merged = merged.compacted(tombstonesOlderThan: cutoffMs)
            let parts = try SyncSharding.split(merged, maxBytes: maxShardBytes)
            for (i, part) in parts.enumerated() {
                let name = SyncSharding.name(device: deviceID, index: i)
                let sealed = try crypto.seal(try part.encoded(), bindingTo: name)
                try await store.save(SyncShard(recordName: name, device: deviceID,
                                               schemaVersion: part.schemaVersion, payload: sealed, updatedAt: now()))
            }
            // Shrunk: blank out leftover higher-index shards from earlier uploads (tiny empty payloads).
            for old in ownShards where (SyncSharding.index(of: old.recordName, device: deviceID) ?? -1) >= parts.count {
                let sealed = try crypto.seal(try SyncState().encoded(), bindingTo: old.recordName)
                try await store.save(SyncShard(recordName: old.recordName, device: deviceID,
                                               schemaVersion: SyncState.currentSchemaVersion, payload: sealed, updatedAt: now()))
            }
            lastSync = now()
            status = .idle(lastSync: lastSync)
            let undecryptable = !fetched.isEmpty && skipped == fetched.count
            return SyncOutcome(merged: merged, skippedShards: skipped, uploaded: true, keyMismatch: undecryptable)
        } catch {
            status = .failed(Self.describe(error))
            return SyncOutcome(merged: local, skippedShards: 0, uploaded: false)
        }
    }

    /// Turn sync off. Optionally erase everything this account stored in iCloud.
    public func disable(deleteCloudData: Bool) async {
        enabled = false
        status = .off
        if deleteCloudData {
            do { try await store.deleteAll() } catch { status = .failed(Self.describe(error)) }
        }
    }

    static func describe(_ e: Error) -> String {
        switch e as? SyncStoreError {
        case .accountUnavailable: "iCloud account unavailable"
        case .networkUnavailable: "No network"
        case .quotaExceeded: "iCloud storage full"
        case .serverRejected(let m): "iCloud error: \(m)"
        case nil: "Sync failed"
        }
    }
}

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
}

/// App-side sync. Opt-in: every call is a no-op while `enabled == false`. The keyboard never links or calls this.
/// Protocol: download all shards -> decrypt + validate -> merge with local -> upload only this device's shard.
public actor SyncEngine {
    private let store: SyncStore
    private let crypto: SyncCrypto
    public let deviceID: String
    private let now: @Sendable () -> Date
    public private(set) var enabled = false
    public private(set) var status: SyncStatus = .off
    private var lastSync: Date?

    public init(store: SyncStore, crypto: SyncCrypto, deviceID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.crypto = crypto; self.deviceID = deviceID; self.now = now
    }

    public var shardName: String { "shard-\(deviceID)-0" }

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
            for shard in try await store.fetchAllShards() {
                guard shard.schemaVersion <= SyncState.currentSchemaVersion,
                      let plain = try? crypto.open(shard.payload, bindingTo: shard.recordName),
                      let remote = try? SyncState.decode(plain) else { skipped += 1; continue }
                merged = merged.merged(with: remote)
            }
            let sealed = try crypto.seal(try merged.encoded(), bindingTo: shardName)
            try await store.save(SyncShard(recordName: shardName, device: deviceID,
                                           schemaVersion: merged.schemaVersion, payload: sealed, updatedAt: now()))
            lastSync = now()
            status = .idle(lastSync: lastSync)
            return SyncOutcome(merged: merged, skippedShards: skipped, uploaded: true)
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

#if canImport(CloudKit)
import Foundation
import CloudKit

/// CloudKit private-database implementation (custom zone `IBoardSync`, docs/SYNC.md). Untested without a real
/// iCloud account and the iCloud entitlement; all logic lives in `SyncEngine`, tested with the in-memory fake.
public final class CloudKitSyncStore: SyncStore, @unchecked Sendable {
    private let db: CKDatabase
    private let zone = CKRecordZone(zoneName: "IBoardSync")
    private let container: CKContainer
    public init(containerID: String = "iCloud.app.iBoard") {
        container = CKContainer(identifier: containerID)
        db = container.privateCloudDatabase
    }

    public func accountAvailable() async throws -> Bool {
        do { return try await container.accountStatus() == .available }
        catch { throw map(error) }
    }

    public func fetchAllShards() async throws -> [SyncShard] {
        do {
            let (results, _) = try await db.records(
                matching: CKQuery(recordType: "DeviceShard", predicate: NSPredicate(value: true)),
                inZoneWith: zone.zoneID)
            return results.compactMap { _, r in
                guard let rec = try? r.get(), let data = rec["payload"] as? Data else { return nil }
                return SyncShard(recordName: rec.recordID.recordName, device: rec["device"] as? String ?? "",
                                 schemaVersion: (rec["schemaVersion"] as? Int) ?? 0, payload: data,
                                 updatedAt: rec["updatedAt"] as? Date ?? .distantPast)
            }
        } catch let e as CKError where e.code == .zoneNotFound { return [] }
        catch { throw map(error) }
    }

    public func save(_ shard: SyncShard) async throws {
        do {
            _ = try await db.save(zone)
            let id = CKRecord.ID(recordName: shard.recordName, zoneID: zone.zoneID)
            let rec: CKRecord
            do { rec = try await db.record(for: id) } catch { rec = CKRecord(recordType: "DeviceShard", recordID: id) }
            rec["device"] = shard.device
            rec["schemaVersion"] = shard.schemaVersion
            rec["payload"] = shard.payload
            rec["updatedAt"] = shard.updatedAt
            _ = try await db.save(rec)
        } catch { throw map(error) }
    }

    public func deleteAll() async throws {
        do { _ = try await db.deleteRecordZone(withID: zone.zoneID) }
        catch let e as CKError where e.code == .zoneNotFound { return }
        catch { throw map(error) }
    }

    private func map(_ e: Error) -> SyncStoreError {
        guard let ck = e as? CKError else { return .serverRejected("unknown") }
        switch ck.code {
        case .notAuthenticated, .permissionFailure: return .accountUnavailable
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited: return .networkUnavailable
        case .quotaExceeded: return .quotaExceeded
        default: return .serverRejected("code \(ck.code.rawValue)")
        }
    }
}
#endif

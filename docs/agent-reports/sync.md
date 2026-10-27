# Sync agent report (M12-02, M12-03)

Status: M12-02 [~], M12-03 [~] (logic [x] and tested with a fake; CloudKit and UI need a real iCloud device).

## Built
- `SyncStore` protocol + `InMemorySyncStore` fake (failure injection, corruption); `CloudKitSyncStore` (private DB, zone IBoardSync, `DeviceShard` records) behind `canImport(CloudKit)`.
- `SyncCrypto`: AES-256-GCM, record name bound as AAD. Key = synchronizable Keychain item (iCloud Keychain), never in CloudKit.
- `SyncEngine` actor: off by default; fetch, decrypt, validate, merge, upload only own shard; skips corrupt, wrong-key and newer-schema shards; status; disable with optional cloud delete.
- App: `iBoard/SyncSettingsView.swift` (toggle, status, sync now, delete iCloud data), one-line link in SettingsView, IBoardSync added to project.yml for the app target.

## Verified
- `swift test` in Packages/IBoardSync: 18 tests green (8 merge + 10 engine/conflict: convergence, encryption, wrong key, replay, forget vs stale device, never-correct LWW, failure recovery, delete, schema).
- `scripts/build.sh` succeeded.

## Needs owner / real device
- iCloud + CloudKit entitlement and container `iCloud.app.iBoard` are NOT added to `iBoard.entitlements` / Apple portal (CloudKit calls fail until then).
- Real two-device sync, iCloud Keychain key sharing, CloudKit schema deployment (record type `DeviceShard` auto-created in dev).
- Not wired to the personal model: the app syncs `LocalSyncFile` only. Follow-up for DATA/app owner: export the personal model into `SyncState` (increment/forget/setNeverCorrect, device id from `Keychain.deviceID()`) and apply `SyncOutcome.merged` back.
- Single shard per device; no splitting above ~1 MB yet; tombstone compaction not scheduled.

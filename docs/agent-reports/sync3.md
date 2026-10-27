# sync3 — iCloud sync hardening (M12-02/03)

Scope: `Packages/IBoardSync`, `Packages/IBoardPersonalSync` only. No keyboard, app, or ROADMAP changes. `swift test` passes in both packages (45 and 9 tests); `scripts/build.sh` and `scripts/audit-privacy.sh` (EXT-SYNC) pass.

## Code changes
- `SyncSharding.cost` underestimated shard size: it counted the device id once per slot, but the JSON writes it twice. This is a real bug that the new size test found. Fixed.
- `SyncCrypto(keys:)`: the first key seals and every key opens, which is needed for rotation.
- `SyncEngine.setCrypto(_:)` swaps the key. `SyncOutcome.keyMismatch` is set when shards exist but none decrypt.
- New `SyncKeyManager` (actor) with a `SyncKeychain` protocol and an `InMemoryKeychain` fake. It handles:
  - create-if-cloud-empty
  - refuse to auto-create when the cloud has data (`.keyMissingCloudHasData`)
  - rotate (keeps at most 2 previous keys)
  - retire old keys
  - `startOver()` (after total key loss)
  - `forgetKey()`
  - damaged keychain item treated as missing, not overwritten
  - keychain write failure leaves state unchanged
- The app does not use `SyncKeyManager` or `keyMismatch` yet (app target was out of scope).

## Proven by automated tests (simulated, in-memory cloud)
- Two and three devices with separate local state converge for several interleavings. Covered: concurrent offline counter edits, never-correct last-writer-wins, forget versus an older concurrent increment, and a later re-learn after a forget.
- Replaying a stale shard (an old CloudKit version) never regresses a device, and the next upload heals the cloud.
- Repeated sync is idempotent. At adapter level, nothing is double counted and the ledger stays stable.
- Every sealed shard is under 1,000,000 bytes, including 12k-key, 4-device, UUID-id worst cases. The shard count projected for `maxKeys` (200k) is under CloudKit's 400-records-per-batch limit. Record names are under 255 bytes.
- Oversized keys are rejected. Hostile or newer-schema shards are skipped. Quota and network errors surface and keep local state.
- Keys: sharing through one shared keychain item works. Key loss is detected, and start-over recovers. Rotation works across two devices: the old key stays readable, the new key re-encrypts on the next sync, and a device still holding the old key skips shards sealed with the new key without failing. The keyring size is bounded.
- Delete iCloud data:
  - it removes all shards of all devices, and sync then stays off with no traffic
  - a failed delete reports an error and can be retried
  - another still-enabled device re-uploads its own data afterwards (documented behaviour)
  - re-enabling converges without double counting

## NOT proven (needs real devices and iCloud)
- The real `CloudKitSyncStore`: zone creation, query consistency and latency, the real error mapping (quota, account change, zone not found), and real record size/batch behaviour.
- A production `SyncKeychain` implementation (synchronizable generic-password item) and real iCloud Keychain propagation delay to a second device. Both are still to be written in the app target.
- App wiring: calling `SyncKeyManager.prepare` and `rotate`, UI for key-missing and mismatch states, and the delete-confirmation flow.
- Behaviour on a different Apple ID, or when iCloud Keychain is off.

## Owner steps (two devices, same Apple ID, iCloud Keychain on)
1. Install the latest Debug build on both phones and enable iCloud sync on both. If the key-missing/mismatch UI has not been wired yet, ask the coordinator first.
2. Phone 1: type a rare word several times in a note. Tap Sync now. Phone 2: tap Sync now and check that its suggestions include the rare word.
3. Phone 2: forget that word in the app. Sync 2, then sync 1, and check it is gone on phone 1 and does not come back after more syncs.
4. Add a never-correct word on phone 1, sync both, and check it is honoured on phone 2.
5. Airplane-mode both phones, learn different words on each, then re-enable the network and sync both twice. Both should show both sets, with no inflated counts.
6. Settings > Delete iCloud data on phone 1. Check Settings > Apple ID > iCloud > Manage Storage for the iBoard container size, then sync phone 2 and check its data re-uploads.
7. Key loss (only once the app wiring exists): turn iCloud Keychain off on phone 2, reinstall, and enable sync. It should report the key as missing and offer "start over" rather than silently creating a new key.

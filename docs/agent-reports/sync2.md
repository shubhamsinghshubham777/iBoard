# SYNC2 report (M12-02, M12-03 follow-up)

## Built
- `Packages/IBoardEngine/.../Personal/PersonalSyncAdapter.swift` (new): `PersonalSyncAdapter.export` (model -> `SyncState`),
  `plan` (merged -> `PersonalOp`s), `run(store:engine:memory:)` (export, `SyncEngine.sync`, apply, in one call),
  `PersonalSyncLedger` / `PersonalSyncMemory` (persisted by the app; Codable).
  - Counters: keys `u:`/`b:`/`t:`/`p:` + normalised key; per-device slot = this device's own observations. The ledger
    (`lastSeen`, `own`, `appliedRemote`) separates local learning from counts folded in from other devices, so repeated syncs
    never double count. Keys over 128 bytes are skipped.
  - Forget: exported as a forget floor on `u:<word>` (and on this device's n-gram keys containing it); remote forgets apply
    `.forget`; n-grams containing a forgotten word are never re-applied.
  - Never-correct: LWW flags with tombstones both ways.
  - Edits to existing Engine files: only `Package.swift` (+ IBoardSync dependency).
- `Packages/IBoardSync`: `SyncSharding` (split by key into ~700 KB plaintext pieces, `shard-<device>-<n>`, leftovers from an
  earlier larger upload are blanked), `SyncEngine` uploads all pieces, `compacted(tombstonesOlderThan:)` now runs before
  upload (`tombstoneRetentionDays`, default 180). `SyncEngine.deviceID` is `nonisolated`. `SyncState` got an internal piece init.
- `iBoard/SyncSettingsView.swift`: placeholder replaced; sync now runs `PersonalSyncAdapter.run` against a `PersonalStore`
  opened on the App Group `personal/` directory; memory saved to `sync-memory.json` (complete file protection).
- `scripts/audit-privacy.allowlist`: reviewed entry for the adapter's memory file.

## Privacy check
Counter keys are the typed words (needed to apply other devices' counts), so they are only protected by encryption: shards are
AES-256-GCM sealed with the iCloud-Keychain key; record names hold device id and index only. Test
`shardContainsNoPlaintextWords` asserts no learned/forgotten/never-correct word (any case) appears in shard payload, record
name or device, that the plain state does contain them (test is meaningful), and that a wrong key cannot open it.

## Tests
- IBoardSync: 23 green (new: splitting, multi-shard round trip, shrink blanking, tombstone compaction).
- IBoardEngine `PersonalSyncAdapterTests`: 5 green (two-device convergence without double counting, forget propagation, never-correct
  add/remove, plaintext check, pruning stability).
- Build and `scripts/test.sh --no-ui`: see final status in the commit message / below.

## Limitations and risks
- Engine now depends on IBoardSync (pure Swift + CryptoKit; CloudKit file is `canImport`-guarded). The keyboard never calls it;
  confirm the extension binary does not grow (static dead-strip expected, not measured).
- Single-writer rule: the app opens its own `PersonalStore` on the App Group directory while the keyboard may also write.
  Mitigated by syncing only on user action in the foreground app; a proper hand-off (keyboard applies a queued op file) is a follow-up.
- Remote counts are folded in as one `.add` with weight capped at 20 (so `uses` understates large remote histories). Surfaces (casing)
  are not synced. Local un-forget is not propagated. Remote phrases/n-grams from pruned words are re-added only if the word is live.
- Compaction caveat from docs/SYNC.md applies: a device offline longer than the retention window must not merge stale flags.
- Still needs real iCloud: entitlement/container (owner), two-device test, CloudKit schema.

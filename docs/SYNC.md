# iCloud sync: merge model and record schema (M12-01)

Package `Packages/IBoardSync` (Swift 6, macOS + iOS, no dependencies: not CloudKit, not IBoardEngine). It is the pure
model the app-side sync engine (M12-02) will drive. The keyboard extension never syncs (no network, P-23); only the app
talks to CloudKit, and only when the user opts in.

## Model (`SyncState`, `schemaVersion = 1`)

A state-based CRDT: replicas exchange whole states (or shards) and call `merged(with:)`. Merge is commutative,
associative and idempotent, so duplicate, reordered or delayed deliveries converge.

| Part | Type | Merge |
|---|---|---|
| `counters[key][device]` | `CounterSlot { value, stamp }` | per (key, device): higher `(stamp, value)` wins |
| `forgetFloors[key]` | `SyncStamp` | max |
| `neverCorrect[key]` | `LWWFlag { present, stamp }` | higher stamp wins; exact tie -> tombstone |

`SyncStamp { time: UInt64 ms, device: String }` orders by time then device id (total order). Local mutators keep a
device's own stamps strictly increasing even under a stalled or backward clock.

- **Counters (per-device grow-only, merged by sum).** A key's value is `count(key)` = the sum of the live slots of all
  devices. Each device writes only its own slot, so two devices never conflict; merging replicas takes the newer slot per
  device (which, inside a forget epoch, is the larger value), so re-delivery never double-counts.
- **Forget.** Forget raises the key's floor above every slot the forgetting replica has seen. Slots with
  `stamp <= floor` are dead and dropped on merge. The floor only grows, so a stale replica can never resurrect the word, while
  learning stamped after the floor counts from zero. Learning on another device concurrent with (stamped before) the
  forget is forgotten too; that is the intended "forget wins over what existed" semantics.
- **Never-correct.** An LWW set: add and remove are both stamped flags; a removal is a tombstone retained so an older add
  cannot return. `compacted(tombstonesOlderThan:)` drops old tombstones; safe only after every device synced past the
  cutoff, otherwise a device offline longer than that must do a full resync rather than merge.
- Overflow saturates at `UInt64.max`.

Item keys are opaque strings (max 128 UTF-8 bytes). Because typed words are sensitive, M12-02 should either use CloudKit
encrypted fields (`CKRecord.encryptedValues`) or a per-account keyed hash of the word; this package does not care.

## Versioning and validation

`schemaVersion` is part of the encoded state. `SyncState.decode` rejects versions newer than supported
(`unsupportedVersion`), keys over 128 bytes or empty, more than 16 devices per key, and more than 200 000 keys per map.
Future versions must stay mergeable with older ones or bump the CloudKit record type name.

## Proposed CloudKit mapping (private database, custom zone `IBoardSync`)

To avoid write conflicts and stay under CloudKit record limits (1 MB), each device owns its records:

| Record type | recordName | Fields |
|---|---|---|
| `DeviceShard` | `shard-<deviceID>-<n>` | `schemaVersion` Int, `device` String, `payload` Bytes (JSON of a `SyncState` containing only that device's slots plus flags it authored, <= ~500 KB), `updatedAt` Date |
| `SharedFlags` | `flags-<deviceID>` | `payload` Bytes (floors and never-correct entries authored by that device) |

The app downloads all shards, merges them, and uploads only its own. Because merge is order-independent, change tokens
and retries need no ordering logic. Server record conflicts (same device on two installs) resolve by merging payloads.

## Tests

`swift test` in `Packages/IBoardSync`: 200 random multi-device histories (skewed/stalled clocks, mid-run merges) check
commutativity, associativity and idempotence; 100 histories check convergence under shuffled and duplicated delivery;
targeted tests cover sum merge, forget vs older/newer learning, stale-resurrection, LWW tombstones, clock monotonicity,
codable round-trip and validation.

## Not done here

CloudKit calls, shard splitting/size management, device-id provisioning, tombstone-compaction policy, key hashing/encryption, wiring to the
personal model (M12-02/M12-03).

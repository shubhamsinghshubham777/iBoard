# Personal model (M3-01, M3-02)

Code: `Packages/IBoardEngine/Sources/IBoardEngine/Personal/`. Tests: `Packages/IBoardEngine/Tests/IBoardEngineTests/Personal/`.

## 1. Store (M3-01)

`PersonalStore` is an actor holding a `PersonalModelState` (value type):

- unigram / bigram / trigram counts and a phrase table (3-6 word sequences), keyed by lowercased words joined with U+001F.
  Casing is remembered only where it matters (`surfaces`: "Shubham", "iPhone").
- forget list (word, time, deliberate-retype count; also a suppress list for base-lexicon suggestions) and a
  never-correct set.
- exponential decay, lazy: each entry stores `(weight, stamp, uses)`; effective weight = `weight * 0.5^((now-stamp)/halfLife)`,
  half-life 60 days (`PersonalStoreConfig.halfLifeDays`). The clock is injectable (`PersonalClock`).
  A new observation adds to the decayed value. `uses` is the undecayed lifetime count (drives the weight schedule).

### Persistence (designed for P-16)
- Every mutation is one `PersonalOp`; it is applied to memory and appended to `personal.journal` in a single short file
  operation (`FileHandle` opened, written, closed). One transaction = one append.
- When the journal passes 400 records / 128 KB (or a cap is exceeded) the store prunes, writes `personal.snapshot`
  atomically (temp + rename) with the last sequence number, then truncates the journal. Replay skips records with
  `seq <= snapshot seq`, so a crash between the two steps cannot double count.
- No handle, lock or transaction is held between calls and no store method suspends: nothing is open when the process is
  suspended. Single writer: the keyboard extension. The app should only read, or send edit commands to the keyboard.
- Snapshot format: `IBPS`, version, payload length, CRC32, little-endian binary payload (bounds-checked decoder).
  Journal: one line per record, `crc32hex SP json LF`.
- Recovery (`PersonalStore.recovery`): corrupt/truncated snapshot -> start from the journal; corrupt journal lines are
  skipped; a torn tail is detected; whenever anything was wrong a clean snapshot is rewritten at open so the next append
  cannot be poisoned. A read error disables persistence for the session instead of overwriting data.
- Write failures (e.g. App Group without Full Access) keep the in-memory model and increment `storageErrorCount`;
  they never throw into the typing path.

### Storage modes
`PersonalStorage` protocol; `FilePersonalStorage(directory:mode:)` and `InMemoryPersonalStorage` (tests).
`PersonalStorageFactory.make(hasFullAccess:localDirectory:appGroupDirectory:)` returns App Group storage only with Full
Access and an available group directory (P-23), otherwise extension-local, which always works.
`PersonalStorageFactory.migrate(from:to:)` copies the model as a fresh snapshot when the mode changes.
Open question for the app side: when Full Access is revoked, the App Group copy is no longer writable by the keyboard, so
the local copy becomes canonical and may diverge from the group copy.

### Caps and memory (P-21)
Defaults: 10k unigrams, 20k bigrams, 20k trigrams, 1k phrases, 2k forget, 2k never-correct. Over a cap the lowest
effective weight entries are evicted down to 90 % of the cap; entries decayed below 0.02 are dropped. At the caps the
state is estimated (key bytes + 64 B per entry) at well under 8 MB (a test asserts this estimate; it is NOT a measured
`phys_footprint`). `PersonalStoreStats.estimatedMemoryBytes` exposes it for the debug overlay.

### Scoring seam
`PersonalStore.scorer()` returns an immutable `PersonalScorer` (`PersonalScoreProvider`): `score(word:context:)` gives
`PersonalScore(probability, weight)` where probability is an interpolated uni/bi/tri estimate and `weight` (trust) grows with
personal data mass up to 0.4. The EngineActor combines it with the base LM using
`PersonalInterpolation.mix(baseLogProb:personal:)` = `log((1-w) * P_base + w * P_personal)`. The constants (0.4 cap, mass
300 for half trust) are untuned placeholders: NOT evaluated on any dataset. `completions(prefix:limit:)` is a linear scan
over the unigram table (not benchmarked).

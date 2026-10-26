# Personal model (M3-01, M3-02, M3-03, M3-06, M3-07)

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

## 2. Learning events and policy (M3-02)

Code: `LearningPolicy.swift` (field traits, incognito model, word filter, config) and `PersonalLearner.swift` (actor that
turns keyboard events into store writes).

### Policy (F4, D-10, F15)
- **Never learn** when: incognito is on (manual toggle) or auto-incognito applies; `isSecureTextEntry`; content type in
  {URL, emailAddress, username, password, newPassword, oneTimeCode, telephoneNumber, postalCode, cellularEID/IMEI,
  flightNumber, shipmentTrackingNumber, anything starting `creditCard`} (matched case-insensitively on the raw
  `UITextContentType` string); keyboard type in {URL, emailAddress, numberPad, decimalPad, phonePad, namePhonePad,
  asciiCapableNumberPad}. `FieldTraits.exclusion` gives the reason. Unknown content types are learnable.
- **Fail closed**: nothing is learned until the first `fieldDidChange`.
- **Word filter** (`LearnableWord.rejection`): 2-32 chars; no digit (any script), `@`, `/ : . \`, `www`-prefix, symbols or
  emoji; no camel-case noise (2+ lower-to-upper transitions; `iPhone`/`McDonald` are fine), no 4+ repeated characters, no
  hex-like 8+ letter strings, no 5+ letter vowel-less Latin strings. A rejected word is a **barrier**: it is not learned
  and no n-gram or phrase spans it.
- **Kept word**: committed, then the user types the next character (`typingContinued`), a next word commits, or
  `sentenceBoundary`/`flush`/`fieldDidChange` happens, without being reopened by backspace (`lastWordReopened`) or having
  its autocorrection reverted (`autocorrectReverted`). Revert drops the correction and learns the restored original as
  a deliberate word with increment 1.0.
- **Weights**: increments 0.3, 0.7, then 1.0 per observation (`LearningConfig.weightSchedule`), on top of decay.
  n-grams use the same increment; every kept word also records the 3-6 word phrases ending at it (same sentence, one
  journal transaction). A phrase counts as learned at `uses >= 2` (`repeatedPhrases`).
- **Casing**: surface kept for proper nouns / mid-sentence capitals / internal capitals; sentence-start capitals are not
  remembered.
- **Forget list**: `forgetSuggestion` removes the word and all n-grams/phrases containing it and records time. While
  forgotten, a word is not relearned (and is a barrier for context) unless 30 days passed, or it was typed deliberately
  (`.typed` or restored original) 3 times: counted in the forget entry, the 3rd learns and unforgets.
  Suggestion/autocorrect/swipe commits never count.
- **Incognito** (`IncognitoState`): `userToggle` or `fieldExclusion`; `indicator` is `.manual` / `.automatic(reason)` /
  `.off`. Switching incognito on discards pending words and cancels queued writes (epoch). Pending words are discarded
  on entering an excluded field, never deferred.

### Privacy
Words live only in the personal store (plus at most `sentenceWindow` = 8 transient in-memory words of the current
sentence). Nothing is logged; only counts are exposed. Typed words are never put in errors or stats.

### Integration notes / caveats
- The controller must supply the events above; mapping UIKit traits to `FieldTraits` and wiring `typingContinued` to the
  first non-backspace insert is not done here (NOT TESTED on device or in the keyboard extension).
- Reentrancy: `PersonalLearner` mutates tracking state synchronously and then awaits the store; events arriving during an
  await are ordered by the actor but write jobs may interleave with later events. Fine for counts; not asserted by tests.
- Never-correct: the store holds the list; automatic additions after reverts are NOT implemented (left to M2-05/M3-04).

## 3. Phrase model and smart wide chip (M3-03, D-13)

Code: `Personal/PhraseModel.swift`. `PersonalStore.phraseSuggester(config:baseLM:)` returns an immutable `PhraseSuggester`
(index of the phrase table built at creation; one pass over at most 1k phrases, NOT benchmarked).
`suggest(context:currentPrefix:)` -> `PhraseSuggestion?` for `Suggestions.phrase` (`.slot` has role `.phrase`).

- Match: the last k (1...5) sentence words equal the first k words of a table phrase; the rest (>= 2 words, shown up to
  `maxWords` = 4) is the continuation. One-word continuations are normal next-word prediction, never a chip.
- Confidence = lifetime uses(phrase) / lifetime uses(context k-gram) (uni/bi/tri/phrase tables; all count one per
  observation, unlike the 0.3/0.7/1.0 weight schedule). Optional base LM agreement (`PhraseBaseLanguageModel`, adapter
  `NGramPhraseBaseLM`) scales it by `(1 - 0.15) + 0.15 * agreement`; words unknown to the base LM count as 0.5.
- Gates (`PhraseConfig`, all UNTUNED placeholders, not evaluated on real data): confidence >= 0.6, uses >= 2, effective
  weight after decay >= 1.0, no forgotten word. Longest confident continuation wins, then confidence.
- A partially typed word (`currentPrefix`) must prefix the first continuation word.
- Chip semantics are data (`PhraseChipSemantics.standard`): tap = `.insertAllWords` (`tapText`), long-press =
  `.insertNextWordOnly` (`longPressText`). The controller must add the leading space and decide whether the strip slot
  widens; not wired into `EngineActor` here (that file is outside this task's scope).
- `PersonalStore` gained `currentTime` and `apply(ops:)` (used by import).

## 4. Adaptive touch model (M3-06, F14)

Code: `Personal/AdaptiveTouchModel.swift`. Value type `AdaptiveTouchModel`, owned by the keyboard controller (not a store actor).

- Input: `record(CommittedWordTouches, in: TouchModelContext)`; one `TouchSample` per letter = offset of the touch from the
  centre of the *intended* key (the committed word's letter), in key units. Accepted only if confidence >= 0.9, not
  corrected, not restored, >= 2 letters; per-axis outliers beyond 0.75 key sizes are dropped (mis-taps).
- State: per context (orientation x display class: `TouchModelContext`) and per letter: count, mean, covariance (EMA with
  rate `max(1/n, 0.02)`). Only aggregates are stored, never text or touch order.
- Output `keyModels(for:)`: `[KeyIdentity: KeySpatialModel]`; mean shrunk by `n/(n+12)` and clamped to +-0.3 key size; sigma
  blended with the 0.30 prior (`n/(n+60)`) and bounded to 0.18...0.42; keys with < 3 samples omitted. The covariance
  cross term is stored but the decoder's `KeySpatialModel` is diagonal, so it is unused today.
- **Decoder hook (no decoder edit needed):** `TapDecoderParameters.keyModels` already exists, so
  `var p = TapDecoderParameters(); adaptive.apply(to: &p, context: ctx); TapDecoder(layout:lexicon:model:parameters: p)`.
  The decoder is immutable, so the controller rebuilds it on a layout change or every N accepted words. Note the decoder's
  `literal` (nearest key) then also uses the shifted means.
- Reset: `reset(context)` / `resetAll()`; `AdaptiveTouchFileStore.delete()` removes the file.
- Persistence: JSON `{"version":1,"models":[...]}` (`AdaptiveTouchCodec`), <= 256 KB, validated and clamped on decode
  (unknown version, malformed, non-finite, bad keys), atomic file write, tolerant load (corrupt file = empty model).
- Evidence (synthetic only, `AdaptiveTouchModelTests`): sloppy typist (0.22 key low bias, side-dependent x bias, noise 0.27)
  raw key-error rate 9.0 % -> 4.7 % after ~1,800 letters (48 % relative reduction); neutral typist (noise 0.20)
  0.33 % -> 0.41 % (a small increase from estimation noise, asserted <= +0.2 pt absolute). NOT validated on real traces.

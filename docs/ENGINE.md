# IBoardEngine design note (M2-02, M2-03)

Package: `Packages/IBoardEngine`. Depends on `IBoardLayout` (key geometry) only; the test target also uses `IBoardCore` (`Perf`).
Format of the data files: `docs/LEXICON_FORMAT.md`.

## Readers (M2-02)

- `MappedFile` (internal): `mmap` PROT_READ / MAP_PRIVATE of the file (zero-copy, pages load lazily and are evictable, so
  they are clean memory against the P-21 ceiling), or a heap copy for `init(data:)`. Immutable, `@unchecked Sendable`.
- `Lexicon` (`.iblex`): `lookup`, `child(of:label:)` / `TrieCursor` for incremental walks, `wordID(at:)`,
  `logProbability(of:)` (`-q/2048`, no `exp`), `withUTF8(of:)` (zero-copy bytes), `word(of:)` (allocates),
  `completions(of:limit:scratch:into:)` (best-first over the trie using each node's `maxQ`; reuse the scratch and output
  array and it allocates nothing). Lookups read the mapping directly; callers pass NFC, lowercase text (no runtime
  normalization).
- `NGramModel` (`.iblm`): `unigramProbability`, `bigramProbability`, `trigramProbability`, `probability(_:context:)`,
  `logProbability`. Interpolated absolute discounting exactly as in the format doc; binary search per call.
- Validation on open: magic, version, endian marker, total size, section bounds and record sizes, and (optional,
  default on) the FNV-1a checksum. The checksum scan reads the whole file, so the keyboard should pass
  `verifyChecksum: false` for the signed bundle copy and keep it on for any downloaded or user-supplied file.
  An `NGramModel` also checks word count and lexicon checksum against its lexicon (`.lexiconMismatch`).

## Tap decoder (M2-03)

`TapDecoder(layout:lexicon:model:parameters:)`, `decode(points:context:)` or `decode(hits:layout:context:)`.

1. Spatial model: every letter key has an axis-aligned 2-D Gaussian over the touch offset in the key-normalized frame
   of `KeyHit.normalized` (default sigma 0.30 key sizes, zero mean; per-key mean and sigma overrides in
   `TapDecoderParameters.keyModels` are the seam for the personal touch model, F14). For each touch the best
   `maxKeysPerTouch` (4) keys within `keyWindow` (6 nats) of the best key survive.
2. Beam search through the lexicon trie, `beamWidth` 24 hypotheses. A hypothesis is a trie cursor plus its summed spatial
   log-likelihood; ranking uses spatial + `lmWeight` * (best unigram log-probability below the node), so words that can
   still become likely are not pruned early.
3. At the end each surviving word-ending hypothesis is scored `spatial + lmWeight * log P(word | context)` with the
   trigram/bigram/unigram LM (context = up to two previous word ids). The literal (nearest key per touch) is always
   scored too; if it is not a lexicon word it gets `oovLogProbability` (-14) instead of an LM term.
4. Same-length readings (including the literal) are normalised into a posterior. `autocorrect` is the best one when
   it is not the literal, and `autocorrectConfidence` is its posterior; the caller applies the threshold.
5. Completions of the top 3 beams (up to 6 each, `completionPenalty` 1 nat) are ranked into `candidates` with
   `isCompletion = true`; they are suggestions only.

Deterministic: no clocks or random numbers, ties are broken by key index, trie node, then word id. Immutable and
`Sendable`; each `decode` allocates a few small arrays (not yet allocation-free).

Edit-aware readings (engine-gap-3, `enableEdits`, default on): the beam is layered by touches consumed and each reading
may use ONE edit: adjacent transposition (touches k, k+1 swapped; `transpositionPenalty` 3 nats), an extra tap
(`insertionPenalty` 8) or a missing letter (`deletionPenalty` 8, never before the first touch or after the last: that is
a completion). Zero-edit hypotheses are pruned exactly as before (`beamWidth`), one-edit ones in their own
`editBeamWidth` (12) quota, repeats of (node, edits) are dropped, and a word reached both ways keeps its best score.
Edit readings join the same-length posterior, so `teh` -> `the` and `adn` -> `and` get autocorrect proposals with
posterior > 0.97, while deletion/insertion readings mostly show up as suggestions (their posterior rarely clears the
policy threshold). Penalties are untuned guesses. Synthetic eval after the change (noise-only typing, so no real
transpositions): precision 100 / 99.9 %, false-correction 0 %, recall 70.2 / 67.7 % at noise 0.25 / 0.35 (before:
70.5 / 68.4 %); the small recall loss is posterior mass moved to transposed readings. Release, macOS, 12k-word fixture:
decode p95 0.0054 ms -> 0.0208 ms per keystroke.

Scope and limits: decodes letter taps of a single word (letter keys of the layout, one Unicode scalar each);
apostrophes and other punctuation inside words, capitalisation and space-ending are not handled here; at most one edit
per word. The defaults (sigma, beam, penalties) are untuned guesses validated only on synthetic traces.

## EngineActor and strip model (M2-04)

`Sources/IBoardEngine/Actor/`. `EngineActor` is a Swift 6 actor owning `Lexicon`, `NGramModel` and `TapDecoder`; the keyboard
calls `beginRequest()` (nonisolated, any thread, a `Mutex` counter) per keystroke to get a sequence number, then
`await submit(EngineRequest)`. `submit` returns nil when the request was superseded, checked at the start and again after
the decode (a decode in progress is not interrupted). `invalidatePending()` drops everything in flight (field change,
cursor jump); `updateLayout(_:)` rebuilds the decoder after a resize / layer change.

`Suggestions`: up to 3 `SuggestionSlot`s in display order `[literal, best, alternative]` (literal is flagged `showsQuotes`
when it is out of vocabulary or about to be corrected; the UI centres `best`), `phrase` (reserved for the D-13 wide chip,
always nil now), and `autocorrect: AutocorrectProposal?` (word, posterior, whether the literal is itself a word).
`SuggestionSlot(text:role:showsQuotes:wordID:isCompletion:)` and `Suggestions(sequence:literal:slots:phrase:autocorrect:)`
(plus `Suggestions.empty(sequence:)`) are public with defaulted arguments, so UI code and its tests build them directly
instead of mirroring them. With no touches the actor predicts the next word (unigram candidates re-ranked by the n-gram model with the last two
words as context; real successor lists come with M3-02). Requests carry previous words only for the call; nothing typed is
stored or logged.

### Adaptive touch model in the engine (engine-gap-4)

`EngineActor.applyTouchModel(_ provider: (any TouchSpatialModelProvider)?, context: TouchModelContext?) -> Int`
(`AdaptiveTouchModel` conforms): the provider's per-key models for the context override the matching
`parameters.keyModels` of the base parameters and the decoder is rebuilt; the return value is the number of keys that got
a learned model (0 for a context with too few samples). `nil` restores the base parameters. The choice survives
`updateLayout(_:)`. The keyboard should call it after a learning batch or an orientation / display-class change, not per
keystroke. Synthetic check (constant 0.28-key bias, 300 trained words): summed log-score of the intended word 540 -> 1274
with the learned model; top-1 was already 100 % on both thanks to the LM, so this is not evidence of real-typing gain.

### Personal model in the engine (engine-gap-2)

Optional and injectable: `EngineActor(..., personal: (any PersonalScoreProvider)?, phrases: PhraseSuggester?)`,
`setPersonal(scorer:phrases:)` (nil removes it) and `refreshPersonal(from: PersonalStore, phraseConfig:)` (takes fresh
immutable snapshots; call it after learning batches, not per keystroke). Without it behaviour is unchanged.
- Typing: every decoder candidate's LM term is replaced by `PersonalInterpolation.mix(base, personal)` (OOV candidates use
  `oovLogProbability` as the base), forgotten words are dropped, up to 3 personal completions of the typed prefix are added
  (spatial term of the literal, completion penalty), the same-length posterior / autocorrect proposal is recomputed, a
  literal the personal model knows is not quoted and counts as `literalIsWord`, and a never-correct literal gets no proposal.
- Prediction (no touches): the 64 base unigrams are mixed with the personal score; personal top unigrams and bigram
  successors of the last word (`PersonalScoreProvider.successors(after:limit:)`, default empty, implemented by
  `PersonalScorer`) join the candidate pool.
- `Suggestions.phrase` = `PhraseSuggester.suggest(context: previousWords, currentPrefix: literal)?.slot`, so
  `EngineRequest.previousWords` should carry the words of the current sentence (up to 5 are used for phrases, 2 for the LM).
- Personal trust is tiny until real data accumulates (`PersonalInterpolation.trust`: 0.4 * mass / (mass + 300)); a handful
  of observations barely moves rankings. Untuned.
- Measured, macOS release, 10k unigrams + 10k bigrams: engine request p50 0.07 ms, p95 0.8 ms
  (`EnginePersonalBenchmarks`). Not a device number.

## Autocorrect policy (M2-05)

`Sources/IBoardEngine/Autocorrect/`. `AutocorrectPolicy.decide(...)` is pure. Corrects only when: autocorrection and
spell-checking traits are not `.no` (otherwise suggestions only), the word has >= 2 letters, is not on the never-correct
list, and the posterior is >= 0.97 (conservative; 0.90 balanced, 0.80 assertive), or >= 0.995 when the typed literal is
itself a valid word. `AutocorrectState` (value type, fake-clock friendly: `now` is an argument) tracks the last applied
correction: backspace right after it (within 30 s, no other input) returns a `TextEdit` restoring the original and
counts the restore; two restores (or choosing the quoted literal slot twice) put the word on the never-correct list.
The list is memory only; persisting it means persisting typed words, which is left to the opt-in personal-model work.

## Smart punctuation (M2-06)

`Sources/IBoardEngine/Punctuation/SmartPunctuation.swift`, pure functions over `(leftContext, traits, event)`: auto-cap
(`shouldAutocapitalize`: none / words / sentences / all characters; sentence ends `.!?…` plus closing quotes and
brackets, newline, document start, abbreviation / initials exceptions), `edit(forInserting:)` for double-space period,
smart quotes (open / close by position, apostrophes inside words are closing), and `--` to an em dash. Contractions:
`contraction(forWord:)` returns a suggestion and `isAutoApplicable` only for unambiguous forms (dont, im, thats...) at high
confidence; real-word collisions (ill, id, its, were, well, lets, wont, hes, shes) are suggestions only. All scanning is
over Characters, so emoji and combining marks are never split; `TextEdit.deleteBackward` counts Characters. The 500-char
left-context cap (P-24) is handled by treating a window without a terminator as "not a sentence start" (an empty context
is the document start). Locale quote styles beyond English are a `QuoteStyle` hook, untested.

## Eval harness (M2-07)

`Tests/IBoardEngineTests/Eval/AutocorrectEval.swift`: `EvalSet` (frequency-weighted words from the 219-word synthetic
fixture plus 500 random-syllable OOV names), Gaussian touch noise at 0.15 / 0.25 / 0.35 key sizes, `EvalScorer` (precision,
false-correction rate, recall) and a test that prints the report against the F2 targets (97% / 0.5%). SYNTHETIC: tiny
lexicon, decoder and generator share the same Gaussian model, so the numbers are optimistic regression guards, not
evidence for F2 acceptance on real typing. The test asserts only loose floors (precision >= 90%, false rate <= 2%).

## Code-switching: English + Hinglish (M7-02, M7-03)

Source: `CodeSwitch.swift`; data and licences: `docs/HINGLISH.md`. Everything is opt-in and backward compatible: without a
`SecondaryLanguage` (lexicon + optional LM) the decoders, `EngineActor` and `Suggestions` behave as before (the existing
189 tests pass unchanged).

- **Both lexicons searched.** `TapDecoder` runs the beam search once per lexicon (same touch evidence), `SwipeDecoder`
  walks both tries. Word ids are per lexicon, so `TapCandidate`, `SwipeCandidate` and `SuggestionSlot` carry a
  `side` (`.primary` English, `.secondary` Hinglish). A word present in both lexicons (`meeting`, `to`, `me`) is
  merged by text and keeps its better score; ties go to the primary side. Completions come from both sides.
- **Language-context score.** `CodeSwitch.context` turns the previous words into log-odds of the second language:
  a word found in only one lexicon is evidence for it (+/- `tokenEvidence` 1.1 nats, decayed 0.65 per step over the last 4
  words), words in both or neither are neutral; the personal model adds a lean (`CodeSwitch.personalBias`: the
  usage-weighted share of its 400 top words found only in one lexicon, shrunk toward 50/50, capped at 1.5 nats; computed once
  per `setPersonal`, nothing typed is stored). The odds, capped at +/-3, become a log-prior `log P(side | context)` that is
  added to every candidate's LM term (weighted by `lmWeight * priorWeight`). Each side also uses its own n-gram context
  (ids of the previous words in that lexicon). Words in neither lexicon (out-of-vocabulary literals) are charged the
  more likely side's prior, so the literal is not penalised for language.
- **M7-03 protection.** A typed word that is a valid secondary-lexicon word is never auto-corrected into a word that exists
  only in the primary lexicon: `TapDecodeResult.autocorrect` is nil and `literalProtected` is true (also in the
  `EngineActor` personal blend). The strip still lists the English word as a suggestion; corrections into Hinglish words
  and corrections of non-words are unaffected; `CodeSwitchParameters.protectSecondaryWords = false` turns it off. Consequence
  to know: short Hinglish forms that are also typos of English words (`ne`, `ho`, `ka`) are never rewritten to English.
- **Literal always listed.** When the candidate list is cut at `maxCandidates`, the literal now replaces the last entry if it
  would have fallen off (before, a valid but low-scoring literal could vanish and the caller then saw an unknown word).
  Single-language output changes only in that edge case.
- **Not done / caveats.** `EngineHost` and the keyboard do not load the Hinglish artifacts yet. The 64-word next-word
  prediction pool is per lexicon, as before. Calibration across languages is by the prior only: each lexicon is normalised
  on its own and a side with a known context is scored by its n-grams while the other falls back to unigrams, so
  weights (`tokenEvidence`, `priorWeight`) need tuning on the M7-04 eval set; the numbers here are not accuracy evidence.
- **Latency** (macOS release, `DualBenchmarks`, English proxy = 150k synthetic pseudo-words + real 56k-word Hinglish
  lexicon + LMs, 0.3 key-size noise): tap keystroke p95 0.033 ms dual vs 0.016 ms English only (budget 25 ms); swipe lift to
  candidate p95 0.87 ms dual vs 0.60 ms (budget 60 ms), adversarial 10-15 key wander p95 1.5 ms. With the 12k bench fixture:
  0.027 / 0.40 / 0.54 ms. A real English lexicon and an iPhone 12 were not available: host numbers only.

## Measured (macOS host, Apple Silicon, not a device)

See the M2-02 / M2-03 progress-log entries for numbers. Benchmarks are in `ReaderBenchmarks` and
`TapDecoderBenchmarks`; run `swift test -c release` in `Packages/IBoardEngine` (optionally with
`IBOARD_BENCH_DIR` pointing at lexicon-builder output for a larger lexicon). Fixtures: `Tests/IBoardEngineTests/Fixtures/README.md`.

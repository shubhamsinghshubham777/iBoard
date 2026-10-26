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

Scope and limits: decodes letter taps of a single word (letter keys of the layout, one Unicode scalar each);
apostrophes and other punctuation inside words, capitalisation, space-ending and transposition errors are not handled
here. The defaults (sigma, beam, penalties) are untuned guesses validated only on synthetic traces.

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

## Measured (macOS host, Apple Silicon, not a device)

See the M2-02 / M2-03 progress-log entries for numbers. Benchmarks are in `ReaderBenchmarks` and
`TapDecoderBenchmarks`; run `swift test -c release` in `Packages/IBoardEngine` (optionally with
`IBOARD_BENCH_DIR` pointing at lexicon-builder output for a larger lexicon). Fixtures: `Tests/IBoardEngineTests/Fixtures/README.md`.

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

## Measured (macOS host, Apple Silicon, not a device)

See the M2-02 / M2-03 progress-log entries for numbers. Benchmarks are in `ReaderBenchmarks` and
`TapDecoderBenchmarks`; run `swift test -c release` in `Packages/IBoardEngine` (optionally with
`IBOARD_BENCH_DIR` pointing at lexicon-builder output for a larger lexicon). Fixtures: `Tests/IBoardEngineTests/Fixtures/README.md`.

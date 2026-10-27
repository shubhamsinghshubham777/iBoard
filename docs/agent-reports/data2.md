# DATA2 report (swipe accuracy on Hinglish, M7-04 / M4-04)

All numbers are SYNTHETIC traces (generator and decoder by the same author) over the REAL English + Hinglish lexicons,
macOS host, debug build for accuracy. `swift test` in Packages/IBoardEngine: 249 tests pass. `scripts/build.sh`: succeeded.

## Diagnosis
Failure dump (`IBOARD_TUNE_FAIL=1`) showed the misses were language-model vetoes, not spatial errors. The Hinglish
trigram/bigram backoff is extremely sharp: `ghar` has unigram -5.3 but scores -19.8 after "bhai tu" (seen context, unseen
continuation); `kar` -18.7 after "mera phone". English look-alikes (`ghat`, `nazi`, `ai`) kept unigram-level scores and won.
Lexicon frequencies, variant clusters and the language prior were not the main cause (prior weight 0 -> 2 moved top-1 only
about 1-3 points).

## Changes
- `SwipeParameters.lmUnigramMix` (default 0.3): contextual probability is interpolated with the unigram before scoring
  (`SwipeDecoder.baseLog`), so an unseen continuation cannot veto a clean swipe.
- `lmWeight` default 1.0 -> 0.5 (spatial evidence dominated more; context still breaks ties).
- `CodeSwitchTests.languageContextReordersAmbiguousSwipes`: threshold scaled by `lmWeight` (it is a magnitude check; ordering unchanged).
- Tuning harness `Tests/.../Swipe/SwipeTuningTests.swift`: sentences split by index parity, even = TUNING, odd = HELD-OUT;
  sweeps (opt-in `IBOARD_TUNE=1`) pick parameters on the tuning half only. Plateau reached; other params
  (shapeSigma, locationSigma, anchorWeight, priorWeight, tokenEvidence) changed < 1 point and were left alone.

## Before / after (2 traces per word per profile, 3 profiles)
| set | top-1 before | top-1 after | top-3 before | top-3 after |
|---|---|---|---|---|
| TUNE half (308 words) | 87.07 | 92.37 | 94.97 | 98.05 |
| HELD-OUT half (337 words) | 86.50 | 94.56 | 96.93 | 98.62 |
| Hinglish-only words, tune / held | 85.85 / 85.52 | 91.54 / 94.98 | | |

Full M7-04 swipe eval (645 words, one trace each):
- careful: 89.8 -> 95.5 top-1, 98.4 -> 99.7 top-3 (meets F3)
- normal: 88.1 -> 94.4, 96.9 -> 99.1 (meets F3)
- sloppy: 82.8 -> 89.5, 92.7 -> 96.3 (still just BELOW 90 / 97)

English regression (real English lexicon, top-5000 words, 1500 traces, no secondary): top-1 93.5 -> 95.1, top-3 99.1 -> 99.0,
confident-wrong 17 -> 4. New test `englishRegression` guards against a drop of more than 1 point. The synthetic small /
bench fixture tests pass unchanged.

## Budgets
Release `SwipeBenchmarks` (bench fixture, 12k words): lift-to-top-candidate p50 0.015 ms, p95 0.063 ms; adversarial wander
p50 0.052 ms, p95 0.22 ms. The change adds one unigram lookup per scored candidate; no memory impact. Not measured on a device.

## Trace recorder format + loader (M4-04, no UI)
- `Sources/IBoardEngine/Swipe/SwipeTrace.swift`: `SwipeTrace` (Codable v1: word, up to 2 previous words, container size,
  `[x,y,t]` points, source, layout), `validate()`, `swipePoints(scaledTo:)`, and `SwipeTraceFile` (`encode`, strict/lenient
  `decode`, `load`, `loadDirectory`) for `.jsonl` (one trace per line, `#` comments).
- `Fixtures/traces/` (README only) is where owner-consented files go; `SwipeTraceTests.realTracesReplay` scores them against
  the real lexicons and prints top-1/top-3. Tests cover round trip, validation, lenient skipping, replay equivalence.
- Traces contain typed text: record only with explicit consent, never from normal typing, and record the licence beside the data.

## Caveats / next
- Synthetic traces only; F3 on real fingers is still unproven (needs real traces for M4-04). Held-out half shares the
  author, generator and lexicons with the tuning half, so the held-out gain is a split check, not independent evidence.
- Sloppy profile is still under target; more gains likely need real-trace-driven path-model changes.
- Possible LM-side follow-up: the Hinglish bigram/trigram backoff weights in the lexicon builder are over-sharp; the typing
  and next-word paths may benefit from the same smoothing (not touched here).

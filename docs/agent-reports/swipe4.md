# SWIPE4: tuning on 201 real iPhone 12 traces (M4-04, F3)

Data: `Fixtures/traces/owner-iphone12.jsonl` (one person, one device, 201 swipes; untouched). Split is deterministic by trace
index: even = TRAIN (101, tuning allowed), odd = HELD-OUT (100, report only). Tool: opt-in
`Swipe/SwipeRealTraceAnalysisTests.swift` (`IBOARD_TRACE=v` prints every miss, `IBOARD_P="name=val,..."` overrides
parameters, `IBOARD_SYNTH=1` also prints the synthetic per-profile report).

## Real results (top-1 / top-3 %, confident-wrong)

| | before | after |
|---|---|---|
| all 201 | 92.0 / 93.5 (8) | 95.0 / 98.0 (4) |
| TRAIN 101 | 92.1 / 93.1 (5) | 94.1 / 97.0 (3) |
| HELD-OUT 100 | 92.0 / 94.0 (3) | 96.0 / 99.0 (1) |

F3 (top-1 >= 90, top-3 >= 97) is met on this owner/device, on both halves.

## Failure analysis (13 misses before the change, each one examined)

| class | n | cases |
|---|---|---|
| Lift-off / touch-down overshoot beyond the old 1.0-key end/start radius (end key 1.05-1.11 keys away), so the word was never a candidate | 6 (4 of them in "with", "then", "their", "and", "about") | with x2, then, their, and, about |
| Wider corridor needed (path wandered ~1.1-1.3 keys from a letter) | 3 | because x2, chalo |
| Look-alike / in list but ranked low | 1 | have (rank 4 behind gave) - still missed |
| Word not in lexicon: owner typed `dhanyavaad`, lexicon has `dhanyavad` | 3 | dhanyavaad x3 (identical in all runs) |
| Letter skipped by the finger (path never reaches `a` in "thanks") | 1 | thanks |

Not causes: a systematic touch offset (mean start/end offset over all 402 endpoints is dx +0.03, dy +0.06 key, i.e. none, so no
offset correction was added), case/apostrophes (none), speed/corner detection (anchors present in every miss, no sweep gain).
Counts overlap slightly because some words had more than one contributing cause; the first-listed dominant cause is used.

## Changes (SwipeParameters / SwipeDecoder only)
1. `endRadius` 1.0 -> 1.3 and `corridorRadius` 1.1 -> 1.3: admit words whose first/last key the finger overshot. Alone this costs
   1-3 points of synthetic top-1 (more look-alike competitors), so:
2. New `endpointWeight` (default 2.0, `endpointTolerance` 0.5, `endpointSigma` 0.5 key): a direct Gaussian-style penalty on
   the distance between the gesture's first/last point and the candidate's first/last key centre beyond a free 0.5 key. The
   existing location channel averages over 48 points so it diluted the two most reliable pieces of evidence. This is the
   principled fix and it more than recovers the synthetic loss. Weight 1 to 4 and tolerance 0.3 to 0.7 all sit on a plateau
   (train top-3 97.0 throughout); 2.0 / 0.5 / 0.5 was picked on TRAIN and not tuned further.
Swept and rejected (no train gain or worse): `lmWeight` 0.3/0.5, `locationTolerance` 0.5, `locationSigma` 0.4. `anchorWeight`
0.25 gave +1 train top-1 only; left alone (noise).
`SwipeDecoderTests.candidateEndsMatchThePathEnds` hard-coded radius 1.0; it now reads `SwipeParameters().endRadius`.

## Synthetic regression (SWIPE3 per-profile report, top-1/top-3)
| set | profile | SWIPE3 | now |
|---|---|---|---|
| English | careful | 97.8/100.0 | 97.8/100.0 |
| English | normal | 96.2/99.8 | 96.8/99.5 |
| English | sloppy | 92.8/97.5 | 95.0/99.2 |
| Hinglish | careful | 96.0/100.0 | 96.0/100.0 |
| Hinglish | normal | 95.2/99.5 | 95.8/99.7 |
| Hinglish | sloppy | 92.4/97.7 | 93.2/98.9 |
Fixtures (all profiles): small 98.9/99.9 (was 97.3/99.9), bench 99.2/99.9 (was 98.3/99.9). English normal top-3 -0.3 is noise.
Decode latency (bench fixture, 12k words): p50 2.5 ms, p95 9.1 ms, adversarial p95 21.9 ms (wider corridor does not blow the
budget). Engine `swift test`: 254 tests pass. `scripts/build.sh`: BUILD SUCCEEDED.

## Honest limits
- One person, one phone, 201 swipes, mostly high-frequency English plus some Hinglish; 100 held-out swipes means +/-1 swipe is
  1 point. The held-out number (96.0/99.0) is higher than train partly by luck of the split; treat ~95/98 combined as the
  estimate, with an interval of several points. Not validated on other hands, thumbs-vs-index, or other devices/layout heights.
- 5 swipes still miss: 3 are a lexicon spelling variant (`dhanyavaad`; add the variant to the Hinglish lexicon, which is
  outside this task's file ownership), 1 skipped letter, 1 look-alike. A trace never decoded as top-3 for lack of a lexicon word
  cannot be fixed by the decoder.
- The `endpoint*` weights were chosen on the same 101 train traces plus the synthetic suites; they are a few-parameter change on
  a flat plateau, but a larger, multi-user set is needed before calling them final.
- Confident-wrong remains 4/201 (the three `dhanyavaad` plus `thanks`, posterior ~1.0): the UI should not auto-commit on
  confidence alone for out-of-lexicon words.

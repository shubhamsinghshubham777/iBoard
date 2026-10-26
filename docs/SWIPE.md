# Swipe decoder (M4-02) and synthetic eval (M4-04)

Code: `Packages/IBoardEngine/Sources/IBoardEngine/Swipe/`. Tests: `Tests/IBoardEngineTests/Swipe/`.
Feature spec and targets: ROADMAP F3 (top-1 >= 90 %, top-3 >= 97 %, >= 95 % top-1 for personal words); budget section 6
(swipe lift to top candidate p95 <= 60 ms on iPhone 12).

## API

`SwipeDecoder(layout:lexicon:model:personal:parameters:)`, then
`decode(points: [SwipePoint], context: LMContext, contextWords: [String]) -> SwipeDecodeResult`.
`SwipePoint` is `(x, y, t)` in the layout's container coordinates (t in seconds, 0 if unknown). The result has ranked
`candidates` (word, wordID, score, spatial, language, usedPersonal), `confidence` (posterior of the top candidate among
all scored), `margin` (top minus runner-up posterior), diagnostics (`scoredCount`, `nodesVisited`, `truncated`,
`anchorCount`) and `isSwipe` (false when the path is shorter than 1 key width: the caller treats it as a tap).
The decoder is immutable, `Sendable` and deterministic (no clocks, randomness or hash order; ties by word id).
Rebuild it when the layout changes (like `TapDecoder`).

## Algorithm (SHARK2-style)

1. Convert the path to the key frame (x / mean key width, y / mean key height; 1 unit is about one key) and resample to
   equidistant points (48 for scoring, 96 for corridor tests).
2. Walk the lexicon trie, pruned to words whose first / last letter key is within 1.0 key of the path start / end and
   whose every letter key lies within `corridorRadius` (1.1 key) of the path, in path order (each letter must be reached
   at or after the previous one). Repeated letters share one key visit. Words with fewer than 2 distinct keys are not
   swipe candidates. `maxNodeVisits` (60 000) bounds the work; `truncated` reports a cut.
3. Template per candidate: the polyline through its letter-key centres in the CURRENT `KeyboardLayout`, resampled the
   same way. No per-layout tables exist, so split, Duo inner / outer and resized layouts work unchanged; a swipe across
   the centre gap is just a longer segment (covered by a test on a `duoInner` landscape layout).
4. Two channels (SHARK2): shape = mean point distance after centroid + scale normalization (position and size free);
   location = mean point distance beyond a 0.45 key tolerance (absolute position matters). Dwell points (slow runs,
   needs timestamps) and corners (turns >= 55 degrees) add an anchor penalty when no letter of the word is near them.
   `spatial = -0.5 * ((shape/0.09)^2 + (location/0.35)^2 + 0.5 * sum((min(d,1.5)/0.6)^2))`.
5. `score = spatial + lmWeight * log P(word | context)`. Personal model: the 64 best base-scored candidates are re-scored
   with `PersonalInterpolation.mix(base, personal.score(word:context:))`; forgotten words are dropped; personal words
   not in the lexicon are added (up to 24 per allowed first letter via `completions(prefix:limit:)`) with the
   `oovLogProbability` base. This reads `PersonalScoreProvider` only; the decoder never stores or logs words or paths.

All constants live in `SwipeParameters` and are untuned guesses checked only on synthetic traces (the corridor radius was
widened from 0.9 to 1.1 after the first synthetic run, a mild tune against the same generator it is evaluated on).

## Latency (macOS host, Apple Silicon, release; NOT a device number)

`swift test -c release --filter SwipeBenchmarks` (optionally `IBOARD_BENCH_DIR` for a bigger lexicon):

| Scenario | p50 | p95 |
|---|---|---|
| 12k-word bench fixture, frequency-weighted real words (62 trie nodes, 2 templates per decode on average) | 0.013 ms | 0.043 ms |
| same fixture, adversarial random 10-15 key wander | 0.046 ms | 0.148 ms |
| 60k-word synthetic lexicon (535 nodes, 26 templates on average) | 0.031 ms | 0.358 ms |
| 60k-word synthetic lexicon, adversarial wander | 0.087 ms | 0.413 ms |

Debug build, 12k fixture: p95 3.1 ms typical, 8.3 ms adversarial. All are far below the 60 ms budget, but the lexicons
are synthetic (random syllables), far smaller and less prefix-dense than a real 100k+ word English / Hinglish lexicon, and
the macOS host is faster than an iPhone 12. Not measured: a real lexicon, device latency, the personal model with a large
dictionary (`PersonalScorer.completions` scans every personal unigram per call; the decoder calls it once per allowed
first letter, so this may need a prefix index when personal dictionaries are large).

## Synthetic eval (M4-04)

Generator (`SwipeSynth`, test target only): waypoints at the word's key centres with Gaussian jitter (0.12 / 0.22 / 0.32
key sizes for careful / normal / sloppy), overshoot at turns, corner cutting, a smooth random-walk speed profile, random
dwells, 60 Hz timestamps with jitter and 0.03 key sample noise, all seeded (SplitMix64). Scorer (`SwipeScore`): top-1 /
top-3 / truth-in-list / confident-wrong. Test targets are frequency-weighted words of 3+ letters.

Measured (release, seeded, reproducible; every line printed as `SYNTHETIC ...`):

| Set | careful top-1 / top-3 | normal | sloppy | all profiles |
|---|---|---|---|---|
| small fixture, 219 words, 1 800 traces | 99.0 / 100 | 98.2 / 99.8 | 95.2 / 98.0 | 97.4 / 99.3 |
| bench fixture, 12k words, targets = 200 real words, 1 200 traces | 99.8 / 100 | 99.2 / 100 | 96.2 / 98.2 | 98.4 / 99.4 |
| small fixture on a `duoInner` landscape layout, 900 traces | 99.0 / 100 | 98.3 / 100 | 93.7 / 96.7 | 97.0 / 98.9 |

Against the F3 targets (90 % / 97 %): the synthetic numbers meet both targets for the all-profile mix and for the careful
and normal profiles on all three sets, and for sloppy top-1; sloppy top-3 meets 97 % on the small and bench sets (98.0,
98.2) and narrowly misses it on the Duo layout (96.7). THESE DO NOT PROVE REAL ACCURACY. Generator and decoder share the same idea of a swipe (paths
through key centres), the lexicons are tiny and synthetic, there is no real finger bias, hesitation, palm drift, one-handed
reach, repeated-letter or out-of-vocabulary behaviour, and no recorded traces exist yet. The F3 acceptance numbers still
need a recorded-trace set from real users (M4-04's "recorded" half, device work) and the personal-word target (>= 95 %)
is untested beyond a unit test that the personal model can boost, add and forget words.

Tests assert only loose floors (small >= 75 % / 88 %, bench >= 60 % / 80 %, Duo >= 70 %).

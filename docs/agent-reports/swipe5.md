# swipe5: contractions in swipe typing

Problem: `SwipeDecoder` walked the trie one letter key at a time, so words with an apostrophe (i'll, didn't, it's) were unreachable.

## Change (Packages/IBoardEngine/Sources/IBoardEngine/Swipe)
- `Search.visit`: at every cursor, an apostrophe child (' or U+2019) is descended through at zero cost, zero width, no path vertex, same corridor position and depth (so mid-word didn't / i'll work; maxLength counts letters only). An apostrophe edge never ends a word by itself. Each hop counts as a node visit (budget honoured).
- `vertices(for:)` (personal OOV path) skips apostrophe scalars.
- Surface form comes from the lexicon, so it keeps the apostrophe. Path, template and spatial scoring use letters only. Dedupe: contraction and plain word (its / it's) are different lexicon ids with the same vertices, both candidates, ranked by LM; the dual-language dedupe is by surface word, unchanged.
- Hinglish secondary: same search code runs per language; Hinglish words have no apostrophes in practice, no behaviour change.
- New `SwipeParameters.contractionPenalty = 0.5` (log-score charge on any word that traversed an apostrophe). Justification: without it, real traces regressed from top-1 95.0 to 93.5 (3x "want" -> "wasn't", whose path is almost the same and whose unigram is higher). Sweep 0 / 0.5 / 1 / 1.5 / 2 / 3: 0.5 is the smallest value restoring 95.0, and costs about 1 point of normal-profile contraction top-1 (90 -> 89); larger values hurt contractions badly (2.0 -> 67%). No other special-casing: ill / i'll, its / it's, well / we'll, were / we're are left to the LM and context.
- Lexicon check (real English): all of i'll, didn't, shouldn't, don't, can't, it's, we're, i'm, isn't, that's, you're, they're, wouldn't, i've, let's, he's, what's, doesn't, won't exist with log-prob > -14 (from contractions.tsv). Data/ not touched.

## Hit rates (19 contractions, apostrophe-less key paths, real English LM)
- Before: 0% top-1 / 0% top-3 (unreachable by construction).
- After, centre swipes: all in top-3; didn't, shouldn't, don't, can't, wouldn't, isn't, doesn't top-1 (asserted).
- After, 190 noisy synthetic "normal" traces (10 per word, seed 11): top-1 88.9%, top-3 100%.
- Owner traces (201, no contractions in the set): top-1 95.0, top-3 98.0 (unchanged). Existing synthetic suites pass (259 tests). `scripts/build.sh` succeeds.

## Tests
`Tests/IBoardEngineTests/Swipe/SwipeContractionTests.swift`; `SwipeSynth.trace` now skips apostrophes in the target word.

## What real contraction traces would add
The synthetic generator shares the decoder's idea of a swipe, and the 0.5 penalty is tuned only on non-contraction traces; real contraction swipes would tune it for real and expose ambiguous-pair errors. Recommended prompt words (~40, ambiguous pairs first, in this order; record each plain and contracted member, with a sentence prefix where noted):
ill / i'll, its / it's, well / we'll, were / we're, wed / we'd, hell / he'll, shell / she'll, id / i'd, cant / can't, wont / won't, dont / don't, isnt / isn't, wasnt / wasn't (also "want"), lets / let's, thats / that's, whats / what's, youre / you're, theyre / they're;
then unambiguous: didn't, doesn't, shouldn't, wouldn't, couldn't, haven't, i'm, i've, you've, there's.
Suggested context: "i'll", "it's", "we're", "don't" after a pronoun or verb ("I ...", "think ...") and the plain word in a sentence where it is the right reading ("its" after "wagging", "were" after "they").

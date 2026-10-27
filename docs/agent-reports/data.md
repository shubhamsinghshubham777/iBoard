# DATA agent report (M7-04, M3-05, M2-07/M4-04 data)

Branch: `worktree-agent-af4ce8dc6469469f1`. All numbers below were measured with `swift test` in `Packages/IBoardEngine`
on the macOS host (debug build). Full package: 241 tests passed.

## M7-04 Hinglish eval set: [~] (built and scored; F2/F3 targets NOT all met)
- Lexicons are the REAL ones (`Data/english` + `Data/hinglish` as secondary). Text is a held-out set of 141 author-written
  code-switched sentences (`Fixtures/eval/hinglish_mixed.txt`, CC0), checked by a test to share no exact sentence with
  the Hinglish training phrases. 764 distinct words: 482 Hinglish-only, 246 in both lexicons, 17 English-only, 19 in neither.
  Touches are SYNTHETIC (Gaussian tap noise, synthetic swipe traces), so the finger side is optimistic.
- Tap/autocorrect (each word typed 10 times, 7,700 typings per noise level), F2 targets: precision >= 97%, false-correction <= 0.5%:
  - noise 0.25 key sizes: 682 typos, 394 applied, precision 99.49%, false-correction 0.01%, auto-fix recall 57.5%
  - noise 0.35: 2,957 typos, 1,442 applied, precision 99.38%, false-correction 0.04%, recall 48.5%
  - noise 0.15: only 1 typo in 7,700, so no information.
  - Words in neither lexicon (19 distinct) at noise 0.35: 2 wrongly "corrected" of 96 typos (1.06% false-correction on that
    subset, small n); the overall rate stays under target.
- Swipe (640 in-vocabulary words of >= 3 letters, one trace each per profile), F3 targets: top-1 >= 90%, top-3 >= 97%:
  - careful: top-1 89.8% (BELOW), top-3 98.4% (meets)
  - normal: top-1 88.1% (BELOW), top-3 96.9% (BELOW)
  - sloppy: top-1 82.8% (BELOW), top-3 92.7% (BELOW)
  - Hinglish-only words are weaker than words in both lexicons (sloppy: 82.1% vs 89.8% top-1 in the first run). Numbers shift by about 1 point
    between runs of the same set because five sentences were reworded, so treat one decimal as noise.
- Caveats: set is small and written by the project author; English-only words are few (17), so mixed sentences are mostly
  Hinglish. Test floors are loose regression floors (precision >= 85%, false-correction <= 3%, swipe top-1 >= 50%, top-3 >= 70%),
  not the F2/F3 claim; the printout labels each line meets/BELOW.
- Missing: real (non-synthetic) touches and swipes, and a larger consented set of real chat text.

## M3-05 UILexicon import: engine side done, keyboard wiring missing -> [~]
- New `Packages/IBoardEngine/Sources/IBoardEngine/Personal/SystemLexicon.swift`: `SystemLexiconEntry`, protocol
  `SystemLexiconSource` (async `entries()`), `SystemLexiconSnapshot` (classifies names vs Text Replacements, `expansion(for:)`,
  `names(withPrefix:)`, caps 5,000 names / 2,000 replacements, order-independent FNV-1a fingerprint), and actor
  `SystemLexiconImporter`: `refresh()` digests the entries and does nothing else when the fingerprint is unchanged; new
  contact names are seeded once into `PersonalStore` (increment 2) so they are offered and not autocorrected away.
- 6 tests (`Personal/SystemLexiconTests.swift`) cover classification, fingerprint, caps, unchanged refresh, add/remove,
  persisted-fingerprint restart, empty source. Refresh cost was not timed on a device.
- Keyboard-side wiring needed (not done, KEYBOARD agent): an adapter `struct UILexiconSource: SystemLexiconSource` that
  maps `UILexicon.entries` (`userInput`, `documentText`) from `requestSupplementaryLexicon` (call on `viewDidLoad`, then
  `await importer.refresh()`); persist `fingerprint` (an integer) in the extension-local defaults and pass it as
  `previousFingerprint`; on typing, check `snapshot.expansion(for:)` when space is pressed to offer the expansion as a chip
  or replace (policy for auto-replace is the keyboard's call); optionally `names(withPrefix:)` for completions. Whether
  `UILexicon` returns Contacts names without Full Access was not tested on a device.

## M2-07 real misspellings: [~] improved, F2 still not demonstrated on real finger typing
- New `Data/testsets/en_misspellings.tsv` (4,529 real misspelling to correction pairs from Wikipedia's Lists of common
  misspellings, CC BY-SA 4.0, `Data/testsets/LICENSE.md`, generator `Tools/TypoData/fetch_misspellings.py`), evaluated in
  `Eval/RealMisspellingEval.swift` against the real English lexicon + LM with real Hinglish as secondary, typed at key centres.
- 4,469 usable pairs: auto-applied 82, precision 100.00% (82/82), auto-fix recall 1.8%, the engine's top proposal equals
  the correction 8.5% (before the policy), the correction is in the top 3 strip slots 63.2%. Control (the 4,469 correct
  words typed exactly): false-correction 0.000% (0).
- Reading: the policy is very conservative on real spelling errors (they are often 2+ edits from the target); precision
  and false-correction meet F2 but recall is low. These are spelling errors, not finger slips, and have no sentence context.

## M4-04 real swipe traces: not done
- No licence-clean recorded swipe data was found or collected (public gesture-typing datasets are research-licensed or
  of unclear terms, so none were vendored). The Hinglish swipe numbers above remain synthetic. A real set needs consented
  recordings from the owner (a recorder in the app) and is the missing piece for F3.

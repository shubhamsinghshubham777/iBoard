# Data/testsets

Evaluation data only. It is never bundled in the app or keyboard.

| File | Source | Licence |
|------|--------|---------|
| `en_misspellings.tsv` | Wikipedia, "Lists of common misspellings" (pages A to Z), https://en.wikipedia.org/wiki/Wikipedia:Lists_of_common_misspellings, fetched 2026-10-27 with `Tools/TypoData/fetch_misspellings.py` (unambiguous single-correction ASCII pairs only) | CC BY-SA 4.0 (Wikipedia text, contributors listed in the page histories) |

The Hinglish mixed-sentence eval set lives next to its tests
(`Packages/IBoardEngine/Tests/IBoardEngineTests/Fixtures/eval/hinglish_mixed.txt`), authored by the iBoard project, CC0-1.0.

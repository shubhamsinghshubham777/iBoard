# LexiconBuilder

macOS-only SwiftPM tool (M2-01) that builds the iBoard binary lexicon (trie with quantized unigram log-probs), a pruned
quantized 3-gram LM, a license manifest and a size report from plain-text inputs. Format: `docs/LEXICON_FORMAT.md`.

```sh
cd Tools/LexiconBuilder
swift test
swift run lexicon-builder --sources sources.json --out build/ [--min-ngram-count 2] [--max-bigrams N] [--max-trigrams N]
```

`sources.json` lists inputs (path relative to the file), each with `id`, `kind` (`unigram` or `ngram`), `spdx`,
`attribution` and optional `url`/`version`. Inputs are `word<TAB>count` lines, and `w1 w2 [w3]<TAB>count` for n-grams.
Outputs: `lexicon.iblex`, `lm.iblm`, `licenses.json` (with SHA-256 of each input), `size-report.json`.

Output is deterministic. Do not commit corpora or generated lexicons from share-alike sources without the licence
notices from `licenses.json` (see `docs/DATA_SOURCES.md`). The reader in `LexiconBuilderCore/Reader.swift` exists to
verify round-trips; the production reader is M2-02.

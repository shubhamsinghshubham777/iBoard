# Engine test fixtures

Generated with `Tools/LexiconBuilder` (M2-01), release build:

```sh
lexicon-builder --sources small/sources.json --out out                          # small
lexicon-builder --sources bench/sources.json --out out --min-ngram-count 2     # bench
```

- `small/`: 219 synthetic words (Zipf-like counts, authored for this repo) and 43 synthetic phrases.
  `golden.json` holds the output of the builder's reference reader (`LexiconBuilderCore.LexiconReader` /
  `LMReader`) for every word, several prefix completion lists and 8,000 bigram / 8,000 trigram probabilities, so
  `LexiconReaderTests` cross-checks the production reader against the reference one.
- `bench/`: 12,000 words (219 real ones plus pseudo-words from random syllables) and about 12,000 random n-grams.
  Only for latency measurement; it is not a language model.
- All inputs are synthetic and CC0-1.0; no third-party corpus is vendored (`licenses.json` is the builder's manifest).
- The `.iblex` / `.iblm` files are deterministic builder output; regenerate them only when the format version changes.

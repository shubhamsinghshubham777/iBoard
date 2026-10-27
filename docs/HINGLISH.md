# Hinglish data and code-switching (M7-01, M7-02, M7-03)

Status: lexicon + LM built from real data and tested on macOS (2026-10-27); not yet wired into the keyboard
extension (EngineHost loads only the English fixture lexicon); no device run.

## 1. Artifacts

`Data/hinglish/` (committed, built by `Tools/HinglishData/build.sh`):

| File | Size | Content |
|---|---|---|
| `lexicon.iblex` | 4,013,244 B | 56,235 romanized words (trie, quantized unigram log-probabilities) |
| `lm.iblm` | 2,985,116 B | 150,006 bigrams + 60,000 trigrams (budget: LM <= 4 MB) |
| `clusters.tsv` | 396,957 B | 18,018 variant clusters `canonical<TAB>variants` (source data, not loaded at runtime) |
| `licenses.json`, `size-report.json`, `provenance.json`, `stats.json` | small | builder manifest, sizes, SHA-256 of every raw input, generator counts |

Together about 7.0 MB of the 25 MB base-language budget (EN + Hinglish). Format: `docs/LEXICON_FORMAT.md`.
The output is byte-identical across rebuilds (checked: SHA-256 of both files equal on two builds).

## 2. Pipeline (`Tools/HinglishData`)

1. **Frequencies.** Leipzig Hindi news 2019 and 2020 (300K sentences each) word counts, Devanagari tokens only.
2. **Romanization and variants.** Every frequent Devanagari word is romanized with the spellings Aksharantar
   attests for it (pairs weighted Dakshina 4, AK-Freq 4, Existing 3, Wikidata 2, Samanantar 1, IndicCorp 1). Up to
   three spellings with an attestation share of at least 12% are kept; they split the word's count by share. A word
   is a cluster: the canonical spelling plus its variants (`nahi / nhi / nahin / nai`). Matching key: NFC, nukta
   removed, chandrabindu folded to anusvara.
3. **Authored casual forms.** `data/common_hinglish.tsv` (about 440 clusters, CC0-1.0) overrides the spelling mix of
   the most common words with how people actually type (`nhi`, `kyu`, `h`, `kr`, `mje`, `tm`) and sets a count floor
   for casual words that news text under-represents. The share numbers are the author's estimates, not measured
   from chat data: they are the main thing a native-speaker review should adjust.
4. **English-mixed source.** `data/english_mixed_words.tsv` (about 245 English words common in Hinglish chat) and
   `data/mixed_phrases.tsv` (about 557 code-switched phrases such as `kal meeting hai`, `phone off hai`, CC0-1.0)
   give casual, mixed n-grams (weight 150 per unit, so they compete with news counts). Their tokens are added to
   the lexicon so the n-grams survive the builder's out-of-vocabulary filter.
5. **N-grams.** Leipzig sentences are mapped through the same romanization; bigrams/trigrams seen at least 6 times
   are expanded over the spelling variants of each word (`count * share_a * share_b`), so `nhi hai` has support
   too. The builder prunes to 150k bigrams / 60k trigrams (`MAX_BIGRAMS`, `MAX_TRIGRAMS` env of `build.sh`).

Raw corpora live only in `/private/tmp/claude-501/hinglish-data` (`fetch.sh` downloads and verifies them).

## 3. Sources and licences (verified 2026-10-27)

| Source | Used for | Licence as read today |
|---|---|---|
| Leipzig Corpora Collection `hin_news_2019_300K`, `hin_news_2020_300K` (https://wortschatz.uni-leipzig.de/en/download) | word and n-gram frequencies | https://wortschatz.uni-leipzig.de/en/usage: "The text corpora offered for download are made available under the Creative Commons licence CC BY" (linked to CC BY 4.0). The project's web service and applications are CC BY-NC; only the downloads are used. |
| AI4Bharat Aksharantar `hin.zip` (https://huggingface.co/datasets/ai4bharat/Aksharantar, SHA-256 `208c2d1b...bdaf`) | romanization pairs and spelling variants | Dataset card: manually collected data CC-BY; mined data (Samanantar, IndicCorp) and existing sources CC0; "we do not own any of the text". Card front matter says only `license: cc`, so the CC BY version is not stated (4.0 assumed). Rows whose `source` is `Dakshina` (24,727 of 1,299,155 train rows) come from Google Dakshina, CC BY-SA 4.0. |
| iBoard authored lists (`Tools/HinglishData/data/*.tsv`) | casual forms, English-mixed words and phrases | CC0-1.0, written for this repo, no third-party text |

Consequences:

- Because Dakshina-derived rows are mixed into the Aksharantar pairs and cannot be separated after counting, the
  generated lexicon and LM are treated as **CC BY-SA 4.0 with attribution** (D-29 allows this): `licenses.json` records
  `derivedOutputLicense: CC-BY-SA-4.0`. The Apache-2.0 code is unaffected; the data files carry their own notice
  (`Data/hinglish/LICENSE.md`, `NOTICE`), which Settings > Licenses must also show (M10-05).
- To get an attribution-only (no share-alike) build, drop rows with `source == "Dakshina"` in `generate.py`
  (a one-line filter); this was not done because those rows are the best attested informal spellings.
- Not used: L3Cube-HingCorpus (CC BY-NC-SA), PHINC (unresolved licence), scraped social text, Wikipedia-derived
  Leipzig corpora.
- Citations: Goldhahn, Eckart, Quasthoff (LREC 2012); Madhani et al. 2022 (arXiv 2205.03018); Roark et al. 2020
  (LREC, Dakshina).

## 4. Known gaps and risks

- The news register drives the counts. Casual chat words are only as good as the authored list (about 440
  clusters); everything beyond is formal Hindi romanized with Aksharantar's standard transliteration, so
  chat spellings such as `kr`, `mje`, `btao` outside the list are missing. Native-speaker review and a chat-register
  frequency source remain open (no licence-clean Hinglish chat corpus exists, DATA_SOURCES section 2).
- Aksharantar's mined rows contain noise (for example `carona` for the Hindi spelling of corona); the share
  threshold keeps most of it out of the variants but not out of the canonical spelling of rare words.
- Frequencies are not calibrated across languages: each lexicon is normalized on its own (see section 6).
- No accuracy number exists yet (M7-04 builds the eval set). Nothing here is measured on a device.

## 5. Rebuilding

```sh
Tools/HinglishData/fetch.sh && Tools/HinglishData/build.sh
```

## 6. Code-switch scoring (M7-02)

See `docs/ENGINE.md` section "Code-switching".

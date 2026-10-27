# English language data (M2-01 data)

Real English lexicon and 3-gram LM, replacing the 219-word synthetic fixture. Built by `Tools/EnglishData` (generator,
Python standard library only) and `Tools/LexiconBuilder` (binary writer); output in `Data/english/`. Binary format:
`docs/LEXICON_FORMAT.md`. Not yet bundled into the keyboard (separate task).

## Output (measured 2026-10-27)

| File | Bytes | Content |
|---|---|---|
| `lexicon.iblex` | 8,266,436 | 125,796 words (all lowercase), 308,262 trie nodes |
| `lm.iblm` | 7,943,288 (7.58 MiB) | 300,000 bigrams, 240,000 trigrams, unigram backoff |
| Total | 16,209,724 | EN + Hinglish (7.0 MB) = about 23.2 MB, under the 25 MB base-asset budget |

LM size is below the 8 MB budget read as 8,000,000 bytes. SHA-256: `lexicon.iblex`
`46b7d775b4b70519e7d94f7e3427a959ca161cde1ab00b913c0ac2e786e51007`, `lm.iblm`
`63b134d715f3cd356e68ef35dfe5d1eaa5420890ddde8022095e72d9857e8d10`. Two full rebuilds (the second after deleting the
generated inputs) gave byte-identical files and sidecars. Counts before pruning: 4.38M bigram types seen (1.54M with
count >= 2), 8.9M trigram types seen (2.37M with count >= 2); the builder keeps the highest-count 300k / 240k.

## Sources and licences (verified 2026-10-27)

| Source | Used for | Licence | How verified |
|---|---|---|---|
| SCOWL 2020.12.07 (Kevin Atkinson), size <= 70, `english`+`american`+`british` (GB-ise) lists, `contractions` | vocabulary | permissive permission notice (use, copy, modify, distribute, sell; keep notice). No share-alike. | `Copyright` file inside the downloaded tarball, read in full; included verbatim in `Data/english/LICENSE.md` |
| Leipzig Corpora Collection `eng_news_2023_1M`, `eng_news_2024_1M` | unigram counts, bigram/trigram counts | CC BY 4.0 for the downloadable corpora (the web service and applications are CC BY-NC and not used) | https://wortschatz.uni-leipzig.de/en/usage read 2026-10-27: "The text corpora offered for download are made available under the Creative Commons licence CC BY" linking to CC BY 4.0 |
| Project-authored `Tools/EnglishData/data/contractions.tsv`, `phrases.tsv` | contractions, casual forms, 164 words, 228 n-grams | CC0 1.0 | authored here |

Why SCOWL 2020.12.07 and not the current ESDB (v2, `Copyright` read 2026-10-27, also a permissive notice): ESDB v2
states that it uses COCA 3-gram data under an NDA ("not freely available"), so the 2020 release, which predates it,
is the clean choice. SCOWL levels up to 70 only: the UKACD notice applies from level 80 up (it is still in the
verbatim file). Leipzig Wikipedia corpora were deliberately not used (CC BY-SA text, formal register); only news
corpora, so the output is attribution-only (`licenses.json`: `shareAlike: false`).
Attribution lines: `Data/english/LICENSE.md`, `NOTICE`; cite Goldhahn, Eckart, Quasthoff, LREC 2012.

## Method

1. **Vocabulary** (125,796 words): SCOWL words (124,677 incl. common proper nouns: `upper` <= 60, `proper-names` <= 50),
   lowercased, letters only (SCOWL possessives/abbreviations are dropped here), 83 SCOWL contractions, the 164
   project-authored contractions, casual forms, brands and acronyms (don't, gonna, lol, iPhone, ...), 150 further
   corpus-frequent words SCOWL lacks (count >= 400 of 39.1M tokens, 3+ ASCII letters: covid, nhs, tiktok, crypto, ...),
   and 847 possessives ("tomorrow's") attested >= 40 times whose base word is present. US and GB-ise spellings are
   both included (D-02 picks the variant by locale at runtime, not by vocabulary). 15 slurs from SCOWL
   `misc/offensive.1/2` are excluded; ordinary profanity stays (it is normal casual vocabulary).
2. **Unigram counts** = 1 (floor, so every SCOWL word exists) + corpus token count (lowercased) + authored per-million
   rate scaled to the 39.1M-token corpus. Word id = rank, so word 0 is "the".
3. **N-grams**: 2M news sentences tokenised (lowercase, curly apostrophes folded, words = letter runs with inner
   apostrophes); numbers, punctuation and out-of-vocabulary words break the chain. Bigrams count >= 2; trigrams count
   >= 2 whose two component bigrams survive; authored phrases add counts. Builder options: `--min-ngram-count 2
   --max-bigrams 300000 --max-trigrams 240000` (`build.sh`, overridable by env vars).

## Rebuild

```sh
Tools/EnglishData/fetch.sh     # downloads into /private/tmp/claude-501/english-data and checks SHA-256 (about 580 MB)
Tools/EnglishData/build.sh     # generate.py (about 75 s) + swift build lexicon-builder + copies into Data/english
```

Raw corpora are never committed. Pinned inputs: SCOWL tarball `5587667c...3859cc`, `eng_news_2023_1M.tar.gz`
`c8a5a5e7...f3e4c`, `eng_news_2024_1M.tar.gz` `8f1d4d07...3a97` (full hashes in `fetch.sh` and `provenance.json`).

## Measurements (macOS, release build, reader in `Packages/IBoardEngine`, throwaway probe, M-series Mac)

- Open lexicon: 9.9 ms with the FNV checksum verification of 8 MB (default), 0.07 ms with `verifyChecksum: false`;
  open LM: 8.6 ms. Warm file cache; cold-cache disk read not measured.
- Exact lookup: 0.105 us per word (2M lookups of the top-10k list in 211 ms). Prefix completions (limit 8): 0.68 us.
- 40 spot-checked common words all present with sensible ranks (rank = frequency order): the 0, it's 16, don't 36,
  i'm 34, because 115, thanks 126, government 147, hello 334, weekend 725, restaurant 1484, definitely 1541,
  separate 1944, accommodate 5624, keyboard 7800, swipe 11933, ... Completions: `hel` -> help, hello, held;
  `keyb` -> keyboard; `defin` -> definitely; `don` -> don't. Next-word checks give "thank you so/very/for", "i don't
  know/think/want", "see you later/soon/tomorrow", "how are you", "let me know", "on my way".
- Top-10,000 corpus words (case-folded, 2+ letters, from the generator's own tokenisation) present in the lexicon:
  SCOWL alone 9,656 / 10,000 (96.6%); final vocabulary 9,824 / 10,000 (98.2%). The 176 absent are news-specific
  acronyms and names below the add threshold (e.g. `ap`, `un`, `sabha`, `starmer`, `lakers`), non-ASCII tokens, and
  tokens like `st`, `dc`. The earlier probe check of "top 10k in lexicon" is circular if the list is taken from the
  lexicon's own counts; only the figure above (against the full corpus) is meaningful.

NOT TESTED: on-device (iPhone 12) memory and latency, behaviour inside the keyboard, cold-start page-in cost, the
effect of this LM on tap/swipe accuracy.

## Known gaps

- **Register**: counts and n-grams are from news text (2023-2024), so chat and casual language is under-weighted
  ("okay", "lol", "gonna" are boosted only by the small authored list; first-person and question forms are rarer than in
  messages). Consider adding a conversational CC BY / permissive source (the DATA_SOURCES.md shortlist has only
  CC BY-SA ones) and weighting by interpolation with the personal model.
- Proper nouns and news names are mixed in lowercase (no case information): `us` (the country) and `us` (pronoun)
  share one count; capitalisation is inferred at runtime.
- 2020 SCOWL: newer words are present only if the news corpus supplies them (>= 400 occurrences).
- Bigram/trigram counts are pruned before the builder (count >= 2) and then by entry count, so backoff weights are
  computed from the pre-pruned set, not the full corpus; the LM is slightly sub-normalised (documented format limit).
- No sentence-start/end tokens in the LM (the format has no `<s>`), so sentence-initial prediction uses the unigram
  model plus authored/personal data.
- US and GB spellings are both valid; no Indian-English overlay; no locale-specific suppression of the other variant.
- Typos and rare word forms in SCOWL (size 60/70) are valid but low-ranked; word quality was spot-checked, not audited.
- Possessives exist only when seen in the corpus; the engine's apostrophe handling decides the rest.

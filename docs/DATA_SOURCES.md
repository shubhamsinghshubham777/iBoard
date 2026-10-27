# Data sources and licensing (M0-11)

Status: research shortlist, verified 2026-10-26 by fetching each source's own page. Not legal advice.
"Unverified" = the licence text could not be read on an authoritative page in this pass; re-check before use.
Nothing from these sources is vendored in the repo. `Tools/LexiconBuilder` (M2-01) must record, per source, the
exact version/URL/checksum and emit a licence manifest (feeds M10-05).

Recommendation legend: **USE** (permissive, attribution only), **SIGN-OFF** (needs owner approval: CC BY-SA,
non-commercial, research-only, or unclear), **AVOID**.

## 00. Data actually in the repository (as built, 2026-10-27)

The sections below are the research shortlist. This table is what the repo really contains. Where it differs from the
shortlist, this table wins.

| Data | Where | Origin and licence | In the keyboard extension? |
|---|---|---|---|
| English lexicon + LM (placeholder) | `iBoardKeyboard/Resources/lexicon.iblex`, `lm.iblm` (14 KB, 1.5 KB) | 219 synthetic words and 43 phrases authored for this repo, CC0-1.0. Same files as `Packages/IBoardEngine/Tests/IBoardEngineTests/Fixtures/small`. NOT real English data | Yes (placeholder). Real English data (SCOWL, Google Books, Leipzig EN per section 5) is not built yet |
| Engine test fixtures | `Packages/IBoardEngine/Tests/.../Fixtures/{small,bench,hinglish-small}` | Synthetic, CC0-1.0 (bench is pseudo-words, hinglish-small is 151 made-up words and 50 phrases) | No (tests only) |
| Hinglish lexicon + LM | `Data/hinglish/lexicon.iblex` (56,235 words, 4.0 MB), `lm.iblm` (150,006 bigrams + 60,000 trigrams, 3.0 MB), `clusters.tsv` | Built by `Tools/HinglishData` + `Tools/LexiconBuilder` from Leipzig Hindi news 2019/2020 (CC BY 4.0), AI4Bharat Aksharantar Hindi pairs (CC BY / CC0; includes rows sourced from Google Dakshina, CC BY-SA 4.0) and project-authored CC0 lists. Because Dakshina rows are in the mix, the derived files are released under **CC BY-SA 4.0** (`Data/hinglish/LICENSE.md`, `licenses.json`). Raw inputs are not committed; their SHA-256 are in `provenance.json` | **Not yet** (built and engine-tested only). Bundling it means shipping a CC BY-SA 4.0 data file inside the app: the Settings > Licenses screen (M10-05) and the owner/lawyer question in section 0 apply |
| Hinglish authored inputs | `Tools/HinglishData/data/*.tsv` | Project-authored (about 440 variant clusters, English words used in Hinglish, mixed phrases), CC0-1.0 | No (build inputs) |
| Emoji catalog | `Packages/IBoardEmoji/Sources/IBoardEmoji/Resources/emoji.json` (about 0.43 MB; 1,923 base emoji, 9 groups) | Unicode `emoji-test.txt` (Emoji 18.0) + CLDR 49 annotations en and hi via cldr-json, Unicode License v3; full text in `Packages/IBoardEmoji/LICENSE-UNICODE.txt`; details in `docs/EMOJI_DATA.md` | Yes (loaded only while the emoji panel is open) |
| Emoji Hinglish keyword overlay | `Packages/IBoardEmoji/Tools/hinglish_overlay.json`, merged into `emoji.json` | Project-authored, Apache-2.0 | Yes (inside `emoji.json`) |
| Evaluation corpora | none | Dakshina, Birkbeck etc. are never committed (sections 2.2, 4) | No |

Everything shipped under a share-alike licence today: nothing yet (the Hinglish data is the only CC BY-SA item and is
not bundled). Attribution texts live in `NOTICE`, `Data/hinglish/LICENSE.md`, `Packages/IBoardEmoji/LICENSE-UNICODE.txt`.

## 0. Why share-alike matters here

D-02/R-06: Hinglish and many frequency lists derive from Wikipedia/subtitle text under CC BY-SA. Consequences:

- A **derived dictionary/LM** (trie, quantized n-gram) built from CC BY-SA data should be treated as an adaptation:
  it must be attributed and released under CC BY-SA 4.0 (or a compatible licence). Whether a statistical frequency
  table is legally an "adaptation" is unsettled; wordfreq distributes its derived counts under CC BY-SA 4.0, so we
  assume SA applies.
- The **app source code** (Apache-2.0) is not affected if the lexicon is a separate data file with its own licence
  notice, but the app bundles both: the data licence must be stated in Settings > Licenses and the repo must
  publish the data files (or builder + inputs) under CC BY-SA. CC BY-SA 4.0 forbids adding technological measures
  that restrict others' rights; App Store DRM on the binary copy is a point for owner/lawyer to confirm, since the
  data is also freely available from the repo.
- **Non-commercial (NC)** is incompatible with an open-source, possibly monetised product: avoid.
  **Research-only / ToS-restricted** (scraped Twitter/Reddit text) must not be redistributed.
- Preferred ordering: public domain/CC0 > MIT/BSD/Apache/Unicode-3.0 > CC BY > CC BY-SA (sign-off) > NC (avoid).

## 1. English wordlist, unigram and n-gram frequencies

### 1.1 SCOWL / ESDB (English Speller Database), spelling word list
- URL: https://github.com/en-wl/wordlist (v2 branch; licence in its `Copyright` file); site http://wordlist.aspell.net
- Gives: curated headword list with size levels (35..85) and regional spellings (US, GB-ise, GB-ize, CA, AU).
  Right source for the ~150k EN valid-word set and for US/UK/IN variant selection (D-02). No frequencies.
- Licence: MIT-like permissive notice, built from BSD-compatible sources (SPDX: no exact id; "unverified" mapping).
  Verified: free to use, modify, distribute and sell, including derived lists, if the copyright and permission
  notice is kept.
- Attribution: ESDB copyright notice in all copies. Extra notices if applicable: UKACD notice (generated lists
  over 80 words; its text verbatim), Princeton notice if WordNet-derived data is in the output, Benjamin Titze 2016
  notice for Australian lists. COCA 3-gram data used by ESDB is under an NDA and is NOT redistributable.
- Share-alike: none. Size: not measured (unverified). v2 is described as work in progress.
- Quality: very good spell-check quality; no frequencies. Indian English spelling follows GB unless we add an overlay.
- Recommendation: **USE** (core EN vocabulary). Ship the exact notice files.

### 1.2 Google Books Ngram datasets v3 (2020-02-17), unigram/n-gram counts
- URL: https://storage.googleapis.com/books/ngrams/books/datasetsv3.html
- Gives: counts for 1- to 5-grams (English and others) by year; basis for unigram frequencies and a pruned
  Kneser-Ney 3-gram LM.
- Licence: CC BY 3.0 Unported (SPDX `CC-BY-3.0`). Verified verbatim: "licensed under a Creative Commons
  Attribution 3.0 Unported License".
- Attribution: credit the Google Books Ngram dataset; cite Michel et al. 2011 / Lin et al. 2012.
- Share-alike: none. Size: very large (full set is TB-scale; page gives no per-file sizes). Process offline, keep
  only pruned output. Book text skews formal and older; POS-tagged tokens and year splits need cleaning; weak for
  chat register, so interpolate with a conversational source and the personal model.
- Recommendation: **USE** as primary unigram/n-gram source.

### 1.3 wordfreq (Robyn Speer), ready-made multilingual unigram frequencies
- URL: https://github.com/rspeer/wordfreq
- Gives: `en`, `hi` and 40+ languages; sources include Wikipedia, OpenSubtitles 2018, SUBTLEX, NewsCrawl,
  GlobalVoices, Google Books Ngrams 2012, OSCAR, Twitter, Reddit.
- Licence: code Apache-2.0; data "may be redistributed under a Creative Commons Attribution-ShareAlike 4.0
  license" (SPDX `CC-BY-SA-4.0`), plus upstream terms (SUBTLEX authors credited, OpenSubtitles attribution,
  Google Books acknowledgement). Verified from README.
- Attribution: wordfreq citation (Zenodo v3.0.2, 2022) and each upstream credit per README.
- Share-alike: yes for data. Size: small (MBs). Maintenance: author says data is a roughly 2021 snapshot and
  "unlikely to be updated again". Hindi list is Devanagari only; no romanized Hindi.
- Quality: excellent, good informal register. Risk: SA plus Twitter/Reddit provenance (statistics only).
- Recommendation: **SIGN-OFF** (CC BY-SA). Useful as an eval cross-check even if not shipped.

### 1.4 Peter Norvig count_1w.txt / count_2w.txt
- URL: https://norvig.com/ngrams/
- Gives: 333k unigrams and 250k bigrams from the Google Web Trillion Word Corpus; `spell-errors.txt`.
- Licence: page says MIT for the **code** only. **Data licence not stated**, and the underlying corpus is
  distributed by the LDC (typically under a paid LDC licence). Unverified, likely restricted.
- Recommendation: **AVOID** for shipping; private sanity check only, never committed.

### 1.5 FrequencyWords (hermitdave), OpenSubtitles frequency lists
- URL: https://github.com/hermitdave/FrequencyWords
- Gives: `en_50k.txt` style lists (word and count) from OpenSubtitles 2016/2018. README confirms English;
  other languages not confirmed on the page, Hindi unverified.
- Licence: README: "MIT License for code. CC-by-sa-4.0 for content." (SPDX `CC-BY-SA-4.0`). Upstream subtitle
  copyright is murky.
- Quality: strong conversational register; no context.
- Recommendation: **SIGN-OFF** (CC BY-SA, murky upstream). Prefer CC BY alternatives.

### 1.6 Leipzig Corpora Collection (Wortschatz), sentence corpora
- URL: https://wortschatz.uni-leipzig.de/en/download ; terms https://wortschatz.uni-leipzig.de/en/usage
- Gives: per-language sentence samples and word-frequency tables for English and Hindi (Devanagari); news, web
  and Wikipedia genres.
- Licence: per the official terms (read via search result; the download page itself showed a bot check), downloadable
  corpora are CC BY. Version number (4.0) seen only on a third-party listing: unverified. The project's
  web service/applications are CC BY-NC: use downloads only.
- Attribution: cite Goldhahn, Eckart, Quasthoff (LREC 2012). Share-alike: none stated for downloads.
- Size: not measured. Quality: news/web, some noise, shuffled sentences (fine for 3-gram). Wikipedia-derived
  sub-corpora may carry SA: check each corpus's metadata.
- Recommendation: **USE**, re-verify the licence per corpus file at build time.

### 1.7 Wikipedia / Wikimedia dumps (EN, HI)
- URL: https://dumps.wikimedia.org/legal.html
- Licence: text CC BY-SA 4.0 and GFDL (verified). Attribution plus SA on adaptations. Formal register.
- Recommendation: **SIGN-OFF** (SA). Largely subsumed by other sources.

### 1.8 Others considered
- AOSP LatinIME bundled dictionaries: code is Apache-2.0 but dictionary provenance unclear (the mirror URL tried
  returned 404). Unverified, avoid until provenance is documented.
- Hunspell en_US: derived from SCOWL, redundant with 1.1.
- Common Crawl / C4 / OSCAR: per-page rights and gated terms; avoid.
- COCA, raw OpenSubtitles: licensed or research-only; **AVOID**.
- Brown, OANC: small, usable for eval text only; terms unverified.

## 2. Hinglish / romanized Hindi

No clean, permissively licensed, large romanized Hindi corpus was found. The pragmatic route: take Hindi
(Devanagari) frequency ranking from a permissive source, then derive Latin spellings and variant clusters
(`nahi/nhi/nahin`) from human-annotated transliteration pairs, and curate the top entries by hand/community.

### 2.1 Aksharantar (AI4Bharat), transliteration pairs
- URL: https://huggingface.co/datasets/ai4bharat/Aksharantar ; project https://github.com/AI4Bharat/Aksharantar
- Gives: about 1.3M Hindi native/Latin word pairs (train), 6k validation, 5.7k test; multiple Latin spellings per word.
- Licence (dataset card): manually collected data CC BY (version unverified, SPDX `CC-BY-4.0` assumed), mined and
  existing-source data CC0 (`CC0-1.0`). Card also says "we do not own any of the text". Code/models (IndicXlit)
  are MIT (verified). The GitHub page itself stated no dataset licence.
- Attribution: cite Madhani et al. 2022 (arXiv 2205.03018). Size: 729 MB whole dataset. Quality: mined pairs are
  noisy; the Latin side is standard transliteration, not casual chat spelling (real users write `nhi`, `kya`).
- Recommendation: **USE**, after verifying per-split provenance.

### 2.2 Dakshina (Google Research), romanization lexicons and sentences
- URL: https://github.com/google-research-datasets/dakshina
- Gives: 25k Hindi word types with human-annotated Latin romanizations and attestation counts (natural,
  informal spellings), 2.5k dev and 2.5k test types, about 10k manually romanized sentences per language.
- Licence: CC BY-SA 4.0 (verified verbatim). Source is Wikipedia text.
- Attribution: cite Roark et al. 2020 (LREC, "Processing South Asian Languages Written in the Latin Script").
- Quality: best informal-romanization signal available.
- Recommendation: **SIGN-OFF**. Use as eval data only (downloaded locally, not committed or shipped) to avoid SA
  on the shipped lexicon. If shipped, the Hinglish lexicon must be CC BY-SA 4.0.

### 2.3 Bhasha-Abhijnaanam (AI4Bharat), language ID incl. romanized Hindi
- URL: https://huggingface.co/datasets/ai4bharat/Bhasha-Abhijnaanam
- Gives: about 5.6k Hindi native and 4.6k romanized sentence rows; useful for code-switch/LID eval.
- Licence: CC0 on manually collected packaging (verified); text origin not owned by AI4Bharat.
- Recommendation: **USE** for eval (small).

### 2.4 L3Cube-HingCorpus (52.9M Roman-script Hinglish tweets, 1.04B tokens)
- URL: https://github.com/l3cube-pune/code-mixed-nlp
- Licence: CC BY-NC-SA 4.0 (verified; `CC-BY-NC-SA-4.0`). Scraped Twitter text.
- Largest Hinglish corpus found, but non-commercial plus share-alike plus Twitter ToS.
- Recommendation: **AVOID**. Revisit only if the authors grant a different licence.

### 2.5 PHINC (parallel Hinglish social-media corpus)
- Listings conflict: CC BY 4.0 on one, CC BY-SA 4.0 on an AIKosh page. **Unverified.**
- Recommendation: **AVOID** until resolved; possible eval source.

### 2.6 Hindi frequency ranking
- Leipzig `hin` corpora (1.6, CC BY) preferred; wordfreq `hi` (1.3) and Wikipedia (1.7) are SA alternatives.

### 2.7 Project-authored community list
- Hand-curated top ~5-10k casual Hinglish forms and variant clusters, written in this repo under Apache-2.0 or
  CC0, reviewed by native speakers, seeded by statistics from 2.1/2.2 but authored by us. Avoids SA on the
  shipped lexicon (R-06 fallback). Needs an owner/community process.
- Recommendation: **USE**.

### 2.8 Not used
- LinCE, GLUECoS, Hinglish-TOP, SentiMix: mostly research-only or NC; unverified.
- Twitter/Reddit scraped Hinglish text: ToS prohibits redistribution.

## 3. Emoji annotations (EN and Hindi)

### 3.1 Unicode CLDR annotations
- URL: https://github.com/unicode-org/cldr (annotations XML), https://github.com/unicode-org/cldr-json
  (`cldr-annotations-full`, `cldr-annotations-derived-full`; package names unverified, check PACKAGES.md);
  terms https://www.unicode.org/copyright.html
- Gives: emoji names and keywords per locale incl. `en`, `en_IN`, `hi`; basis for emoji search.
- Licence: Unicode License v3 (SPDX `Unicode-3.0`); verified that CLDR is treated as Unicode software under it.
  The UTS #35 specification text itself has tighter copying terms; we do not redistribute it.
- Attribution: include the Unicode copyright and permission notice with copies or in documentation; do not use
  Unicode's name to promote the product. Share-alike: none. Size: a few MB per locale (not measured).
- Gap: romanized Hindi keywords (`hasna`, `dil`) are not in CLDR; add a project-authored overlay.
- Recommendation: **USE**.

### 3.2 Emojibase (milesj)
- URL: https://github.com/milesj/emojibase
- Gives: preprocessed JSON from CLDR (README: CLDR 49, Emoji 18), groups, skin tones, shortcodes.
- Licence: repo MIT; datasets not separately stated, underlying data Unicode-3.0. README did not list locales:
  verify `hi` is shipped (unverified).
- Recommendation: **USE** as optional convenience; carry MIT and Unicode-3.0 notices. Generating directly from
  cldr-json avoids a dependency.

## 4. Keyboard evaluation data

### 4.1 Birkbeck spelling error corpus (Roger Mitton)
- URL: https://titan.dcs.bbk.ac.uk/~ROGER/corpora.html (full corpus via the Oxford Text Archive)
- Gives: `birkbeck.dat` with 36,133 misspellings of 6,136 words (native speakers), plus related files.
- Licence: **no terms on the page**; OTA conditions unread (unverified). Handwriting/essay errors, not
  touchscreen errors.
- Recommendation: **SIGN-OFF**; eval-only, fetch locally, do not commit.

### 4.2 Wikipedia "Lists of common misspellings/For machines"
- URL: https://en.wikipedia.org/wiki/Wikipedia:Lists_of_common_misspellings/For_machines
- Gives: `misspelling->correction` pairs (count not captured; page truncated in the fetch).
- Licence: Wikipedia text, CC BY-SA 4.0 (inferred from Wikimedia terms; page footer not read: unverified).
- Recommendation: **SIGN-OFF** if shipped; acceptable as attributed eval data.

### 4.3 GitHub Typo Corpus
- URL: https://github.com/mhagiwara/github-typo-corpus
- Gives: 350k+ edits, 15+ languages, `is_typo` labels for English. Licence follows each source repository (mixed);
  GitHub AUP section 5 also applies.
- Recommendation: **AVOID** for committed data; low relevance to touch typing.

### 4.4 Aalto 37k typing dataset (Palin et al., MobileHCI 2019)
- URL: https://userinterfaces.aalto.fi/typing37k
- Gives: keystroke logs of 37k mobile volunteers (raw 4.7 GB zip, processed 0.8 GB); calibrates error-rate
  priors (2.3% uncorrected errors). No touch coordinates or labelled typo pairs.
- Licence: "openly available" but **no licence on the page** (unverified). A separate Aalto "ITE typing dataset"
  on Zenodo is listed as CC BY 4.0 by a third-party index (unverified; confirm on Zenodo).
- Recommendation: **SIGN-OFF**; local use only.

### 4.5 Swipe/gesture-typing traces
- "How We Swipe" (Leiva et al., MobileHCI 2021): 1,338 participants, 11,318 unique words, trajectories and
  timing. Paper is open access, but the **dataset location and licence were not found** (unverified): ask authors.
- FUTO swipe (https://swipe.futo.org, Hugging Face `futo-org/swipe`): site collects contributions, states no
  licence or download; the HF page lists ~1.22M entries and ~144k negatives under the "FUTO Model Weights
  License 1.0" (terms unread, not an OSI licence). A secondhand claim of MIT was not confirmed.
- No other public redistributable swipe dataset found.
- Recommendation: **AVOID** FUTO data unless an open licence is confirmed. Plan: synthetic swipes generated from
  layout geometry with noise (fits the SHARK2 template design in ROADMAP section 7), plus consented internal
  recordings from the team only (never user data).

### 4.6 ClarityEmail-style and phrase sets
- No verified public ClarityEmail set found. The MacKenzie and Soukoreff 500-phrase set is widely used; terms
  unverified.
- Recommendation: author our own phrase set (about 500 EN + 500 Hinglish, Apache-2.0 or CC0) and inject typos with
  a touch-noise model; use Leipzig EN sentences (CC BY) and Dakshina romanized sentences (eval only) as inputs.

## 5. Recommended minimal v1 set

| Need | Source | Licence | Obligation |
|---|---|---|---|
| EN valid words, regional spellings | SCOWL/ESDB (1.1) | MIT-like | ship ESDB notice |
| EN unigram and n-gram LM | Google Books Ngrams v3 (1.2), Leipzig EN (1.6) for register | CC BY 3.0 / CC BY | attribution |
| Hindi frequency ranking | Leipzig `hin` (1.6) | CC BY | attribution |
| Roman spellings, variant clusters | Aksharantar Hindi (2.1) + project list (2.7) | CC0 / CC BY | attribution |
| Emoji keywords EN/HI | CLDR via cldr-json (3.1) + project roman overlay | Unicode-3.0 | include notice |
| Eval | Own phrase sets, synthetic swipes, Dakshina sentences locally (eval only) | mixed | nothing shipped under SA |

Shipped assets stay attribution-only (no share-alike), provided the Leipzig and Aksharantar per-split licences
verify. Attributions go into the LexiconBuilder licence manifest and Settings > Licenses (M10-05).

## 6. Items requiring owner sign-off

1. CC BY-SA 4.0 sources if used in the shipped lexicon/LM: wordfreq, FrequencyWords, Wikipedia dumps, Dakshina,
   Wikipedia misspellings list. Implication: the derived dictionary must be released under CC BY-SA 4.0 with
   attribution.
2. NC / research-only / ToS-limited or unclear: L3Cube-HingCorpus (CC BY-NC-SA), Birkbeck (OTA terms), Aalto 37k
   (no licence stated), FUTO swipe (FUTO Model Weights License), PHINC (conflicting). Default: do not use.
3. Dakshina as a locally downloaded eval-only dataset (not committed): confirm acceptable.

## 7. Open questions

- Will the owner accept a CC BY-SA 4.0 Hinglish lexicon if the attribution-only path misses quality targets?
- Who curates the project-authored Hinglish list (native-speaker reviewers, community PR flow)?
- Does Aksharantar's per-split licence (CC BY manual vs CC0 mined) cover the Hindi pairs we use? Check before M7-01.
- Leipzig: confirm CC BY version and per-corpus terms for English and Hindi corpora before the build.
- ESDB: confirm the exact `Copyright` notices for the size/region slice we ship.
- Indian English: follow GB spelling or a custom en-IN overlay?
- Emojibase vs direct cldr-json; confirm `hi` annotation coverage and current CLDR release before M2-01.
- Ask authors for licence clarity: How We Swipe dataset, PHINC, Aalto 37k, L3Cube (commercial relicence).
- Legal read: do statistical n-gram tables count as CC BY-SA "adaptations" (affects 1.3, 1.5, 2.2)?

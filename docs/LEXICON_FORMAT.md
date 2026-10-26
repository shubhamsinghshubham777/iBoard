# Lexicon and LM binary format (v1)

Produced by `Tools/LexiconBuilder` (M2-01), mapped by `IBoardEngine` (M2-02). Reference reader: `LexiconBuilderCore/Reader.swift`.

## 1. Conventions

- Little-endian everywhere. 4-byte aligned sections and records. No pointers: all references are integer offsets or indices.
- Safe to `mmap` read-only; read fields with unaligned loads or on 4-byte boundaries (all records start 4-aligned).
- Deterministic: the same inputs and options give byte-identical files (no timestamps, no hash-order dependence).
- Text is NFC-normalized UTF-8; trie labels are Unicode scalars.
- Two files: `lexicon.iblex` (magic `IBLX`) and `lm.iblm` (magic `IBLM`). The LM stores word ids, so it is bound to one lexicon (see META).

## 2. Container

Header, 32 bytes:

| Off | Size | Field |
|---|---|---|
| 0 | 4 | magic (`IBLX` or `IBLM`) |
| 4 | 4 | format version (1) |
| 8 | 4 | endian marker `0x01020304` (bytes `04 03 02 01` on disk) |
| 12 | 4 | section count N |
| 16 | 4 | total file size |
| 20 | 4 | reserved (0) |
| 24 | 4 | checksum: FNV-1a 32 over bytes 32..EOF |
| 28 | 4 | reserved (0) |

Section table at offset 32, N entries of 16 bytes: `id u32, offset u32, length u32, count u32` (offsets absolute, 4-aligned;
`count` = number of records, or bytes for the string pool). Readers must reject a wrong magic, version, endian marker,
size or checksum, and ignore unknown section ids.

## 3. Quantization

`q = clamp(round(-ln(p) * 2048), 0, 65535)`; `p = exp(-q / 2048)`. `q = 65535` means "probability 0 / absent".
Resolution is about 0.05% relative; range down to p = 1e-13.

## 4. Lexicon sections (`IBLX`)

Word id = rank: count descending, then word ascending by UTF-8 bytes. Unigram p = count / total count.

| id | name | record |
|---|---|---|
| 1 | STRINGS | UTF-8 pool, padded to 4 (count = byte length) |
| 2 | WORDS | 8 B: `strOffset u32` (in pool), `strLength u16` (bytes), `q u16` |
| 3 | NODES | 12 B: `edgeStart u32` (index into EDGES), `wordId u32` (`0xFFFFFFFF` = none), `edgeCount u16`, `maxQ u16` |
| 4 | EDGES | 8 B: `label u32` (Unicode scalar), `child u32` (node index) |

Node 0 is the root. Nodes are numbered in BFS order, each node's edges are contiguous and sorted by `label`
(binary search). `maxQ` is the smallest `q` (most probable word) in the node's subtree, so a prefix walk can rank
or prune completions without visiting the subtree. It is a plain trie, not yet suffix-merged (DAWG); suffix sharing
is a possible later optimisation if sizes demand it (the format does not change, only node sharing).

## 5. LM sections (`IBLM`)

| id | name | record |
|---|---|---|
| 1 | META | 8 B: `vocabSize u32`, `lexiconChecksum u32` (header checksum of the paired `.iblex`) |
| 2 | UNIGRAM_BACKOFF | 4 B per word id: `bowQ u16`, pad u16 |
| 3 | BIGRAMS | 12 B sorted by (w1, w2): `w1 u32, w2 u32, pQ u16, bowQ u16` |
| 4 | TRIGRAMS | 16 B sorted by (w1, w2, w3): `w1 u32, w2 u32, w3 u32, pQ u16, pad u16` |

## 6. Model and scoring

Interpolated absolute discounting, D = 0.75. For context h with total count c(h) and T(h) distinct continuations:
`pd(w|h) = (c(h,w) - D) / c(h)` (stored as `pQ`), `bow(h) = D * T(h) / c(h)` (stored as `bowQ`; 0 means weight 1.0
when the context has no data).

```
P1(w)        = exp(-q(w)/2048)                       (WORDS)
P2(w | a)    = pd(a,w) + bow(a) * P1(w)              (bow from UNIGRAM_BACKOFF[a], pd from BIGRAMS or 0)
P3(w | a,b)  = pd(a,b,w) + bow(a,b) * P2(w | b)      (bow from BIGRAMS record (a,b); if absent, P3 = P2)
```

Context totals and T(h) are computed from the full, unpruned counts. Pruning (min count, optional max entries
keeping highest counts) then removes records; a bigram that is the context of a kept trigram is always kept
(with `pQ = 65535` if its own count was pruned) so its backoff weight is available. After pruning the distribution is
slightly sub-normalised, which is acceptable for ranking.

N-gram records whose words are not in the lexicon are dropped and counted in the size report.

## 7. Sidecar outputs

- `licenses.json`: per input source `id, kind, spdx, attribution, url, version, sha256`, plus `shareAlike` and
  `derivedOutputLicense` (`CC-BY-SA-4.0` when any input SPDX id contains `-SA`). Feeds M10-05.
- `size-report.json`: counts and per-section byte sizes.

## 8. Input formats

- Unigram list: UTF-8 lines `word<TAB>count`; `#` comment lines; duplicates (also across sources) are summed.
- N-gram list: `w1 w2<TAB>count` or `w1 w2 w3<TAB>count`.
- `sources.json`: `{"sources":[{"id","path","kind":"unigram|ngram","spdx","attribution","url?","version?"}]}`, paths relative to the file.

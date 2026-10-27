#!/usr/bin/env python3
"""Deterministic generator of the Hinglish LexiconBuilder inputs (M7-01).

    python3 -I Tools/HinglishData/generate.py --raw /private/tmp/claude-501/hinglish-data --out build/inputs

Inputs (never committed, see fetch.sh):
  <raw>/aksharantar/x/hin_{train,valid,test}.json   AI4Bharat Aksharantar Hindi native/Latin pairs
  <raw>/leipzig/n2020/*/*-words.txt, *-sentences.txt, and n2019/...   Leipzig Corpora Collection Hindi news
Project-authored inputs (committed, CC0-1.0): data/common_hinglish.tsv, data/english_mixed_words.tsv,
data/mixed_phrases.tsv.

Method: Hindi (Devanagari) word frequencies come from Leipzig; every frequent Devanagari word is romanized with the
spellings Aksharantar attests (variant spellings share the word's count by attestation weight); the project list
overrides the spelling mix of the most common casual words (nahi / nhi / nahin). Leipzig sentences are mapped through
the same romanization to give bigram / trigram counts (spelling variants expand the counts by their share), and the
authored code-switched phrases add casual, English-mixed n-grams.

Output (in --out): unigrams-derived.tsv, ngrams-derived.tsv, unigrams-authored.tsv, ngrams-authored.tsv,
clusters.tsv, sources.json, provenance.json, stats.json. Same inputs -> byte-identical outputs.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = re.compile(r'^[ऀ-ॣ०-ॿ]+$')
TOKEN = re.compile(r'[ऀ-ॣ०-ॿ]+|\S')
LATIN = re.compile(r'^[a-z]+$')
SOURCE_WEIGHT = {'Dakshina': 4, 'AK-Freq': 4, 'Existing': 3, 'Wikidata': 2, 'Samanantar': 1, 'IndicCorp': 1}


def key_of(native):
    """Lookup key: NFC, nukta removed, chandrabindu folded into anusvara (spelling variants of one word)."""
    s = unicodedata.normalize('NFC', native)
    s = s.replace('़', '').replace('ँ', 'ं')
    return unicodedata.normalize('NFC', s)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def find_one(directory, suffix):
    found = []
    for root, _dirs, files in os.walk(directory):
        for name in files:
            if name.endswith(suffix):
                found.append(os.path.join(root, name))
    if len(found) != 1:
        sys.exit('expected exactly one *%s under %s, found %d' % (suffix, directory, len(found)))
    return found[0]


def read_aksharantar(raw):
    pairs = defaultdict(Counter)   # native key -> latin -> weight
    files = []
    for split in ('train', 'valid', 'test'):
        path = os.path.join(raw, 'aksharantar', 'x', 'hin_%s.json' % split)
        files.append(path)
        with open(path, encoding='utf-8') as f:
            for line in f:
                r = json.loads(line)
                native = unicodedata.normalize('NFC', r['native word'].strip())
                latin = r['english word'].strip().lower()
                if not DEV.match(native) or not LATIN.match(latin) or not 2 <= len(latin) <= 18:
                    continue
                pairs[key_of(native)][latin] += SOURCE_WEIGHT.get(r.get('source'), 1)
    return pairs, files


def read_leipzig(raw):
    freq = Counter()
    sent_files, files = [], []
    for corpus in ('n2020', 'n2019'):
        d = os.path.join(raw, 'leipzig', corpus)
        w = find_one(d, '-words.txt')
        s = find_one(d, '-sentences.txt')
        files += [w, s]
        sent_files.append(s)
        with open(w, encoding='utf-8') as f:
            for line in f:
                p = line.rstrip('\n').split('\t')
                if len(p) < 3:
                    continue
                tok = unicodedata.normalize('NFC', p[1])
                if DEV.match(tok):
                    freq[key_of(tok)] += int(p[2])
    return freq, sent_files, files


def read_authored(path):
    out = {}   # key -> (spellings [(latin, pct)], floor count)
    with open(path, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            p = line.rstrip('\n').split('\t')
            sp = []
            for item in p[1].split(','):
                m = re.fullmatch(r'([a-z]+):(\d+)', item.strip())
                if m and m.group(1) not in [s for s, _ in sp]:
                    sp.append((m.group(1), int(m.group(2))))
            if not sp or not DEV.match(unicodedata.normalize('NFC', p[0])):
                continue
            floor = int(p[2]) if len(p) > 2 and p[2].strip() else 0
            out[key_of(p[0])] = (sp, floor)
    return out


def shares_from_pairs(counter, max_variants=3, min_share=0.12):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    total = sum(w for _, w in items)
    kept = [(s, w / total) for s, w in items if w / total >= min_share][:max_variants]
    if not kept:
        kept = [(items[0][0], 1.0)]
    z = sum(w for _, w in kept)
    return [(s, w / z) for s, w in kept]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--raw', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--top-natives', type=int, default=40000, help='Hindi words kept by frequency')
    ap.add_argument('--min-freq', type=int, default=3)
    ap.add_argument('--min-bigram', type=int, default=6, help='news bigram count before variant expansion')
    ap.add_argument('--min-trigram', type=int, default=6)
    ap.add_argument('--phrase-scale', type=int, default=150, help='n-gram count per unit of phrase weight')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    pairs, ak_files = read_aksharantar(a.raw)
    freq, sent_files, lp_files = read_leipzig(a.raw)
    authored = read_authored(os.path.join(HERE, 'data', 'common_hinglish.tsv'))

    # 1. Vocabulary: natives by news frequency that can be romanized (Aksharantar) or are authored.
    cand = [(k, f) for k, f in freq.items() if f >= a.min_freq and (k in pairs or k in authored)]
    cand.sort(key=lambda kv: (-kv[1], kv[0]))
    vocab = cand[:a.top_natives]
    in_vocab = {k for k, _ in vocab}
    for k, (sp, floor) in sorted(authored.items()):   # authored words are always in
        if k not in in_vocab:
            vocab.append((k, freq.get(k, 0)))
            in_vocab.add(k)

    shares = {}   # native key -> [(latin, share)]
    counts = {}   # native key -> count
    for k, f in vocab:
        if k in authored:
            sp, floor = authored[k]
            z = sum(p for _, p in sp)
            shares[k] = [(s, p / z) for s, p in sp]
            counts[k] = max(f, floor, 1)
        else:
            shares[k] = shares_from_pairs(pairs[k])
            counts[k] = f

    unigrams = Counter()
    for k in shares:
        for s, sh in shares[k]:
            c = int(round(counts[k] * sh))
            if c >= 1:
                unigrams[s] += c
    clusters = defaultdict(set)
    for k in shares:
        sp = shares[k]
        if len(sp) > 1:
            for s, _ in sp[1:]:
                if s != sp[0][0]:
                    clusters[sp[0][0]].add(s)

    # 2. Authored English-mixed words and phrases.
    auth_uni = Counter()
    with open(os.path.join(HERE, 'data', 'english_mixed_words.tsv'), encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            w, c = line.rstrip('\n').split('\t')
            if LATIN.match(w):
                auth_uni[w] += int(c)
    auth_ng = Counter()
    with open(os.path.join(HERE, 'data', 'mixed_phrases.tsv'), encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            sent, w = line.rstrip('\n').split('\t')
            toks = sent.split()
            wt = int(w)
            for t in toks:
                auth_uni[t] += wt * 20
            for n in (2, 3):
                for i in range(len(toks) - n + 1):
                    auth_ng[' '.join(toks[i:i + n])] += wt * a.phrase_scale

    # 3. News n-grams through the romanization.
    index = {k: i for i, k in enumerate(sorted(shares))}
    n_words = len(index)
    big = Counter()
    sents = 0
    for path in sent_files:
        with open(path, encoding='utf-8') as f:
            for line in f:
                sents += 1
                p = line.split('\t', 1)
                if len(p) < 2:
                    continue
                prev = None
                for tok in TOKEN.findall(p[1]):
                    i = index.get(key_of(tok)) if DEV.match(tok) else None
                    if prev is not None and i is not None:
                        big[prev * n_words + i] += 1
                    prev = i
    keep_big = {b for b, c in big.items() if c >= a.min_bigram}
    tri = Counter()
    for path in sent_files:
        with open(path, encoding='utf-8') as f:
            for line in f:
                p = line.split('\t', 1)
                if len(p) < 2:
                    continue
                w1 = w2 = None
                for tok in TOKEN.findall(p[1]):
                    i = index.get(key_of(tok)) if DEV.match(tok) else None
                    if i is not None and w1 is not None and w2 is not None \
                            and (w1 * n_words + w2) in keep_big and (w2 * n_words + i) in keep_big:
                        tri[(w1, w2, i)] += 1
                    w1, w2 = w2, i
    natives = sorted(index, key=index.get)
    ngrams = Counter()
    for b, c in big.items():
        if c < a.min_bigram:
            continue
        x, y = divmod(b, n_words)
        for sa, pa in shares[natives[x]]:
            for sb, pb in shares[natives[y]]:
                v = int(round(c * pa * pb))
                if v >= 2 and sa != sb:
                    ngrams[sa + ' ' + sb] += v
    for (x, y, z), c in tri.items():
        if c < a.min_trigram:
            continue
        for sa, pa in shares[natives[x]]:
            for sb, pb in shares[natives[y]]:
                for sc, pc in shares[natives[z]]:
                    v = int(round(c * pa * pb * pc))
                    if v >= 2:
                        ngrams[sa + ' ' + sb + ' ' + sc] += v

    # 4. Write (sorted, so the output is deterministic).
    def write_tsv(name, counter, header):
        with open(os.path.join(a.out, name), 'w', encoding='utf-8') as f:
            f.write('# %s\n' % header)
            for k in sorted(counter, key=lambda s: (-counter[s], s)):
                f.write('%s\t%d\n' % (k, counter[k]))

    write_tsv('unigrams-derived.tsv', unigrams, 'romanized Hindi unigrams: Leipzig news frequency x Aksharantar spellings')
    write_tsv('ngrams-derived.tsv', ngrams, 'romanized Hindi n-grams from Leipzig news sentences')
    write_tsv('unigrams-authored.tsv', auth_uni, 'project-authored English-mixed words and phrase tokens (CC0-1.0)')
    write_tsv('ngrams-authored.tsv', auth_ng, 'project-authored code-switched phrase n-grams (CC0-1.0)')
    with open(os.path.join(a.out, 'clusters.tsv'), 'w', encoding='utf-8') as f:
        f.write('# variant clusters: canonical<TAB>variants (space separated). Derived data, CC-BY-SA-4.0 (docs/HINGLISH.md).\n')
        for c in sorted(clusters):
            f.write('%s\t%s\n' % (c, ' '.join(sorted(clusters[c]))))

    sources = {'sources': [
        {'id': 'hinglish-derived-unigrams', 'path': 'unigrams-derived.tsv', 'kind': 'unigram', 'spdx': 'CC-BY-SA-4.0',
         'attribution': 'Romanized from Leipzig Corpora Collection Hindi news 2019/2020 (CC BY 4.0, Goldhahn, Eckart, '
                        'Quasthoff 2012) frequencies and AI4Bharat Aksharantar Hindi transliteration pairs (CC BY / CC0; '
                        'rows sourced from Google Dakshina are CC BY-SA 4.0, Roark et al. 2020; Madhani et al. 2022)',
         'url': 'https://huggingface.co/datasets/ai4bharat/Aksharantar', 'version': 'Aksharantar hin.zip 2022; Leipzig hin_news_2019_300K, hin_news_2020_300K'},
        {'id': 'hinglish-derived-ngrams', 'path': 'ngrams-derived.tsv', 'kind': 'ngram', 'spdx': 'CC-BY-SA-4.0',
         'attribution': 'Same sources as hinglish-derived-unigrams',
         'url': 'https://wortschatz.uni-leipzig.de/en/download', 'version': 'Leipzig hin_news_2019_300K, hin_news_2020_300K'},
        {'id': 'hinglish-authored-unigrams', 'path': 'unigrams-authored.tsv', 'kind': 'unigram', 'spdx': 'CC0-1.0',
         'attribution': 'iBoard project-authored word list', 'url': 'https://github.com/shubhamsinghshubham777/iBoard'},
        {'id': 'hinglish-authored-ngrams', 'path': 'ngrams-authored.tsv', 'kind': 'ngram', 'spdx': 'CC0-1.0',
         'attribution': 'iBoard project-authored phrases', 'url': 'https://github.com/shubhamsinghshubham777/iBoard'},
    ]}
    with open(os.path.join(a.out, 'sources.json'), 'w', encoding='utf-8') as f:
        json.dump(sources, f, indent=2, sort_keys=True)
        f.write('\n')
    prov = {'rawFiles': {os.path.relpath(p, a.raw): sha256(p) for p in sorted(ak_files + lp_files)},
            'authoredFiles': {n: sha256(os.path.join(HERE, 'data', n))
                              for n in ('common_hinglish.tsv', 'english_mixed_words.tsv', 'mixed_phrases.tsv')}}
    with open(os.path.join(a.out, 'provenance.json'), 'w', encoding='utf-8') as f:
        json.dump(prov, f, indent=2, sort_keys=True)
        f.write('\n')
    stats = {'nativeWords': len(shares), 'authoredClusters': len(authored), 'spellings': len(unigrams),
             'clustersWithVariants': len(clusters), 'sentences': sents, 'ngrams': len(ngrams),
             'authoredNgrams': len(auth_ng), 'authoredUnigrams': len(auth_uni),
             'options': {'topNatives': a.top_natives, 'minFreq': a.min_freq, 'minBigram': a.min_bigram,
                         'minTrigram': a.min_trigram, 'phraseScale': a.phrase_scale}}
    with open(os.path.join(a.out, 'stats.json'), 'w', encoding='utf-8') as f:
        json.dump(stats, f, indent=2, sort_keys=True)
        f.write('\n')
    print(json.dumps(stats, sort_keys=True))


if __name__ == '__main__':
    main()

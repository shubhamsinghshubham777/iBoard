#!/usr/bin/env python3
"""Deterministic generator of the English LexiconBuilder inputs (M2-01 data).

    python3 -I Tools/EnglishData/generate.py --raw /private/tmp/claude-501/english-data --out <work>/inputs

Inputs (never committed, see fetch.sh):
  <raw>/scowl/scowl-2020.12.07/        SCOWL 2020.12.07 (final/ word lists, Copyright, misc/offensive.*)
  <raw>/lz/x/eng_news_2023_1M/*-sentences.txt, eng_news_2024_1M   Leipzig Corpora Collection English news
Project-authored inputs (committed, CC0-1.0): data/contractions.tsv, data/phrases.tsv.

Method
  * Vocabulary = SCOWL words of size <= 70 (US + GB-ise spellings, lowercased, no possessive/abbreviation noise, no
    slurs from misc/offensive.*) + common proper nouns (SCOWL proper-names <= 50, upper <= 60), + SCOWL contractions
    <= 70, + project contractions/casual forms, + corpus-frequent lowercase tokens SCOWL lacks (COUNT >= ADD_MIN),
    + possessive "x's" attested >= POSS_MIN in the corpus when "x" is in the vocabulary.
  * Unigram counts: every vocabulary word gets a floor count of 1 (SCOWL source), plus its token count in the news
    corpora, plus the authored per-million rate scaled to the corpus size.
  * N-grams: all sentences are tokenised (lowercase, curly apostrophes folded, words are letter runs with at most one
    inner apostrophe group); any non-word token (digits, punctuation, out-of-vocabulary word) breaks the chain.
    Bigrams with count >= 2 are kept, trigrams with count >= 2 whose two bigrams are kept. Authored phrases add
    pair/triple counts (per-million rate scaled to the corpus size).
Output (in --out): unigrams-scowl.tsv, unigrams-corpus.tsv, unigrams-authored.tsv, ngrams-corpus.tsv,
ngrams-authored.tsv, sources.json, provenance.json, stats.json. Same inputs -> byte-identical outputs.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
import unicodedata
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SCOWL_VERSION = '2020.12.07'
CORPORA = ['eng_news_2023_1M', 'eng_news_2024_1M']
SIZE_WORDS = 70        # SCOWL size level for ordinary words
SIZE_UPPER = 60        # capitalised ordinary words (e.g. nationalities, months)
SIZE_NAMES = 50        # proper names (places, common first/last names)
ADD_MIN = 400          # corpus-only words need at least this many tokens (of ~39M)
ADD_MINLEN = 3
POSS_MIN = 40
CORPUS_SKIP = {'https', 'http', 'www', 'html', 'htm', 'amp', 'nbsp', 'jpg', 'png'}   # web-markup noise in news text
MIN_BIGRAM = 2
MIN_TRIGRAM = 2

LETTERS = r"[^\W\d_]+"
WORD_RE = re.compile(r"^%s$" % LETTERS)
APOS_RE = re.compile(r"^%s'%s$" % (LETTERS, LETTERS))
TOKEN_RE = re.compile(r"%s(?:'%s)*|[^\W_]*\d[^\s]*|[^\w\s]" % (LETTERS, LETTERS))


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def norm(w):
    return unicodedata.normalize('NFC', w.replace('’', "'").replace('‘', "'")).lower()


def read_lines_latin1(path):
    with open(path, encoding='latin-1') as f:
        for line in f:
            w = line.rstrip('\n')
            if w:
                yield w


def read_scowl(raw):
    root = os.path.join(raw, 'scowl', 'scowl-' + SCOWL_VERSION)
    final = os.path.join(root, 'final')
    levels = {'words': SIZE_WORDS, 'upper': SIZE_UPPER, 'proper-names': SIZE_NAMES, 'contractions': SIZE_WORDS}
    vocab, contractions, files = set(), set(), []
    for kind, maxlevel in sorted(levels.items()):
        for cat in ('english', 'american', 'british'):
            for path in sorted(glob.glob(os.path.join(final, '%s-%s.*' % (cat, kind)))):
                level = int(path.rsplit('.', 1)[1])
                if level > maxlevel:
                    continue
                files.append(path)
                for w in read_lines_latin1(path):
                    w = norm(w)
                    if kind == 'contractions':
                        if APOS_RE.match(w):
                            contractions.add(w)
                    elif WORD_RE.match(w):
                        vocab.add(w)
                    # possessives and other apostrophe forms are admitted through the corpus (POSS_MIN) instead
    blocked = set()
    for name in ('offensive.1', 'offensive.2'):
        path = os.path.join(root, 'misc', name)
        files.append(path)
        for w in read_lines_latin1(path):
            blocked.add(norm(w).replace("'s", ''))
    return vocab, contractions, blocked, files, os.path.join(root, 'Copyright')


def read_rates(path):
    out = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            k, v = line.rstrip('\n').split('\t')
            out[norm(k)] = out.get(norm(k), 0) + int(v)
    return out


def sentence_files(raw):
    out = []
    for c in CORPORA:
        out.append(os.path.join(raw, 'lz', 'x', c, c + '-sentences.txt'))
    for p in out:
        if not os.path.isfile(p):
            sys.exit('missing %s (run Tools/EnglishData/fetch.sh)' % p)
    return out


def tokens_of(line):
    # Leipzig line: "<id>\t<sentence>"
    tab = line.find('\t')
    return TOKEN_RE.findall(norm(line[tab + 1:]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--raw', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    scowl, scowl_contr, blocked, scowl_files, copyright_path = read_scowl(a.raw)
    contr_rates = read_rates(os.path.join(HERE, 'data', 'contractions.tsv'))
    sfiles = sentence_files(a.raw)

    # ---- pass 1: unigram counts
    C = Counter()
    sentences = 0
    for p in sfiles:
        with open(p, encoding='utf-8') as f:
            for line in f:
                sentences += 1
                C.update(tokens_of(line))
    total_word_tokens = sum(n for w, n in C.items() if WORD_RE.match(w) or APOS_RE.match(w))
    scale = total_word_tokens / 1e6

    # ---- vocabulary
    vocab = set(scowl)
    vocab |= scowl_contr
    vocab |= set(w for w in contr_rates)
    added_from_corpus = set()
    for w, n in C.items():
        if (n >= ADD_MIN and w.isascii() and WORD_RE.match(w) and len(w) >= ADD_MINLEN and w not in vocab
                and w not in CORPUS_SKIP):
            added_from_corpus.add(w)
    vocab |= added_from_corpus
    poss = set()
    for w, n in C.items():
        if n >= POSS_MIN and APOS_RE.match(w) and w.endswith("'s") and w[:-2] in vocab and w not in vocab:
            poss.add(w)
    vocab |= poss
    vocab = set(w for w in vocab if w not in blocked and len(w) <= 24)
    words = sorted(vocab)
    ids = {w: i for i, w in enumerate(words)}
    N = len(words)

    # coverage of the corpus top-10k by SCOWL alone (before any corpus-driven additions)
    top = [w for w, _ in sorted(((w, n) for w, n in C.items() if WORD_RE.match(w) and len(w) >= 2),
                                key=lambda kv: (-kv[1], kv[0]))[:10000]]
    cover_scowl = sum(1 for w in top if w in scowl or w in scowl_contr)
    cover_final = sum(1 for w in top if w in vocab)

    # ---- pass 2: bigrams
    BG = Counter()
    for p in sfiles:
        with open(p, encoding='utf-8') as f:
            for line in f:
                t = [ids.get(x, -1) for x in tokens_of(line)]
                BG.update(t[i] * N + t[i + 1] for i in range(len(t) - 1) if t[i] >= 0 and t[i + 1] >= 0)
    bigrams_total = len(BG)
    keep = set(k for k, n in BG.items() if n >= MIN_BIGRAM)
    BG = Counter({k: n for k, n in BG.items() if k in keep})
    # ---- pass 3: trigrams (both component bigrams must be kept)
    TG = Counter()
    for p in sfiles:
        with open(p, encoding='utf-8') as f:
            for line in f:
                t = [ids.get(x, -1) for x in tokens_of(line)]
                TG.update((t[i] * N + t[i + 1]) * N + t[i + 2] for i in range(len(t) - 2)
                          if t[i] >= 0 and (t[i] * N + t[i + 1]) in keep and (t[i + 1] * N + t[i + 2]) in keep)
    trigrams_total = len(TG)
    TG = Counter({k: n for k, n in TG.items() if n >= MIN_TRIGRAM})

    def write(name, rows, header):
        with open(os.path.join(a.out, name), 'w', encoding='utf-8', newline='\n') as f:
            f.write('# %s\n' % header)
            for k, v in rows:
                f.write('%s\t%d\n' % (k, v))

    write('unigrams-scowl.tsv', ((w, 1) for w in words),
          'vocabulary floor: SCOWL %s words (size <= %d, US) and common proper nouns, count 1' % (SCOWL_VERSION, SIZE_WORDS))
    write('unigrams-corpus.tsv', sorted(((w, C[w]) for w in words if C[w] > 0), key=lambda kv: (-kv[1], kv[0])),
          'token counts in Leipzig English news 2023 + 2024 (1M sentences each), lowercased')
    auth = {}
    for w, r in contr_rates.items():
        if w in ids:
            auth[w] = max(1, round(r * scale))
    write('unigrams-authored.tsv', sorted(auth.items(), key=lambda kv: (-kv[1], kv[0])),
          'project-authored contraction/casual-form counts (CC0-1.0), per-million rate x corpus scale')

    def ng_rows(counter, order):
        rows = []
        for k, n in counter.items():
            if order == 2:
                a1, b1 = divmod(k, N)
                rows.append((words[a1] + ' ' + words[b1], n))
            else:
                ab, c1 = divmod(k, N)
                a1, b1 = divmod(ab, N)
                rows.append((words[a1] + ' ' + words[b1] + ' ' + words[c1], n))
        rows.sort(key=lambda kv: (-kv[1], kv[0]))
        return rows

    rows = ng_rows(BG, 2) + ng_rows(TG, 3)
    write('ngrams-corpus.tsv', rows, 'bigram/trigram counts from Leipzig English news 2023 + 2024 (count >= 2)')

    ang = Counter()
    with open(os.path.join(HERE, 'data', 'phrases.tsv'), encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            s, wgt = line.rstrip('\n').split('\t')
            t = [norm(x) for x in s.split()]
            if any(x not in ids for x in t):
                sys.exit('authored phrase uses out-of-vocabulary word: %r' % s)
            c = max(1, round(int(wgt) * scale))
            for i in range(len(t) - 1):
                ang[t[i] + ' ' + t[i + 1]] += c
            for i in range(len(t) - 2):
                ang[t[i] + ' ' + t[i + 1] + ' ' + t[i + 2]] += c
    write('ngrams-authored.tsv', sorted(ang.items(), key=lambda kv: (-kv[1], kv[0])),
          'project-authored phrase n-grams (CC0-1.0), per-million rate x corpus scale')

    corpus_attr = ('Leipzig Corpora Collection, English news 2023 and 2024, 1M sentences each (Universitat Leipzig, '
                   'Wortschatz), CC BY 4.0; D. Goldhahn, T. Eckart, U. Quasthoff, LREC 2012')
    corpus_ver = 'eng_news_2023_1M, eng_news_2024_1M'
    scowl_attr = ('SCOWL (Spell Checking Oriented Word Lists) %s, Copyright 2000-2018 Kevin Atkinson; permission '
                  'notice in Data/english/LICENSE.md' % SCOWL_VERSION)
    repo = 'https://github.com/shubhamsinghshubham777/iBoard'
    sources = {'sources': [
        {'id': 'english-scowl-vocabulary', 'path': 'unigrams-scowl.tsv', 'kind': 'unigram', 'spdx': 'LicenseRef-SCOWL',
         'attribution': scowl_attr, 'url': 'http://wordlist.aspell.net/', 'version': 'SCOWL ' + SCOWL_VERSION},
        {'id': 'english-news-unigrams', 'path': 'unigrams-corpus.tsv', 'kind': 'unigram', 'spdx': 'CC-BY-4.0',
         'attribution': corpus_attr, 'url': 'https://wortschatz.uni-leipzig.de/en/download', 'version': corpus_ver},
        {'id': 'english-news-ngrams', 'path': 'ngrams-corpus.tsv', 'kind': 'ngram', 'spdx': 'CC-BY-4.0',
         'attribution': corpus_attr, 'url': 'https://wortschatz.uni-leipzig.de/en/download', 'version': corpus_ver},
        {'id': 'english-authored-unigrams', 'path': 'unigrams-authored.tsv', 'kind': 'unigram', 'spdx': 'CC0-1.0',
         'attribution': 'iBoard project-authored contractions and casual forms', 'url': repo},
        {'id': 'english-authored-ngrams', 'path': 'ngrams-authored.tsv', 'kind': 'ngram', 'spdx': 'CC0-1.0',
         'attribution': 'iBoard project-authored phrases', 'url': repo},
    ]}
    with open(os.path.join(a.out, 'sources.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(sources, f, indent=2, sort_keys=True)
        f.write('\n')

    prov = {'scowl': {'version': SCOWL_VERSION,
                      'files': {os.path.relpath(p, a.raw): sha256(p) for p in scowl_files},
                      'copyright': sha256(copyright_path)},
            'leipzig': {os.path.relpath(p, a.raw): sha256(p) for p in sfiles},
            'authored': {n: sha256(os.path.join(HERE, 'data', n)) for n in ('contractions.tsv', 'phrases.tsv')}}
    with open(os.path.join(a.out, 'provenance.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(prov, f, indent=2, sort_keys=True)
        f.write('\n')

    stats = {
        'sentences': sentences, 'wordTokens': total_word_tokens, 'tokenTypes': len(C),
        'scowlWords': len(scowl), 'scowlContractions': len(scowl_contr), 'authoredWords': len(contr_rates),
        'corpusAddedWords': len(added_from_corpus), 'possessives': len(poss), 'blockedSlurs': len(blocked),
        'vocabulary': N, 'top10kInScowlOnly': cover_scowl, 'top10kInVocabulary': cover_final,
        'bigramTypesSeen': bigrams_total, 'bigramsKept(count>=%d)' % MIN_BIGRAM: len(BG),
        'trigramTypesSeen': trigrams_total, 'trigramsKept(count>=%d)' % MIN_TRIGRAM: len(TG),
        'authoredNgrams': len(ang),
        'params': {'SIZE_WORDS': SIZE_WORDS, 'SIZE_UPPER': SIZE_UPPER, 'SIZE_NAMES': SIZE_NAMES, 'ADD_MIN': ADD_MIN,
                   'ADD_MINLEN': ADD_MINLEN, 'POSS_MIN': POSS_MIN},
        'corpusAddedSample': sorted(added_from_corpus, key=lambda w: (-C[w], w))[:60],
    }
    with open(os.path.join(a.out, 'stats.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(stats, f, indent=2, sort_keys=True)
        f.write('\n')
    print(json.dumps(stats, indent=1))


if __name__ == '__main__':
    main()

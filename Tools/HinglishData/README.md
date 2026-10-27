# HinglishData (M7-01)

Deterministic pipeline that turns open Hindi data plus project-authored casual Hinglish forms into the inputs of
`Tools/LexiconBuilder`, then into `Data/hinglish/lexicon.iblex` and `lm.iblm`.

```sh
Tools/HinglishData/fetch.sh [RAW_DIR]    # downloads Aksharantar hin.zip + Leipzig hin_news 2019/2020 (not committed)
Tools/HinglishData/build.sh [RAW_DIR]    # generate.py -> lexicon-builder -> Data/hinglish/
```

Default `RAW_DIR` is `/private/tmp/claude-501/hinglish-data`. Python 3 standard library only. Same raw data and
authored files give byte-identical outputs (checked by building twice and comparing SHA-256).

- `data/common_hinglish.tsv`: ~440 authored variant clusters (`nahi:48,nhi:30,nahin:12,...`), CC0-1.0.
- `data/english_mixed_words.tsv`, `data/mixed_phrases.tsv`: English words and code-switched phrases, CC0-1.0.
- Sources, licences and attribution: `docs/HINGLISH.md`; builder licence manifest: `Data/hinglish/licenses.json`.

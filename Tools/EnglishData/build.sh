#!/bin/sh
# Rebuilds Data/english/ from the raw sources (M2-01). Raw data is never committed: run fetch.sh first.
#   Tools/EnglishData/build.sh [RAW_DIR]      (default RAW_DIR: /private/tmp/claude-501/english-data)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RAW=${1:-/private/tmp/claude-501/english-data}
WORK=${WORK:-$RAW/inputs}
OUT=$ROOT/Data/english
MAX_BIGRAMS=${MAX_BIGRAMS:-300000}
MAX_TRIGRAMS=${MAX_TRIGRAMS:-240000}
MIN_NGRAM=${MIN_NGRAM:-2}

python3 -I "$ROOT/Tools/EnglishData/generate.py" --raw "$RAW" --out "$WORK" >/dev/null
(cd "$ROOT/Tools/LexiconBuilder" && swift build -c release --product lexicon-builder >/dev/null)
BUILDER=$(cd "$ROOT/Tools/LexiconBuilder" && swift build -c release --show-bin-path)/lexicon-builder
rm -rf "$WORK/out"
"$BUILDER" --sources "$WORK/sources.json" --out "$WORK/out" --min-ngram-count "$MIN_NGRAM" \
  --max-bigrams "$MAX_BIGRAMS" --max-trigrams "$MAX_TRIGRAMS"
mkdir -p "$OUT"
cp "$WORK/out/lexicon.iblex" "$WORK/out/lm.iblm" "$WORK/out/licenses.json" "$WORK/out/size-report.json" "$OUT/"
cp "$WORK/provenance.json" "$WORK/stats.json" "$OUT/"
ls -l "$OUT"

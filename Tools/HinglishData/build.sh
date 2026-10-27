#!/bin/sh
# Rebuilds Data/hinglish/ from the raw corpora (M7-01). Raw data is never committed: run fetch.sh first.
#   Tools/HinglishData/build.sh [RAW_DIR]      (default RAW_DIR: /private/tmp/claude-501/hinglish-data)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RAW=${1:-/private/tmp/claude-501/hinglish-data}
WORK=${WORK:-$RAW/inputs}
OUT=$ROOT/Data/hinglish
MAX_BIGRAMS=${MAX_BIGRAMS:-150000}
MAX_TRIGRAMS=${MAX_TRIGRAMS:-60000}

python3 -I "$ROOT/Tools/HinglishData/generate.py" --raw "$RAW" --out "$WORK"
(cd "$ROOT/Tools/LexiconBuilder" && swift build -c release --product lexicon-builder >/dev/null)
BUILDER=$(cd "$ROOT/Tools/LexiconBuilder" && swift build -c release --show-bin-path)/lexicon-builder
rm -rf "$WORK/out"
"$BUILDER" --sources "$WORK/sources.json" --out "$WORK/out" --min-ngram-count 2 \
  --max-bigrams "$MAX_BIGRAMS" --max-trigrams "$MAX_TRIGRAMS"
mkdir -p "$OUT"
cp "$WORK/out/lexicon.iblex" "$WORK/out/lm.iblm" "$WORK/out/licenses.json" "$WORK/out/size-report.json" "$OUT/"
cp "$WORK/clusters.tsv" "$WORK/provenance.json" "$WORK/stats.json" "$OUT/"
ls -l "$OUT"

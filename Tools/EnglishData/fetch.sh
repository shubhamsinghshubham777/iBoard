#!/bin/sh
# Downloads the raw sources for Tools/EnglishData/generate.py into RAW_DIR (never committed). Verifies SHA-256.
#   Tools/EnglishData/fetch.sh [RAW_DIR]
set -eu
RAW=${1:-/private/tmp/claude-501/english-data}
mkdir -p "$RAW/scowl" "$RAW/lz/x"

get() { # url file sha256
  if [ ! -f "$2" ]; then curl -fsSL "$1" -o "$2"; fi
  echo "$3  $2" | shasum -a 256 -c -
}

get "https://downloads.sourceforge.net/project/wordlist/SCOWL/2020.12.07/scowl-2020.12.07.tar.gz" "$RAW/scowl/scowl.tgz" \
  5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc
tar xzf "$RAW/scowl/scowl.tgz" -C "$RAW/scowl"
get https://downloads.wortschatz-leipzig.de/corpora/eng_news_2023_1M.tar.gz "$RAW/lz/eng_news_2023_1M.tar.gz" \
  c8a5a5e72897aa5e367b0319c1884831c02aaf29bf81342de31ca1b1cc8f3e4c
tar xzf "$RAW/lz/eng_news_2023_1M.tar.gz" -C "$RAW/lz/x"
get https://downloads.wortschatz-leipzig.de/corpora/eng_news_2024_1M.tar.gz "$RAW/lz/eng_news_2024_1M.tar.gz" \
  8f1d4d07b9771f8a7fc219ad587d5382eabf5009ef563f1bc4c12a467a8e3a97
tar xzf "$RAW/lz/eng_news_2024_1M.tar.gz" -C "$RAW/lz/x"
echo "raw data ready in $RAW"

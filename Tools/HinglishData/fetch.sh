#!/bin/sh
# Downloads the raw corpora for Tools/HinglishData/generate.py into RAW_DIR (never committed). Verifies SHA-256.
#   Tools/HinglishData/fetch.sh [RAW_DIR]
set -eu
RAW=${1:-/private/tmp/claude-501/hinglish-data}
mkdir -p "$RAW/aksharantar/x" "$RAW/leipzig/n2020" "$RAW/leipzig/n2019"

get() { # url file sha256
  if [ ! -f "$2" ]; then curl -fsSL "$1" -o "$2"; fi
  echo "$3  $2" | shasum -a 256 -c -
}

get https://huggingface.co/datasets/ai4bharat/Aksharantar/resolve/main/hin.zip "$RAW/aksharantar/hin.zip" \
  208c2d1b128234e6dc777b750779b4f5e6214ab43244039349b530bf9868bdaf
unzip -oq "$RAW/aksharantar/hin.zip" -d "$RAW/aksharantar/x"
get https://downloads.wortschatz-leipzig.de/corpora/hin_news_2020_300K.tar.gz "$RAW/leipzig/hin_news_2020_300K.tar.gz" \
  13788400cac17cd9762796d0465cbd9867a34292a2e838455952988c9a62fea4
tar xzf "$RAW/leipzig/hin_news_2020_300K.tar.gz" -C "$RAW/leipzig/n2020"
get https://downloads.wortschatz-leipzig.de/corpora/hin_news_2019_300K.tar.gz "$RAW/leipzig/hin_news_2019_300K.tar.gz" \
  bdbe3765a88c2f09447da12e6d57a3715fcac4b7904ac32f123b7177d70f2af4
tar xzf "$RAW/leipzig/hin_news_2019_300K.tar.gz" -C "$RAW/leipzig/n2019"
echo "raw data ready in $RAW"

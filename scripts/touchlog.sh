#!/usr/bin/env bash
# Pull the DEBUG touch logs (iBoardKeyboard/TouchRecorder.swift, one file per keyboard process) from the owner's iPhone
# into build/touchlog/<timestamp>/. Usage: scripts/touchlog.sh [device-udid]   (default: the owner's iPhone 12)
# Analyse: python3 -I scripts/touchlog-analyze.py [file]   (default: the biggest of the newest files)
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-00008101-0014596A1E01001E}"
OUT="build/touchlog/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appGroupDataContainer \
  --domain-identifier group.app.iBoard --source Library/Caches/touchlog --destination "$OUT"
ls -l "$OUT" "$OUT"/* 2>/dev/null | tail -12
echo "saved $OUT"

#!/usr/bin/env bash
# Pull the DEBUG touch log (iBoardKeyboard/TouchRecorder.swift) from the owner's iPhone into build/touchlog/.
# Usage: scripts/touchlog.sh [device-udid]   (default: the owner's iPhone 12)
# Replay it: copy to Packages/IBoardUI/Tests/IBoardUITests/Fixtures/ and see TouchLogReplayTests.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-00008101-0014596A1E01001E}"
OUT="build/touchlog/touchlog-$(date +%Y%m%d-%H%M%S).json"
mkdir -p build/touchlog
xcrun devicectl device copy from --device "$DEVICE" --domain-type appGroupDataContainer \
  --domain-identifier group.app.iBoard --source Library/Caches/touchlog.json --destination "$OUT"
echo "saved $OUT"

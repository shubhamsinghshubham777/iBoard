#!/usr/bin/env bash
# On-device perf helper (M1-09 / M13-02). Usage: device-perf.sh build|install|pull|crashes|soak [seconds]
# Env: DEVICE (default owner iPhone 12 UDID), DERIVED_DATA (default build/DeviceDD).
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-00008101-0014596A1E01001E}"
DD="${DERIVED_DATA:-build/DeviceDD}"
OUT=build/device-perf
APP="$DD/Build/Products/Release-iphoneos/iBoard.app"
case "${1:-}" in
  build)
    xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Release -destination "id=$DEVICE" \
      -derivedDataPath "$DD" -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DIBOARD_PERF' build ;;
  install) xcrun devicectl device install app --device "$DEVICE" "$APP" ;;
  pull)
    mkdir -p "$OUT"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier app.iBoard.keyboard --source Library/Caches/perf-metrics.json --destination "$OUT/perf-metrics.json"
    python3 -I - "$OUT/perf-metrics.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d["samples"]
print("peakMB %.1f currentMB %.1f appears %d warnings %d samples %d span %.0fs" % (d["peakMB"],d["currentMB"],d["appearCount"],d["memoryWarnings"],len(s),s[-1][0]-s[0][0]))
for k,v in sorted(d["metrics"].items()): print("  %-24s n=%d p50 %.1f ms p95 %.1f ms"%(k,v["count"],v["p50ms"],v["p95ms"]))
PY
    ;;
  crashes)
    mkdir -p "$OUT/crash"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs --source / --destination "$OUT/crash"
    ls -t "$OUT"/crash/iBoardKeyboard-*.ips 2>/dev/null | head -5 ;;
  soak)
    IBOARD_SOAK_SECONDS="${2:-1800}" xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Debug \
      -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DIBOARD_PERF' \
      -only-testing:iBoardUITests/DevicePerfSoakTests test ;;
  *) echo "usage: $0 build|install|pull|crashes|soak [seconds]"; exit 2 ;;
esac

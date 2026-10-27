#!/usr/bin/env bash
# On-device perf helper (M1-09 / M13-02). Usage: device-perf.sh run|build|install|pull|crashes|soak [seconds]
#   run = build + install + guided steps + pull + pass/fail verdict against ROADMAP §6 (the one command the owner needs).
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
B={"touchDownToHighlight":16.7,"touchUpToInsert":20,"keystrokeToSuggestions":25,"swipeLiftToCandidate":60,"coldStart":250,"warmShow":80}
bad=0
for k,v in sorted(d["metrics"].items()):
    b=B.get(k); ok = b is None or v["p95ms"]<=b
    bad+= (not ok)
    print("  %-24s n=%-5d p50 %6.1f  p95 %6.1f ms  budget %s  %s"%(k,v["count"],v["p50ms"],v["p95ms"],b,"PASS" if ok else "FAIL"))
mem = "PASS" if d["peakMB"]<=30 else ("OVER TARGET (<=40 hard cap)" if d["peakMB"]<=40 else "FAIL (over 40 MB hard cap)")
print("  memory peak %.1f MB vs 30 target / 40 hard: %s; warnings %d"%(d["peakMB"],mem,d["memoryWarnings"]))
print("VERDICT:", "ALL TIMING BUDGETS MET" if not bad else "%d TIMING BUDGET(S) MISSED"%bad)
PY
    ;;
  run)
    "$0" build && "$0" install
    cat <<'GUIDE'

== iBoard perf run (about 5 minutes) ==
Unlock the phone. Open Notes, start a new note, switch to iBoard with the globe key. Then, in order (~1 min each):
  1. Idle 20 s.
  2. Type about 100 characters at normal speed.
  3. Swipe-type 10 words.
  4. Open the emoji panel, scroll to the bottom, wait 10 s, close it.
  5. (Optional, Full Access on) open the clipboard panel, wait 10 s, close it.
  6. Dismiss and re-show the keyboard 20 times (tap outside the note, tap back in).
No need to note times; the numbers are read from the phone afterwards. Do not type anything private: only counts and
timings are recorded, never text.
GUIDE
    printf 'Press Return when you have finished all steps... '; read -r _
    "$0" pull
    echo "Crash logs (should list nothing new):"; "$0" crashes || true ;;
  crashes)
    mkdir -p "$OUT/crash"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs --source / --destination "$OUT/crash"
    ls -t "$OUT"/crash/iBoardKeyboard-*.ips 2>/dev/null | head -5 ;;
  soak)
    IBOARD_SOAK_SECONDS="${2:-1800}" xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Debug \
      -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DIBOARD_PERF' \
      -only-testing:iBoardUITests/DevicePerfSoakTests test ;;
  *) echo "usage: $0 run|build|install|pull|crashes|soak [seconds]"; exit 2 ;;
esac

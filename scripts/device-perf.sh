#!/usr/bin/env bash
# On-device perf helper (M1-09 / M13-02). Usage: device-perf.sh run|auto [--soak S]|build|install|pull|crashes|soak [seconds]
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
    rm -rf "$OUT/perf"; mkdir -p "$OUT"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier app.iBoard.keyboard --source Library/Caches/perf --destination "$OUT/perf"
    python3 -I - "$OUT/perf" <<'PY'
import json,sys,glob,time
runs=[]
for f in sorted(glob.glob(sys.argv[1]+"/**/perf-*.json",recursive=True)):
    try: d=json.load(open(f))
    except Exception: continue
    runs.append(d)
if not runs: print("NO PERF FILES on the device (was the perf build installed and the keyboard used?)"); sys.exit(1)
def n(d): return sum(v["count"] for v in d["metrics"].values())
print("keyboard processes recorded: %d"%len(runs))
for d in runs:
    s=d["samples"]; print("  start %s span %4.0fs peak %5.1f MB appears %2d warnings %d timing samples %d"%(time.strftime("%H:%M:%S",time.localtime(d["processStart"])),s[-1][0]-s[0][0],d["peakMB"],d["appearCount"],d["memoryWarnings"],n(d)))
d=max(runs,key=n); s=d["samples"]
print("Busiest process: start %s, span %.0fs, peakMB %.1f, appears %d"%(time.strftime("%H:%M:%S",time.localtime(d["processStart"])),s[-1][0]-s[0][0],d["peakMB"],d["appearCount"]))
B={"touchDownToHighlight":16.7,"touchUpToInsert":20,"keystrokeToSuggestions":25,"swipeLiftToCandidate":60,"coldStart":250,"warmShow":80}
bad=0
for k,v in sorted(d["metrics"].items()):
    b=B.get(k); ok = b is None or v["p95ms"]<=b
    bad+= (not ok)
    print("  %-24s n=%-5d p50 %6.1f  p95 %6.1f ms  budget %s  %s"%(k,v["count"],v["p50ms"],v["p95ms"],b,"PASS" if ok else "FAIL"))
peak=max(r["peakMB"] for r in runs)
mem = "PASS" if peak<=30 else ("OVER TARGET (<=40 hard cap)" if peak<=40 else "FAIL (over 40 MB hard cap)")
print("  memory peak over all processes %.1f MB vs 30 target / 40 hard: %s; warnings %d"%(peak,mem,sum(r["memoryWarnings"] for r in runs)))
if not d["metrics"]: print("VERDICT: NO TIMING DATA (no typing was recorded in any process)")
else: print("VERDICT:", "ALL RECORDED TIMING BUDGETS MET" if not bad else "%d TIMING BUDGET(S) MISSED"%bad)
PY
    ;;
  auto)
    # FULLY AUTOMATED (no human): Release+IBOARD_PERF build, install, XCUITest drives Notes + the real iBoard keyboard, pull, verdict.
    # Usage: auto [--soak SECONDS]. Needs the phone unlocked and plugged in.
    SOAK=0; [ "${2:-}" = "--soak" ] && SOAK="${3:-1800}"
    xcrun devicectl device info lockState --device "$DEVICE" 2>&1 | grep -q "passcodeRequired: true" && { echo "Phone is locked: unlock it and retry."; exit 3; }
    mkdir -p "$OUT"; "$0" crashes > "$OUT/crashes-before.txt" 2>&1 || true
    rm -rf "$OUT/auto.xcresult" "$OUT/attachments"
    TEST_RUNNER_IBOARD_SOAK_SECONDS="$SOAK" xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Release \
      -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates -resultBundlePath "$OUT/auto.xcresult" \
      ENABLE_TESTABILITY=YES OTHER_SWIFT_FLAGS='$(inherited) -DIBOARD_PERF' -only-testing:iBoardUITests/DevicePerfAutoTests/testAuto test \
      > "$OUT/auto.log" 2>&1 || { echo "xcodebuild test failed, see $OUT/auto.log"; tail -15 "$OUT/auto.log"; exit 1; }
    xcrun xcresulttool export attachments --path "$OUT/auto.xcresult" --output-path "$OUT/attachments" >/dev/null 2>&1 || true
    "$0" pull | tee "$OUT/verdict.txt"
    "$0" crashes > "$OUT/crashes-after.txt" 2>&1 || true
    echo "NEW crash logs since start:"; comm -13 <(sort "$OUT/crashes-before.txt") <(sort "$OUT/crashes-after.txt") | sed 's/^/  /'
    echo "(screenshots: $OUT/attachments)"
    grep -q "NO TIMING DATA\|NO PERF FILES" "$OUT/verdict.txt" && { echo "RUN FAILED: typing was not recorded"; exit 1; }
    exit 0 ;;
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
    ls "$OUT"/crash/iBoardKeyboard-*.ips 2>/dev/null | xargs -n1 basename 2>/dev/null || true ;;
  soak)
    IBOARD_SOAK_SECONDS="${2:-1800}" xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Debug \
      -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DIBOARD_PERF' \
      -only-testing:iBoardUITests/DevicePerfSoakTests test ;;
  *) echo "usage: $0 run|build|install|pull|crashes|soak [seconds]"; exit 2 ;;
esac

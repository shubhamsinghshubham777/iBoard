#!/usr/bin/env bash
# Run the privacy audit, `swift test` in every Packages/* dir and Tools/LexiconBuilder, then xcodebuild tests on an
# iPhone simulator.
# Usage: scripts/test.sh [--no-ui] [--packages-only | --xcode-only]
#   --no-ui skips the iBoardUITests target; --packages-only skips xcodebuild;
#   --xcode-only skips the audit and swift test.
# Env: DERIVED_DATA (default build/DerivedData), SIM_NAME (force a simulator name).
set -euo pipefail
cd "$(dirname "$0")/.."

NO_UI=0
RUN_PACKAGES=1
RUN_XCODE=1
for a in "$@"; do
  case "$a" in
    --no-ui) NO_UI=1 ;;
    --packages-only) RUN_XCODE=0 ;;
    --xcode-only) RUN_PACKAGES=0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if [ "$RUN_PACKAGES" = 1 ]; then
  echo "== privacy audit"
  scripts/audit-privacy.sh

  for pkg in Packages/*/ Tools/LexiconBuilder/; do
    [ -f "$pkg/Package.swift" ] || continue
    echo "== swift test: $pkg"
    (cd "$pkg" && swift test)
  done
fi

if [ "$RUN_XCODE" = 0 ]; then exit 0; fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
fi

if [ project.yml -nt iBoard.xcodeproj/project.pbxproj ] && command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

# Pick an available iPhone simulator: SIM_NAME, else a booted iPhone, else the first available one.
udid=$(python3 - <<'PY'
import json, os, subprocess
d = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
want = os.environ.get("SIM_NAME")
import re
need = 27  # project.yml deploymentTarget iOS 27.0: older runtimes cannot be destinations
def ok(rt):
    m = re.search(r"iOS-(\d+)", rt)
    return bool(m) and int(m.group(1)) >= need
alld = [x for rt, xs in d["devices"].items() if ok(rt) for x in xs]
if want:  # an explicit name may be any simulator (custom names, iPhone Duo)
    devs = [x for x in alld if x["name"] == want]
else:
    devs = [x for x in alld if x["name"].startswith("iPhone") and "Duo" not in x["name"]]
devs.sort(key=lambda x: x["state"] != "Booted")
print(devs[0]["udid"] if devs else "")
PY
)
if [ -z "$udid" ]; then
  if [ "${IBOARD_SKIP_IF_NO_SIM:-0}" = 1 ]; then
    echo "test.sh: no iOS 27 simulator on this machine (hosted runners ship Xcode 26); skipping simulator tests" >&2
    exit 0
  fi
  echo "test.sh: no available iPhone simulator with an iOS 27 runtime" >&2
  exit 1
fi
echo "== xcodebuild test on simulator $udid"

args=(-project iBoard.xcodeproj -scheme iBoard -destination "id=$udid"
      -derivedDataPath "${DERIVED_DATA:-build/DerivedData}")
if [ "$NO_UI" = 1 ]; then
  args+=(-skip-testing:iBoardUITests)
fi
xcodebuild "${args[@]}" test

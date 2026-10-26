#!/usr/bin/env bash
# Build the iBoard app + keyboard extension for the iOS Simulator.
# Env: DERIVED_DATA (default build/DerivedData), CONFIGURATION (default Debug).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "build.sh: created Config/Local.xcconfig from example"
fi

if [ project.yml -nt iBoard.xcodeproj/project.pbxproj ] && command -v xcodegen >/dev/null 2>&1; then
  echo "build.sh: project.yml is newer; running xcodegen"
  xcodegen generate
fi

xcodebuild -project iBoard.xcodeproj -scheme iBoard \
  -configuration "${CONFIGURATION:-Debug}" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${DERIVED_DATA:-build/DerivedData}" \
  build

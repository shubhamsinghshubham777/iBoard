#!/usr/bin/env bash
# Restores the agent skills that this open-source repo cannot redistribute.
# MIT-licensed skills (iPhone Duo, swift-concurrency) are vendored in .agents/skills already.
#
#   1. Apple's skills, exported from the Xcode selected by xcode-select.
#   2. dpearson2699/swift-ios-skills (PolyForm Perimeter), fetched with the skills CLI.
#
# Safe to re-run. Requires Xcode 27+ and Node.js (npx).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$ROOT/.agents/skills"
CLAUDE_DIR="$ROOT/.claude/skills"
mkdir -p "$SKILLS_DIR" "$CLAUDE_DIR"

# --- 1. Apple skills from Xcode -------------------------------------------
# Requires Xcode 27.1+ (app-resizability replaced uikit-app-modernization in 27.1).
APPLE_SKILLS=(
  swiftui-specialist
  swiftui-whats-new-27
  app-intents-specialist
  app-intents-whats-new-27
  app-resizability
  device-interaction
  modernize-tests
)

EXPORT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXPORT_DIR"' EXIT
(cd "$EXPORT_DIR" && xcrun agent skills export >/dev/null)

for skill in "${APPLE_SKILLS[@]}"; do
  src="$EXPORT_DIR/xcode-skills/$skill"
  if [[ -d "$src" ]]; then
    rm -rf "${SKILLS_DIR:?}/$skill"
    cp -R "$src" "$SKILLS_DIR/$skill"
    ln -sfn "../../.agents/skills/$skill" "$CLAUDE_DIR/$skill"
    echo "apple: $skill"
  else
    echo "apple: $skill not provided by this Xcode ($(xcodebuild -version | head -1)), skipped"
  fi
done

# --- 2. Community skills that are source-available, not open source -------
npx -y skills add dpearson2699/swift-ios-skills \
  --skill debugging-instruments \
  --skill ios-memgraph-analysis \
  --skill app-store-review \
  --skill ios-accessibility \
  -y </dev/null

echo "Done. Skills in $SKILLS_DIR are linked into $CLAUDE_DIR."

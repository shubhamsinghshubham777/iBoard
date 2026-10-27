#!/usr/bin/env bash
# Static privacy audit (CLAUDE.md hard rule: never log or persist typed text; no network from the keyboard).
# Greps the Swift source tree for code that could log typed text, persist it outside the personal store,
# reach the network, or ship analytics. Reviewed exceptions live in scripts/audit-privacy.allowlist.
# This is a tripwire for review, not proof: it cannot see data flow. Exit 1 on any non-allowlisted hit.
# Usage: scripts/audit-privacy.sh [--list-allowed]
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOW=scripts/audit-privacy.allowlist
SHOW_ALLOWED=0
if [ "${1:-}" = "--list-allowed" ]; then SHOW_ALLOWED=1; fi

# Shipped code only: package Sources, the keyboard extension, the app. Tests, Tools and scripts are out of scope.
ROOTS=()
for d in Packages/*/Sources iBoard iBoardKeyboard; do [ -d "$d" ] && ROOTS+=("$d"); done

failures=0
allowed=0

is_allowed() { # rule file
  [ -f "$ALLOW" ] || return 1
  local rule="$1" file="$2" r p
  while IFS='|' read -r r p _; do
    case "$r" in ''|\#*) continue ;; esac
    [ "$r" = "$rule" ] || continue
    case "$file" in "$p"*) return 0 ;; esac
  done < "$ALLOW"
  return 1
}

# scan RULE DESCRIPTION ERE [post-filter ERE of lines to ignore]
scan() {
  local rule="$1" desc="$2" re="$3" ignore="${4:-}" hits line file
  hits=$(grep -rnE --include='*.swift' -e "$re" "${ROOTS[@]}" 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  if [ -n "$ignore" ]; then hits=$(printf '%s\n' "$hits" | grep -vE -e "$ignore" || true); fi
  if [ -z "$hits" ]; then return 0; fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    file=${line%%:*}
    if is_allowed "$rule" "$file"; then
      allowed=$((allowed + 1))
      if [ "$SHOW_ALLOWED" = 1 ]; then echo "allowed [$rule] $line"; fi
    else
      echo "FAIL [$rule] $desc"
      echo "     $line"
      failures=$((failures + 1))
    fi
  done <<< "$hits"
}

scan LOG       "logging call (never log values in shipped code)" \
  '(^|[^A-Za-z0-9_.])(print|debugPrint|dump|NSLog|os_log|fputs)\(|(^|[^A-Za-z0-9_])Logger\(|OSLog\(|FileHandle\.standardError|standardOutput|\bos_signpost\('
scan SIGNPOST  "signpost with interpolated value not marked public-numeric" \
  'signposter\.[A-Za-z]+\(.*\\\(' 'privacy: \.public'
scan STRDESC   "stringified value (String(describing:/reflecting:) can leak text into UI or logs)" \
  'String\((describing|reflecting):'
scan NETWORK   "network API (no network from the keyboard; app features must be opt-in)" \
  'URLSession|URLRequest|NWConnection|NWPathMonitor|NWListener|import Network|CFNetwork|WKWebView|SFSafariViewController|MultipeerConnectivity|CFStream|URLSessionWebSocketTask'
scan ANALYTICS "analytics / crash-reporting / telemetry" \
  'Firebase|Crashlytics|Sentry|Mixpanel|Amplitude|TelemetryDeck|AppCenter|Bugsnag|PostHog|AppsFlyer|import Segment|import Adjust|MetricKit|MXMetricManager'
scan PASTEBOARD "pasteboard access (typed text must not be copied implicitly)" 'UIPasteboard'
scan WRITE     "persistence outside reviewed stores (file or UserDefaults write)" \
  '\.write\(to|createFile|FileHandle\(forWriting|forWritingTo|NSKeyedArchiver|\.set\(.*forKey|\.setValue\(.*forKey|\.removeObject\(forKey|\.register\(defaults|SecItemAdd|CoreData|NSPersistent|SwiftData|ModelContainer|NSUbiquitousKeyValueStore' \
  '\b(storage|self\.storage|defaults\?|store)\.set\(try\?'

# Dead allowlist entries mean a reviewed exception no longer exists; flag so the list stays honest.
if [ -f "$ALLOW" ]; then
  while IFS='|' read -r r p _; do
    case "$r" in ''|\#*) continue ;; esac
    if [ ! -e "$p" ]; then echo "FAIL [ALLOWLIST] stale entry, path not found: $p"; failures=$((failures + 1)); fi
  done < "$ALLOW"
fi

# Sync/CloudKit must stay out of the keyboard extension (no network from the keyboard; memory budget).
# 1) Source graph: the extension target's dependencies in project.yml must not include sync packages.
ext_deps=$(awk '/^  iBoardKeyboard:/{f=1;next} f&&/^  [A-Za-z]/{f=0} f' project.yml)
if printf '%s\n' "$ext_deps" | grep -qE 'IBoard(Personal)?Sync'; then
  echo "FAIL [EXT-SYNC] iBoardKeyboard target depends on a sync package in project.yml"; failures=$((failures + 1))
fi
# 2) Package graph: no other package may depend on a sync package (app-only: IBoardSync, IBoardPersonalSync).
for pk in Packages/*/Package.swift; do
  case "$pk" in Packages/IBoardSync/*|Packages/IBoardPersonalSync/*) continue ;; esac
  if grep -qE '\.package\(path: "\.\./IBoard(Personal)?Sync"' "$pk"; then
    echo "FAIL [EXT-SYNC] $pk depends on a sync package (would link CloudKit into the keyboard)"; failures=$((failures + 1))
  fi
done
# 3) Built binary (when present; DERIVED_DATA output or EXT_BINARY=<path>): no CloudKit link, no sync symbols.
EXT_BIN=${EXT_BINARY:-$(find "${DERIVED_DATA:-build/DerivedData}" -path '*iBoardKeyboard.appex/iBoardKeyboard' -type f 2>/dev/null | head -1 || true)}
if [ -n "$EXT_BIN" ] && [ -f "$EXT_BIN" ]; then
  if otool -L "$EXT_BIN" | grep -q CloudKit; then
    echo "FAIL [EXT-SYNC] $EXT_BIN links CloudKit.framework"; failures=$((failures + 1))
  fi
  if nm "$EXT_BIN" 2>/dev/null | grep -qE 'IBoardSync|IBoardPersonalSync'; then
    echo "FAIL [EXT-SYNC] $EXT_BIN contains IBoardSync symbols"; failures=$((failures + 1))
  fi
else
  echo "audit-privacy: note: no built extension binary found, skipped binary check"
fi

if [ "$failures" -gt 0 ]; then
  echo "audit-privacy: $failures finding(s). Fix the code, or add a reviewed entry to $ALLOW with a reason."
  exit 1
fi
echo "audit-privacy: OK ($allowed allowlisted hit(s) across ${#ROOTS[@]} source roots)"

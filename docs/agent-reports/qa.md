# QA report (2026-10-27)

## Results
- `scripts/test.sh` (SIM_NAME=qa-iphone iPhone 12 sim, DERIVED_DATA=build/QADD): privacy audit, all `swift test` suites
  (Core, Emoji, Engine incl. ReaderBenchmarks, Layout, OTP, Sync, Theme, UI, LexiconBuilder) green in a full run; no R-11
  flake reproduced. iBoardTests green. iBoardUITests: 7/7 on iPhone 12 and 7/7 on the iPhone Duo sim (iOS 27.1).
- New UI tests (`iBoardUITests/iBoardUITests.swift`): onboarding next/back/done and skip, post-onboarding launch, settings
  (clipboard and haptic toggles, toggle flips, iCloud sync screen), theme studio, dictionary manager add-field validation.
  Tests work for compact stack and regular sidebar layouts. Onboarding is pinned with `-onboarding.completed YES/NO`.
- `scripts/test.sh`: SIM_NAME now accepts any simulator name (previously filtered to names starting with "iPhone", so
  custom/Duo sims were rejected: "no available iPhone simulator"). CI: added `ios-ui-tests` job; other jobs match scripts.

## Warnings for other owners (Swift 6 concurrency)
- KEYBOARD3: `iBoardKeyboard/KeyboardViewController.swift` ~1674-1679 (and further): many "main actor-isolated
  textDocumentProxy / insertText / deleteBackward / setMarkedText / unmarkText / adjustTextPosition referenced from a
  nonisolated context". Mark the enclosing type/functions `@MainActor` or hop with `MainActor.assumeIsolated`.
- KEYBOARD3: `Packages/IBoardEmoji/Sources/IBoardEmoji/EmojiPanelView.swift:412` uses deprecated `UIScreen.main`
  (iOS 26); use the view's window scene screen (also needed for Duo, D-24).
- Test-only warnings in iBoardUITests fixed (class is `@MainActor`).

## Notes
- Test sims created: `qa-iphone`, `qa-duo` (delete when done).
- UI test suite takes ~3 min on a simulator; the haptic switch must be tapped at its trailing edge, not the row centre.

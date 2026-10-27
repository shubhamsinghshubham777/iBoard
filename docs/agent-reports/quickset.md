# QUICKSET report (2026-10-27)

## 1. Emoji-key long-press popup redesign — [~]
- The popup is the strip's alternates row (D-08). Now: rounded plate in the key colour with a soft shadow (follows light/dark and
  theme skin), tiles of 44 pt, SF Symbols `doc.on.clipboard` and `gearshape` as images (`KeyAlternates.symbolName`), highlighted
  tile is a subtle label-colour tint (14 %) instead of the solid blue rectangle. Letter alternates use the same plate/highlight.
- VoiceOver: icon views carry "Quick settings" / "Clipboard history"; the emoji key also gets VoiceOver custom actions with the
  same choices (the long press itself is not reachable by VoiceOver). `KeyAlternates.settingsGlyph` is now a sentinel only.
- Verified: UIKit renders on the iPhone 12 simulator (`QuickSettingsRenderTests`, PNGs with `TEST_RUNNER_IBOARD_RENDER_DIR`),
  light/dark/letters inspected. Not verified on device: real feel, sizing against the live strip height, shadow on glass backdrop.

## 2. Quick Settings panel — [~]
- Gear now opens an in-keyboard panel (`QuickSettingsPanelView`, host `iBoardKeyboard/QuickSettingsHost.swift`): haptic pack,
  autocorrect level (segmented), number row, swipe typing, incognito, landscape side keys (switches), and a row
  "Open iOS Keyboard Settings (Full Access)" calling the existing `openSettingsPage` (Settings only; D-01/4.4.1 kept).
- Created on open, dropped on close (small view tree, no table, nothing resident), replaces the key area like emoji/clipboard.
  Dynamic Type via UIFontMetrics (capped; content scrolls), VoiceOver labels/values, no animation (Reduce Motion needs none).
- Persistence (`IBoardCore/QuickSettings.swift`, documented there): `SettingsOverrides` (extension-local, optional per field) is merged
  OVER the app's App Group settings (`QuickSettingsStore.effective()`, used at every keyboard appearance). Edits always go to the
  override; with Full Access they are also written to the App Group blob and the override for that field is dropped (app wins
  again). Without Full Access the app does not see the edit and the override masks later app changes to that field (P-23).
  Incognito stays the existing keyboard-local key and is never written to the app. No typed text anywhere. 4 new Core tests.
- Panel render checked in the simulator PNGs, but `layer.render` draws UISwitch/segmented chrome poorly (white knob), and the
  Accessibility-XL render did not re-scale fonts offscreen. NOT verified: on-device look, large-text layout, VoiceOver traversal,
  memory number (no measurement; expected negligible), that edits to number row/side keys relayout live on device.

## 3. App toggle — [x]
- `iBoard/SettingsView.swift`: "Landscape side keys" toggle (Layout section); `IBoardSettings.landscapeSideKeys` (default true,
  tolerant decode, no version bump); keyboard passes it into `LayoutSettings`. Builds; not run in the UI.

## 4. Warnings — [~]
- `ProxyAdapter` is now `@MainActor` with `@preconcurrency TextProxy` conformance (all text-proxy isolation warnings gone).
- `requestSystemLexicon` copies `UILexicon` through key-value coding (the SDK marks it main-actor although UIKit calls back off-main,
  P-25), same strings as before. NEEDS DEVICE: confirm text replacements (omw) still expand.
- `EmojiPanelView`: `UIScreen.main.scale` replaced by the cell's `traitCollection.displayScale` (3 when not yet in a window).
- `scripts/build.sh` log shows no warnings from iBoardKeyboard/IBoardUI/IBoardEmoji/IBoardCore.

## Checks run
`scripts/build.sh` OK; `swift test` in every package OK (Core 42, Emoji 27, Engine 251, Layout 47, OTP 11, UI 267, ...);
`scripts/test.sh --no-ui` OK (SIM_NAME="iPhone 12"); `scripts/audit-privacy.sh` OK after one reviewed allowlist line
(QuickSettings.swift). UI tests and device install not run (per instructions).

## Follow-ups
- Roadmap: P-23 note (overrides layer), `landscapeSideKeys` in settings, M8-04 "no app toggle yet" now done (ROADMAP not edited).

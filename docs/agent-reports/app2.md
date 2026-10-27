# APP2 report (2026-10-27)

## Done
- M10-02: `IBoardSettings` v4 adds `clipboardHistory` (default off) and `clipboardTTL` (`ClipboardTTL`: 5 min / 1 h / 1 day, default 1 h); tolerant decode, v3 migration tests. Settings UI: haptic pack picker (+ explanation), clipboard section (toggle, TTL, Full Access note).
- Full Access wording (ContentView step 4, About, Onboarding): iBoard does not need Full Access to type; if the user turns it on it enables exactly haptics, clipboard history, sharing dictionary/counters with the app, iCloud sync (P-23).
- M11-06: `ContentView` uses `NavigationSplitView` (sidebar: set up, settings, theme studio, dictionary, insights, about) when horizontalSizeClass is regular, otherwise the previous stack. `ThemeStudioView` puts the live preview beside the editor in regular width.
- Build and `scripts/test.sh --no-ui` pass.

## Not verified / follow-ups
- Wide layout NOT seen on screen: no iPad sim; the Duo sim screenshot was all black (simctl captured the wrong/off display). Needs a look.
- Keyboard (KEYBOARD2) must read `clipboardHistory`/`clipboardTTL`: `recordClipboardIfChanged` currently ignores them (and `ClipboardHistory(ttl:)` should take `clipboardTTL.seconds`).
- project.yml has `RequestsOpenAccess: false`: with that, iOS may not show the Full Access switch at all, so the optional features cannot be enabled. Owner should confirm; the wording assumes the switch is available.
- Not done: M10-01/M10-05 polish beyond wording; `emojiSuggestions` still unused by keyboard.

# Device session — M0-05 / M0-08 / M0-09 on the owner's iPhone 12 (iOS 27.0), 2026-10-26

Throwaway probe keyboard (not committed) with `RequestsOpenAccess = true`, run by the owner in real apps; results read from a
log file pulled with `devicectl` (counts only, never typed text) plus screenshots. Debug build.

## M0-05 Full Access matrix (device)
| Capability | Full Access OFF | Full Access ON |
|---|---|---|
| `hasFullAccess` | false | true |
| App Group `UserDefaults`: **extension reads value written by app** | **works** (read `app-…`) | works |
| App Group `UserDefaults`: **extension writes, app reads** | **did not land** (app still showed the earlier ON-run value) | works |
| App Group container: `containerURL` | non-nil | non-nil |
| App Group container: file **write** from extension | **FAILS** | works |
| Network (`URLSession` to https://example.com) | **fails** (NSURLError -1003) | NOT TESTED |
| Pasteboard `hasStrings` | false even when clipboard has text | true |
| Pasteboard `string` | nil, no prompt | **system paste prompt on first cross-app read** (see M0-09) |
| Haptics (`UIImpactFeedbackGenerator`) | **not felt** | felt |
| `playInputClick` | **works** (needs the view to adopt `UIInputViewAudioFeedback`, and the user's Settings > Sounds & Haptics > Keyboard Feedback > Sound on) | works |
| `UILexicon` | **works**, 3465 entries in ~55 ms | works, ~61 ms |
| Darwin notifications cross-process delivery | NOT TESTED (post call succeeded) | NOT TESTED |
The simulator does not enforce any of this (see `M0-05.md`), so device results win.

## M0-08 text proxy (device)
- Hosts tested: Notes (body), Messages (search field), WhatsApp (search field), Mail (search field). Safari, Instagram NOT TESTED.
- `adjustTextPosition(byCharacterOffset: -1)` moves by **one UTF-16 unit, not one grapheme**: from the end of `a👨‍👩‍👧` (9 UTF-16 units, 2 graphemes) one step left left 8 units before the cursor (read as 3 graphemes, i.e. the emoji was split) in Notes and Messages. In WhatsApp the context numbers also showed a one-unit move, but the owner observed that the cursor did **not** visibly move there; treat WhatsApp as unreliable.
- `documentContextBeforeInput` is capped at **500 characters** (after inserting 3000 characters, Notes and Messages reported 500). `documentContextAfterInput` was nil at end of text.
- Context before the cursor **crosses paragraph/line boundaries** in Notes (a selection on line 2 reported a before-context that included line 1).
- `selectedText` works in Notes (7 chars for a 7-char selection); before/after contexts then exclude the selection. In the other hosts it was nil with no selection.
- `keyboardType` = default (0) in Notes; `returnKeyType` = 6 (search) in Messages/WhatsApp/Mail search fields.
- Marked text: no public accessor found on `UITextDocumentProxy`. Devanagari/combining-mark adjust behaviour NOT TESTED separately.

## M0-09 misc (device)
- First cross-app read of `UIPasteboard.string` with Full Access ON shows the system "Allow Paste" prompt; the read blocked for ~3.4 s, the owner saw the prompt disappear and the keyboard switch to the system keyboard. After allowing, reads take ~23 ms. `detectPatterns` fails (code 4) without Full Access and works with it.
- `UILexicon` returns entries on the device without Full Access (unlike the simulator).
- Reading `pasteboard.string` twice in a row can return non-nil then nil around the prompt; never force-unwrap (crashed the probe).
- Callbacks of `detectPatterns` / `requestSupplementaryLexicon` arrive off the main thread; under Swift 6 a main-actor-isolated closure there traps (crashed the probe). Mark such closures `@Sendable` and hop to main explicitly.
- Haptic latency: NOT MEASURED (only felt/not felt).

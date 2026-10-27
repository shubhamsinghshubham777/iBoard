# keys5: merged comma/emoji key + even hint placement

## 1. Comma + emoji are one key

- New `KeyIdentity.commaEmoji` (Packages/IBoardLayout Types.swift). It replaces the `.emoji` key in the left bottom group
  (next to 123 / globe) when: letters layer AND `emojiKey` AND `punctuationKeys` AND not the URL / email keyboard
  (`LayoutEngine.mergesCommaWithEmoji`). The separate comma key is gone there, so the space bar grows by one tail key
  plus a gap (about 40 pt on a 390 pt screen; asserted in `commaAndEmojiAreOneKeyAndTheSpaceBarGrows`). Same rule in the
  Duo split bottom row (flex space takes the width) and landscape / fill-to-fold (same builder).
- Behaviour (KeyboardInputMachine): tap types "," on touch-up; holding for the existing `longPressDelay` setting opens the
  emoji panel (`.openEmoji`), highlight is released and nothing is typed on lift. Other emoji routes are unchanged
  (strip, slide from 123, numbers-layer emoji key, VoiceOver).
- Unchanged elsewhere: emojiKey off -> plain comma tail key as before; punctuationKeys off -> plain emoji icon key;
  numbers/symbols layers keep the emoji icon key; URL/email keep it too (no comma key exists there).
- Mapping decision for clipboard / quick settings: the old long-press menu on the emoji key (clipboard, gear = quick
  settings) now exists only on the plain emoji icon key (123 layer, URL/email, punctuation off). On the letters layer it is
  reachable via the clipboard chip in the suggestion strip (tap / long press) and, for VoiceOver, custom actions. The
  quick-settings panel has no other route on the letters layer: OWNER DECISION NEEDED if you want a dedicated button.
  Lost: the comma's own long-press alternates (! ? ; : - ( ) ...).
- Accessibility: label "comma", hint "Touch and hold, or use the Emoji action, to open the emoji keyboard", custom
  actions "Emoji" (+ Clipboard history / Quick settings), Voice Control names "comma", "emoji", "emoji keyboard".
- Text: SettingsView.swift footnote under "Comma and period keys" and the long-press delay footnote (wording only).

## 2. Hint characters

- `HintPlacement` (KeyGridView.swift): hint ink is centred in a fixed 8x8 pt box, 3 pt from the key's right edge and 2 pt
  from its top, using CoreText glyph bounds (so `'`, `"`, `-`, `$`, `(` all share one centre). Monospaced 9 pt font, one
  opacity (0.4), semibold under Bold Text (cache is flushed when the setting flips).
- Root cause of the old unevenness: the glyph bitmap was sized to the letter width, so the right-aligned hint moved with
  the letter (W vs I), and it was drawn at the font's top, so shapes differed. The bitmap is now exactly the key width.
- Still one cached CGImage per (letter, hint, case, width); no per-draw allocation. Dynamic Type does not apply to
  keyboard keys (fixed 9 pt, like the system keyboard).
- Reference renders: docs/reference/hints/hints-{before,after}-{light,dark}.png (390 pt, 3x).

## Verified

- `swift test` IBoardLayout: 48 tests pass (new unit test + 2 snapshot variants, `variants-w390.json` regenerated; all
  other snapshots unchanged).
- IBoardUI via `xcodebuild test -scheme IBoardUI` on iPhone 12 sim: 284 tests pass, incl. new `HintPlacementTests`
  (same inset for all 26 letters at 4 key widths, no ink overlap lower/upper case at 29/32/35 pt keys, grid PNG render),
  3 machine tests (tap, long press, custom delay) and an accessibility test.
- scripts/build.sh succeeded; `SIM_NAME='iPhone 12' scripts/test.sh --no-ui` exit 0 (all packages + app tests); scripts/audit-privacy.sh OK.

## Only unit / snapshot verified (needs device)

1. Letters layer, emoji key setting on: bottom row reads `123 , [wide space] . return`; no emoji icon.
2. Tap `,` types a comma; hold (default delay) opens the emoji panel with no comma typed; change Settings > long-press
   delay to Long and the hold takes proportionally longer.
3. Emoji panel still opens from the other routes; on the 123 layer the emoji icon key opens emoji on tap and offers
   gear / clipboard on hold.
4. When the system asks for a globe key: 123, globe, comma/emoji split their width evenly.
5. URL and email fields: icon emoji key, no comma; landscape and Duo inner split show the merged key.
6. Hints: every hint sits in the same spot top-right of its key (W, M, I, J, quotes, `-`, `;`, `:`), not touching the
   letter, in light and dark, with Bold Text on and off, and shift on (uppercase).
7. VoiceOver on the comma key: "comma", hint, Actions rotor shows Emoji / Clipboard history / Quick settings.

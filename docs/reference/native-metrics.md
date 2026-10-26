# Native keyboard metrics (M1-01)

Source: the system keyboard on an **iOS 27.0 simulator, iPhone 12 (390x844 pt @3x)**, captured 2026-10-26 in Safari
(page served from `http://127.0.0.1`), English (US) with the Hindi/Hinglish option on (space bar reads "EN HI").
Machine-readable copy: `native-metrics.json` (same numbers, with per-layout tile frames). Screenshots:
`screenshots/iphone12-{light,dark}-*.png` (keyboard crop, 50% scale, 585 px wide, so multiply by 2 for pt x 1.5).
Units are pt. "measured" = read from pixels (3x capture, 1 px = 0.33 pt) or the accessibility tree; "estimated" =
inferred and to be verified on device.

## Coverage

| Item | Status |
|---|---|
| iPhone 12 portrait: letters (shift auto / lower / shift), 123, #+=, light and dark | captured, measured |
| Traits: email, URL, numeric, decimal, phone, search, go, send, next, done, no-autocap, light and dark | captured (search-key variant: dark only) |
| Caps lock (double-tap shift) | NOT CAPTURED: axe synthetic double taps did not trigger it |
| iPhone 12 landscape | NOT TESTED: no Simulator.app here, rotation cannot be scripted |
| iPhone 12 mini, 12 Pro Max, Duo | NOT TESTED |
| Real device | NOT TESTED (simulator renderer may differ) |

## Geometry (iPhone 12 portrait, measured)

Keyboard frame: x 0, **y 516, 390 x 328** (bottom of screen). Everything below is relative to the keyboard top.

| Region | y | h |
|---|---|---|
| Prediction bar (always present, empty for email/URL/search) | 0 | 44 |
| Row 1 / 2 / 3 / 4 tile tops | 52 / 106 / 160 / 214 | tile 43, pitch 54 |
| Accessory row (emoji left, dictation right, no tiles) | 257 | 71 |

- Vertical gap between rows 11 pt, horizontal gap 6 pt (letters), edge margin 6.67.
- Letter tile 32.33 x 43, pitch 38.33. Row 1 starts at x 6.67, row 2 at 25.67 (10 / 9 keys), row 3 letters start at 64.0.
- Shift tile x 6.67 w 43.67, delete tile x 339.67 w 44 (13.67 gap to the neighbouring letter).
- Bottom row: 123/ABC x 6.67 w 89.67, space x 102.33 w 185.33, return x 293.67 w 90 (6 gaps).
- Numbers/symbols: rows 1-2 reuse the letter tile grid (10 tiles); row 3 has the toggle (#+= or 123, w 43.67) and five
  punctuation tiles 47.67 wide at pitch 53.67 from x 64.0, then delete.
- Numeric pad: tiles 122.33 x 48, pitch 128.33 x 54, rows at y 50/104/158/212, first x 4.67. Decimal/phone pads leave
  the bottom-left (`.` or `+*#`) and delete untiled/tiled differently; globe replaces emoji.
- Hit rects (accessibility tree) are 38.33 x 54 abutting, one point above each tile top: use them for hit testing,
  not for drawing (edge keys extend to the screen edge).
- Corner radius (circle fit, true shape is continuous): key tile **8.5**, blue return tile 9.1, numeric pad tile 10.6,
  keyboard container top corners about **25**, bottom corners about **43** (follow the display corner).
- Shadows: not measured; no visible drop shadow at 3x.

## Colours (measured over a white host page)

| | Light | Dark |
|---|---|---|
| Backdrop (glass over white host) | #E2E3E8 | #373737 |
| Every key tile (letters, shift, delete, 123, space, return) | #FFFFFF | #575757 |
| Letter / glyph | #000000 | #FFFFFF |
| Prediction text | #4A4A4C | #ACACAC |
| Prediction dividers | #D3D4D9 | #404042 |
| Action return (go / send / done) | #007AFF, white glyph | #007AFF, white glyph |
| Return for "next" and default | tile colour | tile colour |
| Shift active | tile colour, filled arrow glyph | same |

The backdrop is translucent system glass, so these depend on the host content (see `docs/spikes/M0-04.md`). Function
keys have no distinct fill in iOS 27.0 on the simulator.

## Typography (estimated from glyph metrics, SF Pro)

- Lowercase letters about **25 pt** (x-height 13 pt measured), uppercase about **22 pt** (cap height 15.33 pt).
- Prediction text about 17 pt (first glyph height 12 pt). "123"/"ABC" about 16 pt (rough). "EN HI" label about 9 pt.
- Letter glyphs: Q-tile top-to-glyph offsets are in the JSON (`fonts.glyph_measurements`).

## Observations for iBoard

- The prediction bar is a fixed 44 pt strip with a leading chevron button, three equal cells and a trailing "A"
  script-switch button (Hinglish). Mirror this layout for Native theme and the Hinglish toggle.
- Text fields open on the shifted layer; `autocapitalize=none` opens lowercase.
- Return key shows a glyph (arrow, up arrow for send, check for done, chevron for next), never text, for these hints.
- On this simulator there is no globe on the letters layer (single keyboard enabled), emoji left and mic right.
- Number pad and decimal pad have no prediction bar tile row; the keyboard keeps the 328 total height.
- Not measured: key press popover (callout), long-press accent panel, space-bar long-press trackpad, key sounds,
  animation timings.

## Reproducing

Scripts in `scripts/` (stdlib Python 3 plus ImageMagick `magick`): `measure.py` (flood-fill tile bounds and radius
fit from the 1170x2532 captures and `axe describe-ui` JSON), `extras.py` (colours, glyph sizes, container corners),
`build.py` (assembles `native-metrics.json`). Paths inside are hard-coded to the capture session scratch folder.

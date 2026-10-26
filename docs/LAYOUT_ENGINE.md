# Layout engine (M1-02)

`Packages/IBoardLayout`: a pure, `Sendable`, Swift 6, UIKit-free function (builds and tests on macOS with `swift test`).

```swift
LayoutEngine.layout(containerSize:, safeArea:, traits: LayoutTraits, kind: LayoutKind, settings: LayoutSettings)
    -> KeyboardLayout          // keys (identity, frame, touchRegion, row), stripFrame, keyArea, metrics, hitModel
LayoutEngine.preferredHeight(width:, safeArea:, traits:, kind:, settings:) -> CGFloat   // what the host should size to
```

No device model is ever consulted: the host passes the raw view size, safe area, and traits it derives from the screen
(`DisplayClass` phone / duoOuter / duoInner, orientation, `UIKeyboardType`, `UIReturnKeyType`,
`needsInputModeSwitchKey`). The layout **fills the container it is given**; `settings.heightScale` (F11) only changes
`preferredHeight`, which the host uses to choose the view height.

## Coordinates

Origin top-left of the keyboard view. The 44 pt (portrait) suggestion strip is part of the view (`stripFrame`); key
rows follow. Key frames are exact (not pixel-snapped; snapping is the renderer's job). Keys are not touched by shift
state: shift / caps lock do not change geometry, and letter identities are lowercase.

## Layout kinds and key identities

`LayoutKind`: `letters`, `numbers` (123), `symbols` (#+=), `numberPad`, `decimalPad`, `phonePad`.
`KeyIdentity`: `letter`, `symbol` (digits, punctuation, currency, `,` `.` `@` `/` `+*#`), `domainSuffix(".com")`,
`shift`, `delete`, `layerSwitch(target)`, `space`, `returnKey(ReturnKeyKind)`, `globe`.

- Letters: 10 / 9 / (shift + 7 + delete) / bottom row. Bottom row = 123, space, return; the globe appears only when
  `needsInputModeSwitchKey` (P-09) and shares the width of the 123 key, so space is unchanged.
- Email: bottom row `123 | space | @ | . | return`. URL: `123 | . | / | .com | return` (no space bar, as measured).
- Number row (`settings.numberRow`, letters only) adds a row of 1-0 above; `LayoutSettings.defaults(for:)` turns it on
  for Duo inner portrait. `punctuationKeys` adds `,` and `.` around space (not on email/URL).
- Number/decimal/phone pads: 3x3 digits, bottom row `[. or +*#] 0 delete`. Pads never contain a globe (the system draws
  it). Phone pads cannot appear in keyboard extensions (P-04); kept for completeness.

## Hit model

Touch regions tile the key area (`bounds` below the strip) exactly: gaps between keys are split at their midpoint
(nearest key), edge keys extend to the container edges, the first row reaches the strip, the last row reaches the
bottom edge, and blank cells (number pad bottom-left) go to the neighbour. `layout.hit(at:)` is strict (nil outside the
key area, e.g. in the strip), `nearestHit(to:)` clamps. Both return `KeyHit.normalized`: the point's offset from the key
centre in units of the key's own width/height (about -0.5...0.5 over the cap) for the adaptive touch model (F14), so
learning survives resizing. Lookups do not allocate.

## Design tokens (`LayoutMetrics`) and scaling rules

Reference values (iPhone 12 portrait, measured, `docs/reference/native-metrics.json`): strip 44, first row top 52,
key height 43, row gap 11, bottom inset 3 (view height 260, same as the spike), column gap 6, edge margin 6.67, letter
width 32.33, radius 8.5; pad tiles 48 high, row gap 6, margin 5.33, radius 10.6.

| Token | Rule |
|---|---|
| Vertical | strip fixed (44 portrait / 32 landscape); all other vertical tokens x `(height - strip - safe.bottom) / referenceBody`, so 390x260 gives exactly the measured values and other heights scale linearly |
| Column gap | 6 x clamp(width/390, 1, 1.25) |
| Edge margin | 6.67 x clamp(width/390, 0.96, 1.15) (width = container minus safe L/R) |
| Letter width | (content - 9 gaps) / 10 |
| shift/delete/toggle | 1.353 x letter width; 123/return 2.78 x; `@ . ,` 1.3 x (fit to the 390 measurements within 0.3 pt) |
| Third row letters | 7 keys centred; row 2 inset half a pitch |
| Preferred height | `strip + body x growth x displayFactor x heightScale`; growth (phones) = 1 + 0.25 x (clamp(w,390,440)/390 - 1) |
| Corner radius | 8.5 (10.6 pads) x clamp(vertical scale, 0.85, 1.25) |

## Duo seam (D-20)

`LayoutSettings.centreGap: CentreGap?` exists but is **ignored**; a test asserts the layout is identical with and
without it. Implementing the split means placing each row's keys into two column segments around the gap inside
`Placer` (LayoutEngine.swift) and letting `HitModel.build` treat the gap as a cell boundary.

## Tests

`swift test` in `Packages/IBoardLayout`: invariants (no overlap, inside bounds, regions tile, dense point sweep),
trait/key-set tests, preferred-height rules, native comparison (390 pt frames within 1 pt of the JSON for letters, 123,
#+=, email, URL, number/decimal/phone pads, return variants), and JSON snapshots per size and layer in
`Tests/IBoardLayoutTests/Snapshots/`. Regenerate snapshots after an intentional change with
`IBOARD_UPDATE_SNAPSHOTS=1 swift test`, then review the diff.

## Estimated values (NOT measured by M1-01)

- **Landscape (all)**: strip 32, row top gap 6, key 36, row gap 7, bottom 3; pads: key 34, gap 8, bottom 4. F13
  refinements (side columns, etc.) come in M8-04.
- **Caps lock**: not captured; geometry assumed identical to shift (only the glyph differs).
- **12 mini (375), Pro Max (428/440), Duo outer/inner**: derived from the scaling rules above, not captured. Width
  growth of the preferred height and the Duo outer height factor 0.9 are guesses.
- **Duo inner**: letter width cap 56 pt, pad block cap 520 pt, number row on in portrait; centre gap not implemented.
- **Globe layout**: measured captures had no globe; the 123 key's width is split into two halves.
- **Safe-area values used in snapshots** (landscape L/R 44-47, bottom 21) are typical, not measured.
- Gap / margin growth with width, `@ .` widths on email (1.3 x), shadows, fonts: see the JSON for status.
- Pad `Delete` in the JSON is an untiled hit region; we model it as a normal key at the bottom-right cell.
- Native hit rects start 1 pt above the tile; we split gaps evenly instead.

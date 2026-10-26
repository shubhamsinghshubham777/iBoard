# Themes (F10, M8-01, M8-05 logic)

Package: `Packages/IBoardTheme` (no UIKit, testable on macOS). Existing `ThemeColor`, `ThemeAppearance`,
`NativeThemeTokens` are unchanged; `ThemeColor` gained `Hashable`, `Codable`, hex-string, luminance and contrast helpers.

## Model v1 (`Theme`, `schemaVersion = 1`)

`Theme { schemaVersion, id, name, light: ThemeVariant, dark: ThemeVariant }`. A `ThemeVariant` holds:

| Field | Notes |
|---|---|
| `backdrop` | `kind`: `systemMaterial` (draws nothing, P-22) / `photo` (`photoAsset` name, `blurRadius` 0-40) / `gradient` (2-8 stops, angle) / `solid` |
| `dim` | 0-0.8 black overlay (photo/gradient) |
| `translucency` | 0-1 |
| `keys` | fill, pressedFill, opacity, cornerRadius 0-30, border width/colour, shadow colour/radius/offsetY, action fill/pressed |
| `fonts` | family (nil = SF Pro), weight (regular/medium/semibold/bold), four sizes (8-48 pt) |
| `labels` | key, actionKey, strip, stripSecondary colours |
| `swipeTrail` | colour, width 1-16, fadeDuration 0.05-2 s |
| `strip` | kind (plain/chips/filled), background, separator |

Colours serialise as `"#RRGGBB"` or `"#RRGGBBAA"`. One backdrop blur for the whole keyboard; never per-key effects.
Photos are pre-sized in the app (M8-02) and stored as App Group assets; a theme only references them by a safe file-name token.

## Presets (`ThemePresets`)

- **Native** (default): built from `NativeThemeTokens` via `ThemeVariant(native:)`; a test asserts round-trip equality. System backdrop.
- **Native Glass**: system backdrop too (P-22). Only key fill alpha (0.55 light / 0.4 dark) and a hairline edge vary.
- **Midnight**, **Paper**: solid backdrops, own key palettes.
- **High Contrast**: black/white, 1 pt borders, bold; label/fill pairs tested at >= 7:1.

`ThemeVariant.nativeTokens` maps a variant back to `NativeThemeTokens` so IBoardUI can migrate incrementally.

## Accessibility resolution (pure, M8-05)

`theme.resolved(ThemeAccessibilitySettings, appearance:) -> ThemeVariant`:
- Reduce Transparency: opaque solid backdrop (solid colour, first gradient stop, or native grey `#D1D3D9` / `#2B2B2D`), dim 0, key alpha 1.
- Increase Contrast: labels snapped to black/white when below 7:1, border >= 1 pt, opaque separator.
- Bold Text: font weight one step heavier, capped at bold.

The caller reads the UIKit flags (`UIAccessibility.isReduceTransparencyEnabled`, `.isDarkerSystemColorsEnabled`, `.isBoldTextEnabled`) and passes them in.

## Files (`.iboardtheme`)

JSON, `ThemeFile.export/import`. Cap 64 KiB. Import checks size, `schemaVersion` (newer than supported -> `unsupportedVersion`),
decodes, then validates every range, colour component finiteness, gradient stop count, asset-name safety (no separators), string lengths.
Errors: `tooLarge`, `malformed`, `unsupportedVersion`, `invalid(path)`. Export of a valid theme is deterministic (sorted keys).

## Not done here

Rendering (IBoardUI still consumes `NativeThemeTokens`), theme studio (M8-02), photo pipeline, persistence of the selected theme.

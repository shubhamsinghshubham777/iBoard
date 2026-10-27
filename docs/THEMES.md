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

## Theme studio and photo pipeline (M8-02)

App side: `iBoard/ThemeStudioView.swift` (preset picker, My themes, light/dark editing of key fill/opacity/radius/border/shadow,
label colours, weight, backdrop (system/solid/gradient/photo), swipe trail; `fileExporter`/`fileImporter` for `.iboardtheme`)
and `ThemePreviewView.swift` (preview drawn from the `Theme` model only; the system-glass backdrop is a stand-in, P-22).
Editing a preset forks it into a user theme with a fresh UUID; presets are never overwritten. Imported files get a fresh id and
lose photo backdrops (photos are never embedded).

`PhotoPipeline.process(data, target:)` (IBoardTheme, CoreGraphics/ImageIO, macOS-testable): ImageIO thumbnail decode (EXIF applied,
full bitmap never built), aspect-fill centre crop to exactly `PhotoTarget` pixels, opaque sRGB JPEG q0.8. Source cap 100 MP.
The app renders portrait and landscape targets from the keyboard point size x display scale; base heights (portrait 291 pt,
landscape 200 pt) are ASSUMED constants scaled by the user's height setting, to be checked against the real keyboard heights.

Storage (`ThemeStore`, App Group `group.app.iBoard`): selected theme JSON in defaults key `iboard.theme.selected` (keyboard reads it
without Full Access, P-23; invalid or missing falls back to Native), user themes in `iboard.theme.user`, photos as files
`ThemePhotos/<token>-p.jpg` and `<token>-l.jpg`; the theme's `photoAsset` is the token. Keyboard-side file reads without Full Access
are NOT TESTED. Colours quantise to 8 bits on save.

## Not done here

Rendering in the keyboard (IBoardUI still consumes `NativeThemeTokens`), keyboard-side reading of `ThemeStore`, an exported UTType
declaration for `.iboardtheme` (the app uses a dynamic type conforming to JSON), on-screen testing of the studio.

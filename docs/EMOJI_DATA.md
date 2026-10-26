# Emoji data and panel (M9-01, M9-02)

Package: `Packages/IBoardEmoji` (pure data/search logic, plus a UIKit panel behind `#if canImport(UIKit)`).

## 1. Data sources and licence

| Input | Origin | Version used |
|---|---|---|
| `emoji-test.txt` | https://unicode.org/Public/emoji/latest/emoji-test.txt | Emoji 18.0, dated 2026-04-30 |
| `annotations` (en, hi) | `cldr-json` `cldr-annotations-full` | CLDR 49.0.0 |
| `annotationsDerived` (en, hi) | `cldr-json` `cldr-annotations-derived-full` | CLDR 49.0.0 |
| Hinglish overlay | project-authored, `Packages/IBoardEmoji/Tools/hinglish_overlay.json` | Apache-2.0 (ours) |

Licence: the data is under the **Unicode License v3** (SPDX `Unicode-3.0`; the `cldr-json` package.json declares it and
the repo LICENSE file is titled "UNICODE LICENSE V3"). The full text is kept at `Packages/IBoardEmoji/LICENSE-UNICODE.txt`
and a line was appended to `NOTICE`. The permission notice must stay with copies of the data; do not use Unicode's name
to promote iBoard. No share-alike. (`emoji-test.txt` itself points at unicode.org/terms_of_use.html, which is the same
Unicode terms.)

SHA-256 of the inputs used (for reproducibility):

```
8f3735cd...b57ab21a  emoji-test.txt
6b6b6e0e...5d360     cldr-annotations-full/en
e37cf546...54f27     cldr-annotations-full/hi
7aad034f...dea3      cldr-annotations-derived-full/en
afcb1c5a...ecb4      cldr-annotations-derived-full/hi
```

## 2. Generated resource

`Sources/IBoardEmoji/Resources/emoji.json` (about 0.43 MB, budget 1.5 MB), committed. Regenerate deterministically:

```sh
# download the five inputs into DIR as emoji-test.txt, a/{en,hi}/annotations.json, d/{en,hi}/annotations.json
python3 -I Packages/IBoardEmoji/Tools/generate_emoji_data.py --src DIR
```

Generating twice gives byte-identical output (verified by md5). Contents: 1923 base emoji (fully-qualified, Component group
dropped, skin-tone variants folded into their base), 9 groups, 332 emoji with the five uniform skin-tone variants. Multi-person
mixed-tone sequences are intentionally not included (the picker offers uniform tones only). Row format:
`[emoji, group, name, "en|keywords", "hi|keywords", "tone1|..|tone5", "hinglish words"]`.

Caveat: Emoji 18.0 contains emoji newer than what an installed iOS may render. The generator takes everything; if a
newer emoji shows as a missing glyph on a given iOS, add a version filter (not done, NOT TESTED on device).

## 3. Panel design (M9-01)

- `EmojiCatalog` / `EmojiEntry`: immutable data. `EmojiStore`: lazy owner; `catalog()` loads on first use, `dropCaches()`
  releases it.
- `RecentEmoji` (cap 32, most-recent-first, dedupe), `SkinToneMemory` (global default plus per-emoji override, max 200
  overrides), `EmojiPreferences` (Codable, tolerant decode, `pick(_:)` resolves tone and records the recent).
- `Kaomoji.categories`: 8 project-authored categories.
- `EmojiPanelView` (UIKit): bottom category bar (ABC, recents, 9 groups, kaomoji), flow-layout grid with reused cells,
  long-press context menu for the five skin tones and "use this tone for all".
- Memory (F8, P-21): nothing is loaded until the panel is in a window; leaving the window or `didReceiveMemoryWarning()`
  clears items, drops the catalog and reloads the (now empty) grid. Cells are the system's reusable cells (about 30 on
  screen), never one view per emoji.

### Integration API (hooking up is a later task)

```swift
let store = EmojiStore()                                   // keep one per keyboard extension
let prefs = EmojiPreferences.decode(defaults.data(forKey: "iboard.emoji.prefs"))
let panel = EmojiPanelView(store: store, preferences: prefs)
panel.onInsert = { text in proxy.insertText(text) }        // emoji or kaomoji string
panel.onPreferencesChange = { defaults.set($0.encoded(), forKey: "iboard.emoji.prefs") }
panel.onClose = { /* show the letter keyboard again */ }
// in the keyboard view controller:
override func didReceiveMemoryWarning() { panel.didReceiveMemoryWarning() }
```

Privacy and Full Access (P-23): preferences hold only emoji the user tapped in the panel, never typed text. Persist them in
the extension's own (non-shared) `UserDefaults`, which works without Full Access; do not put them in the App Group. Offer
a "clear emoji history" action that calls `RecentEmoji.clear()` and `SkinToneMemory.clear()`.
Insertion uses `insertText` of whole strings, so P-24 UTF-16 splitting does not apply; deleting an inserted emoji must use
Character-based deletion (ENGINE.md).

## 4. Measurements

Measured on macOS (this machine), data layer only, `swift test --filter dataLayerMemory` run alone:
catalog load footprint delta **3.81 MB** (includes transient JSON parse allocations). NOT TESTED: the UIKit grid and
glyph rendering memory on iOS (the +10 MB panel budget is unverified for the UI part).

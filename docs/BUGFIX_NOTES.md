# Owner bug fixes from device testing (branch `fix/owner-bugs`, 2026-10-27)

Verified = seen working on one iPhone 12 / iOS 27.0 **simulator** (driven with `axe`, host: Safari textarea and the
Settings search field) plus unit tests. Nothing here was run on the physical iPhone. Simulator numbers are Debug builds
on a Mac, not iPhone 12 numbers.

| # | Bug | Status | Verified | NOT verified |
|---|---|---|---|---|
| 4 | Swipe typing types nothing | fixed (sim) | real words typed by swipe ("Wet", "ak"); first swipe right after the keyboard appeared inserted a word; `teh` → `the`; Hinglish ranking tests with real data | swipe accuracy on real fingers; swipe quality ("ak" outranked "ask" for a straight A→K line); device speed |
| 6 | Caps lock | fixed (sim) | double tap at sentence start → caps lock (typed `BIG`), blue-tinted shift tile with caps glyph; unit tests for held shift | held shift with two fingers on glass (axe is single-touch); haptic cue (not built) |
| 1 | 123 long-press opened emoji | fixed (sim) | emoji button in the strip opens the panel; slide from 123 onto "5" typed `5` and returned to letters | long-press 123 on device |
| 2 | Spacebar drag wrap down | fixed (sim, partly) | right drag crossed the line break onto line 2 in a textarea; unit tests for the "after-context ends at the line" case | the exact failing host from the owner's test (not named in the report) |
| 3 | Resize handle flicker | fixed (sim) | preview stayed put while the finger moved, one height change on release | feel on device |
| 5 | Swipe trail | fixed (sim) | screenshot of the thin gradient comet | Reduce Motion path, other themes |
| 7 | Emoji panel | fixed (sim) | one scroll through all categories, chips jump and follow the scroll, scroll offset survives a reinstall | skin-tone menu after the rewrite; search results mode; kaomoji chip; memory on device |
| 8 | Backspace swipe preview | partially fixed (see below) | live in-field preview in the Settings search field | any selection-style highlight (impossible), Notes / Messages / WhatsApp |

## 4. Gesture typing: English data bundled
- `project.yml` copies `Data/english/{lexicon.iblex,lm.iblm}` to `<bundle>/english/` like the Hinglish files; the 219-word
  fixture in `iBoardKeyboard/Resources` is deleted. `EngineHost` opens them mmap'd with checksums skipped, on the
  background load task (unchanged).
- **Footprint (Debug, simulator, `footprint <pid>`):** 25 MB after launch + a few swipes and taps; **31 MB** after also
  opening the emoji panel and scrolling it. The 30 MB target is therefore borderline in this measurement and must be
  re-measured on the iPhone 12 with the DEBUG overlay (`phys_footprint`); the hard cap (40 MB) and the device ceiling
  (~76-80 MB, P-21) are not at risk. If the device number is over 30 MB the first lever is releasing the emoji catalog sooner.
- First swipe before the decoder loads: `TypingCoordinator` keeps the last early swipe (6 s) and decodes it when the
  decoder arrives (`swipeBeforeDecoderExistsIsDecodedWhenItArrives`).
- Suggestions: the real data exposed two engine problems, both fixed with tests on the real data
  (`RealEnglishDataTests`, skipped when `Data/` is absent):
  1. Next-word prediction only looked at the 64 most frequent words per lexicon. `NGramModel.successors` now seeds
     candidates with the words that really follow the context (bigram/trigram records).
  2. After an English word with no Hinglish evidence the Hinglish unigrams ("ki", "aur") outranked English
     continuations. Secondary-language candidates in *prediction only* are now penalised up to
     `CodeSwitchParameters.predictionSecondaryHurdle` (6 nats) shrinking to 0 as Hinglish evidence grows. "the" →
     first / company / last; "pata nahi" → chal / hai / tha.
- Known: for a perfectly straight A→K swipe "ak" outranked "ask" (alternative is in the strip). Tuning belongs to M4-04.

## 6. Caps lock
- Double tap within 0.4 s locks caps, **also when the first tap only switched auto-capitalisation off** (the case at the
  start of a sentence; this was the real bug: the second tap used to turn shift back on).
- Holding the shift key capitalises letters typed with another finger (`KeyboardInputMachine.isShiftHeld`), also when
  the tap toggled auto-shift off; those letters do not count as a double tap.
- A manual one-shot shift is no longer undone by a late `textDidChange` auto-shift refresh.
- Indicator: the shift tile is grey for one-shot, blue-tinted for caps lock (plus the filled / capslock glyphs).
- Not done: a haptic/visual pulse when caps lock turns on; comma long-press; undo of the last autocorrect (extras).

## 1. 123 and emoji
- Long-press on 123 no longer does anything special. Emoji has a button (`face.smiling`) at the trailing end of the
  suggestion strip (it overlaps the third suggestion's right margin).
- Like the system keyboard, pressing 123 and sliding onto a key types it and returns to the letters
  (`KeyboardInputMachine.slideFrom`).

## 2. Spacebar cursor
Hosts give the keyboard only the rest of the *current line* as `documentContextAfterInput`, so a right drag at the end
of a line had nothing to step over while the left drag (context before spans lines) wrapped. When the visible text
runs out before the requested steps, `CursorMath.utf16Offset(…, crossingLineEnd: true)` adds one UTF-16 unit (the line
break; at the very end of a document the host clamps it to nothing, but one `adjustTextPosition` call and a feedback
click still happen per step there). Offsets stay UTF-16 (P-24).

## 3. Resize handle
The keyboard is not resized while dragging any more (that moved the handle under the finger). `ResizePreviewView`
shows a scrim with the percentage, a slider thumb and the target top edge (when shorter; an extension cannot draw above
its bounds, P-15); release applies ONE height change. Duo laptop-pose snap is shown as "Fill to fold" (not tested, no axe on Duo).

## 5. Swipe trail
`SwipeTrailLayer` is now 14 chained shape layers: faint hairline tail in a cooler hue to a bright head in the theme
trail colour, thinner (0.8 × theme width), quadratic smoothing, butt caps inside (round caps made dots), round head.
Reduce Motion: unchanged (vanishes at once on lift). Cost: up to 14 small paths per touch-move, not profiled.

## 7. Emoji panel
One `UICollectionView` with a section per category (headers), recents first when non-empty. Chips jump to a section
and follow the scroll position; kaomoji stays a separate list; search results are a flat list. The scroll offset is
saved (`iboard.emoji.scrollOffset`, a number in extension-local defaults) and restored on open. Recents are rebuilt at
open so the list never jumps under the finger. Pure rules in `EmojiSections` (tests).

## 8. Backspace swipe-delete preview: evaluation
Asked: show the words to delete as *selected* in the field. **Not possible**: a keyboard extension cannot set a
selection range (P-08, D-27) and no proxy API draws one. Tested alternatives (iOS 27.0 simulator):
- **Marked text** (`setMarkedText`, option `iBoard.deletePreviewStyle = marked`): re-inserting the words as marked text
  shows **no highlight at all** in the Safari textarea or the Settings search field, so it adds risk (a host that ignores
  marked text loses the words; `verify()`/`cancel()` re-insert them) for no visible benefit. Opt-in only.
- **Live deletion** (default, `live`): the words vanish from the field as you drag and reappear when you drag back to the
  keys or cancel; release keeps the result. Seen working. Trade-offs: the host sees intermediate edits (its undo stack and
  `textDidChange`), no "selected" colour. The suggestion strip also shows the words in an emphasised chip.
- **Strip only** (`strip`): the previous behaviour.
Answering the owner's follow-up ("can't we just highlight/select instead of deleting?"): not with the public keyboard APIs.
The remaining option is a different interaction (a cursor-based selection that the *host* draws, which needs a host
that supports it) and is not available. The owner should decide whether live deletion is acceptable or whether they prefer the strip-only preview.

## Owner checklist on the iPhone 12 (nothing installed on the phone by this work)
1. Swipe words on the real keyboard, check the DEBUG overlay footprint (target ≤ 30 MB, steady state) and suggestion quality (`teh`→`the`, next-word after "the", Hinglish "pata nahi").
2. Shift: double tap at the start of a sentence, hold-shift + one letter, caps lock tile colour.
3. 123: long-press does nothing; emoji button in the strip; slide from 123.
4. Spacebar drag right at the end of a line in the host where it failed before (name it, so it can be added to the notes).
5. Resize handle: stable preview, one change on release (also on the Duo).
6. Trail look and speed; emoji panel scroll position memory; backspace swipe in Notes/WhatsApp (live deletion, undo behaviour).

---
# Round 2 (owner device feedback, branch `fix/owner-bugs-2`, 2026-10-27)
Verified on an iPhone 12 / iOS 27.0 simulator (axe) unless stated; nothing re-tested on the physical phone.

- **Emoji panel went blank on fast scroll — root cause measured, fixed.** The keyboard process grew to **108 MB** (Debug sim)
  after scrolling the whole list: CoreText caches a colour-emoji glyph bitmap per emoji (~43 KB at 30 pt @3x) and never
  frees them, so the extension reached its memory ceiling and the system restarted it (blank panel). Emoji are now 26 pt
  rendered at 2x and the shrink-to-fit measurement is off for single emoji: **28-35 MB after 40 fast full-list scrolls**.
  `didReceiveMemoryWarning` no longer empties a visible list.
- **Resize drag handle removed.** Keyboard size is chosen in the app (Settings > Keyboard size): six presets
  (Extra small 80% ... Maximum 140%) per display class and orientation (`HeightPreset`); takes effect next time the keyboard
  appears. The old slider values map to the nearest preset. (Duo "fill to fold" snap and double-tap number-row on the handle
  went with it; the number row stays a setting.)
- **Emoji key next to 123** (real key in the layout, `LayoutSettings.emojiKey`; with the system globe key the three share
  the old 123 width). Replacing the system globe is NOT possible: iOS draws that key itself (P-09). The strip button is gone.
  Fixed a crash I introduced (exclusivity violation: opening emoji inside the machine's own callback) - now deferred a turn.
- **All screens resident:** the emoji panel is built hidden ~1.5 s after the keyboard loads and only shown/hidden afterwards
  (instant open). Letters/numbers/symbols were already instant (same grid, glyph cache). Honest limit: "always loaded, no memory
  issues" is a trade-off, not a guarantee; resident emoji costs memory (about +6 MB) and a memory warning still drops its
  catalog. Recheck the footprint on the iPhone 12.
- **Compact chrome** (`LayoutSettings.compact`, on in the keyboard): strip 44 -> 36 pt, strip-to-keys gap 8 -> 4, key gap
  6 -> 4.5, side margin 6.67 -> 4, keys 43 -> 46 pt high, rows 11 -> 8 apart. Letter keys ~5% wider, ~7% taller; total height
  260 -> 251 at Standard size (use Large for more). Native-metrics tests stay valid (compact is off in them).
- **Swipe trail, third version:** thick tapered ribbon (thin cool tail -> 12 pt bright head), soft halo, white-rimmed bead at the
  fingertip, seamless (no stepped joints). Reduce Motion unchanged.
- **Emoji panel UI:** equal-width columns (no ragged edge), pinned category headers on an opaque band, hairline above a
  roomier chip bar with soft-filled selection.
- Crashes found by simulator testing and fixed: Auto Layout exception from a constraint added before its view was in the
  hierarchy (emoji hairline), exclusivity violation above.

## Proposed UI/UX improvements (not built; pick any)
1. **Suggestion strip as a tinted pill row**: best word bold, others regular, hairline separators only between filled slots; fade
   in new words (60 ms) instead of swapping, and show the autocorrect target with a subtle underline.
2. **Key feedback**: tiny scale-down (0.96) plus brief colour flash on press; optional soft pop/key-pop on long-press alternates.
3. **Smart shift/caps**: caps lock shows an underline bar under the shift glyph and a one-time haptic tick; shift key pulses once at sentence start.
4. **Spacebar as a live cursor trackpad hint**: while dragging, dim the letters and show "<-  move cursor  ->" on the space key.
5. **Swipe-typing candidate preview**: show the predicted word live above the fingertip as the trail grows (like Gboard), so the
   user can lift as soon as it is right.
6. **Undo last autocorrect chip**: after a correction, the strip's left slot briefly shows "undo: teh" (one tap reverts and teaches).
7. **Quick punctuation**: long-press comma/period for a one-row strip of ! ? ; : - ( ) instead of the symbols layer.
8. **One-handed mode** (left/right squeeze) and a **floating/thumb mode** via the new size presets.
9. **Emoji**: skin-tone/recents "frequently used" row on top, a "search" field that focuses on first keypress, GIF/sticker later.
10. **Theme polish**: accent-coloured return key by context (send/search/go), subtle gradient on key tiles, per-app themes.
11. **Haptics**: distinct light/medium ticks for letters / delete / space; a rising tick pattern while deleting words.
12. **Onboarding in-keyboard**: first-run coach marks for the gestures (swipe, space drag, backspace swipe), dismissible and never shown again.

---
# Round 3: UX proposals built (branch `feat/ux-polish`, 2026-10-27)
Owner asked for all proposals except 5 (live swipe word preview) and 8 (one-handed mode). Simulator-verified (iPhone 12, iOS 27.0, axe) unless noted.

| # | Proposal | Status |
|---|---|---|
| 1 | Strip polish | Best word bold; new words fade in (60 ms, off under Reduce Motion); separators only between two filled slots. NOT done: underline on the autocorrect target. |
| 2 | Key press feedback | Pressed key shrinks to 0.96 on top of the colour change. Not measured against the 1-frame budget on device. |
| 3 | Caps lock cue | Underline bar under the shift glyph + blue tile (seen), heavy haptic tick on lock, one small pulse when shift turns on by itself. Haptics NOT TESTED (simulator has none). |
| 4 | Spacebar cursor hint | While dragging the space bar the letters dim to 30% and the space bar reads "‹ cursor ›" (seen). |
| 6 | Undo autocorrect chip | After a correction the first strip slot shows "↩︎ <typed word>"; one tap restores it (same path and learning signal as backspace). Seen: `teh`→`the`, tap → `teh`. |
| 7 | Quick punctuation | New setting "Comma and period keys" (default ON, `(agent)` choice; off = Native look). Hold comma or period for `! ? ; : - ( ) …` in the strip. Key layout seen; the long-press row itself NOT exercised. |
| 9 | Emoji | The "Recently used" section already leads the panel. NOT built: search focus on first keypress (the keys are hidden while the panel is open), GIF/stickers. |
| 10 | Theme polish | The accent return key by context already exists (Native). NOT built: per-key gradients (one extra layer per key would cost memory/time in the touch path; budget first) and per-app themes. |
| 11 | Haptics | Letters light, space soft, delete rigid, word delete rising 0.5→1, caps lock heavy, actions medium; scaled by the strength setting. NOT TESTED on device (needs Full Access). |
| 12 | In-keyboard coach marks | Four short tips in the strip with Next and Skip (also Done on the last); skipping or finishing is remembered (`iBoard.coach.step`, extension-local) and never shown again. The app's guided setup already has a Skip button (top right). Seen: tips advance, Skip ends them. |

Notes: tapping the strip's rightmost few points (x ≥ ~360 pt) in the simulator missed the Skip cell once; Skip worked at x = 345. Not investigated further. To replay the tips: delete `iBoard.coach.step` from the keyboard's defaults (reinstall).

---
# Round 4: owner device feedback (2026-10-27)
Fixed from the owner's iPhone 12 testing (builds installed on the device, checked by the owner in screenshots unless marked NOT TESTED).

- **Keyboard crashed on open in some hosts (most of ~20 crash logs).** `proxy.documentIdentifier` is nil in e.g. App Library search and the typed Swift property traps. Read via KVC + `as? UUID` (P-29). Another crash: backspace in an empty emoji search relaid the keyboard inside the input machine's callback (exclusivity); relayout is now deferred one turn.
- **Empty suggestion strip.** `resync()` returned early whenever the left context was nil (an empty field), so a stale word survived a cleared field and `requestPrediction` never ran. Now a nil context is re-checked after 250 ms and stale state is dropped (test `resyncDropsTheWordWhenTheHostEmptiesTheField`, fails without the fix). Also: engine load retries 3x, resync on appear. The exact trigger of the owner's last occurrence (a 👋 in the field) was NOT reproduced.
- **Emoji search rebuilt:** pill with caret and emoji icon, Cancel, scrolling results row (keyboard +44 pt while searching), exact/short names rank first, recents shown while empty, gesture typing and swipe-delete work in the field, search key dims until there is a query.
- **Emoji panel:** 32 pt emoji / 7 columns (memory: ~1.5x glyph cache per emoji vs 26 pt, recheck the footprint), new category bar (collection view, ABC and kaomoji fixed), inline headings, unrenderable Emoji 18 entries dropped (the "?" box, P-30).
- **Scroll dead zones (P-28, suspected):** scrolling only began on drawn content; near-zero-alpha background added to those surfaces. Owner confirmation pending. The first attempt (a mask on the scroll view itself) hid cells once scrolled.
- **Keys / strip / defaults (D-31):** translucent Native keys, trail colour from the theme, strip content and field centred under the system glass, taller dividers, icon return key, long-press delay setting, hint symbols + long-press hint, long-press emoji key opens iOS Settings (NOT TESTED).
- **Declined:** opening the iBoard app from the keyboard (locked D-01 / R-09); an app without UI constrained to Settings (see ROADMAP progress log).

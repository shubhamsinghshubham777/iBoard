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

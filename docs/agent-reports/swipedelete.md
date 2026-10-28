# Backspace swipe-delete redesign (M5-03) — design review and decision

Status: implemented; package tests green (`cd Packages/IBoardUI && swift test`, 280 tests). NOT built with xcodebuild and
NOT verified on a device, so M5-03 stays `[~]`.

## Why the old UI failed
Live mode deleted words in the host as you dragged (host undo stack and textDidChange churn, nothing shows what comes
next). Marked mode drew no highlight in tested hosts. The strip preview was one small slot.

## The owner's idea, reviewed honestly
"Hide all keys, use the whole keyboard as a live deletion canvas showing what will be deleted; do not touch the host field."

In its favour:
- Not mutating the host removes undo/textDidChange churn, makes cancel trivially safe, and behaves the same in every host.
- Entirely inside the keyboard bounds, so P-15 is respected.

Hard limits that shape it:
- P-24: only <=500 chars of left context, spanning paragraphs, lagging a run-loop turn; secure fields give none. A
  "whole document" canvas is impossible; only the tail near the cursor can be shown. The context is captured once at drag
  start and every plan is computed from it. In secure fields there is nothing to show: the canvas says so and release
  deletes nothing (unchanged from before).
- Mirroring host text cannot match host fonts, wrapping or line positions, so the canvas must not pretend to be the field:
  it is a clearly separate card in the keyboard's font, not a fake selection.
- The thumb dragging from the bottom-left delete key covers the lower-left and low-centre. Using the whole surface wastes
  space under the finger; the useful region is above the thumb.
- Fully hiding keys is unnecessary and jarring; dimming them (alpha 0.2) says "typing is suspended" and keeps the layout
  stable for drag-back-to-cancel.
- Accessibility: VoiceOver users do not do touch drags, so the canvas is a visual aid only (hidden from the VO tree);
  Reduce Motion: no fade-in. Text is never persisted or logged (in memory for the gesture only).
- Perf: one UIView with two labels, updated only when the plan changes (about every 38 pt). Negligible against the 27 MB
  steady budget.

## Alternatives considered
1. Live in-field deletion (previous default; Gboard/iOS word-swipe feel): no new UI, but destructive while dragging, noisy
   for the host, cancel needs re-insertion, no preview of the next word. Rejected.
2. Marked text / selection highlight: keyboards cannot set a selection (P-08/D-27); marked text showed no highlight in
   hosts. Rejected (measured).
3. Strip-only preview (SwiftKey style): safe and tiny, but one slot, about 30 chars, easy to miss. Fine as a fallback,
   insufficient alone.
4. Canvas card over the upper keyboard (the owner's idea, narrowed). CHOSEN.

## Decision
Canvas card over the upper ~60% of the keyboard, other keys dimmed, host untouched until release.
- Card: kept tail (muted, clipped to ~90 chars, "…" prefix) then the doomed words in red, struck through, with a caption
  "Delete N words" / "Drag further left to choose words" / "No preview in this field".
- Gesture semantics unchanged: drag left > 20 pt starts, 38 pt per extra word, dragging back to within 10 pt of the start
  (or far off the key row) cancels and the canvas disappears, release deletes via `coordinator.deleteRun`.
- New: a haptic tick each time the word count changes; "(more than shown)" when the plan eats the whole 500-char context.
  Setting-free (the `iBoard.deletePreviewStyle` default is gone).
- Emoji search field keeps its live query edit (our own field, not a host).
- Removed `MarkedDeletePreview` and its tests (the marked trick was disproven).

Files: `Packages/IBoardUI/Sources/IBoardUI/DeleteCanvas.swift` (pure model), `DeleteCanvasView.swift` (UIKit overlay),
`Tests/IBoardUITests/DeleteCanvasTests.swift`, `iBoardKeyboard/KeyboardViewController.swift` (`updateDeletePreview`,
`finishArbiter`, `resetArbiter`, overlay above the strip).

## Left for on-device checking
- The keyboard target was not compiled (UIKit parts of `DeleteCanvasView` and the controller edits are unbuilt).
- Looks: card in light/dark and every theme (it uses system colours, not the theme), height on iPhone 12, Duo split,
  landscape, with the height-resize handle.
- Fast drags: overlay is non-interactive and touches stay with the grid; confirm no jank.
- Haptic tick feel per word; Reduce Motion path.
- Real hosts: planned words match what the host deletes on release (multi-paragraph, emoji, Devanagari, Safari/WhatsApp).
- Secure fields: release is a no-op. Option needing an owner decision: word-count fallback with repeated word delete.

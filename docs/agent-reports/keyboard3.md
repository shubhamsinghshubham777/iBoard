# KEYBOARD3 report (2026-10-27)

## M8-04 Landscape layouts (F13) — [~]
- Phone landscape (available width >= 640 pt, letters layer) gets a punctuation column on each side (left `" ' ! ?`, right `- ; : /`,
  last N for N letter rows; none on the bottom row). The 10-key block narrows accordingly (keys stay >= 44 pt wide).
  Appended after all other keys, so key order (swipe decoder / touch model) is unchanged. `LayoutSettings.landscapeSideKeys`
  (default true, tolerant Codable); no app toggle yet. Numbers/symbols layers and pads unchanged.
- Tests: new invariants (`LandscapeSideColumnTests`), snapshots regenerated for 812 (mini), 844, new 932 (Pro Max) and 667 (SE)
  landscape. UIKit render (`LandscapeRenderTests`, run via `xcodebuild test -scheme IBoardUI` on the simulator; PNGs when
  `TEST_RUNNER_IBOARD_RENDER_DIR` is set) inspected at 812 and 844.
- Not done: optional split on phones, arrow/undo keys (need new `KeyIdentity` cases across UI), a Settings toggle, key
  proportions are ESTIMATED. Needs device: feel, thumb reach, and that the strip compaction looks right.

## Clipboard history entry point — [~]
- Long-pressing the emoji key now offers a clipboard glyph (before the Settings gear) when Full Access and clipboard history are
  on; selecting it opens the panel from any state (also with text in the field). Test in AlternatesTests. Needs device.

## Hint symbols — [~]
- Rendering bug found in the UIKit render: the faint hint overlapped the letter glyph (d, x, ...). Fixed by widening the label
  image so the hint sits beside the glyph. Verified in render at 812/844; not on device.

## Robustness review of KeyboardViewController
- Fixed: touches arriving before the first layout would crash on `machine!` (guard added).
- Memory warning now also drops the in-memory clipboard history (reloaded on demand) and clears the swipe trail.
- Checked: swipe capture raw points are bounded (512, decimated) and trail bounded; no `try!`/`as!`/`.first!`; engine load runs
  off-main with 3 retries; remaining `machine!` uses are only reachable after the guard.
- Not measured: memory/perf on iPhone 12 (DEVICE). Sound packs remain impossible in an extension (P-23).

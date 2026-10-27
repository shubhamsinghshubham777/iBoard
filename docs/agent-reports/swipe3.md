# SWIPE3: sloppy-profile accuracy + real-trace recorder (M4-04)

All numbers are SYNTHETIC traces (generator and decoder share one author and geometry). No device was available. Nothing here
shows F3 (90% top-1 / 97% top-3) on real fingers.

## Measured (top-1 / top-3 %, macOS host, fixed seeds)

Real English lexicon (top 5000 words, 400 per profile) and the Hinglish mixed-sentence set (English primary + Hinglish secondary):

| set | profile | before | after |
|---|---|---|---|
| English | careful | 97.2 / 100.0 | 97.8 / 100.0 |
| English | normal | 95.5 / 99.5 | 96.2 / 99.8 |
| English | sloppy | 92.0 / 97.8 | 92.8 / 97.5 |
| Hinglish | careful | 95.7 / 99.7 | 96.0 / 100.0 |
| Hinglish | normal | 94.4 / 98.9 | 95.2 / 99.5 |
| Hinglish | sloppy | 91.8 / 97.1 | 92.4 / 97.7 |

Fixtures, all profiles combined: small (219 words) 97.9 / 99.3 before and after; bench (12k words) 98.5 / 99.4 -> 98.6 / 99.4;
Duo-landscape small 97.3 / 98.9 unchanged. Real-English regression (old params vs defaults): 95.1 -> 95.9 top-1, top-3 99.0.

On this data sloppy top-1 already met 90% before; the earlier "sloppy just short" was the small-fixture sloppy top-3 and
the Hinglish numbers. English sloppy top-3 is 97.5, right at the 97% line, i.e. within noise of it.

## What changed
- `SwipeParameters` defaults: `lmWeight` 0.5 -> 0.4, `locationTolerance` 0.45 -> 0.35, `locationSigma` 0.35 -> 0.30. Gains are
  small (0.5 to 1.0 point) but consistent across profiles and both languages. They were tuned and measured on the same synthetic
  traces (no held-out real data), so some of it may be overfit to the generator.
- Swept and rejected (worse or noise): `corridorRadius` 0.9-1.5, `endRadius` 0.8-1.6 (smaller loses sloppy, larger loses everything),
  `shapeSigma`, `anchorWeight`, `cornerDegrees`, larger `locationTolerance`. Defaults were near a plateau; no structural decoder
  change was made. Remaining sloppy errors are mostly look-alike words (truth is in the returned list ~98% of the time), which only
  real data can disambiguate honestly.
- Tests: `Swipe/SwipeSloppySweepTests.swift` (per-profile report on real English + Hinglish with floors; opt-in sweep with
  `IBOARD_SWEEP=1`). Engine `swift test`: 253 tests pass. `scripts/build.sh` succeeds (after `xcodegen generate` so the new folder
  is in the project; build.sh only regenerates when project.yml is newer).

## Real-trace path
- Existing: `SwipeTrace` / `SwipeTraceFile` (.jsonl) and `SwipeTraceTests.realTracesReplay` over `Fixtures/traces/*.jsonl`.
- New: `iBoard/TraceRecorder/SwipeTraceRecorderView.swift`, a SwiftUI recorder. It shows a word from a fixed prompt list (English +
  Hinglish), draws the real `LayoutEngine` letter layout (260 pt tall, screen width), records the drag path (x, y, t) and saves
  `SwipeTrace`s to `Documents/swipe-traces/traces.jsonl` in the app sandbox. Only coordinates, timing and the prompted word are
  stored; no keyboard-extension involvement, no network; data leaves the device only through the Share button.
  Verified: compiles in the app target. NOT verified: rendering, gesture feel, a saved file (never run).
- One-line hookup (not done, outside my file ownership), inside a `#if DEBUG` section of `SettingsView`:
  `NavigationLink("Swipe trace recorder") { SwipeTraceRecorderView() }`. The privacy audit may need an allowlist entry if it flags
  Documents writes in the app target.

## Follow-ups
1. Wire the recorder, record ~200-300 swipes on the iPhone 12 (mixed careful and fast), AirDrop `traces.jsonl` into
   `Fixtures/traces/` (with a LICENSE.md) and read the `realTracesReplay` output. Only that decides F3 and real tuning.
2. The recorder container is 260 pt tall at screen width; replay scales via `swipePoints(scaledTo:)`. The real keyboard height
   differs by device and height setting; re-record if the layout changes substantially.
3. Re-tune on real traces with a train/held-out split; do not trust the synthetic gains until then.

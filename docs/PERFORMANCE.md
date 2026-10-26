# Performance harness

Budgets live in ROADMAP §6 (reference device: iPhone 12, release build). API: `Perf` in `Packages/IBoardCore`.

## Metrics

All signposts use subsystem `app.iBoard`, category `perf`.

| Signpost | Measures |
|---|---|
| `touchDownToHighlight` | touch-down event to key highlight committed |
| `touchUpToInsert` | touch-up to `insertText` returning to the host |
| `keystrokeToSuggestions` | keystroke to suggestion bar updated |
| `swipeLiftToCandidate` | finger lift to top swipe candidate ready |
| `coldStart` | extension process launch to first interactive frame |
| `warmShow` | keyboard re-shown (process alive) to interactive |
| `memoryFootprint` (event) | `phys_footprint` (KB), via `Perf.emitMemoryEvent()` |

Usage: `let t = Perf.begin(.touchUpToInsert); ...; Perf.end(t)` or `Perf.measure(.warmShow) { ... }`.
Only durations are stored (256-entry ring per metric); typed text is never recorded or logged.

## Capturing

1. Instruments: Blank template, add "os_signpost" (Points of Interest is not needed), filter subsystem `app.iBoard`.
   Attach to the keyboard extension process (`iBoardKeyboard`) on device; use a Release build for real numbers.
2. CLI: `log stream --predicate 'subsystem == "app.iBoard"'` (signposts) or `xcrun xctrace record --template 'Logging'`.
3. Memory: the overlay's `mem` is `task_vm_info.phys_footprint`, the figure jetsam enforces.

## Debug overlay (DEBUG builds only)

Long-press the hidden 44 pt top-right corner of the keyboard, or `defaults write` the app-group-less key
`iBoard.debugOverlay` (UserDefaults) to true. Shows memory (MB) and p50/p95 per recorded metric. Compiled out of Release.

## Engine benchmarks

`swift test --package-path Packages/IBoardEngine` runs micro-benchmarks (`Benchmark.expectP95`) with thresholds
derived from §6 times a loose slack factor (macOS debug host); tighten once the real engine exists.

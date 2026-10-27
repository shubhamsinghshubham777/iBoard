# DEVICE agent report (2026-10-27)

All numbers below are labelled DEVICE (iPhone 12, A2403, iOS 27.0) or NOT-DEVICE.

## What was done
- Release device build (`DERIVED_DATA=build/DeviceDD`, Team 6NKFZTB3JJ, `-DIBOARD_PERF`) built, signed and installed on the
  owner iPhone with `devicectl` (DEVICE: install OK; app launched).
- Added `iBoardKeyboard/PerfMetricsHook.swift` (counts/MB only, never text; compiled only under DEBUG or `-DIBOARD_PERF`,
  so a normal Release build is unchanged) plus two call sites in `KeyboardViewController` (`viewDidLoad`, `viewWillAppear`).
- Added `scripts/device-perf.sh` (build/install/pull/crashes/soak), `iBoardUITests/DevicePerfSoakTests.swift`, `docs/perf/README.md`.

## Measured
| Item | Value | Source |
|---|---|---|
| Keyboard binary (Release, arm64) | 4.7 MB; `__TEXT` 1.74 MB | NOT-DEVICE, static |
| Extension bundle resources | english 15 MB + hinglish 6.7 MB (mmap, not resident) + emoji 428 KB | NOT-DEVICE, static |
| Footprint idle / after typing / swipe / emoji / clipboard | NOT MEASURED | needs the keyboard on screen (below) |
| Launch / appear latency, touch latencies | NOT MEASURED | hook records them; needs the keyboard on screen |
| Crash logs (systemCrashLogs) | 26 iBoardKeyboard .ips; all 2026-10-26..27 up to 12:49; 24 are the `documentIdentifier` nil-UUID trap in `applyFieldConfig` (P-29), 2 SIGABRT at 12:04/12:05. None after the fix (code now bridges via KVC, `KeyboardViewController.swift:302`). | DEVICE |
| Jetsam | latest JetsamEvent (10-27 06:24) does not involve iBoardKeyboard | DEVICE |

## IBoardSync in the extension (static only, footprint delta NOT measured)
IBoardSync is not imported by iBoardKeyboard directly: it arrives through `IBoardEngine` (`Personal/PersonalSyncAdapter.swift`
imports it). The extension binary links **CloudKit.framework** and CryptoKit (otool -L) and carries 1132 IBoardSync symbols.
CloudKit is a system dylib shared in the dyld cache, so the cost is mostly dirty pages when first used, not file size; but it
is a real load-time and footprint risk for an extension that does not sync. Recommendation (owner/KEYBOARD3 decision, outside
my file scope): move `PersonalSyncAdapter` behind a separate target that only the app links, or weak-link CloudKit. A/B this
once footprint numbers exist (same build with the adapter stubbed).

## Why the soak is not automated
XCUITest runs on the device (verified: runner launches, app launched, tests execute). But after tapping the "Tap here"
field in the iBoard app the accessibility tree shows no keyboard (`app.keyboards.count == 0`, field `isHittable == false`)
so `key-grid` is never found and the test skips (`XCTSkip`). Not resolved; likely the software keyboard is suppressed on
this device (hardware-keyboard / "Show software keyboard" setting) or the list cell is occluded. Owner: check Settings >
General > Keyboard > Hardware Keyboard and re-run `scripts/device-perf.sh soak 1800` once a keyboard is visible
in the first field. The test also cycles the globe key to reach iBoard.

## Owner steps
See `docs/perf/README.md` (about 5 minutes), then run `scripts/device-perf.sh pull` and paste the printed summary
into ROADMAP M1-09 / M13-02. Pass criteria: `peakMB` < 30 target / < 40 hard, below ~76 ceiling (P-21); no growth in the
timeline over the soak; p95 per ROADMAP section 6.

## Verdict
M1-09 and M13-02 stay open: no footprint or latency number exists yet. Infrastructure to produce them with one command is in place.

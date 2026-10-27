# Device perf measurement (M1-09 / M13-02)

Hook: `iBoardKeyboard/PerfMetricsHook.swift`, compiled only with `DEBUG` or `-DIBOARD_PERF` (Release stays clean).
Every 0.5 s it samples `phys_footprint` and every 2 s writes counts and numbers only (never text) to
`Library/Caches/perf/perf-<processStart>.json` (one file per keyboard process, newest 12 kept) in the extension container: `peakMB`, `currentMB`, `appearCount`, `memoryWarnings`,
Perf p50/p95 per metric, and a footprint timeline `[unixSeconds, MB]`.

**Quickest:** `scripts/device-perf.sh run` (phone unlocked and plugged in): builds the Release + hook build, installs it, prints
the step list, waits for you to finish, pulls the numbers and prints PASS/FAIL against the ROADMAP §6 budgets.

Individual steps. Build and install (Release + hook): `scripts/device-perf.sh build` then `scripts/device-perf.sh install`.
Read: `scripts/device-perf.sh pull` (prints a summary; raw file in `build/device-perf/`).
Crash logs: `scripts/device-perf.sh crashes`.

Owner steps (about 5 min), because on-device XCUITest could not raise the keyboard (see agent report):
1. Install, open any text field, switch to iBoard. Note the clock time at each step so the timeline can be mapped:
   idle 20 s; type 100 chars; swipe 10 words; open emoji panel, scroll to the bottom, wait 10 s, close;
   open clipboard panel (Full Access on), wait 10 s, close; dismiss and re-show the keyboard 20 times.
2. For the 30-minute soak: type continuously (or run `scripts/device-perf.sh soak 1800` with the phone unlocked on the
   iBoard home screen and iBoard already the active keyboard in the first text field), then `pull`; `peakMB` must stay
   under 30 (target) / 40 (hard) and the timeline must not climb.

## Fully automated run (no human): `scripts/device-perf.sh auto [--soak SECONDS]`
Phone unlocked, awake (screen on, home or any app) and plugged in; Settings > Developer > Enable UI Automation on. One command builds
Release + `-DIBOARD_PERF` (with `ENABLE_TESTABILITY=YES` so `iBoardTests` still compiles), installs, runs
`iBoardUITests/DevicePerfAutoTests.testAuto` (drives Apple Notes and the real iBoard keyboard by screen coordinates: idle 20 s, ~110 typed
characters, 10 swipe-typed words through 3-5 points each, emoji panel via comma long-press + scroll + 10 s, 20 show/hide cycles, then
deletes the scratch note), pulls the per-process files, filters to processes alive since the run started (`PERF_SINCE`), prints the verdict and
lists only NEW crash files. It exits 1 with "RUN FAILED" when no timing data was recorded. Screenshots: `build/device-perf/attachments`.
`TEST_RUNNER_IBOARD_PHASES=idle,type,...` selects phases. Keyboard coordinates in the test are for iPhone 12 / 270 pt keyboard.
"Timed out while enabling automation mode" means the screen was asleep or locked: wake it, then retry. Evidence: `docs/perf/evidence/perfauto6/`.

# perfauto6: fully automated on-device perf run

## How to run
`scripts/device-perf.sh auto` (soak: `auto --soak 1800`). Phone unlocked, screen on, plugged in, UI Automation enabled. Details in `docs/perf/README.md`.
Why it works now: the earlier test tapped a field inside iBoard's own app. This one drives Apple Notes (`com.apple.mobilenotes`), where iBoard is
already the active keyboard. The keyboard's own elements are NOT in the host accessibility tree (`app.keyboards.count == 0`), so it taps screen
coordinates measured from a screenshot (letters rows y = 571 / 628 / 684.5 pt, space 741.5, comma 76; x pitch 38.6 pt). Multi-point swipes use
XCTest's private `XCPointerEventPath` / `XCSynthesizedEventRecord` through `XCUIDevice.eventSynthesizer`. Swiped words decode (Hello, World, People, Great, About, Together
correct; Tow/Stood/Thaana/Mooning are mis-decodes of tomorrow/should/thanks/morning with a sloppy 60 ms-per-point synthetic path).
Only harmless letters are typed into a scratch note; the test deletes it and any leftover "The quick..." notes (verified: after-delete.png shows the Notes list, 24 notes, no scratch note).

## What it proves / does not
Proves: real touches through the real extension process on an iPhone 12 Release build, timing p50/p95 from the keyboard's own Perf hook, footprint timeline, appear count.
Not: synthetic taps are perfectly timed (no finger drift), screenshot-based height checks cost about 1 s each so they cannot resolve sub-second lateness, memory limit behaviour under other
foreground apps, thermal state over 30 min (use `--soak`). Soak mode was not run in this round.

## Final run (21:30 IST, Release + IBOARD_PERF, keyboard process 21:30:47; evidence in docs/perf/evidence/perfauto6/)
| metric | n | p50 | p95 | budget | result |
|---|---|---|---|---|---|
| touchDownToHighlight | 132 | 0.3 ms | 0.5 ms | 16.7 | PASS |
| touchUpToInsert | 121 | 0.9 ms | 4.1 ms | 20 | PASS |
| keystrokeToSuggestions | 87 | 5.6 ms | 10.2 ms | 25 | PASS |
| swipeLiftToCandidate, coldStart, warmShow | not recorded | | | 60 / 250 / 80 | NOT MEASURED (10 swipes were driven but the metric is absent from the hook output; coldStart/warmShow also absent) |

Memory: FAIL. Peak 75.9 MB (target 30, hard cap 40), 9 memory warnings. Timeline of the busiest process: 8 MB at start, about 27 MB while typing and swiping (within target),
then 39 MB, 64 MB and 75.9 MB during the emoji phase (panel open, scroll, 10 s wait). The extension then died and iOS started a new process, which reached 53.8 MB after 6 more
appears (show/hide loop). An earlier run the same day showed the same pattern (emoji + reshow climbing to 62-76 MB). Unlike the first Debug drive (24.4 MB, before the latest main changes),
this is a regression or an emoji-panel cost, and it is the main finding. Appear count: 14 in the busiest process (+6 in the next); 20 show/hide cycles driven.
No new crash files (`crashes` before and after identical; the newest iBoardKeyboard-*.ips is 2026-10-27-161128, no JetsamEvent after 20:31).

## Show/hide height (20 cycles, 270 pt)
All 20 cycles showed the full-height layout (Q-key pixel check at the 270 pt layout position; screenshots reshow-1/10/20.png and 6-reshown.png show the full keyboard).
Time from tap to first positive check: 1076 to 1266 ms (median about 1120 ms). That number is dominated by the ~1 s screenshot polling cost, so it only shows "full height by about 1.1 s";
no short or late cycle was detected, but a lateness under 1 s cannot be seen this way.

## Changes
iBoardUITests/DevicePerfAutoTests.swift (new), scripts/device-perf.sh (`auto`, `PERF_SINCE` filter), docs/perf/README.md, project.pbxproj (xcodegen). No keyboard source edits (main's per-process hook used).
Gotchas: "Timed out while enabling automation mode" when the screen sleeps (twice during this session; waking the phone fixed it); Release test builds need `ENABLE_TESTABILITY=YES`.

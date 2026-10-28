# Touch hunt (M1-04): 'Typing' typed as 'Tyîng'

Status: fixes are covered by unit tests (swift test, IBoardUI) but NOT verified on device. The 'î' half of the symptom is NOT reproduced.

## Confirmed and fixed (failing test first)
1. Sloppy tap crosses a key boundary -> swipe typing. GestureArbiter decided `.swipeTyping` the moment the finger entered another letter key, with no distance threshold; the host then ran `machine.touchCancelled`, so the tapped letter was DROPPED. This is the likely cause of the missing 'p' (right-edge key; a few pt of drift is enough). Now needs >= tapMovement (10 pt) of travel; `end()` returns `.tap` otherwise.
2. KeyboardInputMachine.touchMoved retargeted to the neighbour key (nearestHit) after any movement, so a few pt of drift typed the neighbour's letter. Now needs >= 10 pt from the down point (`slideSwitchDistance`).
3. A repeated touch id in touchDown silently released the old slot, dropping an uncommitted tap. Now handled as a lift (the tap is typed).
4. KeyGridView derived ids from UITouch addresses (recycled by UIKit). Now a monotonic counter id per touch, removed on end/cancel. Hardening only: no stale-state path that needed it was found, so its effect is unproven.

## Round 2 (owner: also in Notes, 'Typîng fat': 's' dropped, 'i' -> 'î')
- (a) Real path checked: after alternatesBegan the host resets arbiter/swipeCapture, and the lift reaches `machine.touchUp` with `isAlternates`, so the late-tick undo is NOT bypassed there. Not proven that it is bypassed anywhere.
- Root cause of the visible symptom (confirmed in code, with tests): `AlternatesSelection` starts with the FIRST alternate highlighted, so any release over the origin key (spurious long press, finger never moved) inserted the first accent ('î'), and a release that slid off/back inserted nothing (dropped letter). Fix (c): `originText`; a release that never entered the strip inserts the key's own letter. Host passes the cased key text.
- (b) Stall guard in `KeyboardInputMachine.tick`: if the gap since the previous pulse exceeds 0.12 s (main thread was blocked, a queued lift may be unprocessed), due long presses are postponed 0.05 s instead of firing; a real hold still fires on the next pulse. This is independent of CACurrentMediaTime and of touch timestamps. Existing tests that ticked at artificial 0.2 s gaps were changed to realistic pulse spacing.
- The root reason the main thread blocks ~0.3 s (Debug build work per keystroke) is NOT found or measured; (b) and (c) make the keyboard safe against it rather than remove it.

## Disproved / not found
- Tick guard `CACurrentMediaTime() - link.timestamp > 0.06`: with a fresh link (timestamp 0) it skips the tick (conservative), so it cannot fire early. Per-keystroke main-thread cost (>300 ms in Debug) was not measured.
- Stale per-id state after finishArbiter / flick / swipe / cancel paths: every path calls machine.touchCancelled or touchUp; none leaves a slot active.

## Suspected, unproven
- 'î': needs i's long press to fire and the lift to be judged at/after the deadline. Not reproducible from machine logic alone; profile main-thread stalls on device.
- Rollover: only the first finger gets arbiter/swipeCapture. If finger A was committed by rollover and then flicks or swipes, A's letter and the flick/swipe text are both inserted. Second fingers get no flick handling.
- touchDown outside keyArea (hit == nil) is ignored; an edge tap could be dropped.
- touchCancelled drops an uncommitted tap.

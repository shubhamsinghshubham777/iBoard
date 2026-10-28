---
name: typing-tune
description: Iteratively tune iBoard's typing feel with the owner on their iPhone 12 — they type test phrases, you pull the DEBUG touch log, find why letters drop / change / mis-hit, fix with a test first, then rebuild and install. Use when the owner says they have time to type, or reports dropped/wrong letters, accents, mis-hits, or swipe/flick misfires.
---

# Typing tune session

Goal: make fast typing on the owner's iPhone 12 exact. Work in small loops; each loop = owner types, you read the log, fix, reinstall. Evidence over theory: past guesses (late display link, UITouch id reuse, slow long press) were wrong until the log showed the real cause (fingertip rolls down the key: down-flick typed accents; drift onto a neighbour typed it or became a failed swipe).

## Loop

1. **Ask for the sample**: owner types a test phrase fast in Notes ~10-15 times, then pastes the results (one per line). Tell them to retype right after a bad one; the ring buffer holds the last 4000 records (~14 attempts). Suggested phrases: `Typing fast`, plus ones with the problem keys they report, a sentence with apostrophes (`I'll don't it's`), numbers/punctuation, and a few swipe words.
2. **Pull + analyse**: `scripts/touchlog.sh` then `python3 -I scripts/touchlog-analyze.py`. It prints per touch: hold ms, drift pt, key index at down vs up, and flags drift > 8 pt, key change, hold > 150 ms, any alternates events. The log holds NO characters (privacy rule): map key indices to letters from the layout (`LayoutEngine.layout`) or the keyboard order if needed. Match bad outputs (missing letter / wrong letter / accent) to flagged touches and the machine's event stream.
3. **Classify** each failure: (a) alternates/flick fired (long press, up/down flick), (b) key changed between down and up (drift/roll), (c) swipe decided on a sloppy tap (dropped letter), (d) touch hit the wrong key at DOWN (hit-test offset: look at down coordinates vs key frames, owner taps tend to land high on keys), (e) text layer after a correct insert (autocorrect, auto-shift, double-space period, stale proxy, TypingCoordinator), (f) main-thread lag (max lag in the header; Release build vs Debug).
4. **Failing test first** in Packages/IBoardUI/Tests (KeyboardInputMachineTests, GestureArbiterTests, StaleContextTests; `TouchLogReplayTests` can replay a log). Then the minimal fix, then `cd Packages/IBoardUI && swift test`.
5. **Ship to the phone**: `scripts/test.sh --no-ui`, then `xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Debug -destination "id=00008101-0014596A1E01001E" -derivedDataPath build/DeviceDD -allowProvisioningUpdates build` and `xcrun devicectl device install app --device 00008101-0014596A1E01001E build/DeviceDD/Build/Products/Debug-iphoneos/iBoard.app`. One xcodebuild at a time. Commit with `[M1-04] ...`, update the ROADMAP progress log in the same commit, push to main (`git -c credential.helper= -c credential.helper='!gh auth git-credential' push`).
6. Report briefly: what the log showed, what changed, what to retype next. Keep status `[~]` until the owner confirms on device.

## Measured facts (iPhone 12, Debug)
- Fast taps last 33-100 ms, gap between keys 60-300 ms, lag normally < 35 ms (spikes ~130 ms).
- A tap's fingertip often drifts 10-30 pt (rolls DOWN the key, or sideways) before lifting. Rules now in code: only up-flicks exist; a touch lifting < 0.2 s after down types the key it went down on; a cross-key drift is a swipe only if held >= 0.18 s or travelled >= 1.1 key heights; key retarget needs 10 pt.
- Owner's saved setting has long-press = Short (0.3 s) at one point; check `iboard.settings.blob` via `devicectl ... appGroupDataContainer` if long presses misfire.

## Ideas not done yet
- Learn the owner's vertical/horizontal touch offset (taps land high on keys) and shift hit-testing accordingly.
- Return key autocorrect of the pending word (iOS does; owner decision pending).
- Replay real logs in `TouchLogReplayTests` as regression fixtures (strip nothing sensitive: logs have no characters).

## Rules
Never log or persist typed text; the recorder is DEBUG-only and must stay out of Release. Release build must be re-measured for perf claims.

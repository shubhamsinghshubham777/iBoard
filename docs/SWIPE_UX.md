# Swipe UX and gesture arbiter (M4-01, M4-03, M5-01)

Code: `Packages/IBoardUI/Sources/IBoardUI/` (`SwipeCapture`, `SwipeTrailLayer`, `SwipeEngine`, `GestureArbiter`, swipe part of
`TypingCoordinator`), wiring in `iBoardKeyboard/KeyboardViewController.swift` and `EngineHost.swift`.
Tests: `Packages/IBoardUI/Tests/IBoardUITests/` (`SwipeCaptureTests`, `SwipeCoordinatorTests`, `SwipeEngineTests`,
`GestureArbiterTests`, `TraceFixtures`).

## M4-01 capture and trail

- `SwipeCapture` (pure): one tracked finger. Down on a letter key of a letters layout = `undecided`; entering the touch region
  of ANOTHER letter key = `swiping` (F5: crosses >= 1 other key). Other fingers type normally. Raw samples are thinned
  (>= 1.5 pt apart) and capped at 512 (2:1 decimation, ends kept), the trail is an equidistant polyline (4 pt spacing,
  120 points, oldest dropped), so memory is bounded for any drag. All numbers are in `SwipeCaptureParameters`.
- When a touch becomes a swipe the controller cancels the key press in `KeyboardInputMachine` (no highlight, nothing typed).
  A long press (alternates) cancels capture.
- `SwipeTrailLayer`: ONE `CAShapeLayer` above the key layers (owned by `KeyGridView.trail`), stroked with the theme's
  `SwipeTrailStyle` (native: the action-key blue, 4 pt, 0.4 s fade). Path rebuilt per move from <= 120 points (quad curves),
  fade on lift via one `CABasicAnimation`; with Reduce Motion the trail is still drawn while the finger is down but removed at
  once on lift. After a fade the layer stays invisible (opacity 0) until the next swipe, `clear()` or the keyboard hiding.
- Verified on the simulator: a slow `axe swipe` across `t y u i` shows the blue trail over the keys (screenshot, iPhone 12 /
  iOS 27.0). NOT TESTED: fade appearance, Reduce Motion on a device, trail cost on a device, multi-touch while swiping.

## M4-03 swipe UX

- `SwipeEngine` (actor in IBoardUI, because `EngineActor` has no swipe entry point yet) owns a `SwipeDecoder`, built per swipe
  with the current `PersonalStore.scorer()` snapshot and the layout of the keyboard; the lexicon / LM are the same objects
  as the tap engine's (`EngineHost` builds both from one `Lexicon`). It returns up to three distinct words.
- `TypingCoordinator.swipeEnded(points:shift:)`: ends the word being typed literally, decodes off the main thread, then inserts
  `[space] word + " "`. Rules:
  - auto-space before unless the text before the cursor is empty, ends in whitespace/newline or an opener (`( [ { < " ' / \ - @ # $ _` ...);
    right after another swipe the implied space already exists;
  - shift at lift time: once = first letter, caps lock = all letters (a pending shift is consumed);
  - backspace right after a swipe deletes the whole word with its implied space (one `lastWordReopened` for the learner);
  - `. , ; : ! ? )` typed right after a swipe takes the implied space back (`hello ` -> `hello.`);
  - the strip shows the top three candidates (best in the middle); tapping another replaces the word (delete + insert,
    learner gets `lastWordReopened` + `suggestionTapped`), tapping the best one keeps it;
  - learning: `wordCommitted(word, .swipe)`; it counts as kept at the next typed character via the existing contract;
  - keys typed while the decoder is still working are queued and replayed after the word lands (order preserved);
  - nothing is inserted when there is no decoder yet, the path is too short or nothing matches; secure fields do not swipe.
- Verified on the iPhone 12 simulator (iOS 27.0, Debug, bundled 219-word lexicon): swipe `a -> l` inserts `All ` (auto-cap,
  implied space), a second swipe `a -> k` inserts `Ask ` without a double space, after the auto-shift fix `out` is lower-case,
  backspace removes `out ` as a unit. NOT TESTED on a device or with a real lexicon: re-pick by tapping an alternative (unit
  tests only: the fixture has too few collinear words to produce several candidates with a straight `axe swipe`), personal
  boost of swiped words, Full Access mode, rotation, Duo.
- `axe swipe` is a single straight drag with only ~3 move events: use words whose letter centres are collinear on the 219-word
  fixture (`all`, `ask`, `add`, `out`, `our`, `put`). `axe touch` has no move event, so curved swipes cannot be injected yet.
- Gotcha found: the auto-shift evaluation scheduled at lift ran BEFORE the async insert and saw a stale context, so the next
  swipe was capitalised; `TypingCoordinator.onAsyncEdit` now re-triggers it after the word lands.

## M5-01 gesture arbiter

`GestureArbiter` is a pure value type (no UIKit, no clock, no layout) implementing the F5 matrix; `GestureThresholds` holds
every number (tap 10 pt, long press 0.35 s, flick `|dy| > 1.5 |dx|` within 1 key height and 0.22 s, spacebar 12 pt, backspace
20 pt, backspace cancel < 10 pt left of the start). The host sends `move(to:time:crossedKeys:)`, `tick(now:)` and
`end(at:time:endedOverKeys:likelyWord:)` and gets the gesture the moment it is certain (`.swipeTyping`, `.spacebarCursor`,
`.spacebarSelection`, `.backspaceSwipeDelete`, `.longPress`) and the final one at lift (also `.tap`, `.flickUp/Down`,
`.backspaceSwipeCancel`). Flick vs swipe: while the touch still looks like a short vertical flick a crossing is NOT yet a
swipe; at lift `likelyWord` (from the swipe decoder) turns it into swipe typing, otherwise it is a flick.

Tests: 24 matrix tests on constructed traces plus 500 synthetic swipe words (real fixture words, 3 jitter levels, 3-12 keys/s,
`TraceFixtures`) that must classify as swipe typing with `likelyWord` and never as flick, cursor, selection, backspace swipe,
long press or tap. SYNTHETIC ONLY: no recorded touch traces exist, so the F5 acceptance on recorded traces is open.

NOT WIRED yet (belongs to M5-02..04): the controller still uses `SwipeCapture` directly, i.e. every crossing of a letter key
starts a swipe immediately, so a flick that crosses a key becomes swipe typing. When flicks land (M5-04) the controller must
feed the arbiter and start the trail only when it reports `.swipeTyping` (or buffer the samples while it is undecided);
the spacebar / backspace gestures (M5-02/03) consume `.spacebarCursor/.spacebarSelection/.backspaceSwipe*` the same way.

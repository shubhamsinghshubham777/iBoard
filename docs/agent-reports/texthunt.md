# Text-path fast-typing hunt (M2)

Status: [~] unit-tested with a lagging fake proxy only; not verified on a device (P-24 lag is real-host behaviour).

## Fixed (tests: `Packages/IBoardUI/Tests/IBoardUITests/StaleContextTests.swift`, all failed before the fix)
Root cause: `TypingCoordinator` read `documentContextBefore` right after its own `insertText`, which lags (P-24), and
decided spacing from that stale text. Fix: `recentEdit` records (proxy context before our edit, expected context
after it); while the proxy still reports the "before" value (< 1.5 s) `currentContext()` returns the expected value.
Cleared by any other input or backspace.
1. Double-space period missed when the second space arrives before the proxy shows the first ("hello  ").
2. Swipe right after a typed space inserted a second space ("hi  world ").
3. Swipe right after typed letters in an empty/lagging field glued the word ("aworld "); now `swipeFollowsWord`.
4. Backspace right after a swipe deleted only one character instead of the whole word when the proxy lagged;
   "." right after a swipe could likewise miss taking back the implied space.
5. `autoShift(context:)` auto-capitalised from the stale context after ". " (host passes the proxy context; it is now
   corrected when it equals the pre-edit snapshot).

## Suspected, not changed (behaviour choices or unproven)
- Return key does not autocorrect the pending word (iOS does). Needs an owner decision (undo path after return).
- Space right after a swipe (implied space already present) triggers the double-space period: "hello. ". Unverified
  against iOS QuickPath behaviour.
- Letter whose key is not in `letterKey` (hit == nil, e.g. non-Latin letters in a Hinglish/other layout) takes the
  separator path and commits the partial word as if finished. Alternates use `insertDirect`, so likely unreachable.
- Letter inserts are not tracked in `recentEdit` (only separators/swipes); a lagging proxy after letters is covered
  by token/flag fallbacks, not by exact context.

## Checked, nothing found
Autocorrect only acts when `lastSuggestions.literal == typed word` (stale suggestions cannot rewrite the wrong
range); undo-autocorrect delete count; apostrophe token handling; swipe then tap / deferred input replay; learner
gating in incognito / secure / excluded fields (`PersonalLearner.isLearning`, epoch cancel of in-flight jobs).

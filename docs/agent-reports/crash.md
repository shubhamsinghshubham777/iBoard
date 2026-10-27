# CRASH: keyboard dies on open with Full Access ON

## Evidence
- Fresh pull of `systemCrashLogs` from the iPhone 12 (15:05): NO new iBoardKeyboard .ips after 12:49 (newest are 2026-10-26 and the UUID bridge traps already fixed). So the post-Full-Access crash has no ground-truth log; everything below is ranked hypothesis. (Possibly a jetsam/other kill that writes no iBoardKeyboard .ips.)
- Earlier logs (2026-10-26 15:06-15:09, 6 crashes) show the exact failure class: `_dispatch_assert_queue_fail <- swift_task_isCurrentExecutor <- closure in KeyboardViewController.lexicon() <- thunk (UILexicon)->() <- -[UIInputViewController requestSupplementaryLexiconWithCompletion:]` and `pasteTest()` from `UIPasteboard` completion queue. A closure formed in a @MainActor method is inferred @MainActor; UIKit invokes it off-main; Swift 6 traps immediately.

## Ranked hypotheses
1. (Most likely, fixed) `requestSystemLexicon()` (runs every viewWillAppear) still passed a non-`@Sendable` closure to `requestSupplementaryLexicon`. Same defect class as the 10-26 crashes; the `DispatchQueue.main.async { assumeIsolated }` inside does not help because the trap fires on closure entry. With Full Access the request is served over XPC on a background queue (timing <0.5 s after start matches), so it manifests only then. Fix: `{ @Sendable [weak self] lexicon in ... }`.
2. (Not reproduced) First-run migration local -> App Group in `EngineHost.load`. Tests with real `FilePersonalStorage`: populated local -> missing group dir, two `PersonalStore` instances on same dir with concurrent writers, corrupt snapshot/journal: all pass, nothing traps; storage errors are swallowed. Runs on a detached task and creates the directory itself.
3. (Ruled out by reading) Haptics (only on key press), clipboard (requires `clipboardHistory`, default off; Task.detached closures are nonisolated), Insights persist (main only), file protection (only `ClipboardStore` uses `.completeFileProtectionUnlessOpen`; personal files use plain atomic writes), force unwraps in Full-Access paths.

## Changes
- `iBoardKeyboard/KeyboardViewController.swift`: `@Sendable` lexicon callback.
- `Packages/IBoardEngine/Tests/.../Personal/PersonalSharedGroupTests.swift`: migration/two-store/corruption tests.

## Next
After reinstall, if it still dies, pull crash logs again (`devicectl ... systemCrashLogs`) and check for JetsamEvent files; the App Group `personal/` dir should then also exist.

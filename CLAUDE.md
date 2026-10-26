# iBoard — agent guide

iBoard is an open-source (Apache-2.0), privacy-first iOS 27 keyboard that feels native and adds personal learning,
swipe typing, OTP codes, Hinglish, gestures, themes and iPhone Duo layouts.

**`ROADMAP.md` is the single source of truth.** Before doing anything:

1. Read `ROADMAP.md` §1–§6 and the latest progress-log entries (§15).
2. Run `scripts/bootstrap-agent-skills.sh` if the skills listed in ROADMAP §11 are missing locally.
3. Pick the next task per ROADMAP §1, mark it `[~]`, do it, verify it, then update the roadmap (checkbox, progress
   log, new facts/risks) **in the same commit**, pushed directly to `main` with a `[TASK-ID] summary` message.

Hard rules (details in ROADMAP §1):
- Locked decisions in ROADMAP §4 change only with the owner's approval.
- Performance budgets in ROADMAP §6 (base iPhone 12) are acceptance criteria.
- Never log or persist typed text; no network from the keyboard extension except opt-in features.
- Never vendor non-open-source skills or data; record licenses.

Build (until `scripts/build.sh` exists, task M0-12):

```sh
xcodebuild -project iBoard.xcodeproj -scheme iBoard -destination 'generic/platform=iOS Simulator' build
```

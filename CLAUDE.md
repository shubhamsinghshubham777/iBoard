# iBoard — agent guide

iBoard is an open-source (Apache-2.0), privacy-first iOS 27 keyboard that feels native and adds personal learning,
swipe typing, OTP codes, Hinglish, gestures, themes and iPhone Duo layouts.

**`ROADMAP.md` is the single source of truth.** Before doing anything:

1. Read `ROADMAP.md` §1–§6 and the latest progress-log entries (§15).
2. Run `scripts/bootstrap-agent-skills.sh` if the skills listed in ROADMAP §11 are missing locally.
3. Pick the next task per ROADMAP §1, mark it `[~]`, do it, verify it, then update the roadmap (checkbox, progress
   log, new facts/risks) **in the same commit**, pushed directly to `main` with a `[TASK-ID] summary` message.

**`docs/HANDOFF.md`** records the current working state (in-flight agents, the owner's open bug list, process, tool quirks).
Read it right after ROADMAP §1–§6.

Hard rules (details in ROADMAP §1):
- Locked decisions in ROADMAP §4 change only with the owner's approval.
- Performance budgets in ROADMAP §6 (base iPhone 12) are acceptance criteria.
- Never log or persist typed text; no network from the keyboard extension except opt-in features.
- Never vendor non-open-source skills or data; record licenses.

Build and test:

```sh
scripts/build.sh            # app + keyboard extension, iOS Simulator
scripts/test.sh             # swift test in every Packages/*, then xcodebuild test (iBoardTests + iBoardUITests)
scripts/test.sh --no-ui     # same, skipping UI tests
```

`build.sh` copies `Config/Local.xcconfig.example` to `Config/Local.xcconfig` if missing and runs `xcodegen generate`
only when `project.yml` is newer than the pbxproj. Set `DERIVED_DATA=<dir>` to change the build dir (default
`build/DerivedData`); `test.sh` also honours `SIM_NAME` to pick a simulator. CI: `.github/workflows/ci.yml` (hosted runners have no iOS 27 simulator, so simulator tests run in the local pre-push
hook: `scripts/install-hooks.sh`; skip once with `IBOARD_SKIP_HOOK=1`).

# Contributing to iBoard

Thanks for helping. iBoard is in early development and is worked on by humans and coding agents using the same rules.
[ROADMAP.md](ROADMAP.md) is the single source of truth for scope, decisions and progress.

## Workflow in short

1. Read `ROADMAP.md` sections 1 to 6 and the latest progress-log entries (section 15).
2. If the agent skills listed in ROADMAP section 11 are missing locally, run:

   ```sh
   scripts/bootstrap-agent-skills.sh
   ```

   It restores the Apple and PolyForm-licensed skills that cannot be redistributed. It needs Xcode 27+ and Node.js
   (`npx`), and is safe to re-run.
3. Pick the next unblocked task in ROADMAP section 9 (`[ ]` with all dependencies `[x]`), or open an issue first
   for anything else. Tasks marked for the owner are not for contributors or agents.
4. Mark the task `[~]`, do it, and verify it. Say exactly what you did and did not test.
5. In the same commit, update the roadmap: checkbox, a new progress-log entry at the top, and any new platform facts
   (section 5) or risks (section 13).
6. **One task per commit** where practical. Commit message format: `[M1-03] Short imperative summary`.

Maintainers push agent work directly to `main`; external contributors should open a pull request.

## Hard rules

- Locked decisions (ROADMAP section 4) change only with the owner's approval. If you think one is wrong, open an
  issue with evidence.
- Performance budgets (section 6, measured on a base iPhone 12) are acceptance criteria.
- Never log or persist typed text, not even in debug builds (use counts or lengths). No analytics SDKs.
- No network from the keyboard extension except opt-in features listed in the roadmap.
- Never vendor non-open-source skills or data. Record licenses in `NOTICE` and the roadmap.

## Code style

- **Swift 6 language mode** for all new packages (D-25). Engine types are `Sendable`; engine work runs off the main
  thread.
- **UIKit + Core Animation with manual frame layout** for the keyboard UI: no SwiftUI and no Auto Layout in the key
  grid (D-24). The companion app is SwiftUI.
- Keep layout size-agnostic: no `UIScreen.main`, no reliance on orientation or idiom checks.
- Measure against the performance budgets rather than guessing.

## Building and testing

Build steps are in [README.md](README.md). Per-user settings go in the untracked `Config/Local.xcconfig`.
`project.yml` (XcodeGen) is the source of truth for the Xcode project: after adding a source file or target, run
`xcodegen generate` and commit the project change deliberately.

Before pushing:

```sh
scripts/test.sh --packages-only   # privacy audit + swift test in every package and Tools/LexiconBuilder
scripts/build.sh                  # app + keyboard compile for the iOS Simulator
```

- `scripts/audit-privacy.sh` fails on any new logging call, network API, analytics name, pasteboard access or
  file/UserDefaults write in shipped code. If a change legitimately needs one, add a reviewed entry to
  `scripts/audit-privacy.allowlist` with a reason showing no typed text is involved. It is a tripwire, not proof: the
  hard rules above still apply.
- Benchmark tests enforce performance budgets only in release (`swift test -c release -Xswiftc -enable-testing`);
  debug runs report numbers. Say whether a number came from macOS, a simulator or a device, and never present a
  simulator figure as a device figure.
- Write tests with Swift Testing (`@Test`, `#expect`). State plainly what you did not test.

## Working with coding agents

Agents follow `CLAUDE.md` / `AGENTS.md`, which point at `ROADMAP.md`. When several run in parallel, each works in its
own worktree with a disjoint file list, does not edit `ROADMAP.md` (the orchestrator records facts, risks and the
progress log), does not commit regenerated `iBoard.xcodeproj` changes (it lists files needing `xcodegen generate`
instead), and never touches the owner's physical device while it is being tested.

## Conduct and security

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md), not in public issues.

## Pre-commit hook (local simulator tests)

GitHub-hosted runners ship Xcode 26 and have no iOS 27 simulator, so CI cannot run the app's simulator tests
(`ios-build-test` only builds; the test step skips itself there). Run `scripts/install-hooks.sh` once per clone: the
pre-commit hook then runs the privacy audit on every commit and, when Swift/project/entitlement files are staged,
`scripts/test.sh --no-ui` (all package tests plus the app's unit tests on an iOS 27 simulator). Skip a WIP commit with
`IBOARD_SKIP_HOOK=1 git commit ...`.

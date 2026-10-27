# iBoard — agent handoff (written 2026-10-27, mid-session; round 4 appended at the end)

Read `CLAUDE.md` and `ROADMAP.md` first (single source of truth: §4 decisions, §5 platform facts P-01…P-27, §9 tasks with
dated Result/Partial notes, §13 risks, §15 progress log). This file records the *working state and process* that the roadmap
does not: what is in flight, how work is run and merged, tool quirks, and the owner's open bug list.

## 1. State at handoff
- `main` is pushed to https://github.com/shubhamsinghshubham777/iBoard (public). Push with
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin main` (plain `git push` has no credentials).
- All package tests were green at the last merge (Core 35, Layout 40, Engine 227, OTP 11, Theme 18, UI 185, Sync 8, Emoji 21,
  LexiconBuilder 7) and `scripts/build.sh` succeeds. Known flaky: macOS debug timing tests (`ReaderBenchmarks`) fail under
  load, pass alone (R-11; round-7 QUALITY agent is fixing).
- **Round 7 (KBD7, ONBOARD, QUALITY) and the English-data agent are all MERGED (2026-10-27); no agents are in flight.** Bundling `Data/english/*` into the keyboard is done on `fix/owner-bugs` (bug 4).
- **In-flight agents, each in its own worktree** (branch = worktree name):
  | Agent | Worktree / branch | Scope |
  |---|---|---|
  | KBD7 | `.claude/worktrees/wf_b8b92d0f-b8b-1` / `worktree-wf_b8b92d0f-b8b-1` | keyboard reads settings v3, bundles Hinglish, Duo split + pinch, theme rendering; owns simulators `kbd7` and `duo7` |
  | ONBOARD | `…-2` | OTP guided setup, self-test, M10-01 onboarding, investigates signed `.shortcut` |
  | QUALITY | `…-3` | flaky-test fix, `scripts/audit-privacy.sh`, CI, README/CONTRIBUTING/ARCHITECTURE docs, accessibility review (docs only) |
  | ENGLISH-DATA (MERGED 2026-10-27, `Data/english/` is on main) | `.claude/worktrees/agent-a8fc6ff6bd3c02bb4` / `worktree-agent-a8fc6ff6bd3c02bb4` | real English lexicon + LM into `Data/english/` + `Tools/EnglishData/` |
  When each finishes you get a task notification; read its result in
  `~/.claude/projects/-Volumes-SSD-Projects-Personal-iBoard/<session>/subagents/workflows/<run>/journal.jsonl`.
  If an agent died on a usage limit, its worktree still holds uncommitted work: `git -C <worktree> status`, then start a
  continuation agent *inside that worktree* (done successfully in round 5).
- Simulators left booted by agents: `kbd7`, `duo7` (agent-owned), and the owner's `iPhone Duo` (Device Hub). Delete agent sims
  after their agent finishes (`xcrun simctl shutdown/delete <id>`).
- The owner's iPhone 12 (UDID `00008101-0014596A1E01001E`) currently has the **round-6 Debug build** installed
  (`app.iBoard`) for the owner to test; do not install over it without telling them.

## 2. Owner's bug list (from device testing of the round-5/6 build) — FIXED on branch `fix/owner-bugs`, simulator-verified only (details: `docs/BUGFIX_NOTES.md`)
Status 2026-10-27: 1 fixed (emoji button; 123 long-press neutral; slide-from-123), 2 fixed (line-end wrap), 3 fixed (preview + one change), 4 fixed (English data bundled; first-swipe buffer; prediction fixes; **footprint 25-31 MB Debug sim, recheck on device**), 5 fixed (gradient trail), 6 fixed (caps lock), 7 fixed (continuous list), 8 **partially**: a host-drawn selection is impossible; live in-field deletion preview is the default. Nothing was tested on the physical phone. Original list kept below for reference.
Do these in ONE dedicated keyboard-owner agent *after* round 7 is merged (they touch the same files as KBD7: `Packages/IBoardUI`,
`iBoardKeyboard/`):
1. Holding the **123** key opens the emoji panel — unexpected. Give emoji its own affordance; 123 long-press should behave like iOS.
2. **Spacebar cursor drag across lines:** dragging left wraps up to the previous line, but dragging right at the end of the top
   line does NOT wrap down. Match Gboard's behaviour (symmetric wrapping across hard line breaks).
3. **Height drag handle** flickers/is unstable. Owner's proposal: show a stable overlay during the drag and apply ONE final
   height on release.
4. **Gesture typing types nothing** (trail only). Root cause confirmed: the bundled English lexicon is the 219-word synthetic
   fixture (`iBoardKeyboard/Resources/lexicon.iblex`, 14 KB). The ENGLISH-DATA agent builds the real one in `Data/english/`;
   then bundle it (lazy, mmap, watch the 30/40 MB footprint, P-21) and re-verify swipe on real words. Also: first swipe
   before the engine finished loading inserts nothing.
5. **Swipe trail looks bad** — redesign: thinner, smooth, modern, gradient with a fading tail; respects Reduce Motion.
6. **No caps lock**: double-tap shift must lock; holding shift while typing a letter (one-handed) must capitalise once.
   Add clear on-key indicators.
7. **Emoji panel revamp:** one continuous scroll through all emojis across categories (people remember scroll distance, not
   category); category chips jump to positions; keep search, recents; remember scroll position.
8. **Backspace swipe-delete has no visual preview:** while dragging, the words that will be deleted must appear *selected*
   (highlighted) in the text field like a cursor selection; on release they are deleted. (Keyboards cannot set a selection range —
   P-08/D-27 — so this needs the strip/virtual-selection approach or a marked-text trick; evaluate and test in a real host.)
Agreed extras (unless the owner objects): visual/haptic cue when caps lock turns on, comma long-press for quick punctuation,
reachable undo of the last autocorrect.

## 3. Owner-only steps still outstanding
- Real-phone test checklist was sent (typing, suggestions, autocorrect, gestures, haptic/click feel, debug overlay numbers for
  the M1-09 perf gate, OTP chip). Results of items 1-8 above came from it; more may follow.
- After the English dictionary + fixes land: reinstall on the phone (`xcodebuild … -destination id=00008101-0014596A1E01001E
  -allowProvisioningUpdates` then `xcrun devicectl device install app --device <udid> <path>/iBoard.app`).
- The owner's Shortcuts automations **"Capture Verification Code - E…"/"iBoard OTP Test"** call the app's `Capture Verification
  Code` action; after replacing the spike build with the production build the action may need re-picking.
- M0-10: only visual evidence so far (labelled screenshots in `docs/spikes/M0-10-assets/owner-*.png`); extension frame sizes
  and hinge-data arrival are still unmeasured.

## 4. How work is run (process that worked)
- Parallel agents, one git worktree each (`Agent`/`Workflow` with `isolation: 'worktree'`), **disjoint file sets**, never
  editing `ROADMAP.md`, never committing `iBoard.xcodeproj` (run `xcodegen generate` after merging; `project.yml` is the source
  of truth, D-28), no physical-device use unless the orchestrator says so, only ONE agent may drive a simulator.
- Merge: `git merge --no-edit <branch>` per worktree in the main checkout, `xcodegen generate`, run `swift test` in every
  `Packages/*` and `Tools/LexiconBuilder`, `scripts/build.sh`, then update ROADMAP (task checkbox/notes, facts, risks, progress
  log), commit `[TASK-IDs] …`, push, `git worktree remove --force` + `git branch -D` for each merged worktree.
- Statuses: use `[~]` with a dated "Partial/Update" note whenever behaviour is only unit/simulator tested; `[x]` only when verified.
- Never claim unmeasured performance; macOS/simulator timings are not iPhone 12 numbers.

## 5. Tools & quirks
- **Simulator driving:** `axe` (installed via brew tap `cameroncooke/axe`, formula trusted). `axe touch --down --up` is more
  reliable than `axe tap` on keyboard UI; `axe swipe --delta 4` for drags. It times out on the iPhone Duo simulator. Many booted
  sims make it flaky — run simulator work one agent at a time. `simctl clone` fails on booted devices (use `simctl create`).
  Enable the keyboard in a sim: `xcrun simctl spawn <id> defaults write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic" "app.iBoard.keyboard"`,
  `AppleKeyboardsExpanded -bool true`, reboot, tap a field, globe long-press. Serve test pages from `http://127.0.0.1` (not
  localhost, no `data:` URLs).
- **Device:** read the app's App Group prefs without the owner:
  `xcrun devicectl device copy from --device <udid> --domain-type appGroupDataContainer --domain-identifier group.app.iBoard --source Library/Preferences/group.app.iBoard.plist --destination <file>` then `plutil -p`.
  Extension container files: `--domain-type appDataContainer --domain-identifier app.iBoard.keyboard`. Crash logs:
  `--domain-type systemCrashLogs`. Console of an app: `devicectl device process launch --console`.
- **App Intents** only appear in Shortcuts if the intent file is in the generated project (run `xcodegen generate` after adding it);
  the build log says "Metadata extraction skipped" otherwise.
- **Gmail connector** (used for the Email OTP test) sends as `shubham@ayrindigital.com`, not the owner's gmail; always ask the
  owner which address and get explicit OK before sending any email.
- `sleep` chains are blocked in the Bash tool; use background tasks/Monitor.
- Usage-limit interruptions happened once (session reset ~02:20 IST); agents commit early so work can be resumed.

## 6. Verified platform facts worth re-reading
P-21 memory ceiling ≈ 76–80 MB; P-22 system glass backdrop (no custom backdrop effect); P-23 Full Access matrix (keyboard can
READ app-written App Group defaults without Full Access, cannot write/network/pasteboard/haptics; `playInputClick` needs
`UIInputViewAudioFeedback` + the Settings > Sounds & Haptics > Keyboard Feedback > Sound toggle); P-24 text proxy
(`adjustTextPosition` counts UTF-16 units; 500-char left context); P-25 pasteboard prompt + off-main callbacks need
`@Sendable`; P-26 Foundation Models unavailable on iPhone 12; P-27 OTP automations (Message and Email) run the background
intent headless on device; after a restart the first run is delayed until Shortcuts is opened once.

## 7. Roadmap pointers
Done/mostly done: M0 (except M0-10 measurements), M1-01…M1-09 partly, M2 engine side, M3 engine side, M4 engine side, M5-01…05
(partly), M6-01/02/03/06, M7 data+scoring, M8-01/02, M9, M10-02…05, M11 layout logic (estimated numbers), M12-01 merge model,
M13-03 manifests. Not started: M12-02/03 (CloudKit), M13-01 accessibility fixes, M13-02 perf soak, M13-04 App Review audit,
M13-05/06 (owner), M6-05 clipboard fallback, M8-03 haptics/sound packs, M8-04 landscape refinements, M8-05 wiring, M1-09 device
perf gate, M4-04/M2-07 real eval sets.

## 8. Round 4 state (2026-10-27, newest; this section supersedes the stale lines above)
- `main` holds everything; no agents in flight. Owner has given standing permission to install builds on the physical iPhone
  (`xcodebuild ... -destination id=00008101-0014596A1E01001E -allowProvisioningUpdates build`, then
  `xcrun devicectl device install app --device 00008101-0014596A1E01001E build/DeviceDD/Build/Products/Debug-iphoneos/iBoard.app`),
  and wants UI work verified by automation where possible. Still ask before sending email.
- Simulator caveat: on this Xcode 27 / Device Hub setup the soft keyboard never appears in simulators (axe can tap a field but no
  keyboard shows), so keyboard UI is verified on the phone and via package tests plus UIKit snapshot renders in a throwaway test.
- Device crash logs: `xcrun devicectl device copy from --device <udid> --domain-type systemCrashLogs --source / --destination <dir>`
  (iBoardKeyboard-*.ips; read `threads[faultingThread].frames`). This found the `documentIdentifier` crash (P-29).
- Open items: confirm P-28 scroll fix; measure footprint with 32 pt emoji; long-press emoji key -> Settings on iOS 27; hint symbols;
  reproduce the occasional empty suggestion strip (see BUGFIX_NOTES round 4); search-results polish.
- Next roadmap task: M1-09 (perf gate, needs owner device numbers). Not built: autocorrect-target underline, GIF/stickers, per-key
  gradients (needs budget check), per-app themes, Settings toggles that need App Group plumbing.


## 9. Handoff 2026-10-27 (evening) — supersedes §1/§7/§8 where they conflict
- `main` holds everything (HEAD = latest `[CI]` commit); **no agents in flight**; all agent worktrees/branches deleted. Owner granted
  **full autonomy** ("do whatever it takes to complete the roadmap and make it production ready"); they still must do Apple-account
  steps themselves. D-29: Full Access is requested (`RequestsOpenAccess: true`), confirmed on the owner's phone (off by default).
- Device: owner's iPhone 12 `00008101-0014596A1E01001E` has the latest **Debug** build (keyboard stable with Full Access; typing, swipe,
  emoji verified by the owner). iCloud container `iCloud.app.iBoard` + entitlement are set; first sync succeeded. Install with
  `xcodebuild -project iBoard.xcodeproj -scheme iBoard -configuration Debug -destination id=<udid> -derivedDataPath build/DeviceDD -allowProvisioningUpdates build`
  then `xcrun devicectl device install app --device <udid> build/DeviceDD/Build/Products/Debug-iphoneos/iBoard.app` (needs the phone unlocked/trusted).
- Process: parallel worktree agents with disjoint file ownership, no agent edits ROADMAP.md (they write `docs/agent-reports/*.md`; the
  coordinator merges + updates the roadmap). Hooks: run `scripts/install-hooks.sh` (pre-commit = privacy audit, pre-push = `scripts/test.sh --no-ui`);
  hosted CI has Xcode 26 / no iOS 27 simulator, so it only builds and runs package tests (simulator tests skip there).
- Fixed this session: Full Access launch crash (likely `requestSupplementaryLexicon` callback off-main, now `@Sendable`; not reproduced
  — if it recurs pull `systemCrashLogs` and JetsamEvent files), sync code removed from the extension (audit check EXT-SYNC), CI.
- **Open work (owner-independent):** swipe accuracy for the sloppy profile (F3), real-finger swipe traces/recorder for M4-04, Duo
  pose verification M11-05 (Device Hub simulator screenshots came back black — try again/other approach), M11-06 split layout seen on a Duo
  sim, M13-01 remaining a11y (Switch/Voice Control, rotor, emoji), M8-03 sound packs impossible in an extension (P-23), M6-04/M10-01 OTP shortcut
  signing/self-test on device, M12 two-device merge + Keychain key sharing + size limits, per-app themes/GIF/stickers (backlog), strict-concurrency warnings.
- **Needs the owner:** device perf run (docs/perf/README.md → `scripts/device-perf.sh pull`; unblocks M1-09/M13-02), device pass over all `[~]`
  keyboard features, App Store Connect (privacy URL = https://shubhamsinghshubham777.github.io/iBoard/privacy.html, support URL `/support.html`,
  review-notes contact, screenshots), TestFlight (M13-05), submission + public launch (M13-06): see `docs/RELEASE_CHECKLIST.md`.

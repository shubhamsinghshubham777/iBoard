# iBoard Roadmap

> The single source of truth for building iBoard. Every agent reads this before working and updates it before
> finishing. If code and this document disagree, fix one of them in the same commit.

**Last updated:** 2026-10-27 · **Phase:** M0 (Foundations & spikes) · **Next task:** `M1-09` (perf gate; needs footprint numbers from the owner's iPhone 12)

---

## Contents

1. [Agent protocol](#1-agent-protocol-read-first)
2. [Status board](#2-status-board)
3. [Vision](#3-vision)
4. [Locked decisions](#4-locked-decisions)
5. [Platform facts & constraints](#5-platform-facts--constraints)
6. [Target devices & performance budget](#6-target-devices--performance-budget)
7. [Architecture](#7-architecture)
8. [Feature specifications](#8-feature-specifications)
9. [Milestones & tasks](#9-milestones--tasks)
10. [Testing & quality](#10-testing--quality)
11. [Agent skills](#11-agent-skills)
12. [Repository map](#12-repository-map)
13. [Risks & open questions](#13-risks--open-questions)
14. [Backlog (post-v1)](#14-backlog-post-v1)
15. [Progress log](#15-progress-log)
16. [Sources](#16-sources)

---

## 1. Agent protocol (read first)

**At session start**
1. Read §1–§6 fully, then the spec (§8) and milestone (§9) sections for the task you pick.
2. Read the latest 5 entries of the [Progress log](#15-progress-log).
3. If skills listed in §11 are missing locally, run `scripts/bootstrap-agent-skills.sh`.

**Picking work**
- Take the first task in §9 whose status is `[ ]` and whose `Depends` are all `[x]`. Work milestones in order unless
  the owner says otherwise. Spikes (M0) gate the milestones listed in their `Unblocks` field.
- Tasks marked `👤` need the owner (Shubham) — e.g. Apple ID, physical device, App Store Connect. Don't attempt them;
  prepare everything around them and say what you need in the progress log.
- Mark the task `[~]` (in progress) in this file **as your first commit** for that task.

**Finishing work** (all in the same commit, pushed to `main`)
1. Code builds (`scripts/build.sh` once M0-12 lands; until then the `xcodebuild` command in §10) and tests pass.
2. Task checkbox → `[x]`, with a one-line result. Status board (§2) updated if a milestone changed state.
3. New entry at the top of the Progress log: date, task ID, what changed, what you verified and how, follow-ups.
4. Any new platform fact → §5 with source and date. Any new risk → §13. Any agent-made design choice → §4
   with `(agent)` tag so the owner can veto it.
5. Commit message: `[M1-03] Short imperative summary`. One task per commit where practical.

**Rules**
- **Locked decisions (§4) change only with the owner's explicit approval.** If a spike disproves one, mark the task
  `[!]` blocked, write the evidence in §13, and stop.
- Never mark a task done without verification you actually ran. Say exactly what was and wasn't tested.
- Performance budgets (§6) are acceptance criteria, not aspirations. A regression is a failing task.
- Keep this file truthful and compact: replace stale text instead of appending contradictions. Move finished
  spike findings into §5 and keep only a one-line pointer in the task.
- Privacy is a product feature: no network calls from the keyboard extension except opt-in features listed in §4,
  no logging of typed text (not even in debug builds — use counts/lengths), no analytics SDKs.

**Status legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked · `👤` needs owner

---

## 2. Status board

| Milestone | Goal | Status |
|---|---|---|
| **M0** Foundations & spikes | Toolchain, project structure, de-risk every platform unknown | In progress (spikes done except M0-10 Duo measurements) |
| **M1** Keyboard shell & layout engine | A fast, native-looking keyboard that types letters | Built; M1-09 perf gate needs the owner's device run (no numbers yet) |
| **M2** Language engine v1 (English) | Suggestions, conservative autocorrect, smart punctuation | Built; real-typing F2 not demonstrated |
| **M3** Learning & personal model | Learns words/phrases, adaptive touch model, incognito | Built; device pass pending (forget menu, UILexicon) |
| **M4** Swipe typing | Gesture typing that uses the personal model | Built; F3 met on synthetic traces for careful/normal, sloppy just short; real traces needed (M4-04) |
| **M5** Gestures & editing | Spacebar cursor, backspace swipe, key flicks, Shift+space select | Built; device pass pending |
| **M6** OTP & smart chips | Codes from SMS/Email/clipboard, personal-info chips | Built; OTP shortcuts need device verification; clipboard code chip tap-only |
| **M7** Hinglish | Romanized Hindi mixed with English, same session | Built; eval run (tap meets F2, swipe near F3 on synthetic data) |
| **M8** Themes, feel & landscape | Theme studio, translucency, haptics/sounds, landscape layouts | Built (theme studio, haptic packs, landscape side keys, a11y wiring); device pass pending |
| **M9** Emoji & clipboard | Emoji panel/search/prediction, clipboard manager | Built (emoji, clipboard history panel); device pass pending |
| **M10** Companion app | Onboarding, settings, dictionary manager, typing insights | Built (onboarding, settings, dictionary, insights, privacy/licences) |
| **M11** iPhone Duo | Outer/inner layouts, auto split, laptop snap | Layout logic built; Duo poses NOT verified (M11-05) |
| **M12** iCloud sync (opt-in) | Encrypted sync of the personal model | Engine + CloudKit + app screen built; first device sync OK (2026-10-27); two-device merge untested |
| **M13** Hardening & launch | Accessibility, perf soak, App Review, open-source launch | Accessibility partial, privacy/App Review audit drafted; perf soak + TestFlight/submission open |

**Current blockers:** none. **Owner-reported bugs (device test, 2026-10-27):** fixed on branch `fix/owner-bugs`, simulator-verified only, bug 8 partial — see `docs/BUGFIX_NOTES.md` (was: 123 long-press opens emoji, spacebar wrap-down, resize flicker, swipe typing types nothing because only a 219-word English fixture is bundled, trail redesign, caps lock, emoji panel revamp, backspace swipe-delete preview).

---

## 3. Vision

iBoard is a free, open-source iOS keyboard that **feels exactly like the Apple keyboard on day one** and then quietly
becomes better than it: it learns the user's words and phrases, reads one-time codes, edits text with fluid
gestures, and types Hinglish as naturally as English — all on-device.

**Product pillars (in priority order when they conflict)**
1. **Native first.** The default theme, metrics, sounds and behaviors match the iOS 27 system keyboard so users feel
   at home. Improvements are invisible until they help; nothing surprises.
2. **Fast and stable on a base iPhone 12.** A dropped keystroke or a crash is worse than a missing feature.
3. **Private by construction.** Offline-first; no data leaves the device unless the user turns on an opt-in feature.
4. **Genuinely smarter.** Personal learning, adaptive touch, phrase prediction, OTP, Hinglish.
5. **Delight.** Theme studio, translucent looks, iPhone Duo layouts.

**Honest scope note — "native feel":** we can match the system keyboard's layout, key metrics, typography (SF Pro),
colors, backdrop style, system click sound (`playInputClick`), auto-capitalization and punctuation behavior, shift and
caps-lock semantics, delete acceleration and return-key labels. We **cannot** match: system dictation (no mic in
keyboard extensions), haptics without Full Access, appearing in secure/phone-pad fields or apps that opt out of
custom keyboards, the system's exact touch model on day one (our adaptive model must earn it), and possibly true
see-through blur of the host app (spike `M0-04`). The default experience is designed around these limits, not
hiding them.

---

## 4. Locked decisions

Decided with the owner on 2026-10-26 unless tagged `(agent)`. `(agent)` items are defaults an agent chose; the owner
may change them without ceremony.

| ID | Decision |
|---|---|
| D-01 | **Open source (Apache-2.0) + free App Store release.** Must comply with App Store Guideline 4.4.1 (works without Full Access, no data collection, no ads/marketing in keyboard, no launching apps other than Settings). No paywall. |
| D-02 | **Languages at launch: English + Hinglish** (romanized Hindi, code-switched in the same session, no layout switch). Spelling variant (US/UK/IN) follows device locale, changeable in settings. Other languages via a pluggable language-pack design later. |
| D-03 | **Devices: iPhone first; iPad later.** Layout engine is size-agnostic from day one. **iPhone Duo is supported** with a dedicated milestone (M11) right after core typing. |
| D-04 | **Minimum iOS 27.0**, built with **Xcode 27.1+** (needed for iPhone Duo simulator and Apple's App Resizability skill). |
| D-05 | **Performance reference device: base iPhone 12 (A14, 4 GB RAM, 60 Hz) on iOS 27.** Every budget in §6 is measured there. |
| D-06 | **Privacy: offline-first, opt-in extras.** Core typing never uses the network. Opt-in only: iCloud sync. GIFs etc. are backlog. |
| D-07 | **Native-first default.** Default theme "Native" mirrors the iOS 27 system keyboard (light/dark, follows `keyboardAppearance`). Behavior defaults mirror iOS. All iBoard extras are additive and individually switchable. |
| D-08 | **No key-press preview popups (balloons).** Tap feedback is a key-cap highlight (like iOS with Character Preview off) + click + optional haptic. Long-press alternates are shown **in the suggestion strip** (see F1), never as a balloon. |
| D-09 | **OTP sources:** SMS via a bundled iOS 27 Shortcuts automation, Email via bundled automation, clipboard fallback (Full Access). Third-party messaging apps: not possible today, tracked in §13. |
| D-10 | **Learning policy: adaptive with easy undo.** Words kept by the user are learned at first use with low weight that grows with use; long-press a suggestion to forget it; repeated phrases are learned. |
| D-11 | **Learning sources:** typing; Contacts + iOS Text Replacements via `UILexicon`; import/export file; iCloud sync (opt-in, off by default). |
| D-12 | **Autocorrect default: conservative.** Prefer suggestions over replacements; correct only high-confidence typos; backspace right after a correction reverts it; a word reverted twice is never auto-corrected again; the strip always offers the literal typed word. Aggressiveness adjustable. |
| D-13 | **Phrases: smart wide chip.** When a multi-word continuation is confident, one of the 3 slots expands into a phrase chip; tap inserts the phrase, long-press inserts only the next word. |
| D-14 | **Gestures:** spacebar swipe moves cursor; backspace swipe-left deletes words with preview and cancel; flick up on a key = its number/symbol, flick down = its alternate; **Shift + spacebar swipe selects text** (incl. across lines). No long-press trackpad mode and no editing panel in v1. |
| D-15 | **v1 extras:** clipboard manager, emoji search + prediction, personal-info chips, adaptive touch model, incognito + per-field rules, typing insights. |
| D-16 | **AI:** feasibility spike in M0 for on-device Foundation Models (proofread/rewrite); ships post-v1 only if the spike passes. No cloud AI. |
| D-17 | **Theming: full theme studio** (presets, photo/gradient backgrounds with blur/dim/translucency, per-element styling, swipe trail color, light/dark variants, export/import). Default remains "Native" (D-07). |
| D-18 | **Resize: in-keyboard drag handle + fine-tune slider in app**, saved per orientation and per display class (iPhone, Duo outer, Duo inner). |
| D-19 | **Layout/feedback options in v1:** number-row toggle, haptics + sound packs, landscape-optimized layouts. (Alt Latin layouts → backlog.) |
| D-20 | **iPhone Duo inner display:** landscape defaults to a **split** layout with a centre gap over the fold; portrait defaults to full width with capped key size; pinch toggles split per orientation and is remembered. **Laptop pose:** resize handle has a "fill to fold" snap at half the inner landscape height. |
| D-21 | **Docs layout:** this `ROADMAP.md` + short `CLAUDE.md` (and `AGENTS.md` → symlink) pointing here. |
| D-22 | **Git flow:** agents commit finished, building, tested tasks **directly to `main`**. |
| D-23 | **Agent skills:** MIT-licensed skills are vendored in `.agents/skills`; Apple's Xcode skills and PolyForm-licensed skills are not redistributable and are restored by `scripts/bootstrap-agent-skills.sh`. |
| D-24 | `(agent)` **Rendering stack:** keyboard UI in UIKit + Core Animation with manual frame layout (no SwiftUI, no Auto Layout in the key grid); companion app in SwiftUI. |
| D-25 | `(agent)` **Swift 6 language mode** for all new Swift packages; engine types are `Sendable` and engine work runs off the main thread. |
| D-26 | `(agent)` **Identifiers:** app `app.iBoard`, keyboard extension `app.iBoard.keyboard`, App Group `group.app.iBoard`, iCloud container `iCloud.app.iBoard`. Contributors override team/bundle prefix via `Config/Local.xcconfig` (gitignored). |
| D-29 | **Data licensing (owner, 2026-10-26):** CC BY-SA data is acceptable for shipped dictionaries (derived dictionary files released under CC BY-SA 4.0 with attribution); non-commercial/research-only/unclear-licence sources stay excluded. Code remains Apache-2.0. |
| D-30 | **Repo:** public from the start at github.com/shubhamsinghshubham777/iBoard; free GitHub features only (private vulnerability reporting enabled). |
| D-31 | `(agent)` **Owner round 4 defaults (2026-10-27, all individually switchable or easy to revert):** Native key tiles are slightly translucent (62 % light / 50 % dark, `ThemePresets.nativeKeyAlpha`); hint symbols on letter keys are on by default and a long press offers the hint symbol first (`KeyAlternates.longPressOptions`; stored key renamed `keyHints`); long-press time is a setting, Standard 0.45 s (was 0.35); with the comma/period keys on, long return labels (search/go/send/join/route/continue) become icon keys 1.56 keys wide so the space bar keeps room; long-press the emoji key for a shortcut to the iOS Settings page (launching Settings is allowed by 4.4.1; D-01 and R-09 unchanged, opening the app itself was declined). |
| D-29 | `(agent)` **Request Full Access (owner approved 2026-10-27):** `RequestsOpenAccess: true` so iOS offers the Full Access switch (with `false` there is no switch, confirmed on the owner's iPhone 12). Core typing still works without it (D-01/4.4.1); Full Access only unlocks haptics, clipboard features, app-shared counters and iCloud sync. |
| D-28 | `(agent)` **Project generation:** `project.yml` (XcodeGen, `brew install xcodegen`) is the source of truth for `iBoard.xcodeproj`; re-run `xcodegen generate` after adding targets/files outside synchronized folders. Team ID lives in gitignored `Config/Local.xcconfig` (copy `Config/Local.xcconfig.example`). |
| D-27 | `(agent)` **Selection rendering:** because keyboards cannot set selection, Shift+space selection is a keyboard-tracked "virtual selection" previewed in the suggestion strip; the marked-text highlight trick is not used by default. |

---

## 5. Platform facts & constraints

Verified facts that shape the design. Each has a source; "verify" items must be re-checked by the linked spike.

| ID | Fact | Consequence | Source / status |
|---|---|---|---|
| P-01 | Third-party keyboards cannot read SMS, Mail or notifications. The system keyboard's OTP AutoFill is unavailable to them. | OTP must come via Shortcuts automations or clipboard (D-09). | Apple docs; well established |
| P-02 | iOS 17+ "Message" personal automations can run without confirmation; on **iOS 27 automations are saved as shortcuts**, so an app can distribute a ready-made `.shortcut` with the Message trigger. User must switch *Automation* on and keep *Confirm Before Run* off. | One-time ~2-tap OTP setup. | forwardsmsapp.com iOS 27 guide (2026); verify in `M0-06` |
| P-03 | Shortcuts also has an Email (communication) trigger. | Email OTP path. | Apple Support "Communication triggers"; verify in `M0-06` |
| P-04 | Keyboards never appear in secure text fields, phone-pad fields, or apps that reject custom keyboards. | Don't promise OTP in those places; onboarding explains it. | Apple docs |
| P-05 | No microphone access in keyboard extensions. | No voice typing in v1. | Apple docs |
| P-06 | Open Access (Full Access) is required for network, writing to the shared App Group, and in practice haptics and pasteboard. Keyboard must remain functional without it (Guideline 4.4.1). | Core typing + learning must work with extension-local storage. | Apple docs; exact read rules → `M0-05` |
| P-07 | Extension memory limit is strict, varies by device and is not documented; exceeding it kills the extension. Dismissing the keyboard does not free memory. | Budgets in §6; mmap'd dictionaries; respond to memory warnings. | Apple "Creating a custom keyboard"; measure → `M0-03` |
| P-08 | `UITextDocumentProxy` can insert/delete, move the cursor by offset (`adjustTextPosition`), read `documentContextBeforeInput/AfterInput`, `selectedText`, marked text, and input traits (`keyboardType`, `returnKeyType`, `textContentType`, `autocapitalizationType`, `autocorrectionType`, `smartQuotesType`, `keyboardAppearance`, …). **It cannot set a selection range** and context length is host-dependent. | Virtual selection (D-27); context-limited LM; trait-driven behavior. | Apple docs; limits → `M0-08` |
| P-09 | On Face ID iPhones the system draws the globe key below the keyboard and `needsInputModeSwitchKey` is false. | Don't draw our own globe key unless the property is true. | Apple docs |
| P-10 | Keyboards must support width changes while on screen (compact ↔ regular); iPad floating keyboard exists. | Layout engine is a pure function of size/traits. | Apple docs |
| P-11 | `UILexicon` (`requestSupplementaryLexicon`) provides contact names and user Text Replacements to keyboards. | Learning source (D-11). | Apple docs |
| P-12 | Base iPhone 12 is supported by iOS 27. iOS 27 dropped iPhone 11. | Reference device (D-05). | Apple Support compatibility list |
| P-13 | **iPhone Duo** (released 2026-10-23, iOS 27.1): outer display ~466×678 pt portrait (84 pt trailing vertical-bar safe area for apps), inner 669×951 pt portrait / 951×669 landscape, fold at the centre (475.5 pt). Apps get `UIHingeInteraction` / `reservedRegions(kind:.division)`. | Duo layouts (M11). | Apple HIG + "Preparing your app for iPhone Duo"; sizes from community skill → verify in `M0-10` |
| P-14 | **Keyboard extensions currently receive no hinge state or reserved regions** on iPhone Duo (simulator, Xcode 27.1 RC). Feedback FB25187339 filed by KeyboardKit. | Duo split is rule-based (D-20); re-test on device and each iOS release. | keyboardkit.com blog 2026-10-14; KeyboardKit issue #1095 |
| P-15 | Keyboard extensions can't draw outside their view bounds. | (Also why balloons look clipped on the top row.) All transient UI — alternates, selection preview, chips — lives inside the keyboard's own area. | Long-standing behavior; recheck in `M0-09` |
| P-16 | SQLite/file locks held in a shared App Group container when a process is suspended can get it terminated (`0xdead10cc`). | Short transactions; no locks across suspension; single writer. | Apple TN on 0xdead10cc; design rule |
| P-17 | Xcode ships exportable agent skills (`xcrun agent skills export`); Xcode 27.1 renames UIKit modernization to **App Resizability** with SwiftUI + iPhone Duo support. | Skills setup (§11). | Verified 2026-10-26 with Xcode 27.1 (27A9275): `uikit-app-modernization` gone, `app-resizability` present |
| P-19 | The **iOS 27.1 simulator runtime (24A94425) supports only the iPhone Duo**; iPhone 12 simulators use the iOS 27.0 runtime (matches the owner's device). | Create `iPhone Duo` on iOS 27.1 and `iPhone 12` on iOS 27.0. | `simctl list runtimes -j`, 2026-10-26 |
| P-20 | On the owner's Mac, `~/Library/Developer/CoreSimulator/Devices` is a symlink to `/Volumes/SSD/Library/Developer/CoreSimulator/Devices`. CoreSimulatorService currently gets EPERM (macOS privacy, external volume) writing there, so `simctl create` fails with "device remained in Creating state". | **Resolved 2026-10-26:** owner granted access; simulator creation works. If it recurs on another machine, grant Full Disk Access to CoreSimulatorService. | CoreSimulator.log, 2026-10-26 |
| P-21 | **Keyboard extension memory ceiling on iPhone 12 / iOS 27.0 is ~76–80 MB** (`phys_footprint`); empty keyboard ≈ 5 MB; no memory warning arrived before the kill. Single run, device only. | §6 caps (30 target / 40 hard) stay; enforce them ourselves; retest on other devices. | `docs/spikes/M0-03.md`, 2026-10-26 |
| P-22 | On iOS 27.0 (simulator) the keyboard extension sits on a system glass backdrop that blurs/tints the host by default; `UIInputView(.keyboard)`, a clear view and no background are identical. A full-sheet `UIVisualEffectView(systemChromeMaterial)` is near-opaque; a full-sheet `UIGlassEffect` shows a second visible layer. | No custom backdrop effect for Native/Native Glass (M1-03, M8-01); vary key tiles only. Retires most of R-02. Recheck on device. | `docs/spikes/M0-04.md`, 2026-10-26 |
| P-23 | **Full Access matrix (iPhone 12, iOS 27.0):** OFF → extension can read App Group `UserDefaults` written by the app, `playInputClick` works (if Keyboard Feedback > Sound is on), `UILexicon` works; but extension writes to shared defaults do not reach the app, App Group file writes fail, network fails, pasteboard `string` is nil, haptics are not felt. ON → all work. The simulator enforces none of this. | App→keyboard settings can use App Group defaults without Full Access (R-03 largely retired); learning/personal model must live in extension-local storage without Full Access; haptics, network-free features that need shared writes, clipboard and sync require Full Access. | `docs/spikes/device-session-2026-10-26.md`, 2026-10-26 |
| P-24 | **Text proxy (device):** `adjustTextPosition` offsets are UTF-16 units (can split emoji/ZWJ sequences); `documentContextBeforeInput` is capped at 500 chars and spans paragraphs; `selectedText` works in Notes; WhatsApp search field's cursor did not visibly move on `adjustTextPosition`; no marked-text accessor. | Cursor movement must step by grapheme boundaries computed by us (R-10), assume ≤500 chars of left context, keep per-host fallbacks. | same doc |
| P-25 | **Pasteboard / lexicon (device):** first cross-app `UIPasteboard.string` read with Full Access shows the system paste prompt, blocks ~3 s, and the keyboard was dismissed; later reads ~23 ms. `hasStrings` false and `detectPatterns` fails without Full Access. `requestSupplementaryLexicon`/`detectPatterns` callbacks arrive off-main (Swift 6: use `@Sendable`). | Clipboard features (F9, M6-05) must read lazily on user action, never block the main thread, and degrade gracefully. | same doc |
| P-26 | Foundation Models `SystemLanguageModel.default.availability` on iPhone 12 / iOS 27.0 = `unavailable(.deviceNotEligible)`. | No on-device AI features on the reference device; any AI must be an optional, availability-gated extra on newer hardware. | `docs/spikes/M0-07.md`, 2026-10-26 |
| P-28 | **Suspected, NOT confirmed:** on the owner's iPhone 12 / iOS 27 a scroll gesture (vertical list, horizontal chip bar and results row) only began when the touch started on drawn content (an emoji or icon), never on fully transparent areas. A near-zero-alpha background (`EmojiPanelView.touchSurface`) on those surfaces was added; a Debug log then showed the pan gestures starting, but the owner has not yet confirmed the fix. | Keep emoji panel surfaces non-transparent; recheck on the device. | owner reports 2026-10-27 |
| P-29 | `UITextDocumentProxy.documentIdentifier` is imported as a non-optional `UUID` but some hosts return nil (App Library search): the Swift bridge traps (EXC_BREAKPOINT in `UUID._unconditionallyBridgeFromObjectiveC`), crashing the keyboard on open (most of ~20 crash logs 2026-10-27). Read it with KVC and `as? UUID`. A nil id means "field change not detectable", so `resync()` also drops stale state when the left context is nil (an empty field). | Never read `documentIdentifier` through the typed property. | device crash logs, 2026-10-27 |
| P-30 | The bundled emoji data is Emoji 18.0; iOS 27.0's emoji font lacks the newest glyphs and draws a "?" box. `EmojiCatalog.droppingUnrenderable()` drops entries the system font cannot draw. | Re-test after OS updates. | owner screenshot, 2026-10-27 |
| P-27 | **OTP via iOS 27 Message automation (iPhone 12):** iOS 27 saves automations as shortcuts (appear in All Shortcuts); a Message-trigger automation with Automation on and Confirm Before Run off runs a background App Intent with the message text and sender, no prompt, app not opened, also while locked; a 'Running <name>' banner appears. App Intents must be compiled into the target (run `xcodegen generate` after adding files) for the action to show up in Shortcuts. Email works too (Email trigger needs the Sender/Account filters to match the real sender, subject passed as the message). After a restart the first message is not handled until Shortcuts is opened once, then the queued run executes (2/2 restarts); a duplicate run was seen once. | Onboarding must describe this setup; investigate the restart behaviour before promising reliability (R-04). | owner's device, 2026-10-27 |
| P-18 | Xcode 27.1 is installed at `/Volumes/SSD/Applications/Xcode-27.1.0.app` (via Xcodes); Xcode 27.0 remains at `/Applications/Xcode.app`. | `xcode-select -p` points at 27.1 (verified 2026-10-26). Always check `xcodebuild -version` at session start. | Owner's machine, 2026-10-26 |

---

## 6. Target devices & performance budget

### Geometry (verify every number in the simulator; never hardcode — the layout engine reads the real bounds)

| Device / state | Screen (pt) | Notes |
|---|---|---|
| iPhone 12 / 12 Pro portrait | 390 × 844 | **Reference device**, 60 Hz |
| iPhone 12 landscape | 844 × 390 | Landscape-optimized layout (F13) |
| iPhone 12 mini | 375 × 812 | Smallest supported width |
| iPhone 17 Pro Max / 18 Pro Max | ~440 × 956 | Largest regular iPhone width |
| iPhone Duo outer, portrait | ~466 × 678 | Wider and shorter than any iPhone → lower default height ratio |
| iPhone Duo outer, landscape | ~678 × 466 | |
| iPhone Duo inner, portrait | 669 × 951 | Full width, capped key size (D-20). Simulator screenshot is 2007×2853 px (= 669×951 @3x, confirmed) |
| iPhone Duo inner, landscape | 951 × 669 | Split default, fold at x = 475.5; laptop snap at height 334.5 |

### Budgets on base iPhone 12, iOS 27 (release build)

| Metric | Budget | How measured |
|---|---|---|
| Touch-down → key highlight visible | ≤ 1 frame (16.7 ms) | `os_signpost` + Instruments |
| Touch-up → text inserted in host | p95 ≤ 20 ms | signposts |
| Keystroke → suggestions updated | p95 ≤ 25 ms, never blocks typing | signposts; engine benchmark |
| Swipe lift → top candidate | p95 ≤ 60 ms (10-letter word) | signposts; engine benchmark |
| Keyboard cold start → first interactive frame | ≤ 250 ms (suggestions may arrive ≤ 400 ms) | signposts |
| Keyboard warm show | ≤ 80 ms | signposts |
| Steady-state memory (letters view) | ≤ 30 MB target, ≤ 40 MB hard cap | Xcode memory gauge / `vmmap` |
| Emoji panel open | ≤ +10 MB over steady state, released on close | memgraph |
| Dropped keystrokes while typing 10 chars/s | 0 | UI test + manual |
| Base language assets on disk (EN + Hinglish) | ≤ 25 MB, mmap'd | build output |

Budgets are re-baselined only after `M0-03` measures the real memory ceiling (if the ceiling is lower than ~50 MB,
tighten the caps proportionally). All main-thread work in the touch path is allocation-free; disk I/O and decoding
never run on the main thread.

---

## 7. Architecture

### Targets & packages

```
iBoard.xcodeproj
├─ iBoard (app, SwiftUI)            onboarding, settings, theme studio, dictionary manager,
│                                    insights, OTP App Intents, iCloud sync (opt-in)
├─ iBoardKeyboard (keyboard ext.)   UIInputViewController + UIKit/CALayer key grid
├─ iBoardTests / iBoardUITests
Packages/
├─ IBoardCore      shared models, settings schema, App Group store, Darwin notifications, logging (no text!)
├─ IBoardLayout    pure layout engine: (size, traits, settings, layout def) → key frames + hit model
├─ IBoardEngine    lexicon/LM readers, tap decoder, swipe decoder, autocorrect, learning, phrase model
├─ IBoardOTP       OTP extraction + TTL store (used by app intents and keyboard)
├─ IBoardTheme     theme model (versioned JSON), presets incl. "Native", rendering tokens
└─ IBoardUI        key/strip rendering & touch state machine (UIKit), used only by the extension
Tools/
└─ LexiconBuilder  macOS CLI: corpora → compact binary lexicon + n-gram LM (+ license manifest)
```

Engine, layout, OTP and theme packages must build and test on **macOS** (`swift test`) so agents iterate without a
simulator. Only `IBoardUI` and the targets depend on UIKit.

### Runtime data flow (keyboard)

```
touches ──► TouchStateMachine (main) ──► KeyEvent / Gesture ──► InputController (main)
                 │ highlight, click, haptic                     │ textDocumentProxy edits
                 ▼                                              ▼
            KeyGrid (CALayers)                       EngineActor (background, serial)
                                                     ├ TapDecoder / SwipeDecoder
                                                     ├ Autocorrect policy
                                                     ├ LM = base (mmap) ⊕ personal (in-memory + journal)
                                                     └ Suggestions ──► SuggestionStrip (main, next frame)
```

- **Cancellation:** every keystroke supersedes pending suggestion work; stale results are dropped by sequence number.
- **Settings:** written by the app to App Group `UserDefaults`; the keyboard reads on appear and on a Darwin
  notification. If App Group reads are unavailable without Full Access (`M0-05`), essential settings get an
  in-keyboard settings sheet stored in the extension's own container.
- **Personal model storage:** extension-local store always works; with Full Access it lives in the App Group so the
  app can show/edit/sync it. Single writer (the keyboard) with short transactions (P-16); the app sends edit
  commands through a command queue file the keyboard applies.

### Language engine design

- **Base lexicon:** DAWG/LOUDS-style trie, memory-mapped, with quantized unigram log-probs; ~150k EN words,
  ~50k Hinglish words with variant clusters (`nahi/nhi/nahin`).
- **Base LM:** pruned, quantized Kneser-Ney 3-gram per language, memory-mapped (≤ 8 MB EN, ≤ 4 MB Hinglish).
- **Personal model:** unigram/bigram/trigram counts with exponential decay (half-life ~60 days), phrase table for
  repeated 3–6 word sequences, forget list, never-correct list. Interpolated with the base LM.
- **Tap decoding:** per-key 2-D Gaussian spatial model (personalized by F14) × LM prior, beam search over the
  touch sequence; produces literal + top candidates + autocorrect confidence.
- **Swipe decoding:** SHARK²-style template matching (shape + location channels) over trie-pruned candidates whose
  start/end keys match, scored with the LM; templates generated from the *current* layout geometry so split and
  Duo layouts work unchanged.
- **Code-switching (Hinglish):** both lexicons are searched; a lightweight language-context score from the previous
  tokens and the personal model weights EN vs Hinglish; never auto-correct a valid Hinglish word into English.

---

## 8. Feature specifications

Each feature lists behavior and **acceptance criteria (AC)**. Milestones in §9 reference these IDs.

### F1 — Core keyboard (native-first)
- QWERTY letters, shift (tap = one capital, double-tap = caps lock, shown like iOS), 123 and #+= layers, return key
  label/colour from `returnKeyType`, `enablesReturnKeyAutomatically`, globe only when `needsInputModeSwitchKey`.
- Trait-specific layouts: email (`@`, `.`), URL (`/`, `.com` long-press for TLDs), number/decimal pads (custom numeric
  layout), ASCII-capable, `keyboardAppearance` dark/light.
- **No preview balloons (D-08).** Pressed key cap darkens/lightens like iOS.
- **Long-press alternates:** after 350 ms, the suggestion strip turns into the alternates row (e.g. `e é è ê ë ē ė ę`)
  with the default alternate highlighted; sliding the finger left/right moves the highlight; release commits;
  sliding back onto the original key cancels. Same mechanism shows `.com/.in/.org` on the URL key.
- Delete: tap deletes one grapheme; hold repeats with iOS-like acceleration (chars → words after ~2 s).
- Number row toggle (off by default to match iOS; on by default on Duo inner portrait).
- Sound: system click via `UIDevice.playInputClick()` (respects system setting). Haptics if Full Access.
- **AC:** side-by-side screenshots against the system keyboard at iPhone 12 / mini / Pro Max sizes match key frames
  within ±1 pt and colours within ΔE < 3 (light and dark); all trait variants covered by layout snapshot tests.

### F2 — Suggestions & autocorrect
- Three-slot strip like iOS: literal word (in quotes when it differs), best candidate centre, alternative. Phrase
  chip may widen one slot (D-13).
- Conservative autocorrect (D-12); respects `autocorrectionType = .no` (suggestions only) and `spellCheckingType`.
- Backspace immediately after an autocorrect restores the original; two restores of the same word → never-correct.
- Auto-capitalization per `autocapitalizationType` and sentence boundaries; double-space period (setting, on);
  smart quotes/dashes per `smartQuotesType`/`smartDashesType`; apostrophe contractions (`dont` → `don't`) as
  suggestions, auto only with high confidence.
- **AC:** offline eval set (§10) — top-1 correction precision ≥ 97 % and false-correction rate ≤ 0.5 % of words at the
  default setting; latency budget §6.

### F3 — Swipe typing
- Start on a letter key, travel across keys; trail drawn (theme colour) and fades on lift.
- Auto-space before a swiped word; space after a swipe is implied; backspace right after a swipe deletes the
  whole word; the strip shows the top alternatives for re-pick (re-pick replaces the word).
- Works across the Duo split gap (gesture continues through the gap).
- **AC:** top-1 accuracy ≥ 90 %, top-3 ≥ 97 % on the swipe eval set; ≥ 95 % top-1 for words in the personal model.

### F4 — Learning & personal dictionary
- Adaptive policy (D-10). A word is "kept" if committed and not corrected away or restored via backspace.
- Never learn when: incognito on; `textContentType` ∈ {URL, emailAddress, username, password, newPassword,
  oneTimeCode, creditCardNumber, …}; `keyboardType` ∈ {URL, emailAddress, number/decimal/phone pads}; the word
  looks like a code, number, or URL.
- Long-press a suggestion → "Forget ‘xyz’" in the strip. Forgotten words go on a forget list (not relearned for 30 days
  unless typed deliberately 3×).
- Imports: `UILexicon` contacts + Text Replacements (refreshed on each keyboard appearance, cheap diff).
- Import/export a versioned `.iboarddict` file from the app (JSON lines; words, phrases, counts, flags).
- **AC:** a new word typed once appears as a suggestion on the next prefix; forgetting removes it immediately; nothing
  is learned in any excluded field (unit + UI tests).

### F5 — Gestures & editing
Conflict-resolution rules (all thresholds tunable, covered by tests):

| Touch starts on | Gesture | Rule |
|---|---|---|
| Letter key | Tap | Movement < 10 pt and duration < long-press threshold |
| Letter key | Flick up / down | Mostly vertical (`|dy| > 1.5·|dx|`), released within ~1 key height and < 220 ms; if released on another key that forms a likely word, prefer swipe typing |
| Letter key | Swipe typing | Crosses ≥ 1 other key |
| Letter key | Long press | ≥ 350 ms with < 10 pt movement → alternates in strip |
| Spacebar | Cursor move | Horizontal drag > 12 pt; speed-scaled steps; vertical drag jumps lines (hard line breaks only) |
| Spacebar with Shift armed | **Selection** | As cursor move, but extends a virtual selection from the anchor; Shift is consumed (next letter not capitalized) |
| Backspace | Word delete | Drag left > 20 pt → words selected for deletion previewed in strip; release deletes; drag back right / onto keys cancels |

- **Selection (D-14/D-27):** anchor = cursor position at gesture start; the keyboard tracks the extent; the strip shows
  `“…selected text…” · 42 chars` and, on lift, the action row `[Cut] [Copy] [Delete] [Aa] [✕]`. Cut/Copy need Full
  Access (pasteboard). `Aa` cycles lower/Title/UPPER by delete + reinsert. If the host already has a real selection
  (`selectedText`), the action row operates on it. Selection length is limited to the context the host exposes.
- Key flicks: secondary glyphs drawn faintly on keys (setting: show/hide), e.g. `q↑1`, `a↑@`; down-flick = default
  accent/alternate.
- **AC:** gesture matrix unit tests on recorded touch traces; no false selection or flick during 500 recorded swipe
  words; cursor lands on the right grapheme with emoji and combining marks (UTF-16 vs grapheme verified in `M0-08`).

### F6 — OTP & codes
- **Capture:** App Intent `CaptureVerificationCode(text: String, sender: String?)` running in the background
  (`supportedModes = .background`, no app launch). Called by two bundled shortcuts: "iBoard SMS Codes" (Message trigger,
  *Message contains* list: `code`, `OTP`, `verification`, `कोड`, …) and "iBoard Email Codes" (Email trigger).
- **Parse:** keyword-proximity + pattern rules (4–8 digits or short alphanumerics like `G-123456`), exclusions for
  amounts (`Rs`, `INR`, `₹`, `$`), masked accounts (`XX1234`), dates, times, phone numbers, reference/transaction IDs.
  Test corpus includes Indian bank/UPI/e-commerce formats and Hindi/Hinglish messages.
- **Store:** only the code, a sender label, and a timestamp go to the App Group (never the message body). TTL 10 min
  (setting), last 3 codes; cleared after insert (setting, on).
- **Show:** code chip in the strip whenever a fresh code exists; prominent (first slot, highlighted) when
  `textContentType == .oneTimeCode` or the field looks numeric; one tap inserts.
- **Clipboard fallback:** with Full Access, when the pasteboard changes and contains a code-like string near OTP
  keywords, offer it as a chip (exact pasteboard prompt behavior → `M0-09`).
- **Onboarding:** app screen installs both shortcuts (signed `.shortcut` files, `shortcuts sign`), walks the user
  through turning *Automation* on and *Confirm Before Run* off, and sends a test code to itself to confirm.
- **AC:** ≥ 99 % correct extraction / 0 false positives on the corpus; code available in the keyboard ≤ 3 s after
  the SMS arrives (device test); body text never persisted (code review + test).

### F7 — Personal-info chips
- User saves name, emails, phones, addresses in the app (App Group, Full Access to read in keyboard).
- Chips appear when `textContentType` is `emailAddress`, `telephoneNumber`, `fullStreetAddress`, `postalCode`,
  `name`/`givenName`/`familyName`, etc. Never shown in other fields.
- **AC:** correct chip per content type; none in untyped fields.

### F8 — Emoji
- Panel with categories, recents, skin-tone memory, kaomoji tab; keyword search (CLDR annotations, EN + Hinglish
  keywords); emoji prediction in the strip after matching words (`pizza` → 🍕).
- Memory-safe: lazily rendered cells, cache dropped on close and on memory warning.
- **AC:** memory budget §6; search results < 30 ms.

### F9 — Clipboard manager (Full Access)
- Records text clipboard items while the keyboard is visible (by `changeCount`), max 20, TTL 1 h (setting), pin to
  keep. Code-like items expire with the OTP TTL. Clear-all. Never syncs.
- **AC:** items appear within one keyboard appearance of being copied; expired items are deleted from disk.

### F10 — Theming
- Theme model v1 (JSON): backdrop (system keyboard material | blur over photo | gradient | solid), dim, translucency,
  key fill/opacity/radius/border/shadow, fonts (SF Pro default), label colours, swipe trail, strip style, separate
  light/dark variants. Export/import `.iboardtheme`.
- Presets: **Native** (default, D-07), Native Glass, Midnight, Paper, high-contrast. Photo backgrounds are
  downsampled in the app to the exact keyboard pixel size per orientation before saving (no large images in the
  extension).
- Honors Reduce Transparency (opaque fallback), Increase Contrast, Bold Text.
- One backdrop blur for the whole keyboard — never per-key effect views (GPU/memory on A14).
- **AC:** theme switch applies on next keyboard appearance without relaunch; memory budget §6 with a photo theme.

### F11 — Resize
- Drag handle (in the strip's overflow/handle affordance) for live resizing; slider in the app; bounds: min 80 %,
  max 140 % of the native height (Duo laptop snap may exceed max); per orientation × display class (D-18).
- Keys, fonts and hit targets scale; the touch model normalizes coordinates so learning survives resizing.
- **AC:** height persists across launches; no layout jump on show.

### F12 — Haptics & sounds
- Haptic intensity (off/light/medium) and pattern; sound packs (system, soft, mechanical, typewriter) via preloaded
  short PCM buffers. Defaults mirror iOS (system click, haptics per system Keyboard Feedback setting if detectable).
- **AC:** no added latency to touch-down (measured).

### F13 — Landscape-optimized iPhone layouts
- Wider keys with side columns (punctuation, arrows, undo) and an optional split; strip compacts.
- **AC:** snapshot tests at iPhone 12 / mini / Pro Max landscape.

### F14 — Adaptive touch model
- For committed words decoded with high confidence (no correction, no restore), record each touch offset from its
  key centre in normalized key coordinates; update per-key mean/covariance with an exponential moving average;
  clamp shift to ±30 % of key size; separate models per orientation × display class; reset in settings.
- **AC:** on recorded sloppy-typing traces, raw key-error rate drops ≥ 15 % after adaptation without increasing
  errors for neutral typists.

### F15 — Incognito & per-field rules
- Toggle in the strip overflow; visible indicator while on; auto-incognito in the excluded fields of F4.
- **AC:** zero learning events while incognito (tests).

### F16 — Typing insights
- On-device aggregate counters only (no text): words typed, WPM sessions, autocorrect accept/revert rates, swipe
  share, words learned, top learned words (shown only in the app). Reset button.
- **AC:** counters survive restart; no raw text stored.

### F17 — Companion app
- Onboarding: add keyboard in Settings, Full Access explanation (what works without it), OTP shortcut setup, typing
  test field. Settings for every feature; theme studio; dictionary manager (search, edit, forget, import/export);
  personal info; insights; privacy page; about + open-source licenses + data attributions.
- Built with SwiftUI and size classes so it adapts to iPhone Duo (outer compact, inner regular) without per-device code.

### F18 — iPhone Duo
- Outer display: standard layout tuned for the wider, shorter screen (default height ratio lower; keys capped).
- Inner portrait: full width, capped key width, number row on.
- Inner landscape: **split** halves with a centre gap ≥ the fold band (default 27 pt, tune on device), suggestion
  strip split around the fold too; pinch toggles split/full per orientation (remembered).
- Laptop pose: resize "fill to fold" snap = half the inner landscape height; in that mode: no split, number row +
  arrow/edit column, bigger keys.
- If Apple exposes hinge/reserved regions to extensions (P-14), switch from rules to live fold data.
- **AC:** no key or strip control within the fold band in any inner-landscape state; verified in Device Hub poses.

### F19 — Accessibility
- VoiceOver: every key and chip labelled; direct-touch typing mode; strip readable. Larger key labels with Bold Text;
  Reduce Motion disables trail/animations; Dynamic Type in the app.
- **AC:** VoiceOver can type a sentence and pick a suggestion; app passes an accessibility audit.

---

## 9. Milestones & tasks

Task format: `- [ ] ID — title` · `Depends:` · `Done when:` (acceptance). Keep results to one line when checking off.

### M0 — Foundations & spikes
- [x] **M0-01 👤 Install Xcode 27.1 and the iPhone Duo simulator** — Owner installs Xcode 27.1 (Xcodes.app or App Store)
  and selects it (`sudo xcode-select -s`). Then an agent: installs/updates the iOS 27.1 simulator runtime
  (`xcodebuild -downloadPlatform iOS`), creates `iPhone 12` and `iPhone Duo` simulators (`xcrun simctl create`),
  re-runs `scripts/bootstrap-agent-skills.sh` (now exports `app-resizability`), then compares `app-resizability` with
  the vendored `iphone-duo-*` skills and removes the community ones it fully supersedes (log the decision).
  Done when: `xcodebuild -version` shows 27.1+, both simulators boot, skills refreshed.
  **Result (2026-10-26):** Xcode 27.1 selected; simulators `iPhone 12` (iOS 27.0) and `iPhone Duo` (iOS 27.1) boot and build the app;
  `app-resizability` exported; all six `iphone-duo-*` skills kept (§11).
- [x] **M0-02 Project structure** — Add keyboard extension target `iBoardKeyboard`, App Group, iCloud container
  entitlement placeholder, `Config/Base.xcconfig` + gitignored `Config/Local.xcconfig` (team ID, bundle prefix;
  move `DEVELOPMENT_TEAM` out of the pbxproj), local Swift packages from §7 with empty modules and one test each,
  Swift 6 mode for packages (D-25), shared schemes in `xcshareddata` (the auto-generated scheme lives in
  gitignored `xcuserdata`). Depends: M0-01. Done when: app + extension build, keyboard can be enabled in the
  simulator and types "a".
  **Result (2026-10-26):** `project.yml` (D-28) + Config xcconfigs, `iBoardKeyboard` stub, 6 Swift 6 packages; owner confirmed typing "a" in Safari's search field on the iPhone 12 sim.
- [x] **M0-03 👤 Spike: memory ceiling** — Debug build that allocates in steps inside the extension and logs the
  footprint at termination; run on the owner's iPhone 12 (if available) and in the simulator. Record the limit in
  §5 and re-baseline §6. Depends: M0-02. Unblocks: M2, M4, M8, M9.
  **Result (2026-10-26):** iPhone 12 / iOS 27.0 jetsam limit is 76–80 MB footprint (P-21); budgets in §6 unchanged. `docs/spikes/M0-03.md`.
- [x] **M0-04 Spike: translucency** — Try `UIInputView(.keyboard)`, `UIVisualEffectView`, Liquid Glass
  (`glassEffect`/`UIGlassEffect`) and a clear background in the extension on iOS 27: does the host show through?
  Screenshot each in light/dark over a colourful host. Record what "Native" and "Native Glass" can be. Unblocks: M1-03, M8.
  **Result (2026-10-26, simulator iOS 27.0):** the system provides a blurred/tinted glass backdrop behind the extension by default (P-22); a full-sheet `UIVisualEffectView` or `UIGlassEffect` is worse (opaque / double layer). Native = default backdrop + system-like key tiles; Native Glass varies key fill/tint only. Not tested: system dark keyboard, per-key glass, cost, device. `docs/spikes/M0-04.md`.
- [x] **M0-05 Spike: Full Access matrix** — With Full Access off/on: App Group `UserDefaults` read/write, file
  read/write, Darwin notifications, haptics, `playInputClick`, pasteboard read/write, network. Record as a table in §5.
  Unblocks: M1, M3, M6, M9.
  **Result (2026-10-26):** device matrix recorded (P-23): without Full Access the keyboard can READ app-written App Group defaults and play clicks and read UILexicon, but cannot write shared defaults/files, use network, pasteboard or haptics. Not tested: Darwin cross-process delivery, network with Full Access. `docs/spikes/device-session-2026-10-26.md`, `M0-05.md`.
- [x] **M0-06 Spike: OTP pipeline** — Minimal App Intent + iOS 27 Message automation built by hand, then as a signed
  `.shortcut` file; confirm background run without opening the app, with locked phone, latency, and that the
  automation survives reboot; repeat with Email trigger. Record exact setup steps for onboarding. Unblocks: M6.
  **Result (2026-10-27):** device-verified on the owner's iPhone 12 (P-27): Message and Email automations both run the background App Intent headless with no confirmation prompt (a 'Running <name>' banner shows), also while locked; Email needs the automation's Sender/Account filters to match the actual sender. After a restart the first text is not handled until Shortcuts is opened once, then the queued run executes (seen on 2 restarts). Not done here: signed `.shortcut` file (M6-04), exact latency (only 'immediate' / same minute), whether Mail notifications are required (untested).
- [x] **M0-07 Spike: on-device AI** — Can the extension (or the app via an intent) call Foundation Models within the
  memory budget? Measure latency for proofreading 200 chars. Pass/fail recorded; drives D-16.
  **Result (2026-10-26): FAIL on the reference device** — iPhone 12 reports `deviceNotEligible` for Foundation Models (P-26); no latency measured. AI stays post-v1/optional (D-16 unchanged). `docs/spikes/M0-07.md`.
- [x] **M0-08 Spike: text proxy behavior** — Across Notes, Messages, Mail, Safari, WhatsApp, Instagram: context length
  before/after cursor, behavior at paragraph boundaries, `adjustTextPosition` units (UTF-16 vs grapheme) with emoji
  and Devanagari, `selectedText` updates, marked text support. Unblocks: M2, M5.
  **Result (2026-10-26):** P-24: `adjustTextPosition` is UTF-16 units (splits emoji), context before cursor capped at 500 chars and crosses paragraphs, `selectedText` works in Notes. Tested Notes/Messages/WhatsApp/Mail; Safari, Instagram, Devanagari-specific and marked text not tested — re-check in M5-02.
- [x] **M0-09 Spike: misc keyboard behaviors** — Rendering limits at the top edge (P-15), pasteboard prompt and
  `detectPatterns` in a keyboard with Full Access, haptic latency, `UILexicon` contents and refresh cost.
  **Result (2026-10-26):** P-25: P-15 holds; cross-app pasteboard read prompts (and disrupted the keyboard), `UILexicon` works without Full Access on device; haptic latency not measured. `docs/spikes/M0-09.md`, device session doc.
- [~] **M0-10 Spike: iPhone Duo keyboard** — In the Duo simulator (27.1 final): extension frame and traits on outer/inner,
  rotation and fold transitions, whether `UIHingeInteraction`/`reservedRegions` now reach the extension (P-14);
  capture system keyboard screenshots in each pose as layout reference. Depends: M0-01, M0-02. Unblocks: M11.
  **Partial (2026-10-26):** NOT TESTED — axe can't drive the Duo sim and simctl has no pose controls; only outer-display sizes confirmed (466×678 / 669×951 pt). Needs the owner in Simulator/Device Hub. See `docs/spikes/M0-10.md`.
  **Update (2026-10-27):** owner supplied 5 labelled Device Hub screenshots (inner tent/landscape/portrait, outer landscape/portrait): iBoard loads in all of them, fills the width, and has no fold awareness — keys cross the vertical fold in inner landscape (expected; split not wired). Frame sizes/traits and hinge-data arrival still NOT measured. `docs/spikes/M0-10.md`.
- [x] **M0-11 Language data & licensing** — Shortlist corpora/word lists for EN and Hinglish, emoji annotations (CLDR),
  keyboard eval data; record license, attribution and share-alike obligations in `docs/DATA_SOURCES.md`; prefer
  public-domain/CC BY/permissive; any CC BY-SA data needs 👤 sign-off (fine for open source, must be attributed and
  derived dictionaries released under the same terms). Unblocks: M2-01, M7.
  **Result (2026-10-26):** `docs/DATA_SOURCES.md` written (licenses checked against source pages; unverified items marked). Needs 👤 sign-off on CC BY-SA/NC items before M2-01/M7 — see R-06.
- [x] **M0-12 Build & test scripts** — `scripts/build.sh` (app + extension, simulator), `scripts/test.sh` (`swift test`
  for packages + `xcodebuild test`), documented in `CLAUDE.md`. Optional GitHub Actions workflow on push.
  **Result (2026-10-26):** `scripts/build.sh`, `scripts/test.sh [--no-ui]`, CI workflow; both run green locally (UI tests not run).
- [x] **M0-13 Performance harness** — `os_signpost` intervals for every §6 metric, a debug overlay toggle in the
  keyboard showing live latency/memory, and macOS benchmarks for engine functions with thresholds.
  **Result (2026-10-26):** `Perf` signposts + p50/p95 ring buffer (IBoardCore), `Benchmark` helper with threshold test (IBoardEngine, 10× slack until the real engine exists), DEBUG-only overlay in the keyboard, `docs/PERFORMANCE.md`. Only `touchUpToInsert` is instrumented so far; overlay/signposts not exercised at runtime.
- [x] **M0-14 Open-source scaffolding** — `README.md` (pitch, screenshots later, build steps, privacy), `CONTRIBUTING.md`
  (agent protocol summary, coding style, how to run bootstrap), `CODE_OF_CONDUCT.md`, `SECURITY.md`, `NOTICE`
  (vendored skills, data attributions), issue templates. Depends: none.
  **Result (2026-10-26):** README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, issue/PR templates, NOTICE; docs only.

### M1 — Keyboard shell & layout engine (F1, F11 base)
- [~] **M1-01 Native metrics capture** — Screenshot the system keyboard (all layers, light/dark, trait variants) on
  iPhone 12, 12 mini, Pro Max and Duo sizes; derive key frames/gaps/radii/colours into `IBoardLayout` tokens with the
  screenshots stored under `docs/reference/`. Depends: M0-02.
  **Partial (2026-10-26):** iPhone 12 portrait only: 33 screenshots (letters/123/#+=, light+dark, 11 trait variants) and `docs/reference/native-metrics.{md,json}` (keyboard 390×328 at y=516; letter tiles 32.33×43 pt, pitch 38.33; radius ≈8.5; light #FFFFFF on #E2E3E8, dark #575757 on #373737). Missing: caps-lock, landscape, 12 mini / Pro Max / Duo, fonts only estimated; capture on a real device/Simulator.app for the rest.
- [x] **M1-02 Layout engine** — Pure function producing key frames + hit regions for letters/123/#+= and trait
  variants; snapshot tests for every device size in §6 (no hardcoded device sizes). Depends: M1-01.
  **Result (2026-10-26):** pure `LayoutEngine` + `HitModel` in IBoardLayout (23 tests green; iPhone 12 frames within ±1 pt of M1-01 measurements; natural keyboard height 260 pt = strip 44 + rows). Estimated, not measured: landscape, caps lock, 375/428/440/Duo sizes, globe layout. `docs/LAYOUT_ENGINE.md`. M1-03 consumes `KeyboardLayout`/`hit`; centre-gap split seam left for M11.
- [x] **M1-03 Key grid renderer** — CALayer-based grid, highlight on touch-down, Native theme tokens, light/dark.
  Depends: M1-02, M0-04.
  **Result (2026-10-27):** `IBoardUI` CALayer key grid driven by `KeyboardLayout`, Native tokens from IBoardTheme, light/dark, no custom backdrop (P-22), no balloons; simulator-verified: render, highlight, typing, 20 fast taps without drops (single pointer only), layer switching. Perf on Mac simulator CPU: highlight p95 0.1 ms, insert p95 0.5 ms, 25.5 MB — NOT an iPhone 12 number. Pressed-state colours, fonts, return glyphs estimated.
- [x] **M1-04 Touch state machine v1** — Tap, multi-touch rollover (fast typing with overlapping touches), shift/caps,
  delete repeat/acceleration, layer switching. Depends: M1-03.
  **Result (2026-10-27):** UIKit-free `KeyboardInputMachine` (tap, rollover, shift/caps, delete repeat/acceleration, layer switching), 26 tests; delete-repeat timings estimated; real multi-finger overlap not tested (axe is single-pointer).
- [~] **M1-05 Input controller** — Insert/delete via proxy, trait handling (return key, auto-cap basic, email/URL/
  numeric layouts, globe rule P-09), `playInputClick`, haptics when allowed. Depends: M1-04.
  **Partial (2026-10-27):** simulator-verified: return label/dimming, auto-cap shift incl. after ``. `` (fixed a layer-switch bug); unit-tested: auto-cap rules, return mapping, grapheme/word deletes. Not tested: globe rule (P-09), email/URL/numeric layouts live, `playInputClick` sound, haptics, grapheme delete with real emoji in a host.
- [~] **M1-06 Suggestion strip shell + long-press alternates in strip (D-08)** — Strip view with 3 slots (static for
  now), alternates row mode with slide-to-select. Depends: M1-04.
  **Partial (2026-10-27):** 3-slot strip + alternates row built; simulator-verified long-press → alternates, release inserts, one slide-to-select (ê); cancel-by-sliding-back and URL suffix row unit-tested only; slots empty until F2 wiring.
- [~] **M1-07 Height resize foundation** — Height constraint, per orientation/display class storage, drag handle,
  number-row toggle. Depends: M1-03.
  **Partial (2026-10-27):** settings schema v2 (`numberRow`, `heightScales`, 80–140% clamp, migration test), live drag handle and number-row toggle, app sliders; handle edits are stored extension-locally (cannot write App Group without Full Access, P-23) and override app values, so the app sliders and the handle can disagree. Per-display-class storage only wired for phone. Fixed orientation bug (was width>height ⇒ always landscape): portrait is taller now — recheck the 260 pt figures.
- [~] **M1-08 Minimal companion app** — Enable-keyboard instructions, test text field, settings stub that the keyboard
  reads (per M0-05 results). Depends: M0-05.
  **Partial (2026-10-26):** App (enable-keyboard steps, test field, settings screens), versioned `IBoardSettings` + App Group `SettingsStore` in IBoardCore (12 tests green), keyboard reads the haptics flag; builds. Not run on a device/simulator yet — verify the keyboard actually sees an app-written setting.
- [ ] **M1-09 Perf gate** — Meet §6 touch and memory budgets on iPhone 12 with the static keyboard. Depends: M1-05, M0-13.

### M2 — Language engine v1, English (F2)
- [x] **M2-01 LexiconBuilder** — CLI building trie + quantized 3-gram LM + license manifest from M0-11 sources;
  deterministic output; size report. Depends: M0-11.
  **Result (2026-10-26):** `Tools/LexiconBuilder` (Swift 6 package, 7 tests green): deterministic `.iblex` trie + `.iblm` 3-gram + `licenses.json` + size report; format in `docs/LEXICON_FORMAT.md`. Not tested: CLI end to end, real-scale data/size, build time. Plain trie (no suffix sharing yet).
  **English data (2026-10-27):** real English lexicon + LM built by `Tools/EnglishData` into `Data/english/` (125,796 words, 8.3 MB; 300k bigrams + 240k trigrams, 7.9 MB; byte-identical rebuilds; SCOWL 2020 vocabulary + Leipzig news 2023/2024 counts (CC BY 4.0), attribution only, no share-alike; top-10k coverage 98.2%). Together with Hinglish ≈23.2 MB of the 25 MB asset budget. Bundled into the keyboard on `fix/owner-bugs` (2026-10-27, `<bundle>/english/`, fixture removed; swipe and suggestions verified on the simulator, footprint 25-31 MB Debug sim, recheck on device); casual-chat register under-weighted (news corpora). `docs/ENGLISH_DATA.md`.
- [x] **M2-02 Runtime readers** — mmap loaders, prefix lookup, LM scoring; macOS benchmarks. Depends: M2-01.
  **Result (2026-10-27):** mmap `Lexicon`/`NGramModel` readers cross-checked against LexiconBuilder (219 words, 16k n-gram probabilities identical); macOS release p95: exact lookup 140 ns, trigram 218 ns, top-8 completions 1.7 µs; fixtures synthetic. Not measured on iPhone 12.
- [x] **M2-03 Tap decoder** — Spatial Gaussian × LM beam search; literal + candidates + confidence. Depends: M2-02, M1-02.
  **Result (2026-10-27):** `TapDecoder` (Gaussian spatial × LM, beam 24): on synthetic seeded noise top-1 97.5–100% vs literal 44.7–88.7%, 0 false corrections; real typing data and iPhone 12 latency untested. `docs/ENGINE.md`.
- [~] **M2-04 EngineActor & strip wiring** — Background engine, cancellation by sequence number, strip updates.
  Depends: M2-03, M1-06.
  **Partial (2026-10-27):** engine side done: Swift 6 `EngineActor`, sequence-number cancellation (stale dropped, 40-request burst test), `Suggestions` (3 slots + reserved phrase slot + autocorrect proposal). Strip wiring in the keyboard is NOT done.
  **Update (2026-10-27):** wired into the keyboard: `TypingCoordinator` + `EngineHost` (bundled 219-word synthetic lexicon, off-main load), strip shows suggestions, autocorrect + backspace restore, SmartPunctuation and PersonalLearner events; simulator-verified (keystroke→suggestions p95 ≈2 ms on the Mac sim, 24–25 MB), nothing learned in an email field. Not done: personal model into suggestions, strip taps live, Full Access mode, device. `docs/KEYBOARD_WIRING.md`.
  **Update (2026-10-27):** EngineActor now has public `Suggestions`/`SuggestionSlot` initialisers, `setPersonal`/`refreshPersonal(from:)`, phrase chip, `applyTouchModel`, and transposition/deletion/insertion edits in the TapDecoder (189 engine tests); IBoardUI still uses its mirror types and `EngineHost` has not adopted `refreshPersonal`/`applyTouchModel` yet.
  **Update (2026-10-27):** EngineHost now uses the public engine API (mirror types removed, `refreshPersonal`, touch model, `previousWords`); queued app commands applied on appear and insight counters recorded (extension-local without Full Access).
- [x] **M2-05 Conservative autocorrect** — Policy, revert-on-backspace, never-correct list, literal slot, respects
  `autocorrectionType`. Depends: M2-04.
  **Result (2026-10-27):** engine-side conservative autocorrect policy (posterior ≥0.97, 0.995 for valid words; autocorrectionType/spellCheckingType respected; backspace restore; never-correct after 2 restores, in memory only) — 119 engine tests green; not wired into the keyboard.
- [x] **M2-06 Smart punctuation & capitalization** — Auto-cap, double-space period, smart quotes/dashes, contractions.
  Depends: M2-04.
  **Result (2026-10-27):** pure smart-punctuation/auto-cap functions (sentences/words/all-chars, double-space period, smart quotes/dashes, contractions with real-word collisions suggestion-only); tested with emoji/combining marks and 500-char context; not wired in.
- [~] **M2-07 Eval harness** — Typo/correction eval set + scorer in `swift test`; F2 acceptance numbers reported in the
  progress log. Depends: M2-05.
  **Partial (2026-10-27):** synthetic eval harness + scorer exist (3,500 items/level; precision 99.9–100%, false-correction 0%, recall ~70%), but the lexicon is the 219-word fixture and the generator shares the decoder's noise model, so the F2 targets (≥97% / ≤0.5%) are NOT shown to be met; needs a real eval set.

### M3 — Learning & personal model (F4, F14, F15)
- [x] **M3-01 Personal store** — Extension-local + App Group modes (per M0-05), journal + snapshot, decay, P-16-safe
  writes. Depends: M2-04.
  **Result (2026-10-27):** personal store (decay half-life 60 d, journal+snapshot, corruption recovery, forget/never-correct lists, phrases, caps, local vs App Group modes) — 25 tests; memory only estimated (<8 MB default caps), no timing, interpolation constants untuned. `docs/PERSONAL_MODEL.md`.
- [x] **M3-02 Learning events & policy** — Kept-word detection, excluded fields, incognito toggle/indicator (F15).
  Depends: M3-01.
  **Result (2026-10-27):** learning policy: 20 excluded content types × 12 keyboard types × incognito, kept-word detection, forget list (30 days, 3 deliberate retypes), word filter; 25 tests; the keyboard controller still has to call the events (contract in `PersonalLearner.swift`). Not run in the extension.
- [~] **M3-03 Phrase model + smart wide chip (D-13)** — Depends: M3-02.
  **Partial (2026-10-27):** engine side: `PhraseModel` (confidence ≥0.6, uses ≥2, wide-chip slot, tap = all words / long-press = next word); 11 tests; not wired into EngineActor; thresholds untuned.
- [~] **M3-04 Forget & never-correct UX** — Long-press suggestion → forget; lists persist. Depends: M3-02.
  Update 2026-10-27: long-press menu (Forget / Never correct) built; only menu policy unit-tested; feel needs device. See docs/agent-reports/keyboard.md.
- [~] **M3-05 UILexicon import** — Contacts + Text Replacements, cheap refresh. Depends: M3-01.
  Update 2026-10-27: engine side done (SystemLexicon, 6 tests); keyboard adapter for UILexicon + fingerprint persistence not wired. See docs/agent-reports/data.md.
- [~] **M3-06 Adaptive touch model (F14)** — Depends: M3-02.
  **Partial (2026-10-27):** engine side: `AdaptiveTouchModel` (EMA mean/cov per orientation×display class, ±30% clamp); synthetic sloppy-typist key error 9.0%→4.7%, neutral 0.33%→0.41%; hook is `adaptive.apply(to:&params,…)` + rebuild TapDecoder; not wired, no real traces.
- [~] **M3-07 Import/export `.iboarddict`** (app side). Depends: M3-01, M1-08.
  **Partial (2026-10-27):** core only: versioned `.iboarddict` JSON-lines encode/decode/validate/merge with corrupt-input tests; the app import/export screens are not built.
  **Update (2026-10-27):** app side added: queue/command encoding in IBoardCore (32 tests), `DictionaryTransferView` (fileImporter/fileExporter), `DictionaryStore` validation; design `docs/APP_COMMANDS.md`; on-screen behaviour NOT tested; the keyboard does not yet apply queued commands. (`project.yml` now links IBoardEngine into the app.)

### M4 — Swipe typing (F3)
- [~] **M4-01 Gesture capture & trail** — Resampling, trail layer, tap-vs-swipe disambiguation. Depends: M1-04.
  **Partial (2026-10-27):** capture, resampling (512-sample cap), tap-vs-swipe, fading trail layer; unit-tested and a trail seen on the iPhone 12 simulator; fade/Reduce Motion/multi-touch/device cost NOT tested.
- [x] **M4-02 Swipe decoder** — Template matching + LM + personal model; benchmarks. Depends: M2-02, M3-01.
  **Result (2026-10-27):** `SwipeDecoder` (SHARK2-style shape+location, trie-pruned, LM + personal re-score, layout-agnostic incl. Duo) — macOS release p95 0.04–0.41 ms (12k/60k-word lexicons; debug 3–8 ms); not measured on a device or with a 100k+ real lexicon. `docs/SWIPE.md`.
- [~] **M4-03 Swipe UX** — Auto-space, whole-word backspace, re-pick alternatives. Depends: M4-02.
  **Partial (2026-10-27):** `SwipeEngine` in IBoardUI + coordinator: auto-space, whole-word backspace, `.swipe` learning event, re-pick (17 tests); simulator: `All `, `Ask `, `out` + one-unit backspace. Re-pick tap and personal boost live NOT tested; first swipe before engine load inserts nothing.
- [~] **M4-04 Swipe eval set & tuning** — Recorded + synthetic traces; F3 numbers. Depends: M4-03.
  **Partial (2026-10-27):** synthetic eval only: top-1 97.0–98.4% / top-3 98.9–99.4% across profiles (generator shares the decoder's geometry, so this is a regression guard, not evidence F3's 90%/97% targets are met on real swipes). Needs recorded real traces.

### M5 — Gestures & editing (F5)
- [~] **M5-01 Gesture arbiter** — Implement the F5 conflict matrix with recorded-trace tests. Depends: M4-01.
  **Partial (2026-10-27):** pure `GestureArbiter` + `GestureThresholds` implementing the F5 matrix; 24 matrix tests and 500 synthetic swipe words with no false flick/selection; NOT wired into the keyboard (a vertical flick crossing a key still becomes a swipe) and no recorded traces yet. `docs/SWIPE_UX.md`.
  **Update (2026-10-27):** arbiter now runs before a swipe trail starts (vertical flicks no longer become swipes); the 'released on a likely word' override is not wired (`likelyWord` always false).
- [~] **M5-02 Spacebar cursor** — Speed-scaled movement, vertical line jumps, grapheme-correct offsets. Depends: M5-01, M0-08.
  **Partial (2026-10-27):** spacebar cursor: drag >12 pt, speed-scaled, grapheme→UTF-16 offsets (P-24), line jumps on hard breaks; fake-proxy tests (emoji, ZWJ, flags, skin tones, combining marks, Devanagari conjuncts) + simulator: a 36 pt drag moved the caret 4 chars with no space typed. Not tested: real hosts with emoji/Devanagari, vertical jumps, device.
- [~] **M5-03 Backspace swipe-delete** — Preview in strip, cancel. Depends: M5-01.
  **Partial (2026-10-27):** backspace swipe-delete: drag >20 pt previews words, release deletes, drag back cancels; simulator: a left drag deleted the preceding word. Caveat: backspace still deletes one character on touch-down, so a swipe-delete also removes that character; strip preview rendering not verified.
- [~] **M5-04 Key flicks** — Up/down, secondary glyph rendering setting. Depends: M5-01.
  **Partial (2026-10-27):** key flicks (up = digit/symbol, down = first alternate), simulator-verified `#` on S↑ and `à` on A↓; faint hint glyphs behind a keyboard-local flag (`iboard.local.flickHints`, off) because `IBoardSettings` has no field yet.
- [~] **M5-05 Shift + space selection** — Virtual selection, preview, action row, host-selection support. Depends: M5-02.
  **Partial (2026-10-27):** Shift+space virtual selection: simulator-verified (11-char selection, banner + Cut/Copy/Delete/Aa/✕, Cut/Copy dimmed without Full Access, Aa case cycling, Delete); Cut/Copy with Full Access, host selection and vertical line-jump live NOT tested; only a manually tapped shift arms it.

### M6 — OTP & smart chips (F6, F7)
- [x] **M6-01 IBoardOTP parser + corpus** — Depends: none (can start any time after M0-02).
  **Result (2026-10-26):** `OTPParser` + 149-message synthetic corpus, 100% / 0 FP (self-written corpus, optimistic; sample real SMS later). Gaps: yyyymmdd-like 8-digit OTPs, Devanagari digits, non-alternating alphanumerics.
- [x] **M6-02 App Intent + TTL store** — Background intent writing code/sender/timestamp. Depends: M6-01, M0-06.
  **Result (2026-10-27):** `OTPWriter`/`OTPReader` store (code, sender, time; last 3; TTL 10 min; App Group `iBoard.otp.` keys; keyboard read-only) with 11 tests, and `iBoard/Intents/CaptureVerificationCodeIntent.swift` (background); App Intents metadata is generated in the build. The same flow was device-verified in M0-06; this production intent itself was not re-run on the phone yet.
- [~] **M6-03 Keyboard code chip** — Freshness, oneTimeCode prominence, insert + clear. Depends: M6-02, M2-04.
  **Partial (2026-10-27):** code chip in the strip (slot 2; emphasised slot 0 for `one-time-code` fields), insert on tap, consumed ids kept in memory (cannot delete from the shared store); simulator-verified without Full Access using a seeded code. Not tested on the real device with the production intent; clipboard fallback not built.
- [~] **M6-04 Bundled shortcuts + onboarding flow** — Signed SMS and Email shortcuts, guided setup, self-test.
  Depends: M6-02, M1-08.
  **Partial (2026-10-27):** guided OTP setup (6 steps for Message or Email, wording from P-27) + self-test screen polling `OTPReader` (2 min, shows code on screen only); signed `.shortcut` carrying the automation trigger is NOT DETERMINED — `shortcuts sign` works on a hand-written trigger-less plist, but no real automation export could be inspected (Mac Shortcuts library is privacy-blocked); owner could export the working automation to settle it. On-screen behaviour NOT tested. `docs/ONBOARDING.md`.
- [~] **M6-05 Clipboard code fallback** — Depends: M6-03, M0-09.
  Update 2026-10-27: tap-only 'Paste code' chip built (no unprompted pasteboard reads); P-25 prompt behaviour needs device.
- [~] **M6-06 Personal-info chips (F7)** — Depends: M2-04, M1-08.
  **Partial (2026-10-27):** personal-info chips (reader/model in IBoardUI): `name` chip verified in Safari on the simulator; email/telephone/address only unit-tested (Safari did not appear to pass `emailAddress`); the app-side editor does not exist.

### M7 — Hinglish
- [~] **M7-01 Hinglish lexicon & LM** (variant clusters). Depends: M0-11, M2-01.
  **Partial (2026-10-27):** real data built: `Data/hinglish/lexicon.iblex` 4.0 MB (56,235 words, 18k variant clusters) + `lm.iblm` 3.0 MB (150k bigrams, 60k trigrams); sources Leipzig Hindi (CC BY), AI4Bharat Aksharantar (mixed; treated as CC BY-SA 4.0 because ~25k rows derive from Dakshina), authored CC0 lists; byte-identical rebuilds; `docs/HINGLISH.md`. Quality on real Hinglish text unmeasured; the keyboard does not bundle it yet.
  **Update (2026-10-27):** Hinglish lexicon + LM are bundled in the keyboard as a `SecondaryLanguage` (copyFiles phase to `<appex>/hinglish/`, mmap'd, background load); footprint on the simulator ≈24 MB before and after (30 MB target); `nahi kya` kept, `teh`→`the`; Hinglish swipe, long sessions, accuracy and device NOT tested.
- [~] **M7-02 Code-switch scoring in decoders** — Depends: M7-01, M2-03, M4-02.
  **Partial (2026-10-27):** `SecondaryLanguage` dual-lexicon scoring in TapDecoder/SwipeDecoder/EngineActor (previous-word language prior + personal bias; backward compatible); 227 engine tests; dual-lexicon latency measured on macOS release only with a synthetic English proxy. Not wired into the keyboard.
- [~] **M7-03 Autocorrect protection for Hinglish** — Depends: M7-02.
  **Partial (2026-10-27):** protection rule implemented and unit-tested (a valid Hinglish word is never auto-corrected into an English-only word; the English word stays as a suggestion).
- [~] **M7-04 Hinglish eval set** — Accuracy targets equal to F2/F3 on mixed text. Depends: M7-03.
  Update 2026-10-27: eval built; tap meets F2, swipe misses F3 (top-1 82.8-89.8%, top-3 92.7-98.4%); synthetic touches. See docs/agent-reports/data.md.

### M8 — Themes, feel & landscape (F10, F12, F13)
- [x] **M8-01 Theme model + presets (Native, Native Glass, …)** — Depends: M0-04, M1-03.
  **Result (2026-10-27):** versioned `Theme` model + presets (Native token-identical, Native Glass key-only per P-22, Midnight, Paper, High Contrast ≥7:1), export/import with validation, accessibility resolution (M8-05 logic) — 12 tests; IBoardUI still renders from `NativeThemeTokens`, `Theme` not wired into rendering. `docs/THEMES.md`.
- [~] **M8-02 Theme studio (app)** — Live preview, photo pipeline, export/import. Depends: M8-01, M1-08.
  **Partial (2026-10-27):** theme studio (preset picker, light/dark editing, export/import `.iboardtheme`, photo pipeline to exact pixel size, `ThemeStore` writes theme to the App Group); 18 theme tests; on-screen, PhotosPicker and the keyboard reading photo files without Full Access NOT tested; photo target heights assumed.
- [~] **M8-03 Haptics & sound packs** — Depends: M1-05.
  Update 2026-10-27: haptic packs built (hapticPack in IBoardSettings; app picker missing); sound packs impossible in an extension (P-23).
- [~] **M8-04 Landscape layouts (F13)** — Depends: M1-02.
- [~] **M8-05 Accessibility of themes** — Reduce Transparency/Contrast/Bold Text. Depends: M8-01.
  Update 2026-10-27: observers + skin tests already existed; not re-checked on device.

### M9 — Emoji & clipboard (F8, F9)
- [~] **M9-01 Emoji panel** (memory-safe). Depends: M0-03, M1-03.
  **Partial (2026-10-27):** `Packages/IBoardEmoji`: CLDR/Unicode data (0.43 MB generated), categories, recents, skin-tone memory, kaomoji, UIKit panel behind canImport; not linked into the keyboard; panel memory NOT measured. `docs/EMOJI_DATA.md`.
  **Update (2026-10-27):** emoji panel wired into the keyboard (long-press 123 opens it); +8.2 MB while open on the simulator (budget +10), but ~8 MB stayed resident after close (33.6 vs ~25 MB) — investigate allocator retention; memory-warning path untested.
- [~] **M9-02 Emoji search & prediction** — Depends: M9-01, M2-04.
  **Partial (2026-10-27):** `EmojiSearchIndex` + `predict(afterWord:)` over en/hi CLDR + ~200 Hinglish keywords: release p95 0.011 ms on macOS (index build 32 ms); 21 tests; not wired into the keyboard; index build cost on an iPhone 12 unmeasured.
  **Update (2026-10-27):** wired: typing `pizza` shows 🍕 in the strip and tap inserts; full-results view after Return NOT tested.
- [~] **M9-03 Clipboard manager** — Depends: M0-05, M1-06.
  Update 2026-10-27: history model/store + empty-field chip built; history panel and TTL setting not built; background pasteboard prompt risk needs device.

### M10 — Companion app (F16, F17)
- [~] **M10-01 Onboarding** — Depends: M6-04.
  **Partial (2026-10-27):** onboarding (enable keyboard, Full Access matrix from P-23, OTP setup link, typing test) as a first-launch full-screen cover; builds; on-screen NOT tested; `iBoardTests/OnboardingTests.swift` compiles but was not run.
- [~] **M10-02 Settings for all features** — Depends: features shipped so far.
  **Partial (2026-10-27):** `IBoardSettings` v3 (haptic intensity, flick hints, autocorrect level, double-space period, smart punctuation, swipe on/off, incognito default, spelling variant from locale, Duo split flags, emoji suggestions) + `SettingsView`; 35 core tests; on-screen NOT tested; the keyboard does not read the new fields yet.
  **Update (2026-10-27):** keyboard now honours settings v3 (flick hints, haptic strength gated on Full Access, autocorrect level 0.97/0.90/0.80/off, double-space period, smart punctuation, swipe on/off, incognito default); `emojiSuggestions` read but unused; several switches NOT tested on the simulator.
- [~] **M10-03 Dictionary manager** — Depends: M3-07.
  **Partial (2026-10-27):** dictionary manager screens (search/sort/add/forget/pin over the shared snapshot, queued edits labelled 'queued', empty state when Full Access is off); builds; on-screen NOT tested.
- [~] **M10-04 Typing insights (F16)** — Depends: M3-02.
  **Partial (2026-10-27):** `InsightCounters`/`InsightsStore` (aggregate only, tolerant decoding, reset) + `InsightsView`; no text stored (tested); keyboard does not record counters yet; on-screen NOT tested.
- [~] **M10-05 Privacy page, licenses & attributions** — Depends: M0-11.
  **Partial (2026-10-27):** privacy, licenses and data-attribution screens (static, no network) in `iBoard/AboutViews.swift`; on-screen NOT tested.

### M11 — iPhone Duo (F18)
- [~] **M11-01 Outer display tuning** — Depends: M0-10, M1-09.
  **Partial (2026-10-27):** outer-display layout tuning (height factor 0.88, key caps 40/46) — ESTIMATED, pure layout, no Duo measurement (M0-10 open).
- [~] **M11-02 Inner portrait wide layout** — Depends: M0-10.
  **Partial (2026-10-27):** inner-portrait wide layout (full width, key cap 56, number row on) — ESTIMATED.
- [~] **M11-03 Inner landscape split + split strip + pinch toggle** — Depends: M11-02, M4-03.
  **Partial (2026-10-27):** inner-landscape split (two halves, centre gap ≥27 pt fold band, hit regions continue across the gap, invariant test that nothing lies in the band); strip split and pinch toggle not wired in the keyboard — ESTIMATED. `LayoutSettings.centreGap` now live.
  **Update (2026-10-27):** keyboard now applies the Duo split: display class from screen metrics (shortest side ≥600 pt inner, ≥450 outer), pinch toggles split per orientation (stored locally), strip slots around the fold band, handle drag on the inner display snaps to fill-to-fold; on a real Duo simulator the outer display reports 466×678 and a 452 pt-wide extension view; interactions NOT tested (axe cannot drive the Duo sim).
- [~] **M11-04 Laptop "fill to fold" snap** — Depends: M11-03, M1-07.
  **Partial (2026-10-27):** laptop fill-to-fold layout (half inner landscape height, no split, number row, key cap 72); the arrow/edit column is reserved space only and the snap handle is not wired — ESTIMATED.
- [ ] **M11-05 Device Hub pose verification** — All poses × orientations; screenshots in `docs/reference/duo/`.
  Depends: M11-04.
- [~] **M11-06 Companion app Duo pass** — Run `app-resizability` skill; fix findings. Depends: M10-02.
  Update 2026-10-27: audit found no screen/orientation hacks; one scene fix; no split layout, not run on Duo sim. See docs/agent-reports/app.md.

### M12 — iCloud sync (opt-in)
- [~] **M12-01 CloudKit private DB schema** — Per-device grow-only counters merged by sum; forget/never-correct as
  last-writer-wins sets. Depends: M3-01.
  **Partial (2026-10-27):** pure merge model in new `Packages/IBoardSync` (per-device counters summed; forget as max-merged floor stamp, never-correct LWW+tombstones; commutative/associative/idempotent over 300 random histories; 8 tests) and `docs/SYNC.md` with a proposed CloudKit mapping; no CloudKit code yet; sync keys must be encrypted/hashed (typed words are sensitive).
- [~] **M12-02 Sync engine in app** (keyboard never touches the network for sync). Depends: M12-01.
  Update 2026-10-27: SyncEngine/CloudKitSyncStore/crypto + settings screen, 18 package tests; needs iCloud entitlement + container and real-device test; not wired to personal model. See docs/agent-reports/sync.md.
- [~] **M12-03 Settings & conflict tests** — Depends: M12-02.
  Update 2026-10-27: conflict/failure tests done against in-memory fake; real iCloud untested.

### M13 — Hardening & launch
- [~] **M13-01 Accessibility (F19)** — Depends: M5, M8.
  Update 2026-10-27: keys + strip now VoiceOver elements; Dynamic Type, Switch/Voice Control, rotor, emoji panel not done.
- [ ] **M13-02 Performance soak** — 30-min typing soak on iPhone 12, memgraph before/after, no growth. Depends: all features.
- [~] **M13-03 Privacy manifest & labels** — `PrivacyInfo.xcprivacy`, "Data Not Collected", required-reason APIs.
  **Partial (2026-10-27):** `PrivacyInfo.xcprivacy` for app + keyboard (no tracking/collection; UserDefaults reasons CA92.1, 1C8F.1) and `docs/PRIVACY.md`; reason codes from memory, not yet validated by App Store Connect; privacy labels still to do.
- [~] **M13-04 App Review audit** — 4.4.1 checklist with `app-store-review` skill. Depends: M13-03.
  Update 2026-10-27: audit done without the app-store-review skill (not installed); added ITSAppUsesNonExemptEncryption; owner items in docs/RELEASE_CHECKLIST.md.
- [ ] **M13-05 👤 TestFlight beta** — Depends: M13-04.
- [ ] **M13-06 👤 App Store submission & public repo launch** — Depends: M13-05.

---

## 10. Testing & quality

- **Unit tests (macOS, `swift test`)** for every package: layout snapshots (key frames as JSON per device size),
  decoders, autocorrect policy, learning rules, OTP parser corpus, theme decoding, gesture arbiter on recorded traces.
- **Eval sets** in `Tests/Eval/`: typo/correction pairs, swipe traces, Hinglish mixed sentences, OTP messages. Scores
  are printed by `scripts/test.sh` and recorded in the progress log when they change.
- **UI tests** in the app target with the keyboard enabled in the simulator: typing, suggestions, gestures.
- **Device checks 👤** on iPhone 12 for every perf gate (M1-09, M13-02) and OTP latency (M6).
- **Build/test:** `scripts/build.sh`, `scripts/test.sh [--no-ui]`. Raw build command:
  `xcodebuild -project iBoard.xcodeproj -scheme iBoard -destination 'generic/platform=iOS Simulator' build`
- Never log typed text, even in tests' console output; use lengths, counts and hashes.

---

## 11. Agent skills

Skills live in `.agents/skills/` (linked into `.claude/skills/`). Load the relevant skill before the matching work.

| Skill | Source / license | In repo? | Use for |
|---|---|---|---|
| `iphone-duo-readiness`, `-adaptive-layout`, `-design-review`, `-dual-pane-patterns`, `-hinge-and-scenes`, `-vertical-bars` | mirzaaghazadeh/iphone-duo-skills, MIT | ✅ vendored | M0-10, M11, companion app on Duo: hinge, reserved regions/fold, ArrangementView, poses, vertical bars, Duo App Store assets. Kept after M0-01 review — `app-resizability` covers none of these. **If they conflict with an Apple skill, Apple wins.** |
| `swift-concurrency` | avdlee/swift-concurrency-agent-skill, MIT | ✅ vendored | EngineActor, Swift 6 mode, Sendable issues |
| `swiftui-specialist`, `swiftui-whats-new-27` | Apple (Xcode), not redistributable | bootstrap | Companion app |
| `app-intents-specialist`, `app-intents-whats-new-27` | Apple (Xcode) | bootstrap | OTP intent (M6) — background `supportedModes` |
| `app-resizability` (Xcode 27.1+) | Apple (Xcode) | bootstrap | **Authoritative** for size-agnostic layout, removing `UIScreen.main`/orientation/idiom, asymmetric safe areas, Duo readiness |
| `device-interaction` | Apple (Xcode) | bootstrap | Simulator screenshots/taps for verification |
| `modernize-tests` | Apple (Xcode) | bootstrap | Swift Testing conventions |
| `debugging-instruments`, `ios-memgraph-analysis` | dpearson2699, PolyForm Perimeter | bootstrap | Perf/memory gates (M0-03, M1-09, M13-02) |
| `app-store-review`, `ios-accessibility` | dpearson2699, PolyForm Perimeter | bootstrap | M13 |

Rules: review any new skill's files before adding it (no scripts that hit the network or delete files); record its
license here; never vendor non-open-source skills.

---

## 12. Repository map

| Path | Purpose | Committed? |
|---|---|---|
| `ROADMAP.md` | This document | ✅ |
| `CLAUDE.md`, `AGENTS.md` (symlink) | Agent entry point → this file | ✅ |
| `LICENSE` | Apache-2.0 | ✅ |
| `NOTICE` | Attribution for vendored third-party material | ✅ |
| `README.md`, `CONTRIBUTING.md`, … | Open-source docs (M0-14) | ✅ (to add) |
| `.gitignore` | Ignores build output, user data, local config, non-redistributable skills | ✅ |
| `scripts/bootstrap-agent-skills.sh` | Restores Apple + PolyForm skills locally | ✅ |
| `skills-lock.json` | Skills CLI lock (sources + hashes) | ✅ |
| `.agents/skills/<MIT skills>` + `.claude/skills/<links>` | Vendored skills with their LICENSE | ✅ |
| `.agents/skills/<Apple/PolyForm skills>` | Restored by bootstrap | ❌ gitignored |
| `iBoard.xcodeproj/project.pbxproj`, `project.xcworkspace/contents.xcworkspacedata` | Project | ✅ |
| `iBoard.xcodeproj/xcuserdata/` | Per-user Xcode state | ❌ gitignored (untracked 2026-10-26) |
| `Config/Base.xcconfig` / `Config/Local.xcconfig` | Shared build settings / personal team ID | ✅ / ❌ (M0-02) |
| `iBoard/`, `iBoardTests/`, `iBoardUITests/` | App target and tests (template code today) | ✅ |
| `iBoardKeyboard/`, `Packages/`, `Tools/`, `docs/` | Created in M0-02 / M0-11 / M1-01 | ✅ |

---

## 13. Risks & open questions

| ID | Risk / question | Mitigation / owner |
|---|---|---|
| R-01 | Memory ceiling lower than budget → crashes on iPhone 12. **Measured ~76–80 MB (P-21); budget OK.** | M0-03 first; mmap everything; memory-warning handling; emoji panel isolation. |
| R-02 | Translucency can't show the host → "glass" looks fake. **Mostly retired (P-22): the system backdrop shows the host; verify on device.** | M0-04; design Native Glass around the system keyboard material if that's all we get. |
| R-03 | ~~App Group not readable without Full Access.~~ **Measured (P-23): reads work without Full Access; only keyboard→app writes need it.** | M0-05; in-keyboard essential settings fallback. |
| R-04 | Shortcuts automation UX changes or requires confirmation in a future iOS. | Keep clipboard fallback; onboarding detects stale codes; re-test each iOS release. |
| R-05 | WhatsApp/Telegram OTPs unreachable (no Shortcuts trigger). | Clipboard fallback; watch for APIs. |
| R-06 | Hinglish corpora licensing (often CC BY-SA or research-only). | M0-11; owner sign-off; community-contributed word lists. |
| R-07 | Duo fold invisible to extensions (P-14) → can't react to folding live. | Rule-based split (D-20); duplicate FB25187339; adopt API when available. |
| R-08 | Gesture conflicts (flick vs swipe) feel unpredictable. | Recorded-trace tests; tunable thresholds; flicks can be disabled. |
| R-09 | App Review rejects due to Full Access messaging or Shortcuts onboarding. | Follow 4.4.1 strictly; core works without Full Access; no app launching from keyboard. |
| R-11 | ~~Debug-build macOS timing tests failed intermittently under load.~~ **Fixed 2026-10-27:** budgets are enforced only in release (`Benchmark.assertBudget`), debug only prints; CI runs a release-budgets job. | Keep release thresholds unchanged. |
| R-10 | `adjustTextPosition` units differ by host. **Measured (P-24): UTF-16 units in Notes/Messages; WhatsApp unreliable.** | M0-08; grapheme-aware cursor logic with per-host fallbacks. |
| Q-01 | ~~Physical base iPhone 12?~~ **Answered 2026-10-26:** yes — "Shubham’s iPhone", iPhone13,2, iOS 27.0 (24A437), Developer Mode on, paired over Wi-Fi (UDID `00008101-0014596A1E01001E`). | Use for every 👤 perf gate; agents can deploy with `xcrun devicectl` when it's reachable. |
| Q-02 | ~~Public GitHub repo name/owner.~~ **Answered:** `shubhamsinghshubham777/iBoard`, public (D-30). **Commit email decided 2026-10-26:** keep `shubhamsinghshubham777@gmail.com` (owner wants it public). | 👤 repo name before M13-06. |

---

## 14. Backlog (post-v1)

On-device AI proofread/rewrite (if M0-07 passes) · iPad layouts incl. floating keyboard · alt Latin layouts (QWERTZ,
AZERTY, Dvorak, Colemak) · Devanagari output / transliteration · more languages via language packs · snippets / text
expander · one-handed mode · long-press spacebar trackpad · editing panel · GIF/sticker search (opt-in network) ·
translation · themes gallery/sharing · iOS widgets for insights.

---

## 15. Progress log

### 2026-10-27 — QUICKSET merged
Owner confirmed on the iPhone 12 with Full Access on: keyboard stable, typing, swipe and emoji panel work. Emoji long-press popup redesigned (SF Symbols, native-style plate); gear opens an in-keyboard Quick Settings panel (haptic pack, number row, autocorrect level, swipe, incognito, landscape side keys, link to iOS Settings) with extension-local overrides merged over app settings (written back to the App Group with Full Access); app toggle for landscape side keys; main-actor and `UIScreen.main` warnings cleaned. Build + `scripts/test.sh --no-ui` + privacy audit pass; Debug build installed on the phone; panel/popup look and text-replacement expansion unverified on device. Rule kept: the keyboard never opens the app (D-01).

### 2026-10-27 — CRASH fix + QA merged
CRASH: likely cause of the Full Access keyboard death fixed — `requestSupplementaryLexicon` callback now `@Sendable` (UIKit may call it off-main; same trap as the 2026-10-26 logs); NOT reproduced, no .ips for the failed run; migration/two-writer/corrupt-store tests added and pass. Needs the owner's phone retest. QA: full suite green; 7 new UI tests pass on iPhone 12 and iPhone Duo sims (onboarding, settings incl. sync screen, theme studio, dictionary); `scripts/test.sh` accepts any SIM_NAME; CI `ios-ui-tests` job added (not yet run on GitHub). Remaining warnings (KeyboardViewController main-actor isolation, `UIScreen.main` in EmojiPanelView) are listed in docs/agent-reports/qa.md.

### 2026-10-27 — DECOUPLE merged; D-29 confirmed on device
The keyboard extension no longer links CloudKit or any sync code (new app-only package `IBoardPersonalSync`; extension binary −777 KB, 0 IBoardSync symbols, `scripts/audit-privacy.sh` EXT-SYNC check). D-29 confirmed: the owner sees the Allow Full Access switch (off by default). OPEN BUG: with Full Access ON the keyboard died <0.5 s after launch on the iPhone 12 (no .ips yet; hypothesis: first local→App Group migration in EngineHost, marked NOT TESTED) — CRASH agent investigating.

### 2026-10-27 — M12-02 first device sync
iCloud/CloudKit entitlement added (`iCloud.app.iBoard`, owner created container); Debug build installed on the owner's iPhone 12; owner enabled sync and tapped Sync now: status 'Last synced 27 Oct 2026 at 3:00 PM' (screenshot), i.e. connect + encrypt + upload succeeded on device. Still unverified: content of the upload (may be near-empty), two-device merge, key sharing via iCloud Keychain, Delete iCloud data. M12-02/03 stay `[~]`.

### 2026-10-27 — KEYBOARD3 + DEVICE merged
M8-04 landscape side punctuation columns (`landscapeSideKeys`, default on; no app toggle yet), clipboard panel via emoji-key long-press, hint-symbol overlap fix, controller robustness fixes (pre-layout touch crash path, memory-warning drops). DEVICE: flag-gated `PerfMetricsHook` (DEBUG/-DIBOARD_PERF only), `scripts/device-perf.sh`, `docs/perf/README.md`; Release build installed on the iPhone 12 but the keyboard never appeared in the XCUITest so M1-09/M13-02 have NO numbers yet (keyboard binary 4.7 MB static). Finding: extension links CloudKit/IBoardSync via IBoardEngine→PersonalSyncAdapter (1132 sync symbols) — being decoupled. All `[~]`; device pass needed. Build + `scripts/test.sh --no-ui` + privacy audit pass.

### 2026-10-27 — APP3 merged (release material)
Original app icon (light/dark/tinted), file-timestamp reason C617.1 in the app privacy manifest, `docs/site/` (home/privacy/support, GitHub Pages ready), `docs/APP_STORE_LISTING.md`, About licences, CHANGELOG, version 1.0.0. Build + privacy audit pass; not validated by an App Store Connect upload. Owner needed: review-notes contact line, enable GitHub Pages, screenshots, confirm repo URL, iCloud container/entitlement. See docs/agent-reports/app3.md and docs/RELEASE_CHECKLIST.md.

### 2026-10-27 — DATA2 merged (swipe accuracy)
Hinglish swipe: top-1 now 95.5/94.4/89.5% and top-3 99.7/99.1/96.3% (careful/normal/sloppy) on synthetic traces, up from 89.8/88.1/82.8 and 98.4/96.9/92.7; held-out half 94.6/98.6. Cause: sharp Hinglish n-gram backoff vetoed correct swipes; fixed via `lmUnigramMix` 0.3 and `lmWeight` 0.5. English top-1 93.5→95.1%. Engine 254 tests pass. M4-04 still needs real traces (versioned `.jsonl` format + loader in `Fixtures/traces/`). F3 on real fingers unproven. See docs/agent-reports/data2.md.

### 2026-10-27 — parallel round 2 (APP2, SYNC2, KEYBOARD2 merged; DATA2 pending)
Merged; build + `scripts/test.sh --no-ui` pass. Settings v4 (haptic pack picker, clipboard history toggle + TTL), Full Access wording fixed, wide-width app layout (unseen on screen), D-29 Full Access requested; sync now exports/applies the real personal model (shards split, tombstones compacted); keyboard: UILexicon wiring + text-replacement expansion, clipboard history panel, Dynamic Type/VoiceOver actions. Keyboard now honours `clipboardHistory`/`clipboardTTL`. All `[~]`: device pass needed (see docs/agent-reports/{app2,sync2,keyboard2}.md). Open risks: sync opens a second PersonalStore writer from the app; IBoardSync now linked into the extension (measure footprint); clipboard panel only reachable via the chip.

### 2026-10-27 — parallel round (KEYBOARD, SYNC, DATA, APP agents merged)
Merged four worktree branches; `scripts/build.sh` and `scripts/test.sh --no-ui` pass on the merged tree. Tasks moved to `[~]`: M3-04, M3-05, M6-05, M7-04, M8-03, M8-05, M9-03, M11-06, M12-02, M12-03, M13-01, M13-04 (none verified on device; details in `docs/agent-reports/`). Added a privacy-audit allowlist entry for the sync app file. Follow-ups: iCloud entitlement/container (owner), hapticPack picker in the app, UILexicon keyboard wiring, swipe accuracy vs F3, real swipe traces (M4-04), device test of new keyboard UI.

Newest first. Format: `YYYY-MM-DD · task · summary · verification · follow-ups`.

- **2026-10-27 · owner round 4 (device feedback, branch work done on `main`) ·** Emoji and keyboard UX overhaul from the owner's iPhone testing, plus two crash fixes. **Emoji search:** new pill field with caret, results as a scrolling row between the field and the keys (keyboard grows 44 pt while searching), live results, best match first (shorter name wins ties), gesture typing and swipe-delete work in the field, Cancel and an emoji icon as exits, no crash on backspace in an empty field (relayout deferred; exclusivity). **Emoji panel:** 32 pt emoji in 7 columns, new category bar (ABC and kaomoji fixed, ten category chips scroll), inline non-pinned headings, 12 pt air under the search field, dropped glyphs the OS cannot draw. **Keys and strip:** neutral swipe trail from the theme label colour, Native keys translucent, strip content moved up (the system glass leaves ~13 pt above our view), taller dividers, icon return key (D-31), long-press time setting (Short 0.3 / Standard 0.45 / Long 0.6 s), hint symbols on keys plus long-press offering the hint first, long-press emoji key opens iOS Settings, chip taps ignored during a backspace swipe. **Crashes (device logs):** `documentIdentifier` nil trap (P-29, most of the ~20 crash logs from that day) and the relayout exclusivity crash. **Empty-strip robustness:** `resync()` now clears stale word state when the left context is nil (new regression test, verified to fail without the fix), engine load retries 3x, resync on appear. Verification: `scripts/test.sh --no-ui` green (Core 36, Emoji 27, Engine 231, Layout 44, OTP 11, Sync 8, Theme 18, UI 236, LexiconBuilder 7), audit-privacy OK, build OK, builds installed on the owner's iPhone 12 and checked by the owner in screenshots. NOT TESTED: long-press emoji key -> Settings (iOS 27 may block it), hint symbols and the 0.3/0.6 s presets on the device, memory with 32 pt emoji (recheck footprint after full-list scrolling, target 30 MB / cap 40 MB), the P-28 scroll fix confirmation, the exact cause of the occasional empty suggestion strip (not reproduced; fixes above address stale state). Declined by the owner: opening the app from the keyboard (D-01) and moving the app into Settings (not feasible: Settings pages cannot hold the theme studio or dictionary, values would not reach the keyboard, OTP needs the app, no public way to hide the icon).
- **2026-10-27 · UX polish round (branch `feat/ux-polish`) ·** Built UX proposals 1-4, 6, 7, 9 (partly), 10 (partly), 11, 12: strip polish (bold best word, fade, separators), press scale, caps lock bar/haptic/pulse, spacebar cursor hint, undo-autocorrect chip, comma/period keys with quick-punctuation long-press (new setting, default on, agent choice), distinct haptics, in-keyboard coach tips with Next/Skip. Not built (owner skipped 5 and 8; the rest with reasons in `docs/BUGFIX_NOTES.md`). Verification: `swift test` green in every package, audit-privacy OK, build OK, simulator checks for coach, undo chip, caps bar, cursor hint; haptics and the punctuation long-press row NOT tested.
- **2026-10-27 · owner bug fixes round 2 (branch `fix/owner-bugs-2`) ·** Emoji blank-on-scroll root cause = colour-emoji glyph cache growing the extension to 108 MB (Debug sim); fixed (28-35 MB after 40 fast full scrolls). Resize drag handle removed; size picker (6 presets) in the app. Emoji key next to 123 (system globe cannot be replaced, P-09); emoji panel kept resident; compact chrome (shorter strip, smaller key gaps, bigger keys); thick ribbon swipe trail; emoji panel visual polish. Two crashes found and fixed during simulator testing. Verification: `swift test` green in every package (Core 36, Emoji 26, Engine 231, Layout 42, OTP 11, Sync 8, Theme 18, UI 227, LexiconBuilder 7), audit-privacy OK, build OK; simulator-only, NOT re-tested on the phone. UX proposals in `docs/BUGFIX_NOTES.md`.
- **2026-10-27 · owner bug fixes (branch `fix/owner-bugs`) ·** English lexicon + LM bundled into the keyboard (`<bundle>/english/`, fixture removed); first swipe before the engine loads is buffered; next-word prediction now seeded by LM successors and English-first without Hinglish evidence; caps lock (double tap after auto-cap, held shift, tinted tile); emoji button in the strip + slide-from-123; spacebar right drag wraps at line end; resize handle shows a stable preview and applies once; thin gradient swipe trail; emoji panel is one continuous list with jump chips and remembered scroll; backspace swipe-delete previews live in the field (a host-drawn selection is impossible, P-08; marked text showed no highlight in the tested hosts). Verification: `swift test` green in every package (Core 35, Layout 40, Engine 231, OTP 11, Theme 18, UI 227, Sync 8, Emoji 26, LexiconBuilder 7), `scripts/audit-privacy.sh` OK, `scripts/build.sh` OK; behaviours seen on one iPhone 12 (iOS 27.0) simulator via axe (details and gaps in `docs/BUGFIX_NOTES.md`). Footprint (Debug, simulator) 25 MB after swipes, 31 MB after the emoji panel: re-measure on the device against the 30 MB target. NOT tested: anything on the physical phone, Duo, Reduce Motion, Notes/Messages/WhatsApp hosts. Statuses stay `[~]`.

- **2026-10-27 · English lexicon data merged ·** `Data/english/` (see M2-01 note). Verification: agent's hash check (rebuild twice, identical SHA-256) re-checked after merge; engine/UI tests and `scripts/build.sh` still green; NOTICE conflict (two appenders) resolved by keeping both. Next: bundle it into the keyboard (lazy mmap, watch the 30/40 MB footprint — now ~16 MB more mapped data), then the owner's bug-fix round.

- **2026-10-27 · round 7 merged (keyboard settings/Hinglish/Duo/theme skin, onboarding + OTP guide, quality pass) ·** Three worktree agents merged cleanly. Verification after merge: `swift test` green — Core 35, Layout 40, Engine 227, OTP 11, Theme 18, UI 206, Sync 8, Emoji 21, LexiconBuilder 7; `scripts/build.sh` green; new `scripts/audit-privacy.sh` passes after two reviewed allowlist entries for Duo split booleans. Quality pass also: release-only benchmark budgets (R-11 fixed), CI with 4 jobs (not run on GitHub yet), README/CONTRIBUTING/`docs/ARCHITECTURE.md`, accessibility review (`docs/ACCESSIBILITY_REVIEW.md`, code reading only). Still in flight: English-lexicon data agent (worktree `agent-a8fc6ff6bd3c02bb4`). Next: bundle the real English lexicon, then the owner's bug-fix round (docs/HANDOFF.md §2).

- **2026-10-27 · handoff note ·** Owner tested the round-6 build on the iPhone 12 and reported 8 issues (listed in `docs/HANDOFF.md` §2). Root cause of 'gesture typing types nothing': the bundled English lexicon is the 219-word synthetic fixture (14 KB); an agent is building a real English lexicon (`Data/english/`). Round 7 (KBD7 keyboard settings/Hinglish/Duo split/theme rendering, ONBOARD, QUALITY) and the English-data agent are in flight in worktrees; the bug-fix round starts after they merge. Added `docs/HANDOFF.md` for context continuity.

- **2026-10-27 · round 6 (chips/selection/emoji, Hinglish data + code-switch, settings + theme studio) ·** Three worktree agents merged cleanly. Verification after merge: `swift test` green — Core 35, Layout 40, Engine 227 (one run had a load-sensitive `ReaderBenchmarks` failure, passes alone — R-11), OTP 11, Theme 18, UI 185, Sync 8, Emoji 21, LexiconBuilder 7; `scripts/build.sh` green. Simulator evidence for code chip, name chip, Shift+space selection, emoji panel and search. Next for agents: bundle Hinglish into the keyboard + read the new settings fields, theme rendering in IBoardUI, emoji memory retention, M6-05 clipboard fallback, M6-04 onboarding + signed shortcut. Needs the owner/device: M1-09 perf gate, haptic/sound feel, Duo screenshots (M0-10).

- **2026-10-27 · M0-06 done ·** Owner-assisted device spike finished: Message + Email automations run the background intent (log read from the App Group via devicectl: code, sender and body length only). Findings: Email filters must match the real sender (my first three test mails came from the connector's account, not the one in the filter); restart delays the first run until Shortcuts is opened. Next for onboarding (M6-04): describe the setup screens (Library > Automation > + > Automation chip > Communication), banner, restart note. Test-mail caveat: the Gmail connector sends as shubham@ayrindigital.com.

- **2026-10-27 · round 5 (keyboard gestures, emoji, Duo layout) ·** The first attempt stopped on a usage limit (2:20 am reset) leaving uncommitted partial work; continuation agents finished inside the same worktrees. Verification after merge: `swift test` green — Core 32, Layout 40, Engine 189, OTP 11, Theme 12, UI 159, Sync 8, Emoji 21; `scripts/build.sh` green. A timing benchmark (`ReaderBenchmarks.prefixCompletions`) failed once under machine load and passed on rerun — treat the macOS benchmarks as load-sensitive. Simulator evidence: flicks, spacebar cursor, backspace swipe-delete. All Duo numbers are ESTIMATED (M0-10 open). Next for agents: wire emoji panel + search into the keyboard, `IBoardSettings` field for flick hints, Shift+space selection (M5-05), M7 Hinglish data, M8 theme rendering/studio, M6-03 code chip + M6-05/06; owner/device: M1-09 perf gate, OTP restart/Email checks, M0-10, haptics/sound feel.

- **2026-10-27 · round 4 (engine gaps, swipe UX + arbiter, companion app screens) ·** Three worktree agents merged cleanly. Verification after merge: `swift test` green — Core 32, Layout 23, Engine 189, OTP 11, Theme 12, UI 119, Sync 8; `scripts/build.sh` green; swipe agent used an iPhone 12 simulator (swipe trail, `All `/`Ask ` inserts, whole-word backspace seen). Rule note: the app agent added `- package: IBoardEngine` to project.yml (needed to link the dictionary decoder). Next integration tasks for an agent: adopt the new public engine API in IBoardUI/EngineHost (drop mirror types, `refreshPersonal`, `applyTouchModel`), wire GestureArbiter (M5-04) and queued app commands in the keyboard, record insight counters. Still needs the owner/device: perf gate M1-09, M0-06 restart/Email checks, M0-10 Duo.

- **2026-10-27 · round 3 (wiring, swipe, personal model v2, themes, sync) ·** Four worktree agents merged cleanly. Verification after merge: `swift test` green — Core 15, Layout 23, Engine 172, OTP 11, Theme 12, UI 66, Sync 8; `scripts/build.sh` green; wiring agent ran the keyboard on an iPhone 12 simulator. Known gaps to give an agent next: `Suggestions`/`SuggestionSlot` need public initialisers (IBoardUI carries mirror types), `PersonalStore.scorer()` and phrase chip not connected to `EngineActor`, tap decoder has no transposition (`teh`→`the`), adaptive touch model not applied. Needs the owner/device: perf gate M1-09 on iPhone 12, feel of haptics/sound, Duo (M0-10).

- **2026-10-27 · M1-05/06/07, M2-04..07, M3-01/02 (parallel round 2) ·** Three worktree agents merged cleanly. Verification after merge: `swift test` green — Core 15, Layout 23, Engine 119, OTP 11, Theme 3, UI 40; `scripts/build.sh` green; agent A drove an iPhone 12 simulator. Statuses are `[~]` where behaviour is only simulator- or unit-tested. Risks: handle/app height settings can disagree (Full Access limit); engine eval numbers are synthetic; portrait height changed after an orientation fix. Next: wire EngineActor + personal learning events into the keyboard (needs an agent that owns KeyboardViewController), M4 swipe, M5 gestures, real-device pass.

- **2026-10-27 · M1-03, M1-04, M2-02, M2-03, M6-02 done; M13-03, M0-06 partial ·** Overnight, three worktree agents (keyboard renderer+state machine, engine readers+tap decoder, OTP store+intent+privacy manifests) merged cleanly; owner device OTP spike captured as P-27. Verification after merge: `swift test` green in all six packages (Core 12, Layout 23, Engine 29, OTP 11, Theme 3, UI 26) and LexiconBuilder 7; `scripts/build.sh` green; app bundle contains Metadata.appintents and PrivacyInfo.xcprivacy. Follow-ups for the owner: (1) open Shortcuts once and report whether the missed post-restart run appears, (2) Email trigger test, (3) a real iPhone 12 pass on the new keyboard (feel, perf gates M1-09). Next agent tasks: M1-05 input controller, M1-06 strip, M1-07 resize, then M2-04.

- **2026-10-26 · M1-02 done ·** Layout engine merged from a worktree agent. Verification: `swift test` IBoardLayout 23 tests; `scripts/build.sh` green; geometry invariants (no overlaps, touch regions tile the area) and ±1 pt match to native-metrics.json at 390 pt wide. Follow-ups: capture caps lock/landscape/other sizes to replace estimates; M1-03 next (needs a simulator).

- **2026-10-26 · M1-01 (partial), M2-01 done, M1-08 (built) ·** Three parallel worktree agents merged cleanly. Verification: LexiconBuilder 7 tests, IBoardCore 12 tests, `scripts/build.sh` green; M1-01 measured from simulator screenshots (see task note for gaps). Next: M1-02 layout engine (can use iPhone 12 tokens; other sizes need captures), runtime-verify M1-08, M0-06 OTP probe awaiting owner, M0-10 Duo awaiting owner.

- **2026-10-26 · M0-13 done ·** Agent-built perf harness merged. Verification: `swift test` IBoardCore (7) and IBoardEngine (2) pass; `scripts/build.sh` succeeds with the overlay; agent also confirmed a Release build compiles. Not verified: overlay and signposts at runtime, absence of overlay in the Release binary. Follow-ups: instrument the other five metrics as M1 lands; M1-09 gate uses this.

- **2026-10-26 · M0-07 done (spike failed) ·** Foundation Models is `deviceNotEligible` on the owner's iPhone 12 (console output captured from a throwaway app). Not tested: extension call, eligible device. Consequence: AI stays post-v1/optional per D-16. M0-13 running in a worktree agent.

- **2026-10-26 · M0-05, M0-08, M0-09 done (device session) ·** With the owner's iPhone 12, one probe keyboard answered the Full Access matrix (P-23), text proxy behaviour (P-24) and pasteboard/lexicon (P-25); results pulled from the extension's log file via `devicectl` and crash reports. Two probe crashes were my own bugs (force-unwrap around the paste prompt; main-actor closure on an off-main callback). Not covered: Darwin delivery, network with Full Access, Safari/Instagram, Devanagari and marked text, haptic latency in ms. The probe build is still on the phone. Remaining M0 spikes: M0-06 (OTP pipeline, needs owner), M0-07 (on-device AI), M0-10 (Duo, needs owner).

- **2026-10-26 · M0-04 done ·** Serial run on one clean iPhone 12 sim. Host content shows through the default system backdrop; custom full-sheet effects regress. Verification: screenshots light/dark over a striped Safari page (`docs/spikes/M0-04-assets/`). Not covered: system keyboard in dark mode, per-key glass, GPU/memory cost, real device. Next: M0-08 and device parts of M0-05/09 serially.

- **2026-10-26 · M0-03 done ·** Probe build on the owner's iPhone 12 allocated until the extension was killed: last footprint recorded 76 MB (limit in [76, 81) MB), idle ≈ 5 MB, no memory warning first. Verification: owner read the on-screen "last run" value (screenshot); one run only. Follow-ups: the throwaway probe build is still installed on the phone (replace on next install); next serial spikes M0-04 then device parts of M0-05/08/09.

- **2026-10-26 · M0-04/05/08/09/10 (partial, parallel agents) ·** Five spike agents, each with its own simulator and worktree; merged docs only (`docs/spikes/`). Outcome: M0-09 mostly answered, M0-05 partially (sim ignores Open Access), M0-08 and M0-10 untested, M0-04 agent never finished (no commit). Cause: five booted simulators drove load to ~500 and made `axe` taps unreliable; `simctl clone` fails on booted sims; `axe touch --down --up` is more reliable than `axe tap` on keyboard UI. Lesson: run simulator spikes one at a time. Follow-ups: re-run M0-04 and M0-08 serially; do M0-03/05/08/09 device parts on the iPhone; M0-10 needs the owner at Simulator/Device Hub.

- **2026-10-26 · infra ·** Created public repo and pushed `main` (D-30); enabled private vulnerability reporting (API confirmed `enabled:true`). Owner approved CC BY-SA data (D-29), clearing the M0-11 sign-off for M2-01/M7. Installed AXe (`brew`, tap `cameroncooke/axe`, formula trusted) for simulator tap/type/describe-ui — agents can now drive simulator UI. Owner's iPhone 12 is paired/available for M0-03.

- **2026-10-26 · M0-11, M0-12, M0-14, M6-01 done (parallel agents) ·** Four agents worked in isolated git worktrees on disjoint files; branches merged cleanly. Verification: `swift test` in IBoardOTP (3 tests, corpus 149/149, 0 FP); build.sh + test.sh --no-ui run green by the agent; M0-11/M0-14 are docs (links/paths checked, licenses sourced from live pages, some marked unverified). Follow-ups: 👤 sign-off on CC BY-SA sources (R-06); enable GitHub private vulnerability reporting; repo has no remote.

- **2026-10-26 · M0-02 done ·** Owner enabled iBoard on the iPhone 12 simulator and confirmed the "a" key types into Safari's search field (Notes isn't installed on the sim). Closes the gap in the entry below. Next: M0-03 needs the owner's device; agents can take M0-04, M0-05 or M0-12.

- **2026-10-26 · M0-02 (built, not closed) ·** Added `project.yml` (D-28), `Config/Base.xcconfig` + `Local.xcconfig(.example)`, `iBoardKeyboard` extension (stub "a" key, no Full Access requested), App Group entitlements on app + extension, iCloud placeholder note, six Swift 6 packages (§7) with one test each, shared scheme in `xcshareddata`; `DEVELOPMENT_TEAM` no longer in the pbxproj. Verification: `swift test` passes in all six packages; app + extension build for generic simulator and the iPhone 12 simulator (extension embedded in PlugIns). **Not verified:** enabling the keyboard and typing "a" — simctl has no tap/typing and the Xcode device-interaction tools weren't available; I pre-seeded `AppleKeyboards` in the iPhone 12 sim but the screen was black after reboot. Follow-up: enable iBoard in Settings > Keyboards on a sim, type in Notes, then tick M0-02. Note: git repo has no remote, so nothing was pushed.

- **2026-10-26 · M0-01 done ·** Owner granted simulator access and selected Xcode 27.1. Created `iPhone 12` (iOS 27.0, 55FDD5FF-…) alongside the owner-created `iPhone Duo` (iOS 27.1, E295B4EA-…). Verification: both booted (`simctl bootstatus`), screenshots 1170×2532 and 2007×2853 px, template app builds for both destinations (exit 0). Next: M0-02.
- **2026-10-26 · M0-01 (blocked 👤) ·** iOS 27.1 simulator runtime installed (24A94425); it supports only iPhone Duo (P-19). `simctl create` fails for both iPhone Duo (27.1) and iPhone 12 (27.0): CoreSimulatorService gets EPERM writing to the SSD-backed device set (P-20); restarting the service and running unsandboxed didn't help. Verification: CoreSimulator.log shows `NSPOSIXErrorDomain Code=1 "Operation not permitted"` on `/Volumes/SSD/Library/Developer/CoreSimulator/Devices/…`. Follow-ups: owner grants access (Full Disk Access for CoreSimulatorService, or opens Xcode 27.1 Device Hub and allows the removable-volume prompt), then re-run the two `simctl create` commands from M0-01 and boot both.
- **2026-10-26 · M0-01 (in progress) ·** Owner installed Xcode 27.1 via Xcodes at `/Volumes/SSD/Applications/Xcode-27.1.0.app` (not yet `xcode-select`ed, P-18). Re-ran bootstrap with 27.1: `app-resizability` exported; `uikit-app-modernization` no longer ships and was removed from the script. Reviewed `app-resizability` vs vendored `iphone-duo-*`: it covers legacy screen/orientation/idiom APIs and safe areas but not hinge, fold/reserved-region layout, ArrangementView or Duo design, so all six community skills stay (§11, Apple wins on conflict). Owner's iPhone 12 found via `devicectl`: iOS 27.0, Developer Mode on, Wi-Fi paired (Q-01). Commit email stays public (Q-02). iOS 27.1 simulator runtime download started (`xcodebuild -downloadPlatform iOS`). Follow-ups: create iPhone 12 + iPhone Duo simulators when the runtime lands; owner runs `xcode-select`.

- **2026-10-26 · planning ·** Product discovery with the owner; all decisions in §4 recorded. Research: OTP via iOS 27
  shortcut-distributable Message automations (P-02), iPhone Duo geometry and the extension fold limitation (P-13,
  P-14), iPhone 12 on iOS 27 (P-12). Repo: added `ROADMAP.md`, `CLAUDE.md`/`AGENTS.md`, Apache-2.0 `LICENSE`,
  `NOTICE`, `.gitignore`, `scripts/bootstrap-agent-skills.sh`, vendored MIT skills (iPhone Duo ×6, swift-concurrency) with
  licenses; untracked `xcuserdata`. Verification: bootstrap script ran on Xcode 27.0 (app-resizability correctly
  skipped); `git status` shows non-redistributable skills ignored; template app builds with the interim command. No app code written. Follow-ups: M0-01 (owner).

---

## 16. Sources

- Apple — Creating a custom keyboard: https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard
- Apple — Designing for iPhone Duo (HIG): https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
- Apple — Preparing your app for iPhone Duo: https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
- Apple — iPhone Duo prepare (App Resizability skill): https://developer.apple.com/iphone-duo/prepare/
- Apple — iPhone models compatible with iOS 27: https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-27-iphe3fa5df43/ios
- Apple — Communication triggers in Shortcuts: https://support.apple.com/guide/shortcuts/communication-triggers-apdd711f9dff/ios
- ForwardSMS — Shortcuts automation on iOS 27: https://forwardsmsapp.com/blog/how-to-set-up-shortcuts-automation-on-ios-27
- KeyboardKit — Keyboard extensions can't detect the iPhone Duo fold: https://keyboardkit.com/blog/2026/10/14/ios-keyboard-extensions-can-t-detect-the-iphone-duo-fold
- mirzaaghazadeh/iphone-duo-skills (MIT): https://github.com/mirzaaghazadeh/iphone-duo-skills

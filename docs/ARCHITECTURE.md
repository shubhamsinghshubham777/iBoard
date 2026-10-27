# Architecture (as built, 2026-10-27)

This describes what the code does today, read from the sources, not what the roadmap plans. Where something is
designed but not wired, it says so. For rationale and locked decisions see `ROADMAP.md`; for per-area detail see the
other notes in `docs/`.

## 1. Targets and packages

```
iBoard (app, SwiftUI)  ---embeds--->  iBoardKeyboard (extension, UIKit, UIInputViewController)
        |                                         |
        +-- IBoardCore, IBoardEngine,             +-- IBoardCore, IBoardLayout, IBoardEngine, IBoardOTP,
            IBoardTheme, IBoardOTP                    IBoardEmoji, IBoardTheme, IBoardUI
```

`project.yml` (XcodeGen) wires the dependencies above. `IBoardSync` is a package with tests but is not linked into
either target.

| Package | Role | Depends on |
|---|---|---|
| `IBoardCore` | `IBoardSettings` + `SettingsStore` (App Group defaults), `LocalLayoutOverrides`, `Perf` (signposts + ring buffers for the ROADMAP section 6 metrics), `InsightCounters`/`InsightsStore` (numbers only), app-to-keyboard `CommandQueue`/`CommandQueueStore`/`ImportPayloadStore`, `DictionaryBrowse` (app-side word list sorting) | none |
| `IBoardLayout` | Pure geometry. `LayoutEngine.layout(...)` turns `LayoutSettings` + `LayoutTraits` + size into a `KeyboardLayout` (keys, strip frame, `stripSegments`, bounds); `HitModel`/`KeyHit` resolve a touch to a key; `DuoGeometry`/`DuoMode`/`CentreGap` carry the fold split logic. No UIKit, no `UIScreen.main` | none |
| `IBoardEngine` | The prediction engine, all `Sendable`: `Lexicon` (memory-mapped trie), `NGramModel`, `TapDecoder`, `SwipeDecoder`, `CodeSwitch` (English + Hinglish scoring), `AutocorrectPolicy`, `SmartPunctuation`, the `EngineActor`, and the `Personal/` model (store, learner, phrase model, adaptive touch model, `.iboarddict` import/export) | `IBoardCore`, `IBoardLayout` |
| `IBoardUI` | UIKit views and UIKit-free logic: `KeyGridView`, `SuggestionStripView`, `KeyboardInputMachine` (shift, repeat-delete), `GestureArbiter`, `SwipeCapture`/`SwipeEngine`, `TypingCoordinator`, `StripChips`/`ChipPlanner`, `VirtualSelection`, `CursorMath`, `AppCommandApplier`, `PersonalInfo`, `InsightRecorder` | `IBoardCore`, `IBoardLayout`, `IBoardEngine`, `IBoardTheme`, `IBoardOTP` |
| `IBoardOTP` | `OTPParser` (finds codes in message text), `OTPStore`/`OTPReader`/`OTPWriter` over App Group defaults (TTL 10 min, max 3 codes) | none |
| `IBoardTheme` | `Theme` model, `NativeTheme` (system-matching default), presets, `ThemeFile` import/export, `PhotoPipeline`, `ThemeAccessibility`, `ThemeStore` (defaults + photo files) | none |
| `IBoardEmoji` | `EmojiCatalog` (bundled `emoji.json`), `EmojiSearchIndex`, `EmojiPreferences`, `EmojiPanelView` (UIKit), kaomoji | none |
| `IBoardSync` | `SyncState` CRDT merge model and schema for future iCloud sync; no CloudKit code | none |

Tools (macOS, not shipped): `Tools/LexiconBuilder` builds `lexicon.iblex` / `lm.iblm` and a licence manifest from
text inputs (format in `docs/LEXICON_FORMAT.md`); `Tools/HinglishData` generates the Hinglish inputs and runs the
builder into `Data/hinglish/`.

## 2. The keyboard extension at runtime

`KeyboardViewController` (about 1,100 lines) owns the view hierarchy and is the only place that touches
`textDocumentProxy`. Collaborators:

- `KeyGridView` draws keys with Core Animation and manual frames from a `KeyboardLayout`; it reports raw touches
  (`began/moved/ended/cancelled` with finger id, point, timestamp) to the controller.
- `EngineHost` loads `lexicon.iblex` / `lm.iblm` from the extension bundle and builds the `PersonalStore` and
  `PersonalLearner` on a detached task (no file IO or decoding on the main thread). Missing assets mean no engine,
  not a crash. Today the bundled English data is a 219-word synthetic placeholder and no secondary (Hinglish)
  language is passed to the engine.
- `EmojiHost` creates the emoji panel, catalog and search index only while the panel is open and drops them on close,
  memory warning or disappearance.
- `DebugOverlay` (DEBUG) prints numbers and flags, never typed text.
- `SuggestionStripView` has three slots; `ChipPlanner` decides when OTP or personal-info chips replace suggestions.

## 3. Data flow

### Per keystroke (tap typing)

```
UITouch (KeyGridView)
  -> KeyboardViewController.handleTouch(phase, fingerId, point, time)
  -> GestureArbiter / KeyboardInputMachine   (tap vs flick vs swipe vs shift+space selection; shift & delete repeat)
  -> KeyEvent (.insert(letter), .backspace, .space, ...)
  -> TypingCoordinator: resolves the KeyHit of the finger that produced the letter, edits the host text
  -> EngineActor.beginRequest()  (main thread, returns a sequence number; older requests are now stale)
  -> EngineActor.submit(EngineRequest(touches, previousWords))   (serial, off the main thread)
       TapDecoder over Lexicon (+ secondary lexicon if configured) + NGramModel
       + adaptive touch model + personal scorer + phrase suggester
  -> Suggestions (3 slots, optional AutocorrectProposal); dropped if the sequence number is stale
  -> KeyboardViewController.renderStrip()
```

`Perf` records `keystrokeToSuggestions` and `touchUpToInsert` around this path. Autocorrect (`AutocorrectPolicy`)
applies only on space or sentence punctuation, only with a result for exactly the current word, and never in
secure, email, URL or number fields; backspace right after a correction restores the original.

### Swipe typing

`KeyGridView` touches -> `SwipeCapture` (point sampling, thresholds) -> `SwipeEngine` (actor over `SwipeDecoder`,
which matches the trace against the lexicon) -> candidate list -> `TypingCoordinator` inserts the word with spacing
(`SwipeSpacing`) and feeds the same learner path as typed words.

### Personal learning

`TypingCoordinator` sends learner events (`wordCommitted`, `autocorrectReverted`, `sentenceBoundary`, `flush`, ...)
to `PersonalLearner`. `LearningPolicy` and `FieldTraits` exclude secure, email, URL and similar fields and
honour incognito. `PersonalStore` (actor) keeps unigram/bigram/phrase counts in memory and persists a snapshot plus an
append-only journal through `PersonalStorage` (`FilePersonalStorage`): extension-local without Full Access, App Group
with it (`PersonalStorageFactory`). With Full Access the keyboard also writes `shared/dictionary.iboarddict`
(`EngineHost.writeSharedSnapshot`) so the app can browse, edit, import and export the dictionary. The adaptive touch
model keeps per-key touch offset statistics (numbers only) in a separate file.

### Companion app <-> keyboard

There is no direct connection. The channel is the App Group (`group.app.iBoard`):

- settings: `SettingsStore` (`IBoardSettings`) written by the app, read by the keyboard;
- commands: the app appends `CommandEnvelope`s to the `CommandQueue` (defaults, readable without Full Access); the
  keyboard applies them through `AppCommandApplier` (`docs/APP_COMMANDS.md`);
- OTP codes: the `CaptureVerificationCodeIntent` App Intent in the app parses message text with `OTPParser` and
  stores the code with `OTPWriter`; the keyboard's `OTPReader` shows fresh codes as chips (`docs/KEYBOARD_WIRING.md`);
- personal info (name, email, phone, address chips): app writes, keyboard only reads (the app-side editor is not
  built);
- themes: `ThemeStore` (theme definitions in defaults, photos as files);
- insights: `InsightCounters` (counts only).

## 4. Layout

`LayoutEngine` is size-agnostic: it takes the container size, `LayoutTraits` (keyboard kind, return-key kind,
orientation/display class) and `LayoutSettings` (number row, height scale, Duo mode) and returns a `KeyboardLayout`.
The same `KeyboardLayout` feeds `KeyGridView` (drawing), `HitModel` (touch resolution) and `EngineActor` (key
geometry for the tap decoder), so all three always agree. `DuoGeometry`, `DuoMode`, `CentreGap` and the split
placement exist and are unit-tested in `IBoardLayout`, but `KeyboardViewController` does not use them yet: on
iPhone Duo's inner display the keys currently run straight across the fold (`docs/spikes/M0-10.md`).

## 5. Data files

- `iBoardKeyboard/Resources/lexicon.iblex`, `lm.iblm`: 219-word synthetic CC0 placeholder (English).
- `Data/hinglish/`: real Hinglish lexicon (56,235 words) and LM (150,006 bigrams, 60,000 trigrams), built and
  engine-tested, not bundled into the extension yet.
- `Packages/IBoardEmoji/.../Resources/emoji.json`: Unicode/CLDR emoji catalog (en, hi, romanized Hindi overlay).
- Licences and provenance: `docs/DATA_SOURCES.md`, `NOTICE`.

## 6. Concurrency and memory

- Swift 6 language mode. Engine types are `Sendable`; `EngineActor`, `SwipeEngine`, `PersonalStore`, `PersonalLearner`
  are actors; the controller and views are main-actor.
- `EngineActor.beginRequest()` is `nonisolated` (a mutex-protected counter) so the main thread can invalidate
  in-flight work without awaiting.
- Lexicon and LM files are memory-mapped, not read into the heap. Personal store caps are configured in
  `PersonalStoreConfig` (`docs/PERSONAL_MODEL.md`). Emoji data exists only while the panel is open.
- Budgets (ROADMAP section 6) are asserted in release builds only; measured numbers so far are macOS or simulator
  figures, not device figures (`docs/PERFORMANCE.md`).

## 7. Privacy boundaries (enforced where possible)

- No logging of values, no network, no analytics, no implicit pasteboard use in shipped code:
  `scripts/audit-privacy.sh` fails the build on any new occurrence unless reviewed in `scripts/audit-privacy.allowlist`.
  It is a grep tripwire; it cannot prove the absence of data flow, so review still matters.
- Typed text persists only in the personal store (and the optional `dictionary.iboarddict` export). Secure fields are
  never seen by a custom keyboard (iOS substitutes the system keyboard), and learning is also excluded for email,
  URL and similar fields and while incognito is on.
- `RequestsOpenAccess` is `false` in `project.yml`'s extension info: Full Access is a runtime capability the keyboard
  checks (`hasFullAccess`); features needing it (shared personal store, clipboard actions, haptics) degrade without it.
  NOT VERIFIED here: how Full Access is requested from the user at install time, since the Info.plist key is false.
  See `docs/PRIVACY.md` and ROADMAP P-23.

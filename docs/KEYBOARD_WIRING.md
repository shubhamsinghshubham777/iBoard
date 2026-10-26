# Keyboard wiring (M2-04 strip wiring, F2/F4 integration)

How the engine (`IBoardEngine`) is connected to the keyboard extension. No new engine features.

## Pieces

- `Packages/IBoardUI/.../TypingCoordinator.swift` (UIKit-free, unit-tested): owns the current word session, turns key
  events into text edits, talks to the engine and the personal learner. Seams: `SuggestionEngine` (adapter
  `EngineBridge` over `EngineActor`) and `PersonalLearning` (`PersonalLearner` conforms as is).
- `iBoardKeyboard/EngineHost.swift`: loads `lexicon.iblex` / `lm.iblm` from the bundle and builds the
  `PersonalStore` + `PersonalLearner`, all in a detached task (no IO or decoding on main). Missing assets: no engine,
  contractions / smart punctuation / learning still work, never a crash.
- `iBoardKeyboard/Resources/lexicon.iblex`, `lm.iblm`: the 219-word synthetic CC0-1.0 fixture from
  `Packages/IBoardEngine/Tests/IBoardEngineTests/Fixtures/small` (built by `Tools/LexiconBuilder`, licences in that
  folder's `licenses.json`). Placeholder until real data (M2-0x).
- `KeyboardViewController`: feeds touches (`trackTouch`) and key events, renders `StripContent` in the 3 slots,
  maps UIKit traits to `FieldConfig` (autocorrection / spell checking / smart quotes / dashes / autocap, `FieldTraits`
  for F4 exclusions), strip taps, DEBUG overlay lines.

## Data flow per keystroke

touch point -> `KeyboardInputMachine` -> `.insert(letter)` -> coordinator resolves the `KeyHit` of the finger that
produced the letter -> inserts the letter -> `EngineActor.beginRequest()` + `submit` on a serial queue ->
`Suggestions` -> strip. `Perf.keystrokeToSuggestions` runs from the key event to the strip update, stale results are
dropped by the engine's sequence number.

## Behaviour

- Strip order: `[literal (quoted if not a word), best, alternative]`; next-word predictions show best in the middle.
- Autocorrect (conservative, `AutocorrectPolicy`) applies on space and `. , ; : ! ? )` only when a result for exactly
  the current word has arrived; otherwise the literal stays. Contractions (`dont` -> `don't`) apply without the engine.
  Never in secure / email / URL / number fields, never when the field says autocorrection off.
- Backspace right after a correction (within 30 s) restores the original, resumes the word session and reports
  `autocorrectReverted`; the second restore of a word puts it on the in-memory never-correct list. Tapping the quoted
  literal counts as the same signal.
- SmartPunctuation: auto-cap (abbreviation aware, replaces `AutoCapitalizer` for shift), double-space period, smart
  quotes / dashes.
- Apostrophe inside a word ends engine tracking for that token; the whole token (`don’t`) is learned, never corrected.
- Learner events: `fieldDidChange` (new `documentIdentifier`, appearance), `wordCommitted` (space, punctuation, strip tap),
  `typingContinued`, `lastWordReopened`, `autocorrectReverted`, `sentenceBoundary` (. ! ? return), `flush`
  (4 s idle, keyboard hidden). Incognito: `iBoard.incognito` in keyboard-local `UserDefaults` (placeholder; DEBUG:
  long-press the top-left corner of the keyboard).
- Storage: `PersonalStorageFactory`: extension-local without Full Access, App Group with it (P-23). The one-way
  local -> App Group migration when Full Access appears is NOT TESTED.

## Verified (iPhone 12 simulator, iOS 27.0, Debug)

- `swift test` in Packages/IBoardUI: 66 tests pass (coordinator with fakes + a real `EngineActor` on the fixture).
- Bundled engine loads ("engine: bundled 219 words"), predictions `Be / The / To` at the start of a text area, typing
  `th` + a touch between `w` and `e` shows `"Thw" / The / They`, space autocorrects to `The `, backspace restores
  `Thw` (screenshots below). Email field: three typed words, learning=false incog=true (automatic), personal counts
  unchanged (u2 b2 t1 before and after).
- Perf on the simulator (Mac CPU, NOT a device number): keystrokeToSuggestions p50 1.6-1.8 ms, p95 1.8-2.3 ms;
  touchUpToInsert p50 0.5 ms. Extension memory 24-25 MB footprint with the tiny lexicon.
- NOT TESTED: real device, Full Access mode, password fields (iOS always shows the system keyboard there, so the
  extension never sees them), strip taps (code path covered by unit tests only), rotation, Duo, the real-size lexicon.

![autocorrect](KEYBOARD_WIRING-assets/autocorrect-applied.png)
![restore](KEYBOARD_WIRING-assets/backspace-restore.png)
![email](KEYBOARD_WIRING-assets/email-field-not-learned.png)

## Caveats and engine hooks wanted

- `Suggestions`, `SuggestionSlot` have internal initialisers: tests cannot build them, hence `EngineResult`/`StripSlot`
  in IBoardUI. Make them public in IBoardEngine and drop the mirror types.
- The engine does not take the personal model: `PersonalStore.scorer()` is not wired into `EngineActor`, so learned
  words do not yet appear in suggestions (needs an engine hook).
- The tap decoder does no transposition (`teh` is not corrected to `the`), only spatial typos.
- Word session starts at the first letter typed after the cursor lands: continuing a word the user did not type this
  session gets no suggestions until a separator.
- A strict exclusivity trap: `shiftActive` must not read the input machine (crashed once, fixed).
- Files needing `xcodegen generate`: `iBoardKeyboard/EngineHost.swift`, `iBoardKeyboard/Resources/lexicon.iblex`,
  `iBoardKeyboard/Resources/lm.iblm`.

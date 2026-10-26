# App to keyboard commands (M3-07, M10-03, M10-04)

The personal dictionary lives in the keyboard extension (P-23: without Full Access the extension cannot write
shared storage, so the app can never be the owner). The companion app therefore works on a file snapshot the keyboard
shares and sends edits as a queue of idempotent commands that the keyboard applies later.

Code: `Packages/IBoardCore/Sources/IBoardCore/AppCommands.swift`, `DictionaryBrowse.swift`, `Insights.swift`.
App: `iBoard/DictionaryStore.swift`, `DictionaryViews.swift`, `DictionaryTransferView.swift`, `InsightsView.swift`.

## Channels

| Direction | Data | Channel | Needs Full Access |
|---|---|---|---|
| app -> keyboard | settings | App Group defaults (existing) | no (read measured, P-23) |
| app -> keyboard | command queue | App Group defaults key `iboard.commands.queue` | no (read measured, P-23) |
| app -> keyboard | import payload | file in App Group `imports/` | NOT MEASURED whether the extension can read app-written files without Full Access |
| keyboard -> app | dictionary snapshot | file `shared/dictionary.iboarddict` in the App Group | yes (file write) |
| keyboard -> app | insight counters | App Group defaults key `iboard.insights.counters` | yes (defaults write) |
| keyboard -> app | acknowledgement | none visible to the app without Full Access | the app only knows what it queued |

## Queue format

One JSON object in defaults: `{"version":1,"nextSeq":N,"entries":[{"seq":1,"created":<unix>,"command":{...}}]}`.
Single writer (the app) appends and assigns `seq` (monotonic, never reused, oldest entries dropped past 500 or 512 KB).
The keyboard keeps `lastAppliedSeq` in its OWN container (it cannot write the group), applies
`CommandQueue.pending(after:)` in order and stores the new value. Commands are idempotent, so re-applying after a crash
is harmless. Unknown future command types and invalid entries are skipped individually, a newer `version` or corrupt
data applies nothing.

Commands (`type`): `addWord{word,surface?}`, `forgetWord{word}`, `unforgetWord{word}`,
`neverCorrect{word,enabled}` (pin = never autocorrect), `importDictionary{fileName,replace}`, `resetInsights`,
`clearPersonalData`. Words are lowercased, 1 to 64 characters, no whitespace or control characters; `surface` only if
it lowercases to `word`. Import file names must match `ImportPayloadStore.isValidFileName` (ASCII, `.iboarddict`,
no path components), so a hostile queue cannot make the keyboard read outside `imports/`.

## Keyboard-side work required (not done here, keyboard target is out of scope)

Map commands to the engine, all of which already exist: `addWord` -> `PersonalOp.add(kind: .unigram ...)`;
`forgetWord`/`unforgetWord` -> `PersonalOp.forget/unforget`; `neverCorrect` -> `addNeverCorrect/removeNeverCorrect`;
`importDictionary` -> `PersonalStore.importDictionary(data, options:)` (DictionaryMerger); `clearPersonalData` ->
`PersonalOp.clear`; `resetInsights` -> zero the local `InsightCounters` and, with Full Access, rewrite the shared copy.
With Full Access also write `shared/dictionary.iboarddict` (`exportDictionary()`) after compaction and
`InsightsStore.save`. Apply the queue on keyboard launch (`viewWillAppear`), not per keystroke.

## What the app shows

- No snapshot (Full Access off or never used with it): honest empty state listing what still works.
- Edits are shown as "queued", never "applied"; the app overlays pending commands onto the snapshot
  (`DictionaryBrowse.applying`). Import and erase cannot be previewed.
- Import: file chosen through `fileImporter`, validated with the engine decoder (counts only shown), copied to
  `imports/`, then queued. Export: the shared snapshot through `fileExporter`.
- Insights: counters are aggregates only (`InsightCounters`: no text). Top learned words are derived from the
  snapshot at view time and never stored.

## Caveats

Replacing the queue from two app processes at once is guarded only by a process-local lock (the app is the single
writer; widgets/intents must not append). Exports contain clear-text words by design.

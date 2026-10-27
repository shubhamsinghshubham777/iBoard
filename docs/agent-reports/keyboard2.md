# KEYBOARD2 agent report (2026-10-27)

Branch: `worktree-agent-aca5edb4052184913`. Verification: `swift test` in Packages/IBoardUI 267 tests green (10 new);
`scripts/build.sh` green; `scripts/test.sh --no-ui` green; `scripts/audit-privacy.sh` OK. The simulator keyboard does not
appear (HANDOFF §8), so nothing here was seen on screen. No ROADMAP edit, no push, nothing installed on the phone.

## M3-05 SystemLexicon keyboard wiring — [~]
- `requestSupplementaryLexicon` is called on every appearance; the callback only copies `userInput`/`documentText` into
  `SystemLexiconEntry` values (it may run off-main, P-25) and hops to the main actor. Entries and the snapshot are memory-only.
- Before the engine finished loading, the snapshot is built directly (expansion works immediately). After the load,
  `SystemLexiconImporter` runs with `host.store` so new contact names are seeded once (`seedIncrement`), then
  `engine.refreshPersonal()` when names were added. The fingerprint (one integer, stored as a decimal string in the extension's
  defaults under `iBoard.systemLexicon.fingerprint`) is passed as `previousFingerprint`, so an unchanged address book costs nothing.
  Allowlist line for the controller was updated with this reason; `audit-privacy.sh` passes.
- Text Replacements: space after a typed token that exactly matches a shortcut (case-insensitive) replaces it with the
  expansion plus a space (`TypingCoordinator.expandShortcut`, new: deletes the token, does not learn or autocorrect the
  shortcut, starts a fresh prediction). Skipped in secure fields, emoji search, the clipboard panel, tokens > 40 chars, and when
  autocorrection is off in settings. Auto-replace was chosen over a chip (it is what the system keyboard does).
  No undo chip for an expansion (backspace removes the space; a second backspace edits the expansion).
- Name completions: not built separately. Contact names are seeded into the personal model, so the engine already offers them
  and no longer autocorrects them. `SystemLexiconSnapshot.names(withPrefix:)` is unused by the keyboard.
- Tests: coordinator expansion (replace + not learned + no token), policy, fingerprint round-trip.
- Needs device: whether `UILexicon` returns contact names without Full Access (unknown); Text Replacements on a real field.

## M9-03 Clipboard history panel — [~]
- New `ClipboardPanelView` (IBoardUI) + `ClipboardHost` (keyboard) + `ClipboardPanelModel` (pure, tested). Replaces the key
  area like the emoji panel: rows (preview, age, "Code" tag), tap pastes and closes, pin/unpin button, delete button,
  "Clear" (two taps: the second confirms; no alerts in an extension; clears pinned too), Done, and a footer that states the
  TTL actually in force. Pinned items sort first; expired items never show (`visible(at:)`) and are removed from disk on every save.
- Entry point: long press on the clipboard chip (strip slot 3, shown in an empty plain field) or the VoiceOver action
  "Open clipboard history". Full Access only (the history is not recorded without it).
- TTL/enabled: `IBoardSettings` has no clipboard field, so the existing defaults are used (1 h, 10 min for codes, 20 items).
  APP2 can add `clipboardTTL`/`clipboardEnabled` later; `ClipboardHistory.ttl` already exists, the controller just has to set it
  from settings after `clipboardStore.load()`.
- Not done: discoverability beyond the chip (an empty-field-only chip means the history cannot be opened while text is in
  the field; a dedicated key/long-press entry is a design call).
- Needs device: layout/feel of the panel at several text sizes, no repeated paste prompts (P-25).

## M13-01 Accessibility remainder — [~]
- Dynamic Type: all strip text (slots, banner, actions, alternates, emoji search pill) uses `UIFontMetrics` capped at 1.35x
  (`StripTypeScale`, tested) with shrink-to-fit; the strip relays out on a text size change. Clipboard panel scales up to 1.6x
  with self-sizing rows. Keys deliberately do not scale (same as the system keyboard).
- VoiceOver: emoji panel search pill and its Cancel button are now elements (they were hidden: the strip returned none in emoji
  mode); the clipboard panel rows are buttons with Pin/Delete custom actions, header and buttons labelled, and a rotor
  "Pinned items". Strip suggestion slots gain custom actions "Forget suggestion" / "Never correct" (the long-press menu is
  unreachable by touch for VoiceOver users); the clipboard chip gains "Open clipboard history". The panel posts
  announcements for pin/delete/clear and a screen-changed notification on open/close.
- Reduce Motion: audited every animation (shift pulse, slot fade, caret blink, swipe trail fade) — all already gated; added
  a live observer so a blinking caret stops immediately when the setting is switched on. The clipboard panel's list
  cross-fade is skipped under Reduce Motion.
- Not done: Packages/IBoardEmoji (not owned here: panel cells already carry names; the category chips and results row too),
  Switch Control / Voice Control checks, key-level rotor (judged not useful).
- Needs device: a full VoiceOver walk-through (strip, emoji, clipboard), Larger Text at the largest accessibility sizes.

# Keyboard-owner agent report (2026-10-27)

Verification: `swift test` IBoardUI 257 tests green (new: SuggestionMenu, HapticPack, KeyAccessibility, ClipboardHistory, chips);
`scripts/build.sh` green; `scripts/test.sh --no-ui` green. Simulator keyboard never appears (HANDOFF §8), so NO on-screen run.

## M3-04 Forget & never-correct UX — [~]
Long-press (0.5 s, moves > 10 pt cancel) on a suggestion slot opens an action row in the strip: Forget / Never correct / Cancel
(`SuggestionMenu`, controller `openSuggestionMenu`). Forget -> `PersonalLearner.forgetSuggestion` + `engine.refreshPersonal()`;
Never correct -> `PersonalStore.addNeverCorrect` + refresh. Lists persist via the personal store. Not offered on chips, the
undo chip, one-letter or multi-word text. Unit-tested: menu policy only. Needs device: gesture feel, strip render.

## M6-05 Clipboard code fallback — [~]
Code fields (one-time-code / numeric pad) with Full Access and no stored code show a "Paste code" chip. The pasteboard is read
ONLY on tap, off the main thread (`Task.detached`, P-25); `ClipboardCode.extract` (bare code or `OTPParser`) inserts it; a miss
hides the chip until the field changes. Tests: planner + extraction. Needs device: paste prompt behaviour (M0-09), real Full
Access run. The roadmap's "offer when the pasteboard changes near OTP keywords" auto-read variant was NOT built (it would read
the pasteboard unprompted).

## M8-03 Haptics & sound packs — [~]
Haptics: `HapticPack` (standard, soft, crisp, lettersOnly) added to `IBoardSettings` (field `hapticPack`, tolerant decode,
default standard) and `HapticPlan` maps kind x pack x intensity; the keyboard uses it. NO sound packs: an extension can only
call `playInputClick` (P-23), so custom sounds are not possible; recorded as a platform limit. APP agent: add a pack picker
bound to `settings.hapticPack`. Needs device: feel of each pack.

## M8-05 Theme accessibility wiring — [~]
Already wired before this round (observers on Reduce Transparency / Darker Colors / Bold Text -> `applyTheme` -> `KeyboardSkin`
via `ThemeVariant.resolved`); `KeyboardSkinTests` cover the three switches. No new code needed; not re-verified on device
(simulator keyboard unavailable). Needs device: toggle each switch with Midnight / Native Glass and look.

## M13-01 Accessibility — [~]
Keys and strip were invisible to VoiceOver (plain layers). Added: one `UIAccessibilityElement` per key (labels via
`KeyAccessibility`: shift state, spelled punctuation, return-key kinds, next keyboard) with activation routed through the
normal touch path; strip slot / action / banner elements with activation; elements invalidated on layout / shift /
return-state change. Not done: Dynamic Type for strip text, Switch Control / Voice Control checks, rotor, emoji panel labels
audit. Needs device: VoiceOver walk-through.

## M9-03 Clipboard manager — [~]
`ClipboardHistory` (max 20, TTL 1 h, code items 10 min, pin, clear-all, dedupe, `changeCount` gating) + `ClipboardStore` file
(extension container; expired items dropped on every save and on disappear). The keyboard records on appearance and on the
2 s chip timer when Full Access, never in secure fields, string read off-main; the newest item shows as a clipboard chip
(slot 2) in an empty plain field. Added a reviewed entry to `scripts/audit-privacy.allowlist`. NOT built: full history panel
with pin / clear buttons and the TTL setting in the app (model supports them). Needs device: that background reads do not
trigger repeated paste prompts (P-25), items appearing within one keyboard appearance.

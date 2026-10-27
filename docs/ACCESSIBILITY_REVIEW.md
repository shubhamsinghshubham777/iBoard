# Accessibility review of the keyboard UI (code read, 2026-10-27)

Scope: `Packages/IBoardUI` (`KeyGridView`, `SuggestionStripView`, `ResizeHandleView`, strip chips), the emoji panel
(`Packages/IBoardEmoji/.../EmojiPanelView.swift`) and `iBoardKeyboard/KeyboardViewController.swift`. Target: ROADMAP F19
("VoiceOver can type a sentence and pick a suggestion").

Method and limits: static reading of the code and a grep for every accessibility API in `Packages/*/Sources`,
`iBoard/` and `iBoardKeyboard/`. **NOT TESTED** with VoiceOver, Voice Control, Switch Control, Full Keyboard Access,
Dynamic Type or the Accessibility Inspector, on device or simulator. Statements about what VoiceOver "will do" are
expectations from the UIKit contract and must be confirmed on a device. No UI code was changed.

## Summary

The keyboard is currently **not usable with VoiceOver for typing**: the key grid exposes no accessibility elements at
all. The only accessibility work present is in the emoji panel (cell and tab labels), the resize handle (a label) and the
Reduce Motion path of the swipe trail. Everything below is a gap to close in M13-01 (F19) unless marked otherwise.

Severity: **P0** blocks the F19 acceptance criterion, **P1** serious usability gap, **P2** polish.

## Findings

### Key grid (`KeyGridView`)

- **P0: keys are invisible to assistive technology.** `KeyGridView` is a plain `UIView` that draws one `CALayer` per key.
  It never sets `isAccessibilityElement`, `accessibilityElements`, labels or traits (only `accessibilityIdentifier`
  and, in DEBUG, a debug `accessibilityValue`). A custom keyboard whose keys are layers has no per-key elements
  unless the view builds them, so VoiceOver will not announce or activate any key. Fix: expose one
  `UIAccessibilityElement` per `KeyboardKey` (rebuilt in `apply(layout:)`, frames converted with
  `accessibilityFrameInContainerSpace`), each with the `.keyboardKey` trait. With that trait, VoiceOver's keyboard
  typing modes (Standard, Touch Typing, Direct Touch Typing) behave like the system keyboard: Touch Typing enters the
  key on finger lift. Cache the element array; do not allocate on the touch path (D-24 / touch budget).
- **P0: no labels.** Needed per `KeyIdentity`: letters (spoken as the character; uppercase when shift is on), symbols
  and domain suffixes (spoken names: "at sign", "dot com"), `space` ("space"), `delete` ("delete"), `shift`
  ("shift", with value "off / on / caps lock" and trait `.selected` while active), `returnKey` (its real action:
  "return", "go", "search", "send", "done", "next", "call"; ReturnKeyStyle.label gives the visible text, but the phone
  glyph is a bare SF Symbol), `layerSwitch` ("numbers", "symbols", "letters"), `globe` ("next keyboard"). A dimmed return key
  (`enablesReturnKeyAutomatically`, opacity 0.4) needs the `.notEnabled` trait.
- **P0: the globe key must work under VoiceOver.** It is how a VoiceOver user leaves the keyboard. Confirm that
  activating it calls `advanceToNextInputMode` / `handleInputModeList` for both tap and the system's long-press behaviour.
  NOT TESTED.
- **P1: state changes are silent.** Shift, caps lock, layer switches (letters to numbers) and field changes do not post
  announcements or `.layoutChanged` notifications. Post `UIAccessibility.post(.layoutChanged, ...)` after a layer
  change, and make shift state readable through `accessibilityValue`. Autocorrect applied or reverted should announce
  ("corrected to ..." / "restored ..."); announcements go to the screen reader only and must not be logged, which
  the privacy audit enforces for the app code.
- **P1: multi-touch and gestures vs VoiceOver.** The grid forwards raw `touches*` with `isMultipleTouchEnabled`, and
  the controller layers custom gestures on them: flick up for secondary characters, swipe typing, shift+space cursor
  and selection, long press on the 123 key for emoji, long press for alternates. VoiceOver does not deliver
  these raw touches to the view in non-direct-touch mode. The keyboard needs accessible equivalents:
  `accessibilityCustomActions` on keys (alternates and secondary characters on letters, "emoji" on the layer key),
  and cursor movement through the `.adjustable` trait on a dedicated element or custom actions on `space`
  ("move cursor left / right", "select word"). Swipe typing should be disabled while VoiceOver is running
  (`UIAccessibility.isVoiceOverRunning`) unless direct touch is active.
- **P1: direct-touch typing.** For users who want raw touch with VoiceOver on, either offer a clearly labelled direct
  interaction region (an element with `.allowsDirectInteraction`) or rely on `.keyboardKey` elements and Touch Typing.
  Decide and document which one is supported; the F19 text says "direct-touch typing mode". Note that
  `.allowsDirectInteraction` on the whole grid would also pass touches without any announcement of keys, so it should
  be a user setting, not the default.
- **P2: Voice Control and Full Keyboard Access.** With per-key elements, Voice Control can use "tap a" style names; names
  should match the visible glyph. Full Keyboard Access / Switch Control cannot reach layer-drawn keys today.
- **P2: highlight state and hit target.** The pressed highlight is a colour swap only, with no feedback for low vision beyond
  that; the keyboard intentionally has no key-preview balloon (D-08), so a spoken echo under VoiceOver is the only
  confirmation, which makes the per-key labels above more important.

### Suggestion strip and chips (`SuggestionStripView`, `StripChips`)

- **P0: suggestions cannot be picked with VoiceOver.** The strip sets `isUserInteractionEnabled = false` and its slots
  are `UILabel`s; taps are resolved by the key grid from touch coordinates (`handleTouch` maps `point.x` to a slot).
  Whether VoiceOver reads these labels at all is NOT VERIFIED; even if it does, a VoiceOver activation
  (double-tap) is not a touch on the grid at the label's location in a way the code recognises. Needed: three
  accessible elements with `.button` trait whose `accessibilityActivate()` calls the same `tapSlot` path as a touch,
  labelled with the text and role: "suggestion: the", "correction: ... (replaces what you typed)", "literal: \"Thw\"".
  Empty slots should not be elements.
- **P0 (selection row): Cut / Copy / Delete / Aa / close** are `UILabel`s in the same non-interactive strip, with the
  disabled state shown only by alpha 0.3. They need `.button` trait elements, `.notEnabled` when disabled (Cut and
  Copy without Full Access), and clear names ("cut", "copy", "delete selection", "change case", "cancel selection").
- **P1: chips.** OTP chips and personal-info chips are displayed through the same slot labels. Give them a role
  ("verification code 123456", "your email", ...). A one-time code will be spoken aloud by VoiceOver: that is the
  expected behaviour for the user but deserves a settings note, and the spoken label should never be written to any log.
  The emphasised-chip look (filled rounded rect) carries meaning only visually: add an accessibility trait or label prefix.
- **P1: the banner** ("...selected text... . N chars") is plain text; mark it `.updatesFrequently` or post
  `.announcement` when a selection starts, so the selection state is perceivable.
- **P2: alternates row** (long press) is only reachable through the grid's touch session; see custom actions above.
- **P2: text size.** Strip fonts are fixed (`systemFont(ofSize: 16/15/14)`), no `adjustsFontForContentSizeCategory`.
  Keyboard extensions generally do not scale with Dynamic Type because the keyboard height is fixed, so this is
  acceptable for key caps, but the strip could honour larger sizes with truncation, and Bold Text should
  switch to a heavier weight (F19 says "larger key labels with Bold Text"; `UIAccessibility.isBoldTextEnabled` is not
  read anywhere).

### Resize handle (`ResizeHandleView`)

- **P1:** `isAccessibilityElement = true` with the label "Resize keyboard", but no trait and no value: VoiceOver
  announces a static element and offers no way to resize (the drag is a `UIPanGestureRecognizer`; double-tap toggles the
  number row, which VoiceOver's double-tap activation will fire without explanation). Make it `.adjustable` with
  `accessibilityIncrement/Decrement` (taller / shorter in steps) and an `accessibilityValue` ("height 100%"), and
  an `accessibilityCustomActions` entry "toggle number row". Its 80 x 20 pt frame is below the usual 44 pt target.

### Emoji panel (`EmojiPanelView`)

What exists: cells are accessibility elements labelled with the CLDR name (`EmojiCell`, e.g. "grinning face"); the
close and tab buttons have labels.

- **P1: cell traits.** `EmojiCell` sets `isAccessibilityElement` and a label but no `.button` trait, so it reads as static text.
  Add `.button`. For skin-tone capable emoji, add `accessibilityCustomActions` for the five tones: the context menu
  (`UIContextMenuInteraction`) is a long-press gesture and is hard to trigger under VoiceOver.
- **P1: kaomoji labels** use the raw text ("^_^") as the label, which VoiceOver reads as punctuation. Give them
  spoken names or the label "kaomoji, N of M".
- **P2: tab labels** are generic ("Category 1" ... "Category 9"); use the group names (Smileys & Emotion, People & Body,
  ...). The first tab button's visible title is "ABC" but its label is "Back to keyboard": acceptable, but Voice Control
  users will say what they see ("tap ABC"); set `accessibilityUserInputLabels = ["ABC", "Back to keyboard"]`. The
  selected tab needs the `.selected` trait (not set).
- **P2: emoji search mode** (strip becomes "Search emoji", the normal keys type into an in-memory buffer): the mode change is not announced
  and the strip query/hit slots have the same activation problem as the suggestion strip.
- **P2: recents tab** glyph "🕘" is read as "clock face nine o'clock" unless the label wins; the label is set, so this is fine, but confirm.
- **P2:** cells are 44 x 44 pt (meets the target); kaomoji cells are 40 pt high.

### Whole keyboard

- **P1: no `accessibilityViewIsModal` or element ordering.** When the emoji panel covers the key area (`keysHidden`),
  the hidden `CALayer` keys are not elements today (so no leak), but once key elements exist the grid's elements
  must be removed from the accessibility tree while the panel is open, and focus moved to the panel
  (`.screenChanged`).
- **P1: theming and contrast.** `IBoardTheme.ThemeAccessibility` resolves Reduce Transparency, Increase Contrast and Bold Text
  as a pure function (M8-05 logic), but nothing in `KeyGridView`, the strip or the controller reads it or the
  `UIAccessibility` switches, and `KeyGridView` renders from `NativeThemeTokens` directly. High-contrast
  and bold behaviour is therefore absent in the UI. (The native tokens are meant to match the system keyboard, which
  itself responds to these switches; iBoard should respond too.)
- **P2: Reduce Motion** is honoured for the swipe trail fade (`SwipeTrailLayer.finish`). Other animations (alternates,
  emoji panel transitions) were not found to animate, but confirm.
- **P2: audio and haptics.** Key click uses `playInputClick()` (respects the system "Keyboard Clicks" setting only when the
  input view conforms to `UIInputViewAudioFeedback`, which `ClickInputView` does). Haptics need Full Access, so
  haptic confirmation for VoiceOver users is mostly unavailable by design; the spoken key echo has to carry the feedback.
- **P2: companion app.** SwiftUI screens use system controls; spot checks found labels on theme swatches and the pinned
  marker, and `.combine` grouping on about rows. Dynamic Type was not audited and the theme preview is hidden from
  VoiceOver (`.ignore`, label "Keyboard preview"), which is reasonable. Run the Accessibility Inspector audit.

## Suggested order of work (all in code owned by the UI agent, not changed here)

1. `KeyGridView`: per-key `UIAccessibilityElement`s with labels, `.keyboardKey`, shift value, return-key trait; globe key check.
2. `SuggestionStripView`: slot, chip and action-row elements with `.button` and `accessibilityActivate` wired to the
   existing `tapSlot` / `performSelectionAction` / `insertChip` paths.
3. Announcements: autocorrect applied / reverted, layer change, selection start; keep them free of logged text.
4. VoiceOver-aware gesture policy: disable swipe typing and flick gestures when VoiceOver is on (or offer custom actions).
5. Resize handle `.adjustable`; emoji cell `.button` + tone custom actions; tab names and `.selected`.
6. Read `UIAccessibility` switches (Bold Text, Increase Contrast, Reduce Transparency) into the render path via
   `ThemeAccessibility`.
7. Verify on a device with VoiceOver on (type a sentence, pick a suggestion, switch layers, open emoji, leave via globe),
   Voice Control, and the Accessibility Inspector audit; record results in the roadmap.

## Test ideas (not written)

- XCUITest on `iBoardUITests` with VoiceOver-equivalent queries: every key has a non-empty label and the
  `keyboardKey` trait; slots expose `.button`; element count equals key count.
- Unit test (pure): a function mapping `KeyIdentity` plus shift state and return-key kind to `(label, value, traits)` so
  the naming table can be tested in `IBoardLayout` / `IBoardUI` without UIKit.

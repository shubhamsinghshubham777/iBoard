# Onboarding and OTP setup (M6-04, M10-01)

Status: built; on-screen behaviour NOT tested (no simulator run); unit tests compile but were NOT RUN (need a simulator).

## Onboarding flow (M10-01)

`OnboardingView` (full-screen cover on first launch, re-openable from the main screen; completion stored in `@AppStorage`):

1. Turn on iBoard: Settings > General > Keyboard > Keyboards > Add New Keyboard. No public API tells an app whether a keyboard is enabled (`UITextInputMode.identifier` is not public), so the step cannot be ticked automatically.
2. Full Access explained: matrix from ROADMAP P-23 (`FullAccessMatrix`). Works without: typing, app settings (read), OTP codes (keyboard only reads), click sounds, learning kept inside the keyboard. Needs Full Access: haptics, clipboard, showing learned words in the app, sync.
3. Verification codes: links to the guided setup below.
4. Typing test field. Text stays in the field and is not stored.

Layout uses a width-capped scroll view and a wrapping chip layout; no `UIScreen.main` or idiom checks.

## OTP guided setup and self-test (M6-04)

Source: the device-verified setup in ROADMAP P-27 (iPhone 12, iOS 27.0). `OTPSetupGuide` holds the wording; `OTPSetupView` renders six steps with a tap-path "breadcrumb" per step.

1. Shortcuts > Automation > + > Automation chip > Communication > Message (or Email).
2. Condition "Message Contains" / "Subject Contains" = `code`, with a Sender (Message) or Sender/Account (Email) filter that matches the real sender exactly.
3. Automation on, Confirm Before Run off.
4. Add the iBoard action "Capture Verification Code".
5. Set the action's "Message Text" and "Sender" fields from the trigger's Message and Sender.
6. A "Running <name>" banner appears; after a phone restart open Shortcuts once or the first code is delayed.

Self-test (`OTPSelfTestView`): the user sends a message containing a code; the app polls `OTPReader.freshCodes()` once a second for up to 2 minutes and shows the first code that was not in the store when the test began. The app can read the App Group (M6-02). The code is shown on screen only; nothing is logged.

Wording not verified on device: the exact label of the "Automation" chip and the field labels in iOS 27 beyond what the owner reported; step 5 assumes the variable picker offers the trigger's Message and Sender (the owner's setup did).

## Can a `.shortcut` file carry the Message-trigger automation? (investigation)

Finding: NOT DETERMINED; the guided manual flow is the deliverable.

What was verified on this Mac (Shortcuts CLI, macOS 27):
- `shortcuts sign --mode anyone|people-who-know-me --input X --output Y` works. A hand-written plain workflow plist (one action, `app.iBoard.CaptureVerificationCodeIntent`, no trigger; `Tools/Shortcuts/make_experiment.py`) was signed into a 21.7 KB `AEA1` container.
- Signing succeeding says nothing about whether iOS accepts the file, or whether the action layout (an `AppIntentDescriptor` dictionary with team id, bundle id, intent id) matches what Shortcuts expects. The action identifier and descriptor layout are NOT verified against a real export, and the file was not imported anywhere.

What could not be checked:
- No automation could be exported: the Shortcuts library on the Mac (`~/Library/Shortcuts`) is blocked by macOS privacy protection for this agent, and exporting a shortcut from the Shortcuts GUI is outside what this task could do. `shortcuts list` does show the owner's synced "Capture Verification Code - Email" shortcut, so an iOS 27 automation saved as a shortcut does sync to the Mac, but whether its trigger travels in a shared/exported `.shortcut` is unknown.
- Historically (pre-iOS 27) personal automations cannot be shared as files, and the trigger is not part of a plain workflow file. That is background knowledge, not tested on iOS 27.

Next step if wanted (needs the owner): export the working "Capture Verification Code" automation from the Shortcuts app (share sheet > file), then inspect the file with `shortcuts sign` round trip plus `plutil -p` after stripping the AEA wrapper (signed files are encrypted/signed containers; an unsigned export may be readable). If it contains a trigger key, a template can be generated per sender; if not, the manual flow stays. Until then iBoard must not promise a one-tap import.

# App Store listing draft (M13-06). Prepared, not submitted.

Pages URL is the owner GitHub Pages site (confirm Pages is enabled).

## Metadata
- **Name (max 30):** iBoard: Private Keyboard
- **Subtitle (max 30):** Hinglish, swipe, no tracking
- **Category:** Utilities (secondary: Productivity)
- **Age rating:** 4+ (no objectionable content; no user-generated content shared)
- **Price:** Free, no in-app purchases
- **Privacy policy URL:** `https://shubhamsinghshubham777.github.io/iBoard/privacy.html`
- **Support URL:** `https://shubhamsinghshubham777.github.io/iBoard/support.html`
- **Marketing URL (optional):** `https://shubhamsinghshubham777.github.io/iBoard/`
- **Copyright:** 2026 Shubham Singh
- **Privacy label:** Data Not Collected. Tracking: No.

## Promotional text (max 170)
A free, open-source keyboard that feels like Apple's, learns your words on your device, and types Hinglish naturally. No tracking, no ads.

## Keywords (max 100 chars, comma separated)
keyboard,hinglish,swipe,private,autocorrect,hindi,themes,emoji,otp,open source,gestures,predictive

## Description
iBoard is a free, open-source keyboard for iPhone that feels like the Apple keyboard from the first tap, then quietly gets smarter. Everything happens on your device.

NATIVE FEEL
Matches the system keyboard's layout, metrics, sounds and behavior, in light and dark. Nothing surprises you.

LEARNS YOU, PRIVATELY
Suggestions and autocorrect adapt to your words and phrases. Conservative autocorrect, one-tap undo, and long-press any suggestion to forget it. Search, edit, export or erase your dictionary in the app. Incognito mode stops learning.

HINGLISH AND ENGLISH TOGETHER
Type romanized Hindi and English in the same sentence, with no layout switch.

SWIPE TYPING
Glide across letters; iBoard uses your personal dictionary to pick the word.

GESTURES
Slide the spacebar to move the cursor, Shift + space to select text, swipe the delete key to remove words with a preview, flick a key for numbers and symbols.

VERIFICATION CODES
Set up a Shortcuts automation once and your latest code appears as a chip above the keys. iBoard never reads your messages on its own.

THEMES, EMOJI AND MORE
Theme studio with colors, gradients and photo backgrounds. Emoji search in English and Hindi. Optional clipboard history. Layouts tuned for landscape and for iPhone Duo.

PRIVATE BY CONSTRUCTION
No ads, no analytics, no tracking, no data collection. The keyboard never uses the network. It works fully without Full Access. Optional extras are off by default: Full Access (haptics, clipboard history, showing your dictionary in the app) and iCloud sync, which stores an encrypted copy of your personal dictionary in your own iCloud.

OPEN SOURCE
Apache-2.0. Read the code and the data licences on GitHub.

Requires iOS 27. Enable in Settings > General > Keyboard > Keyboards > Add New Keyboard.

## What's New (1.0)
First release. A native-feeling private keyboard with personal learning, Hinglish, swipe typing, gestures, themes, emoji, verification-code chips and optional iCloud sync.

## App Review notes
```
iBoard is a custom keyboard (keyboard-service extension) plus a companion app. No account or login is required.

How to enable: Settings > General > Keyboard > Keyboards > Add New Keyboard > iBoard. Then in any text field (e.g. Notes) hold the globe key and choose iBoard. The app's first-launch onboarding repeats these steps and has a typing test field.

Guideline 4.4.1 (keyboard extensions):
- The keyboard is fully functional with Full Access OFF: typing, suggestions, autocorrect, swipe typing, gestures, emoji, themes and verification-code chips all work.
- The keyboard extension contains no network code and makes no network requests, with or without Full Access.
- RequestsOpenAccess is enabled only so the user can optionally turn on: (1) haptic feedback (iOS requires Full Access), (2) clipboard history (off by default, local only), (3) sharing the on-device dictionary and counters with the companion app via an App Group, (4) opt-in iCloud sync, which is performed by the companion app (not the extension) through the user's own private CloudKit database and is off by default.
- No keystroke logging, no collection of typed text, no ads or marketing inside the keyboard, no third-party SDKs or analytics. Privacy label: Data Not Collected.
- The keyboard does not launch other apps. The only link out is to Settings from the app.
- The keyboard offers a Next Keyboard (globe) key.

Verification codes: iBoard does not read SMS or email. The user may create their own Shortcuts automation (Message/Mail trigger) that passes text to the iBoard action "Capture Verification Code"; setup is guided in the app. A reviewer does not need this to evaluate the app.

Encryption: ITSAppUsesNonExemptEncryption = NO (only exempt system crypto, including Keychain/CloudKit).

Open source: https://github.com/shubhamsinghshubham777/iBoard (Apache-2.0).
Contact: <owner email/phone to fill in>
```

## Screenshots (owner/automation)
6.9" and 6.5" iPhone: keyboard in Notes (light/dark), suggestions strip, Hinglish typing, theme studio, dictionary manager, onboarding. Capture from the simulator once the UI is final.

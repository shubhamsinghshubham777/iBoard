# iBoard

A free, open-source (Apache-2.0), privacy-first keyboard for iOS 27 that aims to **feel exactly like the Apple keyboard
on day one** and then quietly become better: it learns your words and phrases, reads one-time codes, edits text with
fluid gestures, and types Hinglish as naturally as English, all on-device.

> **Status: early development.** There is no release, no App Store build and no screenshots yet. Most features below
> are planned, not built. See [ROADMAP.md](ROADMAP.md) for what exists today.

## Goals

1. **Native first.** Default theme, metrics, sounds and behavior match the iOS 27 system keyboard.
2. **Fast and stable** on a base iPhone 12. A dropped keystroke or crash is worse than a missing feature.
3. **Private by construction.** Offline-first; nothing leaves the device unless you turn on an opt-in feature.
4. **Genuinely smarter.** Personal learning, adaptive touch, phrase prediction, OTP codes, Hinglish.
5. **Delight.** Theme studio, translucent looks, iPhone Duo layouts.

## Honest scope

"Native feel" has limits that come from iOS itself. iBoard can match the system keyboard's layout, key metrics,
typography, colors, click sound, auto-capitalization, shift/caps-lock behavior and delete acceleration. It cannot match:

- system dictation (keyboard extensions have no microphone access);
- haptics without Full Access;
- secure text fields, phone-pad fields, or apps that opt out of custom keyboards (iOS shows the system keyboard there);
- the system's exact touch model on day one (iBoard's adaptive model has to earn it);
- possibly true see-through blur of the host app (under investigation).

## Privacy

- Core typing never uses the network. The keyboard extension makes no network calls except opt-in features
  (currently only iCloud sync, off by default).
- Typed text is never logged or persisted for diagnostics, including in debug builds.
- No analytics SDKs, no ads, no data collection.
- Designed to work without Full Access.

To report a privacy or security problem, see [SECURITY.md](SECURITY.md).

## Building

Requirements: macOS with **Xcode 27.1+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen), minimum deployment target
iOS 27.0.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # ignored by version control
# edit Config/Local.xcconfig and set DEVELOPMENT_TEAM to your Apple team ID
xcodegen generate
xcodebuild -project iBoard.xcodeproj -scheme iBoard -destination 'generic/platform=iOS Simulator' build
```

Notes:

- `project.yml` is the source of truth for `iBoard.xcodeproj`; re-run `xcodegen generate` after adding targets or
  files outside synchronized folders.
- Default identifiers are `app.iBoard` (app), `app.iBoard.keyboard` (extension) and `group.app.iBoard` (App Group).
  If you cannot sign those, uncomment and change `IBOARD_BUNDLE_PREFIX` and `IBOARD_APP_GROUP` in
  `Config/Local.xcconfig`.
- After installing, enable the keyboard in Settings > General > Keyboard > Keyboards.

## Repository layout

- `iBoard/` companion app (SwiftUI); `iBoardKeyboard/` keyboard extension (UIKit)
- `Packages/` Swift packages: `IBoardCore`, `IBoardEngine`, `IBoardLayout`, `IBoardOTP`, `IBoardTheme`, `IBoardUI`
- `Config/` shared and local build settings
- [ROADMAP.md](ROADMAP.md) plan, locked decisions, performance budgets and progress log

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). iBoard is not affiliated with or endorsed by
Apple Inc.

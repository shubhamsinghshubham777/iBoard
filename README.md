# iBoard

A free, open-source (Apache-2.0), privacy-first keyboard for iOS 27 that aims to **feel exactly like the Apple keyboard
on day one** and then quietly become better: it learns your words and phrases, reads one-time codes, edits text with
fluid gestures, and types Hinglish as naturally as English, all on-device.

> **Status: pre-release (1.0 in preparation).** The keyboard and companion app build and run: native-look layout,
> English and Hinglish language data, autocorrect, personal learning, swipe typing, one-time-code and personal-info
> chips, emoji panel, clipboard history, gestures, themes, iPhone Duo layouts and opt-in iCloud sync. Real-device
> verification is still in progress and there is no App Store build yet. See [ROADMAP.md](ROADMAP.md) for the exact
> state and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it fits together. Privacy policy and support pages
> live in [docs/site](docs/site) (static, GitHub Pages ready); the App Store text is in
> [docs/APP_STORE_LISTING.md](docs/APP_STORE_LISTING.md).

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
  (currently only iCloud sync, performed by the app, off by default).
- Typed text is never logged or persisted for diagnostics, including in debug builds.
- No analytics SDKs, no ads, no data collection.
- Works without Full Access. With it on you additionally get haptics, clipboard history, the dictionary shown in the
  app, and iCloud sync (see [docs/site/privacy.html](docs/site/privacy.html)).

To report a privacy or security problem, see [SECURITY.md](SECURITY.md).

## Building

Requirements: macOS with **Xcode 27.1+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen), minimum deployment target
iOS 27.0.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # ignored by version control
# edit Config/Local.xcconfig and set DEVELOPMENT_TEAM to your Apple team ID
xcodegen generate
scripts/build.sh                                         # app + keyboard, iOS Simulator
```

`scripts/build.sh` creates `Config/Local.xcconfig` from the example if it is missing and re-runs `xcodegen` when
`project.yml` is newer than the project. The raw equivalent is
`xcodebuild -project iBoard.xcodeproj -scheme iBoard -destination 'generic/platform=iOS Simulator' build`.

Notes:

- `project.yml` is the source of truth for `iBoard.xcodeproj`; re-run `xcodegen generate` after adding source files
  or targets.
- Default identifiers are `app.iBoard` (app), `app.iBoard.keyboard` (extension) and `group.app.iBoard` (App Group).
  If you cannot sign those, uncomment and change `IBOARD_BUNDLE_PREFIX` and `IBOARD_APP_GROUP` in
  `Config/Local.xcconfig`.
- After installing, enable the keyboard in Settings > General > Keyboard > Keyboards.

## Testing

```sh
scripts/test.sh                  # privacy audit + swift test (every package and Tools/LexiconBuilder) + xcodebuild tests
scripts/test.sh --packages-only  # no simulator needed
scripts/test.sh --xcode-only --no-ui
scripts/audit-privacy.sh         # static check: no logging, network, analytics or stray persistence of typed text
# enforce the performance budgets (release build):
cd Packages/IBoardEngine && swift test -c release -Xswiftc -enable-testing --filter Benchmarks
```

Timing and benchmark tests assert the ROADMAP section 6 budgets only in optimised builds. In a debug `swift test`
they print their numbers and never fail, because a loaded host machine is not a phone. Simulator and macOS timings are
never device numbers.

## Repository layout

- `iBoard/` companion app (SwiftUI); `iBoardKeyboard/` keyboard extension (UIKit)
- `Packages/` Swift packages, each with its own tests (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):
  `IBoardCore` (settings, perf signposts, app-to-keyboard commands), `IBoardLayout` (key geometry, Duo split logic),
  `IBoardEngine` (lexicon, tap and swipe decoding, autocorrect, personal model), `IBoardUI` (UIKit keyboard views and
  typing coordinator), `IBoardOTP`, `IBoardTheme`, `IBoardEmoji`, `IBoardSync` (iCloud sync model and CloudKit store, used by the app only)
- `Tools/` `LexiconBuilder` (binary lexicon and LM builder), `HinglishData` (Hinglish data pipeline)
- `Data/english/` (CC BY 4.0 with SCOWL notices) and `Data/hinglish/` (CC BY-SA 4.0) built lexicons and language models
- `Config/` shared and local build settings; `project.yml` is the XcodeGen spec
- `scripts/` `build.sh`, `test.sh`, `audit-privacy.sh`, `bootstrap-agent-skills.sh`
- `docs/` design notes, measured platform facts, data sources, `site/` (privacy and support pages), release checklist
- [ROADMAP.md](ROADMAP.md) plan, locked decisions, performance budgets and progress log

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). iBoard is not affiliated with or endorsed by
Apple Inc.

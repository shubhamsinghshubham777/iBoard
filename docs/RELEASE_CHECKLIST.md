# Release checklist for the owner (M13-05 TestFlight, M13-06 submission). Prepared, not executed.

## Before upload
- [ ] All Duo/real-device passes done (M11-05, M1-09 perf gates on iPhone 12); owner bug list retested on phone.
- [ ] Merge SYNC work; re-run `scripts/audit-privacy.sh`; update entitlements, manifests, and privacy label if iCloud is enabled.
- [ ] Reconcile Full Access copy (docs/agent-reports/app.md finding 1).
- [ ] Set a real `IBOARD_BUNDLE_PREFIX`/`IBOARD_APP_GROUP` and team in Config/Local.xcconfig; register the App Group and App IDs (app + keyboard) in the developer portal.
- [ ] Bump version/build; Release archive: `xcodebuild archive -scheme iBoard -configuration Release`.

## M13-05 TestFlight
- [ ] Create the app record in App Store Connect (name, bundle ID, primary language).
- [ ] Upload the archive (Xcode Organizer or `xcrun altool`/`asc`); fix any processing/privacy-manifest emails.
- [ ] Export compliance: already set to NO via Info.plist key.
- [ ] Add internal testers; fill beta app description, feedback email, and review notes (how to enable the keyboard, the Shortcuts OTP flow).
- [ ] Beta App Review for external testers; collect feedback for a week.

## M13-06 App Store + public repo
- [ ] Privacy policy URL (publish docs/PRIVACY.md), support URL.
- [ ] Privacy label: Data Not Collected.
- [ ] Screenshots: 6.9" and 6.5" iPhone; app description, keywords, category, age rating.
- [ ] Review notes + contact info; demo steps for keyboard enablement.
- [ ] Submit for review; choose release mode.
- [ ] Public repo: confirm Apache-2.0 LICENSE, README, CONTRIBUTING, third-party licenses; scrub secrets/UDIDs (docs/HANDOFF.md has device UDIDs); tag the release; announce.

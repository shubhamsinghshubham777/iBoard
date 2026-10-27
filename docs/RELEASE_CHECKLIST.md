# Release checklist for the owner (M13-05 TestFlight, M13-06 submission). Prepared, not executed.

## Before upload
- [ ] All Duo/real-device passes done (M11-05, M1-09 perf gates on iPhone 12); owner bug list retested on phone.
- [x] SYNC merged; container `iCloud.app.iBoard` and entitlement are in `iBoard/iBoard.entitlements`. Re-run `scripts/audit-privacy.sh` before each upload.
- [x] Full Access copy reconciled (RequestsOpenAccess true, optional features listed in the policy, About and review notes).
- [ ] Set a real `IBOARD_BUNDLE_PREFIX`/`IBOARD_APP_GROUP` and team in Config/Local.xcconfig; register the App Group and App IDs (app + keyboard) in the developer portal.
- [ ] Bump version/build; Release archive: `xcodebuild archive -scheme iBoard -configuration Release`.

## M13-05 TestFlight
- [ ] Create the app record in App Store Connect (name, bundle ID, primary language).
- [ ] Upload the archive (Xcode Organizer or `xcrun altool`/`asc`); fix any processing/privacy-manifest emails.
- [ ] Export compliance: already set to NO via Info.plist key.
- [ ] Add internal testers; fill beta app description, feedback email, and review notes (how to enable the keyboard, the Shortcuts OTP flow).
- [ ] Beta App Review for external testers; collect feedback for a week.

## M13-06 App Store + public repo
- [ ] Enable GitHub Pages from `docs/site` (branch main, /docs is not it: use a Pages workflow or copy `docs/site`), then set privacy/support URLs. Text is ready in `docs/site`.
- [ ] Privacy label: Data Not Collected.
- [ ] Screenshots: 6.9" and 6.5" iPhone. Name, subtitle, description, keywords, category, age rating, What's New are drafted in `docs/APP_STORE_LISTING.md`.
- [ ] Review notes drafted in `docs/APP_STORE_LISTING.md` (4.4.1 explanation); add contact info.
- [ ] Deploy the CloudKit schema for `iCloud.app.iBoard` to Production in CloudKit Dashboard before release (entitlement already present).
- [ ] Submit for review; choose release mode.
- [ ] Public repo: confirm Apache-2.0 LICENSE, README, CONTRIBUTING, third-party licenses; scrub secrets/UDIDs (docs/HANDOFF.md has device UDIDs); tag the release; announce.
- [ ] Companion app on iPhone Duo / iPad: verified compact layout on the Duo outer-display simulator (see docs/agent-reports/appduo3.md); owner to eyeball on hardware.

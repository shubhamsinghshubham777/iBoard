# APP agent report (M13-04, M11-06, M13-05/06 prep)

## M13-04 App Review audit: [~]
Method: source/manifest review against the `app-store-review` checklist (skill not installed locally; applied from guideline knowledge). NOT validated by an App Store Connect upload.

Fixed (safe):
- Added `ITSAppUsesNonExemptEncryption = NO` (project.yml `INFOPLIST_KEY_`, verified in built Info.plist). No custom crypto; avoids the export-compliance prompt on every upload. (Owner: confirm no HTTPS/CloudKit-only use changes this; CloudKit uses exempt system crypto.)

Verified OK:
- Both `PrivacyInfo.xcprivacy`: no tracking, no domains, no collected data; UserDefaults reasons CA92.1 + 1C8F.1. Required-reason API grep of app sources found nothing else (see docs/PRIVACY.md).
- Entitlements: only App Group in app + extension. (M12 sync agent will add iCloud/CloudKit: must update entitlements, privacy labels, and re-audit.)
- Keyboard `RequestsOpenAccess=false`, no network code in the extension (4.4.1). No usage-description strings needed (PhotosPicker is out-of-process).
- iPhone-only (`TARGETED_DEVICE_FAMILY=1`); no private APIs seen in iBoard/.

Open findings (owner/doc):
1. Guideline 4.4.1 / 5.1.1: keyboard must work without Full Access and say what Full Access does. Setup text says Full Access is "needed only for haptics and opt-in features": confirm wording matches `RequestsOpenAccess=false` (with false, Full Access is never requested; haptics via UIFeedbackGenerator need it). Reconcile copy before TestFlight.
2. Privacy label in App Store Connect must be "Data Not Collected"; if M12 iCloud sync ships, CloudKit private DB is still not "collected" by developer, but review the answers then.
3. Metadata needs: privacy policy URL (host docs/PRIVACY.md publicly), support URL, app description not mentioning other platforms, screenshots (6.9" and 6.5"), age rating questionnaire, keyboard-specific review notes (how to enable the keyboard; demo OTP flow via Shortcuts).
4. Review notes should explain the Shortcuts-based verification-code feature (reads no SMS; user-created automation).
5. Third-party data licenses (CC BY-SA 4.0 Hinglish, SCOWL, Leipzig) must be shown in-app: About view exists; verify attribution text complete (not re-checked here).
6. Re-run `scripts/audit-privacy.sh` after SYNC merges.

## M11-06 Companion app Duo pass: [~]
Audit of iBoard/*.swift for resizability: no UIScreen, userInterfaceIdiom, UIDevice, orientation, or safe-area-inset use; fixed frames only on small icons/theme preview chips; root uses NavigationStack in List (adapts to any width).
Fixed: ThemeStudioView picked `connectedScenes.first` for photo scaling; now prefers the foreground-active scene (multi-scene/Split View safe).
Remaining / suggestions (not done, behaviour change): root could use `NavigationSplitView` for the inner-display/wide windows; ThemeStudio preview could be a side pane when wide; Duo hinge/fold avoidance untested. Not run on a Duo simulator (axe cannot drive it), so status stays [~].

## Verification
`scripts/build.sh` succeeded; see commit for test run.

## M13-05/06 owner checklist
See docs/RELEASE_CHECKLIST.md (prepared, not executed).

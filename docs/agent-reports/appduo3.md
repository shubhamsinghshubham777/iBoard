# APPDUO3 report (2026-10-27)

## Findings (code audit, no app code changes needed)
- Resizability: no UIScreen/interfaceOrientation/userInterfaceIdiom/UIDevice use; layout driven by horizontalSizeClass (sidebar + detail when regular, stack when compact); all orientations enabled; scene manifest generated; FlowLayout wraps at any width/Dynamic Type.
- Accessibility: icons carry labels, decorative previews hidden with a summary label, text uses semantic fonts (only the decorative theme preview uses fixed sizes).
- Privacy manifest (UserDefaults CA92.1/1C8F.1, FileTimestamp C617.1, no tracking, no collected data) matches the code; ITSAppUsesNonExemptEncryption NO; entitlements = app group + iCloud/CloudKit.
- Docs: RELEASE_CHECKLIST (iCloud/sync items were stale) and APP_STORE_LISTING (placeholder URLs) updated.

## Verified
- scripts/build.sh succeeds.
- `xcrun simctl io <udid> screenshot` is NOT black (the Device Hub screenshot was). On the iPhone Duo simulator (E295B4EA...) the outer display renders onboarding and the home list correctly, content avoiding the right-side status rail; iPhone 18 Pro onboarding renders correctly.

## Unverified
- Inner (open) Duo display / NavigationSplitView sidebar layout, hinge and poses, Split View/Stage Manager resizing.
- VoiceOver traversal, Dynamic Type at AX sizes, Switch/Voice Control (read from code only).
- App Review audit is a source/doc review, not an upload validation.
- scripts/test.sh --no-ui exceeded 10 minutes in my shell (background run); result not confirmed by me.

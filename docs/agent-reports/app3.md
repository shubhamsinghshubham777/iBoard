# APP3 report (2026-10-27)

## Done
- App icon: the asset catalog had no image files. Created an original icon (keycaps + swipe curve) in light, dark and tinted 1024 px variants (ImageMagick); Contents.json updated; build compiles it.
- Privacy: re-ran `scripts/audit-privacy.sh` (OK). Found a real gap: `DictionaryStore.swift` reads a file modification date, so `iBoard/PrivacyInfo.xcprivacy` now declares FileTimestamp C617.1. Keyboard manifest unchanged (no such use). `docs/PRIVACY.md` updated. Label stays Data Not Collected.
- `docs/site/` (index, privacy, support, style.css, .nojekyll): static, GitHub Pages ready, covers optional Full Access features and opt-in iCloud sync.
- `docs/APP_STORE_LISTING.md`: name, subtitle, keywords, description, What's New, review notes with the 4.4.1 explanation.
- About screen: Data attributions now lists the real bundled data (SCOWL, Leipzig, Hinglish CC BY-SA 4.0 incl. Dakshina, Unicode/CLDR); added build number, Apple non-affiliation note, repo link.
- NOTICE fixed (stale placeholder-data entry and "not yet bundled" text removed, duplicate line removed). README status/layout, SECURITY, CHANGELOG (new), RELEASE_CHECKLIST updated. MARKETING_VERSION 1.0.0, build 1.
- `scripts/build.sh` succeeds.

## Open / owner
- Privacy page claims (clipboard code chip, Contacts via system lexicon) are written from docs, not code-verified; check against actual keyboard behaviour.
- Repo URL `shubhamsinghshubham777/iBoard` is assumed (Q-02); confirm.
- iCloud entitlement + container are not in `iBoard.entitlements`; sync cannot work until added (checklist updated).
- Review-note contact info, enabling Pages, screenshots: owner.
- Icon is clean but simple; a designer pass is optional. FileTimestamp reason code not validated by an upload.

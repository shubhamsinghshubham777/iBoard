# DECOUPLE report: sync/CloudKit removed from the keyboard extension

## Change
- New package `Packages/IBoardPersonalSync` (depends on IBoardEngine + IBoardSync, app-only). `PersonalSyncAdapter.swift` and `PersonalSyncAdapterTests.swift` moved there with `git mv` (5 tests, all pass).
- `Packages/IBoardEngine/Package.swift` no longer depends on IBoardSync. IBoardSync stays dependency-free.
- `project.yml`: `IBoardPersonalSync` package added; only the `iBoard` app target links IBoardSync + IBoardPersonalSync. `iBoard/SyncSettingsView.swift` imports it. Project regenerated with xcodegen.
- `scripts/audit-privacy.allowlist`: PersonalSyncAdapter WRITE entry re-pointed to the new path.
- `scripts/audit-privacy.sh`: new `EXT-SYNC` check, three layers: (1) iBoardKeyboard deps in project.yml, (2) no non-app package.swift depends on a sync package, (3) built extension binary (`DERIVED_DATA` or `EXT_BINARY=`) must not link CloudKit or contain IBoardSync/IBoardPersonalSync symbols. Verified it fails on the old binary and passes on the new one.

## Proof (Release, iphonesimulator, extension binary `iBoardKeyboard.appex/iBoardKeyboard`)
| | before (HEAD) | after |
|---|---|---|
| size | 9,937,200 B | 9,159,824 B (-777,376 B, -7.8%) |
| `otool -L` CloudKit lines | 2 | 0 |
| `nm` IBoardSync symbols | 1132 | 0 |
| `nm` PersonalSync symbols | 273 | 0 |

The app binary still links CloudKit and carries the sync code (1134 IBoardSync symbols), as intended.

## Verification
`scripts/build.sh` (Debug) and `scripts/test.sh --no-ui` pass; test.sh picks up the new package automatically.

# Privacy manifests and audit (M13-03)

Files: `iBoard/PrivacyInfo.xcprivacy` (app) and `iBoardKeyboard/PrivacyInfo.xcprivacy` (keyboard extension).
Both declare: no tracking, no tracking domains, no collected data types.

## Required-reason API audit (source at 2026-10-27)

Searched `iBoard/`, `iBoardKeyboard/`, `Packages/*/Sources` (excluding tests) for:

| Category | Found | Declared |
|---|---|---|
| UserDefaults (`NSPrivacyAccessedAPICategoryUserDefaults`) | Yes: `Settings.swift` (IBoardCore), `DebugOverlay.swift` (keyboard), and the new `OTPStore` (App Group suite) | CA92.1 (app-own data) and 1C8F.1 (App Group shared with the app's own extension) in both manifests |
| File timestamp (`...FileTimestamp`) | None found (no creationDate/modificationDate/stat) | not declared |
| System boot time (`...SystemBootTime`) | None found (no `systemUptime`, `mach_absolute_time`, `ProcessInfo.systemUptime`) | not declared |
| Disk space (`...DiskSpace`) | None found (no `volumeAvailableCapacity`, `attributesOfFileSystem`) | not declared |
| Active keyboards | None found | not declared |

Note: `task_info(TASK_VM_INFO)` in `Perf.swift` (memory footprint) is not a required-reason category.

Caveat: reason codes are from Apple's documented list as recalled; not validated by an App Store Connect upload (NOT TESTED).

## Re-audit triggers
Any new use of file timestamps, boot time, disk space, or third-party SDKs (none vendored) requires updating
both manifests. Typed text is never logged or persisted; nothing is collected or transmitted.

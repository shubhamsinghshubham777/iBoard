# Security Policy

iBoard is a keyboard, so it can see everything a user types. We treat any issue that could expose, retain or transmit
typed text as a security issue.

## Supported versions

iBoard is in early development and has no releases yet. Only the latest `main` is supported.

## Reporting a vulnerability

Please report privately using GitHub's **private vulnerability reporting**: open this repository's **Security** tab
and choose **Report a vulnerability** (a GitHub security advisory). Do not open a public issue or pull request for
security problems.

Include what you found, how to reproduce it, the affected version or commit, and the impact. We will acknowledge the
report as soon as we can and keep you updated while we fix it. This is a volunteer project, so we cannot promise
fixed response times.

## In scope

- Anything that logs, persists, caches or transmits typed text, contacts, clipboard contents or OTP codes
  unexpectedly, including in debug builds.
- Network access from the keyboard extension outside documented opt-in features.
- Leaks through the shared App Group container, pasteboard, backups, crash reports or system logs.
- Learned-data handling: the on-device store, import/export files and iCloud sync (when it exists).
- Bypassing Full Access boundaries or secure-field behavior.
- Vulnerabilities in build or release scripts, or in vendored dependencies.

## Out of scope

- Behavior of iOS itself, or of other keyboards and apps.
- Issues requiring a jailbroken or already-compromised device.
- Missing features that the roadmap lists as not yet built.

## Disclosure

We prefer coordinated disclosure: please give us a reasonable time to fix the issue before publishing details.

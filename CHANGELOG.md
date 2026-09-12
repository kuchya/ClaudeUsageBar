# Changelog

All notable changes to **ClaudeUsageBar** are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.2.1](https://github.com/kuchya/ClaudeUsageBar/releases/tag/v1.2.1) — 2026-09-12

### Reverted
- **In-app OAuth token refresh (from v1.2.0).** Writing the refreshed token back
  into Claude Code's Keychain item required authorization on every refresh, which
  triggered **repeated macOS Keychain permission dialogs**. The app is read-only
  again: it reads the existing token but does not renew it. When the token expires,
  run Claude Code once and the app recovers automatically on the next poll.

### Kept
- The launch-error `-10825` fix from v1.2.0 (pinned deployment target) is retained.

## [1.2.0](https://github.com/kuchya/ClaudeUsageBar/releases/tag/v1.2.0) — 2026-08-17

### Added
- **In-app OAuth token refresh.** The app now renews its own access token
  (`POST https://platform.claude.com/v1/oauth/token`) when the token is expired,
  about to expire, or the usage API returns `401` — no more opening a terminal to
  run Claude Code. New tokens are written back into the same Keychain item via a
  value-only update, so Claude Code stays authorized and in sync with the rotated
  refresh token. Side effect: far fewer Keychain permission prompts.

### Fixed
- **Launch error `-10825`** (*"You can't use this version of the application with
  this version of macOS"*). Newer Swift toolchains stamped the binary's minimum-OS
  higher than the running macOS; the build now pins the deployment target to
  macOS 12. The prebuilt zip is rebuilt correctly.

## [1.1.1](https://github.com/kuchya/ClaudeUsageBar/releases/tag/v1.1.1) — 2026-08-16

### Fixed
- **Mini gauge invisible on dark menu bars.** The gauge is a rendered bitmap, so the
  adaptive `labelColor` used for the normal (<70%) fill baked to black and vanished.
  It now uses appearance-independent colors: 🟢 green → 🟠 orange (≥70%) → 🔴 red
  (≥90%) fills over a fixed neutral-gray track.

## [1.1.0](https://github.com/kuchya/ClaudeUsageBar/releases/tag/v1.1.0) — 2026-08-16

### Changed
- **Rate-limit resilient.** Polls the usage endpoint every ~5 min instead of every
  60s, honours the `Retry-After` header, and applies exponential backoff (capped at
  30 min) on `429`/network errors. Countdown timers still tick every minute locally
  (no network) because `resets_at` is absolute.

### Added
- **Persistent last reading.** The last successful values are cached to disk and
  restored on launch, so the bar never blanks out — even a rate-limited or offline
  cold start shows the last known numbers with an "Updated N ago" freshness note.

### Fixed
- **Reset-timer legibility in light mode.** The countdown used a translucent color
  that washed out on light menu bars; it now uses an opaque, adaptive color.

## [1.0.0](https://github.com/kuchya/ClaudeUsageBar/releases/tag/v1.0.0) — 2026-08-16

### Added
- Initial release. Native macOS menu-bar app showing live Claude **session (5h)**
  and **weekly (7d)** usage percentages with inline reset countdowns.
- Color-coded thresholds, mini dual-bar gauge, threshold notifications
  (80% / 90% / 100%), and a Start-at-Login toggle.
- Reuses the existing Claude Code Keychain login — no separate sign-in, no secrets,
  no telemetry. Pure Swift + AppKit, no dependencies.

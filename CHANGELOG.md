# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-03-08

### Added

- Collapsible cards with persistent state (localStorage). Each card shows
  a summary when collapsed (e.g. bonus points, countdown, session status).
- "Next Spend" card with spend simulation computed from cached profile data.
  Automatically updates when stats are refreshed or settings change — no
  separate API call needed.
- Auto-refresh toggle and configurable interval (default: 5 minutes).
  Periodically fetches fresh stats from MAM without manual interaction.
- Vault page scraping during refresh and after spend cycles. Pot amount,
  max, start date, and user contribution are kept up to date.

### Fixed

- All purchases (VIP, wedge, vault, upload) now respect the points buffer.
  Previously only upload checked the buffer; VIP, wedge, and vault could
  spend below it.
- Upload GB calculation no longer needs block-size rounding — MAM API
  accepts any integer amount.

### Changed

- Removed standalone "Dry Run" button. Simulation is now always visible
  in the "Next Spend" card, computed from last-known profile data.
- "Spend Now" button moved to the "Next Spend" card.
- Vault card moved above "Next Spend" card in layout.
- Post-spend cycle always re-fetches profile for updated balance and ratio.

## [0.1.0] - 2026-03-07

### Added

- Initial release.
- Background spender with configurable spend interval.
- Auto VIP top-off when expiry falls below 90 days.
- Freeleech wedge purchasing (off / before upload / FL-only modes).
- Upload credit purchasing with configurable minimum and points buffer.
- Millionaire's Vault support (off / once per pot / daily) via browser
  session cookie (mbsc) with automatic rotation and expiry detection.
- Web UI with stats, vault, spend history, and settings management.
- Profile page scraping for points/hour and seeding stats.
- Browser session (mbsc) keepalive every 4 hours to prevent expiry.
- Spend history with 90-day rolling window.
- Points history (rolling 48 entries) for rate calculation.
- Optional HTTP Basic Auth via `FORAGER_USER` / `FORAGER_PASS`.
- CORS support on all endpoints.
- Test suite (shunit2) with 31 unit and integration tests including
  simulation coverage for buffer enforcement across all purchase types.

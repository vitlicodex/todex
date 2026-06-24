# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses semantic versioning after the first tagged release.

## [Unreleased]

### Added

- Native macOS menu bar token monitor.
- Always-visible `TODEX` menu bar title.
- Launch control window with an Open Menu fallback for crowded menu bars.
- Local Codex session log token counting.
- Persistent day, week, and month usage log.
- Daily Codex project token breakdown.
- Optional OpenAI Usage API cost monitoring.
- Encrypted local API key vault with device-owner authentication.
- Codex permission monitoring with policy presets.
- Local help window with bundled documentation.
- Custom macOS app icon with a reproducible generator.
- Standalone SwiftPM test runner for core monitoring logic.

### Changed

- Reports menu now shows compact source file and folder labels instead of full-width paths.

### Security

- Vault file ownership, permissions, and symlink validation.
- Private state/report writes now reject symlink destinations and overly broad permissions.
- Parser limits for large or deeply nested local files.
- Codex session parser skips non-token lines before UTF-8 decoding.
- Secret redaction for logs and API error bodies.
- Private file permissions for stored state, settings, reports, and logs.

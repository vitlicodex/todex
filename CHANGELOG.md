# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses semantic versioning after the first tagged release.

## [Unreleased]

### Added

- Native macOS menu bar token monitor.
- Launch control window with an Open Menu fallback for crowded menu bars.
- Local Codex session log token counting.
- Optional OpenAI Usage API cost monitoring.
- Encrypted local API key vault with device-owner authentication.
- Codex permission monitoring with policy presets.
- Local help window with bundled documentation.
- Custom macOS app icon with a reproducible generator.
- Standalone SwiftPM test runner for core monitoring logic.

### Security

- Vault file ownership, permissions, and symlink validation.
- Parser limits for large or deeply nested local files.
- Secret redaction for logs and API error bodies.
- Private file permissions for stored state, settings, reports, and logs.

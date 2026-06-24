# Security Policy

## Supported Versions

Security fixes are prepared for the latest commit on `main`.

## Reporting a Vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub private vulnerability reporting when it is enabled for the repository. If that is not available, open a minimal public issue that says a private security report is needed, without exploit details, keys, logs, screenshots, or private paths.

## Security Model

TODEX is a local-first macOS menu bar app.

- Token usage data stays on the local machine unless the user explicitly enables the OpenAI Usage API source.
- The OpenAI API key is stored in a local encrypted vault, not in settings, logs, reports, or process arguments.
- Unlocking the vault requires the local encryption password plus macOS device-owner authentication.
- Reports contain numeric usage statistics and technical metadata only.
- Raw Codex session files can contain prompt text. The app warns before opening raw sources.

## Known Boundaries

- macOS device-owner authentication gates vault decryption. It does not make a process already running as the same macOS user impossible to inspect.
- A weak local encryption password can still be attacked offline if an attacker obtains the encrypted vault.
- Ad-hoc builds are suitable for local development. Public releases should use Developer ID signing, hardened runtime, and notarization.

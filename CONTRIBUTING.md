# Contributing

Thanks for considering a contribution.

## Development Setup

Requirements:

- macOS 13 or newer
- Xcode command line tools
- Swift 6 compatible toolchain

Run the checks:

```bash
swift build
Scripts/test.sh
Scripts/make-app-bundle.sh
```

Install a local app bundle:

```bash
Scripts/install-app.sh
open "$HOME/Applications/TODEX.app"
```

## Pull Request Guidelines

- Keep changes focused.
- Do not add prompt contents, screenshots with private data, local machine paths, API keys, or generated build products.
- Add or update tests for monitoring, parsing, storage, or security behavior.
- Keep user-facing documentation in English.
- Prefer native macOS APIs and low-resource background behavior.

## Code Style

- Use clear Swift names and small types.
- Keep AppKit UI code separate from monitoring logic.
- Keep local privacy guarantees explicit in code and docs.
- Avoid adding third-party dependencies unless they remove real complexity.

## Security Changes

Security-sensitive changes should include a short explanation of the threat model in the pull request body.

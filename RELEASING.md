# Releasing

This project currently supports local ad-hoc development builds and installable app bundles.

## Local Release Build

```bash
Scripts/test.sh
Scripts/make-app-bundle.sh
codesign --verify --deep --strict .build/CodexTokenMenuBar.app
```

On Apple Silicon Macs, the bundle script builds a native `arm64` release binary.

## Public Release Checklist

- Run `Scripts/test.sh`.
- Regenerate help screenshots with `swift Scripts/generate-help-images.swift`.
- Build the app bundle with `Scripts/make-app-bundle.sh`.
- Verify no local paths, private data, build products, logs, or API keys are included.
- Sign with Developer ID.
- Enable hardened runtime.
- Notarize with Apple.
- Attach a zipped app bundle to a GitHub release.

## Current Signing

The repository scripts use ad-hoc signing for local development. Public binary distribution should use Developer ID signing and notarization.

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/.build/CodexTokenMenuBar.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/Codex Token Menu Bar.app"

cd "$ROOT_DIR"

Scripts/make-app-bundle.sh >/dev/null

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"

xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
codesign --force --deep --sign - "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"

echo "$TARGET_APP"

#!/bin/bash
# Assembles XCodeVault.app from SwiftPM build products (ADR-0003: SwiftPM is the build system of
# record; the .app is script-assembled). Optionally signs inside-out with Developer ID.
#
# Usage: scripts/bundle-app.sh [--release] [--sign "Developer ID Application: Name (TEAMID)"] [--team TEAMID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=debug; SIGN=""; TEAM=""
while [ $# -gt 0 ]; do case "$1" in
  --release) CONFIG=release;; --sign) SIGN="$2"; shift;; --team) TEAM="$2"; shift;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
if [ -n "$SIGN" ] && [ -z "$TEAM" ]; then TEAM=$(echo "$SIGN" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/'); fi

cd "$ROOT"
if [ -n "$TEAM" ]; then
  # Bake the client code-signing requirement's team id into the helper before building.
  sed -i '' "s/let teamID = \"TEAMID_PLACEHOLDER\"/let teamID = \"$TEAM\"/" Sources/XCodeVaultHelper/main.swift
  trap 'git checkout -- Sources/XCodeVaultHelper/main.swift' EXIT
fi
swift build -c "$CONFIG" --product XCodeVault --product xcodevaultctl --product xcodevault-helper
BIN="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/XCodeVault.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/XCodeVault" "$APP/Contents/MacOS/XCodeVault"
cp "$BIN/xcodevaultctl" "$APP/Contents/MacOS/xcodevaultctl"
cp "$BIN/xcodevault-helper" "$APP/Contents/MacOS/xcodevault-helper"
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
cp Resources/LaunchDaemons/com.xcodevault.helper.plist "$APP/Contents/Library/LaunchDaemons/"
# SwiftPM resource bundles (none for the app today); strip quarantine (Apple requirement before signing).
xattr -cr "$APP"
if [ -n "$SIGN" ]; then
  # Inside-out: helper, CLI, then the app. Hardened runtime, timestamps, no library-validation opt-out.
  codesign --force --options runtime --timestamp --identifier com.xcodevault.helper --sign "$SIGN" "$APP/Contents/MacOS/xcodevault-helper"
  codesign --force --options runtime --timestamp --identifier com.xcodevault.xcodevaultctl --sign "$SIGN" "$APP/Contents/MacOS/xcodevaultctl"
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "note: unsigned bundle; the helper refuses connections without a team id (by design)."
fi
echo "built $APP"

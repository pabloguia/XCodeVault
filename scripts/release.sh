#!/bin/bash
# Release pipeline (M5): signed bundle → notarize → staple → dmg. Requires a Developer ID
# Application certificate in the keychain and a notarytool keychain profile.
#
# Usage: scripts/release.sh --sign "Developer ID Application: Name (TEAMID)" --profile <notarytool-profile> [--version X.Y.Z]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN=""; PROFILE=""; VERSION="$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/XCodeVaultCore/Scan/ScanReport.swift")"
while [ $# -gt 0 ]; do case "$1" in
  --sign) SIGN="$2"; shift;; --profile) PROFILE="$2"; shift;; --version) VERSION="$2"; shift;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
[ -n "$SIGN" ] && [ -n "$PROFILE" ] || { echo "need --sign and --profile"; exit 2; }
# An empty VERSION is not caught by `set -u` — the variable is set, just empty — and the run would
# go on to build, notarize and publish `XCodeVault-.dmg`, reporting success.
[ -n "$VERSION" ] || { echo "refusing: could not determine the version from ScanReport.swift"; exit 2; }
cd "$ROOT"
swift test 2>&1 | tail -3
scripts/bundle-app.sh --release --sign "$SIGN"
APP="$ROOT/dist/XCodeVault.app"
DMG="$ROOT/dist/XCodeVault-$VERSION.dmg"
rm -f "$DMG"
# Two passes, and the order is the whole point. An earlier version built the DMG from `$APP` and
# then stapled `$APP` afterwards — the copy OUTSIDE the DMG — so the app a user dragged out of the
# shipped image carried no ticket and first launch depended on an online Gatekeeper check.
# Staple the app FIRST, then package it, then notarize and staple the container (research F7).
ZIP="$ROOT/dist/XCodeVault-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
# Only now does the app inside the image carry its ticket.
hdiutil create -quiet -volname "XCodeVault" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "release artifacts in dist/: $(basename "$DMG") (+ .sha256). Update the Homebrew cask sha256 in packaging/homebrew/xcodevault.rb."

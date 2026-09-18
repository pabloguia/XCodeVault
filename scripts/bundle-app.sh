#!/bin/bash
# Assembles XCodeVault.app from SwiftPM build products (ADR-0003: SwiftPM is the build system of
# record; the .app is script-assembled). Optionally signs inside-out with Developer ID.
#
# Usage: scripts/bundle-app.sh [--release] [--sign "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--with-helper]
#
# `--with-helper` is off by default, and deliberately. Nothing in the shipped code connects to the
# privileged helper — no NSXPCConnection anywhere in the app or the CLI — so bundling it, together
# with its LaunchDaemon plist, offered the user a root Mach service in the global bootstrap
# namespace in exchange for no functionality at all. That is attack surface with no benefit, and it
# was reachable because the cask told people to enable it. Bundle it when a client exists.
#
# **Gate on this flag, not a backlog.** These are known and deliberately unfixed while nothing can
# reach the helper; every one of them becomes live the moment this flag is used in a release:
#   - the cleanup verb validates only the final path component, never the intermediate ones, and
#     checks the target's owner but not its mode (a root-owned but group-writable target is enough);
#   - `isMountPoint` fails *open* in that same verb: a getattrlist error reads as "not a mount point";
#   - the cleanup verb has no in-use check: it deletes the CoreSimulator dyld and Cryptex caches
#     regardless of whether a simulator, `simctl` or `xcodebuild` is running against them;
#   - the volume-UUID lookup parses `ATTR_VOL_UUID` without confirming it was returned;
#   - there is no audit log of any kind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=debug; SIGN=""; TEAM=""; WITH_HELPER=0
while [ $# -gt 0 ]; do case "$1" in
  --release) CONFIG=release;; --sign) SIGN="$2"; shift;; --team) TEAM="$2"; shift;;
  --with-helper) WITH_HELPER=1;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
if [ -n "$SIGN" ] && [ -z "$TEAM" ]; then TEAM=$(echo "$SIGN" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/'); fi

cd "$ROOT"
HELPER_SRC=Sources/XCodeVaultHelper/main.swift
if [ -n "$TEAM" ]; then
  # A team id is interpolated into both a sed expression and Swift source; validate its shape first.
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "refusing: --team must be 10 uppercase alphanumerics, got '$TEAM'" >&2; exit 2; }
  # Restore from a copy, and arm the trap BEFORE the edit. Previously the trap was installed after
  # the sed, so an interrupt in that window left a real team id sitting in a tracked file — in a
  # public repository. `git checkout --` also discarded any unrelated uncommitted edits to this
  # file, which is not the script's to do.
  cp "$HELPER_SRC" "$HELPER_SRC.bundle-bak"
  trap 'mv -f "$HELPER_SRC.bundle-bak" "$HELPER_SRC" 2>/dev/null || true' EXIT
  sed -i '' "s/let teamID = \"TEAMID_PLACEHOLDER\"/let teamID = \"$TEAM\"/" "$HELPER_SRC"
  # A reformat of that line would make the substitution a silent no-op and ship a helper that
  # refuses every connection — fail-closed, but a silent release. Assert it landed.
  grep -q "let teamID = \"$TEAM\"" "$HELPER_SRC" || { echo "refusing: team id substitution did not apply to $HELPER_SRC" >&2; exit 1; }
fi
BUILD_PRODUCTS=(--product XCodeVault --product xcodevaultctl)
[ "$WITH_HELPER" = 1 ] && BUILD_PRODUCTS+=(--product xcodevault-helper)
swift build -c "$CONFIG" "${BUILD_PRODUCTS[@]}"
BIN="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/XCodeVault.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/XCodeVault" "$APP/Contents/MacOS/XCodeVault"
cp "$BIN/xcodevaultctl" "$APP/Contents/MacOS/xcodevaultctl"
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
# One authoritative version, stamped into the bundle rather than maintained in two places.
# `Resources/App/Info.plist` carried `0.1.0` while `ScanReport.current` said `0.1.0-dev`, and
# nothing reconciled them: `release.sh --version` renamed the DMG and left the notarized app
# reporting whatever the tracked plist happened to say. A notarized artifact cannot be corrected
# after the fact, so the source of truth wins here.
XCV_VERSION="$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/XCodeVaultCore/Scan/ScanReport.swift)"
[ -n "$XCV_VERSION" ] || { echo "refusing: could not read the version from ScanReport.swift" >&2; exit 2; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $XCV_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $XCV_VERSION" "$APP/Contents/Info.plist"
# The CLI copied above statically links swift-argument-parser, which is Apache-2.0. Its licence
# therefore ships with the binary, not only in the repository — see THIRD-PARTY-LICENSES.md for
# the clause-by-clause reasoning. Info.plist's NSHumanReadableCopyright points the reader here.
cp THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/THIRD-PARTY-LICENSES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
if [ "$WITH_HELPER" = 1 ]; then
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$BIN/xcodevault-helper" "$APP/Contents/MacOS/xcodevault-helper"
  cp Resources/LaunchDaemons/com.xcodevault.helper.plist "$APP/Contents/Library/LaunchDaemons/"
fi
# SwiftPM resource bundles (none for the app today); strip quarantine (Apple requirement before signing).
xattr -cr "$APP"
if [ -n "$SIGN" ]; then
  # Inside-out: helper, CLI, then the app. Hardened runtime, timestamps, no library-validation opt-out.
  [ "$WITH_HELPER" = 1 ] && codesign --force --options runtime --timestamp --identifier com.xcodevault.helper --sign "$SIGN" "$APP/Contents/MacOS/xcodevault-helper"
  codesign --force --options runtime --timestamp --identifier com.xcodevault.xcodevaultctl --sign "$SIGN" "$APP/Contents/MacOS/xcodevaultctl"
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "note: unsigned bundle; the helper refuses connections without a team id (by design)."
fi
echo "built $APP"

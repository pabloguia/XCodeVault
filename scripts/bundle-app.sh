#!/bin/bash
# Assembles XCodeVault.app from SwiftPM build products (ADR-0003: SwiftPM is the build system of
# record; the .app is script-assembled). Signs inside-out: with Developer ID when `--sign` is given,
# otherwise ad hoc with the hardened runtime.
#
# Usage: scripts/bundle-app.sh [--release] [--sign "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--with-helper]
#
# `--with-helper` is off by default, and deliberately. The app can connect since deliverable 4 of the
# 2026-09-27 permissions plan — registration and the two verb calls — gated on a build signed by a
# usable team and on this flag, so no build made without `--sign` and `--with-helper` can. None of it
# has run live (#30). Without the flag the bundle offers no root Mach service in the global bootstrap
# namespace at all, which stays the default until the helper has run live in a signed build and the
# list below is empty or accepted in review. The cask once told people to enable it; it must not again.
#
# **Gate on this flag, not a backlog.** Re-verified against Sources/XCodeVaultHelperCore on 2026-09-28
# (the list here had gone stale; helper-security review of deliverable 3) and completed by the review of
# deliverable 4. Still true, and live the moment this flag is used in a release:
#   - the cleanup verb has no in-use check of its own: it deletes the CoreSimulator dyld and Cryptex
#     caches whatever is running against them. The client now refuses while Xcode, a simulator,
#     `simctl`, `xcodebuild` or the cache builder runs (`PrivilegedActionRunner`), which protects against
#     accident; the verb itself still has none, so a hostile client is not constrained by it;
#   - the client's requirement refuses a wrong daemon's reply, not the request (xpc/connection.h:790-793;
#     measured in-process 2026-09-28): a daemon from an older bundle still holding the name acts on a verb
#     before the client can refuse it. The fix is the M5 TODO on `helperRequirement` in HelperProtocol.swift;
#   - neither requirement has a minimum-version predicate yet (`clientRequirement` and `helperRequirement`
#     in HelperProtocol.swift, both TODO(M5));
#   - the audit trail is not rate-limited: a client that passes the requirement can flood the persisted
#     log and push older records out (HelperAudit.swift:29-34).
# Closed since the list was first written, with the evidence:
#   - every component from `/` is opened with `O_NOFOLLOW`, and owner and mode are checked on each
#     (`openGuardedDirectory`, HelperService.swift:245-251 and 695-794);
#   - the mount question is asked of the descriptor, and an undetermined answer refuses
#     (HelperService.swift:254-300);
#   - `ATTR_VOL_UUID` is used only when the returned-attributes set says it was supplied
#     (HelperService.swift:1052);
#   - each verb emits an audit record through os_log (HelperAudit.swift:100-145, called from
#     HelperService.swift:142, 162, 179 and 191).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=debug; SIGN=""; TEAM=""; WITH_HELPER=0
while [ $# -gt 0 ]; do case "$1" in
  --release) CONFIG=release;; --sign) SIGN="$2"; shift;; --team) TEAM="$2"; shift;;
  --with-helper) WITH_HELPER=1;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
if [ -n "$SIGN" ] && [ -z "$TEAM" ]; then TEAM=$(echo "$SIGN" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/'); fi

cd "$ROOT"
HELPER_SRC=Sources/XCodeVaultHelper/main.swift
# The client needs the same substitution as the daemon (issue #30). The CLI and the app link it since
# the 2026-09-27 permissions work: `xcodevaultctl permissions` and the app's Permissions section report
# the helper as "not available in this build" while the team ID is still the placeholder, so in a
# signed build this substitution is what lets that report say anything else. The app's connection
# (deliverable 4) also needs the running code signed by that team, which is `--sign`'s job, not this
# one's. What it prevents is the shape the protocol called "a requirement written down, not a property
# held": a client whose team ID is still the placeholder refuses every connection, which is
# fail-closed but inert — the daemon installed and nothing able to talk to it.
# `HelperClientTests` asserts this script still names the file; the check after the sed below is held
# by review, not by a test.
CLIENT_SRC=Sources/XCodeVaultHelperClient/HelperClient.swift
TEAM_SRCS=("$HELPER_SRC" "$CLIENT_SRC")
if [ -n "$TEAM" ]; then
  # A team id is interpolated into both a sed expression and Swift source; validate its shape first.
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "refusing: --team must be 10 uppercase alphanumerics, got '$TEAM'" >&2; exit 2; }
  # Restore from copies, and arm the trap BEFORE any edit. Previously the trap was installed after
  # the sed, so an interrupt in that window left a real team id sitting in a tracked file — in a
  # public repository. `git checkout --` also discarded any unrelated uncommitted edits to this
  # file, which is not the script's to do. With two files the ordering matters more, not less:
  # both backups are taken and the trap armed before either file is touched.
  for src in "${TEAM_SRCS[@]}"; do
    [ -f "$src" ] || { echo "refusing: $src does not exist; the team id substitution has nowhere to land" >&2; exit 2; }
    # Check the PRE-state, not just the post-state. The assertion after the sed passes either way if
    # a previous run died on SIGKILL leaving a real team id in a tracked source: the sed then matches
    # nothing, the grep still succeeds, and the trap restores the contamination — permanently and
    # silently, in a public repository. This is the check that notices.
    grep -q "let teamID = \"TEAMID_PLACEHOLDER\"" "$src" \
      || { echo "refusing: $src does not contain the placeholder. A previous run may have left a real team id in it; inspect it before rebuilding." >&2; exit 1; }
    cp "$src" "$src.bundle-bak"
  done
  trap 'for s in "${TEAM_SRCS[@]}"; do mv -f "$s.bundle-bak" "$s" 2>/dev/null || true; done' EXIT
  for src in "${TEAM_SRCS[@]}"; do
    sed -i '' "s/let teamID = \"TEAMID_PLACEHOLDER\"/let teamID = \"$TEAM\"/" "$src"
    # A reformat of that line would make the substitution a silent no-op and ship a build that
    # refuses every connection — fail-closed, but a silent release. Assert it landed, per file:
    # asserting only the first would let a rename in the second pass unnoticed, which is exactly
    # the shape of the bug this whole block exists to prevent.
    grep -q "let teamID = \"$TEAM\"" "$src" || { echo "refusing: team id substitution did not apply to $src" >&2; exit 1; }
  done
fi
BUILD_PRODUCTS=(XCodeVault xcodevaultctl)
[ "$WITH_HELPER" = 1 ] && BUILD_PRODUCTS+=(xcodevault-helper)
# One `swift build` per product. Given several `--product` options, SwiftPM builds only the last one: measured
# 2026-10-02, when `--release` left only xcodevaultctl in .build/release and the copy below failed. Debug
# bundles hid it by copying whatever an earlier full build had left in .build/debug, possibly stale.
for product in "${BUILD_PRODUCTS[@]}"; do swift build -c "$CONFIG" --product "$product"; done
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
cp Resources/App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
  # No Developer ID: sign ad hoc, inside-out, with the hardened runtime. The app asks the user for Full
  # Disk Access (deliverable 3 of the 2026-09-27 permissions plan), and code injected into a granted app
  # would run with its grant: the premise of the helper-security review of 2026-09-28, not measured here.
  # Measured that day on macOS 26.7: a dylib named in DYLD_INSERT_LIBRARIES loaded into SwiftPM's own CLI
  # output (ad hoc, no runtime flag, get-task-allow) and was ignored by the CLI as signed here. The app is
  # signed the same way; it was not launched. Ad hoc carries no team ID, so the helper still refuses every
  # connection, by design; and a rebuild changes the code hash, so it may need the grant again (unmeasured).
  [ "$WITH_HELPER" = 1 ] && codesign --force --options runtime --identifier com.xcodevault.helper --sign - "$APP/Contents/MacOS/xcodevault-helper"
  codesign --force --options runtime --identifier com.xcodevault.xcodevaultctl --sign - "$APP/Contents/MacOS/xcodevaultctl"
  codesign --force --options runtime --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "note: ad hoc signed with the hardened runtime; the helper refuses connections without a team id (by design)."
fi
echo "built $APP"

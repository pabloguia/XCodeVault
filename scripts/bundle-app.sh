#!/bin/bash
# Assembles XCodeVault.app from SwiftPM build products (ADR-0003: SwiftPM is the build system of
# record; the .app is script-assembled). Signs inside-out: with Developer ID when `--sign` is given,
# otherwise ad hoc with the hardened runtime.
#
# Usage: scripts/bundle-app.sh [--release] [--sign "Developer ID Application: Name (TEAMID)"] [--team TEAMID] [--with-helper] [--for-ci-signing]
#
# `--release` builds every binary universal (arm64 + x86_64) and refuses a bundle that is not; a debug bundle is built
# for the host only. See "A release is universal" below.
#
# `--for-ci-signing` (M5, ADR-0016): the release workflow's build job has no identity, so it assembles the bundle with
# `--with-helper --team` and signs it ad hoc, and the `sign` job re-signs every binary with the CI Developer ID
# (`ci-sign-notarize.sh`). Only that flag lets `--with-helper` go without `--sign`; the bundle it leaves is not usable
# until that re-signing, and says so.
#
# `--with-helper` is off by default, and on in the release workflow since ADR-0016 (M5). The app can connect since
# deliverable 4 of the 2026-09-27 permissions plan, gated on a build signed by a usable team and on this flag. It never
# registers the helper by itself: only when the user asks (ADR-0007). The cask once told people to enable it; it must
# not again.
#
# **`--with-helper` needs a Developer ID Application identity** (R8 fix round 5, N2), or `--for-ci-signing` (above).
# The helper accepts its authorization right's definition only when the writer's code requirement names the team as
# `certificate leaf[subject.OU]` (ADR-0014). An "Apple Development" identity's designated requirement keys on the
# leaf's `subject.CN` instead, so every read-back would fail and every Turn On Ownership would be refused — fail
# closed, but a build that cannot work. Refused here rather than shipped broken.
#
# **Gate on this flag, not a backlog.** Open, and live the moment this flag is used in a release:
#   - `createVaultDirectory` has not run live in a signed build (#30); `enableOwnership` has (H18, 2026-10-07). The
#     runbook's live tests on a release candidate (ADR-0016) are the remaining step;
#   - no client-call timeout: a daemon that takes a message and never replies leaves the call pending (advisory A2).
# Closed by ADR-0016 (M5, 2026-10-17):
#   - the cleanup verb, which has no in-use check of its own, is refused by the daemon (`verbNotOffered`), and so is its
#     companion; the app offers the manual route (`CleanAction.helperCleanupOffered`);
#   - every verb waits for a validated `version()` and `begin(clientVersion:)` on its own connection, so a daemon of
#     another version is sent nothing (`HelperClient.opening`), and the daemon refuses every verb on a connection
#     without a `begin` of exactly its version (`HelperService.notBegunRefusal`): the minimum version, both ways;
#   - the audit trail is rate-limited per uid, and a flood is marked and counted (`AuditThrottle`).
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
CONFIG=debug; SIGN=""; TEAM=""; WITH_HELPER=0; FOR_CI=0
while [ $# -gt 0 ]; do case "$1" in
  --release) CONFIG=release;; --sign) SIGN="$2"; shift;; --team) TEAM="$2"; shift;;
  --with-helper) WITH_HELPER=1;; --for-ci-signing) FOR_CI=1;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
if [ "$FOR_CI" = 1 ] && { [ -n "$SIGN" ] || ! [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; }; then
  echo "refusing: --for-ci-signing takes --team TEAMID and no --sign; the CI sign job signs" >&2
  exit 2
fi
if [ "$WITH_HELPER" = 1 ] && [ "$FOR_CI" = 0 ] && ! [[ "$SIGN" =~ ^Developer\ ID\ Application:\ .+\ \([A-Z0-9]{10}\)$ ]]; then
  echo "refusing: --with-helper needs --sign 'Developer ID Application: Name (TEAMID)'; the helper's right is keyed on the team OU (ADR-0014)" >&2
  exit 2
fi
if [ -n "$SIGN" ] && [ -z "$TEAM" ]; then TEAM=$(echo "$SIGN" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/'); fi

cd "$ROOT"
HELPER_SRC=Sources/XCodeVaultHelper/main.swift
# The client needs the same substitution as the daemon (issue #30). The CLI and the app link it since
# the 2026-09-27 permissions work: `xcodevaultctl permissions` and the app's Access screen (formerly Permissions) report
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
#
# A release is universal. A plain `swift build` builds only the host's architecture, and the release workflow runs on
# `macos-15`, an Apple silicon runner: 0.3.0-rc.1 shipped arm64 only, and on this project's Intel development Mac Finder
# showed it as unable to run (2026-10-17). So a release builds each product once per architecture, one `--arch` at a
# time — one keeps SwiftPM's native build system, several switch it to XCBuild, which is a different build — and `lipo`
# joins the slices. A debug bundle stays host-only: it is for the machine that built it.
RELEASE_ARCHS=(arm64 x86_64)
if [ "$CONFIG" = release ]; then
  BIN="$ROOT/.build/universal-release"
  rm -rf "$BIN"; mkdir -p "$BIN"
  for product in "${BUILD_PRODUCTS[@]}"; do
    slices=()
    for arch in "${RELEASE_ARCHS[@]}"; do
      swift build -c release --arch "$arch" --product "$product"
      slices+=("$(swift build -c release --arch "$arch" --show-bin-path)/$product")
    done
    lipo -create "${slices[@]}" -output "$BIN/$product"
  done
else
  for product in "${BUILD_PRODUCTS[@]}"; do swift build -c "$CONFIG" --product "$product"; done
  BIN="$ROOT/.build/$CONFIG"
fi
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
# Refuse a release bundle any of whose binaries is not exactly the two release architectures. The build above makes
# them so; this holds it if that ever changes, before anything is signed. `release-artifact-scan.sh` checks the same
# again on the bundle the CI `sign` job receives and on the one it signs.
if [ "$CONFIG" = release ]; then
  want=$(printf '%s\n' "${RELEASE_ARCHS[@]}" | sort | tr '\n' ' ')
  for bin in "$APP"/Contents/MacOS/*; do
    # Not a Mach-O lipo can read is a refusal too, said as one, not a bare `set -e` exit.
    have=$(lipo -archs "$bin" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ') || have="unreadable "
    [ "$have" = "$want" ] \
      || { echo "refusing: $(basename "$bin") holds [${have% }], a release must hold exactly [${want% }]" >&2; exit 1; }
  done
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
  if [ "$FOR_CI" = 1 ]; then
    echo "note: ad hoc signed for the CI sign job to re-sign; not usable as it is."
  else
    echo "note: ad hoc signed with the hardened runtime; the helper refuses connections without a team id (by design)."
  fi
fi
echo "built $APP"

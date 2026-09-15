#!/bin/bash
# E14b control — does `simctl create` work in an alternate device set on the INTERNAL disk?
#
#   E14b phase 2 failed on the vault: CoreSimulatorService could not copy the device's sample
#   content into <set>/<UDID>/data, NSPOSIXErrorDomain Code=1 (EPERM, "Operation not permitted"),
#   and the device was torn down as "stuck in creation state".  Two readings survive that
#   observation and they lead to different products:
#
#     A. something about that volume is the problem -> H12 dies there
#     B. alternate device sets do not work at all -> H12 dies for an unrelated reason, and E15's
#        transparency question is moot as well
#
#   Note what (A) does NOT establish. This control's set is internal, case-insensitive, on the
#   boot volume, mounted with the default options; the vault is external, Case-sensitive APFS,
#   `nodev,nosuid`, USB. A create that succeeds here narrows the cause to *volume class* and no
#   further — removability, case sensitivity, mount options and bus all still differ. Do not
#   report (A) as removability, and so do not report it as H6, without an experiment that varies
#   one of those at a time. E2 controlled case sensitivity for bundle loading; nothing has
#   controlled it for device creation, which copies xattrs, ACLs and flags that a zero-byte
#   write never exercises.
#
#   This script discriminates them, and only that.  Identical device type and runtime, identical
#   commands, on an internal scratch path.  If creation succeeds here, the difference is the
#   volume; if it fails here too, the difference is the mechanism.
#
#   It also establishes E15's precondition, which deliberately uses an internal alternate set.
#
# THIS SCRIPT MUTATES STATE, but its blast radius is a directory it creates itself:
#   - the device set is a fresh `mktemp -d`; the script never accepts a path from you;
#   - every simctl invocation carries --set, so the default device set is never addressed;
#   - it deletes only the device it created and only that temp directory;
#   - it never touches /Volumes, never touches ~/Library/Developer, and never uses sudo.
#
# Usage:
#   scripts/experiments/e14b-control-internal-create.sh --i-understand

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "${1:-}" = "--i-understand" ] || { echo "usage: $0 --i-understand" >&2; exit 2; }

SET_PATH=$(mktemp -d -t xcv-e14b-ctl) || exit 2
# mktemp resolves through $TMPDIR, so the returned string is not trustworthy on its own: a
# crafted TMPDIR (`/tmp/../Users/<you>/Library/Developer/...`, or one on the vault) matches the
# textual arms below and would both misdirect `rm -rf` and silently run this control on the very
# volume it exists to compare against. Canonicalise, re-test, then assert the device.
SET_PATH=$(cd "$SET_PATH" 2>/dev/null && pwd -P) || { echo "REFUSING: mktemp path unreachable." >&2; exit 2; }
case "$SET_PATH" in
  /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) ;;
  *) echo "REFUSING: mktemp returned an unexpected location: $SET_PATH" >&2; exit 2;;
esac
case "$SET_PATH" in *\'*) echo "REFUSING: quote in the temp path." >&2; exit 2;; esac
# The whole point of this control is that the set is NOT on the volume under test. Assert it.
if [ "$(stat -f %Sd "$SET_PATH" 2>/dev/null)" != "$(stat -f %Sd / 2>/dev/null)" ]; then
  echo "REFUSING: the control set is not on the boot volume; it would compare nothing." >&2
  rmdir "$SET_PATH" 2>/dev/null; exit 2
fi

OUT="$XCV_EVIDENCE_DIR/e14b-control-internal-create-$(xcv_env_slug).txt"
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"
STATE=$(mktemp -t xcv-e14b-ctl-udid) || { rmdir "$SET_PATH" 2>/dev/null; exit 2; }
CTL_RC=0
xcv_rotate_out "$OUT" || exit 2

cleanup() {
  echo "## cleanup"
  local udid remaining
  udid=$(cat "$STATE" 2>/dev/null || true)
  if [ -n "$udid" ]; then
    xcrun simctl --set "$SET_PATH" shutdown "$udid" >/dev/null 2>&1
    echo "## shutdown -> exit $?"
    xcrun simctl --set "$SET_PATH" delete "$udid" >/dev/null 2>&1
    echo "## delete   -> exit $?"
  fi
  # Same rule as E14b: ask the set what it holds rather than trusting a return code.
  remaining=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
'import json,sys
try:
    d = json.load(sys.stdin)["devices"]
except Exception:
    print("?"); raise SystemExit
print(sum(len(v) for v in d.values()))' 2>/dev/null)
  echo "# set reports ${remaining:-<unreadable>} remaining device(s)"
  if [ "$remaining" = "0" ]; then
    xcv_run "remove control set" rm -rf "$SET_PATH"
  else
    echo "left $SET_PATH in place — the set still reports ${remaining:-?} device(s). By hand:"
    echo "   xcrun simctl --set '$SET_PATH' list devices"
    echo "   xcrun simctl --set '$SET_PATH' shutdown <udid> && xcrun simctl --set '$SET_PATH' delete <udid>"
    echo "   rm -rf '$SET_PATH'"
    echo "   NOTE: this path is under the system temp directory, which macOS reaps periodically."
    echo "   Clean it up now rather than later, or a registered device may be half-removed."
  fi
  xcv_run "post-cleanup: anything left?" bash -c "ls -la '$SET_PATH' 2>&1 | head -3"
  rm -f "$STATE"
}
trap 'cleanup 2>&1 | xcv_redact >> "$OUT"' INT TERM

{
  xcv_header "E14b control — simctl create in an alternate device set on the INTERNAL disk"
  echo "# Control set path (internal, mktemp): $SET_PATH"
  echo "# Discriminates: external volume (H6) vs alternate device sets in general."
  echo
  xcv_run "the control path is on the internal disk" bash -c "df -h '$SET_PATH' | tail -1"
  xcv_run "BASELINE default device set (must be unchanged at the end)" \
    bash -c "xcrun simctl list devices"
  xcv_run "BASELINE default set size" du -shx "$DEFAULT_SET"

  DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
  RUNTIME="${XCV_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
  echo "## create — identical device type and runtime to the E14b run that failed"
  echo "# device type: $DEVTYPE"
  echo "# runtime:     $RUNTIME"
  # No `bash -c`: DEVTYPE/RUNTIME come from the environment, and interpolating them into a shell
  # string lets a crafted value run arbitrary simctl against the DEFAULT set.
  xcv_run "create" xcrun simctl --set "$SET_PATH" create XCV-E14b-ctl "$DEVTYPE" "$RUNTIME"
  UDID=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"]=="XCV-E14b-ctl"), ""))')
  echo "# probe UDID: ${UDID:-<none>}"
  printf '%s' "$UDID" > "$STATE"

  echo "## verdict"
  if [ -n "$UDID" ]; then
    echo "CREATED on the internal disk. The E14b phase-2 failure is therefore about the VOLUME"
    echo "CLASS, not about alternate device sets as a mechanism — reading A."
    echo "This does NOT isolate removability: this set is internal, case-insensitive and on the"
    echo "boot volume, while the vault differs in all of those plus mount options and bus. It is"
    echo "consistent with H6 and is not yet a reproduction of it."
    xcv_run "what the set looks like" bash -c "ls -la '$SET_PATH'"
    xcv_run "sample content that E14b could not copy" bash -c "du -sh '$SET_PATH/$UDID/data' 2>&1"
  else
    echo "NOT CREATED on the internal disk either. The E14b phase-2 failure is then NOT evidence"
    echo "about external storage — reading B, and H12 dies on the mechanism rather than on H6."
    xcv_run "CoreSimulator log tail" bash -c \
      "grep -a 'XCV-E14b-ctl\|stuck in creation' ~/Library/Logs/CoreSimulator/CoreSimulator.log | tail -12"
    CTL_RC=1
  fi

  echo "## accounting — the default set must be untouched"
  xcv_run "default set size (compare with baseline)" du -shx "$DEFAULT_SET"
  xcv_run "default set device list (compare with baseline)" bash -c "xcrun simctl list devices"
  cleanup
  exit "$CTL_RC"
} 2>&1 | xcv_redact > "$OUT"
BODY_RC=${PIPESTATUS[0]}

echo "wrote $OUT"
[ "$BODY_RC" -ne 0 ] && echo "!! the control did NOT create a device (exit $BODY_RC) — read $OUT." >&2
rm -f "$STATE"
exit "$BODY_RC"

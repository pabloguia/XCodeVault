#!/bin/bash
# E14b — Can a CoreSimulator *device set* live on an external physical volume?
#
#   Gates H12.  Kill-gate order is cheapest-first: each phase can end the experiment.
#   Phase 3 is the one that matters — H6 (E2) showed the sandbox restriction that breaks
#   `xctest` bundle loading follows the *physical external device*, not the path.  A device
#   set holds the simulator's whole data volume, and for simulator-destination testing the
#   .xctest bundle is installed *into* that data volume.  If a device cannot boot, or an
#   installed app cannot launch, from a set on a USB volume, nothing downstream matters and
#   the alternate-device-set idea is dead without needing the IDE question answered at all.
#
# THIS SCRIPT MUTATES STATE.  It is not run by the research agent.  Read it first.
#   It writes ONLY under the --set path you pass, which must be on an external volume and
#   must NOT be inside ~/Library/Developer or /Library/Developer.  It never touches the
#   default device set: every simctl invocation carries --set.  It never uses sudo.
#
# Usage:
#   scripts/experiments/e14b-device-set-external.sh /Volumes/<vault>/XCodeVault/E14bSet --i-understand
#
# Manual procedure if you would rather not run a script:
#   1. SET=/Volumes/<vault>/XCodeVault/E14bSet
#   2. xcrun simctl --set "$SET" list devices          # does the service accept the path?
#   3. xcrun simctl --set "$SET" create XCV-E14b <deviceTypeId> <runtimeId>
#   4. xcrun simctl --set "$SET" boot <udid>; then POLL `list devices` for "Booted".
#      Do NOT use `simctl bootstatus -b` — E11 recorded it hanging on Data Migration long
#      after the device had actually booted.
#   5. xcrun simctl --set "$SET" install <udid> <some .app>; ... launch <udid> <bundleid>
#   6. xcrun simctl --set "$SET" shutdown <udid>; delete <udid>; then rm -rf "$SET".
#
# What would FALSIFY H12, in the order the phases test it:
#   - simctl refuses the set path, or CoreSimulatorService cannot create it        (phase 1)
#   - device creation fails, or fails only on the external volume                  (phase 2)
#   - the device never reaches Booted, or boots then wedges                        (phase 3)
#   - an installed app cannot be launched (the E2 shape, one layer in)             (phase 4)
#   - device data still lands in the default set (i.e. --set is not honoured)      (phase 5)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SET_PATH="${1:-}"
CONFIRM="${2:-}"

if [ -z "$SET_PATH" ] || [ "$CONFIRM" != "--i-understand" ]; then
  echo "usage: $0 <device-set-path-on-external-volume> --i-understand" >&2
  exit 2
fi

case "$SET_PATH" in
  "$HOME"/Library/Developer/*|/Library/Developer/*|"$HOME"/Library/Developer|/Library/Developer)
    echo "REFUSING: $SET_PATH is inside a developer-data directory." >&2; exit 2;;
  /Volumes/*) ;;
  *) echo "REFUSING: $SET_PATH is not under /Volumes." >&2; exit 2;;
esac

VOLUME="/Volumes/$(echo "${SET_PATH#/Volumes/}" | cut -d/ -f1)"
OUT="$XCV_EVIDENCE_DIR/e14b-device-set-external-$(xcv_env_slug).txt"
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"
UDID=""

cleanup() {
  echo "## cleanup"
  if [ -n "$UDID" ]; then
    xcv_run "shutdown probe device" xcrun simctl --set "$SET_PATH" shutdown "$UDID"
    xcv_run "delete probe device" xcrun simctl --set "$SET_PATH" delete "$UDID"
  fi
  # Only ever remove a directory this script created, under /Volumes, named as passed.
  if [ -d "$SET_PATH" ] && [ -f "$SET_PATH/.xcv-e14b" ]; then
    xcv_run "remove probe device set" rm -rf "$SET_PATH"
  else
    echo "left $SET_PATH in place (no .xcv-e14b marker — not ours to delete)"
  fi
}

{
  xcv_header "E14b — CoreSimulator device set on an external volume (gates H12)"
  echo "# Device set path: $SET_PATH"
  echo "# Volume: $VOLUME"
  echo

  echo "## phase 0 — preflight, no mutation"
  xcv_run "volume class" diskutil info "$VOLUME"
  xcv_run "mount options (owners must be on)" bash -c "mount | grep -F '$VOLUME'"
  xcv_run "free space" df -h "$VOLUME" /System/Volumes/Data
  xcv_run "BASELINE default device set (must be unchanged at the end)" \
    bash -c "xcrun simctl list devices | sed -n '1,80p'"
  xcv_run "BASELINE default set size" du -shx "$DEFAULT_SET"
  xcv_run "available runtimes / device types" bash -c "xcrun simctl list runtimes; xcrun simctl list devicetypes | tail -20"

  echo "## phase 1 — does the service accept a set on this volume?"
  mkdir -p "$SET_PATH" && : > "$SET_PATH/.xcv-e14b"
  xcv_run "list devices in the external set" xcrun simctl --set "$SET_PATH" list devices
  xcv_run "what got created there" bash -c "ls -la '$SET_PATH'"
  if [ ! -f "$SET_PATH/device_set.plist" ]; then
    echo "!! phase 1 FAILED — no device_set.plist. H12 falsified at the cheapest gate."
    cleanup; exit 1
  fi

  echo "## phase 2 — create a device in the external set"
  DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
  RUNTIME="${XCV_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]]; print(rs[0]["identifier"] if rs else "")')}"
  echo "# device type: $DEVTYPE"
  echo "# runtime:     $RUNTIME"
  xcv_run "create" bash -c "xcrun simctl --set '$SET_PATH' create XCV-E14b '$DEVTYPE' '$RUNTIME'"
  UDID=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
    'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"]=="XCV-E14b"), ""))')
  echo "# probe UDID: ${UDID:-<none>}"
  if [ -z "$UDID" ]; then
    echo "!! phase 2 FAILED — device not created on the external volume."
    cleanup; exit 1
  fi

  echo "## phase 3 — boot it (the H6 gate)"
  xcv_run "boot" xcrun simctl --set "$SET_PATH" boot "$UDID"
  echo "## poll for Booted (never bootstatus -b; see E11)"
  for i in $(seq 1 60); do
    state=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
      "import json,sys
d=json.load(sys.stdin)['devices']
print(next((x['state'] for v in d.values() for x in v if x['udid']=='$UDID'),'?'))")
    echo "  t+${i}0s state=$state"
    [ "$state" = "Booted" ] && break
    sleep 10
  done
  if [ "$state" != "Booted" ]; then
    echo "!! phase 3 FAILED — never reached Booted from the external volume."
    echo "   Capture the reason before cleanup:"
    xcv_run "CoreSimulator/sandbox log" bash -c \
      "log show --last 5m --predicate 'subsystem CONTAINS \"CoreSimulator\" OR subsystem CONTAINS \"com.apple.TCC\" OR senderImagePath CONTAINS \"Sandbox\"' --style compact | tail -120"
    cleanup; exit 1
  fi

  echo "## phase 4 — can a bundle be loaded from the external set? (the E2 shape)"
  APP="${XCV_PROBE_APP:-}"
  if [ -n "$APP" ] && [ -d "$APP" ]; then
    xcv_run "install" xcrun simctl --set "$SET_PATH" install "$UDID" "$APP"
    BID=$(defaults read "$APP/Info.plist" CFBundleIdentifier 2>/dev/null)
    xcv_run "launch $BID" xcrun simctl --set "$SET_PATH" launch "$UDID" "$BID"
  else
    echo "skipped — set XCV_PROBE_APP to a built simulator .app to run this phase."
    echo "This is the phase that most directly mirrors E2: it loads a bundle that lives"
    echo "on the physical external volume into a simulated process."
  fi

  echo "## phase 5 — accounting: did anything leak into the default set?"
  xcv_run "external set size" du -shx "$SET_PATH"
  xcv_run "external set contents" bash -c "du -shx '$SET_PATH'/*/ 2>/dev/null | sort -h"
  xcv_run "default set size (compare with phase 0)" du -shx "$DEFAULT_SET"
  xcv_run "default set device list (compare with phase 0)" bash -c "xcrun simctl list devices | sed -n '1,80p'"

  cleanup
  xcv_run "default set after cleanup" du -shx "$DEFAULT_SET"
} 2>&1 | xcv_redact > "$OUT"

echo "wrote $OUT"

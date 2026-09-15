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
#   2. xcrun simctl --set "$SET" list devices          # smoke test only — see phase 1's note:
#      this exits 0 for any directory that exists, so it says nothing about the volume.
#   3. xcrun simctl --set "$SET" create XCV-E14b <deviceTypeId> <runtimeId>
#   4. xcrun simctl --set "$SET" boot <udid>; then POLL `list devices` for "Booted".
#      Do NOT use `simctl bootstatus -b` — E11 recorded it hanging on Data Migration long
#      after the device had actually booted.
#   5. xcrun simctl --set "$SET" install <udid> <some .app>; ... launch <udid> <bundleid>
#   6. xcrun simctl --set "$SET" shutdown <udid>; delete <udid>; then rm -rf "$SET".
#
# What would FALSIFY H12, in the order the phases test it:
#   - device creation fails on the external volume                                 (phase 2)
#     (phase 1 gates nothing: it only detects that the path stopped existing)
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

# Canonicalise BEFORE deciding anything. The textual refusal below is not sound against `..`
# or symlinks on its own: `/Volumes/<vol>/../../Users/<you>/Library/Developer/CoreSimulator`
# matches the `/Volumes/*` arm, resolves to the real developer directory, and would be adopted
# and then deleted. Resolve the parent with `pwd -P` — the leaf itself need not exist yet — and
# re-test the resolved form.
SET_PARENT=$(cd "$(dirname "$SET_PATH")" 2>/dev/null && pwd -P) || SET_PARENT=""
if [ -z "$SET_PARENT" ]; then
  echo "REFUSING: the parent of $SET_PATH does not exist or is not reachable." >&2; exit 2
fi
SET_LEAF=$(basename "$SET_PATH")
case "$SET_LEAF" in
  .|..) echo "REFUSING: a '.' or '..' leaf resolves to a directory this script did not name." >&2; exit 2;;
esac
SET_PATH="$SET_PARENT/$SET_LEAF"

case "$SET_PATH" in
  "$HOME"/Library/Developer/*|/Library/Developer/*|"$HOME"/Library/Developer|/Library/Developer)
    echo "REFUSING: $SET_PATH is inside a developer-data directory." >&2; exit 2;;
  /Volumes/?*/?*) ;;
  *) echo "REFUSING: $SET_PATH is not a path under /Volumes/<volume>/." >&2; exit 2;;
esac

VOLUME="/Volumes/$(echo "${SET_PATH#/Volumes/}" | cut -d/ -f1)"

# The resolved parent must sit on the same device as the volume it claims to be on, so that a
# symlink under /Volumes cannot redirect every write to the internal disk.
if [ "$(stat -f %Sd "$SET_PARENT" 2>/dev/null)" != "$(stat -f %Sd "$VOLUME" 2>/dev/null)" ]; then
  echo "REFUSING: $SET_PATH does not reside on the device backing $VOLUME." >&2; exit 2
fi

# Volume identity, captured once and re-asserted between phases. MIGRATION_ENGINE.md forbids
# identifying a volume by its /Volumes/<name> path alone: an unplug mid-run leaves that name
# free for something else to occupy, and the writes would land there unnoticed.
VOLUME_UUID=$(diskutil info -plist "$VOLUME" 2>/dev/null | plutil -extract VolumeUUID raw - 2>/dev/null)
if [ -z "$VOLUME_UUID" ]; then
  echo "REFUSING: could not read a volume UUID for $VOLUME." >&2; exit 2
fi

OUT="$XCV_EVIDENCE_DIR/e14b-device-set-external-$(xcv_env_slug).txt"
xcv_rotate_out "$OUT" || exit 2
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"

# The main body runs inside a pipeline, hence in a subshell: a UDID assigned there is invisible
# to a trap in this shell. Park it in a file that both can read.
STATE=$(mktemp -t xcv-e14b-udid) || exit 2

assert_volume() {
  local now
  now=$(diskutil info -plist "$VOLUME" 2>/dev/null | plutil -extract VolumeUUID raw - 2>/dev/null)
  if [ "$now" != "$VOLUME_UUID" ]; then
    echo "!! $VOLUME is no longer the volume this run started on."
    echo "   expected $VOLUME_UUID, found ${now:-<nothing mounted there>}"
    return 1
  fi
  return 0
}

cleanup() {
  echo "## cleanup"
  local udid delete_rc=0 shutdown_rc=0 remaining
  udid=$(cat "$STATE" 2>/dev/null || true)
  if [ -n "$udid" ]; then
    xcrun simctl --set "$SET_PATH" shutdown "$udid" >/dev/null 2>&1; shutdown_rc=$?
    echo "## shutdown probe device -> exit $shutdown_rc"
    xcrun simctl --set "$SET_PATH" delete "$udid" >/dev/null 2>&1; delete_rc=$?
    echo "## delete probe device -> exit $delete_rc"
  fi

  if [ ! -f "$STATE.created" ]; then
    # The trap is armed before phase 1 runs, so cleanup can fire while mkdir has never
    # executed. Without this the trap would delete a leftover set from an earlier run —
    # exactly the directory phase 1 refuses to adopt three lines later.
    echo "left $SET_PATH alone — this run never created it, so it is not ours to remove."
  elif [ -n "$udid" ] && [ "$delete_rc" -ne 0 ]; then
    echo "left $SET_PATH in place — simctl delete returned $delete_rc, so a device may still be"
    echo "live there; removing the tree under it is E9's shadow-data hazard. By hand:"
    echo "   xcrun simctl --set '$SET_PATH' shutdown $udid"
    echo "   xcrun simctl --set '$SET_PATH' delete $udid"
  elif ! assert_volume; then
    echo "left $SET_PATH in place — volume identity changed; refusing to delete on an unknown volume."
  else
    # Do not let a return code stand in for the state. `delete_rc` is 0 when nothing was
    # deleted, so a `create` that succeeded while the UDID probe came back empty — or an
    # interrupt landing between the two — reaches here with a live device the shutdown above
    # never addressed. Ask the set what it still holds.
    remaining=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
'import json,sys
try:
    d = json.load(sys.stdin)["devices"]
except Exception:
    print("?"); raise SystemExit
print(sum(len(v) for v in d.values()))' 2>/dev/null)
    if [ "$remaining" != "0" ]; then
      echo "left $SET_PATH in place — the set still reports ${remaining:-?} device(s); refusing rm -rf."
      echo "   Inspect with: xcrun simctl --set '$SET_PATH' list devices"
    elif [ -d "$SET_PATH" ] && [ -f "$SET_PATH/.xcv-e14b" ]; then
      xcv_run "remove probe device set" rm -rf "$SET_PATH"
    else
      echo "left $SET_PATH in place (no .xcv-e14b marker — not ours to delete)"
    fi
  fi

  # Shadow-data probe runs on every path, including the ones that left something behind —
  # those are the paths where it matters.
  xcv_run "post-cleanup: anything left at the set path?" bash -c "ls -la '$SET_PATH' 2>&1 | head -5"
  xcv_run "post-cleanup: any device set left anywhere on the volume?" \
    bash -c "find '$VOLUME' -maxdepth 4 -name device_set.plist 2>/dev/null | head"
  rm -f "$STATE" "$STATE.created"
}

# Ctrl-C during the phase-3 poll would otherwise leave a booted device and the probe set on the
# volume. Append the trap's own output to the evidence file: the interrupted run is the one that
# most needs a record, and cleanup's stdout is not inside the pipeline that writes $OUT.
trap 'cleanup 2>&1 | xcv_redact >> "$OUT"' INT TERM

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

  echo "## phase 1 — smoke test only. This phase is NOT a gate on this volume; see below."
  # `mkdir` without -p, deliberately: -p succeeds on a directory that already exists, and the
  # marker written on the next line would then adopt whatever was already in it for cleanup's
  # `rm -rf` to remove. Create the leaf ourselves or refuse.
  if ! mkdir "$SET_PATH" 2>/dev/null; then
    echo "!! REFUSING — $SET_PATH already exists, or its parent is not writable."
    echo "   This script will not adopt a directory it did not create. If it is a leftover"
    echo "   probe set from an interrupted run, inspect and remove it yourself, then re-run."
    rm -f "$STATE"; exit 2
  fi
  : > "$SET_PATH/.xcv-e14b"
  # Records that THIS run created the set. cleanup() requires it before removing anything:
  # the trap is armed before phase 1, so without this an interrupt in phase 0 would delete a
  # leftover set that the mkdir above would have refused to adopt.
  : > "$STATE.created"
  # Capture the exit status directly: xcv_run ends in `echo`, so its return value is echo's,
  # not the command's, and cannot be used as a gate.
  echo "## list devices in the external set"
  echo "\$ xcrun simctl --set $SET_PATH list devices"
  xcrun simctl --set "$SET_PATH" list devices 2>&1
  list_rc=$?
  echo "[exit=$list_rc]"
  echo
  xcv_run "what got created there" bash -c "ls -la '$SET_PATH'"
  # Two gates were tried here and both were wrong, in opposite directions. Recorded so the
  # third attempt is not a guess either:
  #
  #   1. "device_set.plist must exist after the list" — it is materialised by the first
  #      `create`, not by a `list`. The 2026-09-15 run aborted on this and printed that H12
  #      was falsified. A control run against an empty set on the INTERNAL disk produced an
  #      equally empty directory, exit 0, byte-identical output: the check discriminated
  #      empty-vs-non-empty set, not external-vs-internal. Evidence
  #      e14b-control-internal-*.txt.
  #   2. "the list's exit status" — measured 2026-09-15: this exits 1 only when the path does
  #      not exist ("Provided set path does not exist") and 0 for ANY existing directory,
  #      /tmp included. The directory is created three lines above, so exit 0 asserts that
  #      `mkdir` worked. It is a stat(), not a verdict from CoreSimulatorService.
  #
  # So phase 1 cannot say anything about this volume, and its result must not be reported as
  # the service accepting external storage. It is kept only because a non-zero here means the
  # path vanished between mkdir and list, which is worth stopping for. The first test that
  # discriminates anything about the storage is phase 2's `create`.
  if [ "$list_rc" -ne 0 ]; then
    echo "!! phase 1 FAILED — the set path stopped existing between mkdir and list (exit $list_rc)."
    cleanup; exit 1
  fi

  echo "## phase 2 — create a device in the external set"
  # Everything from here writes gigabytes and boots a device. Re-assert that the volume under
  # us is still the one phase 0 measured before doing any of it.
  if ! assert_volume; then echo "!! ABORT before phase 2."; cleanup; exit 1; fi
  DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
  RUNTIME="${XCV_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]]; print(rs[0]["identifier"] if rs else "")')}"
  echo "# device type: $DEVTYPE"
  echo "# runtime:     $RUNTIME"
  # No `bash -c`: DEVTYPE and RUNTIME come from the environment, and interpolating them into a
  # shell string lets a crafted value run arbitrary simctl against the DEFAULT set.
  xcv_run "create" xcrun simctl --set "$SET_PATH" create XCV-E14b "$DEVTYPE" "$RUNTIME"
  UDID=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
    'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"]=="XCV-E14b"), ""))')
  echo "# probe UDID: ${UDID:-<none>}"
  # Record it where a trap in the parent shell can find it: an interrupt during the phase-3
  # poll must still be able to shut the device down and delete it.
  printf '%s' "$UDID" > "$STATE"
  if [ -z "$UDID" ]; then
    echo "!! phase 2 FAILED — device not created on the external volume."
    # Capture the reason HERE. EXPERIMENTS.md specified log capture on a phase 3/4 failure only,
    # so the 2026-09-15 phase-2 failure recorded nothing but `code=22` and its mechanism had to be
    # read out of band afterwards — which then got cited as if the run had sourced it.
    echo "   Capture the reason before cleanup:"
    xcv_run "CoreSimulator.log around the failure" bash -c \
      "grep -a -E 'E14bSet|XCV-E14b|stuck in creation' ~/Library/Logs/CoreSimulator/CoreSimulator.log | tail -20"
    xcv_run "unified log: TCC / Sandbox / the set path" bash -c \
      "log show --last 10m --predicate 'subsystem == \"com.apple.TCC\" OR senderImagePath CONTAINS \"Sandbox\" OR eventMessage CONTAINS \"E14bSet\"' --style compact 2>/dev/null | tail -60"
    # tail, not head: the failure is the newest event in the window. Measured 2026-09-15, this
    # predicate over --last 10m returns ~1000 lines, so `head` would capture only tccd noise
    # from the start of the window and miss the deny line entirely.
    echo "   (an empty unified-log result is what E2 recorded too; record it, do not retry)"
    cleanup; exit 1
  fi

  echo "## phase 3 — boot it (the H6 gate)"
  if ! assert_volume; then echo "!! ABORT before phase 3."; cleanup; exit 1; fi
  xcv_run "boot" xcrun simctl --set "$SET_PATH" boot "$UDID"
  echo "## poll for Booted (never bootstatus -b; see E11)"
  for i in $(seq 1 60); do
    state=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
      "import json,sys
d=json.load(sys.stdin)['devices']
print(next((x['state'] for v in d.values() for x in v if x['udid']=='$UDID'),'?'))")
    echo "  t+${i}0s state=$state"
    [ "$state" = "Booted" ] && break
    # A ten-minute poll is the longest window in this script and the likeliest moment for the
    # vault to be unplugged. Notice it here rather than discovering it in the accounting.
    if ! assert_volume; then
      echo "!! ABORT — the volume went away mid-poll. Not cleaning up on an unknown volume."
      echo "   A booted device is deliberately left behind. When the vault is back, by hand:"
      echo "     xcrun simctl --set '$SET_PATH' shutdown $UDID"
      echo "     xcrun simctl --set '$SET_PATH' delete $UDID"
      echo "     rm -rf '$SET_PATH'   # only if it still holds the .xcv-e14b marker"
      rm -f "$STATE" "$STATE.created"; exit 1
    fi
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
  if ! assert_volume; then echo "!! accounting is being read off an unknown volume; do not trust it."; fi
  xcv_run "external set size" du -shx "$SET_PATH"
  xcv_run "external set contents" bash -c "du -shx '$SET_PATH'/*/ 2>/dev/null | sort -h"
  xcv_run "default set size (compare with phase 0)" du -shx "$DEFAULT_SET"
  xcv_run "default set device list (compare with phase 0)" bash -c "xcrun simctl list devices | sed -n '1,80p'"

  cleanup
  xcv_run "default set after cleanup" du -shx "$DEFAULT_SET"
} 2>&1 | xcv_redact > "$OUT"
# The block above runs in a pipeline subshell, so its `exit 1`s do not end this script and the
# trailing echo would otherwise make every aborted run exit 0 — nothing downstream could tell
# that the experiment failed. Propagate the block's own status.
BODY_RC=${PIPESTATUS[0]}

echo "wrote $OUT"
[ "$BODY_RC" -ne 0 ] && echo "!! the run ABORTED (exit $BODY_RC) — read $OUT before citing anything from it." >&2
rm -f "$STATE"
exit "$BODY_RC"

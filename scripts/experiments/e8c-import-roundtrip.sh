#!/bin/bash
# E8 (import half) + functional probe — install a runtime from an exported installer, prove it works
# (create + boot + shutdown + delete a device), then remove the runtime so the machine ends in its
# prior state. Staging is measured by e11-staging-monitor.sh in import mode.
#
# Usage: scripts/experiments/e8c-import-roundtrip.sh <path to *_Cryptex.dmg or .exportedBundle> --i-understand
#
# THE FUNCTIONAL PROBE BOOTS A DEVICE IN THE DEFAULT DEVICE SET — the one you run real test suites
# against. Check nothing is running first:  pgrep -fl xcodebuild ; xcrun simctl list devices
# The device it creates is named xcv-probe-<platform> and is deleted by UDID, including on a crash.
#
# ---------------------------------------------------------------------------------------------
# REWRITTEN 2026-09-16. Three things in the previous version were wrong, and two of them had already
# been decided against elsewhere in this repo — the script simply was never updated to match.
#
# 1. `xcrun simctl delete unavailable` ran unconditionally at the end. That sweeps EVERY unavailable
#    device in the user's default set, not the ones this script made. F10's own round-trip recorded
#    why that is destructive: offloading a runtime marks the user's real devices Unavailable, and
#    they come back automatically on reimport — CoreSimulator rebinds by OS version, so nothing is
#    lost unless something deletes them first. `doctor` is tested to say "Do NOT run
#    `xcrun simctl delete unavailable`" in exactly that state, and the product has removed this same
#    pattern three times. The experiment kept doing it. It now REPORTS what went unavailable and
#    deletes nothing.
#
# 2. `simctl bootstatus -b` waited for boot. EXPERIMENTS.md already specifies "poll `list devices`
#    for `Booted` — never `bootstatus -b`", because E11 measured it hanging on a non-terminal
#    `Data Migration` status for minutes after the device had booted. The protocol was written; this
#    script was the only thing still ignoring it.
#
# 3. It was hardcoded to tvOS, and when no tvOS runtime appeared it silently skipped the entire
#    probe and still wrote an evidence file that reads like a run. STATUS 2026-09-13 records the
#    consequence: the script was abandoned mid-session and the steps were done by hand instead. It
#    is now platform-general — it probes whatever the import actually added — and a mismatch is a
#    refusal with a reason, not a skip.
#
# Reviewed 2026-09-16 after the rewrite, and the review found the rewrite worse than the original in
# three places, all of them on paths that had never been executed: a leftover lowercase `$rid` made
# the probe unreachable while blaming simctl for it; `cleanup` deleted the state directory that
# phase 5's report needed, so the replacement for `delete unavailable` printed a blank that reads as
# zero; and `runtime delete` was being handed the SimRuntime identifier instead of the runtime image
# UUID the CLI documents, which the ORIGINAL script had right. Fixed, and none of it was visible
# from the refusal paths, which were all that had been run.
#
# THE GUARD THAT MAKES (3) SAFE, and it is the load-bearing one:
#   "Restore prior state" means deleting the runtime this script imported. If that runtime was
#   ALREADY INSTALLED before the import, the cleanup would delete something the user had — and on
#   this machine both available installers are for installed runtimes, so a naive generalisation
#   would have removed the iOS runtime that the user's two iPhone devices depend on. So the probe
#   target must be a runtime that APPEARED during the import. If nothing appeared, the script
#   refuses and deletes nothing. A round trip is only meaningful for a runtime that was not there.
# ---------------------------------------------------------------------------------------------

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CTL="$XCV_ROOT/.build/debug/xcodevaultctl"
IN="${1:-}"
if [ -z "$IN" ] || [ "${2:-}" != "--i-understand" ]; then
  echo "usage: $0 <installer path> --i-understand" >&2
  echo "  This boots a device in your DEFAULT device set. Check nothing is running against it first:" >&2
  echo "    pgrep -fl xcodebuild; xcrun simctl list devices" >&2
  exit 2
fi

case "$IN" in
  *.exportedBundle)
    DMG=$(ls "$IN"/Restore/*_Cryptex.dmg 2>/dev/null | head -1)
    [ -n "$DMG" ] || { echo "REFUSING: no Restore/*_Cryptex.dmg inside $IN" >&2; exit 2; };;
  *) DMG="$IN";;
esac
[ -f "$DMG" ] || { echo "REFUSING: $DMG is not a file." >&2; exit 2; }
[ -x "$CTL" ] || { echo "REFUSING: $CTL not built. Run: swift build" >&2; exit 2; }

# --- pre-flight: do not spend a 10 GB import to then refuse ---------------------------------------
# The authoritative guard is in phase 2 (did a NEW runtime appear?), and it stays there because only
# the import can answer that honestly. But running the import first means a 10.6 GB operation just to
# discover the runtime was already installed. Apple's export filenames encode the platform and
# version — iphonesimulator_26.5_23F77.dmg — so a cheap filter can refuse up front.
#
# Advisory by construction: if the name cannot be parsed this says so and continues, and phase 2
# still decides. A pre-flight that cannot read the name must not be able to veto a real experiment.
installed_versions_for() {  # <platform token, e.g. iOS> -> registered versions, one per line
  xcrun simctl list runtimes -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
plat = sys.argv[1].lower()
try: rs = json.load(sys.stdin)["runtimes"]
except Exception: sys.exit(0)
for r in rs:
    if plat == (r.get("platform") or "").lower() or plat in (r.get("identifier") or "").lower():
        print(r.get("version",""))' "$1"
}

BASE=$(basename "$IN")
PRE_PLATFORM=""
case "$BASE" in
  iphonesimulator_*)  PRE_PLATFORM="iOS";;
  watchsimulator_*)   PRE_PLATFORM="watchOS";;
  appletvsimulator_*) PRE_PLATFORM="tvOS";;
  xrsimulator_*)      PRE_PLATFORM="xrOS";;
esac
PRE_VERSION=$(echo "$BASE" | sed -n 's/^[a-z]*simulator_\([0-9][0-9.]*\)_.*/\1/p')
if [ -n "$PRE_PLATFORM" ] && [ -n "$PRE_VERSION" ]; then
  if installed_versions_for "$PRE_PLATFORM" | grep -qx "$PRE_VERSION"; then
    echo "REFUSING: $PRE_PLATFORM $PRE_VERSION is already installed on this machine." >&2
    echo "  E8c is a ROUND TRIP: import, probe, remove, back to where we started. Removing a runtime" >&2
    echo "  you already had is not restoring prior state, it is taking something away — and here it" >&2
    echo "  would be the runtime your simulator devices bind to." >&2
    echo "  Use an installer for a runtime you do NOT have, or offload this one first." >&2
    echo "  (Refused before importing, to avoid spending the copy to reach the same answer.)" >&2
    exit 3
  fi
  echo "pre-flight: $PRE_PLATFORM $PRE_VERSION is not installed — proceeding." >&2
else
  echo "pre-flight: could not read platform/version from '$BASE'; phase 2 will decide." >&2
fi

OUT="$XCV_EVIDENCE_DIR/e8c-import-$(xcv_env_slug).txt"
xcv_rotate_out "$OUT" || exit 2

# The body runs in a pipeline, so the trap cannot see its variables. One file per fact.
STATE=$(mktemp -d -t xcv-e8c-state) || exit 2

# The trap lives HERE, in the parent, not inside the `{ … }` body below.
#
# Measured 2026-09-17 on this machine (bash 3.2, macOS 26.7), with a minimal reproduction —
# `{ trap cleanup EXIT INT TERM HUP; echo BODY; sleep 60; } 2>&1 | cat`:
#
#     trap position   normal exit   any interruption
#     parent          RUNS          does not run
#     body            does not run  does not run
#
# Interruption was tried four ways: SIGTERM to the parent alone, SIGTERM to the whole pipeline, and
# SIGINT to the process group (what Ctrl-C sends), against both placements. None cleaned up.
#
# So a body trap is useless in every case, and a parent trap is worth having for the normal exit
# path. A previous version of this file put the trap inside the body on review advice — "the
# subshell is where the device's lifecycle lives" — which sounds right and is wrong: it silently
# gave up the one path that did work. This script BOOTS A DEVICE IN THE USER'S DEFAULT SET, so that
# regression mattered.
#
# What is still true and not fixed: an interrupted run can leave the probe device booted. The whole
# harness shares this (ten scripts use the body-in-a-pipeline shape) and the fix is structural —
# take the body out of the pipeline so the shell that owns the trap is the one receiving signals.
# That is recorded in EXPERIMENTS.md under "Harness", unvalidated, rather than half-applied here.
trap 'cleanup 2>&1 | xcv_redact >> "$OUT"' EXIT INT TERM HUP

# --- instruments ---------------------------------------------------------------------------------

# Runtime identifiers currently registered, one per line.
rids() {
  xcrun simctl list runtimes -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
try: rs = json.load(sys.stdin)["runtimes"]
except Exception: sys.exit(1)
for r in rs: print(r.get("identifier",""))' | sed '/^$/d' | LC_ALL=C sort
}

# Devices that are NOT available: "name<TAB>udid<TAB>runtime" — used to REPORT, never to delete.
unavailable_devices() {
  xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
d = json.load(sys.stdin)["devices"]
for k, v in d.items():
    for x in v:
        if not x.get("isAvailable"): print("%s\t%s\t%s" % (x["name"], x["udid"], k))' 2>/dev/null
}

# Prints the device state, "?" when absent, or "UNREADABLE" when the instrument failed. Those are
# three different facts and the previous version collapsed the last two into empty output — which
# cleanup read as "gone" and wait_for_boot polled against for the full timeout.
device_state() {
  local out
  out=$(xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
try: d = json.load(sys.stdin)["devices"]
except Exception: print("UNREADABLE"); raise SystemExit
print(next((x["state"] for v in d.values() for x in v if x["udid"] == sys.argv[1]), "?"))' "$1")
  echo "${out:-UNREADABLE}"
}

# A device type this runtime actually supports, straight from simctl rather than guessed by name.
# The old script hardcoded "Apple TV", which is half of why it only ever worked for tvOS.
device_type_for() {
  xcrun simctl list -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
rid = sys.argv[1]
d = json.load(sys.stdin)
for r in d.get("runtimes", []):
    if r.get("identifier") == rid:
        sdt = r.get("supportedDeviceTypes") or []
        if sdt: print(sdt[0]["identifier"]); break' "$1"
}

# Poll for Booted. Never bootstatus -b (E11: hangs on Data Migration long after the device is up).
wait_for_boot() {
  local udid="$1" deadline=$((SECONDS + ${XCV_BOOT_TIMEOUT:-300})) st
  while [ "$SECONDS" -lt "$deadline" ]; do
    st=$(device_state "$udid")
    if [ "$st" = "Booted" ]; then echo "Booted after $((SECONDS)) s of polling"; return 0; fi
    sleep 2
  done
  echo "TIMEOUT: still '$(device_state "$udid")' after ${XCV_BOOT_TIMEOUT:-300} s"
  return 1
}

# Deletes ONLY the device this script created, by UDID. Never `delete unavailable`.
cleanup() {
  [ -f "$STATE/cleaned" ] && return 0
  : > "$STATE/cleaned"
  local udid
  udid=$(cat "$STATE/udid" 2>/dev/null || true)
  echo "## cleanup"
  if [ -n "$udid" ]; then
    echo "# probe device $udid — shutdown then delete, by UDID"
    xcrun simctl shutdown "$udid" >/dev/null 2>&1; echo "## shutdown -> exit $?"
    xcrun simctl delete "$udid"   >/dev/null 2>&1; echo "## delete   -> exit $?"
    case "$(device_state "$udid")" in
      "?") ;;
      UNREADABLE) echo "!! could not confirm removal of $udid — check: xcrun simctl list devices";;
      *) echo "!! $udid still present. Remove by hand: xcrun simctl delete $udid";;
    esac
  else
    echo "# no probe device was created"
  fi
  # $STATE is NOT removed here. It used to be, and phase 5 then wrote its unavailable-device report
  # into a directory that no longer existed — so the report that replaced `delete unavailable`, the
  # load-bearing half of this rewrite, printed a blank that reads as zero. The parent removes it
  # after the pipeline, which also lets the `cleaned` sentinel survive to do its job.
}

{
  xcv_header "E8c: import from an exported installer + functional probe + restore prior state"
  echo "# installer: $DMG ($(du -sk "$DMG" 2>/dev/null | cut -f1) KB)"
  echo "# The probe device is created in the DEFAULT device set and deleted by UDID on every exit"
  echo "# path this shell can catch: normal completion, INT/TERM/HUP, and any error exit. A SIGKILL"
  echo "# or power loss can still leave it — check for a device named xcv-probe-* after any such."
  echo

  echo "== phase 0 — before =="
  rids > "$STATE/before" || { echo "!! could not read the runtime list; refusing."; exit 4; }
  echo "## runtimes before"
  sed 's/^/   /' "$STATE/before"
  xcv_run "devices before (must be unchanged at the end, except our probe)" \
    bash -c "xcrun simctl list devices"
  unavailable_devices > "$STATE/unavail-before"
  echo "## devices already unavailable before we started: $(wc -l < "$STATE/unavail-before" | tr -d ' ')"
  sed 's/^/   /' "$STATE/unavail-before"
  echo

  echo "== phase 1 — import (monitored) =="
  "$XCV_ROOT/scripts/experiments/e11-staging-monitor.sh" import "$DMG" 1.5
  echo "[import monitor exit=$?]"
  echo

  echo "== phase 2 — what did the import actually add? =="
  rids > "$STATE/after" || { echo "!! could not read the runtime list after the import; refusing."; exit 4; }
  echo "## runtimes after"
  sed 's/^/   /' "$STATE/after"
  comm -13 "$STATE/before" "$STATE/after" > "$STATE/new"
  NEW_COUNT=$(sed '/^$/d' "$STATE/new" | wc -l | tr -d ' ')
  echo "## newly registered: ${NEW_COUNT}"
  sed 's/^/   /' "$STATE/new"
  echo

  # The guard the whole rewrite turns on. "Restore prior state" deletes the runtime we imported, so
  # it must be one that was not here before. Both installers on this machine are for runtimes that
  # ARE installed, and the previous version would have deleted the live one.
  if [ "$NEW_COUNT" != "1" ]; then
    echo "== REFUSING TO PROBE, and deleting nothing =="
    if [ "$NEW_COUNT" = "0" ]; then
      echo "The import registered no NEW runtime. Either this runtime was already installed, or the"
      echo "import failed — the monitor output above says which."
      echo
      echo "This is not a failure of the experiment, it is the experiment declining to run. A round"
      echo "trip means import, probe, remove, back to where we started. If the runtime was already"
      echo "here, the 'remove' step would delete something you had — and on this machine that is the"
      echo "iOS runtime your two iPhone devices bind to. Export a runtime you do NOT have installed,"
      echo "or offload this one first, then run E8c against the installer."
    else
      echo "The import registered ${NEW_COUNT} new runtimes. This script removes exactly what it"
      echo "added, and it will not guess which of several to remove."
    fi
    exit 3
  fi

  RID=$(sed '/^$/d' "$STATE/new" | head -1)
  echo "## probe target: $RID  (registered DURING this run, so removing it restores prior state)"
  # "During", not "by": Xcode downloads runtimes in the background and they land in the same
  # registry, and the import window is minutes. If the pre-flight could read the installer name,
  # cross-check that the thing that appeared is the thing we imported.
  if [ -n "$PRE_PLATFORM" ]; then
    case "$RID" in
      *"SimRuntime.$PRE_PLATFORM"-*) echo "## cross-check: matches the installer's platform ($PRE_PLATFORM)";;
      *) echo "!! REFUSING: the installer is $PRE_PLATFORM but what appeared is $RID."
         echo "   Something else registered a runtime while this import ran. Not deleting it."
         exit 3;;
    esac
  fi

  # Two identifiers, two namespaces — the previous rewrite collapsed them and would have passed the
  # wrong one to `runtime delete`. `simctl create` wants the SimRuntime.* identifier; the CLI's
  # `runtime delete` wants the runtime IMAGE UUID (M2Commands.swift: "UUID from runtime list"),
  # which comes from `simctl runtime list -j` — a different command, keyed by that UUID.
  IMG_UUID=$(xcrun simctl runtime list -j 2>/dev/null | /usr/bin/python3 -c \
'import json,sys
rid = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
for k, v in d.items():
    if v.get("runtimeIdentifier") == rid: print(k); break' "$RID")
  echo "## runtime image UUID: ${IMG_UUID:-<unresolved>}"
  xcv_run "verify" xcrun simctl runtime verify "${IMG_UUID:-$RID}"

  DEVTYPE=$(device_type_for "$RID")
  if [ -z "$DEVTYPE" ]; then
    echo "!! REFUSING: simctl reports no supported device type for $RID, so there is nothing to boot."
    echo "   The runtime stays installed — this script only removes what it has finished probing."
    exit 4
  fi
  PLATFORM=$(echo "$RID" | sed 's/.*SimRuntime\.//; s/-.*//' | tr '[:upper:]' '[:lower:]')
  NAME="xcv-probe-${PLATFORM:-rt}"
  echo "## device type: $DEVTYPE"
  echo "## probe device name: $NAME  (distinctive on purpose; the UDID below is what is acted on)"
  echo

  echo "== phase 3 — functional probe in the DEFAULT device set =="
  # `simctl create` prints the UDID it just made. The previous version looked the device up BY NAME
  # afterwards, which takes the FIRST match — a leftover from a failed earlier run, or the device of
  # a concurrent run — and could boot and delete one it did not create. It also left a window
  # between create and recording the UDID in which a signal orphaned the device.
  echo "## create device"
  echo "\$ xcrun simctl create $NAME $DEVTYPE $RID"
  CREATE_OUT=$(xcrun simctl create "$NAME" "$DEVTYPE" "$RID" 2>&1); CREATE_RC=$?
  echo "$CREATE_OUT"
  echo "[exit=$CREATE_RC]"
  UDID=$(printf '%s' "$CREATE_OUT" | tail -1 | tr -d '[:space:]')
  case "$UDID" in
    [0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*) ;;
    *) echo "!! REFUSING: create did not return a UDID, so there is nothing to probe. If it did"
       echo "   create something, the output above is the only record — check by hand:"
       echo "   xcrun simctl list devices | grep $NAME"
       exit 4;;
  esac
  printf '%s' "$UDID" > "$STATE/udid"     # the trap can find it from here on
  echo "# probe UDID: $UDID"

  xcv_run "boot device" xcrun simctl boot "$UDID"
  echo "## wait for boot — polling list devices, NOT bootstatus -b"
  echo "# E11 measured bootstatus -b reporting a non-terminal Data Migration status for minutes"
  echo "# after the device had actually booted. EXPERIMENTS.md specifies polling; this now matches."
  wait_for_boot "$UDID"
  BOOT_RC=$?
  echo "[boot wait rc=$BOOT_RC]"
  xcv_run "device state, read back independently" bash -c "xcrun simctl list devices | grep -F -- \"$UDID\""
  echo

  echo "== phase 4 — restore prior state =="
  cleanup                                     # our device, by UDID, and only ours
  if [ "$BOOT_RC" != "0" ]; then
    echo "!! NOT deleting the runtime: the probe never reached Booted (see phase 3)."
    echo "   This experiment exists to prove the imported runtime WORKS. Removing it after a failed"
    echo "   probe would destroy the evidence and report a completed round trip that did not happen."
    echo "   $RID stays installed. Remove it by hand when you have looked:"
    echo "     $CTL runtime delete ${IMG_UUID:-<uuid from: xcrun simctl runtime list>} --yes"
    exit 4
  fi
  if [ -z "$IMG_UUID" ]; then
    echo "!! NOT deleting the runtime: could not resolve its image UUID, and \`runtime delete\` takes"
    echo "   that rather than the SimRuntime identifier. $RID stays installed."
    exit 4
  fi
  xcv_run "runtime delete (removing exactly what phase 1 added)" "$CTL" runtime delete "$IMG_UUID" --yes
  echo

  echo "== phase 5 — accounting =="
  echo "## runtimes after cleanup (compare with phase 0)"
  rids | sed 's/^/   /'
  unavailable_devices > "$STATE/unavail-after" 2>/dev/null || true
  echo "## devices unavailable now: $(wc -l < "$STATE/unavail-after" 2>/dev/null | tr -d ' ')"
  sed 's/^/   /' "$STATE/unavail-after" 2>/dev/null
  echo
  echo "# NOT running 'simctl delete unavailable', and that is deliberate."
  echo "# Removing the runtime marks every device bound to it Unavailable. Those devices are NOT"
  echo "# broken and are NOT garbage: E8/F-round-trip measured them returning to Shutdown on their"
  echo "# own once the same-version runtime is reimported, because CoreSimulator rebinds by OS"
  echo "# version rather than by the runtime's internal UUID. 'delete unavailable' is permanent and"
  echo "# sweeps the whole default set. doctor is tested to refuse to recommend it in this exact"
  echo "# state; an experiment has no licence the product does not have."
  echo
  xcv_run "devices after (compare with phase 0)" bash -c "xcrun simctl list devices"
  xcv_run "asset stores" bash -c "du -sk /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime"
  xcv_run "internal free" df -h /System/Volumes/Data
  echo 0 > "$STATE/outcome"
} 2>&1 | xcv_redact | tee "$OUT"

# Exit codes: 0 round trip completed · 2 bad arguments · 3 refused, nothing touched · 4 could not
# finish (the evidence says what is left behind). The body runs in a subshell, so its `exit` only
# leaves the pipeline; without this the script's status was the last echo's and always 0.
RC=$(cat "$STATE/outcome" 2>/dev/null || echo 4)
rm -rf "$STATE"
echo
echo "wrote $OUT"
echo "exit $RC  (0 completed · 3 refused · 4 unfinished)"
exit "$RC"

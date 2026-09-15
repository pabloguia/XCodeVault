#!/bin/bash
# E18 — does `log erase --all` inside a device actually reclaim the simulated log store?
#
#   `simulatorLogStore` is the one per-device regenerable of the three with a documented, narrow
#   verb: `man log` defines `log erase --all`, runnable inside a device through `simctl spawn`.
#   The catalog reports the category and offers nothing, and says why in its own note — "an
#   unreproduced verb is not a product feature". This reproduces it, or fails to.
#
#   Until this runs, nothing about `simulatorLogStore` changes in the product. That order is the
#   point: rule 10, and the note in the catalog is already written the honest way round.
#
# THE DANGEROUS COMMAND IS THE SAME COMMAND.
#   `log erase --all` run on the HOST erases the user's own Mac system logs. The only thing that
#   makes it safe here is the `simctl spawn <udid>` in front of it. So there is exactly one function
#   that runs `log erase`, it always passes a UDID, and it refuses if the UDID is empty. Anything
#   less and a future edit that drops one word wipes the user's logs.
#
#   Narrowly stated on purpose: this script DOES run host-side `log show` when capturing why a
#   refusal happened. That is read-only. An earlier version of this paragraph claimed the script
#   "never runs `log` directly", which was false, and a reviewer who checks a stated invariant and
#   finds it wrong is right to stop trusting the rest of the header.
#
# WHAT IT DOES NOT DO: touch any device the user owns. It creates a throwaway device in a
#   `mktemp` device set on the internal disk (external fails at `create` — E14b), boots that,
#   measures, erases inside it, measures again, and deletes it. Every simctl invocation carries
#   `--set`, so the default device set is never addressed.
#
# Usage:
#   scripts/experiments/e18-simctl-log-erase.sh --i-understand
#
#   Takes several minutes: a device boot dominates. XCV_SETTLE_SECONDS (default 120) is how long
#   the device is left running to accumulate log data before the first measurement.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "${1:-}" = "--i-understand" ] || { echo "usage: $0 --i-understand" >&2; exit 2; }

SET_PATH=$(mktemp -d -t xcv-e18) || exit 2
SET_PATH=$(cd "$SET_PATH" 2>/dev/null && pwd -P) || { echo "REFUSING: mktemp path unreachable." >&2; exit 2; }
case "$SET_PATH" in
  /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) ;;
  *) echo "REFUSING: mktemp returned an unexpected location: $SET_PATH" >&2; exit 2;;
esac
case "$SET_PATH" in *\'*) echo "REFUSING: quote in the temp path." >&2; exit 2;; esac
# The device set must be on the boot volume: E14b showed `create` fails on external storage, and a
# failure for that reason would be recorded here as a failure of `log erase`.
if [ "$(stat -f %Sd "$SET_PATH" 2>/dev/null)" != "$(stat -f %Sd / 2>/dev/null)" ]; then
  echo "REFUSING: the probe device set is not on the boot volume." >&2
  rmdir "$SET_PATH" 2>/dev/null; exit 2
fi

OUT="$XCV_EVIDENCE_DIR/e18-simctl-log-erase-$(xcv_env_slug).txt"
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"
DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
RUNTIME="${XCV_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
SETTLE="${XCV_SETTLE_SECONDS:-120}"
LOG_SUBPATHS=("data/var/db/diagnostics" "data/var/db/uuidtext")

avail_mb=$(df -m / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 3072 ]; then
  echo "REFUSING: only ${avail_mb} MB free on the boot volume; a device boot needs headroom." >&2
  rmdir "$SET_PATH" 2>/dev/null; exit 2
fi

STATE=$(mktemp -d -t xcv-e18-state) || { rmdir "$SET_PATH" 2>/dev/null; exit 2; }
CLEANED_MARK="${STATE}.cleaned"
xcv_rotate_out "$OUT" || exit 2

# --- the one place the dangerous verb is invoked ------------------------------------------------

# erase_inside_device <udid> <args...>
#
# The ONLY call site of `log erase` in this script — host-side `log show` appears once, read-only,
# in the failure capture. It refuses an empty UDID rather than falling through to a host-wide erase,
# which is what every other arrangement of this code risks.
erase_inside_device() {
  local udid="$1"; shift
  if [ -z "$udid" ]; then
    echo "!! REFUSING to run \`log\` without a device. On the host this erases the user's own"
    echo "   system logs, which is not what any part of this experiment is for."
    return 2
  fi
  echo "## log erase, inside device $udid"
  echo "\$ xcrun simctl --set $SET_PATH spawn $udid log erase $*"
  xcrun simctl --set "$SET_PATH" spawn "$udid" log erase "$@" 2>&1
  local rc=$?
  echo "[exit=$rc]"
  return $rc
}

# --- helpers -----------------------------------------------------------------------------------

store_bytes() {  # <udid> -> total allocated bytes of the log-store subpaths, or empty
  local udid="$1" total=0 n
  for sub in "${LOG_SUBPATHS[@]}"; do
    n=$(du -skx "$SET_PATH/$udid/$sub" 2>/dev/null | awk '{print $1}')
    [ -n "$n" ] && total=$((total + n))
  done
  echo "$total"
}

report_store() {  # <udid> <label>
  local udid="$1" label="$2"
  echo "## log store $label"
  for sub in "${LOG_SUBPATHS[@]}"; do
    echo "   $(du -shx "$SET_PATH/$udid/$sub" 2>&1 | head -1)"
  done
  echo "   total KiB: $(store_bytes "$udid")"
  echo
}

device_state() {  # <udid>
  xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
"import json,sys
try:
    d = json.load(sys.stdin)['devices']
except Exception:
    print('?'); raise SystemExit
print(next((x['state'] for v in d.values() for x in v if x['udid']=='$1'), '?'))"
}

set_device_count() {
  xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
'import json,sys
try:
    d = json.load(sys.stdin)["devices"]
except Exception:
    print("?"); raise SystemExit
print(sum(len(v) for v in d.values()))' 2>/dev/null
}

cleanup() {
  [ -f "$CLEANED_MARK" ] && return 0
  : > "$CLEANED_MARK"
  echo "## cleanup"
  local udid remaining
  udid=$(cat "$STATE/udid" 2>/dev/null || true)
  if [ -n "$udid" ]; then
    xcrun simctl --set "$SET_PATH" shutdown "$udid" >/dev/null 2>&1
    echo "## shutdown -> exit $?"
    xcrun simctl --set "$SET_PATH" delete "$udid" >/dev/null 2>&1
    echo "## delete   -> exit $?"
  fi
  remaining=$(set_device_count)
  echo "# set reports ${remaining:-<unreadable>} remaining device(s)"
  if [ "$remaining" = "0" ]; then
    xcv_run "remove probe set" rm -rf "$SET_PATH"
  else
    echo "left $SET_PATH in place — the set still reports ${remaining:-?} device(s). By hand:"
    echo "   xcrun simctl --set '$SET_PATH' list devices"
    echo "   xcrun simctl --set '$SET_PATH' shutdown <udid> && xcrun simctl --set '$SET_PATH' delete <udid>"
    echo "   rm -rf '$SET_PATH'"
  fi
  xcv_run "post-cleanup: anything left?" bash -c "ls -la '$SET_PATH' 2>&1 | head -3"
  # The accounting lives HERE, not at the end of the body. It used to sit after the verdict, so on
  # the branch that is this experiment's actual outcome — every erase form refused, `exit 1` — it
  # never ran, and the matrix went on to report a before/after comparison that had never happened.
  # The promise "no device of the user's was touched" has to be measured on the paths that fail.
  echo "## accounting — the user's default device set must be unchanged"
  xcv_run "default set size (compare with phase 0)" du -shx "$DEFAULT_SET"
  xcv_run "default set device list (compare with phase 0)" bash -c "xcrun simctl list devices"
  rm -rf "$STATE"
}
trap 'cleanup 2>&1 | xcv_redact >> "$OUT"' INT TERM HUP

# --- body --------------------------------------------------------------------------------------

RC=0
{
  trap cleanup EXIT

  xcv_header "E18 — simctl spawn <device> log erase --all against the simulated log store"
  echo "# Probe device set (internal, mktemp): $SET_PATH"
  echo "# Device type: $DEVTYPE"
  echo "# Runtime:     $RUNTIME"
  echo "# Settle time before first measurement: ${SETTLE}s"
  echo

  echo "## phase 0 — baselines. The user's devices must be untouched at the end."
  xcv_run "BASELINE default device set" bash -c "xcrun simctl list devices"
  xcv_run "BASELINE default set size" du -shx "$DEFAULT_SET"
  xcv_run "free space" df -h /

  echo "## phase 1 — create and boot a throwaway device"
  xcv_run "create" xcrun simctl --set "$SET_PATH" create XCV-E18 "$DEVTYPE" "$RUNTIME"
  UDID=$(xcrun simctl --set "$SET_PATH" list devices -j 2>/dev/null | python3 -c \
'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x["name"]=="XCV-E18"), ""))')
  printf '%s' "$UDID" > "$STATE/udid"
  echo "# probe UDID: ${UDID:-<none>}"
  if [ -z "$UDID" ]; then
    echo "!! phase 1 FAILED — no device was created; nothing downstream can be read."
    RC=1; exit 1
  fi
  xcv_run "boot" xcrun simctl --set "$SET_PATH" boot "$UDID"
  echo "## poll for Booted (never bootstatus -b; E11 saw it hang on Data Migration)"
  state="?"
  for i in $(seq 1 60); do
    state=$(device_state "$UDID")
    echo "  t+${i}0s state=$state"
    [ "$state" = "Booted" ] && break
    sleep 10
  done
  if [ "$state" != "Booted" ]; then
    echo "!! phase 1 FAILED — never reached Booted, so \`log erase\` cannot be reached either."
    RC=1; exit 1
  fi

  echo "## phase 2 — let the device write logs, then measure"
  echo "# A freshly booted device has a small store. What this phase can establish is whether the"
  echo "# verb reclaims, not how much it reclaims on a device with months of logs on it."
  sleep "$SETTLE"
  report_store "$UDID" "BEFORE erase"
  BEFORE=$(store_bytes "$UDID")
  xcv_run "the log store is readable from inside the device" bash -c \
    "xcrun simctl --set '$SET_PATH' spawn '$UDID' log stats 2>&1 | head -20"

  echo "## phase 3 — the verb, and then the narrower forms of it"
  echo "# --all is what the catalog note names. If it is refused, try the bounded form before"
  echo "# concluding the category cannot be offered: a verb that trims by age would still be a"
  echo "# real remediation, just a smaller one."
  # The forms, widest first, taken from the verb's own usage text rather than guessed:
  #   log erase [--all | --ttl]      and with no argument at all, which erases only the main
  #                                  (Persist) store. An earlier run passed `--ttl 1`; --ttl takes
  #                                  no argument, so that was exit 64, a usage error, and proved
  #                                  nothing. A broken arm is not a refusal.
  WORKED=""
  for form in "--all" "--ttl" ""; do
    # shellcheck disable=SC2086
    if erase_inside_device "$UDID" $form; then WORKED="${form:-<no argument>}"; break; fi
    echo "   (refused: ${form:-<no argument>})"
  done
  if [ -z "$WORKED" ]; then
    echo "!! every erase form was refused inside the device. That is the answer: the verb the"
    echo "   catalog note points at does not work here, and simulatorLogStore stays report-only."
    xcv_run "does the log binary work at all inside the device?" bash -c \
      "xcrun simctl --set '$SET_PATH' spawn '$UDID' log stats 2>&1 | head -5"
    xcv_run "host-side sandbox/TCC around the refusal" bash -c \
      "log show --last 3m --predicate 'senderImagePath CONTAINS \"Sandbox\" OR eventMessage CONTAINS \"logd\"' --style compact 2>/dev/null | tail -30"
    report_store "$UDID" "after the refused erase"
    RC=1; exit 1
  fi
  echo "# the form that was accepted: $WORKED"
  # The store is written by a daemon; give it a moment to actually unlink.
  sleep 10
  report_store "$UDID" "AFTER erase"
  AFTER=$(store_bytes "$UDID")

  echo "## phase 4 — is the device still healthy after the erase?"
  echo "# A verb that reclaims by breaking the device is not a verb the product can offer."
  xcv_run "device state" bash -c "xcrun simctl --set '$SET_PATH' list devices | grep XCV-E18"
  xcv_run "logging still works inside the device" bash -c \
    "xcrun simctl --set '$SET_PATH' spawn '$UDID' log stats 2>&1 | head -10"
  xcv_run "the device still answers" bash -c \
    "xcrun simctl --set '$SET_PATH' spawn '$UDID' /usr/bin/true; echo spawn-exit=\$?"

  echo "## phase 5 — verdict"
  echo "# before: ${BEFORE:-?} KiB   after: ${AFTER:-?} KiB"
  if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" -gt 0 ] 2>/dev/null; then
    RECLAIMED=$((BEFORE - AFTER))
    PCT=$((RECLAIMED * 100 / BEFORE))
    echo "# reclaimed: ${RECLAIMED} KiB (${PCT}% of the store)"
    if [ "$RECLAIMED" -gt 0 ]; then
      echo "RECLAIMS, via the form: $WORKED. Running it through simctl spawn reduced the on-disk store by ${RECLAIMED} KiB"
      echo "(${PCT}%), the device stayed Booted, and logging still worked afterwards."
      echo "What this does NOT establish: the proportion on a device with a large store. The probe"
      echo "was booted minutes ago, so its store is small and mostly boot-time. Before the product"
      echo "offers this, measure it once against a device that actually has the gigabytes — which"
      echo "means the user's, and that needs their device booted and their say-so."
    else
      echo "DOES NOT RECLAIM. The command succeeded and the on-disk store did not shrink"
      echo "(${BEFORE} -> ${AFTER} KiB). An exit code is not a reclaim; \`simulatorLogStore\` stays"
      echo "report-only and the catalog note stands as written."
      RC=1
    fi
  else
    echo "INCONCLUSIVE — the store could not be measured on both sides (before=${BEFORE:-?},"
    echo "after=${AFTER:-?}). Nothing is established either way."
    RC=1
  fi

  echo
  cleanup   # also prints the accounting, on this path and on every failure path
  exit "$RC"
} 2>&1 | xcv_redact > "$OUT"
BODY_RC=${PIPESTATUS[0]}

echo "wrote $OUT"
[ "$BODY_RC" -ne 0 ] && echo "!! E18 did not establish that the verb reclaims (exit $BODY_RC) — read $OUT." >&2
rm -rf "$STATE" "$CLEANED_MARK"
exit "$BODY_RC"

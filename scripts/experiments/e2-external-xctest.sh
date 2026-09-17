#!/bin/bash
# E2 — Does the external-volume xctest restriction follow the DEVICE or the PATH? (gates H6)
#
# Same framework+XCTest fixture, DerivedData placed on:
#   A   internal disk (control)
#   B   a real external device under /Volumes                (needs XCV_E2_EXTERNAL=/Volumes/<name>)
#   E   an internal path that is a symlink to B
#   C   an APFS disk image attached at /Volumes/<name>       (DiskArbitration: External + Removable)
#   D   the SAME disk image attached at $HOME/<dir>          (same device, non-/Volumes path)
#   C2  a CASE-SENSITIVE APFS disk image at /Volumes         (isolates case sensitivity)
#   D2  the case-insensitive image, hidden nested path       (isolates the .TemporaryItems path used for B)
#   F   a disk image whose BACKING FILE is on the external device  (isolates physical-device I/O path)
#   C3  the case-insensitive image attached with ownership ENABLED (-owners on; isolates noowners vs owners)
# Needs no root. Writes docs/research/evidence/e2-<env>.txt. Cleans up everything it creates.
#
# Usage: XCV_E2_EXTERNAL=/Volumes/MyDrive [XCV_E2_CASES="A B C"] scripts/experiments/e2-external-xctest.sh
source "$(dirname "$0")/common.sh"
FIXTURE="$XCV_ROOT/fixtures/E2Fixture"
EXT="${XCV_E2_EXTERNAL:-}"
SCRATCH="${XCV_E2_SCRATCH:-$HOME/.xcodevault-e2-scratch}"
# A user-writable work dir ON the external device. Volume roots are usually root-owned, so default
# to the per-user temp dir macOS provides for exactly this purpose.
EXTWORK="${XCV_E2_EXTERNAL_DIR:-${EXT:+$EXT/.TemporaryItems/folders.$(id -u)/TemporaryItems/XCodeVault-experiments}}"
DEFAULT_CASES="A B E C D C2 D2 F C3"
CASES="${XCV_E2_CASES:-$DEFAULT_CASES}"
HOMEMOUNT="$HOME/XCodeVault-E2-Mount"
out="$XCV_EVIDENCE_DIR/e2-$(xcv_env_slug)$([ "$CASES" = "$DEFAULT_CASES" ] || echo "-cases-$(echo $CASES | tr ' ' '-')").txt"
SUMMARY=()
MOUNTS="${TMPDIR:-/tmp}/xcv-e2-mounts.$$"
: > "$MOUNTS"

# EXTWORK comes from the environment and is handed to `rm -rf` in cleanup. Require the shape this
# script builds rather than trusting whatever was exported.
if [ -n "$EXTWORK" ]; then
  case "$EXTWORK" in
    */.TemporaryItems/folders.*/TemporaryItems/XCodeVault-experiments) ;;
    *) echo "REFUSING: EXTWORK is not the per-user temp path this script builds: $EXTWORK" >&2; exit 2;;
  esac
fi

want() { [[ " $CASES " == *" $1 "* ]]; }

classify() {  # classify <path> → device/location/removable/protocol/owners of the volume holding it
  local dev; dev=$(df "$1" | awk 'NR==2{print $1}')
  echo "volume-device: $dev"
  diskutil info "$dev" 2>/dev/null | grep -E 'Mount Point|Device Location|Removable Media|Protocol|Owners|File System Personality' | sed 's/^ *//'
}

progress() { echo "$*" >&3 2>/dev/null; }

run_case() {  # run_case <label> <derivedDataPath>
  local label="$1" dd="$2" log rc verdict
  progress "== CASE $label"
  echo "==================== CASE $label ===================="
  echo "DerivedData: $dd"
  classify "$(dirname "$dd")"
  rm -rf "$dd"; mkdir -p "$dd"
  log="$dd.xcodebuild.log"
  ( cd "$FIXTURE" && xcodebuild test -scheme E2Fixture -destination 'platform=macOS' \
      -derivedDataPath "$dd" -quiet >"$log" 2>&1 ); rc=$?
  if [ $rc -eq 0 ] && ! grep -q 'TEST FAILED' "$log"; then verdict="PASS"; else verdict="FAIL"; fi
  echo "xcodebuild exit=$rc verdict=$verdict"
  grep -E 'E2-EVIDENCE|error|Failed to|cannot load|TEST (SUCCEEDED|FAILED)' "$log" | grep -vE 'warning:|DVTProvisioningProfileManager' | sort -u | head -25
  echo "--- swift test --scratch-path (second runner) ---"
  local sp="$dd/spm"; mkdir -p "$sp"
  local spv; if ( cd "$FIXTURE" && swift test --scratch-path "$sp" 2>&1 | tee "$dd.swifttest.log" | grep -E 'E2-EVIDENCE|error:' | head -5; exit "${PIPESTATUS[0]}" ); then spv=PASS; else spv=FAIL; fi
  echo "swift-test verdict=$spv"
  SUMMARY+=("$label | xcodebuild-test=$verdict (exit $rc) | swift-test=$spv | $dd")
  echo
}

attach_image() {  # attach_image <img> [<mountpoint>] [extra hdiutil flags…] → echoes mount point
  local img="$1" mp="${2:-}"; if [ $# -ge 2 ]; then shift 2; else shift; fi; local extra=("$@")
  if [ -n "$mp" ]; then mkdir -p "$mp"; hdiutil attach -quiet -nobrowse -mountpoint "$mp" "${extra[@]}" "$img" || return 1
  else mp=$(hdiutil attach -plist "${extra[@]}" "$img" 2>/dev/null | python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(next(e["mount-point"] for e in d["system-entities"] if e.get("mount-point")))' 2>/dev/null); [ -n "$mp" ] || return 1; fi
  sleep 1
  printf '%s\n' "$mp" >> "$MOUNTS"
  echo "$mp"
}
detach_image() {
  hdiutil detach -quiet "$1" 2>/dev/null || hdiutil detach -force "$1" 2>/dev/null
  [ -f "$MOUNTS" ] && { awk -v m="$1" '$0 != m' "$MOUNTS" > "$MOUNTS.n" 2>/dev/null && mv "$MOUNTS.n" "$MOUNTS"; }
  return 0
}

# --- cleanup ------------------------------------------------------------------------------------
#
# Measured 2026-09-17 on a bench that ran both shapes under five conditions (normal exit, SIGTERM to
# the parent, SIGTERM to every matching process, SIGINT to the parent, SIGINT to the process group):
#
#     shape                          normal   Ctrl-C    SIGTERM
#     { … } | redact | tee | grep    cleans   LEAKS     LEAKS
#     main > file  (this one)        cleans   cleans    cleans, deferred
#
# A brace group in a pipeline is a subshell, and a trap did not run there on any interruption —
# whichever side of the `{` it was written on. Running the body as a FUNCTION with a redirect does
# not fork, so the shell holding the trap is the shell receiving the signal.
#
# "Deferred" is measured, not assumed: with SIGTERM the handler runs when the current foreground
# command finishes, so an interrupt during an `xcodebuild` waits for that build. The bench logged
# ACQ t=0, TERM at t≈1, CLEANED t=6 against a 6-second body. Ctrl-C is prompt because the signal
# reaches the foreground child too.
#
# The same bench showed cleanup firing TWICE on a signal — once from the handler, once from EXIT —
# so the idempotence guard below is required, not tidiness.
CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  local mp
  if [ -s "$MOUNTS" ]; then
    while IFS= read -r mp; do
      [ -n "$mp" ] || continue
      progress "cleanup: detaching $mp"
      hdiutil detach -quiet "$mp" 2>/dev/null || hdiutil detach -force "$mp" 2>/dev/null
      if mount | grep -qF " $mp "; then
        progress "cleanup: STILL MOUNTED $mp — detach by hand: hdiutil detach '$mp'"
        STUCK=1
      fi
    done < "$MOUNTS"
  fi
  # Never delete the backing file of something still mounted: that turns a leak into a mount with
  # no image behind it.
  if [ "${STUCK:-0}" != "1" ]; then
    rmdir "$HOMEMOUNT" 2>/dev/null
    rm -rf "$SCRATCH" ${EXTWORK:+"$EXTWORK"}
  fi
  # Redaction used to happen in the pipeline; it happens here, over whatever the run produced —
  # including a partial transcript, which says what happened where a missing one says nothing.
  if [ -f "$out.raw" ]; then
    # `2>/dev/null &&` used to hide the one failure that matters: if xcv_redact errors, the `&&`
    # short-circuits and `$out.raw` — un-redacted — survives inside the published evidence
    # directory. Let the error be seen, and move the raw file out of the evidence tree either way.
    if xcv_redact < "$out.raw" > "$out"; then
      rm -f "$out.raw"
    else
      mv -f "$out.raw" "${TMPDIR:-/tmp}/$(basename "$out").raw" 2>/dev/null || rm -f "$out.raw"
      echo "REDACTION FAILED: raw transcript moved out of $(dirname "$out"); do not publish it." >&2
    fi
  fi
  rm -f "$MOUNTS" "$MOUNTS.n" 2>/dev/null
}

e2_main() {
  xcv_header "E2 external-volume xctest restriction: device vs path"
  echo "cases: $CASES"; echo
  mkdir -p "$SCRATCH"
  want A && run_case "A-internal" "$SCRATCH/DD-A"

  if [ -n "$EXTWORK" ] && mkdir -p "$EXTWORK/E2" 2>/dev/null; then
    want B && run_case "B-external-device-under-Volumes" "$EXTWORK/E2/DD-B"
    if want E; then ln -sfn "$EXTWORK/E2" "$SCRATCH/E-link"; run_case "E-internal-symlink-to-external" "$SCRATCH/E-link/DD-E"; fi
  else
    echo "!! XCV_E2_EXTERNAL not set / no writable dir on it — cases B, E, F skipped"
  fi

  IMG="$SCRATCH/XCodeVault-E2.sparseimage"
  hdiutil create -quiet -size 2g -fs APFS -type SPARSE -volname XCVE2IMG "$IMG" -ov
  if want C || want D2; then
    if mp=$(attach_image "$IMG"); then
      want C && run_case "C-diskimage-under-Volumes" "$mp/DD-C"
      want D2 && run_case "D2-diskimage-hidden-tempitems-like-path" "$mp/.TemporaryItems/folders.$(id -u)/TemporaryItems/XCodeVault-experiments/E2/DD-D2"
      detach_image "$mp"
    else echo "!! could not attach $IMG at /Volumes"; fi
  fi
  if want D; then
    if mp=$(attach_image "$IMG" "$HOMEMOUNT"); then
      run_case "D-same-diskimage-at-HOME-path" "$mp/DD-D"; detach_image "$mp"; rmdir "$HOMEMOUNT" 2>/dev/null
    else echo "!! disk image did not mount at $HOMEMOUNT"; fi
  fi
  if want C3; then
    if mp=$(attach_image "$IMG" "" -owners on); then
      echo "(owners on) $(mount | grep "$mp" | sed 's/.*(//')"
      run_case "C3-diskimage-owners-enabled-under-Volumes" "$mp/DD-C3"; detach_image "$mp"
    else echo "!! could not attach image with -owners on"; fi
  fi
  rm -f "$IMG"

  if want C2; then
    IMGCS="$SCRATCH/XCodeVault-E2-cs.sparseimage"
    hdiutil create -quiet -size 2g -fs 'Case-sensitive APFS' -type SPARSE -volname XCVE2CS "$IMGCS" -ov
    if mp=$(attach_image "$IMGCS"); then run_case "C2-case-sensitive-diskimage-under-Volumes" "$mp/DD-C2"; detach_image "$mp"; else echo "!! could not attach case-sensitive image"; fi
    rm -f "$IMGCS"
  fi

  if want F && [ -n "$EXTWORK" ] && [ -d "$EXTWORK/E2" ]; then
    IMGF="$EXTWORK/E2/XCodeVault-E2-onext.sparseimage"
    hdiutil create -quiet -size 2g -fs APFS -type SPARSE -volname XCVE2ONEXT "$IMGF" -ov
    if mp=$(attach_image "$IMGF"); then run_case "F-diskimage-backed-by-external-device" "$mp/DD-F"; detach_image "$mp"; else echo "!! could not attach image on external"; fi
    rm -f "$IMGF"
  fi

  echo "==================== SUMMARY ===================="
  printf '%s\n' "${SUMMARY[@]}"
}

exec 3>&2                      # console handle, kept because stdout is about to become a file
trap 'cleanup' EXIT INT TERM HUP

# A function call with a redirect does not fork: this runs in THIS shell, the one the trap is on.
e2_main > "$out.raw" 2>&1
E2_RC=$?

cleanup
[ -f "$out" ] || echo "!! no transcript was produced" >&2
if [ -f "$out" ]; then
  grep -E '^(====|xcodebuild exit|swift-test verdict|!!|[A-F][0-9]?-)' "$out" | head -40
fi
echo "wrote $out"
exit "$E2_RC"

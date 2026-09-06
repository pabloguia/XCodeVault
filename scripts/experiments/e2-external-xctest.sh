#!/bin/bash
# E2 — Does the external-volume xctest restriction follow the DEVICE or the PATH? (gates H6)
#
# Runs the same framework+XCTest fixture with DerivedData placed on:
#   A. internal disk (control)
#   B. a real external device under /Volumes            (needs XCV_E2_EXTERNAL=/Volumes/<name>)
#   C. an APFS disk image attached at /Volumes/<name>    (external+removable per DiskArbitration, no root needed)
#   D. the SAME disk image attached at $HOME/<dir>       (same device, non-/Volumes path)
#   E. an internal path that is a symlink to B           (does the check follow realpath?)
# Needs no root. Writes docs/research/evidence/e2-<env>.txt. Cleans up everything it creates.
#
# Usage: XCV_E2_EXTERNAL=/Volumes/MyDrive scripts/experiments/e2-external-xctest.sh
source "$(dirname "$0")/common.sh"
FIXTURE="$XCV_ROOT/fixtures/E2Fixture"
EXT="${XCV_E2_EXTERNAL:-}"
SCRATCH="${XCV_E2_SCRATCH:-$HOME/.xcodevault-e2-scratch}"
# A user-writable work dir ON the external device. Volume roots are usually root-owned, so default
# to the per-volume temp dir macOS provides for exactly this purpose.
EXTWORK="${XCV_E2_EXTERNAL_DIR:-${EXT:+$EXT/.TemporaryItems/folders.$(id -u)/TemporaryItems/XCodeVault-experiments}}"
IMGDIR="${XCV_E2_IMGDIR:-$SCRATCH}"                  # where the sparse image FILE lives (small)
HOMEMOUNT="$HOME/XCodeVault-E2-Mount"
out="$XCV_EVIDENCE_DIR/e2-$(xcv_env_slug).txt"
SUMMARY=()

classify() {  # classify <path> → device/location/removable/protocol/owners of the volume holding it
  local dev; dev=$(df "$1" | awk 'NR==2{print $1}')
  echo "volume-device: $dev"
  diskutil info "$dev" 2>/dev/null | grep -E 'Mount Point|Device Location|Removable Media|Protocol|Owners|File System Personality' | sed 's/^ *//'
}

run_case() {  # run_case <label> <derivedDataPath>
  local label="$1" dd="$2" log rc verdict
  echo "==================== CASE $label ===================="
  echo "DerivedData: $dd"
  classify "$(dirname "$dd")"
  rm -rf "$dd"; mkdir -p "$dd"
  log="$dd.xcodebuild.log"
  ( cd "$FIXTURE" && xcodebuild test -scheme E2Fixture -destination 'platform=macOS' \
      -derivedDataPath "$dd" -quiet >"$log" 2>&1 ); rc=$?
  if grep -q 'TEST SUCCEEDED' "$log"; then verdict="PASS"; else verdict="FAIL"; fi
  echo "xcodebuild exit=$rc verdict=$verdict"
  grep -E 'E2-EVIDENCE|error:|Failed to load|cannot load|xctest|TEST (SUCCEEDED|FAILED)' "$log" | grep -v 'warning:' | sort -u | head -25
  echo "--- swift test --scratch-path (second runner) ---"
  local sp="$dd/spm"; mkdir -p "$sp"
  ( cd "$FIXTURE" && swift test --scratch-path "$sp" 2>&1 | grep -E 'E2-EVIDENCE|error|Executed|passed|failed' | head -10 ); 
  local spv; ( cd "$FIXTURE" && swift test --scratch-path "$sp" >/dev/null 2>&1 ) && spv=PASS || spv=FAIL
  echo "swift-test verdict=$spv"
  SUMMARY+=("$label | xcodebuild-test=$verdict | swift-test=$spv | $dd")
  echo
}

{
  xcv_header "E2 external-volume xctest restriction: device vs path"
  mkdir -p "$SCRATCH"
  run_case "A-internal" "$SCRATCH/DD-A"

  if [ -n "$EXTWORK" ] && mkdir -p "$EXTWORK/E2" 2>/dev/null; then
    run_case "B-external-device-under-Volumes" "$EXTWORK/E2/DD-B"
    ln -sfn "$EXTWORK/E2" "$SCRATCH/E-link"
    run_case "E-internal-symlink-to-external" "$SCRATCH/E-link/DD-E"
  else
    echo "!! XCV_E2_EXTERNAL not set / no writable dir on it — cases B and E skipped"
  fi

  IMG="$IMGDIR/XCodeVault-E2.sparseimage"
  rm -f "$IMG"
  hdiutil create -quiet -size 2g -fs APFS -type SPARSE -volname XCVE2IMG "$IMG" -ov
  # C: default attach → /Volumes/XCVE2IMG
  hdiutil attach -quiet "$IMG" && sleep 1
  if [ -d /Volumes/XCVE2IMG ]; then
    run_case "C-diskimage-under-Volumes" "/Volumes/XCVE2IMG/DD-C"
    hdiutil detach -quiet /Volumes/XCVE2IMG || hdiutil detach -force /Volumes/XCVE2IMG
  else
    echo "!! disk image did not appear at /Volumes/XCVE2IMG"
  fi
  # D: same image at a $HOME path
  mkdir -p "$HOMEMOUNT"
  hdiutil attach -quiet -nobrowse -mountpoint "$HOMEMOUNT" "$IMG" && sleep 1
  if mount | grep -q "$HOMEMOUNT"; then
    run_case "D-same-diskimage-at-HOME-path" "$HOMEMOUNT/DD-D"
    hdiutil detach -quiet "$HOMEMOUNT" || hdiutil detach -force "$HOMEMOUNT"
  else
    echo "!! disk image did not mount at $HOMEMOUNT"
  fi
  rmdir "$HOMEMOUNT" 2>/dev/null
  rm -f "$IMG"

  echo "==================== SUMMARY ===================="
  printf '%s\n' "${SUMMARY[@]}"
} 2>&1 | xcv_redact | tee "$out.tmp" | grep -E '^(====|DerivedData|xcodebuild exit|swift-test verdict|Device Location|Removable|Mount Point|E2-EVIDENCE|!!|[A-E]-)' 
mv "$out.tmp" "$out"
# cleanup scratch build products (keep nothing on the user's disks)
rm -rf "$SCRATCH" ${EXTWORK:+"$EXTWORK"}
echo "wrote $out"

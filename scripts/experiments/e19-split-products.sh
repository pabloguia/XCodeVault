#!/bin/bash
# E19 — Can the bulk of a build live on a physical external volume while the
# test bundle stays where xctest can load it? (gates H19)
#
# Does not re-run E2. One new question, three layouts, on the current OS:
#   CTRL  entire DerivedData on the external volume (baseline for this OS build)
#   SYM   DerivedData on the external volume, SYMROOT (products) on the internal disk
#   INV   DerivedData on the internal disk, intermediates/index/module cache external
#
# Scratch only. External writes are confined to:
#   <volume>/.TemporaryItems/folders.<uid>/TemporaryItems/XCodeVault-experiments/E19
# Internal writes are confined to ~/.xcodevault-e19-scratch.
# Does not read or delete a vault folder, does not touch CoreSimulator, and does
# not write com.apple.dt.Xcode defaults (no -IDE* flags, no `defaults write`).
#
# Usage: XCV_E19_VOLUME=/Volumes/<ext> scripts/experiments/e19-split-products.sh
source "$(dirname "$0")/common.sh"

FIXTURE="$XCV_ROOT/fixtures/E2Fixture"
VOL="${XCV_E19_VOLUME:-}"
VOL="${VOL%/}"
INT="${XCV_E19_SCRATCH:-$HOME/.xcodevault-e19-scratch}"
UID_N="$(id -u)"
# Default is the three layouts already measured. SOURCE is opt-in so a later run
# does not repeat them: the package sources live on the external scratch, products
# stay internal. Evidence for a subset uses its own file so it cannot overwrite
# the full-run transcript.
CASES="${XCV_E19_CASES:-CTRL SYM INV}"
want() { [[ " $CASES " == *" $1 "* ]]; }
case "$CASES" in
  "CTRL SYM INV") out="$XCV_EVIDENCE_DIR/e19-split-products-$(xcv_env_slug).txt" ;;
  *) out="$XCV_EVIDENCE_DIR/e19-$(echo "$CASES" | tr ' ' '-')-$(xcv_env_slug).txt" ;;
esac
SUMMARY=()
DEFAULTS_BEFORE=""

refuse() { echo "REFUSING: $*" >&2; exit 2; }

[ -n "$VOL" ] || refuse "set XCV_E19_VOLUME to a mounted external volume"
case "$VOL" in
  /Volumes/*) ;;
  *) refuse "volume must be a /Volumes mount, got $VOL" ;;
esac
[ -d "$VOL" ] || refuse "not a directory: $VOL"
case "$VOL" in
  */.*) refuse "volume path must not contain a dot-component" ;;
esac

loc=$(diskutil info "$VOL" | awk -F: '/^ *Device Location:/{gsub(/^ +| +$/,"",$2); print $2; exit}')
[ "$loc" = "External" ] || refuse "$VOL is Device Location '$loc', not External"

# The per-user temp directory has to already exist. Creating .TemporaryItems at
# the volume root needs privileges this script does not have, and a sibling of
# that directory would be a place a vault folder can live.
# Do not use [ -w ] here: on this volume access(W_OK) is EPERM for the temp
# folder itself (TCC), while creating a child directory succeeds. The probe
# below is the check that matters, and it is confined to the E19 directory.
BASE="$VOL/.TemporaryItems/folders.$UID_N"
[ -d "$BASE" ] || refuse "no per-user temp at $BASE — will not create one, and will not write elsewhere on the volume"
EXT="$BASE/TemporaryItems/XCodeVault-experiments/E19"
mkdir -p "$EXT" || refuse "cannot create $EXT"
echo probe > "$EXT/.write-probe" || refuse "cannot write inside $EXT"
rm -f "$EXT/.write-probe"
EXT_PHYS=$(cd "$EXT" && pwd -P) || refuse "cannot resolve $EXT"
case "$EXT_PHYS" in
  "$VOL/.TemporaryItems/folders.$UID_N/TemporaryItems/XCodeVault-experiments/E19") ;;
  *) refuse "external scratch resolved outside the per-user temp: $EXT_PHYS" ;;
esac
case "$EXT_PHYS" in
  *"/Library/Developer"*|*/Vault|*/Vault/*) refuse "scratch landed on a forbidden path: $EXT_PHYS" ;;
esac

dev_vol=$(df "$VOL" | awk 'NR==2{print $1}')
dev_ext=$(df "$EXT_PHYS" | awk 'NR==2{print $1}')
[ "$dev_vol" = "$dev_ext" ] || refuse "scratch device $dev_ext is not the volume device $dev_vol"

mkdir -p "$INT" || refuse "cannot create internal scratch"
INT_PHYS=$(cd "$INT" && pwd -P) || refuse "cannot resolve internal scratch"
case "$INT_PHYS" in
  "$HOME/.xcodevault-e19-scratch") ;;
  *) refuse "internal scratch resolved unexpectedly: $INT_PHYS" ;;
esac
dev_int=$(df "$INT_PHYS" | awk 'NR==2{print $1}')
[ "$dev_int" != "$dev_ext" ] || refuse "internal scratch is on the external device"

# Read-only snapshot. Compared again at the end; this script never writes these.
snapshot_defaults() {
  defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || echo '<unset>'
  defaults read com.apple.dt.Xcode IDECustomCompilationCacheLocation 2>/dev/null || echo '<unset>'
  defaults read com.apple.dt.Xcode IDECustomBuildProductsPath 2>/dev/null || echo '<unset>'
  defaults read com.apple.dt.Xcode IDECustomBuildIntermediatesPath 2>/dev/null || echo '<unset>'
  defaults read com.apple.dt.Xcode IDEBuildLocationStyle 2>/dev/null || echo '<unset>'
}
DEFAULTS_BEFORE=$(snapshot_defaults)

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  local phys
  if [ -d "$EXT" ]; then
    phys=$(cd "$EXT" && pwd -P) || phys=""
    if [ "$phys" = "$EXT_PHYS" ]; then rm -rf "$phys"; else echo "cleanup: refused to remove $phys" >&2; fi
  fi
  if [ -d "$INT" ]; then
    phys=$(cd "$INT" && pwd -P) || phys=""
    if [ "$phys" = "$INT_PHYS" ]; then rm -rf "$phys"; else echo "cleanup: refused to remove $phys" >&2; fi
  fi
  if [ -f "$out.raw" ]; then
    if xcv_redact < "$out.raw" > "$out"; then
      rm -f "$out.raw"
    else
      mv -f "$out.raw" "${TMPDIR:-/tmp}/$(basename "$out").raw" 2>/dev/null || rm -f "$out.raw"
      echo "REDACTION FAILED: raw transcript moved out of the evidence directory." >&2
    fi
  fi
}

where_dev() {
  # where_dev <path> → INTERNAL / EXTERNAL / OTHER
  local d
  [ -e "$1" ] || { echo MISSING; return; }
  d=$(df "$1" | awk 'NR==2{print $1}')
  if [ "$d" = "$dev_int" ]; then echo INTERNAL
  elif [ "$d" = "$dev_ext" ]; then echo EXTERNAL
  else echo "OTHER:$d"
  fi
}

inventory() {
  local root
  echo "-- layout --"
  for root in "$@"; do
    [ -d "$root" ] || continue
    echo "ROOT $root ($(where_dev "$root"))"
    du -sh "$root"/* 2>/dev/null | sort -h
    find "$root" \( -name '*.xctest' -o -name '*.framework' -o -name '*.dylib' \) -print | while IFS= read -r b; do
      echo "BUNDLE $(where_dev "$b") $b"
    done
  done
}

run_case() {
  # run_case <label> <derivedData>  — remaining args are xcodebuild build settings
  local label="$1" dd="$2"
  shift 2
  local log rc verdict
  echo "== CASE $label" >&2
  echo "==================== CASE $label ===================="
  echo "DerivedData: $dd"
  printf 'setting: %s\n' "$@"
  rm -rf "$dd"
  mkdir -p "$dd"
  log="$INT_PHYS/$label.xcodebuild.log"
  ( cd "$FIXTURE" && xcodebuild test -scheme E2Fixture -destination 'platform=macOS' \
      -derivedDataPath "$dd" "$@" -quiet >"$log" 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'TEST FAILED' "$log"; then verdict="PASS"; else verdict="FAIL"; fi
  echo "xcodebuild exit=$rc verdict=$verdict"
  grep -E 'error:|Failed to|TEST (SUCCEEDED|FAILED)' "$log" | grep -vE 'warning:|DVTProvisioningProfileManager' | sort -u | head -15
  inventory "$dd" "$@"
  # inventory walks directories only; settings that are KEY=PATH are handled below
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ "$k" = "$kv" ] && continue
    [ -d "$v" ] || continue
    echo "OVERRIDE $k $(where_dev "$v") $v"
    du -sh "$v" 2>/dev/null
    find "$v" \( -name '*.xctest' -o -name '*.framework' -o -name '*.dylib' \) -print | while IFS= read -r b; do
      echo "BUNDLE $(where_dev "$b") $b"
    done
  done
  SUMMARY+=("$label | xcodebuild=$verdict (exit $rc)")
  echo
}

e19_main() {
  xcv_header "E19 split DerivedData: products where xctest can load them, bulk on the external volume"
  echo "volume-device: $dev_vol"
  diskutil info "$VOL" | awk '/File System Personality|Protocol|Device Location|Removable Media|Owners|Mount Point/'
  echo "external-scratch: $EXT_PHYS"
  echo "internal-scratch: $INT_PHYS ($(where_dev "$INT_PHYS"))"
  echo "defaults-before:"
  printf '%s\n' "$DEFAULTS_BEFORE"
  echo

  run_case "CTRL-all-external" "$EXT_PHYS/DD-CTRL"

  run_case "SYM-products-internal" "$EXT_PHYS/DD-SYM" \
    "SYMROOT=$INT_PHYS/SYM" \
    "OBJROOT=$EXT_PHYS/DD-SYM/Intermediates" \
    "INDEX_DATA_STORE_DIR=$EXT_PHYS/DD-SYM/Index" \
    "MODULE_CACHE_DIR=$EXT_PHYS/DD-SYM/ModuleCache" \
    "CLANG_MODULE_CACHE_PATH=$EXT_PHYS/DD-SYM/ModuleCache"

  run_case "INV-bulk-external" "$INT_PHYS/DD-INV" \
    "OBJROOT=$EXT_PHYS/INV-Intermediates" \
    "INDEX_DATA_STORE_DIR=$EXT_PHYS/INV-Index" \
    "MODULE_CACHE_DIR=$EXT_PHYS/INV-ModuleCache" \
    "CLANG_MODULE_CACHE_PATH=$EXT_PHYS/INV-ModuleCache"

  echo "defaults-after:"
  snapshot_defaults
  echo
  echo "==================== SUMMARY ===================="
  printf '%s\n' "${SUMMARY[@]}"
}

exec 3>&2
trap 'cleanup' EXIT INT TERM HUP
e19_main > "$out.raw" 2>&1
E19_RC=$?
cleanup
if [ -f "$out" ]; then
  grep -E '^(====|xcodebuild exit|BUNDLE |OVERRIDE |SUMMARY|CTRL|SYM|INV|REFUSING|defaults-)' "$out" | head -80
fi
echo "wrote $out"
exit "$E19_RC"

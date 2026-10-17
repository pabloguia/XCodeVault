#!/bin/bash
# E19 locations-keys — do the keys DerivedDataSplit writes make `xcodebuild test`
# pass when the bulk is on a physical external volume and the products stay internal?
#
# Scratch only. Does not `defaults write` except to put a key back if a probe
# changed it. Does not touch CoreSimulator, /System, or a vault folder.
# External writes stay under the pre-existing per-user TemporaryItems path E2 uses.
# Internal writes stay under ~/.xcodevault-e19-keys-scratch.
#
# The split (XcodeLocations.DerivedDataSplit) writes five keys and no separate
# index or module-cache key; those two follow IDECustomDerivedDataLocation.
# This probe passes the five as one-shot -IDE… arguments (NSArgumentDomain),
# which is the non-persistent form in LOCATIONS-KEYS-2026-09-06.md.
#
#   CTRL  entire DerivedData on the external scratch (-derivedDataPath). E2/E19
#         already failed this. If it passes, the machine changed and KEYS is
#         not interpretable.
#   KEYS  the five Locations keys. Products on the internal scratch. DerivedData
#         and Intermediates on the external scratch. No -derivedDataPath: that
#         flag is IDEDerivedDataPathOverride, a different mechanism.
#
# Usage: XCV_E19_VOLUME=/Volumes/<ext> scripts/experiments/e19-locations-keys.sh
source "$(dirname "$0")/common.sh"

FIXTURE="$XCV_ROOT/fixtures/E2Fixture"
VOL="${XCV_E19_VOLUME:-}"
VOL="${VOL%/}"
INT="${XCV_E19_KEYS_SCRATCH:-$HOME/.xcodevault-e19-keys-scratch}"
UID_N="$(id -u)"
out="$XCV_EVIDENCE_DIR/e19-locations-keys-$(xcv_env_slug).txt"
SUMMARY=()
DEFAULTS_BEFORE=""
KEYS=(
  IDECustomDerivedDataLocation
  IDEBuildLocationStyle
  IDECustomBuildLocationType
  IDECustomBuildProductsPath
  IDECustomBuildIntermediatesPath
  IDECustomCompilationCacheLocation
  IDECustomDistributionArchivesLocation
  IDEDerivedDataPathOverride
)

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
# The sibling vault volume is not a scratch target, even though it is external.
case "$VOL" in
  /Volumes/XCodeVault) refuse "refusing the vault volume itself" ;;
esac

loc=$(diskutil info "$VOL" | awk -F: '/^ *Device Location:/{gsub(/^ +| +$/,"",$2); print $2; exit}')
[ "$loc" = "External" ] || refuse "$VOL is Device Location '$loc', not External"
protocol=$(diskutil info "$VOL" | awk -F: '/^ *Protocol:/{gsub(/^ +| +$/,"",$2); print $2; exit}')
case "$protocol" in
  Disk\ Image|Disk\ Image*) refuse "$VOL is a disk image ($protocol); this probe needs a physical volume" ;;
esac

# The per-user temp directory has to already exist. Creating .TemporaryItems at
# the volume root needs privileges this script does not have.
BASE="$VOL/.TemporaryItems/folders.$UID_N"
[ -d "$BASE" ] || refuse "no per-user temp at $BASE — will not create one, and will not write elsewhere on the volume"
EXT="$BASE/TemporaryItems/XCodeVault-experiments/E19-keys"
mkdir -p "$EXT" || refuse "cannot create $EXT"
echo probe > "$EXT/.write-probe" || refuse "cannot write inside $EXT"
rm -f "$EXT/.write-probe"
EXT_PHYS=$(cd "$EXT" && pwd -P) || refuse "cannot resolve $EXT"
case "$EXT_PHYS" in
  "$VOL/.TemporaryItems/folders.$UID_N/TemporaryItems/XCodeVault-experiments/E19-keys") ;;
  *) refuse "external scratch resolved outside the per-user temp: $EXT_PHYS" ;;
esac
case "$EXT_PHYS" in
  *"/Library/Developer"*|*/Archives|*/Archives/*|*/Runtimes|*/Runtimes/*|*/backup-ios|*/backup-ios/*|*/parallels|*/parallels/*)
    refuse "scratch landed on a forbidden path: $EXT_PHYS" ;;
esac

dev_vol=$(df "$VOL" | awk 'NR==2{print $1}')
dev_ext=$(df "$EXT_PHYS" | awk 'NR==2{print $1}')
[ "$dev_vol" = "$dev_ext" ] || refuse "scratch device $dev_ext is not the volume device $dev_vol"

mkdir -p "$INT" || refuse "cannot create internal scratch"
INT_PHYS=$(cd "$INT" && pwd -P) || refuse "cannot resolve internal scratch"
case "$INT_PHYS" in
  "$HOME/.xcodevault-e19-keys-scratch") ;;
  *) refuse "internal scratch resolved unexpectedly: $INT_PHYS" ;;
esac
case "$INT_PHYS" in
  /Volumes/*) refuse "internal scratch is under /Volumes: $INT_PHYS" ;;
esac
dev_int=$(df "$INT_PHYS" | awk 'NR==2{print $1}')
[ "$dev_int" != "$dev_ext" ] || refuse "internal scratch is on the external device"

read_key() {
  defaults read com.apple.dt.Xcode "$1" 2>/dev/null || echo '<unset>'
}

snapshot_defaults() {
  local k
  for k in "${KEYS[@]}"; do
    printf '%s=%s\n' "$k" "$(read_key "$k")"
  done
}

# Only runs when a probe changed a key. Puts the before-value back.
restore_defaults() {
  local line key before now
  [ -n "$DEFAULTS_BEFORE" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    before=${line#*=}
    now=$(read_key "$key")
    [ "$now" = "$before" ] && continue
    echo "RESTORING $key (was '$before', now '$now')" >&2
    if [ "$before" = "<unset>" ]; then
      defaults delete com.apple.dt.Xcode "$key" >/dev/null 2>&1 || true
    else
      defaults write com.apple.dt.Xcode "$key" -string "$before"
    fi
  done <<< "$DEFAULTS_BEFORE"
}

DEFAULTS_BEFORE=$(snapshot_defaults)
DD_DEFAULT="$HOME/Library/Developer/Xcode/DerivedData"
DD_BEFORE=$(ls -1d "$DD_DEFAULT"/E2Fixture-* 2>/dev/null | sort || true)

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  restore_defaults
  local phys now gone
  if [ -d "$EXT" ]; then
    phys=$(cd "$EXT" && pwd -P) || phys=""
    if [ "$phys" = "$EXT_PHYS" ]; then rm -rf "$phys"; else echo "cleanup: refused to remove $phys" >&2; fi
  fi
  if [ -d "$INT" ]; then
    phys=$(cd "$INT" && pwd -P) || phys=""
    if [ "$phys" = "$INT_PHYS" ]; then rm -rf "$phys"; else echo "cleanup: refused to remove $phys" >&2; fi
  fi
  # Drop only fixture DerivedData folders this run created in the default location.
  if [ -d "$DD_DEFAULT" ]; then
    now=$(ls -1d "$DD_DEFAULT"/E2Fixture-* 2>/dev/null | sort || true)
    gone=$(comm -13 <(printf '%s\n' "$DD_BEFORE") <(printf '%s\n' "$now") || true)
    local d
    for d in $gone; do
      case "$d" in
        "$DD_DEFAULT"/E2Fixture-*) rm -rf "$d" ;;
      esac
    done
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
  local d
  [ -e "$1" ] || { echo MISSING; return; }
  d=$(df "$1" | awk 'NR==2{print $1}')
  if [ "$d" = "$dev_int" ]; then echo INTERNAL
  elif [ "$d" = "$dev_ext" ]; then echo EXTERNAL
  else echo "OTHER:$d"
  fi
}

inventory_tree() {
  local root label
  root="$1"
  label="$2"
  [ -d "$root" ] || { echo "ROOT-MISSING $label $root"; return; }
  echo "ROOT $label $(where_dev "$root") $root"
  du -sh "$root" 2>/dev/null
  du -sh "$root"/* 2>/dev/null | sort -h
  find "$root" \( -name '*.xctest' -o -name '*.framework' -o -name '*.dylib' -o -name 'Index.noindex' -o -name 'ModuleCache.noindex' -o -name 'CompilationCache.noindex' -o -name 'Intermediates' \) -print | while IFS= read -r b; do
    echo "ITEM $(where_dev "$b") $b"
  done
}

run_ctrl() {
  local dd log rc verdict
  dd="$EXT_PHYS/DD-CTRL"
  echo "== CASE CTRL-all-external" >&3
  echo "==================== CASE CTRL-all-external ===================="
  echo "DerivedData: $dd"
  echo "invocation: xcodebuild test -scheme E2Fixture -destination platform=macOS -derivedDataPath <external> -quiet"
  rm -rf "$dd"
  mkdir -p "$dd"
  log="$INT_PHYS/CTRL.xcodebuild.log"
  ( cd "$FIXTURE" && xcodebuild test -scheme E2Fixture -destination 'platform=macOS' \
      -derivedDataPath "$dd" -quiet >"$log" 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'TEST FAILED' "$log"; then verdict="PASS"; else verdict="FAIL"; fi
  echo "xcodebuild exit=$rc verdict=$verdict"
  grep -E 'error:|Failed to|TEST (SUCCEEDED|FAILED)|Unknown' "$log" | grep -vE 'warning:|DVTProvisioningProfileManager' | sort -u | head -20
  inventory_tree "$dd" "CTRL-derived"
  SUMMARY+=("CTRL | xcodebuild=$verdict (exit $rc)")
  echo
  CTRL_VERDICT=$verdict
}

run_keys() {
  local bulk products intermediates log rc verdict
  bulk="$EXT_PHYS/DD-KEYS"
  products="$INT_PHYS/Products"
  intermediates="$bulk/Intermediates"
  echo "== CASE KEYS-locations-split" >&3
  echo "==================== CASE KEYS-locations-split ===================="
  echo "IDECustomDerivedDataLocation: $bulk"
  echo "IDEBuildLocationStyle: Custom"
  echo "IDECustomBuildLocationType: Absolute"
  echo "IDECustomBuildProductsPath: $products"
  echo "IDECustomBuildIntermediatesPath: $intermediates"
  echo "index/module-cache keys: none (they follow IDECustomDerivedDataLocation)"
  echo "invocation: xcodebuild test -scheme E2Fixture -destination platform=macOS -IDECustomDerivedDataLocation=<external> -IDEBuildLocationStyle=Custom -IDECustomBuildLocationType=Absolute -IDECustomBuildProductsPath=<internal> -IDECustomBuildIntermediatesPath=<external>/Intermediates -quiet"
  rm -rf "$bulk" "$products"
  mkdir -p "$bulk" "$products" "$intermediates"
  log="$INT_PHYS/KEYS.xcodebuild.log"
  ( cd "$FIXTURE" && xcodebuild test -scheme E2Fixture -destination 'platform=macOS' \
      -IDECustomDerivedDataLocation="$bulk" \
      -IDEBuildLocationStyle=Custom \
      -IDECustomBuildLocationType=Absolute \
      -IDECustomBuildProductsPath="$products" \
      -IDECustomBuildIntermediatesPath="$intermediates" \
      -quiet >"$log" 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'TEST FAILED' "$log"; then verdict="PASS"; else verdict="FAIL"; fi
  echo "xcodebuild exit=$rc verdict=$verdict"
  grep -E 'error:|Failed to|TEST (SUCCEEDED|FAILED)|Unknown' "$log" | grep -vE 'warning:|DVTProvisioningProfileManager' | sort -u | head -20
  inventory_tree "$bulk" "KEYS-bulk"
  inventory_tree "$products" "KEYS-products"
  SUMMARY+=("KEYS | xcodebuild=$verdict (exit $rc)")
  echo
  KEYS_VERDICT=$verdict
}

keys_main() {
  xcv_header "E19 locations keys: one-shot split keys, products internal, bulk on the external volume"
  echo "volume-device: $dev_vol"
  diskutil info "$VOL" | awk '/File System Personality|Protocol|Device Location|Removable Media|Owners|Mount Point/'
  echo "external-scratch: $EXT_PHYS"
  echo "internal-scratch: $INT_PHYS ($(where_dev "$INT_PHYS"))"
  echo "disk-images-before:"
  hdiutil info 2>/dev/null | awk '/^image-path/' || true
  echo "defaults-before:"
  printf '%s\n' "$DEFAULTS_BEFORE"
  echo
  echo "note: no defaults write. Five -IDE arguments match DerivedDataSplit.changes. No index or module-cache defaults key exists on that split."
  echo

  CTRL_VERDICT=""
  KEYS_VERDICT=""
  run_ctrl
  run_keys

  echo "defaults-after:"
  snapshot_defaults
  echo
  if [ "$(snapshot_defaults)" = "$DEFAULTS_BEFORE" ]; then
    echo "defaults-unchanged: yes"
  else
    echo "defaults-unchanged: no"
    echo "defaults differ; restoring"
    restore_defaults
    echo "defaults-restored:"
    snapshot_defaults
  fi
  echo
  if [ "$CTRL_VERDICT" = "PASS" ]; then
    echo "CONTROL-INTERPRETATION: CTRL passed. E2/E19 failed this layout. The machine state changed; KEYS is not interpretable."
  else
    echo "CONTROL-INTERPRETATION: CTRL failed, consistent with E2/E19. KEYS can be read against that baseline."
  fi
  echo "==================== SUMMARY ===================="
  printf '%s\n' "${SUMMARY[@]}"
}

exec 3>&2
trap 'cleanup' EXIT INT TERM HUP
xcv_rotate_out "$out" || exit 2
keys_main > "$out.raw" 2>&1
KEYS_RC=$?
cleanup
if [ -f "$out" ]; then
  grep -E '^(====|xcodebuild exit|ITEM |ROOT |SUMMARY|CTRL|KEYS|defaults-|CONTROL-|note:|invocation:)' "$out" | head -120
fi
echo "wrote $out"
exit "$KEYS_RC"

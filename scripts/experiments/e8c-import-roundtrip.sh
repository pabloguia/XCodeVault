#!/bin/bash
# E8 (import half) + functional probe — install a runtime from an exported installer, prove the
# runtime works (create + boot + shutdown + delete a device), then remove the runtime again so the
# machine ends in its prior state. Staging is measured by e11-staging-monitor.sh in import mode.
# Usage: scripts/experiments/e8c-import-roundtrip.sh <path-to-Restore/*_Cryptex.dmg or .exportedBundle> --i-understand
#
# The functional probe creates and BOOTS a device in the DEFAULT device set — the one the user runs
# real test suites against. The gate was missing until 2026-09-15, when a lint added for a different
# hazard found this one; nothing else about the script changed, so its recorded evidence still
# stands.
source "$(dirname "$0")/common.sh"
CTL="$XCV_ROOT/.build/debug/xcodevaultctl"
IN="${1:-}"
if [ -z "$IN" ] || [ "${2:-}" != "--i-understand" ]; then
  echo "usage: $0 <installer path> --i-understand" >&2
  echo "  This boots a device in your DEFAULT device set. Check nothing is running against it first:" >&2
  echo "    pgrep -fl xcodebuild; xcrun simctl list devices" >&2
  exit 2
fi
case "$IN" in *.exportedBundle) DMG=$(ls "$IN"/Restore/*_Cryptex.dmg | head -1);; *) DMG="$IN";; esac
out="$XCV_EVIDENCE_DIR/e8c-import-$(xcv_env_slug).txt"
{
  xcv_header "E8c: -importPlatform from an exported installer + functional probe + delete"
  echo "installer: $DMG ($(du -sk "$DMG" | cut -f1) KB)"
  xcv_run "registry before" xcrun simctl runtime list
  echo "== import (monitored) =="
  "$XCV_ROOT/scripts/experiments/e11-staging-monitor.sh" import "$DMG" 1.5
  xcv_run "registry after import" xcrun simctl runtime list -j
  rid=$(xcrun simctl runtime list -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((k for k,v in d.items() if "tvOS" in (v.get("runtimeIdentifier") or "") or "appletv" in (v.get("platformIdentifier") or "")), ""))')
  echo "tvOS runtime id: $rid"
  if [ -n "$rid" ]; then
    xcv_run "verify" xcrun simctl runtime verify "$rid"
    rt=$(xcrun simctl runtime list -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["'"$rid"'"]["runtimeIdentifier"])')
    xcv_run "create device" xcrun simctl create xcv-probe-tv "Apple TV" "$rt"
    udid=$(xcrun simctl list devices -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for v in d.values() for x in v if x["name"]=="xcv-probe-tv"))')
    xcv_run "boot device" xcrun simctl boot "$udid"
    xcv_run "wait for boot" xcrun simctl bootstatus "$udid" -b
    xcv_run "device state" sh -c "xcrun simctl list devices | grep xcv-probe-tv"
    xcv_run "shutdown" xcrun simctl shutdown "$udid"
    xcv_run "delete device" xcrun simctl delete "$udid"
    xcv_run "runtime delete (restore prior state)" "$CTL" runtime delete "$rid" --yes
    xcv_run "delete unavailable devices created for the runtime" xcrun simctl delete unavailable
  fi
  xcv_run "registry after" xcrun simctl runtime list
  xcv_run "asset stores" du -sk /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime
  xcv_run "internal free" df -h /System/Volumes/Data
} 2>&1 | xcv_redact | tee "$out.tmp" | grep -E '^(## |installer|tvOS runtime|\[exit|t=|peak|import exit|Booted|Shutdown|Error|!!|== )' | awk '!/^t=/ || NR%6==0'
mv "$out.tmp" "$out"; echo "wrote $out"

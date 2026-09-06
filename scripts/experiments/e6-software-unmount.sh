#!/bin/bash
# E6 (software variant) — the vault volume disappears in the middle of a migration.
# Physical yank is still "pending — manual"; this drives the closest software equivalents:
#   phase 1: `diskutil unmount force` while `externalize --apply` is copying   (surprise removal)
#   phase 2: clean `diskutil unmount` between operations                        (clean eject)
# and records: command outcome, journal state, vault state, doctor findings, whether a plain
# /Volumes/<name> directory appeared (shadow data), remount behaviour, abort, and a full
# externalize → remove-source → restore round trip afterwards.
#
# Needs: a registered vault volume (`xcodevaultctl vault init <mount>`), no Xcode running.
# Creates a throwaway Archives fixture under ~/Library/Developer/Xcode/Archives ONLY if that
# directory does not exist yet, and removes it at the end.
# Usage: scripts/experiments/e6-software-unmount.sh <vault-mount-point> [fixture-MB=600]
source "$(dirname "$0")/common.sh"
MP="$1"; MB="${2:-600}"
CTL="$XCV_ROOT/.build/debug/xcodevaultctl"
ARCH="$HOME/Library/Developer/Xcode/Archives"
out="$XCV_EVIDENCE_DIR/e6-software-$(xcv_env_slug).txt"
dev=$(df "$MP" | awk 'NR==2{print $1}')
uuid=$(diskutil info "$dev" | awk -F': *' '/Volume UUID/{print $2}')
VDIR=$("$CTL" vault status --json | python3 -c 'import json,sys; print(next(c["volume"]["lastMountPoint"]+"/"+c["volume"]["relativeDirectory"] for c in json.load(sys.stdin) if c["volume"]["volumeUUID"]=="'"$uuid"'"))')
[ -n "$VDIR" ] || { echo "vault for $uuid not registered"; exit 1; }
[ -e "$ARCH" ] && { echo "!! $ARCH exists — refusing to use the user's real Archives as a fixture"; exit 1; }
cleanup() {
  rm -rf "$ARCH" "$ARCH".xcodevault-removing-* 2>/dev/null
  rm -rf "$VDIR/archives" 2>/dev/null
}
trap cleanup EXIT
{
  xcv_header "E6 software variant: vault volume unmounted during/between migrations ($MP, $dev, $uuid)"
  echo "vault directory: $VDIR"
  mkdir -p "$ARCH/2026-09-06/XCVProbe.xcarchive/dSYMs/XCVProbe.app.dSYM/Contents/Resources/DWARF" "$ARCH/2026-09-06/XCVProbe.xcarchive/Products/Applications"
  head -c "$((MB*1024*1024))" /dev/urandom > "$ARCH/2026-09-06/XCVProbe.xcarchive/dSYMs/XCVProbe.app.dSYM/Contents/Resources/DWARF/XCVProbe"
  head -c 4096 /dev/urandom > "$ARCH/2026-09-06/XCVProbe.xcarchive/Info.plist"
  xattr -w com.apple.quarantine "0083;68bd0000;Safari;XCV" "$ARCH/2026-09-06/XCVProbe.xcarchive/Info.plist"
  ln -s ../Info.plist "$ARCH/2026-09-06/XCVProbe.xcarchive/Products/link"
  xcv_run "fixture" du -sk "$ARCH"
  xcv_run "vault status before" "$CTL" vault status

  echo "==================== PHASE 1: force-unmount during COPY ===================="
  ( "$CTL" externalize --category archives --vault "$uuid" --apply > /tmp/xcv-e6-ext.log 2>&1; echo "externalize exit=$?" >> /tmp/xcv-e6-ext.log ) &
  bg=$!
  # wait until the copy has written a good chunk (≥ 25 % of the fixture), then pull the volume out from under it
  target_kb=$((MB*1024/4))
  for i in $(seq 1 600); do
    cur=$(du -sk "$VDIR/archives/Archives" 2>/dev/null | cut -f1); [ "${cur:-0}" -ge "$target_kb" ] && break; sleep 0.2
  done
  echo "destination had ${cur:-0} KB when the volume was force-unmounted"
  echo "\$ diskutil unmount force $MP   (at $(date +%T))"; diskutil unmount force "$MP"; echo "[exit=$?]"
  wait $bg
  echo "--- externalize output ---"; cat /tmp/xcv-e6-ext.log
  xcv_run "is $MP a mount point now?" sh -c "mount | grep -c '$MP' || true"
  xcv_run "does a plain directory remain at $MP (shadow-data trap)?" sh -c "ls -la '$MP' 2>&1 | head -5"
  xcv_run "source intact?" du -sk "$ARCH"
  xcv_run "journal tail" sh -c "'$CTL' journal --last 8"
  xcv_run "migration status" "$CTL" migration status
  xcv_run "vault status (expect ABSENT or AMBIGUOUS)" "$CTL" vault status
  xcv_run "doctor" sh -c "'$CTL' doctor 2>&1 | grep -E '^\\[|doctor:'"
  echo "\$ diskutil mount $dev"; diskutil mount "$dev"; echo "[exit=$?]"; sleep 2
  xcv_run "mount point after remount (same name or 'Name 1'?)" sh -c "mount | grep '$dev'"
  xcv_run "vault status after remount" "$CTL" vault status
  xcv_run "migration status after remount (expect LEFTOVER PARTIAL COPY)" "$CTL" migration status
  xcv_run "externalize retry must point at abort" "$CTL" externalize --category archives --vault "$uuid"
  op=$("$CTL" migration status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); l=d.get("interrupted",[])+d.get("leftoverPartialCopies",[]); print(l[0]["id"] if l else "")')
  if [ -n "$op" ]; then xcv_run "abort failed/interrupted migration $op (removes only the partial copy)" "$CTL" migration abort "$op"; fi
  xcv_run "partial copy gone?" sh -c "ls -la '$VDIR/archives' 2>&1"

  echo "==================== PHASE 2: full round trip, then clean unmount between operations ===================="
  xcv_run "externalize (plan)" "$CTL" externalize --category archives --vault "$uuid"
  xcv_run "externalize --apply --remove-source-after-verify" "$CTL" externalize --category archives --vault "$uuid" --apply --remove-source-after-verify --i-confirm-deleting-non-regenerable-data
  xcv_run "source removed?" sh -c "ls -la '$ARCH' 2>&1 | head -2"
  xcv_run "vault copy" sh -c "find '$VDIR/archives' -maxdepth 4 | head; du -sk '$VDIR/archives'"
  echo "\$ diskutil unmount $MP (clean eject)"; diskutil unmount "$MP"; echo "[exit=$?]"
  xcv_run "restore while the vault is absent (must refuse)" "$CTL" restore --category archives --vault "$uuid" --name Archives --apply
  xcv_run "vault status (absent)" "$CTL" vault status
  echo "\$ diskutil mount $dev"; diskutil mount "$dev"; echo "[exit=$?]"; sleep 2
  xcv_run "restore --apply" "$CTL" restore --category archives --vault "$uuid" --name Archives --apply
  xcv_run "restored fixture (quarantine xattr + symlink preserved?)" sh -c "xattr -l '$ARCH/2026-09-06/XCVProbe.xcarchive/Info.plist'; ls -l '$ARCH/2026-09-06/XCVProbe.xcarchive/Products/'; du -sk '$ARCH'"
  xcv_run "journal tail" sh -c "'$CTL' journal --last 12"
  xcv_run "doctor after" sh -c "'$CTL' doctor 2>&1 | grep -E '^\\[|doctor:'"
} 2>&1 | xcv_redact | tee "$out.tmp" | grep -E '^(====|\$ |\[exit|externalize exit|!!|Error|Copying|Verified|Source removed|Restored|INTERRUPTED|No interrupted|[A-Z]+  )' 
mv "$out.tmp" "$out"; echo "wrote $out"

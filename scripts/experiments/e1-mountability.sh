#!/bin/bash
# E1 — Is /Library/Developer/CoreSimulator even mountable? (gates H1, H8). Read-only.
# Usage: scripts/experiments/e1-mountability.sh   → docs/research/evidence/e1-<env>.txt
source "$(dirname "$0")/common.sh"
out="$XCV_EVIDENCE_DIR/e1-$(xcv_env_slug).txt"
{
  xcv_header "E1 mountability / SIP status of CoreSimulator paths (read-only)"
  xcv_run "flags and xattrs on target paths" ls -ldO@ /Library/Developer /Library/Developer/CoreSimulator /Library/Developer/CoreSimulator/*
  xcv_run "xattr -l CoreSimulator" xattr -l /Library/Developer/CoreSimulator
  xcv_run "xattr -l /Library/Developer" xattr -l /Library/Developer
  xcv_run "rootless.conf entries mentioning developer" grep -i developer /System/Library/Sandbox/rootless.conf
  xcv_run "mounts under /Library/Developer" sh -c "mount | grep -i developer"
  xcv_run "nested mount points" ls -la /Library/Developer/CoreSimulator/Volumes
  xcv_run "Cryptex layout" find /Library/Developer/CoreSimulator/Cryptex /Library/Developer/CoreSimulator/Images -maxdepth 3 -exec ls -ldO {} \;
  xcv_run "on-disk bytes under CoreSimulator (du -x, not crossing mounts)" du -xsk /Library/Developer/CoreSimulator /Library/Developer/CoreSimulator/*
  xcv_run "runtime registry" xcrun simctl runtime list -j
  xcv_run "MobileAsset runtime store" sh -c "ls -la /System/Library/AssetsV2/ | grep -i SimulatorRuntime; du -sk /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime"
  xcv_run "disk image attachments (runtime images)" sh -c "hdiutil info | grep -E 'image-path|^/dev/disk'"
  xcv_run "df of /System/Library/AssetsV2 (which volume backs it)" df -h /System/Library/AssetsV2
} 2>&1 | xcv_redact > "$out"
echo "wrote $out"

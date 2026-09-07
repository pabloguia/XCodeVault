#!/bin/bash
# E1 (mount half) — run AS ROOT (sudo). Self-contained: creates a 2 GB sparse APFS image in /tmp,
# attaches it -nomount, mounts it over a throwaway directory under /Library/Developer, proves
# read/write, unmounts, and removes everything it created. Never touches the real CoreSimulator path.
# Usage: sudo scripts/experiments/e1b-mount-probe.sh [evidence-file]
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$ROOT/docs/research/evidence/e1b-mount-$(sw_vers -productVersion)-$(sw_vers -buildVersion)-$(uname -m).txt}"
probe=/Library/Developer/xcv-probe
img=/tmp/xcv-e1b-probe.sparseimage
cleanup() {
  diskutil unmount "$probe" >/dev/null 2>&1
  [ -n "${dev:-}" ] && hdiutil detach "$dev" >/dev/null 2>&1
  [ -d "$probe" ] && { rm -f "$probe/hello"; rmdir "$probe" 2>/dev/null; }
  rm -f "$img"
}
trap cleanup EXIT
{
  echo "# Experiment: E1 mount half (as root)"; echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(uname -m) · $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "\$ hdiutil create -size 2g -fs APFS -type SPARSE $img"; hdiutil create -quiet -size 2g -fs APFS -type SPARSE -volname XCVPROBE "$img" -ov; echo "[exit=$?]"
  dev=$(hdiutil attach -nomount -plist "$img" | plutil -extract system-entities json -o - - 2>/dev/null | python3 -c 'import json,sys; print([e["dev-entry"] for e in json.load(sys.stdin) if e.get("content")=="41504653-0000-11AA-AA11-00306543ECAC"][0])' 2>/dev/null)
  [ -n "$dev" ] || dev=$(diskutil list | awk '/APFS Volume XCVPROBE/{print "/dev/"$NF}' | head -1)
  echo "scratch APFS volume device: ${dev:-NOT FOUND}"; [ -n "$dev" ] || { echo "!! could not attach the scratch image; aborting before touching /Library/Developer"; exit 1; }
  if [ -d "$probe" ]; then echo "(removing leftover probe dir from an earlier run)"; rm -f "$probe/hello"; rmdir "$probe"; fi
  echo "\$ mkdir $probe"; mkdir "$probe"; echo "[exit=$?]"
  echo "\$ diskutil mount -mountPoint $probe $dev"; diskutil mount -mountPoint "$probe" "$dev"; rc=$?; echo "[exit=$rc]"
  if [ $rc -eq 0 ]; then
    echo "\$ mount | grep xcv-probe"; mount | grep xcv-probe
    echo "\$ touch $probe/hello && ls -l $probe"; touch "$probe/hello" && ls -l "$probe"; echo "[exit=$?]"
    echo "\$ diskutil unmount $probe"; diskutil unmount "$probe"; echo "[exit=$?]"
    echo "\$ ls -la $probe (empty local dir again?)"; ls -la "$probe"
  else
    echo "!! mount over $probe refused — record this: it would falsify H8"
  fi
  echo "\$ rmdir $probe"; rmdir "$probe"; echo "[exit=$?]"
} 2>&1 | tee -a "$out"
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$out" 2>/dev/null
echo "wrote $out"

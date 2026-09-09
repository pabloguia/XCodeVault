#!/bin/bash
# E4b — will CoreSimulator use a simulator runtime whose bytes stay on an external volume?
#
# E4a settled the seal half without privilege. What it could NOT show is CoreSimulator *using* an
# externally-hosted image: `simctl runtime add` stages into the internal secure storage area, and no
# simctl verb accepts an external path. This tests the remaining half.
#
# WHAT E4a ACTUALLY COVERS, precisely — an earlier draft of this header overstated it. The sha256
# byte-identity in E4a is for the **iOS** image. For watchOS — the runtime this script relocates —
# E4a only observed that the inner image attaches `sealed`; it was never hashed. So this script
# hashes it in preflight and refuses on mismatch, because otherwise a negative result cannot be
# attributed to the path rather than to the bytes.
#
# PROTOCOL DEVIATION, deliberate, and amended in EXPERIMENTS.md before running. E4 says "make it
# visible at the canonical location by mount (not symlink)". Mounting over
# /Library/Developer/CoreSimulator/Volumes/<name> fights simdiskimaged for the same mount point, and
# `Signature State` is served from images.plist rather than from whatever is mounted. This repoints
# images.plist instead — the database CoreSimulator actually consults.
#
# THE FAILURE MODE THIS SCRIPT IS BUILT AROUND. Both runtime volumes are already attached at the
# kernel level; killing simdiskimaged does not detach them. So a naive version of this experiment
# reports "Ready / Verified" while the daemon never opens the external file at all — reading back a
# cached signatureState the script itself wrote, over a stale mount. That false positive would argue
# for reopening ADR-0004, which is the worst outcome available here. Hence: the runtime is unmounted
# first, the mount point is asserted clear, and `hdiutil info` records the backing file before and
# after. `hdiutil info` is the only line that can prove the external .dmg is being read.
#
# REVERSIBILITY. images.plist is backed up outside the daemon's own directory and restored through an
# atomic rename on every catchable exit. The 5.2 GB internal image is never touched, so a restore is
# a pointer swap, not a re-download. A truncated plist is the one state re-import would not fix, and
# the atomic write is what makes it unreachable.
#
# Needs root ONLY to write images.plist. Every simctl call is dropped back to the invoking user.
#     sudo ./scripts/experiments/e4b-runtime-from-external-volume.sh [--dry-run]
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
source "$HERE/common.sh" 2>/dev/null || true   # for xcv_redact; the script works without it

PLIST=/Library/Developer/CoreSimulator/Images/images.plist
TARGET_RID="com.apple.CoreSimulator.SimRuntime.watchOS-26-5"
EXTERNAL_IMAGE="/Volumes/<vault>/XCodeVault/RuntimeLibrary/watchsimulator_26.5_23T570.exportedBundle/Restore/WatchOSSimulatorRuntime_Cryptex.dmg"
STAMP=$(date +%Y%m%dT%H%M%S)
OUT=${XCV_E4B_OUT:-$REPO/docs/research/evidence/e4b-runtime-from-external-$STAMP.txt}
BACKUP=/var/root/images.plist.xcv-e4b-$STAMP     # outside Images/, which simdiskimaged stages into
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

redact () { if command -v xcv_redact >/dev/null 2>&1; then xcv_redact; else cat; fi; }
fail () { echo "REFUSING: $*" | tee -a "$OUT" >&2; exit 1; }
# simctl must run as the invoking user: under sudo it targets root's own device set, so a
# booted-device check would read an empty set and always pass — and it would create a root-owned
# CoreSimulator tree, which is shadow data made by the tool that forbids it.
# Anything that reads the INVOKING USER's state must run as them. Under sudo, both simctl and
# xcodevaultctl otherwise read root's world: simctl targets /var/root's device set, and the vault
# registry lives in ~/Library/Application Support/XCodeVault, so root sees no registered vault at
# all. One helper rather than remembering it per call site — the previous version had it on simctl
# and not on xcodevaultctl, so the rootless --dry-run passed and the sudo run refused with "no
# VERIFIED vault volume". A dry run in a different privilege context is not a rehearsal.
as_user () {
    # -H is not optional: `sudo -u` switches the uid but leaves HOME pointing at the caller's home
    # on macOS, so the command would run as the user while still reading /var/root. Both consumers
    # here resolve their state through HOME (the vault registry and simctl's device set), which is
    # the whole reason this helper exists.
    if [ "$(id -u)" -eq 0 ]; then sudo -u "$REAL_USER" -H "$@"; else "$@"; fi
}
sim () { as_user xcrun simctl "$@"; }

mkdir -p "$(dirname "$OUT")" && : > "$OUT" || { echo "cannot write $OUT"; exit 1; }

# ---- preflight: every branch is a refusal ----------------------------------
# --dry-run writes nothing, so it must not demand root: the whole point is to validate the
# preflight, the byte-identity and the exact rewrite BEFORE spending a privileged run.
if [ "$DRY" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || fail "needs root only to write $PLIST — re-run with sudo, or pass --dry-run"
    REAL_USER=${SUDO_USER:-}
    [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] || fail "run through sudo from a normal account; SUDO_USER is '$REAL_USER'"
else
    REAL_USER=${SUDO_USER:-$(id -un)}
fi
[ -f "$PLIST" ] || fail "$PLIST not found"
[ -f "$EXTERNAL_IMAGE" ] || fail "external image not found — is the vault mounted?"
# Volume identity through the repo's own mechanism (UUID + sentinel), not a name under /Volumes.
as_user "$REPO/.build/debug/xcodevaultctl" vault status 2>/dev/null | grep -q "^VERIFIED" \
  || fail "no VERIFIED vault volume — a path under /Volumes is not proof a volume is mounted (rule 6)"
booted=$(sim list devices booted 2>/dev/null | grep -c "Booted")
[ "$booted" -eq 0 ] || fail "$booted simulator device(s) booted — shut them down first"
pgrep -q "^Xcode$" && fail "Xcode is running — quit it first"
sim runtime list 2>/dev/null | grep -q "watchOS 26.5" || fail "the watchOS 26.5 runtime is not installed; nothing to relocate"

# Free space. Not because the experiment needs room — the edit is 1.6 KB — but because the most
# plausible way this goes wrong is simdiskimaged deciding to STAGE the external image into the
# secure storage area, which is exactly what `simctl runtime add` does. That is 5.2 GB written to
# the internal disk, and it is shadow data at a canonical path (the E9 pattern). Floor = image size
# + 3 GB of headroom, so a stage that starts cannot fill the disk before the watcher below aborts.
IMG_GB=$(( $(stat -f '%z' "$EXTERNAL_IMAGE") / 1000000000 ))
FREE_GB=$(df -k / | tail -1 | awk '{print int($4/1024/1024)}')
FLOOR=$(( IMG_GB + 3 ))
[ "$FREE_GB" -ge "$FLOOR" ] || fail "only ${FREE_GB} GiB free; need ${FLOOR} GiB so a staging copy of the ${IMG_GB} GB image cannot fill the disk. Free some first (\`xcodevaultctl clean --apply\` recovers user-level regenerable data)."

# `runtime unmount` and `runtime delete` take the IMAGE UUID, not the runtime identifier — the
# earlier draft passed the identifier and got "No runtime disk images or bundles found matching…",
# which the mount assertion then correctly reported as a failed unmount.
IMAGE_UUID=$(sim runtime list -j 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d.items():
    if v.get('runtimeIdentifier')=='$TARGET_RID': print(v.get('identifier') or k); break") || true
[ -n "$IMAGE_UUID" ] || fail "could not resolve the image UUID for $TARGET_RID"

INTERNAL_IMAGE=$(python3 -c "
import plistlib,pathlib,urllib.parse,sys
d=plistlib.loads(pathlib.Path('$PLIST').read_bytes())
m=[i for i in d.get('images',[]) if i.get('runtimeInfo',{}).get('bundleIdentifier')=='$TARGET_RID']
if len(m)!=1: sys.exit(1)
print(urllib.parse.unquote(urllib.parse.urlparse(m[0]['path']['relative']).path))") || fail "expected exactly one $TARGET_RID entry"

{
  echo "E4b — CoreSimulator with runtime bytes on an external volume"
  echo "date:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')   macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))   arch: $(uname -m)"
  echo "xcode:    $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "repo:     $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "target:   $TARGET_RID (image $IMAGE_UUID)"
  echo "internal: $INTERNAL_IMAGE"
  echo "external: $EXTERNAL_IMAGE"
  echo "free:     $(df -h / | tail -1 | awk '{print $4}')"
} | redact | tee -a "$OUT"

# Byte-identity. Without this a negative result cannot be attributed to the path rather than the
# bytes — and for watchOS this has never been checked (E4a hashed iOS).
echo "== hashing both images (a few minutes) ==" | tee -a "$OUT"
H_INT=$(shasum -a 256 "$INTERNAL_IMAGE" | cut -d' ' -f1)
H_EXT=$(shasum -a 256 "$EXTERNAL_IMAGE" | cut -d' ' -f1)
echo "internal sha256: $H_INT" | tee -a "$OUT"
echo "external sha256: $H_EXT" | tee -a "$OUT"
[ "$H_INT" = "$H_EXT" ] || fail "the external image is NOT byte-identical — relocating it would test the wrong thing"

snapshot () {
  echo "-- runtimes --"; sim runtime list -v 2>&1
  echo "-- backing files (hdiutil info: the only proof of what is actually being read) --"
  hdiutil info 2>/dev/null | grep -E "image-path|CoreSimulator/Volumes"
  echo "-- staging dirs (shadow-data watch, E9 precedent) --"
  for d in /Library/Developer/CoreSimulator/Images/Inbox /Library/Developer/CoreSimulator/Images/mnt \
           /Library/Developer/CoreSimulator/Cryptex/Images/Inbox; do
    echo "   $d: $(ls -A "$d" 2>/dev/null | wc -l | tr -d ' ') entries"
  done
}
{ echo; echo "== BASELINE =="; snapshot; } | redact | tee -a "$OUT"

if [ "$DRY" -eq 1 ]; then
  echo | tee -a "$OUT"
  echo "DRY RUN: images.plist would be repointed $TARGET_RID -> $EXTERNAL_IMAGE. Nothing written." | tee -a "$OUT"
  exit 0
fi

cp -p "$PLIST" "$BACKUP" || fail "could not back up $PLIST"
chmod 600 "$BACKUP"
echo | tee -a "$OUT"
echo "Backup taken. If anything goes wrong and this script is not running, restore by hand with:" | tee -a "$OUT"
echo "    sudo cp -p $BACKUP $PLIST && sudo launchctl kickstart -k system/com.apple.CoreSimulator.simdiskimaged" | tee -a "$OUT"

restore () {
  trap - EXIT INT TERM            # never let restore run twice
  { echo; echo "== RESTORE =="; } | tee -a "$OUT"
  # Atomic: write beside the target, then rename. A truncate-in-place here is the one failure that
  # re-import would not fix, and at 11 GiB free the re-import path is not reliably available anyway.
  # In-place, NOT a temp-file-plus-rename. Measured 2026-09-09: creating a new file in
  # /Library/Developer/CoreSimulator/Images/ is refused even for root ("Operation not permitted")
  # although the directory carries no BSD flags and is absent from rootless.conf — the same
  # signature as the runtime Inbox (F1). So atomicity is not available here, and the mitigation is
  # the backup living OUTSIDE that directory plus the hash check below.
  if cp -p "$BACKUP" "$PLIST"; then
    echo "images.plist restored in place from $BACKUP" | tee -a "$OUT"
  else
    echo "RESTORE FAILED — run by hand: sudo cp -p $BACKUP $PLIST" | tee -a "$OUT"
  fi
  if shasum -a 256 "$PLIST" "$BACKUP" | awk '{print $1}' | uniq -c | grep -q "^ *2 "; then
    echo "verified: restored plist is byte-identical to the backup" | tee -a "$OUT"
  else
    echo "WARNING: restored plist does NOT match the backup" | tee -a "$OUT"
  fi
  launchctl kickstart -k system/com.apple.CoreSimulator.simdiskimaged 2>&1 | tee -a "$OUT"
  sleep 8
  { echo "-- after restore --"; snapshot; } | redact | tee -a "$OUT"
  echo | tee -a "$OUT"
  echo "If watchOS did not come back: the internal image at $INTERNAL_IMAGE was never touched, so" | tee -a "$OUT"
  echo "this is a pointer problem, not a data problem. Re-run the restore command above, or reboot." | tee -a "$OUT"
  echo "NOTE: re-import is NOT a usable fallback here — the vault's watchOS artifact is an" | tee -a "$OUT"
  echo ".exportedBundle DIRECTORY and \`runtime import\` takes a .dmg, and free space is under the" | tee -a "$OUT"
  echo "1.5x+2GB that preflightImport requires. Restoring the pointer is the recovery path." | tee -a "$OUT"
}
trap 'restore' EXIT
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM

# Unmount first and assert the mount point is clear. Without this the already-attached /dev/diskN
# survives the daemon restart and the experiment reports a stale mount as success.
{ echo; echo "== UNMOUNT the runtime so the daemon has to reopen a file =="; } | tee -a "$OUT"
sim runtime unmount "$IMAGE_UUID" 2>&1 | tee -a "$OUT"
sleep 3
if mount | grep -q "CoreSimulator/Volumes/watchOS"; then
  echo "STILL MOUNTED after unmount — aborting: any verdict now would be about the stale mount." | tee -a "$OUT"
  exit 1
fi
echo "mount point clear." | tee -a "$OUT"

python3 - "$PLIST" "$TARGET_RID" "$EXTERNAL_IMAGE" 2>&1 <<'PY' | tee -a "$OUT"
import plistlib, sys, pathlib
plist, rid, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(plist)
d = plistlib.loads(p.read_bytes())
hits = 0
for img in d.get("images", []):
    if img.get("runtimeInfo", {}).get("bundleIdentifier") == rid:
        old = img["path"]["relative"]
        img["path"]["relative"] = pathlib.Path(new).as_uri()
        hits += 1
        print(f"repointed {rid}\n  from {old}\n  to   {img['path']['relative']}")
if hits != 1:
    print(f"ABORT: expected exactly one entry for {rid}, found {hits}"); sys.exit(1)
# In place. A temp file in this directory is refused even for root (see the restore comment), so
# the atomic rename that would normally protect against a truncated plist is not available. If this
# write itself fails with EPERM, nothing has changed and the experiment simply cannot run.
try:
    p.write_bytes(plistlib.dumps(d, fmt=plistlib.FMT_BINARY))
except PermissionError as e:
    print(f"ABORT: cannot write {plist} even as root ({e}). The secure storage area refuses it.")
    sys.exit(2)
print("images.plist rewritten in place")
PY
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "edit failed; restoring" | tee -a "$OUT"; exit 1; }

echo "== kickstart simdiskimaged ==" | tee -a "$OUT"
launchctl kickstart -k system/com.apple.CoreSimulator.simdiskimaged 2>&1 | tee -a "$OUT"
echo "kickstart exit=$?" | tee -a "$OUT"

# Watch the staging directories while the daemon settles. If it starts copying the external image
# in, that is both a disk-space hazard and shadow data at a canonical path — abort and let the trap
# restore, rather than discovering 5 GB later. Ten one-second samples instead of one blind sleep.
for i in $(seq 1 10); do
  staged=0
  for d in /Library/Developer/CoreSimulator/Images/Inbox /Library/Developer/CoreSimulator/Images/mnt \
           /Library/Developer/CoreSimulator/Cryptex/Images/Inbox; do
    n=$(ls -A "$d" 2>/dev/null | wc -l | tr -d ' '); staged=$(( staged + n ))
  done
  now=$(df -k / | tail -1 | awk '{print int($4/1024/1024)}')
  if [ "$staged" -gt 0 ]; then
    echo "ABORT at t=${i}s: $staged entry(ies) appeared in the staging directories — the daemon is copying the image in." | tee -a "$OUT"
    echo "That is shadow data at a canonical path and a disk-space hazard. Restoring." | tee -a "$OUT"
    exit 1
  fi
  if [ "$now" -lt 3 ]; then
    echo "ABORT at t=${i}s: internal free fell to ${now} GiB. Restoring." | tee -a "$OUT"; exit 1
  fi
  sleep 1
done
echo "staging directories stayed empty; free ${FREE_GB} -> $(df -k / | tail -1 | awk '{print int($4/1024/1024)}') GiB" | tee -a "$OUT"
sim runtime verify "$TARGET_RID" 2>&1 | tee -a "$OUT"

{
  echo
  echo "== VERDICT =="
  snapshot
  echo
  echo "Read the 'image-path' line for the watchOS volume, NOT the Ready/Verified text:"
  echo "  image-path = the EXTERNAL .dmg, runtime Ready   -> CoreSimulator will read runtime bytes"
  echo "     from the external volume. The registration+seal half of H9 holds. Booting is still"
  echo "     untested, and H6 expects the removable-device restriction to bite there."
  echo "  image-path = the INTERNAL .dmg                  -> NO-OP. The daemon never opened the"
  echo "     external file; ignore any Ready/Verified, it is the cached signatureState this script"
  echo "     wrote. Not evidence either way."
  echo "  SimDiskImageErrorDomain Code 5 / -67061         -> the seal check rejects a relocated"
  echo "     image, and E4a's user-level hdiutil attach is NOT the same gate."
  echo "  runtime absent / Unusable                       -> CoreSimulator will not read that path."
  echo "     Check the kickstart exit above before concluding: a failed restart looks the same."
  echo
  echo "NOT tested here even on success: booting a device against it. Do that by hand, once."
} | redact | tee -a "$OUT"

echo; echo "Evidence: $OUT"

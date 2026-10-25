#!/bin/bash
# shellcheck disable=SC2329  # phases and their helpers are dispatched indirectly, as "phase_$PHASE"
# E20 — does simdiskimaged use a runtime store that lives on an external APFS volume mounted (not
# symlinked) at /Library/Developer/CoreSimulator/Images?  Gates H20.
#
# CLASS: destructive + root (see .claude/skills/run-experiment). It changes what every simulator on
# this Mac runs from, until `restore`. Ask before running, every time.
#
# WHY THIS SHAPE AND NO OTHER (H20, docs/research/OS-LEVEL-RELOCATION-ALTERNATIVES-2026-10-22.md):
#   simdiskimaged's embedded sandbox allows file-mount only under CoreSimulator/{Images,Volumes,
#   Cryptex/...} and its code rejects symlinks by name. A real mount whose mount point IS
#   .../Images is the one relocation the daemon's own rules leave open.
#
# WHY IT IS SAFE TO RUN ON THE REAL MACHINE:
#   - The internal store is COPIED, never moved. It stays intact underneath the mount; unmounting
#     uncovers it again. The only deletions are this script's own mktemp device set and its state
#     file. Nothing is ever force-unmounted.
#   - No plist is edited. images.plist is copied byte-identically; its paths already read
#     /Library/Developer/CoreSimulator/Images/<UUID>.dmg, which is the mount point.
#   - The volume is re-identified (mount point, UUID, st_dev) immediately before and after the copy,
#     so a drive pulled mid-copy is caught: ditto would otherwise recreate /Volumes/<name> on the
#     INTERNAL disk and the byte comparison would pass against that copy (review 2026-10-23, #1).
#   - The copy and its verification run with the runtimes STILL ATTACHED (they are sealed and
#     read-only). The runtimes are detached only for the short window before mount_apfs, and that
#     window uses no simctl call — `mountPolicy: automatic` means a simctl call could re-attach a
#     runtime from the internal store, which the mount would then cover (review #2). The mount table
#     is asserted empty of runtime volumes both before and right after the mount.
#   - It refuses with xcodebuild running or any simulator booted (any device set: launchd_sim), and
#     fails closed when the tools it asks cannot answer (review #3).
#   - A reboot, or the drive being pulled, drops the mount; what is uncovered is the untouched
#     internal store, consistent with its own images.plist. That is what makes the experiment
#     reversible — and why it says NOTHING about a product that deleted the internal copy.
#
# PHASES — run one at a time, in this order; each writes its own evidence file:
#   preflight   read-only. Checks everything stage needs and snapshots the internal store.
#   stage       sudo. Copy + verify the store onto the volume; detach the runtimes; mount the volume
#               at Images; restart simdiskimaged; record WHICH FILE each runtime is served from.
#   exercise    a scratch device set: create, boot, wait for Booted, shut down, delete.
#   clone-import  (arm 3) sudo; staged only. Clone the smallest runtime's image INSIDE the volume
#               (cp -c, APFS clonefile), delete that runtime from the mounted store, and re-add it
#               from the clone with `simctl runtime add`, timing it and measuring free space on the
#               volume and on the internal disk. Re-checks before every step that Images is still the
#               staged volume. Re-baselines the stage-mounted snapshot only if the sole change is its
#               own image swap. Afterwards the volume differs from the internal store (new image UUID),
#               so a later stage needs a fresh copy, not --reuse-copy.
#   boot-arm    (arm 5) sudo; staged with --mount-with diskutil only. Adds two marked lines to /etc/fstab so
#               DiskArbitration mounts the volume at Images whenever it appears — at boot or on hotplug.
#               Persistent system configuration: boot-disarm removes exactly those lines.
#   boot-check  (arm 5) read-only. After a restart (with or without the drive) or a hotplug, classifies
#               the result: BOOT PASS / SHADOW / ABSENT / NOT MOUNTED, pre-registered in the phase.
#   boot-disarm (arm 5) sudo. Removes the two lines (or the file, if nothing else was in it). Then restore.
#   pull-arm    (arm 4b) staged only, fstab disarmed, every OTHER volume of the drive unmounted. Records the
#               baseline and starts a background log stream; with --live it also boots a scratch device
#               (temp --set) on the volume's runtime. Then the operator PULLS THE CABLE — no eject.
#   pull-check  (arm 4b) read-only (sudo lsof only), every probe under a timeout because a dead mount can
#               hang a command. Classifies what the pull did; readings pre-registered below.
#   restore     sudo. Compare the mounted store with what stage left (anything written there while
#               mounted would be stranded); detach the runtimes; unmount Images (never -f); snapshot
#               the uncovered internal store at once and again after a rescan (rule 6).
#   status      read-only snapshot, for any time — including after a reboot.
#
# PRE-REGISTERED READINGS (fixed before the first run):
#   stage PASS    both runtimes Ready + Verified AND lsof shows each <UUID>.dmg open on the mounted
#                 volume's device. Ready alone is NOT a pass. If lsof shows no holder, the ordering
#                 argument applies only if the mount table showed NO runtime volume between detach
#                 and mount — the script asserts that and stops otherwise.
#   stage FAIL    a runtime Unusable/missing, signature not Verified, or served from the internal disk.
#   exercise PASS the scratch device reaches Booted and shuts down cleanly.
#   clone-import  (pre-registered 2026-10-23, before its first run)
#                 CLONE  the re-added runtime is Ready + Verified, served from the volume, AND the
#                        volume's free space fell by less than 5% of the image's size during the add.
#                 COPY   it is Ready, but the volume's free space fell by 50% or more of the image.
#                 In between: report the numbers, call it neither. FAIL if it never becomes Ready.
#                 Internal free space is recorded too; it must not fall by the image's size.
#   restore       records, does not judge: the internal store at the mount (pre-mount) vs. the moment
#                 it is uncovered (post-umount) vs. after a rescan (post-rescan). lastUsedAt churn in
#                 images.plist is expected after the rescan; any other change is a rule-6 finding.
#   pull-check    (arm 4b, pre-registered 2026-10-24, before its first run). One of, first match wins:
#                 NOT PULLED  the drive is still present and mounted at Images: nothing to classify.
#                 PANIC       the Mac restarted since pull-arm, or a panic report is newer than it — KILLS H20.
#                 HUNG        a CoreSimulator process sits in uninterruptible wait, or simctl does not answer
#                             within 60 s — needs a reboot to clear — KILLS H20 for a product.
#                 SHADOW      Images is uncovered and the internal store's listing or image set differs from
#                             pre-mount — the rule-6 failure — KILLS H20.
#                 STALE MOUNT Images is still a mount point with the drive gone: the store is neither the
#                             drive nor the internal copy until a reboot. Recorded as a finding.
#                 SURVIVED    Images uncovered, internal store unchanged, nothing hung. Sub-reading from lsof:
#                             FALLBACK if runtimes are open on the internal disk again, DETACHED if not.
#                 With --live, the scratch device's state is recorded alongside (it is expected to die).
#                 Crash reports (simdiskimaged, diskimagesiod, launchd_sim, CoreSimulatorService) newer
#                 than pull-arm are listed by name in every case.
#
# WHAT THIS DOES NOT TEST (deliberately deferred, see H20):
#   arm 3 import of an .exportedBundle (clone-import uses a raw image clone, the cheaper shape —
#   the .exportedBundle form is what the product's Runtime Library holds); a FORCED unmount (arm 4b
#   tests the physical pull only); a pull during an install or a test run; and
#   a layout with the internal store deleted — that turns "uncovered store" into an empty stub, the
#   shadow-data case rule 6 forbids. Not before every other arm passes and an ADR says so.
#   No fault-injection harness exists for this script (unlike e6c's); its failure paths are
#   reviewed, not exercised.
#
# PREREQUISITES (preflight checks each one):
#   - a DEDICATED, EMPTY APFS volume on the external drive, ownership enabled, with room for the
#     store plus 2 GB: 'diskutil apfs addVolume <container> APFS <name>' (H17: no sudo needed), then
#     'sudo diskutil enableOwnership <UUID>'.
#   - a terminal holding Full Disk Access (H15: every refusal in this hierarchy is TCC).
#   - no xcodebuild, no booted simulator, and nothing installing runtimes until restore.
#
# Usage:
#   scripts/experiments/e20-images-mount.sh [--dry-run] [--i-understand] \
#       [--reuse-copy] [--mount-with mount_apfs|diskutil] --volume /Volumes/<name> --volume-uuid <Volume UUID> <phase>
#   --volume is needed for preflight and stage; restore/status read it from the state file.
#   --mount-with diskutil (stage only) mounts through DiskArbitration — `diskutil mount -mountPoint
#   Images <UUID>`, no nobrowse — instead of the default `mount_apfs -o nobrowse`. It exists for one
#   question: the arm-3 repeat showed CacheDelete answering "Invalid volume" (0 bytes free) for the
#   mount_apfs mount, which blocks every add while staged. Pre-registered (2026-10-23, before its run):
#     ACCEPTED  clone-import's log shows CacheDeleteCopyAvailableSpaceForVolume for Images WITHOUT
#               "Invalid volume" and a non-zero result. Two variables changed at once (the mounter and
#               nobrowse); a follow-up would separate them.
#     REJECTED  "Invalid volume" again: neither the mounter nor nobrowse is the cause.
#     NOT RUN   DiskArbitration declines the mount (E6c saw it refuse a previously mounted volume at a
#               chosen mount point): the volume goes back to /Volumes and nothing is staged.
#   --reuse-copy lets stage accept a volume that already holds a copy of the store from an earlier
#   stage (every entry must be a name the store also has); the copy is NOT redone but IS verified
#   byte for byte before anything is detached.
#   --dry-run runs every read-only check for real and prints each mutating command instead of
#   running it; its output goes to a temp file, never to docs/research/evidence.
#   --i-understand is required for stage, exercise and restore without --dry-run.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMAGES=/Library/Developer/CoreSimulator/Images
RTVOLUMES=/Library/Developer/CoreSimulator/Volumes
DAEMON_LABEL=system/com.apple.CoreSimulator.simdiskimaged
STATE_DIR="$HOME/.xcodevault-e20"
STATE_FILE="$STATE_DIR/state"
SNAP_DIR="$STATE_DIR/snapshots"
DEVICE_TYPE="${XCV_E20_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
SELF="scripts/experiments/e20-images-mount.sh"

DRY=0; OK=0; VOLMP=""; VOLUUID=""; PHASE=""; VOLDEV=""; REUSE=0; CI_DEV=""; CI_LOG=""; CI_LOG_PID=""; MOUNTWITH=mount_apfs; CI_SAMPLER=""; CI_MIN=""; LIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --i-understand) OK=1 ;;
    --reuse-copy) REUSE=1 ;;
    --live) LIVE=1 ;;
    --mount-with) MOUNTWITH="${2:-}"; shift ;;
    --volume) VOLMP="${2:-}"; shift ;;
    --volume-uuid) VOLUUID="${2:-}"; shift ;;
    preflight|stage|exercise|clone-import|restore|status|boot-arm|boot-check|boot-disarm|pull-arm|pull-check) PHASE="$1" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$LIVE" = 0 ] || [ "${PHASE:-}" = pull-arm ] || { echo "REFUSING: --live belongs to pull-arm" >&2; exit 2; }
case "$MOUNTWITH" in mount_apfs|diskutil) ;; *) echo "REFUSING: --mount-with takes mount_apfs or diskutil" >&2; exit 2 ;; esac
[ -n "$PHASE" ] || { echo "usage: $0 [--dry-run] [--i-understand] --volume /Volumes/<name> --volume-uuid <UUID> preflight|stage|exercise|clone-import|restore|status|boot-arm|boot-check|boot-disarm|pull-arm|pull-check [--live]" >&2; exit 2; }
case "$VOLMP" in *[[:space:]]*) echo "REFUSING: the volume's name contains whitespace; this script parses the mount table and needs a name without spaces (rename it in Disk Utility)." >&2; exit 2 ;; esac
[ -n "$VOLUUID" ] || { echo "REFUSING: --volume-uuid is required. Read it from 'diskutil apfs list' next to the volume's NAME." >&2; exit 2; }
case "$PHASE" in
  stage|exercise|clone-import|restore|boot-arm|boot-disarm|pull-arm)
    if [ "$DRY" = 0 ] && [ "$OK" = 0 ]; then
      echo "REFUSING: '$PHASE' changes this machine's state. Read the header of this script, then pass --i-understand (or --dry-run)." >&2; exit 2
    fi ;;
esac
if [ "$(id -u)" = 0 ]; then
  echo "REFUSING: run as yourself, not under sudo. simctl as root addresses root's device set; this script calls sudo only for the commands that need it." >&2; exit 2
fi

state_get() { [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" | head -1; }

# Redaction must keep working after the volume leaves /Volumes, so name it from values held now —
# from --volume, or from the state file stage wrote (restore and status do not take --volume).
XCV_REDACT_ALSO_UUID="$VOLUUID"
if [ -n "$VOLMP" ]; then XCV_REDACT_ALSO_LABEL="${VOLMP##*/}"; else XCV_REDACT_ALSO_LABEL="$(state_get label)"; fi
export XCV_REDACT_ALSO_UUID XCV_REDACT_ALSO_LABEL
VOLSHOW="${VOLMP:-<volume>}"

# act <label> <cmd...> — the ONLY way this script changes anything. Dry-run prints, never runs.
act() {
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then
    echo "## $label"; echo "[dry-run] would run: $*"; echo; XCV_LAST_EXIT=0; return 0
  fi
  xcv_run "$label" "$@"
  return "$XCV_LAST_EXIT"
}

FAILS=0
refuse() { echo "!! $*"; FAILS=$((FAILS + 1)); }

vol_field() { diskutil info "$1" 2>/dev/null | sed -n "s/^ *$2: *//p" | head -1; }
is_mountpoint() { mount | awk -v p="$1" '{ for (i = 1; i <= NF; i++) if ($i == "on" && $(i + 1) == p) f = 1 } END { exit !f }'; }
# major,minor — the form lsof's DEVICE column uses, so the two can be compared as strings.
dev_of() { stat -f '%Hd,%Ld' "$1" 2>/dev/null; }
runtime_volume_count() { mount | grep -c " on $RTVOLUMES/"; }

# Fail closed: no answer is not "nothing booted". launchd_sim runs for every booted simulator in
# ANY device set (Xcode's test clones included), which the default-set listing does not see.
nothing_booted() {
  local out
  if pgrep -f launchd_sim >/dev/null; then echo "!! a simulator is running (launchd_sim) — shut it down first"; return 1; fi
  if ! out=$(xcrun simctl list devices booted 2>&1); then echo "!! simctl could not list devices — refusing rather than guessing"; return 1; fi
  if printf '%s\n' "$out" | grep -q "(Booted)"; then echo "!! a simulator is booted in the default set — shut it down first"; return 1; fi
  return 0
}
no_xcodebuild() { if pgrep -x xcodebuild >/dev/null; then echo "!! xcodebuild is running (test rigs?) — wait until it finishes"; return 1; fi; return 0; }

runtime_ids() { # fails if the answer cannot be read
  local json
  json=$(xcrun simctl runtime list -j 2>/dev/null) || return 1
  printf '%s' "$json" | python3 -I -c '
import json, sys
for k, v in json.load(sys.stdin).items():
    if v.get("state") == "Ready": print(k)'
}

runtime_table() {
  echo "## simctl runtime list (summary)"
  xcrun simctl runtime list -j 2>/dev/null | python3 -I -c '
import json, sys
for k, v in json.load(sys.stdin).items():
    print(v.get("runtimeIdentifier"), "|", v.get("state"), "|", v.get("signatureState"), "|", v.get("path"), "|", v.get("mountPath"))' ||
    echo "   (simctl runtime list failed)"
  echo
}

# snap <name> <dir> — tree listing (owner, mode, flags, xattrs, ACLs; no block totals), images.plist
# content, and the image set (every file but images.plist, with its size). Saved, then printed.
snap() {
  local name="$1" dir="$2" out
  echo "## snapshot '$name' of $dir"
  out=$(
    echo "--- listing"; (cd "$dir" && ls -leO@R .) 2>&1 | grep -v '^total '
    echo "--- images.plist"; plutil -p "$dir/images.plist" 2>&1
    # Dot-entries (Spotlight, fseventsd) and the 700-mode `<uuid>.dmg.sb-*` directory a runtime delete leaves
    # are pruned, not walked: their "Permission denied" lines used to land in the image set as if they were images.
    echo "--- image set"; (cd "$dir" && find . \( -name '.?*' -o -name '*.sb-*' \) -prune -o -type f ! -name images.plist -exec stat -f '%N %z' {} + | sort) 2>&1
  )
  printf '%s\n' "$out"
  if [ "$DRY" = 1 ]; then echo "[dry-run] not saved"; echo; return 0; fi
  mkdir -p "$SNAP_DIR"; printf '%s\n' "$out" > "$SNAP_DIR/$name"; echo
}
imageset_of() { sed -n '/^--- image set$/,$p' "$SNAP_DIR/$1"; }
compare() { # <a> <b> <title>
  echo "## compare: $3 ($1 -> $2)"
  if [ ! -f "$SNAP_DIR/$1" ] || [ ! -f "$SNAP_DIR/$2" ]; then echo "   missing snapshot — cannot compare"; echo; return 2; fi
  if diff "$SNAP_DIR/$1" "$SNAP_DIR/$2"; then echo "   UNCHANGED"; echo; return 0; fi
  echo "   CHANGED (diff above)"; echo; return 1
}

# If lsof shows no holder (the backing file can be held where lsof does not see it), fall back on
# ordering — admissible only because stage asserts the mount table held no runtime volume between
# detaching the runtimes and the mount.
served_from() {
  echo "## open runtime images (lsof, root)"
  echo "   internal data volume device: $(dev_of /System/Volumes/Data)"
  if is_mountpoint "$IMAGES"; then echo "   volume mounted at Images device: $(dev_of "$IMAGES")"; fi
  echo "   COMMAND DEVICE NAME"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] would run: sudo lsof -nP +c0 | grep CoreSimulator/Images/<UUID>.dmg"
  else
    sudo lsof -nP +c0 2>/dev/null | grep -E '/CoreSimulator/Images/[0-9A-F-]+\.dmg' | awk '{print "   " $1, $(NF-3), $NF}'
    echo "   (no line above = no visible holder; see the ordering argument)"
  fi
  echo
}

# What is left behind, said plainly — printed on every stop and on interrupt.
state_report() {
  echo "== state now =="
  echo "   Images is a mount point: $(is_mountpoint "$IMAGES" && echo "YES (volume $(vol_field "$IMAGES" "Volume UUID"))" || echo no)"
  echo "   runtime volumes mounted: $(runtime_volume_count) (0 = runtimes detached)"
  if [ -n "$VOLMP" ]; then echo "   $VOLSHOW is a mount point: $(is_mountpoint "$VOLMP" && echo yes || echo no)"; fi
  echo "   to return to normal: $SELF --i-understand --volume-uuid <UUID> restore"
  echo "   (with Images not mounted, restore only rescans if a runtime is not Ready)"
}
stop() { echo; echo "RESULT: $PHASE STOPPED — $*"; state_report; }

volume_checks() { # needs --volume; read-only
  local fs owners loc phys bootphys pw bpw used entries need have f
  [ -n "$VOLMP" ] || { refuse "--volume /Volumes/<name> is required for this phase"; return; }
  case "$VOLMP" in /Volumes/?*) ;; *) refuse "--volume must be /Volumes/<name>"; return ;; esac
  is_mountpoint "$VOLMP" || { refuse "$VOLSHOW is not mounted (connect the drive)"; return; }
  [ "$(vol_field "$VOLMP" "Volume UUID")" = "$VOLUUID" ] || { refuse "$VOLSHOW is not the volume with UUID $VOLUUID"; return; }
  fs=$(vol_field "$VOLMP" "Type (Bundle)"); [ "$fs" = "apfs" ] || refuse "volume is not APFS ($fs)"
  owners=$(vol_field "$VOLMP" "Owners"); [ "$owners" = "Enabled" ] || refuse "ownership is not enabled — run: sudo diskutil enableOwnership $VOLUUID"
  loc=$(vol_field "$VOLMP" "Device Location")
  echo "   device location: $loc; protocol: $(vol_field "$VOLMP" "Protocol"); removable: $(vol_field "$VOLMP" "Removable Media")"
  [ "$loc" = "External" ] || refuse "volume is not on an external device ($loc)"
  phys=$(vol_field "$VOLMP" "APFS Physical Store"); bootphys=$(vol_field / "APFS Physical Store")
  pw=$(vol_field "${phys:-/nonexistent}" "Part of Whole"); bpw=$(vol_field "${bootphys:-/nonexistent}" "Part of Whole")
  if [ -z "$pw" ] || [ -z "$bpw" ] || [ "$pw" = "$bpw" ]; then refuse "cannot show the volume is on a different physical disk from the boot volume ('$pw' vs '$bpw')"; fi
  entries=0
  for f in "$VOLMP"/* "$VOLMP"/.[!.]*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      .fseventsd|.Spotlight-V100|.Trashes|.TemporaryItems|.DS_Store) ;;
      *) if [ "$REUSE" = 1 ] && [ -e "$IMAGES/${f##*/}" ]; then :; else entries=$((entries + 1)); fi ;;
    esac
  done
  if [ "$entries" != 0 ]; then
    if [ "$REUSE" = 1 ]; then refuse "volume holds $entries entries the store does not have — not a previous E20 copy"
    else refuse "volume is not empty ($entries entries) — E20 needs a dedicated, empty volume (or --reuse-copy for a previous E20 copy)"; fi
  fi
  used=$(du -sk "$IMAGES" 2>/dev/null | awk '{print $1}')
  need=$(( ${used:-0} + 2 * 1024 * 1024 ))
  # A reused copy already occupies its space; only the headroom is needed.
  [ "$REUSE" = 1 ] && need=$(( 2 * 1024 * 1024 ))
  have=$(df -k "$VOLMP" | awk 'NR==2{print $4}')
  echo "   store ${used:-?} KB; volume free ${have:-?} KB; needed $need KB"
  [ "${have:-0}" -ge "$need" ] || refuse "not enough free space on the volume"
}

# The volume is still the one checked: mounted at VOLMP, same UUID, same st_dev.
assert_volume() {
  [ "$DRY" = 1 ] && return 0
  is_mountpoint "$VOLMP" && [ "$(vol_field "$VOLMP" "Volume UUID")" = "$VOLUUID" ] && [ "$(dev_of "$VOLMP")" = "$VOLDEV" ]
}

common_checks() { # read-only
  no_xcodebuild || FAILS=$((FAILS + 1))
  nothing_booted || FAILS=$((FAILS + 1))
  if head -c1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
    echo "   this terminal holds Full Disk Access"
  else
    refuse "this terminal lacks Full Disk Access (System Settings → Privacy & Security → Full Disk Access)"
  fi
  [ -d "$IMAGES" ] && [ ! -L "$IMAGES" ] || refuse "$IMAGES is not a real directory"
}

restart_daemon() {
  act "restart simdiskimaged (scan and mount)" sudo launchctl kickstart -k "$DAEMON_LABEL" ||
    act "restart simdiskimaged (fallback)" sudo killall simdiskimaged
  [ "$DRY" = 1 ] && return 0
  sleep 5
  # Let the scan settle: poll until no runtime is in a transitional state, up to 120 s.
  for _ in $(seq 1 24); do
    xcrun simctl runtime list 2>/dev/null | grep -q -E '\((Mounting|Verifying|Staging|Unmounting)' || break
    sleep 5
  done
}

# Detach every Ready runtime; fail closed when the list cannot be read or one will not detach.
unmount_runtimes() {
  local ids id
  if [ "$DRY" = 1 ]; then act "unmount every Ready runtime" xcrun simctl runtime unmount "<each Ready runtime>"; return 0; fi
  ids=$(runtime_ids) || { echo "!! could not read the runtime list"; return 1; }
  for id in $ids; do act "unmount runtime $id" xcrun simctl runtime unmount "$id" || return 1; done
  return 0
}

# ls -leO@R minus block totals, images.plist's line (re-copied and compared before the mount),
# provenance stamps, and the '@' marker a provenance stamp alone adds (ls pads that column with a space).
e20_listing_norm() {
  grep -v -e '^total ' -e ' images\.plist$' -e 'com\.apple\.provenance' | sed 's/^\([-dlbcpsrwxStT]\{10\}\)@/\1 /'
}

# Every regular file byte-identical, and the trees' metadata listings equal.
verify_copy() {
  local rel bad=0 a b
  echo "## verify the copy: every file byte for byte, then metadata"
  # images.plist is excluded: it changes on every use, and is re-copied and compared just before the mount.
  for rel in $(cd "$IMAGES" && find . -type f ! -path './.*' ! -name images.plist | sort); do
    if sudo cmp -s "$IMAGES/$rel" "$VOLMP/$rel"; then echo "   identical: $rel"; else echo "   DIFFERS: $rel"; bad=1; fi
  done
  # com.apple.provenance is not copied data: macOS stamps it on every file and directory a process
  # creates (measured 2026-10-23: ditto's new images.plist, Inbox and mnt carried it, the originals
  # did not). It is dropped, and with it the '@' it adds after the mode; every OTHER xattr still has
  # its own line in -@ output, so a real xattr difference still shows. The stamps are printed below.
  echo "   provenance stamps on the copy (expected, not compared):"
  (cd "$VOLMP" && ls -leO@R .) 2>&1 | grep -B1 'com\.apple\.provenance' | grep -v -e 'com\.apple\.provenance' -e '^--$' | sed 's/^/     /'
  a=$( (cd "$IMAGES" && ls -leO@R .) 2>&1 | e20_listing_norm)
  b=$( (cd "$VOLMP" && ls -leO@R .) 2>&1 | e20_listing_norm)
  if [ "$a" = "$b" ]; then echo "   metadata listing: identical"; else echo "   metadata listing DIFFERS:"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"); bad=1; fi
  echo
  return "$bad"
}

phase_preflight() {
  armed_banner
  echo "## checks"
  common_checks
  volume_checks
  if is_mountpoint "$IMAGES"; then refuse "$IMAGES is already a mount point — run restore first"; else snap preflight "$IMAGES"; fi
  runtime_table
  echo "## internal data volume free: $(df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
  echo; echo "RESULT: preflight $([ "$FAILS" = 0 ] && echo PASSED || echo "FAILED ($FAILS)")"
  [ "$FAILS" = 0 ]
}

on_interrupt() {
  if [ -n "$CI_LOG_PID" ]; then kill "$CI_LOG_PID" 2>/dev/null; fi
  if [ -n "$CI_SAMPLER" ]; then kill "$CI_SAMPLER" 2>/dev/null; fi
  echo; echo "RESULT: $PHASE INTERRUPTED"; state_report
  { echo "E20 $PHASE interrupted:"; state_report; } >/dev/tty 2>/dev/null
  exit 130
}

# Unmount Images the way it was mounted; never forced either way. A DiskArbitration mount goes back
# through DiskArbitration; a mount_apfs mount through umount.
unmount_images() {
  local how="${1:-$(state_get mounter)}"
  if [ "$how" = diskutil ]; then act "unmount Images through DiskArbitration (never forced)" sudo diskutil unmount "$IMAGES"
  else act "unmount Images (never forced)" sudo umount "$IMAGES"; fi
}

# Right after mount_apfs, before the daemon is restarted, nothing on the volume is open: a plain
# umount undoes the mount without touching runtimes or simulators (review N2).
rollback_mount() {
  unmount_images "$MOUNTWITH" || { stop "rollback unmount refused — Images is still mounted"; return 1; }
  restart_daemon
  act "give the volume back to /Volumes" sudo diskutil mount "$VOLUUID"
  return 0
}

phase_stage() {
  local devnode owner mode before after n
  armed_banner
  echo "## checks"
  common_checks; volume_checks
  is_mountpoint "$IMAGES" && refuse "$IMAGES is already a mount point — run restore first"
  if [ "$FAILS" != 0 ]; then
    if [ "$DRY" = 0 ]; then echo "RESULT: stage REFUSED ($FAILS) — nothing was changed"; return 1; fi
    echo "[dry-run] a real run would STOP HERE ($FAILS refusals). Showing the rest of the plan anyway."; echo
  fi
  devnode=$(vol_field "${VOLMP:-/nonexistent}" "Device Node"); VOLDEV=$(dev_of "${VOLMP:-/nonexistent}")
  if [ -z "$devnode" ] || [ -z "$VOLDEV" ]; then
    if [ "$DRY" = 1 ]; then devnode="<device-node>"; else echo "!! cannot read the volume's device node"; return 1; fi
  fi
  trap on_interrupt INT TERM HUP
  if [ "$DRY" = 0 ]; then
    mkdir -p "$STATE_DIR"
    printf 'uuid=%s\ndevnode=%s\nlabel=%s\nvoldev=%s\nmounter=%s\nstaged=%s\n' "$VOLUUID" "$devnode" "${VOLMP##*/}" "$VOLDEV" "$MOUNTWITH" "$(date -u +%FT%TZ)" > "$STATE_FILE"
  fi
  runtime_table
  served_from

  # 1. Copy and verify with the runtimes still attached.
  act "keep Spotlight off the volume" sudo mdutil -i off "$VOLSHOW"
  assert_volume || { stop "the volume is no longer the one checked; nothing was copied"; return 1; }
  if [ "$REUSE" = 1 ]; then
    echo "## --reuse-copy: the volume's existing copy is kept and verified below; ditto is not run"; echo
  elif ! act "copy the store to the volume (copy, never move)" sudo ditto "$IMAGES/" "$VOLSHOW/"; then
    if assert_volume; then stop "ditto failed; the internal store is untouched, the volume holds a partial copy"
    else stop "the volume went away during the copy — a copy may now be on the INTERNAL disk at $VOLSHOW; inspect and remove it yourself"; fi
    return 1
  fi
  assert_volume || { stop "the volume went away during the copy — a copy may now be on the INTERNAL disk at $VOLSHOW; inspect and remove it yourself"; return 1; }
  owner=$(stat -f '%Su:%Sg' "$IMAGES"); mode=$(stat -f '%Lp' "$IMAGES")
  act "volume root owned like the store ($owner)" sudo chown "$owner" "$VOLSHOW"
  act "volume root mode like the store ($mode)" sudo chmod "$mode" "$VOLSHOW"
  if [ "$DRY" = 0 ]; then
    verify_copy || { stop "the copy differs from the store; nothing was detached or mounted"; return 1; }
    assert_volume || { stop "the volume went away during verification — check $VOLSHOW on the INTERNAL disk"; return 1; }
  fi
  before=$( (cd "$IMAGES" && find . -type f ! -name images.plist -exec stat -f '%N %z %m' {} + | sort) 2>&1)

  # 2. The copy took minutes; a rig may have started. Re-check while a simctl call is still allowed.
  if [ "$DRY" = 0 ]; then
    { no_xcodebuild && nothing_booted; } || { stop "a rig started during the copy; nothing was detached or mounted"; return 1; }
  fi
  # The short window: no simctl call from here to the mount (it could re-attach a runtime).
  act "refresh sudo so no password prompt widens the window" sudo -v
  unmount_runtimes || { stop "a runtime would not detach; nothing is mounted"; restart_daemon; return 1; }
  if [ "$DRY" = 0 ]; then
    no_xcodebuild || { stop "xcodebuild started; nothing is mounted"; restart_daemon; return 1; }
    if pgrep -f launchd_sim >/dev/null; then stop "a simulator started; nothing is mounted"; restart_daemon; return 1; fi
    n=$(runtime_volume_count)
    [ "$n" = 0 ] || { stop "$n runtime volume(s) still attached after detaching; nothing is mounted"; restart_daemon; return 1; }
    after=$( (cd "$IMAGES" && find . -type f ! -name images.plist -exec stat -f '%N %z %m' {} + | sort) 2>&1)
    [ "$before" = "$after" ] || { stop "the internal image set changed since the copy; nothing is mounted"; restart_daemon; return 1; }
  fi
  act "re-copy images.plist (it changes on use)" sudo cp -p "$IMAGES/images.plist" "$VOLSHOW/images.plist"
  if [ "$DRY" = 0 ] && ! sudo cmp -s "$IMAGES/images.plist" "$VOLMP/images.plist"; then
    stop "images.plist copy differs; nothing is mounted"; restart_daemon; return 1
  fi
  snap pre-mount "$IMAGES"
  assert_volume || { stop "the volume is no longer the one checked; nothing is mounted"; restart_daemon; return 1; }
  act "release the volume from /Volumes" sudo diskutil unmount "$VOLUUID" || {
    stop "diskutil would not unmount the volume; it is still at $VOLSHOW and nothing is mounted at Images"; restart_daemon; return 1; }
  if [ "$MOUNTWITH" = diskutil ]; then
    act "mount the volume at Images through DiskArbitration" sudo diskutil mount -mountPoint "$IMAGES" "$VOLUUID" || {
      act "give the volume back to /Volumes" sudo diskutil mount "$VOLUUID"
      stop "DiskArbitration declined to mount the volume at Images (pre-registered NOT RUN); Images is the internal store"; restart_daemon; return 1; }
  else
    act "mount the volume at Images" sudo mount_apfs -o nobrowse "$devnode" "$IMAGES" || {
      stop "mount_apfs refused; the volume is unmounted (not at /Volumes), Images is the internal store"; restart_daemon; return 1; }
  fi

  # 3. Is it really ours, owned, and did nothing slip in during the window?
  if [ "$DRY" = 0 ]; then
    is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] || {
      stop "Images is not mounted with volume $VOLUUID after mount_apfs reported success"; restart_daemon; return 1; }
    echo "## mount line"; mount | grep " on $IMAGES "; echo
    n=$(runtime_volume_count)
    if [ "$n" != 0 ]; then
      echo "!! $n runtime volume(s) attached during the window — served from the internal store; rolling back"
      rollback_mount || return 1
      stop "rolled back: a runtime re-attached from the internal store before the mount"; return 1
    fi
    if mount | grep " on $IMAGES " | grep -q noowners; then
      echo "!! mounted noowners — rolling back (H20 requires owners)"
      rollback_mount || return 1
      stop "rolled back: the volume mounted without ownership"; return 1
    fi
  fi
  restart_daemon
  runtime_table
  served_from
  snap stage-mounted "$IMAGES"
  trap - INT TERM HUP
  echo "## internal data volume free: $(df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
  echo
  local pfx=""; [ "$DRY" = 1 ] && pfx="[dry-run] "
  echo "${pfx}RESULT: staged. Read the tables above against the pre-registered readings in this script's header:"
  echo "${pfx}        PASS needs every runtime Ready + Verified AND every open <UUID>.dmg on the mounted volume's device."
  echo
  echo "${pfx}!!! EVERY simulator on this Mac now runs from the external drive — the test rigs included — until"
  echo "${pfx}!!! '$SELF --i-understand --volume-uuid <UUID> restore'. Do not install or delete runtimes, and do"
  echo "${pfx}!!! not eject the drive — nor the volume in Finder, where a DiskArbitration mount shows up — while staged."
}

phase_exercise() {
  local set udid state rt
  if [ "$DRY" = 0 ]; then
    is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] || { echo "!! Images is not mounted with $VOLUUID — run stage first"; return 1; }
    no_xcodebuild || return 1
  fi
  set=$(mktemp -d -t xcv-e20-set) || return 1
  set=$(cd "$set" && pwd -P)
  case "$set" in /private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING: unexpected temp location $set"; rmdir "$set"; return 1 ;; esac
  echo "## scratch device set (internal, temporary): $set"
  rt=$(xcrun simctl list runtimes -j 2>/dev/null | python3 -I -c '
import json, sys
r = [x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]
print(r[0] if r else "")')
  [ -n "$rt" ] || { echo "!! no available iOS runtime"; rmdir "$set"; return 1; }
  if [ "$DRY" = 1 ]; then
    act "create" xcrun simctl --set "$set" create xcv-e20 "$DEVICE_TYPE" "$rt"
    act "boot" xcrun simctl --set "$set" boot "<udid>"
    act "shutdown" xcrun simctl --set "$set" shutdown "<udid>"
    act "delete" xcrun simctl --set "$set" delete "<udid>"
    rmdir "$set"; return 0
  fi
  udid=$(xcrun simctl --set "$set" create xcv-e20 "$DEVICE_TYPE" "$rt" 2>&1) || { echo "!! create failed: $udid"; rm -rf "$set"; echo "RESULT: exercise FAILED at create"; return 1; }
  echo "   created $udid on $rt"
  xcv_run "boot" xcrun simctl --set "$set" boot "$udid"
  state=""
  for _ in $(seq 1 60); do
    state=$(xcrun simctl --set "$set" list devices 2>/dev/null | grep "$udid" | sed -n 's/.*(\([A-Za-z ]*\)) *$/\1/p')
    [ "$state" = "Booted" ] && break
    sleep 5
  done
  echo "   state after boot wait: ${state:-unknown}"
  served_from
  xcv_run "shutdown" xcrun simctl --set "$set" shutdown "$udid"
  xcv_run "delete" xcrun simctl --set "$set" delete "$udid"
  rm -rf "$set"
  echo "RESULT: exercise $([ "$state" = "Booted" ] && echo PASSED || echo "FAILED (never reached Booted)")"
  [ "$state" = "Booted" ]
}

# Before EVERY step, Images must still be the staged volume — same UUID, same device as at the
# start. If the mount dropped, every path below would be the INTERNAL store, and `runtime delete`
# would delete the internal image (clone-import review #1).
ci_guard() {
  [ "$DRY" = 1 ] && return 0
  if is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] && [ "$(dev_of "$IMAGES")" = "$CI_DEV" ]; then return 0; fi
  stop "Images is no longer the staged volume — stopped before '$1' so nothing reaches the internal store"
  return 1
}
ci_names() { imageset_of "$1" | awk '{print $1}'; }
devices_on() { # <runtimeIdentifier> — "udid isAvailable" per device in the default set; UNREADABLE on failure
  local j; j=$(xcrun simctl list devices -j 2>/dev/null) || { echo UNREADABLE; return 1; }
  printf '%s' "$j" | python3 -I -c '
import json, sys
for d in json.load(sys.stdin)["devices"].get(sys.argv[1], []): print(d["udid"], d.get("isAvailable"))' "$1" || echo UNREADABLE
}
pairs_now() { # UNREADABLE on failure
  local j; j=$(xcrun simctl list pairs -j 2>/dev/null) || { echo UNREADABLE; return 1; }
  printf '%s' "$j" | python3 -I -c '
import json, sys
for k, p in sorted(json.load(sys.stdin)["pairs"].items()): print(k, p["watch"]["udid"], p["phone"]["udid"])' || echo UNREADABLE
}
dyld_cache_kb() { du -sk /Library/Developer/CoreSimulator/Caches/dyld/*/*"$1"* 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

# The daemon's free-space and staging decisions are info-level messages, which macOS does not keep:
# `log show` afterwards came back empty on the first arm-3 run. So stream them live, from just before
# the delete to just after the add, into a temp file, and copy the relevant lines into the evidence.
ci_log_start() {
  if [ "$DRY" = 1 ]; then echo "[dry-run] would run in the background: log stream --level info --style compact --timeout 30m --predicate 'process == \"simdiskimaged\"'"; echo; return 0; fi
  CI_LOG=$(mktemp -t xcv-e20-sdi-log) || { echo "!! could not create the log file; continuing without the log"; return 0; }
  # Not under sudo: an admin user can stream, and a stream we started ourselves is one we can stop with a
  # plain kill (sudo may drop a signal from its own process group, leaving a root stream and a hung wait).
  # --timeout is the backstop: the stream can never outlive the run by more than that.
  log stream --level info --style compact --timeout 30m --predicate 'process == "simdiskimaged"' > "$CI_LOG" 2>&1 &
  CI_LOG_PID=$!
  sleep 3
  echo "## simdiskimaged log stream started (info level)"; echo
}
# The add stages the whole image on the internal disk before it fails or finishes (arm-3 repeat log), so
# the free space measured after it hides the peak. Sample it once a second, read-only, bounded at 30 min.
ci_sampler_start() {
  [ "$DRY" = 1 ] && return 0
  CI_MIN=$(mktemp -t xcv-e20-min) || return 0
  ( m=""; for _ in $(seq 1 1800); do
      f=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}')
      if [ -z "$m" ] || [ "$f" -lt "$m" ]; then m=$f; echo "$m" > "$CI_MIN"; fi
      sleep 1
    done ) &
  CI_SAMPLER=$!
}
ci_sampler_stop() { # prints the lowest internal free space seen
  [ -n "$CI_SAMPLER" ] || return 0
  kill "$CI_SAMPLER" 2>/dev/null; wait "$CI_SAMPLER" 2>/dev/null; CI_SAMPLER=""
  echo "   lowest internal free space during the add: $(cat "$CI_MIN" 2>/dev/null || echo '?') KB"
}

ci_log_stop() {
  [ -n "$CI_LOG_PID" ] || return 0
  sleep 3
  kill "$CI_LOG_PID" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$CI_LOG_PID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$CI_LOG_PID" 2>/dev/null; then echo "!! the log stream is still running (pid $CI_LOG_PID); it ends by itself within 30 minutes"
  else wait "$CI_LOG_PID" 2>/dev/null; fi
  CI_LOG_PID=""
  echo "## simdiskimaged log during delete + add (info level, filtered)"
  grep -i -E 'inbox|free space|almost full|clone|same volume|minimum|copy|move|stag|final location|purg|sparse|dyld|delet|request' "$CI_LOG" | cut -c1-400 | tail -120
  echo "   ($(wc -l < "$CI_LOG" | tr -d ' ') lines captured in total; the unfiltered stream is in \$TMPDIR as ${CI_LOG##*/} until the next reboot)"
  echo
}

phase_clone_import() {
  local pick uuid rid size src srcdir short vfree0 vfree1 vfree2 vfree3 ifree0 ifree1 ifree2 t0 t1 dv out newuuid devs0 devs1 pairs0 pairs1 fell kb
  echo "## checks"
  if [ "$DRY" = 0 ]; then
    is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] || { echo "RESULT: clone-import REFUSED — Images is not mounted with $VOLUUID; run stage first"; return 1; }
    no_xcodebuild || { echo "RESULT: clone-import REFUSED"; return 1; }
    nothing_booted || { echo "RESULT: clone-import REFUSED"; return 1; }
    head -c1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1 || {
      echo "RESULT: clone-import REFUSED — this terminal lacks Full Disk Access"; return 1; }
    [ -f "$SNAP_DIR/stage-mounted" ] || { echo "RESULT: clone-import REFUSED — no stage-mounted snapshot to compare against"; return 1; }
  elif ! is_mountpoint "$IMAGES"; then
    echo "[dry-run] Images is not staged: a real run would REFUSE here. Every path below would be the internal store — which is exactly why each real step re-checks the mount."
  fi
  CI_DEV=$(dev_of "$IMAGES")
  echo "   staged volume device at Images: $CI_DEV; mounted by: $(state_get mounter)"
  echo "   mount line: $(mount | grep " on $IMAGES " || echo none)"; echo
  trap on_interrupt INT TERM HUP

  # Nothing may have landed on the volume since stage: otherwise the re-baseline below would absorb it (#3).
  snap ci-start "$IMAGES"
  if [ "$DRY" = 0 ] && [ "$(imageset_of stage-mounted)" != "$(imageset_of ci-start)" ]; then
    diff <(imageset_of stage-mounted) <(imageset_of ci-start)
    echo "RESULT: clone-import REFUSED — the volume's image set changed since stage (above). Run restore and look before anything else."
    return 1
  fi

  # The smallest Ready runtime whose image is a file directly in Images: least to re-add, fewest devices.
  pick=$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c '
import json, sys
c = [(v.get("sizeBytes") or 0, k, v.get("runtimeIdentifier"), v.get("path", "")) for k, v in json.load(sys.stdin).items()
     if v.get("state") == "Ready" and v.get("path", "").startswith("/Library/Developer/CoreSimulator/Images/")]
c.sort()
print("%s %s %s" % (c[0][1], c[0][2], c[0][0]) if c else "")') || pick=""
  [ -n "$pick" ] || { echo "RESULT: clone-import REFUSED — no Ready runtime with an image in Images"; return 1; }
  read -r uuid rid size <<< "$pick"
  # The UUID ends up in sudo paths: accept only the shape simdiskimaged uses (#7).
  printf '%s' "$uuid" | grep -q -E '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$' || {
    echo "RESULT: clone-import REFUSED — unexpected image identifier '$uuid'"; return 1; }
  short=${rid##*.}
  srcdir="$IMAGES/xcv-e20-src"; src="$srcdir/$uuid-source.dmg"
  devs0=$(devices_on "$rid"); pairs0=$(pairs_now)
  echo "   runtime: $rid  image: $uuid.dmg  size: $size bytes"
  echo "   devices on it (default set), udid + available:"; printf '%s\n' "$devs0" | sed 's/^/     /'
  echo "   pairs:"; printf '%s\n' "$pairs0" | sed 's/^/     /'
  echo

  vfree0=$(df -k "$IMAGES" | awk 'NR==2{print $4}'); ifree0=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}')
  echo "## before: volume free ${vfree0} KB, internal free ${ifree0} KB, internal dyld cache for $short $(dyld_cache_kb "$short") KB"
  ls -la /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime 2>&1 | sed 's/^/   /'
  echo

  # 1. The source: an APFS clone inside the same volume. It goes in a subdirectory, not next to the
  #    images; whether simdiskimaged's scan registers it anyway is checked after the add.
  ci_guard "mkdir" || return 1
  act "source directory on the volume" sudo mkdir -p "$srcdir"
  ci_guard "clone" || return 1
  act "clone the image inside the volume (clonefile)" sudo cp -c "$IMAGES/$uuid.dmg" "$src" || { stop "the clone failed; nothing was deleted"; return 1; }
  if [ "$DRY" = 0 ]; then
    [ "$(dev_of "$src")" = "$CI_DEV" ] || { stop "the clone is not on the staged volume; nothing was deleted"; return 1; }
    sudo cmp -s "$IMAGES/$uuid.dmg" "$src" || { ci_guard "remove bad clone" && act "remove the bad clone" sudo rm -f "$src"; stop "the clone differs from the image; nothing was deleted"; return 1; }
    vfree1=$(df -k "$IMAGES" | awk 'NR==2{print $4}')
    echo "   clone cost on the volume: $(( vfree0 - vfree1 )) KB (a clonefile should be ~0)"; echo
  fi

  # 2. Offload: delete the runtime from the MOUNTED store. --keep-asset keeps the call off the
  #    MobileAsset store under /System (#2). A rig may have started since the checks above (#5).
  if [ "$DRY" = 0 ]; then
    { no_xcodebuild && nothing_booted; } || {
      ci_guard "remove clone" && act "remove the clone" sudo rm -f "$src"; stop "a rig started; nothing was deleted"; return 1; }
  fi
  ci_log_start
  ci_guard "delete" || { ci_log_stop; return 1; }
  act "delete $short from the mounted store (keep the MobileAsset)" xcrun simctl runtime delete "$uuid" --keep-asset || {
    ci_log_stop; ci_guard "remove clone" && act "remove the clone" sudo rm -f "$src"; stop "runtime delete failed; the runtime is still installed"; return 1; }
  if [ "$DRY" = 0 ]; then
    sleep 5
    ci_guard "post-delete checks" || { ci_log_stop; return 1; }
    if [ -e "$IMAGES/$uuid.dmg" ] || xcrun simctl runtime list -j 2>/dev/null | grep -q "\"$uuid\""; then
      ci_log_stop; stop "the delete did not take effect ($uuid is still there); the clone is kept at $src. Run restore."; return 1
    fi
    ifree1=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}'); vfree2=$(df -k "$IMAGES" | awk 'NR==2{print $4}')
    echo "## after delete: volume free ${vfree2} KB, internal free ${ifree1} KB (moved $(( ifree1 - ifree0 )) KB), dyld cache for $short $(dyld_cache_kb "$short") KB"
    ls -la /System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime 2>&1 | sed 's/^/   /'
    echo
  fi

  # 3. Import from the same volume, timed. A failure leaves the runtime uninstalled while staged:
  #    keep the clone and say exactly what to do (#5).
  ci_guard "add" || { ci_log_stop; return 1; }
  t0=$(date +%s)
  if [ "$DRY" = 1 ]; then
    act "re-add from the clone (timed)" xcrun simctl runtime add "$src"
    ci_log_stop
    act "remove the source clone" sudo rm -f "$src"; act "remove the source directory" sudo rmdir "$srcdir"
    trap - INT TERM HUP; return 0
  fi
  echo "## re-add from the clone (timed)"; echo "\$ xcrun simctl runtime add $src"
  ci_sampler_start
  out=$(xcrun simctl runtime add "$src" 2>&1); dv=$?
  t1=$(date +%s)
  printf '%s\n' "$out"; echo "[exit=$dv]"
  ci_sampler_stop; echo
  ci_log_stop
  newuuid=$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c '
import json, sys
r = [k for k, v in json.load(sys.stdin).items() if v.get("runtimeIdentifier") == sys.argv[1] and v.get("state") == "Ready"]
print(r[0] if r else "")' "$rid" 2>/dev/null)
  if [ "$dv" != 0 ] || [ -z "$newuuid" ] || [ "$newuuid" = "$uuid" ]; then
    echo "!!! $short is NOT installed while staged, and its devices are unavailable. The clone is kept at $src."
    echo "!!! Run restore now (it uncovers the internal store, which still has $short). Do NOT run 'simctl delete unavailable'."
    stop "the add failed (exit $dv, new image '${newuuid:-none}')"; return 1
  fi

  vfree3=$(df -k "$IMAGES" | awk 'NR==2{print $4}'); ifree2=$(df -k /System/Volumes/Data | awk 'NR==2{print $4}')
  fell=$(( vfree2 - vfree3 )); kb=$(( size / 1024 ))
  echo "## measurements"
  echo "   add wall time: $(( t1 - t0 )) s"
  echo "   volume free: before add ${vfree2} KB, after ${vfree3} KB, fell by $fell KB"
  echo "   image size: $kb KB  (5% = $(( kb / 20 )) KB, 50% = $(( kb / 2 )) KB)"
  echo "   internal free, add only: before ${ifree1} KB, after ${ifree2} KB, fell by $(( ifree1 - ifree2 )) KB"
  echo "   source clone still present after the add: $([ -f "$src" ] && echo yes || echo NO)"
  local reg rl
  # Fail closed: an unreadable list is not "0 entries" — keep the clone (final review, low).
  if rl=$(xcrun simctl runtime list -j 2>/dev/null); then reg=$(printf '%s' "$rl" | grep -c "xcv-e20-src"); else reg="unreadable"; fi
  echo "   runtime entries pointing at the source clone: $reg (must be 0)"
  echo "   internal dyld cache for $short after the add: $(dyld_cache_kb "$short") KB"
  echo
  if [ "$reg" != 0 ]; then
    stop "simdiskimaged registered the source clone itself; it is KEPT at $src (removing it could pull a file from under a mounted runtime). Run restore."
    return 1
  fi
  devs1=$(devices_on "$rid"); pairs1=$(pairs_now)
  echo "## devices on $short after the add (udid + available):"; printf '%s\n' "$devs1" | sed 's/^/     /'
  if printf '%s\n%s\n' "$devs0" "$devs1" | grep -q UNREADABLE; then echo "   !! devices could not be read — NOT verified"
  elif [ "$(printf '%s\n' "$devs0" | awk '{print $1}')" = "$(printf '%s\n' "$devs1" | awk '{print $1}')" ] && ! printf '%s\n' "$devs1" | grep -q " False$"; then
    echo "   same devices, all available"
  else echo "   !! devices changed or unavailable — see above"; fi
  if printf '%s\n%s\n' "$pairs0" "$pairs1" | grep -q UNREADABLE; then echo "   !! pairs could not be read — NOT verified"
  elif [ "$pairs0" = "$pairs1" ]; then echo "   pairs unchanged"; else echo "   !! pairs changed:"; diff <(printf '%s\n' "$pairs0") <(printf '%s\n' "$pairs1"); fi
  echo

  ci_guard "cleanup" || return 1
  act "remove the source clone" sudo rm -f "$src"
  act "remove the source directory" sudo rmdir "$srcdir"
  runtime_table
  served_from

  # Re-baseline restore's stranded-image check only if the ONLY change is this phase's own: the old
  # image gone, the new one present, the source gone (#3). Names only — the daemon may resize.
  snap ci-end "$IMAGES"
  if [ "$(ci_names ci-start | sed "s#^\./$uuid\.dmg\$#./$newuuid.dmg#" | sort)" = "$(ci_names ci-end | sort)" ]; then
    cp "$SNAP_DIR/ci-end" "$SNAP_DIR/stage-mounted"
    echo "## re-baselined 'stage-mounted': the only change on the volume is $uuid.dmg -> $newuuid.dmg"
  else
    echo "## NOT re-baselined: the volume changed beyond this phase's own swap — restore will flag it"
    diff <(ci_names ci-start) <(ci_names ci-end)
  fi
  echo
  trap - INT TERM HUP

  if [ "$fell" -lt $(( kb / 20 )) ]; then echo "RESULT: clone-import CLONE — $short back as $newuuid in $(( t1 - t0 )) s; the volume lost $fell KB of a $kb KB image."
  elif [ "$fell" -ge $(( kb / 2 )) ]; then echo "RESULT: clone-import COPY — $short back as $newuuid in $(( t1 - t0 )) s; the volume lost $fell KB, a full copy."
  else echo "RESULT: clone-import NEITHER — $short back as $newuuid in $(( t1 - t0 )) s; the volume lost $fell KB of a $kb KB image. Read the log above."; fi
  echo "        Confirm 'served from' above shows $newuuid.dmg on device $CI_DEV."
  echo "        The volume now differs from the internal store (new image UUID): a later stage needs a fresh copy, not --reuse-copy."
}

# Detach, unmount (never forced), snapshot the uncovered store at once, then rescan. Returns 1 and
# leaves Images mounted if anything refuses.
phase_restore_body() {
  local cur n
  # The arm-4b scratch device first: it is this script's own, and nothing_booted below would refuse on it.
  pull_cleanup || return 1
  if [ "$DRY" = 0 ]; then
    no_xcodebuild || return 1
    nothing_booted || return 1
  fi
  if ! is_mountpoint "$IMAGES" && [ -n "$(state_get pulled_at)" ]; then
    # After arm 4b the runtime volumes may still be attached with their backing file gone, so "every runtime
    # is attached" below would be wrong. Detach whatever is attached (any state), then rescan.
    echo "   $IMAGES is not a mount point and arm 4b pulled the drive: detaching every runtime, then rescanning"
    unmount_all_runtimes || { echo "!! a runtime would not detach after the pull — reboot to clear it, then restore again"; return 1; }
    restart_daemon; snap post-rescan "$IMAGES"; return 0
  fi
  if ! is_mountpoint "$IMAGES"; then
    echo "   $IMAGES is not a mount point — nothing to unmount"
    # A stage that stopped after detaching the runtimes leaves them detached; only then rescan.
    local total
    total=$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
    # A volume count alone would count dead attachments too (review 4b #5): every runtime must also be Ready.
    if all_runtimes_back; then echo "   every runtime is Ready and attached — nothing to do"
    else
      echo "   $(runtime_volume_count) of ${total:-?} runtimes attached — rescanning"; restart_daemon
      # A pull nobody armed would otherwise read as done (note d).
      all_runtimes_back || { echo "!! not every runtime is Ready and attached after the rescan — reboot, then restore again"; return 1; }
    fi
    runtime_table; return 0
  fi
  cur=$(vol_field "$IMAGES" "Volume UUID")
  if [ -z "$cur" ]; then echo "!! cannot identify the volume at $IMAGES (a stale mount after the drive was pulled?) — reboot to clear it"; return 1; fi
  if [ "$cur" != "$VOLUUID" ]; then echo "!! $IMAGES holds volume $cur, not $VOLUUID — refusing to unmount something this script did not mount"; return 1; fi
  act "refresh sudo" sudo -v
  unmount_runtimes || { echo "!! a runtime would not detach; Images left mounted"; return 1; }
  if [ "$DRY" = 0 ]; then
    n=$(runtime_volume_count)
    [ "$n" = 0 ] || { echo "!! $n runtime volume(s) still attached; Images left mounted"; return 1; }
  fi
  unmount_images || {
    echo "!! umount refused (busy). Nothing forced. Find the holder with: sudo lsof +D $IMAGES"; return 1; }
  snap post-umount "$IMAGES"
  restart_daemon
  snap post-rescan "$IMAGES"
  return 0
}

phase_restore() {
  local staged_uuid stranded=0
  # An armed fstab would make the final `diskutil mount` put the volume straight back over Images, and
  # deleting the state file would erase the only record of the arm (review #1).
  if fstab_armed; then
    armed_banner
    echo "RESULT: restore REFUSED — run boot-disarm first; nothing was changed"; return 1
  fi
  staged_uuid=$(state_get uuid)
  if [ -f "$STATE_FILE" ]; then echo "## state"; cat "$STATE_FILE"; echo; fi
  if [ -n "$staged_uuid" ] && [ "$staged_uuid" != "$VOLUUID" ]; then
    echo "RESULT: restore REFUSED — the state file says stage used $staged_uuid, not $VOLUUID"; return 1
  fi
  # After a pull, Images may be a dead mount: listing or unmounting it can block in the kernel until a reboot
  # (review 4b #1). With the drive gone, touch nothing; with it present, it is the NOT PULLED case.
  if [ -n "$(state_get pulled_at)" ] && is_mountpoint "$IMAGES" && [ "$(drive_present)" != yes ]; then
    echo "RESULT: restore REFUSED — STALE MOUNT: Images is still mounted with the drive gone. Shut down with the drive out,"
    echo "        start up, then run restore again. Nothing was changed."; return 1
  fi
  if is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ]; then
    snap restore-mounted "$IMAGES"
    if [ "$DRY" = 0 ] && [ -f "$SNAP_DIR/stage-mounted" ]; then
      echo "## did anything change ON THE VOLUME while staged? (image set only; plist churn is expected)"
      if [ "$(imageset_of stage-mounted)" = "$(imageset_of restore-mounted)" ]; then echo "   image set UNCHANGED"
      else echo "   image set CHANGED:"; diff <(imageset_of stage-mounted) <(imageset_of restore-mounted); stranded=1; fi
      echo
    fi
  fi
  trap on_interrupt INT TERM HUP
  phase_restore_body || { stop "restore refused (see the state below)"; return 1; }
  trap - INT TERM HUP
  [ "$DRY" = 1 ] && return 0
  local pulled=0 shadow=0 incomplete=0
  if [ -n "$(state_get pulled_at)" ]; then
    pulled=1
    echo "## rule 6 after the pull — internal store, listing and image set (images.plist apart), pre-mount -> post-rescan"
    if diff <(store_view pre-mount) <(store_view post-rescan); then echo "   UNCHANGED"; else echo "   CHANGED (diff above)"; shadow=1; fi
    echo
    echo "## did every runtime come back?"
    all_runtimes_back || incomplete=1
    echo
  else
    compare pre-mount post-umount "rule 6 — the internal store at the moment it is uncovered"
    compare post-umount post-rescan "after simdiskimaged rescans (lastUsedAt churn expected)"
  fi
  runtime_table
  served_from
  if diskutil info "$VOLUUID" >/dev/null 2>&1; then act "give the volume back to /Volumes" sudo diskutil mount "$VOLUUID"
  else echo "## the drive is not connected: reconnect it and it mounts in /Volumes (fstab is not armed)"; fi
  # The pull's record outlives the state file (review 4b #2), and a bad outcome keeps the state file too.
  [ "$pulled" = 1 ] && cp "$STATE_FILE" "$SNAP_DIR/pull-state-$(state_get pulled_at)" 2>/dev/null
  if [ "$(state_get fstab)" = armed ]; then echo "!! the state file says the fstab arm is still in place — keeping it"
  elif [ "$shadow" = 1 ] || [ "$incomplete" = 1 ]; then echo "!! keeping the state file: the pull's outcome needs reading first"
  else rm -f "$STATE_FILE"; fi
  if [ "$shadow" = 1 ]; then
    echo "!!! RESULT: restore done, BUT the internal store changed after the pull (rule 6, diff above). Record it before anything else."
  elif [ "$incomplete" = 1 ]; then
    echo "!!! RESULT: restore INCOMPLETE — not every runtime is Ready and attached after the rescan. A reboot may clear it; then restore again."
  elif [ "$stranded" = 1 ]; then
    echo "!!! RESULT: restore done, BUT the volume's image set changed while staged (diff above): something was"
    echo "!!! installed, imported or deleted there. A deletion loses nothing (the internal store still has it); an"
    echo "!!! installed or imported image is NOT in the internal store. Do not erase the volume until that is understood."
  else
    echo "RESULT: restore done. The volume holds a copy of the store; erase it yourself when finished."
  fi
}

# --- Arm 5: mount at boot through DiskArbitration (/etc/fstab) ---------------------------------
# DiskArbitration reads /etc/fstab when a volume appears and mounts it at the mount point given there,
# at boot or on hotplug alike. That is the DiskArbitration-native form of the one mount that works
# (arm 3, --mount-with diskutil): no nobrowse, so the line carries only `rw`. The entry is the
# experiment's own: two marked lines, removed exactly by boot-disarm.
FSTAB=/etc/fstab
FSTAB_MARK="# xcodevault-e20 arm 5 — remove with: e20-images-mount.sh --volume-uuid <UUID> boot-disarm"
fstab_line() { printf 'UUID=%s %s apfs rw\n' "$VOLUUID" "$IMAGES"; }
fstab_armed() { [ -e "$FSTAB" ] && grep -q -i -E "$VOLUUID|xcodevault-e20" "$FSTAB"; }
# Loud wherever an armed fstab could surprise: it remounts the volume over Images every time the drive appears.
armed_banner() {
  fstab_armed || return 0
  echo "!!! $FSTAB holds the E20 arm-5 entry: DiskArbitration mounts the volume over Images whenever the drive appears."
  echo "!!! Remove it with: $SELF --i-understand --volume-uuid <UUID> boot-disarm"
  echo
}
# The store's listing without images.plist (it churns on use) plus the image set — what rule 6 is about.
store_view() { sed -n '1,/^--- images.plist$/p' "$SNAP_DIR/$1" | grep -v -e ' images\.plist$' -e '^--- images.plist$'; imageset_of "$1"; }
plist_view() { sed -n '/^--- images.plist$/,/^--- image set$/p' "$SNAP_DIR/$1"; }
DA_MOUNT_OPTS="apfs, local, nodev, nosuid, journaled"   # the working mount, arm 3 DiskArbitration evidence

phase_boot_arm() {
  local tmp before
  echo "## checks"
  if [ "$DRY" = 0 ]; then
    is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] || {
      echo "RESULT: boot-arm REFUSED — Images is not staged with $VOLUUID; stage it first (--mount-with diskutil)"; return 1; }
    [ "$(state_get mounter)" = diskutil ] || { echo "RESULT: boot-arm REFUSED — the stage was not a DiskArbitration mount; restore and re-stage with --mount-with diskutil"; return 1; }
    if [ -e "$FSTAB" ] && grep -q -i -E "$VOLUUID|$IMAGES|xcodevault-e20" "$FSTAB"; then
      echo "RESULT: boot-arm REFUSED — $FSTAB already mentions this volume, Images or the marker:"; cat "$FSTAB"; return 1
    fi
  fi
  before=absent; [ -e "$FSTAB" ] && before=present
  echo "   $FSTAB before: $([ -e "$FSTAB" ] && echo "present ($(wc -l < "$FSTAB" | tr -d ' ') lines, kept as they are)" || echo absent)"
  echo "   AutomountDisksWithoutUserLogin: $(defaults read /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin 2>/dev/null || echo 'unset (external disks mount at login)')"
  echo "   simdiskimaged: $(launchctl print system/com.apple.CoreSimulator.simdiskimaged 2>/dev/null | sed -n 's/^[[:space:]]*path = //p' | head -1) — submitted on first simulator use, not at boot"
  echo
  tmp=$(mktemp -t xcv-e20-fstab) || return 1
  # A file whose last line has no newline would have our marker glued onto it (review #3).
  { if [ -e "$FSTAB" ]; then cat "$FSTAB"; [ -n "$(tail -c1 "$FSTAB")" ] && echo; fi; echo "$FSTAB_MARK"; fstab_line; } > "$tmp"
  echo "## $FSTAB after"; cat "$tmp"; echo
  act "install $FSTAB (root:wheel 644)" sudo install -m 644 -o root -g wheel "$tmp" "$FSTAB" || { rm -f "$tmp"; echo "RESULT: boot-arm FAILED — $FSTAB not written"; return 1; }
  rm -f "$tmp"
  [ "$DRY" = 1 ] || printf 'fstab=armed\nfstab_before=%s\narmed_at=%s\n' "$before" "$(date +%s)" >> "$STATE_FILE"
  echo "RESULT: boot-arm done. Images stays mounted now. Next: restart with the drive connected, log in, and run boot-check"
  echo "        BEFORE opening Xcode or a simulator. Leave the arm in place only for the test; boot-disarm removes it."
}

# Read-only. Classifies what the last boot (or a hotplug) did, against readings pre-registered here:
#   BOOT PASS    Images is the volume, mounted with the same options as the working DiskArbitration mount, and
#                every open <UUID>.dmg is on its device — the store came up on the drive.
#   DIFFERENT MOUNT  as BOOT PASS but with other mount options: a reading of its own, not a pass.
#   NO OWNERS    mounted without ownership (H20 requires owners).
#   SHADOW       Images is the volume but a runtime is held open on the INTERNAL disk: it attached before the
#                mount (or the drive was hot-plugged under a live store). This is the rule-6 failure. Run restore.
#   NOT REBOOTED no restart since boot-arm: the result would describe the stage, so it is not classified.
#   ABSENT       the drive is not connected and Images is the internal store — the safe fallback, expected.
#   NOT MOUNTED  the drive is connected but Images is not mounted — DiskArbitration did not honour fstab.
#   (In every case, no runtime attached yet means it cannot be classified: run `xcrun simctl runtime list`
#   once to let simdiskimaged scan, then boot-check again.)
phase_boot_check() {
  local present mounted internal ext n_int n_ext boot armed
  # A check without a restart since the arm measures the stage, not the boot: say so, never BOOT PASS.
  # The arm time comes from the state file, or failing that from /etc/fstab's own modification time.
  boot=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/')
  armed=$(state_get armed_at); [ -n "$armed" ] || { [ -e "$FSTAB" ] && armed=$(stat -f %m "$FSTAB"); }
  echo "## boot: $(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/' | xargs -I{} date -r {} '+%Y-%m-%d %H:%M:%S %z') (uptime:$(uptime | sed 's/.*up \([^,]*\),.*/ \1/'))"
  echo "## $FSTAB:"; if [ -e "$FSTAB" ]; then sed 's/^/   /' "$FSTAB"; else echo "   absent"; fi
  present=no; diskutil info "$VOLUUID" >/dev/null 2>&1 && present=yes
  mounted=no; is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] && mounted=yes
  echo "## drive connected: $present; Images is the volume: $mounted"
  mount | grep " on $IMAGES " || echo "   (Images is not a mount point)"
  echo "## runtime volumes attached: $(runtime_volume_count)"
  nothing_booted && echo "## no simulator booted"
  echo
  runtime_table
  served_from
  [ "$DRY" = 1 ] && return 0
  local opts; opts=$(mount | grep " on $IMAGES " | sed 's/.*(\(.*\))$/\1/')
  [ -n "$opts" ] && echo "## mount options: '$opts' (the working DiskArbitration mount had '$DA_MOUNT_OPTS')"
  internal=$(dev_of /System/Volumes/Data); ext=$(dev_of "$IMAGES")
  n_int=$(sudo lsof -nP +c0 2>/dev/null | grep -E '/CoreSimulator/Images/[0-9A-F-]+\.dmg' | awk -v d="$internal" '$(NF-3) == d' | wc -l | tr -d ' ')
  n_ext=$(sudo lsof -nP +c0 2>/dev/null | grep -E '/CoreSimulator/Images/[0-9A-F-]+\.dmg' | awk -v d="$ext" '$(NF-3) == d' | wc -l | tr -d ' ')
  if [ -n "$armed" ] && [ "$boot" -lt "$armed" ]; then echo "RESULT: boot-check NOT REBOOTED — the Mac has not restarted since the arm ($(date -r "$armed" '+%H:%M')); this measures the stage, not a boot. Restart and run boot-check again."
  elif [ "$mounted" = no ] && is_mountpoint "$IMAGES"; then echo "RESULT: boot-check UNEXPECTED — Images holds some other volume"
  elif [ "$mounted" = yes ] && [ "$n_int" != 0 ]; then echo "RESULT: boot-check SHADOW — $n_int runtime image(s) held open on the internal disk under the mounted volume. Disarm, then restore."
    if printf '%s' "$opts" | grep -q noowners; then echo "        and NO OWNERS — the volume is also mounted without ownership"; fi
  elif [ "$mounted" = yes ] && printf '%s' "$opts" | grep -q noowners; then echo "RESULT: boot-check NO OWNERS — mounted without ownership; H20 requires owners. Disarm and restore."
  elif [ "$mounted" = yes ] && [ "$n_ext" != 0 ] && [ "$opts" != "$DA_MOUNT_OPTS" ]; then echo "RESULT: boot-check DIFFERENT MOUNT — the store came up on the drive ($n_ext image(s) on $ext) but with options '$opts', not the working mount's"
  elif [ "$mounted" = yes ] && [ "$n_ext" != 0 ]; then echo "RESULT: boot-check BOOT PASS — the store came up on the drive ($n_ext image(s) open on $ext), same options as the working mount"
  elif [ "$mounted" = yes ]; then echo "RESULT: boot-check UNCLASSIFIED — mounted, no runtime attached yet. Run 'xcrun simctl runtime list' once, then boot-check again."
  elif [ "$present" = no ]; then
    echo "RESULT: boot-check ABSENT — no drive, the internal store is in use ($n_int image(s) open internally)"
    if [ -f "$SNAP_DIR/pre-mount" ]; then
      snap boot-absent "$IMAGES"
      echo "## rule 6 — the internal store after a boot without the drive (listing and image set, images.plist apart)"
      if diff <(store_view pre-mount) <(store_view boot-absent); then echo "   UNCHANGED"; else echo "   CHANGED (diff above)"; fi
      echo "## images.plist apart (lastUsedAt churn is expected):"; diff <(plist_view pre-mount) <(plist_view boot-absent) && echo "   identical"
    fi
  else echo "RESULT: boot-check NOT MOUNTED — the drive is connected but DiskArbitration did not mount it at Images"; fi
}

phase_boot_disarm() {
  local tmp
  [ -e "$FSTAB" ] || { echo "RESULT: boot-disarm — $FSTAB is absent, nothing to remove"; return 0; }
  tmp=$(mktemp -t xcv-e20-fstab) || return 1
  local before_n after_n rc
  grep -v -x -F -e "$FSTAB_MARK" -e "$(fstab_line)" "$FSTAB" > "$tmp"; rc=$?
  if [ "$rc" -gt 1 ]; then rm -f "$tmp"; echo "RESULT: boot-disarm FAILED — could not read $FSTAB (grep exit $rc); nothing changed"; return 1; fi
  before_n=$(wc -l < "$FSTAB" | tr -d ' '); after_n=$(wc -l < "$tmp" | tr -d ' ')
  if [ $(( before_n - after_n )) != 2 ]; then
    rm -f "$tmp"; echo "RESULT: boot-disarm REFUSED — expected to remove exactly 2 lines, would remove $(( before_n - after_n )). $FSTAB left as it is:"; sed 's/^/   /' "$FSTAB"; return 1
  fi
  echo "## $FSTAB now:"; sed 's/^/   /' "$FSTAB"
  echo "## removing exactly the two E20 lines"
  # Remove the file only if it did not exist before the arm AND nothing else is in it now.
  if [ -s "$tmp" ] || [ "$(state_get fstab_before)" = present ]; then
    echo "## $FSTAB after:"; sed 's/^/   /' "$tmp"
    act "install the filtered $FSTAB" sudo install -m 644 -o root -g wheel "$tmp" "$FSTAB" || { rm -f "$tmp"; echo "RESULT: boot-disarm FAILED"; return 1; }
  else
    echo "   nothing else is in it and there was no $FSTAB before the arm: the file is removed"
    act "remove $FSTAB" sudo rm -f "$FSTAB" || { rm -f "$tmp"; echo "RESULT: boot-disarm FAILED"; return 1; }
  fi
  rm -f "$tmp"
  if [ "$DRY" = 0 ] && fstab_armed; then echo "RESULT: boot-disarm FAILED — the entry is still there"; return 1; fi
  [ "$DRY" = 0 ] && [ -f "$STATE_FILE" ] && sed -i '' 's/^fstab=armed$/fstab=disarmed/' "$STATE_FILE"
  echo "RESULT: boot-disarm done. Images is left as it is: run restore next."
}

phase_status() {
  armed_banner
  echo "## Images is a mount point: $(is_mountpoint "$IMAGES" && echo yes || echo no)"
  mount | grep " on $IMAGES " || true
  echo "## runtime volumes mounted: $(runtime_volume_count)"
  if [ -f "$STATE_FILE" ]; then echo "## state"; cat "$STATE_FILE"; fi
  echo
  runtime_table
  nothing_booted && echo "## no simulator booted"
}

# --- Arm 4b: pull the drive with the store in use ----------------------------------------------
# A dead mount can block a probe in the kernel, where no signal reaches it (review 4b #3). So every probe
# that can touch the drive runs in the background into a file; the caller polls it and, if it is still
# running after N seconds, records it as stuck and moves on without waiting. A stuck probe counts as HUNG.
PROBE_STUCK=""
probe() { # probe <seconds> <name> <cmd...>  — output in $PROBE_OUT; returns 0 done, 124 stuck
  local secs="$1" name="$2" pid; shift 2
  # Each probe's file is removed when the next one starts (a stuck writer keeps its unlinked file); the last
  # one is removed by the caller. It can hold a system-wide lsof listing (review 4b note c).
  [ -n "${PROBE_OUT:-}" ] && rm -f "$PROBE_OUT"
  PROBE_OUT=$(mktemp -t xcv-e20-probe) || return 124
  "$@" > "$PROBE_OUT" 2>/dev/null < /dev/null &
  pid=$!
  for _ in $(seq 1 "$secs"); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null; return 0; fi
    sleep 1
  done
  PROBE_STUCK="$PROBE_STUCK $name(pid $pid)"
  return 124
}
tmo() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }   # bounds interruptible waits only
drive_present() { # yes / no / stuck
  probe 30 "diskutil-info" diskutil info "$VOLUUID" || { echo stuck; return; }
  if grep -q "Volume UUID: *$VOLUUID" "$PROBE_OUT"; then echo yes; else echo no; fi
  rm -f "$PROBE_OUT"
}

# Every OTHER volume on the staged volume's PHYSICAL drive, mounted or not: volumes in one APFS container
# share its metadata, so a pull can damage a sibling that is not even mounted (mount-staging.sh, STATUS
# E6b variant B; review 4b #6). Prints OK, OTHERS <list> or ERR <why>; fails closed.
drive_verdict() {
  local dev store phys
  dev=$(vol_field "$IMAGES" "Device Identifier"); store=$(vol_field "$IMAGES" "APFS Physical Store")
  phys=$(vol_field "${store:-/nonexistent}" "Part of Whole")
  [ -n "$dev" ] && [ -n "$phys" ] || { echo "ERR cannot resolve the physical disk under Images"; return; }
  diskutil list -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -I -c '
import json, sys
phys, donor = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: print("ERR unreadable listing"); raise SystemExit
ents = d.get("AllDisksAndPartitions", [])
drive = [e for e in ents if e.get("DeviceIdentifier") == phys]
if len(drive) != 1: print("ERR drive %s not listed" % phys); raise SystemExit
others, stores, found = [], set(), False
for p in drive[0].get("Partitions", []):
    c = p.get("Content", "")
    if c == "EFI": continue
    if c == "Apple_APFS": stores.add(p.get("DeviceIdentifier")); continue
    others.append("%s(%s)" % (p.get("DeviceIdentifier"), c or "no content"))
for e in ents:
    ps = {s.get("DeviceIdentifier") for s in e.get("APFSPhysicalStores", [])}
    if not ps & stores: continue
    for v in e.get("APFSVolumes", []):
        if v.get("DeviceIdentifier") == donor: found = True
        else: others.append(v.get("DeviceIdentifier"))
if not found: print("ERR the staged volume %s is not among the volumes on %s" % (donor, phys)); raise SystemExit
print("OK" if not others else "OTHERS " + " ".join(others))' "$phys" "$dev" || echo "ERR listing failed"
}
lsof_images() { # the open runtime-image lines, or UNREADABLE when lsof gave no listing at all (review 4b #4)
  # Called in $(...), so PROBE_STUCK would be lost: a stuck lsof says STUCK instead, and the caller counts it.
  probe 60 "lsof" sudo -n lsof -b -nP +c0 || { echo STUCK; return; }
  # lsof may exit non-zero on -b warnings while still listing; judge by the output, not the exit code.
  [ -s "$PROBE_OUT" ] || { rm -f "$PROBE_OUT"; echo UNREADABLE; return; }
  grep -E '/CoreSimulator/Images/[0-9A-F-]+\.dmg' "$PROBE_OUT" || true
  rm -f "$PROBE_OUT"
}
count_on() { # <lines> <device> — count, or UNREADABLE
  case "$1" in UNREADABLE|STUCK) echo "$1"; return ;; esac
  printf '%s\n' "$1" | awk -v d="$2" 'NF && $(NF-3) == d' | wc -l | tr -d ' '
}
# The scratch device pull-arm --live booted: shut down and deleted, its set removed. Only a set this script
# recorded, directly under this user's temp directory or /private/tmp, holding nothing but a device set
# (review 4b #7).
pull_cleanup() {
  local set parent tmpd f
  set=$(state_get pull_set)
  [ -n "$set" ] || return 0
  tmpd=$(cd "${TMPDIR:-/private/tmp}" 2>/dev/null && pwd -P); parent=$(dirname "$set")
  case "$set" in *..*) echo "!! the recorded scratch set '$set' contains '..' — not touching it"; return 1 ;; esac
  case "${set##*/}" in xcv-e20-set.*) ;; *) echo "!! '$set' is not a set this script made — not touching it"; return 1 ;; esac
  [ "$parent" = "$tmpd" ] || [ "$parent" = /private/tmp ] || { echo "!! '$set' is not in the temp directory — not touching it"; return 1; }
  if [ -d "$set" ]; then
    for f in "$set"/* "$set"/.[!.]*; do
      [ -e "$f" ] || continue
      case "${f##*/}" in device_set.plist|.lock) ;; *) [ -d "$f" ] && [ -f "$f/device.plist" ] && continue
        echo "!! '$set' holds '${f##*/}', which is not part of a device set — not touching it"; return 1 ;; esac
    done
    act "shut down the arm-4b scratch device" tmo 120 xcrun simctl --set "$set" shutdown all
    act "delete the arm-4b scratch device" tmo 120 xcrun simctl --set "$set" delete all || { echo "!! the scratch device would not delete — reboot, then restore again"; return 1; }
    act "remove the scratch set" rm -rf "$set"
  fi
  [ "$DRY" = 1 ] || sed -i '' '/^pull_set=/d' "$STATE_FILE"
}
unmount_all_runtimes() { # any state, not just Ready: after a pull the runtimes are not Ready
  local ids id
  if [ "$DRY" = 1 ]; then act "unmount every runtime" xcrun simctl runtime unmount "<each runtime>"; return 0; fi
  probe 60 "simctl-runtime-list" xcrun simctl runtime list -j || { echo "!! simctl does not answer"; return 1; }
  ids=$(python3 -I -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))))' "$PROBE_OUT") || { echo "!! could not read the runtime list"; return 1; }
  for id in $ids; do act "unmount runtime $id" tmo 120 xcrun simctl runtime unmount "$id" || true; done
  [ "$(runtime_volume_count)" = 0 ] || { echo "!! $(runtime_volume_count) runtime volume(s) still attached"; return 1; }
}
all_runtimes_back() { # every runtime Ready and attached; prints the count
  local total ready
  total=$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
  ready=$(runtime_ids 2>/dev/null | grep -c .)
  echo "   runtimes: ${total:-?} total, ${ready:-?} Ready, $(runtime_volume_count) attached"
  [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$ready" = "$total" ] && [ "$(runtime_volume_count)" -ge "$total" ]
}

phase_pull_arm() {
  local verdict lines n_ext set udid rt state
  echo "## checks"
  if [ "$DRY" = 0 ]; then
    is_mountpoint "$IMAGES" && [ "$(vol_field "$IMAGES" "Volume UUID")" = "$VOLUUID" ] || { echo "RESULT: pull-arm REFUSED — Images is not staged with $VOLUUID; stage first"; return 1; }
    if fstab_armed; then armed_banner; echo "RESULT: pull-arm REFUSED — disarm first, or a reconnect would remount over Images"; return 1; fi
    [ -z "$(state_get pulled_at)" ] || { echo "RESULT: pull-arm REFUSED — a previous pull is not restored yet; run restore"; return 1; }
    no_xcodebuild || { echo "RESULT: pull-arm REFUSED"; return 1; }
    nothing_booted || { echo "RESULT: pull-arm REFUSED"; return 1; }
  fi
  verdict=$(drive_verdict)
  echo "   other volumes on the staged volume's physical drive: $verdict"
  case "$verdict" in
    OK) ;;
    OTHERS*) [ "$DRY" = 1 ] && echo "   [dry-run] a real run REFUSES here" || {
      echo "RESULT: pull-arm REFUSED — the drive carries other volumes (${verdict#OTHERS }). Mounted or not, a pull can damage them:"
      echo "        volumes in one APFS container share its metadata. Use a drive with nothing on it but the E20 volume."; return 1; } ;;
    *) [ "$DRY" = 1 ] && echo "   [dry-run] a real run REFUSES here" || { echo "RESULT: pull-arm REFUSED — cannot establish what else is on the drive"; return 1; } ;;
  esac
  if [ "$DRY" = 0 ]; then
    act "refresh sudo" sudo -v || return 1
    lines=$(lsof_images); n_ext=$(count_on "$lines" "$(dev_of "$IMAGES")")
    case "$n_ext" in UNREADABLE|STUCK|0) served_from; echo "RESULT: pull-arm REFUSED — no runtime image is seen open on the volume ($n_ext); the pull would test nothing"; return 1 ;; esac
    echo "   $n_ext runtime image(s) open on the volume"
  fi
  served_from
  if [ "$LIVE" = 1 ]; then
    rt=$(xcrun simctl list runtimes -j 2>/dev/null | python3 -I -c '
import json, sys
r = [x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]
print(r[0] if r else "")')
    [ -n "$rt" ] || { echo "RESULT: pull-arm FAILED — no available iOS runtime"; return 1; }
    if [ "$DRY" = 1 ]; then
      act "create a scratch device in a temp set" xcrun simctl --set "<temp set>" create xcv-e20-pull "$DEVICE_TYPE" "$rt"
      act "boot it" xcrun simctl --set "<temp set>" boot "<udid>"
    else
      set=$(mktemp -d -t xcv-e20-set) || return 1; set=$(cd "$set" && pwd -P)
      case "$set" in /private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING: unexpected temp location $set"; rmdir "$set"; return 1 ;; esac
      printf 'pull_set=%s\n' "$set" >> "$STATE_FILE"
      udid=$(xcrun simctl --set "$set" create xcv-e20-pull "$DEVICE_TYPE" "$rt" 2>&1) || { echo "!! create failed: $udid"; pull_cleanup; echo "RESULT: pull-arm FAILED at create"; return 1; }
      xcv_run "boot" xcrun simctl --set "$set" boot "$udid"
      state=""
      for _ in $(seq 1 60); do
        state=$(xcrun simctl --set "$set" list devices 2>/dev/null | grep "$udid" | sed -n 's/.*(\([A-Za-z ]*\)) *$/\1/p')
        [ "$state" = "Booted" ] && break
        sleep 5
      done
      [ "$state" = "Booted" ] || { pull_cleanup; echo "RESULT: pull-arm FAILED — the scratch device never booted"; return 1; }
      echo "   scratch device $udid Booted on $rt (temp set, deleted by restore)"
    fi
  fi
  if [ "$DRY" = 1 ]; then
    echo
    echo "RESULT: [dry-run] pull-arm rehearsed. Nothing was armed — do NOT pull the cable."
    return 0
  fi
  CI_LOG=$(mktemp -t xcv-e20-pull-log) || CI_LOG=""
  if [ -n "$CI_LOG" ]; then
    # Not under sudo, detached, bounded: it outlives this script and ends by itself within 30 minutes.
    # diskarbitrationd is left out: its lines name the drive's model and volumes, which the redactor cannot see.
    nohup log stream --level info --style compact --timeout 30m \
      --predicate 'process == "simdiskimaged" OR process == "diskimagesiod" OR process == "CoreSimulatorService"' \
      > "$CI_LOG" 2>&1 < /dev/null &
    printf 'pull_log=%s\npull_log_pid=%s\n' "$CI_LOG" "$!" >> "$STATE_FILE"
    sleep 3
  fi
  printf 'pulled_at=%s\npull_mode=%s\n' "$(date +%s)" "$([ "$LIVE" = 1 ] && echo live || echo idle)" >> "$STATE_FILE"
  echo
  echo "RESULT: pull-arm done ($([ "$LIVE" = 1 ] && echo 'live: a simulator is booted on the volume' || echo 'idle: runtimes attached, nothing booted'))."
  echo "        Save your work first: a reboot may be needed to clear what the pull leaves behind."
  echo "        Then PULL THE DRIVE'S CABLE — do not eject. Wait 60 seconds, then run pull-check (within 30 minutes)."
}

phase_pull_check() {
  local armed boot present mounted cur internal lines n_int hung_ps s1 s2 s3 simctl_ok crashes set host plog ppid rule6=""
  armed=$(state_get pulled_at)
  [ -n "$armed" ] || { echo "RESULT: pull-check — no pull-arm recorded; nothing to classify"; return 1; }
  boot=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/')
  echo "## pull-arm at $(date -r "$armed" '+%Y-%m-%d %H:%M:%S %z') ($(state_get pull_mode)); boot $(date -r "$boot" '+%Y-%m-%d %H:%M:%S %z')"
  present=$(drive_present)
  mounted=no; is_mountpoint "$IMAGES" && mounted=yes
  cur=""
  if [ "$mounted" = yes ]; then
    if probe 30 "diskutil-info-images" diskutil info "$IMAGES"; then cur=$(sed -n 's/^ *Volume UUID: *//p' "$PROBE_OUT" | head -1); else cur="(no answer)"; fi
  fi
  echo "## drive present: $present; Images is a mount point: $mounted${cur:+ (volume $cur)}"
  mount | grep -E " on ($IMAGES|$RTVOLUMES/)" | sed 's/^/   /' || echo "   (no Images or runtime-volume mount)"
  echo "## runtime volumes in the mount table: $(runtime_volume_count)"
  # Three samples ~5 s apart; only a process in uninterruptible wait in all three counts (review 4b #9).
  sample() { ps -axo pid=,stat=,comm= | awk '$2 ~ /U/ && $3 ~ /simdiskimaged|diskimagesiod|launchd_sim|CoreSimulatorService|simctl/ {print $1, $3}' | sort; }
  s1=$(sample); sleep 5; s2=$(sample); sleep 5; s3=$(sample)
  hung_ps=$(comm -12 <(printf '%s\n' "$s1") <(printf '%s\n' "$s2") | comm -12 - <(printf '%s\n' "$s3") | grep . | sed 's/^/   /')
  echo "## CoreSimulator processes in uninterruptible wait in three samples over 10 s:"; echo "${hung_ps:-   none}"
  simctl_ok=yes
  if probe 60 "simctl-runtime-list" xcrun simctl runtime list -j; then
    python3 -I -c '
import json, sys
for k, v in json.load(open(sys.argv[1])).items():
    print("  ", v.get("runtimeIdentifier"), "|", v.get("state"), "|", v.get("signatureState"), "|", v.get("path"))' "$PROBE_OUT" 2>/dev/null || echo "   (unparsable)"
  else simctl_ok=no; fi
  echo "## simctl runtime list answered within 60 s: $simctl_ok"
  set=$(state_get pull_set)
  if [ -n "$set" ]; then
    echo "## scratch device (live arm):"
    if probe 60 "simctl-list-devices" xcrun simctl --set "$set" list devices; then grep xcv-e20-pull "$PROBE_OUT" | sed 's/^ */   /' || echo "   (not listed)"
    else echo "   (no answer)"; fi
    if pgrep -f launchd_sim >/dev/null; then echo "   launchd_sim is still running"; else echo "   no launchd_sim running"; fi
  fi
  internal=$(dev_of /System/Volumes/Data)
  sudo -v
  lines=$(lsof_images); n_int=$(count_on "$lines" "$internal")
  echo "## open runtime images (lsof -b, root) — internal data volume is $internal"
  if [ "$lines" = UNREADABLE ] || [ "$lines" = STUCK ]; then echo "   $lines (no listing within 60 s)"; else printf '%s\n' "$lines" | awk 'NF {print "   " $1, $(NF-3), $NF}'; fi
  echo "   on the internal disk: $n_int"
  echo
  # Crash-report names carry the host name; it is replaced (review 4b #8).
  host=$(scutil --get LocalHostName 2>/dev/null)
  crashes=$(find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -newermt "@$armed" 2>/dev/null |
    grep -i -E 'panic|simdiskimaged|diskimagesiod|launchd_sim|CoreSimulator' | sed 's#.*/#   #')
  [ -n "$host" ] && crashes=$(printf '%s' "$crashes" | sed "s/$host/<host>/g")
  crashes=$(printf '%s' "$crashes" | sed -E 's/_[A-Za-z0-9-]+(\.(diag|panic|ips))$/_<host>\1/')
  echo "## crash/panic reports newer than pull-arm:"; echo "${crashes:-   none}"
  plog=$(state_get pull_log); ppid=$(state_get pull_log_pid)
  if [ -n "$plog" ] && [ -f "$plog" ]; then
    if [ -n "$ppid" ] && ps -p "$ppid" -o comm= 2>/dev/null | grep -q '^log$'; then kill "$ppid" 2>/dev/null; fi
    echo "## log around the pull (info level, filtered)"
    grep -i -E 'disappear|eject|unmount|remov|terminat|detach|error|fail|lost|not found|missing|stale|mount|scan|images\.plist|orphan' "$plog" | cut -c1-300 | tail -150
    echo "   ($(wc -l < "$plog" | tr -d ' ') lines captured; the unfiltered stream is in \$TMPDIR as ${plog##*/} until the next reboot)"
    echo
  fi
  # Only an uncovered Images is listed: a stale mount could block the listing in the kernel.
  if [ "$mounted" = no ] && [ -f "$SNAP_DIR/pre-mount" ]; then
    snap pull-after "$IMAGES" >/dev/null
    echo "## rule 6 — the uncovered internal store after the pull (listing and image set, images.plist apart)"
    if diff <(store_view pre-mount) <(store_view pull-after); then rule6=UNCHANGED; echo "   UNCHANGED"; else rule6=CHANGED; echo "   CHANGED (diff above)"; fi
    echo "## images.plist apart:"; diff <(plist_view pre-mount) <(plist_view pull-after) && echo "   identical"
    echo
  fi
  # drive_present and lsof_images run in $(...); their stuck probes come back as words, not in PROBE_STUCK.
  [ "$present" = stuck ] && PROBE_STUCK="$PROBE_STUCK diskutil-info"
  [ "$lines" = STUCK ] && PROBE_STUCK="$PROBE_STUCK lsof"
  [ -n "$PROBE_STUCK" ] && echo "## probes still running (stuck, left behind):$PROBE_STUCK"
  if [ "$present" = yes ] && [ "$mounted" = yes ] && [ "$cur" = "$VOLUUID" ]; then echo "RESULT: pull-check NOT PULLED — the drive is still present and mounted at Images"
  elif [ "$boot" -gt "$armed" ] || printf '%s' "$crashes" | grep -q -i panic; then echo "RESULT: pull-check PANIC — the Mac restarted or panicked after the pull. This kills H20."
  elif [ "$mounted" = yes ] && [ -z "$hung_ps" ] && [ "$simctl_ok" = yes ] && [ "$(printf '%s' "$PROBE_STUCK" | sed 's/(pid [0-9]*)//g' | xargs)" = diskutil-info-images ]; then
    # The only thing that hung is asking diskutil about Images itself: that is the stale mount, not CoreSimulator (note a).
    echo "RESULT: pull-check STALE MOUNT — Images is still a mount point and diskutil cannot describe it; shut down with the drive out, then restore"
  elif [ -n "$hung_ps" ] || [ -n "$PROBE_STUCK" ] || [ "$simctl_ok" = no ]; then echo "RESULT: pull-check HUNG — CoreSimulator does not answer or a process is stuck in the kernel; a reboot is needed. This kills H20 for a product."
  elif [ "$rule6" = CHANGED ]; then echo "RESULT: pull-check SHADOW — the internal store changed after the pull (rule 6). This kills H20."
  elif [ "$mounted" = yes ]; then echo "RESULT: pull-check STALE MOUNT — Images is still a mount point (volume: ${cur:-unidentifiable}) with the drive gone; shut down with the drive out, then restore"
  elif [ "$rule6" = UNCHANGED ] && [ "$n_int" != UNREADABLE ] && [ "$n_int" != STUCK ]; then
    if [ "$n_int" -gt 0 ]; then echo "RESULT: pull-check SURVIVED, FALLBACK — internal store unchanged, nothing hung, $n_int runtime image(s) open on the internal disk again"
    else echo "RESULT: pull-check SURVIVED, DETACHED — internal store unchanged, nothing hung, no runtime image open (they come back on restore's rescan)"; fi
  else echo "RESULT: pull-check UNCLASSIFIED — read the sections above"; fi
  echo "        Next: restore (it deletes the scratch device, detaches every runtime and rescans). Keep the drive out until then."
  [ -n "${PROBE_OUT:-}" ] && rm -f "$PROBE_OUT"
}

# A dry run is a rehearsal, not evidence: it goes to a temp file, never into docs/research/evidence.
if [ "$DRY" = 1 ]; then
  OUT=$(mktemp -t xcv-e20-dryrun) || exit 2
else
  OUT="$XCV_EVIDENCE_DIR/e20-$PHASE-$(xcv_env_slug).txt"
  xcv_rotate_out "$OUT" || exit 2
fi
echo "evidence: $OUT"
# The per-user temp directory (/var/folders/<hash>/<hash>/T) identifies the machine; it is rewritten to <tmpdir>.
# The consumers ignore INT/TERM/HUP (ignored dispositions survive exec), so an interrupt reaches
# only the phase, whose trap reports the state left behind into a pipeline that is still there.
{
  xcv_header "E20 images-store mount — phase $PHASE$([ "$DRY" = 1 ] && echo ' (dry run)')"
  echo "# Hypothesis: H20"
  echo
  "phase_${PHASE//-/_}"
} 2>&1 | (trap '' INT TERM HUP; xcv_redact | sed -l -E 's#/(private/)?var/folders/[^/ ]+/[^/ ]+/T/#<tmpdir>/#g' | tee "$OUT")
exit "${PIPESTATUS[0]}"

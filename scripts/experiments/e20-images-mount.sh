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
#   restore       records, does not judge: the internal store at the mount (pre-mount) vs. the moment
#                 it is uncovered (post-umount) vs. after a rescan (post-rescan). lastUsedAt churn in
#                 images.plist is expected after the rescan; any other change is a rule-6 finding.
#
# WHAT THIS DOES NOT TEST (deliberately deferred, see H20):
#   arm 3 import of an .exportedBundle on the same volume (the clone question); arm 4b a physical
#   disconnect or a forced unmount with runtimes attached; arm 5 mounting at boot (LaunchDaemon); and
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
#       --volume /Volumes/<name> --volume-uuid <Volume UUID> <phase>
#   --volume is needed for preflight and stage; restore/status read it from the state file.
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

DRY=0; OK=0; VOLMP=""; VOLUUID=""; PHASE=""; VOLDEV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --i-understand) OK=1 ;;
    --volume) VOLMP="${2:-}"; shift ;;
    --volume-uuid) VOLUUID="${2:-}"; shift ;;
    preflight|stage|exercise|restore|status) PHASE="$1" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$PHASE" ] || { echo "usage: $0 [--dry-run] [--i-understand] --volume /Volumes/<name> --volume-uuid <UUID> preflight|stage|exercise|restore|status" >&2; exit 2; }
case "$VOLMP" in *[[:space:]]*) echo "REFUSING: the volume's name contains whitespace; this script parses the mount table and needs a name without spaces (rename it in Disk Utility)." >&2; exit 2 ;; esac
[ -n "$VOLUUID" ] || { echo "REFUSING: --volume-uuid is required. Read it from 'diskutil apfs list' next to the volume's NAME." >&2; exit 2; }
case "$PHASE" in
  stage|exercise|restore)
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
    echo "--- image set"; (cd "$dir" && find . -type f ! -name images.plist ! -path './.*' -exec stat -f '%N %z' {} + | sort) 2>&1
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
    case "${f##*/}" in .fseventsd|.Spotlight-V100|.Trashes|.TemporaryItems|.DS_Store) ;; *) entries=$((entries + 1)) ;; esac
  done
  [ "$entries" = 0 ] || refuse "volume is not empty ($entries entries) — E20 needs a dedicated, empty volume"
  used=$(du -sk "$IMAGES" 2>/dev/null | awk '{print $1}')
  need=$(( ${used:-0} + 2 * 1024 * 1024 ))
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
  echo; echo "RESULT: $PHASE INTERRUPTED"; state_report
  { echo "E20 $PHASE interrupted:"; state_report; } >/dev/tty 2>/dev/null
  exit 130
}

# Right after mount_apfs, before the daemon is restarted, nothing on the volume is open: a plain
# umount undoes the mount without touching runtimes or simulators (review N2).
rollback_mount() {
  act "roll back: unmount Images (never forced)" sudo umount "$IMAGES" || { stop "rollback umount refused — Images is still mounted"; return 1; }
  restart_daemon
  act "give the volume back to /Volumes" sudo diskutil mount "$VOLUUID"
  return 0
}

phase_stage() {
  local devnode owner mode before after n
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
    printf 'uuid=%s\ndevnode=%s\nlabel=%s\nvoldev=%s\nstaged=%s\n' "$VOLUUID" "$devnode" "${VOLMP##*/}" "$VOLDEV" "$(date -u +%FT%TZ)" > "$STATE_FILE"
  fi
  runtime_table
  served_from

  # 1. Copy and verify with the runtimes still attached.
  act "keep Spotlight off the volume" sudo mdutil -i off "$VOLSHOW"
  assert_volume || { stop "the volume is no longer the one checked; nothing was copied"; return 1; }
  act "copy the store to the volume (copy, never move)" sudo ditto "$IMAGES/" "$VOLSHOW/" || {
    if assert_volume; then stop "ditto failed; the internal store is untouched, the volume holds a partial copy"
    else stop "the volume went away during the copy — a copy may now be on the INTERNAL disk at $VOLSHOW; inspect and remove it yourself"; fi
    return 1; }
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
  act "mount the volume at Images" sudo mount_apfs -o nobrowse "$devnode" "$IMAGES" || {
    stop "mount_apfs refused; the volume is unmounted (not at /Volumes), Images is the internal store"; restart_daemon; return 1; }

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
  echo "${pfx}!!! not eject the drive, while staged."
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

# Detach, unmount (never forced), snapshot the uncovered store at once, then rescan. Returns 1 and
# leaves Images mounted if anything refuses.
phase_restore_body() {
  local cur n
  if [ "$DRY" = 0 ]; then
    no_xcodebuild || return 1
    nothing_booted || return 1
  fi
  if ! is_mountpoint "$IMAGES"; then
    echo "   $IMAGES is not a mount point — nothing to unmount"
    # A stage that stopped after detaching the runtimes leaves them detached; only then rescan.
    local total
    total=$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
    if [ -n "$total" ] && [ "$(runtime_volume_count)" -ge "$total" ]; then echo "   every runtime is attached — nothing to do"
    else echo "   $(runtime_volume_count) of ${total:-?} runtimes attached — rescanning"; restart_daemon; fi
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
  act "unmount Images (never forced)" sudo umount "$IMAGES" || {
    echo "!! umount refused (busy). Nothing forced. Find the holder with: sudo lsof +D $IMAGES"; return 1; }
  snap post-umount "$IMAGES"
  restart_daemon
  snap post-rescan "$IMAGES"
  return 0
}

phase_restore() {
  local staged_uuid stranded=0
  staged_uuid=$(state_get uuid)
  if [ -f "$STATE_FILE" ]; then echo "## state"; cat "$STATE_FILE"; echo; fi
  if [ -n "$staged_uuid" ] && [ "$staged_uuid" != "$VOLUUID" ]; then
    echo "RESULT: restore REFUSED — the state file says stage used $staged_uuid, not $VOLUUID"; return 1
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
  compare pre-mount post-umount "rule 6 — the internal store at the moment it is uncovered"
  compare post-umount post-rescan "after simdiskimaged rescans (lastUsedAt churn expected)"
  runtime_table
  served_from
  act "give the volume back to /Volumes" sudo diskutil mount "$VOLUUID"
  rm -f "$STATE_FILE"
  if [ "$stranded" = 1 ]; then
    echo "!!! RESULT: restore done, BUT the volume's image set changed while staged (diff above). Something was"
    echo "!!! installed, imported or deleted there and is NOT in the internal store. Do not erase the volume until"
    echo "!!! that is understood."
  else
    echo "RESULT: restore done. The volume holds a copy of the store; erase it yourself when finished."
  fi
}

phase_status() {
  echo "## Images is a mount point: $(is_mountpoint "$IMAGES" && echo yes || echo no)"
  mount | grep " on $IMAGES " || true
  echo "## runtime volumes mounted: $(runtime_volume_count)"
  if [ -f "$STATE_FILE" ]; then echo "## state"; cat "$STATE_FILE"; fi
  echo
  runtime_table
  nothing_booted && echo "## no simulator booted"
}

# A dry run is a rehearsal, not evidence: it goes to a temp file, never into docs/research/evidence.
if [ "$DRY" = 1 ]; then
  OUT=$(mktemp -t xcv-e20-dryrun) || exit 2
else
  OUT="$XCV_EVIDENCE_DIR/e20-$PHASE-$(xcv_env_slug).txt"
  xcv_rotate_out "$OUT" || exit 2
fi
echo "evidence: $OUT"
# The consumers ignore INT/TERM/HUP (ignored dispositions survive exec), so an interrupt reaches
# only the phase, whose trap reports the state left behind into a pipeline that is still there.
{
  xcv_header "E20 images-store mount — phase $PHASE$([ "$DRY" = 1 ] && echo ' (dry run)')"
  echo "# Hypothesis: H20"
  echo
  "phase_$PHASE"
} 2>&1 | (trap '' INT TERM HUP; xcv_redact | tee "$OUT")
exit "${PIPESTATUS[0]}"

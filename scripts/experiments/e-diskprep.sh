#!/bin/bash
# E-diskprep (H17) — which disk-preparation commands does `diskutil` run WITHOUT sudo?
#
# R6 (ADR-0012) lets the app prepare an external drive: add an APFS volume to an existing container,
# add an APFS partition in free space, erase one volume, or erase the whole disk. Before any of those
# is wired into Core, this measures, for each command, whether it runs as the logged-in user with no
# sudo, its exact output, and the resulting `diskutil list -plist`. A command that needs root is NOT
# run by the app; it becomes a copyable command (ADR-0012).
#
# SCRATCH-ONLY. Every target is a disk image this script just created and attached:
#   - images live under /private/tmp/xcv-dp* only (refused otherwise);
#   - the device node is the one `hdiutil attach` printed, never a name or a guess;
#   - before EVERY mutating command, `xcv_dp_guard` re-reads `diskutil info -plist` for the target and
#     refuses unless it is, or lives on, that whole disk AND that whole disk reports
#     BusProtocol = "Disk Image" and VirtualOrPhysical = "Virtual". A synthesized APFS container is
#     checked through its physical store. Anything else aborts the run.
# A trap detaches and deletes every image on every exit path, including failure and Ctrl-C.
#
# The limit of this evidence, stated up front: a disk image is not a USB drive. diskutil authorizes
# a mutation by the console user's ownership of the media; images attached by the user are owned by
# the user. Whether the same commands run unprivileged on a physical external disk is NOT shown here
# and is recorded as pending in COMPATIBILITY_MATRIX.md.
set -u
source "$(dirname "$0")/common.sh"

IMG_A=${XCV_DP_IMAGE_A:-/private/tmp/xcv-dp-a}
IMG_B=${XCV_DP_IMAGE_B:-/private/tmp/xcv-dp-b}
# Canonical paths only: no `..`, and the directory resolved (realpath) must itself be /private/tmp, so a symlink or a
# relative component cannot point the images — and so the guard's image-path check — anywhere else.
for v in "$IMG_A" "$IMG_B"; do
  case "$v" in *..*) echo "refusing: '$v' contains '..'" >&2; exit 1;; esac
  case "$v" in /private/tmp/xcv-dp*) ;; *) echo "refusing: '$v' is outside /private/tmp/xcv-dp*" >&2; exit 1;; esac
  [ "$(cd "$(dirname "$v")" 2>/dev/null && pwd -P)" = "/private/tmp" ] || { echo "refusing: '$v' does not resolve under /private/tmp" >&2; exit 1; }
done
out="$XCV_EVIDENCE_DIR/e-diskprep-$(xcv_env_slug).txt"
xcv_rotate_out "$out" || exit 1

# Whole-disk nodes this script attached. Only these may ever be named in a mutating command.
DISK_A=""
DISK_B=""
BACKING_A=""
BACKING_B=""

# plist key of a `diskutil info -plist <id>`; empty when absent.
dp_key() { diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }

# The image file `hdiutil info` says backs /dev/<whole>, or nothing. Recorded at attach and checked by the guard: a device
# id that was detached and reused by another disk no longer maps to OUR image file.
dp_backing_image() {
  hdiutil info -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin); w='/dev/'+sys.argv[1]
for i in d.get('images',[]):
  if any(e.get('dev-entry')==w for e in i.get('system-entities',[])): print(i.get('image-path','')); break" "$1" 2>/dev/null
}

# Is <whole> one of OUR attached images, still backed by the image file recorded at attach, and does diskutil call it a
# disk image right now?
dp_is_our_image() {
  local whole="$1" expected=""
  case "$whole" in disk[0-9]*) ;; *) return 1 ;; esac
  if [ "$whole" = "$DISK_A" ]; then expected="$BACKING_A"; elif [ "$whole" = "$DISK_B" ]; then expected="$BACKING_B"; else return 1; fi
  [ -n "$expected" ] && [ "$(dp_backing_image "$whole")" = "$expected" ] || return 1
  [ "$(dp_key "$whole" BusProtocol)" = "Disk Image" ] || return 1
  [ "$(dp_key "$whole" VirtualOrPhysical)" = "Virtual" ] || return 1
  [ "$(dp_key "$whole" Internal)" = "false" ] || return 1
  return 0
}

# xcv_dp_guard <id> — abort the whole run unless <id> is one of our images or lives on one.
xcv_dp_guard() {
  local id="${1#/dev/}" parent store storeparent
  case "$id" in disk[0-9]*) ;; *) echo "GUARD ABORT: '$1' is not a disk identifier" >&2; exit 2 ;; esac
  parent=$(dp_key "$id" ParentWholeDisk)
  if dp_is_our_image "$parent"; then echo "[guard ok: $id on image $parent]"; return 0; fi
  # A synthesized APFS container (or a volume in one): follow its physical store to the real disk.
  store=$(dp_key "$id" APFSPhysicalStores.0.APFSPhysicalStore)
  [ -n "$store" ] || store=$(diskutil apfs list -plist 2>/dev/null \
      | plutil -convert json -o - - 2>/dev/null \
      | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin); t=sys.argv[1]
for c in d.get('Containers',[]):
  ids=[c.get('ContainerReference')]+[v.get('DeviceIdentifier') for v in c.get('Volumes',[])]
  if t in ids: print(c.get('DesignatedPhysicalStore','')); break" "$id" 2>/dev/null)
  if [ -n "$store" ]; then
    storeparent=$(dp_key "$store" ParentWholeDisk)
    if dp_is_our_image "$storeparent"; then echo "[guard ok: $id via store $store on image $storeparent]"; return 0; fi
  fi
  echo "GUARD ABORT: '$id' (parent '$parent', store '${store:-none}') is not on an image this script attached" >&2
  exit 2
}

# dp_mutate <label> <VARIABLE NAME> diskutil … @TARGET@ …
# The device is never written in the call: the caller names the variable that holds it, the guard checks that value, and
# THIS function substitutes it for the one `@TARGET@` placeholder. So the argument diskutil receives is, by
# construction, the value the guard accepted. A call without exactly one placeholder is refused.
dp_mutate() {
  local label="$1" var="$2" target arg n=0; shift 2
  case "$var" in [A-Z_]*) ;; *) echo "GUARD ABORT: dp_mutate wants a variable name, got '$var'" >&2; exit 2 ;; esac
  target="${!var}"
  xcv_dp_guard "$target"
  local -a argv=()
  for arg in "$@"; do
    if [ "$arg" = "@TARGET@" ]; then argv+=("$target"); n=$((n + 1)); else argv+=("$arg"); fi
  done
  [ "$n" = 1 ] || { echo "GUARD ABORT: '$label' must name its device exactly once, as @TARGET@" >&2; exit 2; }
  xcv_run "$label (no sudo)" "${argv[@]}"
  echo "RESULT: $label => exit $XCV_LAST_EXIT ($([ "$XCV_LAST_EXIT" = 0 ] && echo works-without-sudo || echo FAILED-without-sudo))"
  echo
}

dp_map() {
  local whole="$1"
  xcv_run "diskutil list -plist $whole" diskutil list -plist "$whole"
}

# Attach an image with -nomount, capture the whole-disk node it printed. Never a guess.
dp_attach() {
  local img="$1" line
  line=$(hdiutil attach -nomount -nobrowse "$img" 2>&1 | awk '/^\/dev\/disk[0-9]+[[:space:]]/{print $1; exit}')
  printf '%s' "${line#/dev/}"
}

cleanup() {
  local d
  for d in "$DISK_A" "$DISK_B"; do
    # Detach only what we attached, and only while it is still OUR image (the same check as the guard: the image file
    # recorded at attach still backs it, and diskutil calls it a disk image). Fix round 2, N3.
    [ -n "$d" ] && dp_is_our_image "$d" && hdiutil detach "/dev/$d" -force -quiet 2>/dev/null
  done
  rm -f "$IMG_A".sparseimage "$IMG_B".sparseimage
}
FINISHED=0
on_exit() {
  [ "$FINISHED" = "1" ] && return 0
  FINISHED=1
  cleanup
  if [ -f "$out.raw" ]; then
    if xcv_redact < "$out.raw" > "$out"; then
      rm -f "$out.raw"
    else
      mv -f "$out.raw" "${TMPDIR:-/tmp}/$(basename "$out").raw" 2>/dev/null || rm -f "$out.raw"
      echo "REDACTION FAILED: raw transcript moved out of $(dirname "$out"); do not publish it." >&2
    fi
  fi
}
progress() { echo "$*" >&3 2>/dev/null; }

dp_main() {
  xcv_header "E-diskprep (H17) — disk preparation commands without sudo, on scratch images"
  echo "# Script: scripts/experiments/e-diskprep.sh @ $(git -C "$XCV_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "# sudo: deliberately never used; every command below runs as $(id -un)"
  echo
  rm -f "$IMG_A".sparseimage "$IMG_B".sparseimage

  # ---------- Image A: GPT + one APFS container (the PABLO shape) ----------
  progress "== image A: GPT + APFS"
  xcv_run "create image A (GPT, APFS, sparse)" hdiutil create -size 2g -layout GPTSPUD -fs APFS -volname XCVDPA -type SPARSE "$IMG_A"
  DISK_A=$(dp_attach "$IMG_A.sparseimage")
  BACKING_A=$(dp_backing_image "$DISK_A")
  echo "## image A backed by: ${BACKING_A:-<none>}"
  [ "$BACKING_A" = "$IMG_A.sparseimage" ] || { echo "ABORT: $DISK_A is not backed by $IMG_A.sparseimage" >&2; exit 2; }
  echo "## image A attached as: ${DISK_A:-<none>}"
  [ -n "$DISK_A" ] || { echo "ABORT: attach of image A printed no device" >&2; exit 1; }
  xcv_run "image A identity" sh -c "diskutil info -plist $DISK_A | plutil -p - | grep -E 'BusProtocol|VirtualOrPhysical|Internal\"|DeviceNode|MediaName|DiskUUID|\"Size\"'"
  dp_is_our_image "$DISK_A" || { echo "ABORT: $DISK_A does not report as a disk image" >&2; exit 2; }
  dp_map "$DISK_A"
  CONT_A=$(diskutil apfs list -plist | plutil -convert json -o - - | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin)
for c in d.get('Containers',[]):
  if c.get('DesignatedPhysicalStore','').startswith(sys.argv[1]+'s'): print(c['ContainerReference']); break" "$DISK_A")
  echo "## image A container: ${CONT_A:-<none>}"
  [ -n "$CONT_A" ] || { echo "ABORT: no APFS container found on $DISK_A" >&2; exit 1; }

  dp_mutate "apfs addVolume, case-insensitive" CONT_A diskutil apfs addVolume @TARGET@ APFS XCVDP1 -nomount
  dp_mutate "apfs addVolume, case-sensitive" CONT_A diskutil apfs addVolume @TARGET@ "Case-sensitive APFS" XCVDP2 -nomount
  dp_mutate "apfs addVolume with -quota 200m" CONT_A diskutil apfs addVolume @TARGET@ APFS XCVDP3 -quota 200m -nomount
  dp_mutate "apfs addVolume with -reserve 100m" CONT_A diskutil apfs addVolume @TARGET@ APFS XCVDP4 -reserve 100m -nomount
  dp_map "$DISK_A"
  xcv_run "apfs list (container A)" sh -c "diskutil apfs list $CONT_A"
  VOL_A1=$(diskutil apfs list -plist | plutil -convert json -o - - | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin)
for c in d.get('Containers',[]):
  if c.get('ContainerReference')==sys.argv[1]:
    for v in c.get('Volumes',[]):
      if v.get('Name')=='XCVDP2': print(v['DeviceIdentifier'])" "$CONT_A")
  echo "## volume to erase (XCVDP2): ${VOL_A1:-<none>}"
  if [ -n "$VOL_A1" ]; then
    dp_mutate "eraseVolume APFS on an APFS volume (case-sensitive -> case-insensitive)" VOL_A1 diskutil eraseVolume APFS XCVDPE @TARGET@
    xcv_run "personality after eraseVolume" sh -c "diskutil info $VOL_A1 | grep -E 'Volume Name|Personality|Mount Point'"
  fi
  dp_map "$DISK_A"
  dp_mutate "eraseDisk APFS GPT on the whole disk" DISK_A diskutil eraseDisk APFS XCVDPD GPT @TARGET@
  dp_map "$DISK_A"

  # ---------- Image B: raw disk -> exFAT partition + free space (the NTFS/exFAT stick shape) ----------
  progress "== image B: exFAT + free space"
  xcv_run "create image B (no partition map, sparse)" hdiutil create -size 2g -layout NONE -type SPARSE "$IMG_B"
  DISK_B=$(dp_attach "$IMG_B.sparseimage")
  BACKING_B=$(dp_backing_image "$DISK_B")
  [ "$BACKING_B" = "$IMG_B.sparseimage" ] || { echo "ABORT: $DISK_B is not backed by $IMG_B.sparseimage" >&2; exit 2; }
  echo "## image B attached as: ${DISK_B:-<none>}"
  [ -n "$DISK_B" ] || { echo "ABORT: attach of image B printed no device" >&2; exit 1; }
  dp_is_our_image "$DISK_B" || { echo "ABORT: $DISK_B does not report as a disk image" >&2; exit 2; }
  dp_mutate "partitionDisk GPT: 800M exFAT + free space (setup)" DISK_B \
    diskutil partitionDisk @TARGET@ GPT ExFAT XCVDPX 800M "Free Space" gap R
  dp_map "$DISK_B"
  PART_X=$(diskutil list -plist "$DISK_B" | plutil -convert json -o - - | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin)
for p in d.get('AllDisksAndPartitions',[{}])[0].get('Partitions',[]):
  if p.get('VolumeName')=='XCVDPX': print(p['DeviceIdentifier'])")
  echo "## exFAT partition: ${PART_X:-<none>}"
  if [ -n "$PART_X" ]; then
    dp_mutate "addPartition APFS into the free space after the exFAT partition" PART_X \
      diskutil addPartition @TARGET@ APFS XCVDPN 0
    dp_map "$DISK_B"
    xcv_run "apfs list after addPartition" sh -c "diskutil apfs list -plist | plutil -p - | grep -E 'ContainerReference|DesignatedPhysicalStore|\"Name\"'"
    dp_mutate "eraseVolume APFS on the exFAT partition (others stay)" PART_X diskutil eraseVolume APFS XCVDPV @TARGET@
    dp_map "$DISK_B"
  fi

  progress "== teardown"
  echo "## teardown"
  cleanup
  xcv_run "images gone" sh -c "ls -l $IMG_A.sparseimage $IMG_B.sparseimage 2>&1; true"
  echo "## summary"
  grep -h '^RESULT:' "$out.raw" 2>/dev/null || true
}

exec 3>&2
# EXIT cleans up; a signal cleans up and then EXITS — without the exit, the body would carry on after Ctrl-C with the
# images already detached.
trap 'on_exit' EXIT
trap 'on_exit; exit 130' INT
trap 'on_exit; exit 143' TERM
trap 'on_exit; exit 129' HUP
dp_main > "$out.raw" 2>&1
RC=$?
on_exit
[ -f "$out" ] && grep -E '^(RESULT:|GUARD|ABORT)' "$out"
echo "wrote $out"
exit "$RC"

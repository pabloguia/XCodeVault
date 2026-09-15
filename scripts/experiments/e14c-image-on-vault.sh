#!/bin/bash
# E14c — what does the restriction actually key on? (narrows H6)
#
#   E14b: `simctl create` fails on the USB vault and succeeds in an alternate device set on the
#   internal disk, with tccd queried for kTCCServiceSystemPolicyRemovableVolumes and the kernel
#   denying file-write-create.  Those two volumes differed in several properties at once, so the
#   result narrowed to "volume class"; only the log pointed at removability, and a log line is
#   not a controlled variable.
#
#   This narrows it with E2's own trick — an APFS disk image — whose xctest failure vanished
#   inside images even when the image FILE sat on the USB SSD.
#
# MEASURED 2026-09-15, BEFORE THE FIRST RUN. Two drafts died here, which is the only reason the
# third is worth running:
#
#     property                  vault (/Volumes/<vault>)     attached sparse image
#     File System Personality   Case-sensitive APFS        Case-sensitive APFS
#     Device Location           External                   External
#     Removable Media           Fixed                      Removable
#     Protocol                  USB                        Disk Image
#     mount options             nodev,nosuid               nodev,nosuid (+nobrowse)
#
#   Draft one assumed the image would come back Internal/Fixed, and would have voided every run
#   on this hardware.  Draft two assumed the two volumes agreed on Removable Media — they do not,
#   and the image is the one macOS calls *Removable*.  So this script assumes none of it: phase 3
#   reads both volumes at run time, computes which properties were held equal and which varied,
#   and phrases its verdict from that set.  If the machine disagrees with the table above, the
#   verdict follows the machine.
#
#   Held equal by construction in arm A rather than by measurement: the bytes live on the vault's
#   physical device, and the set path is under /Volumes.
#
# TWO ARMS, cheapest and most disqualifying first.
#   Arm B (image on the INTERNAL disk) is the control for the control.  If `create` fails inside
#   a disk image there, images do not host device sets at all, arm A is uninterpretable, and the
#   run stops and says so.  Without arm B a null result in arm A has two readings and no way to
#   choose between them.
#   Arm A (image file stored on the vault) is the question.
#
# THIS SCRIPT MUTATES STATE.  Read it first.  It:
#   - creates two sparse images, one under $TMPDIR and one under the vault directory you pass,
#     both named with this run's pid, and refuses to start if either name already exists;
#   - attaches them -nobrowse -owners on, detaches them BY MOUNT POINT in cleanup and on
#     INT/TERM/HUP/EXIT, and refuses to delete an image file while hdiutil still lists it;
#   - carries --set on every simctl invocation, so the DEFAULT device set is never addressed;
#   - re-checks the vault's volume UUID before touching anything on the vault during cleanup;
#   - never touches ~/Library/Developer, never uses sudo.
#
# Usage:
#   scripts/experiments/e14c-image-on-vault.sh /Volumes/<vault>/XCodeVault --i-understand
#
#   The argument is a DIRECTORY ON THE VAULT to hold the image file, not a device set path.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VAULT_DIR="${1:-}"
[ "${2:-}" = "--i-understand" ] || { echo "usage: $0 <directory-on-the-vault> --i-understand" >&2; exit 2; }
[ -n "$VAULT_DIR" ] || { echo "usage: $0 <directory-on-the-vault> --i-understand" >&2; exit 2; }

# Same validation discipline as e14b-device-set-external.sh, and for the same reason: a textual
# refusal is not sound against `..` or a symlink. Canonicalise, then judge the resolved path.
VAULT_DIR_IN="$VAULT_DIR"   # keep the argument as given: the failure message needs it
VAULT_DIR=$(cd "$VAULT_DIR" 2>/dev/null && pwd -P) || {
  echo "REFUSING: $VAULT_DIR_IN does not exist or is not reachable." >&2; exit 2; }
case "$VAULT_DIR" in
  "$HOME"/Library/Developer/*|/Library/Developer/*|"$HOME"/Library/Developer|/Library/Developer)
    echo "REFUSING: $VAULT_DIR is inside a developer-data directory." >&2; exit 2;;
  /Volumes/?*/?*) ;;
  *) echo "REFUSING: $VAULT_DIR is not a path under /Volumes/<volume>/." >&2; exit 2;;
esac
case "$VAULT_DIR" in *\'*) echo "REFUSING: quote in the vault path." >&2; exit 2;; esac
[ -w "$VAULT_DIR" ] || { echo "REFUSING: $VAULT_DIR is not writable." >&2; exit 2; }

VOLUME="/Volumes/$(echo "${VAULT_DIR#/Volumes/}" | cut -d/ -f1)"
if [ "$(stat -f %Sd "$VAULT_DIR" 2>/dev/null)" != "$(stat -f %Sd "$VOLUME" 2>/dev/null)" ]; then
  echo "REFUSING: $VAULT_DIR does not reside on the device backing $VOLUME." >&2; exit 2
fi
VOLUME_UUID=$(diskutil info -plist "$VOLUME" 2>/dev/null | plutil -extract VolumeUUID raw - 2>/dev/null)
[ -n "$VOLUME_UUID" ] || { echo "REFUSING: could not read a volume UUID for $VOLUME." >&2; exit 2; }

VAULT_LOCATION=$(diskutil info "$VOLUME" 2>/dev/null | awk -F': *' '/Device Location/{print $2; exit}' | xargs)
if [ "$VAULT_LOCATION" != "External" ]; then
  echo "REFUSING: $VOLUME reports Device Location '$VAULT_LOCATION', not External." >&2
  echo "  E14c compares that volume against a disk image; with a non-external vault there is" >&2
  echo "  nothing here to narrow." >&2
  exit 2
fi

OUT="$XCV_EVIDENCE_DIR/e14c-image-on-vault-$(xcv_env_slug).txt"
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"
DEVTYPE="${XCV_DEVTYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation}"
RUNTIME="${XCV_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
IMAGE_MB=2048

INT_IMG="${TMPDIR:-/tmp}/xcv-e14c-int-$$.sparseimage"
VAULT_IMG="$VAULT_DIR/xcv-e14c-vault-$$.sparseimage"

# pids recycle. If a crashed earlier run left an image at one of these names, `hdiutil create`
# would fail, `attach` would attach the STALE file, and cleanup would then delete an image this
# run did not make — exactly what the pid in the name is supposed to prevent.
for img in "$INT_IMG" "$VAULT_IMG"; do
  [ -e "$img" ] && { echo "REFUSING: $img already exists (stale run?). Inspect and remove it." >&2; exit 2; }
done

# Space. A disk-full failure in arm B would otherwise be recorded as "disk images cannot host
# device sets", which is the one conclusion arm B is there to make: check first.
for fs in "$VOLUME" /System/Volumes/Data; do
  avail_mb=$(df -m "$fs" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 3072 ]; then
    echo "REFUSING: only ${avail_mb} MB free on $fs; need ~3 GB so a disk-full failure is not" >&2
    echo "  mistaken for a finding about disk images." >&2
    exit 2
  fi
done

# The body runs inside a pipeline, hence a subshell: anything assigned there is invisible to a
# trap out here. One small file per fact.
STATE=$(mktemp -d -t xcv-e14c-state) || exit 2
CLEANED_MARK="${STATE}.cleaned"
xcv_rotate_out "$OUT" || exit 2

# --- helpers -----------------------------------------------------------------------------------

da_field() {
  local v
  v=$(diskutil info "$1" 2>/dev/null | awk -F': *' -v k="$2" '$0 ~ k {print $2; exit}' | xargs)
  # Never return empty: two unreadable values would compare equal and be printed as a held-equal
  # property, which would be a false claim in the evidence file.
  if [ -n "$v" ]; then echo "$v"; else echo "<unreadable>"; fi
}

# Mount options with the artifacts of how THIS SCRIPT attached stripped, so the comparison is
# about the volume rather than about our own flags.
mount_opts() {
  mount | grep -F " $1 (" | sed 's/.*(\(.*\))/\1/' \
    | sed -e 's/, *nobrowse//' -e 's/, *mounted by [^,)]*//' -e 's/^ *//'
}

image_still_attached() { hdiutil info 2>/dev/null | grep -qF "image-path      : $1"; }

# attach_image <imagefile> <tag> — records image, devnode and mountpoint into $STATE/<tag>.*
# The image path is written FIRST: if we are interrupted mid-attach, cleanup must still know
# there may be something attached for this file.
attach_image() {
  local img="$1" tag="$2" out rc dev mnt
  printf '%s' "$img" > "$STATE/$tag.img"
  echo "## [$tag] attach"
  echo "\$ hdiutil attach $img -nobrowse -owners on"
  out=$(hdiutil attach "$img" -nobrowse -owners on 2>&1); rc=$?
  echo "$out"
  echo "[exit=$rc]"
  dev=$(echo "$out" | awk '/\/Volumes\//{print $1; exit}')
  mnt=$(echo "$out" | sed -n 's#.*\(/Volumes/[^[:cntrl:]]*\)$#\1#p' | head -1)
  # Do not trust the text parse: the mount point must exist and must actually be a mount.
  if [ -n "$mnt" ] && [ -d "$mnt" ] && mount | grep -qF " $mnt ("; then
    printf '%s' "$mnt" > "$STATE/$tag.mnt"
    [ -n "$dev" ] && printf '%s' "$dev" > "$STATE/$tag.dev"
    echo "# [$tag] mounted at $mnt (device ${dev:-<unparsed>})"
    return 0
  fi
  echo "!! [$tag] could not determine a usable mount point from the attach output."
  return 1
}

create_in_set() {
  local set_path="$1" name="$2"
  xcrun simctl --set "$set_path" create "$name" "$DEVTYPE" "$RUNTIME" >/dev/null 2>&1
  xcrun simctl --set "$set_path" list devices -j 2>/dev/null | python3 -c \
"import json,sys
try:
    d = json.load(sys.stdin)['devices']
except Exception:
    print(''); raise SystemExit
print(next((x['udid'] for v in d.values() for x in v if x['name']=='$name'), ''))"
}

set_device_count() {
  xcrun simctl --set "$1" list devices -j 2>/dev/null | python3 -c \
'import json,sys
try:
    d = json.load(sys.stdin)["devices"]
except Exception:
    print("?"); raise SystemExit
print(sum(len(v) for v in d.values()))' 2>/dev/null
}

drop_probe() {
  local tag="$1" mnt udid set_path remaining
  [ -f "$STATE/$tag.mnt" ] || return 0
  mnt=$(cat "$STATE/$tag.mnt"); set_path="$mnt/E14cSet"
  udid=$(cat "$STATE/$tag.udid" 2>/dev/null || true)
  if [ -n "$udid" ]; then
    xcrun simctl --set "$set_path" shutdown "$udid" >/dev/null 2>&1
    echo "## [$tag] shutdown -> exit $?"
    xcrun simctl --set "$set_path" delete "$udid" >/dev/null 2>&1
    echo "## [$tag] delete   -> exit $?"
  fi
  remaining=$(set_device_count "$set_path")
  echo "## [$tag] set reports ${remaining:-<unreadable>} remaining device(s)"
  [ "$remaining" = "0" ] || echo "## [$tag] NOT clean — xcrun simctl --set '$set_path' list devices"
}

cleanup() {
  # The marker lives BESIDE $STATE, not inside it: cleanup removes $STATE at the end, so a
  # marker within it could neither be found nor recreated on a second call. Both E14c runs
  # recorded `.cleaned: No such file or directory` and ran their cleanup body twice because of
  # this. Harmless there, but an idempotence guard that cannot hold is not a guard.
  [ -f "$CLEANED_MARK" ] && return 0
  : > "$CLEANED_MARK"
  echo "## cleanup"
  local tag img mnt now
  for tag in int vault; do
    drop_probe "$tag"
    [ -f "$STATE/$tag.img" ] || continue
    img=$(cat "$STATE/$tag.img"); mnt=""
    if [ -f "$STATE/$tag.mnt" ]; then
      mnt=$(cat "$STATE/$tag.mnt")
      # Detach the MOUNT POINT, not the synthesized APFS volume node: hdiutil can refuse to
      # detach a device that is not the one it attached.
      xcv_run "[$tag] detach $mnt" hdiutil detach "$mnt"
      if image_still_attached "$img"; then
        xcv_run "[$tag] detach again, forced" hdiutil detach "$mnt" -force
      fi
    fi
    # Refuse to remove the backing file of anything hdiutil still lists — and note this guard
    # does NOT depend on the devnode parse having succeeded, because an attached image whose
    # file is gone is a worse state to leave behind than a leftover file.
    if image_still_attached "$img"; then
      echo "!! [$tag] $img is STILL ATTACHED. Not removing it. By hand:"
      echo "     hdiutil detach '${mnt:-<find it in: hdiutil info>}' -force"
      continue
    fi
    if [ "$tag" = "vault" ]; then
      # rule 6: never act on a vault path without re-establishing that it is still the vault.
      now=$(diskutil info -plist "$VOLUME" 2>/dev/null | plutil -extract VolumeUUID raw - 2>/dev/null)
      if [ "$now" != "$VOLUME_UUID" ]; then
        echo "!! $VOLUME is no longer the volume this run started on (expected $VOLUME_UUID,"
        echo "   found ${now:-<nothing mounted there>}). Leaving $img alone."
        continue
      fi
    fi
    [ -f "$img" ] && xcv_run "[$tag] remove image" rm -f "$img"
  done
  xcv_run "post-cleanup: anything attached naming e14c?" \
    bash -c "hdiutil info 2>/dev/null | grep -i e14c || echo '(nothing)'"
  xcv_run "post-cleanup: e14c images left on the vault?" \
    bash -c "ls -la '$VAULT_DIR'/xcv-e14c-*.sparseimage 2>&1 | head -5"
  rm -rf "$STATE"
}
trap 'cleanup 2>&1 | xcv_redact >> "$OUT"' INT TERM HUP

# --- body --------------------------------------------------------------------------------------

VERDICT_RC=0
{
  # The parent's trap does not survive into this subshell. Without this, a `set -u` exit or any
  # early exit inside the block would leak an attached image.
  trap cleanup EXIT

  xcv_header "E14c — APFS disk image vs the external volume itself (narrows H6)"
  echo "# Vault directory for the image file: $VAULT_DIR"
  echo "# Vault volume: $VOLUME (UUID $VOLUME_UUID, Device Location $VAULT_LOCATION)"
  echo "# Device type: $DEVTYPE"
  echo "# Runtime:     $RUNTIME"
  echo

  echo "## phase 0 — preflight and baselines"
  xcv_run "vault volume properties" bash -c \
    "diskutil info '$VOLUME' | grep -E 'Volume Name|File System Personality|Device Location|Removable Media|Protocol|Owners|Volume UUID'"
  xcv_run "vault mount options" bash -c "mount | grep -F ' $VOLUME ('"
  xcv_run "free space" df -h "$VOLUME" /System/Volumes/Data
  xcv_run "BASELINE default device set (must be unchanged at the end)" \
    bash -c "xcrun simctl list devices"
  xcv_run "BASELINE default set size" du -shx "$DEFAULT_SET"

  # ---- Arm B: the control for the control -----------------------------------------------------
  echo "## phase 1 — ARM B: case-sensitive image on the INTERNAL disk"
  echo "# If create fails here, disk images do not host device sets at all and arm A cannot be"
  echo "# read either way. This phase exists so that outcome is visible instead of inferred."
  xcv_run "create internal image" hdiutil create -size "${IMAGE_MB}m" -fs "Case-sensitive APFS" \
    -volname XCV-E14c-INT -type SPARSE "$INT_IMG"
  if [ ! -f "$INT_IMG" ]; then
    echo "!! phase 1 FAILED — hdiutil create produced no internal image. Experiment void, and"
    echo "   this says nothing about whether disk images host device sets."
    VERDICT_RC=1; exit 1
  fi
  if ! attach_image "$INT_IMG" int; then
    echo "!! phase 1 FAILED — could not attach the internal image. Experiment void."
    VERDICT_RC=1; exit 1
  fi
  INT_MNT=$(cat "$STATE/int.mnt")
  xcv_run "[int] volume properties" bash -c \
    "diskutil info '$INT_MNT' | grep -E 'File System Personality|Device Location|Removable Media|Protocol|Owners'"
  xcv_run "[int] mount options" bash -c "mount | grep -F ' $INT_MNT ('"
  if ! mkdir "$INT_MNT/E14cSet"; then
    echo "!! phase 1 FAILED — could not create the set directory inside the internal image."
    VERDICT_RC=1; exit 1
  fi
  echo "## [int] create"
  echo "\$ xcrun simctl --set $INT_MNT/E14cSet create XCV-E14c-int $DEVTYPE $RUNTIME"
  INT_UDID=$(create_in_set "$INT_MNT/E14cSet" XCV-E14c-int)
  printf '%s' "$INT_UDID" > "$STATE/int.udid"
  echo "# [int] probe UDID: ${INT_UDID:-<none>}"
  if [ -z "$INT_UDID" ]; then
    echo "!! ARM B FAILED — create does not work inside a disk image even on the internal disk."
    echo "   Disk images therefore do not host device sets, arm A would be uninterpretable, and"
    echo "   E14c is VOID as a way to narrow H6. That is a real result about the METHOD and should"
    echo "   be recorded as one — it says nothing about external storage."
    echo "   (Free space was checked before starting, so this is not a disk-full failure.)"
    xcv_run "[int] CoreSimulator.log" bash -c \
      "grep -a -E 'XCV-E14c|stuck in creation' ~/Library/Logs/CoreSimulator/CoreSimulator.log | tail -20"
    VERDICT_RC=1; exit 1
  fi
  xcv_run "[int] the data container the vault refused" bash -c "du -sh '$INT_MNT/E14cSet/$INT_UDID/data' 2>&1"

  # ---- Arm A: the question --------------------------------------------------------------------
  echo "## phase 2 — ARM A: case-sensitive image whose FILE lives on the vault"
  xcv_run "create vault image" hdiutil create -size "${IMAGE_MB}m" -fs "Case-sensitive APFS" \
    -volname XCV-E14c-VAULT -type SPARSE "$VAULT_IMG"
  if [ ! -f "$VAULT_IMG" ]; then
    echo "!! phase 2 FAILED — hdiutil create produced no image on the vault."
    echo "   That is itself a finding about writing to external storage; capture it."
    VERDICT_RC=1; exit 1
  fi
  xcv_run "the image file is on the external device" bash -c \
    "df -h '$VAULT_IMG' | tail -1; stat -f 'backing device: %Sd' '$VAULT_IMG'"
  if ! attach_image "$VAULT_IMG" vault; then
    echo "!! phase 2 FAILED — could not attach the image stored on the vault."
    echo "   Also a finding about external storage rather than a harness problem; capture it."
    VERDICT_RC=1; exit 1
  fi
  VAULT_MNT=$(cat "$STATE/vault.mnt")
  xcv_run "[vault] volume properties" bash -c \
    "diskutil info '$VAULT_MNT' | grep -E 'File System Personality|Device Location|Removable Media|Protocol|Owners'"
  xcv_run "[vault] mount options" bash -c "mount | grep -F ' $VAULT_MNT ('"
  if ! mkdir "$VAULT_MNT/E14cSet"; then
    echo "!! phase 2 FAILED — could not create the set directory inside the vault image."
    VERDICT_RC=1; exit 1
  fi
  echo "## [vault] create"
  echo "\$ xcrun simctl --set $VAULT_MNT/E14cSet create XCV-E14c-vault $DEVTYPE $RUNTIME"
  VAULT_UDID=$(create_in_set "$VAULT_MNT/E14cSet" XCV-E14c-vault)
  printf '%s' "$VAULT_UDID" > "$STATE/vault.udid"
  echo "# [vault] probe UDID: ${VAULT_UDID:-<none>}"
  if [ -n "$VAULT_UDID" ]; then
    xcv_run "[vault] the data container" bash -c "du -sh '$VAULT_MNT/E14cSet/$VAULT_UDID/data' 2>&1"
  else
    xcv_run "[vault] CoreSimulator.log" bash -c \
      "grep -a -E 'XCV-E14c|stuck in creation' ~/Library/Logs/CoreSimulator/CoreSimulator.log | tail -20"
    xcv_run "[vault] unified log: TCC / Sandbox / the set path" bash -c \
      "log show --last 10m --predicate 'subsystem == \"com.apple.TCC\" OR senderImagePath CONTAINS \"Sandbox\" OR eventMessage CONTAINS \"E14cSet\"' --style compact 2>/dev/null | tail -60"
  fi

  # ---- Phase 3: verdict, computed -------------------------------------------------------------
  echo "## phase 3 — verdict, computed from what the two volumes report in THIS run"
  SAME=""; DIFF=""; LOC_OK=yes; FS_OK=yes
  echo "# property                vault                      image-on-vault"
  for k in "File System Personality" "Device Location" "Removable Media" "Protocol"; do
    a=$(da_field "$VOLUME" "$k"); b=$(da_field "$VAULT_MNT" "$k")
    printf '# %-23s %-26s %s\n' "$k" "$a" "$b"
    if [ "$a" = "$b" ]; then SAME="$SAME  $k=$a"; else DIFF="$DIFF  $k($a->$b)"; fi
    if [ "$k" = "Device Location" ] && [ "$a" != "$b" ]; then LOC_OK=no; fi
    if [ "$k" = "File System Personality" ] && [ "$a" != "$b" ]; then FS_OK=no; fi
  done
  V_OPTS=$(mount_opts "$VOLUME"); I_OPTS=$(mount_opts "$VAULT_MNT")
  printf '# %-23s %-26s %s\n' "mount options" "$V_OPTS" "$I_OPTS"
  if [ "$V_OPTS" = "$I_OPTS" ]; then SAME="$SAME  mount-options=$V_OPTS"; else DIFF="$DIFF  mount-options($V_OPTS -> $I_OPTS)"; fi
  echo "# (mount options compared with this script's own -nobrowse and 'mounted by' stripped)"
  echo "# HELD EQUAL:${SAME:-  (none)}"
  echo "# VARIED:${DIFF:-  (none)}"
  echo "# Held equal by construction, not measured: the bytes live on $VOLUME's device, and the"
  echo "# set path is under /Volumes."
  echo

  RM_VAULT=$(da_field "$VOLUME" "Removable Media"); RM_IMG=$(da_field "$VAULT_MNT" "Removable Media")

  if [ "$LOC_OK" = no ] || [ "$FS_OK" = no ]; then
    # This gate CAN fire: it does not test Protocol, which differs by construction of the arm.
    echo "VOID — the image did not match the vault on a property this comparison depends on:"
    echo "Device Location and/or File System Personality differ (see the table). The two arms are"
    echo "not the controlled pair the experiment needs, so the create result licenses nothing."
    echo "Rebuild the image to match and re-run."
    VERDICT_RC=1
  elif [ -n "$VAULT_UDID" ]; then
    echo "CREATED inside the image, while the identical create fails on the vault volume itself"
    echo "(E14b). The discriminator is therefore among the VARIED properties above and not among"
    echo "the HELD EQUAL ones — read those two lines, not this sentence."
    if [ "$RM_VAULT" != "$RM_IMG" ]; then
      echo
      echo "Removable Media varied ($RM_VAULT -> $RM_IMG), so it is in the candidate set. But the"
      echo "DIRECTION excludes it rather than implicating it: the volume macOS calls '$RM_IMG' is"
      echo "the one that WORKS, and the one it calls '$RM_VAULT' is the one that FAILS. A policy"
      echo "keyed on that field would have to be inverted to produce this, so the field whose name"
      echo "TCC's service evokes is not what the restriction reads."
    fi
    echo
    echo "What survives in the candidate set is Protocol: a real device versus a virtual one."
    echo "That also matches E2, whose failure vanished inside images stored on this same SSD."
    echo "NOT varied by either arm, and still what H6 needs to finish: bus. A Thunderbolt"
    echo "enclosure would separate 'physically removable' from 'USB'. Nothing here has done that,"
    echo "so this NARROWS H6 — it does not verify it."
  else
    echo "NOT CREATED inside the image either. The discriminator is among the HELD EQUAL"
    echo "properties above, or is the physical device holding the bytes — which both arms share,"
    echo "so this run cannot rule it out. Whatever it is, it is not what varied."
    echo
    echo "NOTE this DIVERGES FROM E2, whose xctest failure did not reproduce inside an image"
    echo "stored on this SSD. Device creation failing where bundle loading passed would mean the"
    echo "two restrictions are not one mechanism — a larger finding than the one this experiment"
    echo "set out for. Record it on its own; do not fold it into H6."
    VERDICT_RC=1
  fi

  echo
  echo "## accounting — the default set must be untouched"
  xcv_run "default set size (compare with phase 0)" du -shx "$DEFAULT_SET"
  xcv_run "default set device list (compare with phase 0)" bash -c "xcrun simctl list devices"
  cleanup
  exit "$VERDICT_RC"
} 2>&1 | xcv_redact > "$OUT"
BODY_RC=${PIPESTATUS[0]}

echo "wrote $OUT"
[ "$BODY_RC" -ne 0 ] && echo "!! E14c did not reach a narrowing verdict (exit $BODY_RC) — read $OUT." >&2
rm -rf "$STATE" "$CLEANED_MARK"
exit "$BODY_RC"

#!/bin/bash
# E6c item 4 — does WHO ATTACHED the donor image decide whether DiskArbitration honours a
# caller-chosen mount point? Four B1 cells on one image file, in one session, each differing from
# its neighbour in one variable.
#
# **Why this exists.** Through run 7 DiskArbitration refused the donor at every mount point the
# caller named (`0x0000004D`) and accepted B0's throwaway image everywhere. The candidate left
# standing names the donor's placement by the user's session. Re-mounting through DA cannot move
# that variable: B3 is `diskutil mount` run as root and its line still reads `mounted by <user>`
# (runs 6 and 7). What can move is the ATTACH: B0's image is attached by root with `-nomount`, the
# donor by the operator's session. And `hdiutil info -plist` records the attacher as `owner-uid`,
# which is measured here rather than inferred from a mount line.
#
#   cell | attach                                  | default-location mount | differs from previous in
#   -----+-----------------------------------------+------------------------+-------------------------
#   B1u  | the donor as the operator attached it    | yes                    | —
#   B1c  | the user again, after a detach           | yes                    | a fresh attach, and the
#        |                                          |                        | attach path (launchctl
#        |                                          |                        | asuser + sudo -u)
#   B1n  | the user, -nomount                       | no                     | the default mount
#   B1r  | root, -nomount (B0's own shape)          | no                     | who attached
#
# The reading is fixed in HYPOTHESES.md H14 ("Item 4") before the run.
#
# Usage: sudo scripts/experiments/e6c-item4-attach-owner.sh /tmp/e6b-donor.sparseimage --i-understand
#
# **What it touches.** Only the image named on the command line, identified by its path in
# `hdiutil info` and never by a volume name, and only the control directory
# `/Library/Developer/xcv-e6c-probe`, which it creates and removes, for every cell — and the image's
# default location under /Volumes, where its user re-attaches auto-mount. Never a CoreSimulator path. It
# detaches and re-attaches that image three times and, on every exit path, tries to leave it as it
# found it: attached by the operator and mounted at its default location.
#
# **Not tested, and said here so a clean review is not read as more.** There is no stub harness
# for this script, unlike `test-e6c-dryrun.sh` for E6c. Its abort and restore paths have been read,
# not executed. They were kept short for that reason: every failure stops the run, no fallback
# force-unmounts anything, and the image is disposable.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./common.sh
. ./mount-staging.sh

IMG="${1:-}"
[ "${2:-}" = "--i-understand" ] || { echo "!! usage: sudo $0 /path/to/donor.sparseimage --i-understand"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "!! must run under sudo"; exit 2; }
[ -n "${SUDO_USER:-}" ] && [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != 0 ] \
    || { echo "!! run with \`sudo\` from the operator's account, not \`sudo -i\` or a root shell."; exit 2; }
case "$IMG" in
    /*.sparseimage) ;;
    *) echo "!! the image must be an absolute path to a .sparseimage"; exit 2 ;;
esac
[ -f "$IMG" ] && [ ! -L "$IMG" ] || { echo "!! $IMG is not a regular file"; exit 2; }

P=/Library/Developer/xcv-e6c-probe
APFS_VOLUME_HINT=41504653-0000-11AA-AA11-00306543ECAC
exec 3>&1

# img_state — reads `hdiutil info -plist` and sets, for images whose path is $IMG (compared after
# resolving both, so /tmp and /private/tmp agree): IMG_N (how many), IMG_UID (owner-uid), IMG_WHOLE
# (the image's whole disk), IMG_VOL (its APFS volume), IMG_MP (that volume's mount point, if any).
img_state() {
    local out
    out="$(hdiutil info -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null | /usr/bin/python3 -c '
import json, os, sys
want = os.path.realpath(sys.argv[1]); hint = sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: print("ERR=unparseable"); raise SystemExit
hits = [i for i in d.get("images", []) if os.path.realpath(i.get("image-path", "")) == want]
print("N=%d" % len(hits))
if len(hits) == 1:
    im = hits[0]; ents = im.get("system-entities", [])
    # The partitioned disk of the image, by content-hint, not by list order: the synthesized APFS
    # container is also a whole disk, and nothing guarantees which one hdiutil lists first.
    # (No apostrophes anywhere in this block: it is a single-quoted bash string.)
    wholes = [e["dev-entry"] for e in ents if e.get("content-hint") == "GUID_partition_scheme"]
    vols = [e for e in ents if e.get("content-hint") == hint]
    print("UID=%s" % im.get("owner-uid", ""))
    print("WHOLE=%s" % (wholes[0] if len(wholes) == 1 else ""))
    print("VOL=%s" % (vols[0]["dev-entry"] if len(vols) == 1 else ""))
    print("MP=%s" % (vols[0].get("mount-point", "") if len(vols) == 1 else ""))
' "$IMG" "$APFS_VOLUME_HINT")"
    IMG_N="$(printf '%s\n' "$out" | sed -n 's/^N=//p')"
    IMG_UID="$(printf '%s\n' "$out" | sed -n 's/^UID=//p')"
    IMG_WHOLE="$(printf '%s\n' "$out" | sed -n 's/^WHOLE=//p')"
    IMG_VOL="$(printf '%s\n' "$out" | sed -n 's/^VOL=//p')"
    IMG_MP="$(printf '%s\n' "$out" | sed -n 's/^MP=//p')"
    [ -n "$IMG_N" ] || IMG_N=unreadable
}

img_state
[ "$IMG_N" = 1 ] || { echo "!! $IMG must be attached exactly once; hdiutil info shows: $IMG_N."; exit 1; }
[ "$IMG_UID" = "$SUDO_UID" ] || { echo "!! $IMG is attached by uid $IMG_UID, not by $SUDO_USER. Attach it from your own session first."; exit 1; }
[ -n "$IMG_WHOLE" ] && [ -n "$IMG_VOL" ] || { echo "!! could not resolve the image's whole disk and APFS volume."; exit 1; }
case "$IMG_MP" in
    /Volumes/*) ;;
    *) echo "!! the image's volume must be mounted at its default location; it is at '${IMG_MP}'."; exit 1 ;;
esac
# The shared donor checks: APFS, a volume UUID, not on the boot disk — and it arms the redactor with
# the label and UUID while the volume is still mounted, which is the last moment it is guaranteed.
xcv_stage_resolve_donor "$IMG_MP" || exit 1
[ "$XCV_DEV" = "$IMG_VOL" ] || { echo "!! $IMG_MP resolves to $XCV_DEV, but the image's volume is $IMG_VOL. Refusing."; exit 1; }
DONOR_LABEL="${IMG_MP##*/}"

# The control directory, and the same pre-flight the E6c cells get. It must not exist: this run
# creates it and removes it, and a directory it did not create is someone else's.
xcv_stage_refuse_symlinked_path "$P" || exit 1
[ ! -e "$P" ] || { echo "!! $P already exists. Inspect it and remove it by hand; this run only uses a directory it creates."; exit 1; }
if pgrep -qx "xcodebuild|Xcode|Simulator" || pgrep -qx launchd_sim; then
    echo "!! an Xcode/Simulator session or a booted simulator is running. Check whose it is first."; exit 1
fi

REPORT="$(mktemp -t xcv-e6c-item4)" || exit 1
out="$XCV_EVIDENCE_DIR/e6c-item4-attach-owner-$(xcv_env_slug).txt"
P_CREATED=0
CLEANED=0
FAILED=0
CELLS=""

# The volume's identity after a re-attach: device nodes change, the UUID does not.
same_volume() { [ "$(xcv_volume_uuid "$IMG_VOL")" = "$XCV_DONOR_UUID" ]; }

# restore_state — put the image back as the run found it and write the restore and the cell list
# into the report. publish — redact the report into the evidence file. Split, and each guarded, so
# the normal path can close the report at top level (the stream-restore rule `test-common.sh`
# enforces on every script that redirects) and the EXIT trap still covers every other exit.
RESTORED=0
PUBLISHED=0
restore_state() {
    [ "$RESTORED" = 1 ] && return
    RESTORED=1
    trap '' INT TERM HUP
    echo
    echo "==================== restore ===================="
    img_state
    if [ "$IMG_N" = 1 ] && mount | grep -q "^$(xcv_re_escape "$IMG_VOL") on $(xcv_re_escape "$P") "; then
        xcv_run "unmount the donor from the control dir" diskutil unmount "$IMG_VOL"
    fi
    # Back to the operator's attach, mounted at its default location — the state the run started from.
    img_state
    if [ "$IMG_N" = 1 ] && [ -n "$IMG_WHOLE" ] && { [ "$IMG_UID" != "$SUDO_UID" ] || [ -z "$IMG_MP" ]; }; then
        xcv_run "detach the image" hdiutil detach "$IMG_WHOLE"
        img_state
    fi
    if [ "$IMG_N" = 0 ]; then
        xcv_run "attach the image again, as $SUDO_USER" launchctl asuser "$SUDO_UID" sudo -u "$SUDO_USER" hdiutil attach "$IMG"
        img_state
    fi
    echo "final: attached=$IMG_N owner-uid=$IMG_UID mount-point=${IMG_MP:-<none>}"
    if [ "$P_CREATED" = 1 ] && [ -d "$P" ] && [ ! -L "$P" ] && ! mount | grep -q " on $(xcv_re_escape "$P") "; then
        rmdir "$P" && echo "removed $P" || echo "!! could not remove $P"
    fi
    [ -e "$P" ] && echo "!! $P is still there." >&3
    # `/Volumes/*`, not merely non-empty: a teardown that failed twice leaves it mounted at $P,
    # and that is not the state the run started from.
    case "$IMG_N:$IMG_UID:$IMG_MP" in
        "1:$SUDO_UID:/Volumes/"*) ;;
        *) echo "!! the image was NOT restored to your attach at its default location: attached=$IMG_N owner-uid=$IMG_UID mount-point=${IMG_MP:-<none>}" >&3 ;;
    esac
    echo
    echo "==================== cells ====================$CELLS"
    [ "$FAILED" = 1 ] && echo "!! THE RUN STOPPED EARLY. Cells not listed above were not run."
}
publish() {
    [ "$PUBLISHED" = 1 ] && return
    PUBLISHED=1
    xcv_stage_write_evidence "$REPORT" "$out" || echo "!! the run log is kept at $REPORT — read it, then delete it; do not commit it." >&3
    [ -f "$out" ] && rm -f "$REPORT"
}
cleanup() {
    [ "$CLEANED" = 1 ] && return
    CLEANED=1
    trap '' INT TERM HUP
    restore_state
    exec >&3 2>&3
    publish
}
trap cleanup EXIT
trap 'FAILED=1; exit 130' INT TERM HUP

stop() { echo "!!!! $1"; echo "!! $1" >&3; FAILED=1; exit 1; }

exec >>"$REPORT" 2>&1
xcv_header "E6c item 4 — does who attached the donor decide DiskArbitration's -mountPoint answer?"
if xcv_tcc_err="$( { : < "/Library/Application Support/com.apple.TCC/TCC.db"; } 2>&1 )"; then
    echo "TCC indicator: TCC.db opened by this process — Full Disk Access reaches it"
else
    echo "TCC indicator: TCC.db NOT opened by this process (${xcv_tcc_err##*: }) — Full Disk Access does not reach it"
fi
echo "image: $IMG"
echo "donor: $IMG_MP ($IMG_VOL, whole disk $IMG_WHOLE, UUID $XCV_DONOR_UUID)"
echo "control dir: $P"
echo

mkdir "$P" || stop "could not create $P"
P_CREATED=1

# cell <name> — B1's call against the image as it is now attached. Records the attacher first.
cell() {
    local name="$1" t rc mounted logf
    echo
    echo "==================== $name ===================="
    img_state
    [ "$IMG_N" = 1 ] || stop "$name: the image is not attached exactly once ($IMG_N)"
    same_volume || stop "$name: $IMG_VOL is not the donor volume (UUID differs)"
    echo "owner-uid: $IMG_UID"
    echo "standing mount: $(mount | grep "^$(xcv_re_escape "$IMG_VOL") on " | head -1)"
    if [ -n "$IMG_MP" ]; then
        xcv_run "unmount from $IMG_MP" diskutil unmount "$IMG_VOL"
        ! mount | grep -q "^$(xcv_re_escape "$IMG_VOL") on " || stop "$name: the donor did not unmount"
    fi
    ! mount | grep -q " on $(xcv_re_escape "$P") " || stop "$name: something is mounted at $P"
    [ -z "$(ls -A "$P" 2>&1)" ] || stop "$name: $P is not empty (or not readable)"
    t="$(date '+%Y-%m-%d %H:%M:%S')"
    xcv_run "$name" diskutil mount -mountPoint "$P" "$IMG_VOL"
    echo "   mounts of $IMG_VOL now: $(mount | grep "^$(xcv_re_escape "$IMG_VOL") on " || echo '<none>')"
    mounted=0
    mount | grep -q "^$(xcv_re_escape "$IMG_VOL") on $(xcv_re_escape "$P") " && mounted=1
    echo "## diskarbitrationd for $IMG_VOL since $t"
    # Its own mktemp, not a name derived from $REPORT: root writes it with `>`, and a predictable
    # name in /tmp is a symlink someone else could have planted.
    logf="$(mktemp -t xcv-e6c-item4-log)" || stop "$name: could not create a temp file for the log"
    /usr/bin/log show --start "$t" --predicate 'process == "diskarbitrationd"' > "$logf" 2>&1
    rc=$?
    echo "   log show exit=$rc"
    grep -F "$IMG_VOL" "$logf" | grep 'status code' | sed 's/^/   /'
    rm -f "$logf"
    if [ "$mounted" = 1 ]; then
        echo "-> MOUNTED at $P"
        CELLS="$CELLS
  $name (owner-uid $IMG_UID): MOUNTED"
        xcv_run "teardown" diskutil unmount "$IMG_VOL"
        ! mount | grep -q " on $(xcv_re_escape "$P") " || stop "$name: the teardown did not take"
    else
        echo "-> REFUSED (nothing of ours at $P; exit=$XCV_LAST_EXIT)"
        CELLS="$CELLS
  $name (owner-uid $IMG_UID): REFUSED (exit $XCV_LAST_EXIT)"
    fi
}

# reattach <who> <flag> — detach the image, attach it again as <who>, and verify the attach is the
# one asked for. A detach that did not take, or an attach by the wrong owner, stops the run: the
# next cell would otherwise measure the previous condition under the new cell's name.
reattach() {
    local who="$1" flag="$2" want
    echo
    echo "==================== re-attach as $who ${flag:-(auto-mount)} ===================="
    img_state
    [ "$IMG_N" = 1 ] || stop "re-attach: the image is not attached exactly once ($IMG_N)"
    [ -n "$IMG_WHOLE" ] || stop "re-attach: the image's partitioned disk could not be resolved"
    xcv_run "detach" hdiutil detach "$IMG_WHOLE"
    img_state
    [ "$IMG_N" = 0 ] || stop "re-attach: the detach did not take ($IMG_N attachment(s) remain)"
    if [ "$who" = root ]; then
        want=0
        xcv_run "attach as root" hdiutil attach $flag "$IMG"
    else
        want="$SUDO_UID"
        xcv_run "attach as $SUDO_USER" launchctl asuser "$SUDO_UID" sudo -u "$SUDO_USER" hdiutil attach $flag "$IMG"
    fi
    img_state
    [ "$IMG_N" = 1 ] || stop "re-attach: the attach did not take ($IMG_N)"
    [ -n "$IMG_VOL" ] || stop "re-attach: no APFS volume on the new attach"
    [ "$IMG_UID" = "$want" ] || stop "MANIPULATION FAILED: asked for owner-uid $want, got $IMG_UID"
    if [ -n "$flag" ]; then
        [ -z "$IMG_MP" ] || stop "re-attach: -nomount, yet the volume is mounted at $IMG_MP"
    else
        [ "$IMG_MP" = "/Volumes/$DONOR_LABEL" ] || stop "re-attach: expected /Volumes/$DONOR_LABEL, got '${IMG_MP}'"
    fi
    echo "owner-uid after attach: $IMG_UID"
}

cell B1u
reattach "$SUDO_USER" ""
cell B1c
reattach "$SUDO_USER" -nomount
cell B1n
reattach root -nomount
cell B1r

restore_state
exec >&3 2>&3
publish

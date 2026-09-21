#!/bin/bash
# E6c — why does `mount_apfs` refuse a CoreSimulator cache path? Fill the mechanism × path matrix.
#
# **Why this exists.** E6b could not run: `mount_apfs -o nobrowse /dev/diskNsM
# /Library/Developer/CoreSimulator/Cryptex/Caches` returned `Operation not permitted` to root
# (evidence/e6b-mount-stub-cryptex-FAILED-*.txt). The target carries no BSD flag, no ACL, no
# `com.apple.rootless` xattr and no `rootless.conf` entry — the same shape as E4b, where root could
# not write `images.plist` while `simdiskimaged` rewrote it freely (HYPOTHESES.md, H9).
#
# Two explanations fit, and they lead to opposite conclusions:
#
#   (a) the PATH is protected, whatever the mechanism — the canonical-mount strategy is dead at
#       CoreSimulator paths for any privilege a product may use, as `images.plist` already is;
#   (b) the MECHANISM is refused — `mount_apfs` called directly by a non-entitled process is
#       blocked, and DiskArbitration is the supported route. E1b mounted a disk image over a
#       throwaway directory under `/Library/Developer` and it WORKED — using
#       `diskutil mount -mountPoint`, not `mount_apfs`. So E6b has never used the mechanism this
#       project actually proved.
#
# Four cells; two are already known, so this fills the other two and re-measures one as a control:
#
#                      | throwaway dir under /Library/Developer | real CoreSimulator cache path
#   -------------------+----------------------------------------+------------------------------
#   mount_apfs         | cell A                                  | known: EPERM (E6b, 2026-09-21)
#   diskutil mount     | cell B (E1b says yes; re-measured here) | cell C
#
# Read the result as: C succeeds → (b), and E6b can run once staging switches mechanism. C fails
# while B succeeds → (a), and H14 is unreachable by mounting at all, which is itself the finding.
# A succeeds → the refusal is specific to the CoreSimulator path, not to `mount_apfs`.
#
# Usage: sudo scripts/experiments/e6c-mount-mechanism.sh /Volumes/DONOR [dyld|cryptex]
#
# Nothing is written to either target. Every cell unmounts before the next one starts, and the
# EXIT trap unmounts anything still mounted and gives the donor back.
#
# **Why this does not use `xcv_stage_mount`/`xcv_stage_cleanup`**, given that `mount-staging.sh`
# exists to stop exactly this fork. Two reasons, both structural: this script mounts at TWO
# destinations and must sequence them, and it must NOT create the target — `mount-staging.sh:131`
# deliberately `mkdir`s a missing one, which here would forge the very cell it is measuring. It
# does reuse the donor resolution, the target guard and the evidence writer, which is where the
# safety lives. Its own cleanup is the part that is forked, and it mirrors the library's: `-f`
# first, re-entrancy guarded, donor given back by UUID.
#
# **If you SIGQUIT (Ctrl-\\) or `kill -9` this**, no cleanup runs: the donor is left mounted over a
# CoreSimulator cache path, nothing is published, and the shadow-data comparison is never made.
# Recover by hand: `mount | grep CoreSimulator`, then `umount -f` the device, then inspect the
# donor's root before trusting it.
#
# **Known test gap.** Nothing exercises the cleanup or interrupt paths — they need a real donor and
# root. `ExperimentScriptSafetyTests` checks only that this file sources `common.sh` and uses the
# header and redactor. Stated rather than left for the next reviewer to find.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./common.sh
. ./mount-staging.sh

MP="${1:-}"
TARGET_NAME="${2:-cryptex}"
TARGET="$(xcv_e6b_target "$TARGET_NAME")" || {
    echo "!! unknown target '$TARGET_NAME'. Allowed: dyld, cryptex (see scripts/experiments/e6b-check.sh)."
    exit 2
}
[ -n "$MP" ] || { echo "!! usage: sudo $0 /Volumes/DONOR [dyld|cryptex]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "!! must run under sudo (mount_apfs/umount)"; exit 2; }
[ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; redaction cannot be verified. Use \`sudo\`, not \`sudo -i\`."; exit 2; }

out="$XCV_EVIDENCE_DIR/e6c-mount-mechanism-$TARGET_NAME-$(xcv_env_slug).txt"

# A throwaway directory, deliberately NOT under CoreSimulator: it is the control that separates
# "this path" from "this mechanism". `/Library/Developer` because that is where E1b mounted.
# The path cell D was actually measured at, on 2026-09-21. Named rather than assumed: this script
# takes a target argument, and printing "D: REFUSED" under a `dyld` run would assert a measurement
# at a path where none was made — then the "by either mechanism" reading would rest on a cell from
# a different path. `common.sh`'s target allowlist exists to stop exactly that confusion.
D_MEASURED_AT=/Library/Developer/CoreSimulator/Cryptex/Caches

PROBE=/Library/Developer/xcv-e6c-probe
PROBE_CREATED=0

# Declared here, not beside `cell`: `matrix` reads it, and `cleanup` calls `matrix` on abort
# paths that can be reached long before the first cell runs. Under `set -u` that would be an
# unbound-variable death inside a trap.
CELLS=""

exec 3>&1
xcv_stage_resolve_donor "$MP" || exit 1
xcv_stage_guard_target "$TARGET" || exit 1

REPORT="$(mktemp -t xcv-e6c)"
E6C_CLEANED=0
cleanup() {
    # Ignore further signals for the duration. The guard below is only half the fix: a second
    # Ctrl-C arriving INSIDE cleanup re-enters the handler, returns immediately on the guard, and
    # then `exit 130` runs with EXIT already disarmed — donor never remounted, mounts left
    # standing, nothing published, nothing said.
    #
    # The cost, said out loud: an IGNORED disposition is inherited across `exec`, so the `umount`s
    # and `diskutil` below run with these signals ignored too. A `umount -f` wedged on a yanked
    # device — which is exactly what the sibling variant B sets out to create — is then beyond
    # Ctrl-C and `kill -TERM`. SIGQUIT (Ctrl-\\) and `kill -9` still work.
    trap '' INT TERM HUP
    # Re-entrancy guard, as `xcv_stage_cleanup` has: the INT trap is still armed while the EXIT
    # trap is publishing, so a second Ctrl-C would rotate twice, publish twice, and `rm -f` the
    # report out from under the outer invocation.
    [ "$E6C_CLEANED" = 1 ] && return 0
    E6C_CLEANED=1
    local discard=1
    # Order matters: unmount everything this script could have mounted BEFORE handing the donor
    # back, or the remount races a mount that is still standing.
    for m in "$PROBE" "$TARGET"; do
        if mount | grep -q "^$(xcv_re_escape "$XCV_DEV") on $(xcv_re_escape "$m") "; then
            # `-f` first: a plain `umount` can block with no timeout, and this runs on a trap.
            umount -f "$m" >/dev/null 2>&1 || umount "$m" >/dev/null 2>&1 \
                || echo "!! COULD NOT UNMOUNT $m. Unmount it before doing anything else: sudo umount -f $m" >&3
        fi
    done
    [ "$PROBE_CREATED" = 1 ] && rmdir "$PROBE" 2>/dev/null
    if [ "$XCV_STAGE_DONOR_UNMOUNTED" = 1 ]; then
        diskutil info "$XCV_DONOR_UUID" 2>/dev/null | grep -q "Mounted: *Yes" \
            || diskutil mount "$XCV_DONOR_UUID" >/dev/null 2>&1 \
            || echo "!! YOUR DONOR VOLUME IS STILL UNMOUNTED. Remount it: diskutil mount $XCV_DONOR_UUID" >&3
    fi
    if [ "${XCV_RUN_FAILED:-0}" = 1 ] && [ -s "$REPORT" ]; then
        # Into the report, explicitly: on the publish-failure path stdout is already the terminal.
        # The donor has just been handed back, so this is the first moment the comparison can run;
        # on an abort it is the only moment. It is idempotent, so the success path calling it
        # first costs nothing.
        shadow_check >>"$REPORT" 2>&1
        # Not on a publish failure: `matrix "complete"` has already been printed, the run DID
        # finish, and appending "INCOMPLETE — the run aborted" would contradict both that and the
        # `PUBLISH-FAILED` filename chosen three lines below.
        [ "${XCV_PUBLISH_FAILED:-0}" = 1 ] || matrix "INCOMPLETE — the run aborted" >>"$REPORT" 2>&1
        # A publish failure is not a run failure: if the matrix completed and only the write
        # refused, this log is a SUCCESSFUL experiment's evidence and must not be filed as FAILED.
        local why=FAILED
        [ "${XCV_PUBLISH_FAILED:-0}" = 1 ] && why=PUBLISH-FAILED
        local diag="$XCV_EVIDENCE_DIR/e6c-mount-mechanism-$TARGET_NAME-$why-$(xcv_env_slug).txt"
        if ! xcv_stage_write_evidence "$REPORT" "$diag"; then
            discard=0
            echo "!! the log could NOT be redacted, so it was not published — see the messages above." >&3
            echo "!! it is kept UNREDACTED at $REPORT. Read it, then delete it; do not commit it." >&3
        fi
    fi
    [ "$discard" = 1 ] && rm -f "$REPORT"
    return 0
}

# The matrix is the artefact. Every abort path exits before the summary is printed, so a run that
# stopped at cell B published per-cell sections, no summary and no reading rule — the one part a
# reader actually uses. Printed from cleanup, marked INCOMPLETE so it is never mistaken for a run
# that finished.
matrix() {
    echo
    echo "==================== matrix ($1) ===================="
    if [ "$TARGET" = "$D_MEASURED_AT" ]; then
        echo "  D. mount_apfs at $D_MEASURED_AT: REFUSED (measured 2026-09-21, EPERM; not repeated here)$CELLS"
    else
        echo "  D. mount_apfs at $TARGET: NOT MEASURED. The 2026-09-21 EPERM was at"
        echo "     $D_MEASURED_AT, a different path, so the 'unreachable by either"
        echo "     mechanism' reading below does NOT apply to this run.$CELLS"
    fi
    echo
    echo "Reading (fixed in HYPOTHESES.md H14 before this run, deliberately):"
    echo "  B REFUSED             => the harness or the mechanism is broken; the matrix is VOID."
    echo "  C MOUNTED             => the mechanism was the problem. E6b re-runs on DiskArbitration"
    echo "                           and H14 stays open."
    echo "  C REFUSED, B MOUNTED  => the CoreSimulator path is unreachable by this route, at root,"
    echo "                           by either mechanism. H14 closes as sized-but-unproducible."
    echo "                           NOT 'by any privilege': Apple's own daemons mount these paths"
    echo "                           (F16/E4b), and two root cells do not license that claim."
    if [ "$TARGET" = "$D_MEASURED_AT" ]; then
        echo "  A MOUNTED, D REFUSED  => the refusal is specific to the CoreSimulator path rather than"
        echo "                           to mount_apfs."
    else
        echo "  (the A-vs-D rule is omitted: D was not measured at this target.)"
    fi
}

# H2, the other half, as a function because the abort paths need it too. Anything a daemon wrote
# to a cache path while the donor was mounted over it landed ON THE DONOR and is still there.
# `xcv_stage_guard_target` only excludes interactive sessions; `simdiskimaged` and
# CoreSimulatorService are daemons, and E4b is the evidence that `simdiskimaged` writes these
# paths when root cannot. New entries here are shadow data — safety rule 6.
#
# Called from `cleanup` as well as from the success path. The run that most needs this is the one
# where cell C mounted over the real cache path and the unmount then FAILED: the donor spent the
# longest there and was force-unmounted, and on the straight-line-only version that run published
# a `-FAILED-` file that said nothing about it at all.
SHADOW_CHECKED=0
shadow_check() {
    # Idempotent: the success path calls it, and so does `cleanup` on the publish-failure path.
    # Not a harmless replay — between the two, `cleanup` remounts the donor with `diskutil`,
    # which is BROWSABLE unlike the nobrowse cell mounts, so Spotlight and fseventsd can create
    # `.Spotlight-V100` / `.fseventsd` in the donor root. A second comparison against the same
    # DONOR_BEFORE would publish that benign remount as shadow data attributable to the
    # cache-path mount, in a tracked evidence file. Exactly the misreading rule 6 must not carry.
    [ "$SHADOW_CHECKED" = 1 ] && return 0
    SHADOW_CHECKED=1
    echo
    echo "==================== shadow data on the donor ===================="
    # BY UUID, not by `$MP`. `diskutil mount <uuid>` mounts at `/Volumes/<label>`, which need not be
    # where it was: a stale directory or a label collision gives `/Volumes/<label> 1`, and a failed
    # remount gives nothing at all. Reading `$MP` in any of those returns empty, which is
    # indistinguishable from "the donor root is empty" — so a comparison that was never made would
    # print as "unchanged". Ask the volume where it is.
    diskutil mount "$XCV_DONOR_UUID" >/dev/null 2>&1
    MP_AFTER="$(diskutil info "$XCV_DONOR_UUID" 2>/dev/null | sed -n 's/^ *Mount Point: *//p' | head -1)"
    # `-d` as well as `-n`: a future `diskutil` emitting anything but a path there would otherwise
    # turn "not compared" into a confident "CHANGED".
    if [ -z "$MP_AFTER" ] || [ ! -d "$MP_AFTER" ]; then
        echo "!!!! THE DONOR DID NOT COME BACK, so the shadow-data comparison was NOT MADE."
        echo "!!!! This is not 'unchanged'. Remount it and inspect its root by hand:"
        echo "!!!!     diskutil mount $XCV_DONOR_UUID"
        echo "!! the donor did not come back; the shadow-data comparison was NOT made." >&3
    elif DONOR_AFTER="$(ls -A "$MP_AFTER" 2>/dev/null | sort)"; [ "$DONOR_BEFORE" = "$DONOR_AFTER" ]; then
        [ "$MP_AFTER" = "$MP" ] || echo "note: the donor came back at $MP_AFTER, not $MP"
        # Scoped to what was actually compared: top-level names, one level deep. A daemon writing
        # INSIDE an existing directory on the donor does not show here.
        echo "donor root listing unchanged, top-level names only (${DONOR_BEFORE:-<empty>})"
    else
        [ "$MP_AFTER" = "$MP" ] || echo "note: the donor came back at $MP_AFTER, not $MP"
        echo "!!!! THE DONOR ROOT CHANGED. Something wrote to a cache path while we were mounted over it."
        echo "before: ${DONOR_BEFORE:-<empty>}"
        echo "after:  ${DONOR_AFTER:-<empty>}"
        echo "new:"
        comm -13 <(printf '%s\n' "$DONOR_BEFORE") <(printf '%s\n' "$DONOR_AFTER")
        echo "!! THE DONOR ROOT CHANGED — shadow data was written. See the evidence file." >&3
    fi
}

trap cleanup EXIT
trap 'XCV_RUN_FAILED=1; trap - EXIT; cleanup; exit 130' INT TERM HUP

exec >>"$REPORT" 2>&1
xcv_header "E6c — mount mechanism × path, after E6b's mount_apfs returned EPERM"
echo "donor: $MP ($XCV_DEV, $XCV_FS, whole disk $XCV_DONOR_DISK, UUID $XCV_DONOR_UUID)"
echo "owners on donor: $(diskutil info "$XCV_DEV" 2>/dev/null | sed -n 's/^ *Owners: *//p' | head -1)"
echo "cache target: $TARGET"
echo "control dir:  $PROBE"
echo

# The control directory gets the same scrutiny as the real target, for the same reasons: mounting
# over an occupied directory hides whatever is in it, and mounting over an existing mount point
# stacks filesystems. `$PROBE` is a name this script owns, but "I own this name" is exactly the
# assumption an aborted earlier run falsifies.
# The same predicate the real target gets, from the same function — the third copy of a rule in
# these scripts is where the drift always started. Called OUTSIDE the exists-check below, because
# an absent $PROBE can still sit under a symlinked ancestor, and that combination is what defeated
# two earlier drafts. A symlinked `/Library/Developer` (some CI images relocate it) would put
# cells A and B on the resolved path while `cell`'s verification and `cleanup`'s loop both grep
# for this literal one: both cells would misreport, the matrix would be false, and cleanup would
# not unmount.
xcv_stage_refuse_symlinked_path "$PROBE" || exit 1
if [ -e "$PROBE" ]; then
    [ -d "$PROBE" ] || { echo "!! $PROBE exists and is not a directory. Refusing." >&3; exit 1; }
    mount | grep -q " on $(xcv_re_escape "$PROBE") " \
        && { echo "!! something is already mounted at $PROBE — an earlier run did not clean up. Refusing." >&3; exit 1; }
    [ -z "$(ls -A "$PROBE" 2>/dev/null)" ] \
        || { echo "!! $PROBE is not empty. Refusing to mount over it." >&3; exit 1; }
else
    mkdir -p "$PROBE" || { echo "!! could not create $PROBE" >&3; exit 1; }
    PROBE_CREATED=1
fi

# H2: what is on the donor before any of this. While the donor sits over a CoreSimulator cache
# path, anything a daemon writes there lands ON THE DONOR and survives the unmount. The guard only
# excludes interactive sessions; `simdiskimaged` and CoreSimulatorService are daemons, and E4b is
# the evidence that `simdiskimaged` writes these paths when root cannot. Compared after the run.
DONOR_BEFORE="$(ls -A "$MP" 2>/dev/null | sort)"

# The donor cannot be mounted in two places at once, so it comes off /Volumes first and stays off
# for the whole matrix. Every cell leaves it unmounted for the next one.
# Flag BEFORE the call, not after: a signal landing in the one-line window between them leaves
# `XCV_STAGE_DONOR_UNMOUNTED=0`, so cleanup skips both the remount and the warning, and the
# operator's drive is simply gone with nothing said.
XCV_STAGE_DONOR_UNMOUNTED=1
xcv_run "unmount donor from its mount point" diskutil unmount "$XCV_DEV"

# VERIFIED, because `xcv_run` always returns 0 — it ends in `echo`. An unmount that failed (an open
# file, `mds` indexing) leaves the donor mounted, every cell then fails with "already mounted", and
# all three print REFUSED. The reading rule at the bottom would turn that into "the CoreSimulator
# path is protected against mounting by any privilege a product may use" and retire H14 on the
# strength of a busy volume. That is the single worst thing this script could do.
if mount | grep -q "^$(xcv_re_escape "$XCV_DEV") on "; then
    echo "!!!! UNMOUNT DID NOT TAKE: $XCV_DEV is still mounted. Every cell below would report a"
    echo "!!!! false REFUSED, so nothing was run."
    mount | grep "^$(xcv_re_escape "$XCV_DEV") on "
    echo "!! UNMOUNT DID NOT TAKE — the donor is still mounted. Nothing was run." >&3
    XCV_RUN_FAILED=1
    exit 1
fi


# cell <label> <destination> <command...>
#
# Attempts one mount, verifies it took ANCHORED TO OUR DEVICE — `mount_apfs` exits 0 in cases where
# nothing is mounted, and "is something mounted here" would pass on a leftover from an aborted run —
# then unmounts so the next cell starts clean. Records PASS/FAIL into the matrix summary.
cell() {
    local label="$1" dest="$2"; shift 2
    echo
    echo "==================== $label ===================="
    xcv_run "$label" "$@"

    # Where did it actually land? `diskutil mount`'s own usage says it mounts "in the standard
    # place (/Volumes), unless an optional custom mount point is specified" — and nothing in that
    # contract promises it REFUSES rather than falling back when the custom point is rejected. A
    # fallback would read as REFUSED here, occupy the device so the next cell also read REFUSED,
    # and leave a stray mount the cleanup loop (which knows only $PROBE and $TARGET) would not
    # even unmount. So the whereabouts go in the report on every attempt, and "mounted, but not
    # where we asked" is its own outcome rather than a silent false negative.
    local where
    where="$(mount | grep "^$(xcv_re_escape "$XCV_DEV") on " || true)"
    echo "   mounts of $XCV_DEV now: ${where:-<none>}"
    if [ -n "$where" ] && ! mount | grep -q "^$(xcv_re_escape "$XCV_DEV") on $(xcv_re_escape "$dest") "; then
        echo "!!!! MOUNTED ELSEWHERE: the command did not refuse — it mounted somewhere other than"
        echo "!!!! $dest. Recording REFUSED would be a false reading, so nothing below was run."
        CELLS="$CELLS
  $label: MOUNTED ELSEWHERE, not at $dest"
        umount -f "$XCV_DEV" >/dev/null 2>&1 || umount "$XCV_DEV" >/dev/null 2>&1
        # Verified. If the stray survives, cleanup will NOT find it — its loop knows only $PROBE
        # and $TARGET — and worse, `diskutil info … Mounted: Yes` would then be satisfied by the
        # stray itself, so cleanup would conclude the donor was handed back and say nothing.
        local strays
        strays="$(mount | grep "^$(xcv_re_escape "$XCV_DEV") on " || true)"
        if [ -n "$strays" ]; then
            echo "!!!! AND IT IS STILL MOUNTED: $strays"
            echo "!! $label mounted at an unexpected place AND could not be unmounted:" >&3
            echo "!!   $strays" >&3
            echo "!! Unmount it by hand before anything else: sudo umount -f $XCV_DEV" >&3
        else
            echo "!! $label mounted somewhere other than $dest. Nothing below was run." >&3
        fi
        return 1
    fi

    if [ -n "$where" ]; then
        echo "-> MOUNTED at $dest"
        CELLS="$CELLS
  $label: MOUNTED"
        xcv_run "unmount $dest" umount "$dest"
        if mount | grep -q "^$(xcv_re_escape "$XCV_DEV") on $(xcv_re_escape "$dest") "; then
            echo "!!!! COULD NOT UNMOUNT $dest — stopping before the next cell mounts on top of it."
            echo "!! COULD NOT UNMOUNT $dest. Nothing below was run." >&3
            return 1
        fi
    else
        # The exit status matters in the summary, not just in the body. A cell refuses for
        # "Operation not permitted" and for "unknown option" alike, and the matrix line is the
        # artefact that travels into HYPOTHESES.md. A bare REFUSED there invites the reader to
        # assume the mount was refused when the invocation may simply have been wrong.
        echo "-> REFUSED (nothing of ours is mounted at $dest; exit=${XCV_LAST_EXIT:-?})"
        CELLS="$CELLS
  $label: REFUSED (exit ${XCV_LAST_EXIT:-?})"
    fi
    return 0
}

cell "A. mount_apfs at the control dir" "$PROBE" mount_apfs -o nobrowse "$XCV_DEV" "$PROBE" || { XCV_RUN_FAILED=1; exit 1; }
# `nobrowse` on the diskutil cells too. Without it A and B differ in TWO things — the mechanism
# and the browse flag — and a divergence would be attributable to neither. It also keeps Finder
# and Spotlight off a volume mounted under /Library/Developer.
cell "B. diskutil at the control dir" "$PROBE" diskutil mount nobrowse -mountPoint "$PROBE" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }

# The guard ran once, before the donor unmount and two mount cycles ago: both its `pgrep` and its
# emptiness check have expired. And an ABSENT target makes `diskutil mount` fail for "no such
# mount point", which would be recorded as REFUSED and read as "the path is protected" — the false
# conclusion again, and absence is exactly the state H14 is about. Deliberately NOT created:
# `mount-staging.sh` creates a missing target, which here would forge the cell it is measuring.
echo
echo "## re-checking the cache target immediately before cell C"
xcv_run "stat $TARGET" stat -f 'type=%HT mode=%Sp owner=%Su:%Sg links=%l' "$TARGET"
if [ ! -d "$TARGET" ]; then
    echo "!!!! $TARGET does not exist, so diskutil would fail for that reason and the cell would"
    echo "!!!! read as REFUSED. Not creating it: that would forge the measurement."
    echo "!! $TARGET does not exist, so cell C cannot be measured. Nothing more was run." >&3
    XCV_RUN_FAILED=1
    exit 1
fi
xcv_stage_guard_target "$TARGET" || { XCV_RUN_FAILED=1; exit 1; }

cell "C. diskutil at the cache target" "$TARGET" diskutil mount nobrowse -mountPoint "$TARGET" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }

shadow_check
matrix "complete"
exec >&3 2>&3
xcv_stage_write_evidence "$REPORT" "$out" || { XCV_RUN_FAILED=1; XCV_PUBLISH_FAILED=1; exit 1; }
echo "Next: record the matrix in HYPOTHESES.md (H14) and COMPATIBILITY_MATRIX.md."

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
# Six cells. D is a prior measurement and is not repeated; B0 is the control that separates a
# broken harness from a real change in the environment.
#
#                      | throwaway dir under /Library/Developer   | real CoreSimulator cache path
#   -------------------+------------------------------------------+-----------------------------
#   mount_apfs         | A — MOUNTED (2026-09-21)                 | D — EPERM (E6b, 2026-09-21)
#   diskutil mount     | B0 (E1b replicated, own sparse image)    | C
#                      | B1 (E1b's call, the donor) + B2 (nobrowse)|
#
# **What the 2026-09-21 run settled.** A mounted and D refused: same mechanism, same invocation
# shape, same root, same OS build, same donor device, two paths under /Library/Developer. The
# refusal is specific to that path — or to some property of it — and not to `mount_apfs`. Two
# qualifications, because the first draft of this paragraph over-read on both: it was TWO runs
# about six hours apart, not one session; and the two directories differ in more than their
# names (`$PROBE` is root:wheel and created by the run, the target is root:admin and
# system-created). Neither carries the `restricted` flag and `rootless.conf` has no CoreSimulator
# entry, so the obvious SIP explanation is ruled out and the cause is still unidentified.
#
# **What it did not settle.** The diskutil column was VOID by this script's own rule: cell B
# failed on the control. Five candidate causes — three defects introduced here, and two that
# would be FINDINGS:
#
#   1. `nobrowse` was added to a call E1b had proven WITHOUT it, during review, so that cells A
#      and B would differ only in mechanism. That traded one confound for a departure from the
#      only call this project had seen work.
#   2. The cells ran `mount_apfs` first.
#   3. `cell` tore mounts down with bare `umount`, bypassing DiskArbitration. Plausible and
#      UNEVIDENCED: an earlier version of this comment called it the leading suspect because the
#      failure message looked like it had an emptied volume name. It does not — `diskutil`'s
#      template for that path is literally `Volume on %@ failed to mount`, with no name field
#      (`strings /usr/sbin/diskutil`), and cell C produced the same message with no bare `umount`
#      before it. Reading a fixed format string as a symptom is the error.
#   4. The donor class. E1b used a fresh hdiutil sparse image; this uses a physical external
#      drive, which DA may decline for `-mountPoint`.
#   5. The OS build. E1b ran on 26.6.2 (25G83), this on 26.7 (25G229).
#
# 4 and 5 are not defects, and the first design could not tell them from a broken harness because
# "B1 refused" was pre-labelled VOID. Hence B0. The other three are addressed directly: diskutil
# cells run first; teardown goes through `diskutil unmount` and RECORDS which mechanism won,
# tainting every later diskutil cell if it ever fell back outside DA; and `nobrowse` is its own
# cell. Cell C keeps `nobrowse` unless B2 proves it is the obstacle — a browsable donor over a
# real cache path is a manufactured shadow-data event, which is rule 6.
#
# The full rule set, including every void condition, is printed by `matrix` at the end of the run
# and is fixed in HYPOTHESES.md H14 before it.
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
# safety lives. Its own cleanup is the part that is forked, and it mirrors the library's:
# DiskArbitration first with `umount -f` as the fallback, re-entrancy guarded, donor given back
# by UUID. B0 runs through `cell` for the same reason — a hand-rolled copy of it had none of
# `cell`'s protections.
#
# **If you SIGQUIT (Ctrl-\\) or `kill -9` this**, no cleanup runs: the donor is left mounted over a
# CoreSimulator cache path, nothing is published, and the shadow-data comparison is never made.
# Recover by hand: `mount | grep CoreSimulator`, then `umount -f` the device, then inspect the
# donor's root before trusting it.
#
# **Testing.** `scripts/experiments/test-e6c-dryrun.sh` runs this script unmodified against
# recording stubs (`XCV_DRYRUN=1`), which reaches the cleanup, teardown, abort and interrupt
# paths — the ones that need root and a real donor, and that four review rounds filled with
# defects while nothing tested them. What it still does NOT cover is listed in that file's
# header; read it before assuming a green run means more than it does.
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

# **Dry run — the harness for the paths nothing else can reach.**
#
# Four review rounds put six defects in this script, and every one of them was in the cleanup,
# teardown or abort paths: `rm -rf /` on a failed `mktemp`, a detach that never ran, a cleanup
# that reported STILL ATTACHED about a device it had just removed, a dead attach-failure branch.
# Those paths need root and a real donor to reach, so nothing tested them and the header said so.
# This is what closes that: `XCV_DRYRUN=1` puts a directory of recording stubs ahead of PATH, so
# `diskutil`, `hdiutil`, `mount`, `umount` and `mount_apfs` return scripted statuses and log their
# calls instead of touching a device.
#
# **It refuses to run as root, and that inversion is the point.** A dry run is the one mode where
# a command that slips past the stubs would act for real, so the mode that skips the privilege
# check must be the mode that cannot have privileges. A real run and a dry run can therefore
# never be confused for one another: each refuses the other's conditions.
if [ "${XCV_DRYRUN:-0}" = 1 ]; then
    [ "$(id -u)" != 0 ] || { echo "!! XCV_DRYRUN must NOT run as root: a command the stubs do not cover would act for real."; exit 2; }
    [ -n "${XCV_STUB_BIN:-}" ] && [ -d "$XCV_STUB_BIN" ] || { echo "!! XCV_DRYRUN needs XCV_STUB_BIN pointing at a stub directory."; exit 2; }
    # A DISTINCT variable, because `common.sh` assigns `XCV_EVIDENCE_DIR` unconditionally and
    # would discard anything the caller exported — the first draft of the dry-run harness passed
    # `XCV_EVIDENCE_DIR`, saw it overwritten, and was correctly refused by the guard below for
    # trying to write to the real evidence directory. The guard working on its author is the
    # reason it is written this way round: refuse first, then accept an explicit scratch path.
    [ -n "${XCV_DRYRUN_EVIDENCE_DIR:-}" ] && [ -d "$XCV_DRYRUN_EVIDENCE_DIR" ] \
        || { echo "!! XCV_DRYRUN needs XCV_DRYRUN_EVIDENCE_DIR pointing at a scratch directory."; exit 2; }
    # RESOLVED before the comparison. A literal prefix match is defeated by `/./`, by `..`, and
    # by a symlink — `$XCV_ROOT/./docs/research/evidence` walked straight past the first version
    # of this guard. That is the same class of hole `xcv_stage_refuse_symlinked_path` exists for,
    # one function away from it.
    XCV_DRYRUN_EVIDENCE_DIR="$(cd "$XCV_DRYRUN_EVIDENCE_DIR" && pwd -P)" || exit 2
    case "$XCV_DRYRUN_EVIDENCE_DIR/" in
        "$(cd "$XCV_ROOT" && pwd -P)"/docs/*) echo "!! XCV_DRYRUN refuses to write to the real evidence directory."; exit 2 ;;
    esac
    XCV_EVIDENCE_DIR="$XCV_DRYRUN_EVIDENCE_DIR"
    PATH="$XCV_STUB_BIN:$PATH"
    SUDO_USER="${SUDO_USER:-dryrun}"
    echo "## XCV_DRYRUN: stubs at $XCV_STUB_BIN, evidence to $XCV_EVIDENCE_DIR. NOTHING IS MOUNTED."
else
    [ "$(id -u)" = 0 ] || { echo "!! must run under sudo (mount_apfs/umount)"; exit 2; }
    [ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; redaction cannot be verified. Use \`sudo\`, not \`sudo -i\`."; exit 2; }
fi

out="$XCV_EVIDENCE_DIR/e6c-mount-mechanism-$TARGET_NAME-$(xcv_env_slug).txt"
# `-DRYRUN` in the NAME, because the two banners above go to the terminal, before the report is
# opened, and never reach the file. A dry run's output is otherwise indistinguishable from real
# evidence: same filename pattern, same `xcv_header`, a full matrix — all of it fabricated from
# stub answers. There are already `-superseded-` files sitting untracked in that directory.
[ "${XCV_DRYRUN:-0}" = 1 ] && out="$XCV_EVIDENCE_DIR/e6c-mount-mechanism-$TARGET_NAME-DRYRUN-$(xcv_env_slug).txt"

# A throwaway directory, deliberately NOT under CoreSimulator: it is the control that separates
# "this path" from "this mechanism". `/Library/Developer` because that is where E1b mounted.
# The path cell D was actually measured at, on 2026-09-21. Named rather than assumed: this script
# takes a target argument, and printing "D: REFUSED" under a `dyld` run would assert a measurement
# at a path where none was made — then the "by either mechanism" reading would rest on a cell from
# a different path. `common.sh`'s target allowlist exists to stop exactly that confusion.
D_MEASURED_AT=/Library/Developer/CoreSimulator/Cryptex/Caches

PROBE=/Library/Developer/xcv-e6c-probe

# **The in-hierarchy control.** `$PROBE` differs from the cache target in more than location:
# root:wheel vs root:admin, created by this run vs created by the system, depth 3 vs depth 6, a
# backup-exclude xattr on one and not the other, and guaranteed-empty vs unmeasured. So a
# refusal at the target and a success at `$PROBE` cannot distinguish "this directory has some
# property" from "this hierarchy is protected". `$HPROBE` is a run-created empty directory
# INSIDE `/Library/Developer/CoreSimulator/`, which holds location constant and varies only the
# things `$PROBE` already varies — the one cheap cell that separates the two.
HPROBE=/Library/Developer/CoreSimulator/xcv-e6c-hprobe
HPROBE_CREATED=0
H0_RECORDED=0
PROBE_CREATED=0

# In a dry run the control directory moves to scratch, because creating it is a REAL `mkdir` that
# a non-root process cannot do under `/Library/Developer` — and a dry run is defined as one that
# cannot be root. Only `$PROBE` moves: it is a path this script owns and invents. `$TARGET` stays
# exactly where the allowlist puts it, because that allowlist is a safety property and a test
# mode that relaxes it would be testing something else.
if [ "${XCV_DRYRUN:-0}" = 1 ]; then
    PROBE="$XCV_EVIDENCE_DIR/dryrun-probe"
    # The cache target moves too, and the reason is worth stating because it looks like the
    # allowlist being relaxed and is not. Three reads of `$TARGET` cannot be stubbed — `[ -d ]`
    # and `[ -e ]` are builtins, `ls -A` and `cd`/`pwd -P` are real — so a dry run against the
    # live path answers differently depending on whether that directory happens to exist and be
    # empty on the machine running it. Measured: absent, 2 checks fail; non-empty, 16 fail and 5
    # of the survivors pass VACUOUSLY because no scenario reaches a cell. As a CI gate on two
    # runners that is worse than no gate.
    #
    # What is NOT relaxed: `xcv_e6b_target` still resolves the real allowlisted path, and
    # `test-e6c-dryrun.sh` asserts that separately — so the allowlist is still pinned here as
    # well as by `ExperimentScriptSafetyTests`. A dry run measures nothing about the real path;
    # it exercises the script's reactions.
    TARGET="$XCV_EVIDENCE_DIR/dryrun-target"
    mkdir -p "$TARGET"
    # One level down, and the parent is deliberately NOT created here. `mkdir` (no `-p`) then
    # succeeds or fails purely on whether the caller made the parent — which is how the test
    # harness reaches the H0 branch without a test-only environment variable, and how the real
    # script behaves on a machine whose hierarchy refuses.
    HPROBE="$XCV_EVIDENCE_DIR/dryrun-hprobe-parent/hprobe"
    # `D_MEASURED_AT` moves with it, or the harness exercises only the arm that never ships: in a
    # real `cryptex` run the two ARE the same path, so leaving it behind made every dry run take
    # `matrix`'s "D NOT MEASURED at this target" branch and left the shipping branch — and the
    # A-vs-D reading rule — deletable without a failure.
    D_MEASURED_AT="$TARGET"
    echo "## XCV_DRYRUN: control dir -> $PROBE, cache target -> $TARGET (the real ones need root)."
    echo "## XCV_DRYRUN: the allowlist is UNCHANGED; xcv_e6b_target still returns the real path."
fi

# Declared here, not beside `cell`: `matrix` reads it, and `cleanup` calls `matrix` on abort
# paths that can be reached long before the first cell runs. Under `set -u` that would be an
# unbound-variable death inside a trap.
CELLS=""
# Per-cell outcomes, set by `cell` through `eval` (which is why shellcheck cannot see the writes)
# and read by the decisions that depend on them: whether cell C may keep `nobrowse`, and which
# void banners `matrix` prints. Initialised so `set -u` is safe on a run that stops early.
# shellcheck disable=SC2034
CELL_RESULT_B0=unmeasured
CELL_RESULT_B1=unmeasured
CELL_RESULT_B2=unmeasured
CELL_RESULT_C=unmeasured
CELL_RESULT_E=unmeasured
CELL_RESULT_E0=unmeasured
CELL_RESULT_E0b=unmeasured
CELL_RESULT_B3=unmeasured
CELL_RESULT_H1=unmeasured
CELL_RESULT_H2=unmeasured
CELL_RESULT_A=unmeasured
XCV_LAST_TEARDOWN=""
DA_BYPASSED=0
# B0 attaches its own throwaway image; cleanup has to be able to take it away on every path.
B0_DEV=""
B0_VOL=""
B0_IMG=""
B0_TMPDIR=""
B0_NAME=""
B0_CREATED_RC=1
B0_ATTACH_RC=0
B0_PLIST=""
B0_STORE=""
B0_STORE_DISK=""

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
    # Re-entrancy guard, as `xcv_stage_cleanup` has. Belt-and-braces GIVEN the ignore above, and
    # measured as such: deleting this line alone changes nothing, because the ignored disposition
    # already stops a second signal from re-entering. Deleting the ignore alone IS caught, and so
    # is deleting both. Kept because it is the defence that survives someone removing the ignore
    # for an unrelated reason — the INT trap is still armed while the EXIT
    # trap is publishing, so a second Ctrl-C would rotate twice, publish twice, and `rm -f` the
    # report out from under the outer invocation.
    [ "$E6C_CLEANED" = 1 ] && return 0
    E6C_CLEANED=1
    local discard=1
    # Order matters: unmount everything this script could have mounted BEFORE handing the donor
    # back, or the remount races a mount that is still standing.
    for m in "$PROBE" "$HPROBE" "$TARGET"; do
        # Whatever is mounted there, ours or B0's. DiskArbitration first for the same reason the
        # cells use it — a teardown that goes around DA is what may have voided the first run —
        # then `-f`, because a plain `umount` can block with no timeout and this is a trap.
        if mount | grep -q " on $(xcv_re_escape "$m") "; then
            diskutil unmount "$m" >/dev/null 2>&1 || umount -f "$m" >/dev/null 2>&1 || umount "$m" >/dev/null 2>&1 \
                || echo "!! COULD NOT UNMOUNT $m. Unmount it before doing anything else: sudo umount -f $m" >&3
        fi
    done
    # B0's throwaway image, if the run died between attach and detach. Removing it cannot touch
    # the operator's donor: `$B0_DEV` is only ever set from this run's own `hdiutil attach`.
    # Cleared on success, because the delete below reads it. Cleanup's detach is the one that
    # runs on every abort path — B0's cell returning 1, a later cell failing, Ctrl-C — so without
    # this the image is detached, the operator is told it is STILL ATTACHED, handed a command for
    # a device that no longer exists, and left a 512 MB file nothing will ever collect. The
    # earlier comment claiming "$B0_DEV is cleared on a successful detach" was true only of the
    # main-line detach.
    if [ -n "$B0_DEV" ]; then
        if hdiutil detach "$B0_DEV" >/dev/null 2>&1 || hdiutil detach -force "$B0_DEV" >/dev/null 2>&1; then
            B0_DEV=""
        else
            echo "!! could not detach B0's image at $B0_DEV. Detach it: hdiutil detach -force $B0_DEV" >&3
        fi
    fi
    # The captured directory, never `dirname "$B0_IMG"` — see the B0 block for why that
    # spelling was `rm -rf /` as root on a failed `mktemp`.
    #
    # And only once nothing is attached to it. `$B0_DEV` is cleared on a successful detach, so a
    # non-empty value here means the image is still live: deleting its backing file would leave a
    # `/dev/diskN` over a deleted file, silently. Keeping a 512 MB sparse file in TMPDIR is the
    # cheaper mistake, and the operator is told where it is.
    if [ -n "${B0_TMPDIR:-}" ]; then
        if [ -n "${B0_DEV:-}" ]; then
            echo "!! B0's image is STILL ATTACHED at $B0_DEV, so its file was kept rather than deleted" >&3
            echo "!!   under a live device. Detach and remove: hdiutil detach -force $B0_DEV && rm -rf $B0_TMPDIR" >&3
        else
            rm -rf "$B0_TMPDIR"
        fi
    fi
    [ "$PROBE_CREATED" = 1 ] && rmdir "$PROBE" 2>/dev/null
    [ "$HPROBE_CREATED" = 1 ] && rmdir "$HPROBE" 2>/dev/null
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
    case "$CELL_RESULT_B1" in
        refused) echo "  !! CELL C IS VOID: its control (B1) refused. Do not read C's line above." ;;
    esac
    # A is the trailing control. If the session lost the ability to mount ANYWHERE by the time it
    # ran, then C's refusal is uninterpretable and so is the A-vs-D comparison that is otherwise
    # this experiment's firmest result. The rule said so and nothing enforced it — the same gap
    # B0's banner below was added to close.
    case "$CELL_RESULT_A" in
        refused)    echo "  !! A REFUSED: the trailing control could not mount at the throwaway dir either."
                    echo "     The session lost the ability to mount anywhere. THE WHOLE RUN IS VOID,"
                    echo "     including the A-vs-D comparison." ;;
        unmeasured) echo "  !! A NOT MEASURED: the run stopped before the trailing control. Nothing below"
                    echo "     B0 can be read, because nothing establishes the session could still mount." ;;
    esac
    case "$CELL_RESULT_C" in
        unmeasured) echo "  !! C NOT MEASURED: the cache-path cell did not run." ;;
    esac
    case "$CELL_RESULT_E" in
        unmeasured) echo "  !! E NOT MEASURED: the decisive DA-at-the-cache-path cell did not run." ;;
    esac
    case "$CELL_RESULT_E0" in
        refused)
            echo "  !! E0 REFUSED: DiskArbitration declined a volume it had just accepted, so a"
            echo "     SECOND -mountPoint mount of the same volume is refused. Cell E WAS NOT RUN"
            echo "     — not void; void means it ran and its control failed. This makes mount"
            echo "     history a live explanation for B1, not an established one: B1 is a"
            echo "     different volume of a different media class." ;;
    esac
    case "$CELL_RESULT_B0" in
        refused)    echo "  !! B0 REFUSED: E1b's own call, on E1b's own kind of volume, no longer works on"
                    echo "     this OS build. That is the RESULT. Every diskutil cell after it is VOID." ;;
        unmeasured) echo "  !! B0 NOT MEASURED: the control that separates 'the call' from 'this donor /"
                    echo "     this OS build' did not run. B1's REFUSED, if any, cannot be attributed." ;;
    esac
    echo
    echo "Reading (fixed in HYPOTHESES.md H14 before the run, deliberately):"
    echo "  any VOID marker above => a teardown bypassed DiskArbitration before that cell. Its"
    echo "                           REFUSED is the fallback talking, not macOS. Do not read it."
    echo "  B0 REFUSED            => E1b's own call, on E1b's own kind of volume, no longer works."
    echo "                           A RESULT about this OS build, not a harness fault. Stop here."
    echo "  B0 MOUNTED, B1 REFUSED=> the call works; this DONOR is what diskutil will not take."
    echo "                           Not a statement about the cache path. Do not read C."
    echo "  B0 NOT MEASURED       => B1 REFUSED cannot be attributed to the call, the donor or the"
    echo "                           OS build. Fix B0 and re-run before reading anything below it."
    echo "  B1 MOUNTED, B2 REFUSED=> \`nobrowse\` is what diskutil refuses, not the path. That alone"
    echo "                           explains the 2026-09-21 void and is worth recording."
    echo "  E0 REFUSED            => a second -mountPoint mount of the same volume is refused;"
    echo "                           E was not run. Mount history becomes a live explanation for"
    echo "                           B1, not an established one."
    echo "  E MOUNTED             => the cache path IS reachable by mounting, at root, via DA —"
    echo "                           FOR A DISK-IMAGE VOLUME. H14 is producible that way. It is"
    echo "                           not yet a product claim: E6b relocates to EXTERNAL storage,"
    echo "                           and B1 (the donor's own refusal) is still unexplained."
    echo "  E REFUSED, E0 AND     => history is ruled out AT E'S OWN MOUNT DEPTH, and both"
    echo "  E0b BOTH MOUNTED         mechanisms refuse the cache path with a volume each has"
    echo "                           accepted elsewhere. Strongest (a) available here: H14"
    echo "                           closes as unreachable. E0 alone is NOT enough — a rule"
    echo "                           monotone in mount depth gives the same pattern with the"
    echo "                           path playing no part, which is what E0b measures."
    echo "  C MOUNTED             => the mechanism was the problem. E6b re-runs on DiskArbitration"
    echo "                           and H14 stays open."
    echo "  C REFUSED, B1 MOUNTED => the CoreSimulator path is unreachable by this route, at root,"
    echo "                           by either mechanism. H14 closes as sized-but-unproducible."
    echo "                           NOT 'by any privilege': Apple's own daemons mount these paths"
    echo "                           (F16/E4b), and two root cells do not license that claim."
    # Printed only when H0 actually happened on THIS machine. Left unconditional it would state
    # one Intel machine's 26.7 result as though every report had measured it.
    if [ "${H0_RECORDED:-0}" = 1 ]; then
        echo "  H0 REFUSED            => this hierarchy refuses DIRECTORY CREATION at this privilege,"
        echo "                           before any mount is attempted. Read it narrowly: it is a"
        echo "                           result about mkdir, NOT about mounting. D was refused at a"
        echo "                           directory that already existed, so H0 does not explain D."
        echo "                           It blocks the run-created control only; the same question"
        echo "                           is still open against a PRE-EXISTING empty directory in"
        echo "                           the hierarchy. The errno above is the measurement — record"
        echo "                           it, and do not carry another machine's errno to it."
    fi
    echo "  H1 MOUNTED, D REFUSED => the CoreSimulator HIERARCHY is not what refuses; something"
    echo "                           about the cache path itself is. Without H1 the A-vs-D"
    echo "                           contrast cannot tell those apart."
    echo "  H1 REFUSED            => /Library/Developer/CoreSimulator/ refuses mounting"
    echo "                           generally — a larger finding than 'this cache directory'."
    echo "  A REFUSED             => the session lost the ability to mount ANYWHERE before the"
    echo "                           trailing control ran. C is uninterpretable and so is the"
    echo "                           A-vs-D comparison. The whole run is void."
    echo "  A NOT MEASURED        => the run stopped before the trailing control, so nothing"
    echo "                           establishes the session could still mount at the end. Read"
    echo "                           no cell below B0."
    echo "  C NOT MEASURED        => the cache-path cell did not run; the matrix answers nothing"
    echo "                           about the question it was built for."
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
# Into the REPORT, after the redirect: the startup banners went to the terminal and the artifact
# carried no trace of being fabricated.
if [ "${XCV_DRYRUN:-0}" = 1 ]; then
    echo "################################################################################"
    echo "## THIS IS A DRY RUN. Every diskutil/hdiutil/mount/umount answer below came from"
    echo "## recording stubs. NOTHING WAS MOUNTED and NOTHING HERE MEASURES THIS MACHINE."
    echo "## Do not read it as evidence and do not commit it."
    echo "################################################################################"
fi
echo "donor: $MP ($XCV_DEV, $XCV_FS, whole disk $XCV_DONOR_DISK, UUID $XCV_DONOR_UUID)"
echo "owners on donor: $(diskutil info "$XCV_DEV" 2>/dev/null | sed -n 's/^ *Owners: *//p' | head -1)"
# The target's CONTENTS, recorded and guarded the way the probe's are. The 2026-09-22 run
# recorded only `stat`, so "the mount point was not empty" — a textbook DiskArbitration refusal
# that produces exactly diskutil's bare failure template — could not be ruled out for the one
# column that mattered. The probe has had both a guard and a record since the first draft; the
# target had neither.
TARGET_ENTRIES="$(ls -A "$TARGET" 2>/dev/null | wc -l | tr -d ' ')"
echo "cache target: $TARGET (entries: ${TARGET_ENTRIES:-?})"
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
xcv_stage_refuse_symlinked_path "$HPROBE" || exit 1
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

# The in-hierarchy control gets the same treatment as `$PROBE`: refuse anything already there,
# create it otherwise, and remove it only if this run created it.
if [ -e "$HPROBE" ]; then
    [ -d "$HPROBE" ] || { echo "!! $HPROBE exists and is not a directory. Refusing." >&3; exit 1; }
    mount | grep -q " on $(xcv_re_escape "$HPROBE") " \
        && { echo "!! something is already mounted at $HPROBE — an earlier run did not clean up. Refusing." >&3; exit 1; }
    [ -z "$(ls -A "$HPROBE" 2>/dev/null)" ] \
        || { echo "!! $HPROBE is not empty. Refusing to mount over it." >&3; exit 1; }
else
    # **A failure here is a MEASUREMENT, not a fatal error**, and the first version aborted the
    # whole run on it — losing, with the report it deleted, the one thing worth having: the
    # errno. On 2026-09-22 `mkdir` inside `/Library/Developer/CoreSimulator/` failed under
    # `sudo` and all that survived was "it failed". Record the error text and continue.
    #
    # `mkdir`, not `mkdir -p`, and one attempt only:
    #   - `-p` would create a missing `/Library/Developer/CoreSimulator` on a machine that has
    #     no Xcode, and cleanup removes only the leaf — a script-created shadow directory in the
    #     live hierarchy, which is the class rule 7 exists for. The parent must pre-exist for
    #     the cell to mean anything anyway.
    #   - a second attempt to capture stderr can succeed where the first failed, and would then
    #     write `REFUSED ()` into the evidence for an operation that worked, with `$HPROBE` left
    #     behind unowned and H1/H2 mounting over it past the checks above.
    if mkdir_err="$(mkdir "$HPROBE" 2>&1)"; then
        HPROBE_CREATED=1
    else
        # `-L` as well as `-e`: `[ -e ]` is false on a DANGLING symlink, which `mkdir` still
        # rejects with `File exists` — that would record a hierarchy refusal that is not one.
        # This line has no test and cannot get one: reaching it needs `mkdir` to fail with the
        # path present, which is a race, and `mkdir` is not stubbed in the dry-run harness.
        { [ -e "$HPROBE" ] || [ -L "$HPROBE" ]; } && { echo "!! $HPROBE appeared after a failed mkdir — this run does not own it. Refusing." >&3; exit 1; }
        echo "!!!! could not create $HPROBE: ${mkdir_err:-no error text}"
        echo "!!!! That is itself a result: the in-hierarchy control cannot be created at this"
        echo "!!!! privilege. It is a result about DIRECTORY CREATION and not about mounting —"
        echo "!!!! cell D was refused at a directory that already existed, so this does not"
        echo "!!!! explain D. H1/H2 could still be run against a PRE-EXISTING empty directory"
        echo "!!!! inside the hierarchy; that cell is not written."
        echo "!! $HPROBE could not be created — recorded as H0; the run continues." >&3
        H0_RECORDED=1
        CELLS="$CELLS
  H0. mkdir (not mount) inside /Library/Developer/CoreSimulator/: REFUSED — ${mkdir_err:-no error text}"
    fi
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


# cell <label> <device> <destination> <command...>
#
# The device is a parameter rather than `$XCV_DEV` because B0 mounts a different volume — its own
# throwaway image — and a hand-rolled copy of this function for B0 would be the fourth forked
# block in these scripts. The first draft did exactly that, and the copy lacked every protection
# below: no mounted-elsewhere detection, no verified teardown, no `DA_BYPASSED` participation, on
# the one cell whose REFUSED now carries the strongest conclusion in the matrix.
#
# Attempts one mount, verifies it took ANCHORED TO OUR DEVICE — `mount_apfs` exits 0 in cases where
# nothing is mounted, and "is something mounted here" would pass on a leftover from an aborted run —
# then unmounts so the next cell starts clean. Records PASS/FAIL into the matrix summary.
cell() {
    local label="$1" dev="$2" dest="$3"; shift 3
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
    where="$(mount | grep "^$(xcv_re_escape "$dev") on " || true)"
    echo "   mounts of $dev now: ${where:-<none>}"

    # `dest` of `ANYWHERE` is the one cell that does not name a destination: B3 asks DA to mount
    # wherever DA wants, so "it landed somewhere else" is the expected outcome rather than the
    # failure this branch exists to catch. Everything downstream — the teardown, the taint, the
    # listings — still works off `$where`.
    if [ "$dest" = ANYWHERE ]; then
        [ -n "$where" ] && dest="$(printf '%s' "$where" | head -1 | sed 's/^.* on //; s/ (.*$//')"
    elif [ -n "$where" ] && ! mount | grep -q "^$(xcv_re_escape "$dev") on $(xcv_re_escape "$dest") "; then
        echo "!!!! MOUNTED ELSEWHERE: the command did not refuse — it mounted somewhere other than"
        echo "!!!! $dest. Recording REFUSED would be a false reading, so nothing below was run."
        CELLS="$CELLS
  $label: MOUNTED ELSEWHERE, not at $dest"
        umount -f "$dev" >/dev/null 2>&1 || umount "$dev" >/dev/null 2>&1
        # Verified. If the stray survives, cleanup will NOT find it — its loop knows only $PROBE
        # and $TARGET — and worse, `diskutil info … Mounted: Yes` would then be satisfied by the
        # stray itself, so cleanup would conclude the donor was handed back and say nothing.
        local strays
        strays="$(mount | grep "^$(xcv_re_escape "$dev") on " || true)"
        if [ -n "$strays" ]; then
            echo "!!!! AND IT IS STILL MOUNTED: $strays"
            echo "!! $label mounted at an unexpected place AND could not be unmounted:" >&3
            echo "!!   $strays" >&3
            echo "!! Unmount it by hand before anything else: sudo umount -f $dev" >&3
        else
            echo "!! $label mounted somewhere other than $dest. Nothing below was run." >&3
        fi
        return 1
    fi

    if [ -n "$where" ]; then
        # The outcome as a VALUE, keyed on the cell's short id. The `case` that decides whether
        # cell C may keep `nobrowse` used to grep a display string out of `$CELLS`; the safety
        # property it protects — not mounting browsable over a real cache path — must not hang
        # on two copies of a human-readable label staying byte-identical.
        eval "CELL_RESULT_${label%%.*}=mounted"
        echo "-> MOUNTED at $dest"
        # The donor's root, seen through this cell's own mount. `shadow_check` compares once at
        # the end, and with A now running after C a change there can no longer be pinned on the
        # cell that caused it. This is that attribution, for free, while the evidence is live.
        # "volume root", not "donor root": B0 mounts a throwaway image, and this line sits in a
        # file whose shadow-data section is read for exactly that phrase.
        echo "   root of the mounted volume ($dev): $(ls -A "$dest" 2>/dev/null | sort | tr '\n' ' ')"
        CELLS="$CELLS
  $label: MOUNTED"
        # Again, immediately before the teardown. The listing above is taken the instant the
        # mount lands, before any daemon could react; this one is what the window produced. For
        # cell E it is the only record that survives, because its volume is detached and deleted.
        echo "   root after the window ($dev): $(ls -A "$dest" 2>/dev/null | sort | tr '\n' ' ')"

        # `diskutil unmount` first, and WHICH ONE WON is recorded. Going around DiskArbitration
        # with bare `umount` is a candidate cause of the 2026-09-21 void, so a teardown that falls
        # back to it taints every diskutil cell after it: reading such a cell's REFUSED as a fact
        # about macOS would be reading the fallback. E1b, the one `diskutil mount -mountPoint`
        # this project ever got to work, unmounted with `diskutil unmount`. Output is NOT
        # suppressed — a suppressed teardown is how you get a clean-looking control that was not.
        if xcv_run "unmount $dest via DiskArbitration" diskutil unmount "$dest"; [ "${XCV_LAST_EXIT:-1}" = 0 ]; then
            XCV_LAST_TEARDOWN=diskutil
        else
            echo "!!!! DiskArbitration declined the unmount; falling back OUTSIDE it."
            xcv_run "unmount $dest (fallback, bypasses DiskArbitration)" umount -f "$dest"
            XCV_LAST_TEARDOWN=umount-f
            DA_BYPASSED=1
        fi
        echo "   teardown: $XCV_LAST_TEARDOWN"
        if mount | grep -q "^$(xcv_re_escape "$dev") on $(xcv_re_escape "$dest") "; then
            echo "!!!! COULD NOT UNMOUNT $dest — stopping before the next cell mounts on top of it."
            echo "!! COULD NOT UNMOUNT $dest. Nothing below was run." >&3
            return 1
        fi
    else
        # The exit status matters in the summary, not just in the body. A cell refuses for
        # "Operation not permitted" and for "unknown option" alike, and the matrix line is the
        # artefact that travels into HYPOTHESES.md. A bare REFUSED there invites the reader to
        # assume the mount was refused when the invocation may simply have been wrong.
        eval "CELL_RESULT_${label%%.*}=refused"
        echo "-> REFUSED (nothing of ours is mounted at $dest; exit=${XCV_LAST_EXIT:-?})"
        # One predicate, used by both the taint and the log capture. Written twice in the first
        # draft — `case *diskutil*` here and `${label#*diskutil}` below — which is two chances to
        # drift apart and have the taint apply where the log does not, or the reverse.
        local is_da=0
        case "$label" in *diskutil*) is_da=1 ;; esac
        local taint=""
        [ "$is_da" = 1 ] && [ "${DA_BYPASSED:-0}" = 1 ] && taint=" — VOID: an earlier teardown bypassed DiskArbitration"
        [ -n "$taint" ] && echo "!!!!$taint"
        CELLS="$CELLS
  $label: REFUSED (exit ${XCV_LAST_EXIT:-?})$taint"

        # The reason, if there is one, is not in diskutil's output: its template for this failure
        # is the bare `Volume on %@ failed to mount`, with a `: "%@"` variant it did not use. So
        # the only place a cause exists is diskarbitrationd's log. Cheap, and it may end this in
        # one run instead of a third.
        # Bounded, and filtered to this run's own disks. Unfiltered, 60s of `diskarbitrationd`
        # names every volume it touched — including ones NOT mounted at redaction time, which
        # `xcv_redact` cannot see by its own stated limit, in a tracked and published file.
        if [ "$is_da" = 1 ]; then
            echo "## diskarbitrationd, last 60s, filtered to this run's disks (see ADR-0005: an"
            echo "## unfiltered dump would name volumes the redactor cannot detect)"
            # Captured first, then reported. `cmd | grep | tail || echo` takes the pipeline's
            # status from `tail`, which is 0 on empty input — so the fallback text never printed
            # and "nothing matched" looked identical to "the capture never ran".
            local da_log
            da_log="$(log show --last 60s --style compact --predicate 'process == "diskarbitrationd"' 2>/dev/null \
                | grep -E "$(xcv_re_escape "${XCV_DONOR_DISK:-__none__}")|$(xcv_re_escape "${dev#/dev/}")" \
                | tail -40)"
            if [ -n "$da_log" ]; then printf '%s\n' "$da_log"; else echo "   (no matching diskarbitrationd lines)"; fi
            echo
        fi
    fi
    return 0
}

# **Order, and why it is not the obvious one.** The diskutil cells run BEFORE `mount_apfs`. On
# 2026-09-21 the order was A-then-B and B failed; a `mount_apfs` mount torn down outside
# DiskArbitration is a candidate cause, so the mechanism under suspicion now runs first, with
# nothing before it.
#
# **`nobrowse` is isolated rather than assumed harmless.** B1 is E1b's call verbatim — the one
# `diskutil mount -mountPoint` this project has ever seen succeed. B2 adds `nobrowse`, which the
# 2026-09-21 run carried and E1b did not. Adding it to match `mount_apfs -o nobrowse` was meant to
# leave the mechanism as the only difference between the cells and instead departed from the only
# proven call; splitting it answers both questions instead of trading one confound for another.
# **B0, the control the first run did not have.** "B1 is E1b's call verbatim" is verbatim in argv
# only: E1b ran on macOS 26.6.2 (25G83) against a freshly created hdiutil sparse image, and this
# runs on 26.7 (25G229) against the operator's physical external donor. Either difference could be
# the whole story — DA on 26.7 refusing `-mountPoint` outside /Volumes, or refusing it for
# removable physical media — and either would be a FINDING, not a harness defect, while the
# reading rule would have filed it as "broken". So E1b is replicated first, on its own throwaway
# image, touching neither the donor nor the cache path.
#
#   B0 REFUSED             => something changed since 26.6.2. A real result, not a harness fault.
#   B0 MOUNTED, B1 REFUSED => it is the donor class, not the call.
# **Temp handling, spelled out.** The first draft wrote `B0_IMG="$(mktemp -d)/e6c-b0.sparseimage"`
# and had cleanup `rm -rf "$(dirname "$B0_IMG")"`. A failed `mktemp -d` — a full or unwritable
# TMPDIR, which is not hypothetical on this machine — makes that `rm -rf /`, as root, on every
# exit path. `set -u` does not catch an empty command substitution. So: capture the DIRECTORY,
# validate it, delete that variable and never a re-derived path, and skip B0 entirely rather
# than proceed with a half-built one.
B0_TMPDIR="$(mktemp -d 2>/dev/null)" || B0_TMPDIR=""
case "$B0_TMPDIR" in
    /*/*) [ -d "$B0_TMPDIR" ] || B0_TMPDIR="" ;;
    *) B0_TMPDIR="" ;;
esac

echo
echo "==================== B0. E1b replicated, on a throwaway image ===================="
if [ -z "$B0_TMPDIR" ]; then
    echo "!!!! could not create a temp directory; B0 is NOT MEASURED and B1's reading is weaker."
    CELLS="$CELLS
  B0. E1b replicated (sparse image): NOT MEASURED"
else
    B0_IMG="$B0_TMPDIR/e6c-b0.sparseimage"
    # A volume name unique to THIS run. The name is what the volume resolution matches on, and a
    # leftover `XCVB0` from a run that failed to detach would otherwise be a candidate — its
    # backing file already deleted, its mount therefore failing, and `cell` recording B0 REFUSED,
    # which the reading rule turns into "E1b's call no longer works on this OS build". A harness
    # artifact promoted to a finding about macOS, through the control added to prevent exactly
    # that. A per-run name makes a stale image unmatchable instead of merely unlikely.
    B0_NAME="XCVB0-$$"
    xcv_run "create a 512 MB APFS sparse image" hdiutil create -size 512m -fs APFS -volname "$B0_NAME" -type SPARSE "${B0_IMG%.sparseimage}"
    B0_CREATED_RC="${XCV_LAST_EXIT:-1}"
fi

# `hdiutil create`'s status, checked. On a full or unwritable volume — the documented state of
# this machine — it fails, and the block below would attach a path that does not exist and then
# fall through to a name match that can only find someone else's volume.
if [ -n "$B0_TMPDIR" ] && [ "${B0_CREATED_RC:-1}" != 0 ]; then
    echo "!!!! hdiutil create failed (exit ${B0_CREATED_RC:-?}); B0 is NOT MEASURED."
    echo "!! B0's image could not be created, so the control did not run." >&3
    CELLS="$CELLS
  B0. E1b replicated (sparse image): NOT MEASURED (hdiutil create failed)"
elif [ -n "$B0_TMPDIR" ]; then
    # `content-hint`, not `content`. Verified against live `hdiutil info -plist` on 2026-09-21:
    # every `system-entities` entry carries exactly `['content-hint', 'dev-entry']`, and `content`
    # is `None` for all of them. `e1b-mount-probe.sh:27` has the same `e.get("content")` and has
    # therefore ALWAYS fallen through to its `diskutil list` fallback — so "E1b's proven
    # extraction", the justification for reusing this code, was proven only in its fallback half.
    # The attach and the parse are SEPARATE statements, so the status belongs to `hdiutil` and
    # not to python3. Two traps here, both of which a one-liner walks into: the status of a
    # pipeline is its LAST command's, and `XCV_LAST_EXIT` is written only by `xcv_run` — reading
    # it after a plain command substitution returns the previous `xcv_run`'s value, which here
    # was `hdiutil create`, always 0 on this path. That made the attach-failure branch below
    # dead code in the round that added it.
    B0_PLIST="$(hdiutil attach -nomount -plist "$B0_IMG" 2>/dev/null)"
    B0_ATTACH_RC=$?
    B0_DEV="$(printf '%s' "$B0_PLIST" | plutil -convert json -o - - 2>/dev/null \
        | python3 -c 'import json, sys
# Both shapes. `hdiutil attach -plist` puts `system-entities` at the TOP level — which is why
# E1b reaches it with `plutil -extract system-entities` — while `hdiutil info -plist` nests it
# under `images`. A first draft of this filter handled only the nested one and was "verified"
# against `info` output, which is the wrong command: it would have resolved nothing here.
d = json.load(sys.stdin)
groups = [d] if isinstance(d, dict) and "system-entities" in d else d.get("images", [])
for g in groups:
    for e in g.get("system-entities", []):
        if (e.get("content-hint") or e.get("content")) == "GUID_partition_scheme":
            print(e["dev-entry"]); raise SystemExit
' 2>/dev/null)"
    B0_VOL="$(diskutil list 2>/dev/null | awk -v n="$B0_NAME" '$0 ~ ("APFS Volume " n "[ \t]") {print "/dev/"$NF}' | head -1)"

    # `APFS Physical Store`, NOT `Part of Whole`. For a disk-image APFS volume `Part of Whole` is
    # the SYNTHESIZED CONTAINER, not the attached image: measured on the donor, `/dev/disk9s1`
    # reports `Part of Whole: disk9` and `APFS Physical Store: disk8s1`, while `hdiutil info`
    # lists that image's entities as disk8 (GUID_partition_scheme), disk8s1, disk9, disk9s1. So
    # the container is disk9 and the thing `hdiutil detach` wants is disk8. The physical store
    # minus its slice is the image.
    B0_STORE="$(diskutil info "${B0_VOL:-__none__}" 2>/dev/null | sed -n 's/^ *APFS Physical Store: *//p' | head -1)"
    B0_STORE_DISK="${B0_STORE%s*}"
    [ -n "$B0_DEV" ] || [ -z "$B0_STORE_DISK" ] || B0_DEV="/dev/$B0_STORE_DISK"
    [ "$B0_DEV" = "/dev/" ] && B0_DEV=""
    echo "B0 image whole disk: ${B0_DEV:-<none>}   volume: ${B0_VOL:-<none>}   store: ${B0_STORE:-<none>}   name: $B0_NAME"
    # The two volumes' device class and ownership, side by side. The 2026-09-21 write-up ruled
    # out "kind of volume" as the difference between the donor and this image on a premise that
    # was in neither the evidence nor this script — which elsewhere frames the donor as the
    # operator's PHYSICAL external drive and calls media class a live candidate. Recorded rather
    # than assumed, so the next reading of B1 rests on something.
    # `$XCV_DEV`, not `$MP`: the donor was unmounted 250 lines ago, and `diskutil info` on a path
    # that is no longer a mount point exits 1 with `Could not find disk`, so every field came back
    # empty while the artifact looked measured. Worse, a stale `/Volumes/<name>` directory would
    # resolve to whatever owns that path — the one place in this file that identified a volume by
    # name instead of by device or UUID.
    for v in "$XCV_DEV" "${B0_VOL:-__none__}"; do
        # `sed -E`. BSD sed has no `\|` alternation in basic regex, so the first version matched
        # nothing and printed an empty row for both volumes — on the real machine as well as in
        # the harness, which is where it was caught.
        echo "-- $v: $(diskutil info "$v" 2>/dev/null | sed -nE 's/^ *(Protocol|Device Location|Removable Media|Owners|Virtual): */\1=/p' | tr '\n' ' ')"
    done

    # **Containment, asserted rather than assumed.** `$B0_DEV` comes from this run's own attach;
    # `$B0_VOL` comes from a global name scan. They are resolved independently and a disagreement
    # would be invisible — which is the last door on "B0 bound to a volume this run did not
    # create", after the per-run name closed the obvious one. The physical store must sit on the
    # disk we attached.
    #
    # It bites only when `$B0_DEV` came from the PLIST — that is the independent identity. On the
    # path where `$B0_DEV` was derived from the physical store instead, the comparison is a value
    # against itself and proves nothing; there is no second source to check it against, which is
    # why the plist path is the one that matters. This also covers the residual PID-reuse case: `$$` wraps, and a genuinely
    # stuck image plus a collision is the only way the name alone can lie.
    if [ "${B0_ATTACH_RC:-0}" != 0 ]; then
        echo "!!!! hdiutil attach failed (exit $B0_ATTACH_RC); B0 is NOT MEASURED rather than bound"
        echo "!!!! to whatever the name scan happens to find."
        B0_VOL=""
        CELLS="$CELLS
  B0. E1b replicated (sparse image): NOT MEASURED (hdiutil attach failed)"
    elif [ -n "$B0_VOL" ] && [ -n "$B0_DEV" ] && [ "${B0_STORE_DISK:-}" != "${B0_DEV#/dev/}" ]; then
        echo "!!!! CONTAINMENT FAILED: $B0_VOL sits on ${B0_STORE_DISK:-<unknown>}, not on the image"
        echo "!!!! this run attached (${B0_DEV#/dev/}). That volume is not ours. B0 is NOT MEASURED."
        echo "!! B0's volume did not resolve to this run's own image; the control did not run." >&3
        B0_VOL=""
        CELLS="$CELLS
  B0. E1b replicated (sparse image): NOT MEASURED (containment check failed)"
    fi

    if [ -z "$B0_DEV" ] && [ -n "$B0_VOL" ]; then
        echo "!!!! B0's volume resolved but its whole disk did NOT. The image cannot be detached"
        echo "!!!! automatically, so its backing file will be KEPT rather than deleted under a"
        echo "!!!! live device. Detach it by hand."
        echo "!! B0's image could not be resolved for detach; it is still attached." >&3
        echo "!!   detach it: hdiutil detach \$(diskutil info $B0_VOL | sed -n 's/.*Part of Whole: *//p')" >&3
    fi

    if [ -n "$B0_VOL" ]; then
        # Through `cell`, so B0 gets mounted-elsewhere detection, a VERIFIED teardown and the
        # DiskArbitration-bypass taint — all of which the hand-rolled first draft lacked, on the
        # cell whose REFUSED the reading rule now turns into a finding about the OS.
        cell "B0. E1b replicated, diskutil at the control dir (sparse image)" "$B0_VOL" "$PROBE" \
            diskutil mount -mountPoint "$PROBE" "$B0_VOL" || { XCV_RUN_FAILED=1; exit 1; }

        # **E — the cell the 2026-09-21 run turned into the decisive one.**
        #
        # That run split the question in two. `mount_apfs` with the donor mounted at the probe
        # (A) and was refused at the cache path (D): path-specific. DiskArbitration with a FRESH
        # image mounted at the probe (B0) and was refused with the DONOR at the same probe (B1,
        # status 0x4D): volume-specific, and it is why C is void — its control failed.
        #
        # So nothing yet says whether DiskArbitration can reach the cache path, because the only
        # volume DA has agreed to mount is B0's, and B0 never went there. This is that: B0's own
        # image, the one DA just accepted, at the real cache target. B0 is its control.
        #
        # **E0, the control E needs and B0 cannot be.** Running B0 is what destroys E's freshness:
        # by the time E runs, B0's image has itself been mounted and unmounted in this session —
        # which is the very property the leading candidate attributes B1's refusal to. So an
        # `E REFUSED` would be confounded between "the path refuses DA" and "DA refuses a volume
        # with a prior mount in this session". E0 is the same image at the same probe a second
        # time, and it separates them:
        #
        #   E0 REFUSED             => a second -mountPoint mount of the same volume is refused;
        #                             E is not run. Makes mount history a live explanation for
        #                             B1, not an established one — B1 is a different volume.
        #   E0 MOUNTED, E REFUSED  => history is ruled out; the cache path is what refuses. The
        #                             strongest form of (a) this experiment can produce.
        #   E MOUNTED              => the cache path IS reachable via DA, FOR A DISK-IMAGE VOLUME.
        #                             Not yet a product claim: E6b relocates to external storage,
        #                             and B1's refusal is still unexplained.
        #
        # Deliberately not reordered before B0: then B0 would be the second mount, and a history
        # refusal would print as "E1b's call no longer works on this OS build" — a false finding
        # about macOS, which is the error this whole experiment exists to avoid.
        if [ "$CELL_RESULT_B0" = mounted ]; then
            cell "E0. diskutil at the control dir AGAIN, same image (history control)" "$B0_VOL" "$PROBE" \
                diskutil mount -mountPoint "$PROBE" "$B0_VOL" || { XCV_RUN_FAILED=1; exit 1; }
        fi

        # `[ -d "$TARGET" ]` gets its OWN reason rather than being folded into the control gate:
        # an absent cache path is the state H14 is literally about, and reporting it as "no
        # control" beside a row saying B0 MOUNTED is a self-contradictory matrix.
        if [ "$CELL_RESULT_B0" = mounted ] && [ "$CELL_RESULT_E0" = mounted ] && [ ! -d "$TARGET" ]; then
            echo "!!!! the cache target does not exist, so cell E cannot be measured there."
            CELLS="$CELLS
  E. diskutil at the cache target, with B0's own image: NOT MEASURED (target absent)"
        fi

        # The target is re-guarded first: three mount cycles have passed since it was checked.
        if [ "$CELL_RESULT_B0" = mounted ] && [ "$CELL_RESULT_E0" = mounted ] && [ -d "$TARGET" ]; then
            echo
            echo "## re-checking the cache target immediately before cell E"
            xcv_run "stat $TARGET" stat -f 'type=%HT mode=%Sp owner=%Su:%Sg links=%l' "$TARGET"
            if xcv_stage_guard_target "$TARGET"; then
                # Browsable, like B0, because B0 is the control and a control that differs in a
                # flag is not one. The donor spends no time here; this is B0's throwaway image.
                echo "## NOTE: a BROWSABLE filesystem covers $TARGET for the duration of this cell."
                echo "## It is B0's 512 MB throwaway image, not the donor — but anything a daemon"
                echo "## writes during the window lands on it and is DESTROYED with it minutes later."
                echo "## The 'root after the window' listing is the only record that survives."
                echo "## Browsable to match B0, which is E's control."
                cell "E. diskutil at the cache target, with B0's own image" "$B0_VOL" "$TARGET" \
                    diskutil mount -mountPoint "$TARGET" "$B0_VOL" || { XCV_RUN_FAILED=1; exit 1; }
            else
                echo "!!!! the cache target no longer passes its guard; cell E was not run."
                CELLS="$CELLS
  E. diskutil at the cache target, with B0's own image: NOT MEASURED (target guard refused)"
            fi
        fi

        # **E0b — the rest of the control E0 only half provides.** E0 is the image's SECOND
        # mount; E is its THIRD attempt. A refusal rule monotone in mount depth — the obvious
        # shape for cached or leaked DiskArbitration state, which is exactly what the history
        # candidate posits — produces `E0 MOUNTED, E REFUSED` with the path playing no part, and
        # the matrix would print "H14 closes as unreachable" on it. E0b repeats the probe mount
        # AFTER E: a refused E contributed no successful mount, so E0b attempts at precisely E's
        # depth. "History is ruled out" needs E0 AND E0b.
        if [ "$CELL_RESULT_E0" = mounted ] && [ "$CELL_RESULT_E" != unmeasured ]; then
            cell "E0b. diskutil at the control dir a THIRD time (depth control for E)" "$B0_VOL" "$PROBE" \
                diskutil mount -mountPoint "$PROBE" "$B0_VOL" || { XCV_RUN_FAILED=1; exit 1; }
        fi
    else
        echo "!!!! could not resolve B0's volume; B0 is NOT MEASURED."
        CELLS="$CELLS
  B0. E1b replicated (sparse image): NOT MEASURED (volume did not resolve)"
    fi
    # E0 refused gets its OWN reason. The deferred recorder further down says "no control",
    # which beside a matrix row reading `B0 …: MOUNTED` is the self-contradictory matrix this
    # script warns about — and "B0 never mounted" and "the image stopped accepting a second
    # -mountPoint mount" are different findings. (A second recorder used to sit here and fired
    # first, printing the wrong one of the two.)
    if [ "$CELL_RESULT_B0" = mounted ] && [ "$CELL_RESULT_E0" = refused ]; then
        CELLS="$CELLS
  E. diskutil at the cache target, with B0's own image: NOT MEASURED (E0 refused: mount history)"
    fi

    if [ -n "$B0_DEV" ]; then
        xcv_run "detach B0's image" hdiutil detach "$B0_DEV"
        [ "${XCV_LAST_EXIT:-1}" = 0 ] && B0_DEV=""
    fi
fi

# E's absence recorded ONCE, below EVERY arm B0 can fail in — a failed `mktemp`, a failed
# `hdiutil create`, a failed attach, an unresolved volume, a refused mount, a refused E0. An
# earlier version sat inside the last of those, so the two arms above it produced a matrix
# stamped `complete` with no E row at all. A matrix that simply omits a cell is how a reader
# concludes it passed.
if [ "$CELL_RESULT_E" = unmeasured ]; then
    case "$CELLS" in
        *"E. diskutil at the cache target"*) ;;
        *)
            echo "!!!! cell E did not run: B0 or E0 gave it no control."
            CELLS="$CELLS
  E. diskutil at the cache target, with B0's own image: NOT MEASURED (no control)" ;;
    esac
fi

cell "B1. diskutil at the control dir (E1b's call verbatim)" "$XCV_DEV" "$PROBE" diskutil mount -mountPoint "$PROBE" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }

# **B3 — the cell the 2026-09-21 run was already performing and not recording.**
#
# That run's `shadow_check` remounted the donor with a PLAIN `diskutil mount` — no `-mountPoint`
# — and it SUCCEEDED, minutes after B1, B2 and C had all refused. The evidence shows it: the
# "donor root listing unchanged" branch is reachable only when the donor came back. So
# "DiskArbitration refuses this volume" was never true. What it refuses is this volume **with a
# custom mount point**, and that is a different and much narrower claim.
#
# Recorded as a measurement here instead of happening incidentally in cleanup, because a fact
# the experiment produces and does not count is a fact the next reader will not find.
echo
echo "## B3 mounts the donor WHERE DA WANTS IT, so the run must put it back afterwards."
cell "B3. diskutil with NO -mountPoint (the donor, DA's own choice of location)" "$XCV_DEV" ANYWHERE \
    diskutil mount "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }
cell "B2. diskutil at the control dir, WITH nobrowse" "$XCV_DEV" "$PROBE" diskutil mount nobrowse -mountPoint "$PROBE" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }

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

# **`nobrowse` at the cache target unless B2 says it cannot be.** A browsable donor mounted over
# a path `simdiskimaged` and CoreSimulatorService watch, with Spotlight free to index it, is a
# manufactured shadow-data event on the operator's own volume — rule 6, and E1b's evidence shows
# a browsable mount picking up `.fseventsd`. So: if B2 mounted, `nobrowse` is not the obstacle and
# C uses it. Only if B2 refused while B1 mounted does C drop it, because then asking the question
# with `nobrowse` would answer the wrong one.
case "$CELL_RESULT_B2" in
    mounted)
        echo "## B2 mounted, so nobrowse is not the obstacle: cell C keeps it."
        cell "C. diskutil at the cache target (nobrowse)" "$XCV_DEV" "$TARGET" \
            diskutil mount nobrowse -mountPoint "$TARGET" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }
        ;;
    *)
        echo "## B2 did not mount, so cell C drops nobrowse to ask the question with E1b's shape."
        echo "## NOTE: the donor is BROWSABLE over a real cache path for the duration of this cell."
        cell "C. diskutil at the cache target (browsable — see note)" "$XCV_DEV" "$TARGET" \
            diskutil mount -mountPoint "$TARGET" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }
        ;;
esac

# Last, deliberately: it already passed on 2026-09-21, and a `mount_apfs` mount torn down outside
# DiskArbitration is a candidate cause of that run's cell-B failure. Nothing depends on it running
# first. The guard on $PROBE has expired by now — four mount cycles — for the same reason the
# target is re-guarded above, so it is re-checked here.
xcv_stage_refuse_symlinked_path "$PROBE" || { XCV_RUN_FAILED=1; exit 1; }
if mount | grep -q " on $(xcv_re_escape "$PROBE") "; then
    echo "!!!! something is mounted at $PROBE after the diskutil cells; cell A would stack on it."
    echo "!! something is still mounted at $PROBE. Cell A was not run." >&3
    XCV_RUN_FAILED=1
    exit 1
fi
cell "A. mount_apfs at the control dir" "$XCV_DEV" "$PROBE" mount_apfs -o nobrowse "$XCV_DEV" "$PROBE" || { XCV_RUN_FAILED=1; exit 1; }

# **H1/H2 — the in-hierarchy control, and the cells that make the A-vs-D contrast mean what it
# is read to mean.** A mounts at `/Library/Developer/xcv-e6c-probe` and D was refused at
# `…/CoreSimulator/Cryptex/Caches`; those two differ in ownership, creator, depth, an xattr and
# emptiness as well as location, so the contrast cannot say whether it is the directory or the
# hierarchy. `$HPROBE` is run-created and empty like `$PROBE`, but inside
# `/Library/Developer/CoreSimulator/`.
#
#   H1 MOUNTED  => the hierarchy is not what refuses; something about the cache path itself is.
#   H1 REFUSED  => `/Library/Developer/CoreSimulator/` refuses mounting generally, which is a
#                  larger and more useful finding than "this one cache directory does".
#
# On 2026-09-22 the guard tripped before the cell could run: `mkdir` under
# `/Library/Developer/CoreSimulator/` failed under `sudo`, so the run-created form of this
# control could not be built. That is recorded as H0, and it settles LESS than it looks like.
# H0 is about creating a directory; D was refused at a directory that already existed, so H0
# does not explain D, and "the hierarchy refuses mounts" remains untested. The cell that would
# test it is H1/H2 against a PRE-EXISTING empty directory in the hierarchy, and it is not
# written. These two stay here for a machine where the mkdir succeeds.
if [ -d "$HPROBE" ]; then
    # The guard at the top of the run has expired here exactly as $PROBE's has — five mount
    # cycles have gone by — so re-check the same three things before mounting: not a symlink,
    # nothing mounted there, still empty.
    xcv_stage_refuse_symlinked_path "$HPROBE" || { XCV_RUN_FAILED=1; exit 1; }
    if mount | grep -q " on $(xcv_re_escape "$HPROBE") "; then
        echo "!!!! something is mounted at $HPROBE; H1 would stack on it."
        echo "!! something is mounted at $HPROBE. H1/H2 were not run." >&3
        XCV_RUN_FAILED=1
        exit 1
    fi
    if [ -n "$(ls -A "$HPROBE" 2>/dev/null)" ]; then
        echo "!!!! $HPROBE is not empty; mounting over it would hide its contents."
        echo "!! $HPROBE is no longer empty. H1/H2 were not run." >&3
        XCV_RUN_FAILED=1
        exit 1
    fi
    cell "H1. mount_apfs at a run-created dir INSIDE CoreSimulator" "$XCV_DEV" "$HPROBE" \
        mount_apfs -o nobrowse "$XCV_DEV" "$HPROBE" || { XCV_RUN_FAILED=1; exit 1; }
    cell "H2. diskutil at that same in-hierarchy dir" "$XCV_DEV" "$HPROBE" \
        diskutil mount -mountPoint "$HPROBE" "$XCV_DEV" || { XCV_RUN_FAILED=1; exit 1; }
else
    CELLS="$CELLS
  H1/H2. in-hierarchy control: NOT MEASURED (no probe directory; see H0 above if present)"
fi

shadow_check
matrix "complete"
exec >&3 2>&3
xcv_stage_write_evidence "$REPORT" "$out" || { XCV_RUN_FAILED=1; XCV_PUBLISH_FAILED=1; exit 1; }
echo "Next: record the matrix in HYPOTHESES.md (H14) and COMPATIBILITY_MATRIX.md."

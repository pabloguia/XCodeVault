#!/bin/bash
# E6b variant A — after a volume mounted at a CoreSimulator cache path is cleanly UNMOUNTED, what is
# left behind?
#
# **The question, and why it is worth an experiment.** Issue #24 added a guard to the cleanup verb on
# the strength of one sequence: a canonical mount lives at
# /Library/Developer/CoreSimulator/Caches/dyld; the verb refuses while it is mounted; after a
# disconnect a plain directory is there, the mount query truthfully says it is not a mount point, and
# the old code deleted its contents as an ordinary cache. Step two — that anything reappears at all,
# and with what owner and mode — is **inferred**. Nothing in docs/research/evidence/ records it
# (issue #29). The guard is correct either way, because an absent path returns "nothing to do" long
# before the record is read — so this measures whether the *bug* was ever reachable, and what the
# stub actually looks like if it is.
#
# This is the software half. The physical-yank half is `e6b-physical-disconnect.sh`, and a clean
# `umount` is not obviously the same event: both must be recorded before either is the answer.
#
# **This script carried four defects for months, and every one was found in its twin rather than
# here.** It gave `mount_apfs` a mount point instead of a device node, so the mount could never
# succeed and every probe would have read `absent` — the headline finding, manufactured. It had no
# boot-volume guard, so `/System/Volumes/Data` would have been accepted and unmounted. Its `mkdir -p`
# planted the "directory present, not a mount point" artifact that the reading guide calls the one
# outcome making #24's bug reachable, with no note and no cleanup. And it never gave the donor back.
# The staging is shared with variant B in `mount-staging.sh` now, because keeping two copies is
# exactly how this one was left behind while the runbook told people to run it first.
#
# Usage: sudo scripts/experiments/e6b-mount-stub-reappearance.sh /Volumes/<donor>
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/mount-staging.sh"

MP="$1"
# The target is a NAME from a closed set, never a path: this mounts a filesystem over the
# argument and later force-unmounts it, under sudo. `xcv_e6b_target` mirrors
# `HelperCleanupTarget`, so the experiment cannot stage over anything the product would not
# itself treat as regenerable.
TARGET_NAME="${2:-dyld}"
TARGET="$(xcv_e6b_target "$TARGET_NAME")" || {
    echo "!! unknown target '$TARGET_NAME'. Allowed: dyld, cryptex (see scripts/experiments/e6b-check.sh)."
    exit 2
}
# The target is in the FILENAME. Two runs against different targets are different findings —
# whether macOS recreates a directory can depend on which daemon owns the path — and a shared
# name would have one rotate the other away as though it superseded it.
out="$XCV_EVIDENCE_DIR/e6b-mount-stub-$TARGET_NAME-$(xcv_env_slug).txt"

[ -n "$MP" ] || { echo "usage: sudo $0 <donor-volume-mount-point> [dyld|cryptex]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "!! must run under sudo (mount_apfs/umount)"; exit 2; }
[ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; redaction cannot be verified. Use \`sudo\`, not \`sudo -i\`."; exit 2; }

# fd 3 is the terminal, opened before anything can fail: every refusal and every cleanup warning goes
# there, because stdout below becomes a report file that cleanup deletes.
exec 3>&1

xcv_stage_resolve_donor "$MP" || exit 1
xcv_stage_guard_target "$TARGET" || exit 1

REPORT="$(mktemp -t xcv-e6b-stub)"
# On a FAILED run the report is the only account of why, so it is kept — redacted, because it
# holds machine paths and the donor's UUID.
#
# It used to be deleted unconditionally. On 2026-09-21 `mount_apfs` refused and the operator got
# `!! MOUNT DID NOT TAKE … Nothing was recorded.` on the terminal while the line saying WHY went
# into the same `rm -f`. An experiment harness whose failure path destroys its own diagnosis is
# the shape this project already paid for once in `abort`, where a journal-write error replaced
# the removal error it was reporting.
cleanup() {
    # 1 = the report is safe to delete. Cleared only when it is the last copy of a failed run.
    local discard=1
    xcv_stage_cleanup "$TARGET"
    # The target is in the name for the same reason it is in `$out`: a failed dyld run and a
    # failed cryptex run are different findings, and a shared name would have one rotate the
    # other away as though it superseded it.
    if [ "${XCV_RUN_FAILED:-0}" = 1 ]; then
        # FAILED vs PUBLISH-FAILED. If the run completed and only the publish failed — a
        # rotation refusal, say — then this log is a *successful* experiment's evidence, and
        # filing it as FAILED would have the next reader discard a real finding.
        local why=FAILED
        [ "${XCV_PUBLISH_FAILED:-0}" = 1 ] && why=PUBLISH-FAILED
        local diag="$XCV_EVIDENCE_DIR/e6b-mount-stub-$TARGET_NAME-$why-$(xcv_env_slug).txt"
        # `-s` here as well as inside the writer: an empty report is nothing to preserve, and
        # "kept UNREDACTED at ..." pointing at an empty file is a false alarm.
        if [ -s "$REPORT" ] && ! xcv_stage_write_evidence "$REPORT" "$diag"; then
            discard=0
            # **Do not delete it.** The write just failed its own verification, so this temp file
            # is the only account of a run that, in variant B, cost an operator a physical cable
            # pull. Deleting the source after verification failed is the one thing this project
            # refuses to do anywhere else, and doing it here was how the harness came to destroy
            # its own diagnosis in the first place.
            #
            # It is UNREDACTED: it names the operator's account, home and donor. It is root-owned
            # under a private `mktemp` directory, which is where it has sat for the whole run
            # anyway; total loss is the worse end of that trade. Say both things out loud.
            echo "!! the log could NOT be redacted, so it was not published — see the messages above." >&3
            echo "!! it is kept UNREDACTED at $REPORT. Read it, then delete it; do not commit it." >&3
        fi
    fi
    [ "$discard" = 1 ] && rm -f "$REPORT"
    return 0
}
trap cleanup EXIT
# Split deliberately: bash runs an interrupt trap and then *resumes*, so a Ctrl-C used to fall
# through to the success epilogue and exit 0.
# An interrupt after staging is a failed run, not a quiet one: variant B's own header calls
# Ctrl-C at the cable prompt the likeliest interrupt here, and without this the record of
# what was mounted where goes with it.
# `trap - EXIT` first: bash runs the interrupt handler and then `exit 130` fires the EXIT
# trap, so `cleanup` ran twice. The second pass found the report already gone and told the
# operator its log could not be kept, seconds after telling them where it was written — on
# the single likeliest failure mode here.
trap 'XCV_RUN_FAILED=1; trap - EXIT; cleanup; exit 130' INT TERM HUP


exec >>"$REPORT" 2>&1

xcv_header "E6b variant A: what is left at $TARGET after a clean unmount"
echo "donor: $MP ($XCV_DEV, $XCV_FS, whole disk $XCV_DONOR_DISK, UUID $XCV_DONOR_UUID)"
xcv_stage_tcc_indicator 0
echo
echo "NOTE: this is the software variant. The physical-yank variant is the one issue #29 actually"
echo "describes, and a clean umount may well behave differently — record both before treating"
echo "either as the answer. See e6b-physical-disconnect.sh."
echo

xcv_stage_probe "$TARGET" "0. before anything"

echo
echo "==================== stage the mount ===================="
xcv_stage_mount "$TARGET" || { XCV_RUN_FAILED=1; exit 1; }
xcv_stage_probe "$TARGET" "1. while mounted (verified as $XCV_DEV)"

echo
echo "==================== unmount, then look immediately ===================="
xcv_run "umount" umount "$TARGET"
# Verified, for the same reason the mount is: `xcv_run` ends in `echo` and always returns 0, so its
# exit status says nothing. Probes labelled "after umount" over a still-mounted filesystem would be
# the same lie in the other direction.
if mount | grep -q " on $(xcv_re_escape "$TARGET") "; then
    echo "!!!! UNMOUNT DID NOT TAKE: something is still mounted at $TARGET. Nothing below was run."
    echo "!! UNMOUNT DID NOT TAKE. Nothing was recorded." >&3
    XCV_RUN_FAILED=1
    exit 1
fi
xcv_stage_probe "$TARGET" "2. immediately after umount"

echo
echo "==================== and after giving the system time to react ===================="
sleep 10
xcv_stage_probe "$TARGET" "3. ten seconds later"

echo
echo "==================== after a simulator service touches the path ===================="
# If anything recreates the stub, the likeliest agent is CoreSimulator itself. E9 recorded it
# rebuilding a Devices/ skeleton after a service restart, which is adjacent evidence for a different
# scenario — this asks the question directly for the dyld cache. As the user, not as root: root's
# CoreSimulatorService uses a different device set under /var/root.
xcv_run "simctl list runtimes (as $SUDO_USER)" sudo -u "$SUDO_USER" xcrun simctl list runtimes
sleep 5
xcv_stage_probe "$TARGET" "4. after simctl touched CoreSimulator"

echo
echo "==================== what this means for the issue #24 guard ===================="
echo "Read probes 2-4. The guard matters only if a *directory* is present and is NOT a mount point —"
echo "and if this run created that directory, the NOTE above says so and the reading is ambiguous."
echo "If every probe says 'absent', the cleanup verb returns \"nothing to do\" before it ever reads"
echo "its record, and the composition issue #24 describes was never reachable by this route — which"
echo "is a finding worth recording, not a disappointment."

# **Both** streams. `exec >>"$REPORT" 2>&1` redirected stdout *and* stderr into the report;
# restoring only stdout left every `>&2` in the epilogue writing into a file the EXIT trap
# then deletes. The leak check below would find the operator's account name in a file bound
# for a public repo, print "do not commit it" into the void, exit 1, and leave that file on
# disk — while the terminal showed `wrote <path>` and nothing else. The shape has four recorded
# appearances across these scripts — not four in this one; `scripts/experiments/test-common.sh` now pins it.
exec >&3 2>&3

# The whole epilogue is `xcv_stage_write_evidence`: rotate, redact, verify, hand over, and delete
# on any doubt. It used to be thirty lines duplicated here and in the sibling, which is how the
# `rm` on the redact-failure branch came to exist in one variant and not the other.
#
# A failure here marks the run FAILED so the EXIT trap keeps the log. Rotation failing used to
# discard a fully successful run — including, in variant B, one that cost an operator a physical
# cable pull.
xcv_stage_write_evidence "$REPORT" "$out" || { XCV_RUN_FAILED=1; XCV_PUBLISH_FAILED=1; exit 1; }

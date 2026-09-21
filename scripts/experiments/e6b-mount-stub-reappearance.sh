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
cleanup() {
    xcv_stage_cleanup "$TARGET"
    rm -f "$REPORT"
}
trap cleanup EXIT
# Split deliberately: bash runs an interrupt trap and then *resumes*, so a Ctrl-C used to fall
# through to the success epilogue and exit 0.
trap 'cleanup; exit 130' INT TERM HUP


exec >>"$REPORT" 2>&1

xcv_header "E6b variant A: what is left at $TARGET after a clean unmount"
echo "donor: $MP ($XCV_DEV, $XCV_FS, whole disk $XCV_DONOR_DISK, UUID $XCV_DONOR_UUID)"
echo
echo "NOTE: this is the software variant. The physical-yank variant is the one issue #29 actually"
echo "describes, and a clean umount may well behave differently — record both before treating"
echo "either as the answer. See e6b-physical-disconnect.sh."
echo

xcv_stage_probe "$TARGET" "0. before anything"

echo
echo "==================== stage the mount ===================="
xcv_stage_mount "$TARGET" || exit 1
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

# Rotate here, not at the top: every refusal above exits before this line, and rotating early would
# rename the previous evidence even for a run that recorded nothing.
xcv_rotate_out "$out" || exit 1
# All three failure paths remove the file, because the shell creates `$out` the moment it opens the
# redirection — before `xcv_redact` has written a byte. Without these `rm`s the script printed "NO
# evidence was written" while a file sat at the canonical path with the previous good evidence
# already renamed `-superseded-`; on the redact-failure branch that file can hold partial,
# UN-REDACTED output. The leak branch below was fixed one round earlier and these two were not,
# which is the same defect one branch up.
xcv_redact < "$REPORT" > "$out" || { rm -f "$out"; echo "!! redaction failed; NO evidence was written." >&2; exit 1; }
[ -s "$out" ] || { rm -f "$out"; echo "!! the redactor produced nothing; NO evidence was written." >&2; exit 1; }
# `$SUDO_USER`, not `$USER`: this runs under sudo, so `$USER` is root and the check would pass on a
# file full of the operator's name. `grep -c` on a missing file leaves this empty and `[ "" -gt 0 ]`
# fails, so the default below makes an unreadable count fatal rather than reassuring.
leaks=$(grep -cF "$SUDO_USER" "$out")
if [ "${leaks:-1}" -gt 0 ]; then
    # **Delete it.** Restoring the warning to the terminal was only half: the previous version wrote
    # the file, printed "wrote <path>", then found the operator's account name in it and exited 1 —
    # leaving that file in `docs/research/evidence/`, a tracked directory in a public repository,
    # with the previous good evidence already renamed to `-superseded-`. A leaking run left the tree
    # strictly worse than before it. `$leaks` counts LINES, not occurrences.
    rm -f "$out"
    echo "!! REDACTION FAILED: the account name is in the output ($leaks line(s)); NO evidence was written." >&2
    exit 1
fi
echo "wrote $out"
echo "redaction: ok"

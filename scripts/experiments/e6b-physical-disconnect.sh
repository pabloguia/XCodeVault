#!/bin/bash
# E6b variant B — what is left at a CoreSimulator cache path after the volume mounted there is
# PHYSICALLY disconnected.
#
# **Why a second script when variant A exists.** Variant A does a clean `umount`; the case issue #29
# describes is a surprise removal, and macOS may behave differently. The runbook has always said both
# must be recorded before either is treated as the answer. Variant B used to be seven steps to run by
# hand and paste into the evidence file — a transcription step between observation and record, in an
# issue that exists *because* a premise was written down without being observed.
#
# **The staging, the guards and the cleanup live in `mount-staging.sh`, shared with variant A.** That
# is not tidiness: three review rounds found that every fix landed in whichever variant was under
# review while its twin kept the defect, and the runbook sends people to the twin first.
#
# What is local to this script is the shape that kept letting it lie about what happened:
#
#   1. Output goes to a file, not through `{ ... } | xcv_redact`. In a pipeline `exit 1` leaves only
#      the subshell, so a refused run resumed and printed `wrote ...`, `redaction: ok` and
#      `Next: record the result in HYPOTHESES.md` — byte-identical to a completed one.
#   2. fd 3 is opened *before* the trap. When it was not, `cleanup`'s emergency messages were written
#      into the report file, which `cleanup` then deleted, so the operator saw nothing.
#   3. `INT`/`TERM`/`HUP` exit rather than resume. Bash runs an interrupt trap and then continues —
#      which is how Ctrl-C at the cable prompt, the likeliest interrupt here, still reached the
#      success epilogue.
#
# Usage: sudo scripts/experiments/e6b-physical-disconnect.sh /Volumes/<donor>
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
out="$XCV_EVIDENCE_DIR/e6b-physical-$TARGET_NAME-$(xcv_env_slug).txt"

[ -n "$MP" ] || { echo "usage: sudo $0 <donor-volume-mount-point> [dyld|cryptex]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "!! must run under sudo (mount_apfs/umount)"; exit 2; }
# Treat an unverifiable redaction as a failure, not as a pass. Under `sudo -i` or launchd this is
# empty, and `grep -c ""` counts every line — so the check at the end would report a leak on every
# run and be learned-to-ignore, which is worse than not having it.
[ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; redaction cannot be verified. Use \`sudo\`, not \`sudo -i\`."; exit 2; }

# fd 3 is the terminal. Opened before anything can fail, because every refusal below goes there.
exec 3>&1

xcv_stage_resolve_donor "$MP" || exit 1
xcv_stage_guard_target "$TARGET" || exit 1

REPORT="$(mktemp -t xcv-e6b-physical)"
cleanup() {
    xcv_stage_cleanup "$TARGET"
    rm -f "$REPORT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP


exec >>"$REPORT" 2>&1

xcv_header "E6b variant B: physical disconnect of a volume mounted at $TARGET"
echo "donor: $MP ($XCV_DEV, $XCV_FS, whole disk $XCV_DONOR_DISK, UUID $XCV_DONOR_UUID)"
echo
echo "Variant A (clean umount) is in e6b-mount-stub-reappearance.sh; both belong in HYPOTHESES.md"
echo "before either is treated as the answer."
echo

xcv_stage_probe "$TARGET" "0. before anything"

echo
echo "==================== stage the mount ===================="
xcv_stage_mount "$TARGET" || exit 1
xcv_stage_probe "$TARGET" "1. while mounted (verified as $XCV_DEV)"

echo
echo "==================== the physical act ===================="
{
    echo
    echo ">>> PHYSICALLY DISCONNECT $MP ($XCV_DEV) NOW."
    echo ">>> Pull the cable. Do NOT eject it first — the surprise is the point."
    echo ">>> Press Enter once it is out."
} >/dev/tty
read -r </dev/tty

# Verified, not taken on the operator's word. Pressing Enter without pulling — or pulling a different
# drive — would otherwise label the probes below "after the disconnect" while they describe a
# still-connected volume, in a file that will be cited in HYPOTHESES.md.
#
# Both the UUID and the node must be gone. The UUID is the identity that matters (checklist item 4);
# the node is checked too because `diskutil info` on either can fail for reasons other than absence,
# and requiring both to fail is the conservative direction — a false "still present" aborts the run,
# which loses an experiment, while a false "gone" would fabricate one.
observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! diskutil info "$XCV_DONOR_UUID" >/dev/null 2>&1 && ! diskutil info "$XCV_DEV" >/dev/null 2>&1; then
        observed=1
        break
    fi
    sleep 2
done
if [ "$observed" = 0 ]; then
    echo "!!!! DISCONNECT NOT OBSERVED: $XCV_DEV / $XCV_DONOR_UUID is still present after 20s."
    echo "!!!! Either the cable was not pulled, or a different drive was. Nothing below was run."
    echo "!! DISCONNECT NOT OBSERVED — the donor is still attached. Nothing was recorded." >&3
    exit 1
fi
echo "disconnect observed at $(date -u '+%Y-%m-%dT%H:%M:%SZ'): device node and UUID are both gone"

xcv_stage_probe "$TARGET" "2. immediately after the disconnect"
sleep 10
xcv_stage_probe "$TARGET" "3. ten seconds later"
sleep 50
xcv_stage_probe "$TARGET" "4. one minute later"

echo
echo "==================== after a simulator service touches the path ===================="
# As the user, not as root. The whole script runs under sudo, and root's CoreSimulatorService uses a
# different device set under /var/root — a different agent from the one whose behaviour is being
# measured, and it leaves state under an account nobody inspects.
xcv_run "simctl list runtimes (as $SUDO_USER)" sudo -u "$SUDO_USER" xcrun simctl list runtimes
sleep 5
xcv_stage_probe "$TARGET" "5. after simctl touched CoreSimulator"

echo
echo "==================== reconnect ===================="
{
    echo
    echo ">>> Reconnect the drive, wait for it to mount, then press Enter."
} >/dev/tty
read -r </dev/tty
echo "reconnected at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "where it came back:"
# `cmd | sed || echo` never reaches the echo: `||` binds to `sed`, which exits 0 on empty input. The
# reconnect outcome is exactly what issue #26 cares about, so it must be recorded either way.
# By UUID, and escaped. `grep -i "$(basename "$MP")"` was unanchored and unescaped, unlike every
# other pattern in these scripts — a donor named `Data` would have matched `/System/Volumes/Data`.
back="$(mount | grep -F " on $(diskutil info "$XCV_DONOR_UUID" 2>/dev/null | sed -n 's/^ *Mount Point: *//p' | head -1) ")"
if [ -n "$back" ]; then
    printf '%s\n' "$back" | sed 's/^/  /'
else
    echo "  (did not come back as a mount)"
fi
echo "  NOTE: /Volumes/<name> 1 is the shape ADR-0004 and issue #26 care about."
xcv_stage_probe "$TARGET" "6. after reconnect"

echo
echo "==================== reading this ===================="
echo "Probes 2-5 are the answer, and they exist only because the mount and the disconnect were both"
echo "verified — an unverified run aborts and records nothing rather than reporting 'absent'."
echo "The guard added for #24 matters only if a DIRECTORY is present and is NOT a mount point; if"
echo "this run created that directory the NOTE above says so, and the reading is ambiguous."
echo "If every probe says absent, the cleanup verb returns \"nothing to do\" before it ever reads its"
echo "record, and the composition #24 describes was never reachable by this route — a finding worth"
echo "recording, not a disappointment."

# **Both** streams. `exec >>"$REPORT" 2>&1` redirected stdout *and* stderr into the report;
# restoring only stdout left every `>&2` in the epilogue writing into a file the EXIT trap
# then deletes. The leak check below would find the operator's account name in a file bound
# for a public repo, print "do not commit it" into the void, exit 1, and leave that file on
# disk — while the terminal showed `wrote <path>` and nothing else. The shape has four recorded
# appearances across these scripts (this file is new, so not four of them here — the sentence
# was copied from variant A, which is the twin-divergence this shared staging exists to end).
# `scripts/experiments/test-common.sh` pins it now.
exec >&3 2>&3

# Rotate here, not at the top: every refusal above exits before this line, and rotating early
# renamed the previous evidence to `-superseded-` even for a run that recorded nothing.
xcv_rotate_out "$out" || exit 1
# All three failure paths remove the file, because the shell creates `$out` the moment it opens the
# redirection — before `xcv_redact` has written a byte. Without these `rm`s the script printed "NO
# evidence was written" while a file sat at the canonical path with the previous good evidence
# already renamed `-superseded-`; on the redact-failure branch that file can hold partial,
# UN-REDACTED output. The leak branch below was fixed one round earlier and these two were not,
# which is the same defect one branch up.
xcv_redact < "$REPORT" > "$out" || { rm -f "$out"; echo "!! redaction failed; NO evidence was written." >&2; exit 1; }
[ -s "$out" ] || { rm -f "$out"; echo "!! the redactor produced nothing; NO evidence was written." >&2; exit 1; }
# `grep -c` on a missing file leaves this empty, `[ "" -gt 0 ]` fails, and the old `||` then printed
# "redaction: ok" — a leak check that could not fail. `$out` is verified non-empty above, and the
# default below makes an unreadable count fatal rather than reassuring.
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
echo "Next: record the result in HYPOTHESES.md (H14) and COMPATIBILITY_MATRIX.md, then close #29."

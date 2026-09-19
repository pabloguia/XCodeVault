#!/bin/bash
# E6b — after a volume mounted at a CoreSimulator cache path goes away, what is left behind?
#
# **The question, and why it is worth an experiment.** Issue #24 added a guard to the cleanup verb
# on the strength of one sequence: a canonical mount lives at
# /Library/Developer/CoreSimulator/Caches/dyld; the verb refuses while it is mounted; after a
# disconnect a plain directory is there, the mount query truthfully says it is not a mount point,
# and the old code deleted its contents as an ordinary cache. Step two — that anything reappears at
# all, and with what owner and mode — is **inferred**. Nothing in docs/research/evidence/ records
# it (issue #29). The guard is correct either way, because an absent path returns "nothing to do"
# long before the record is read — so this measures whether the *bug* was ever reachable, and what
# the stub actually looks like if it is.
#
# This is the software half and it needs `sudo` (mount/umount). The physical-yank half is in
# docs/process/RUNBOOK-E6b-disconnect.md and cannot be scripted.
#
# Refuses to run unless the target path is empty or absent: mounting over a populated cache would
# hide real data, and unmounting would then look like the very reappearance being measured.
#
# Usage: scripts/experiments/e6b-mount-stub-reappearance.sh <external-volume-mount-point>
source "$(dirname "$0")/common.sh"
MP="$1"
TARGET="/Library/Developer/CoreSimulator/Caches/dyld"
out="$XCV_EVIDENCE_DIR/e6b-mount-stub-$(xcv_env_slug).txt"

[ -n "$MP" ] || { echo "usage: $0 <external-volume-mount-point>"; exit 2; }
mount | grep -q " on $MP " || { echo "!! $MP is not a mount point"; exit 1; }

# The target must be empty or absent. A populated dyld cache is regenerable, but hiding it under a
# mount and then measuring what is underneath afterwards would confuse the two states this is
# trying to tell apart.
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    echo "!! $TARGET is not empty. This experiment must not run over real cache contents:"
    echo "   the point is to distinguish 'macOS recreated a stub' from 'the old contents are still there'."
    echo "   Clear it first if you accept regenerating it — note that \`xcodevaultctl clean\` CANNOT:"
    echo "   the category is privilege: .root and the helper has no client (issue #30), so it lists"
    echo "   and stops. See docs/process/RUNBOOK-E6b-disconnect.md for the manual step, or run this"
    echo "   on a machine where the path is already empty."
    exit 1
fi

# `mountStatus` as the helper asks it, so the evidence answers the question the code actually asks
# rather than a proxy. `stat -f` prints the mount point of the filesystem containing a path.
probe() {
    local label="$1"
    echo "--- $label ---"
    if [ -e "$TARGET" ]; then
        # BSD stat: type, mode, owner, group, link count, device number.
        stat -f 'exists: type=%HT mode=%Sp owner=%Su:%Sg links=%l device=%d' "$TARGET"
        echo "containing filesystem mount point: $(stat -f '%SY' "$TARGET" 2>/dev/null || df "$TARGET" | awk 'NR==2{print $NF}')"
        echo "is a mount point per mount(8): $(mount | grep -c " on $TARGET ")"
        echo "entries: $(ls -A "$TARGET" 2>/dev/null | wc -l | tr -d ' ')"
    else
        echo "absent (this is the answer that makes issue #24's bug unreachable)"
    fi
}

cleanup() {
    mount | grep -q " on $TARGET " && sudo umount "$TARGET" 2>/dev/null
}
trap cleanup EXIT

{
    xcv_header "E6b: what is left at $TARGET after a volume mounted there goes away"
    echo "donor volume: $MP"
    echo
    echo "NOTE: this is the software variant (umount). The physical-yank variant is the one the"
    echo "issue actually describes, and a clean umount may well behave differently — record both"
    echo "before treating either as the answer. See docs/process/RUNBOOK-E6b-disconnect.md."
    echo

    probe "0. before anything"

    echo
    echo "==================== mount the donor volume over the cache path ===================="
    sudo mkdir -p "$TARGET"
    xcv_run "mount" sudo mount_apfs -o nobrowse "$MP" "$TARGET" \
        || xcv_run "mount (fallback: bind via mount -t nullfs is unavailable on macOS; recording the failure)" true
    probe "1. while mounted"

    echo
    echo "==================== unmount, then look immediately ===================="
    xcv_run "umount" sudo umount "$TARGET"
    probe "2. immediately after umount"

    echo
    echo "==================== and after giving the system time to react ===================="
    sleep 10
    probe "3. ten seconds later"

    echo
    echo "==================== after a simulator service touches the path ===================="
    # If anything recreates the stub, the likeliest agent is CoreSimulator itself. E9 recorded it
    # rebuilding a Devices/ skeleton after a service restart, which is adjacent evidence for a
    # different scenario — this asks the question directly for the dyld cache.
    xcv_run "simctl list runtimes" xcrun simctl list runtimes
    sleep 5
    probe "4. after simctl touched CoreSimulator"

    echo
    echo "==================== what this means for the issue #24 guard ===================="
    echo "Read probes 2-4. The guard matters only if a *directory* is present and is NOT a mount"
    echo "point. If every probe says 'absent', the cleanup verb returns 'nothing to do' before it"
    echo "ever reads its record, and the composition issue #24 describes was never reachable by"
    echo "this route — which is a finding worth recording, not a disappointment."
} 2>&1 | xcv_redact > "$out"

echo "wrote $out"
grep -c "$USER" "$out" | awk '{ if ($1 > 0) print "!! REDACTION FAILED: the account name appears " $1 " time(s)"; else print "redaction: ok" }'

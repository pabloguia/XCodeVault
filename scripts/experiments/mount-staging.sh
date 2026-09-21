#!/bin/bash
# Shared staging for the two E6b variants: resolve a donor, refuse the dangerous ones, mount it over
# a target path, verify it took, and give everything back afterwards.
#
# **Why this exists rather than two copies.** Variant A and variant B do the same staging and
# differ only in how the volume goes away — a clean `umount` versus a pulled cable. They were
# separate copies, and three review rounds showed what that costs: every fix landed in the variant
# under review and the sibling kept the defect. `mount_apfs` was given a mount point instead of a
# device node in both; the boot-volume guard, the "did the mount take" check, the created-directory
# ambiguity note and the donor remount were added to B and missing from A — while the runbook told
# people to run A first. This file is the fix for that, not for any one bug.
#
# Deliberately not named `e*.sh`: `ExperimentScriptSafetyTests` requires every experiment script to
# source `common.sh` and use its header/redaction helpers, and this is a library like `common.sh`
# itself, not an experiment.
#
# Callers must have sourced `common.sh` first, and must have opened fd 3 on the terminal — every
# refusal and warning here goes to `>&3`, because the caller's stdout is a report file that this
# code's own cleanup may delete.

# Self-defending rather than merely documented: a caller that forgets `exec 3>&1` would get a
# bad-fd write on every refusal while `return 1` still fired — a silent refusal, the same shape
# one level up. Falling back to stderr keeps the message somewhere a person reads.
{ true >&3; } 2>/dev/null || exec 3>&2

XCV_STAGE_TARGET_CREATED=0
XCV_STAGE_DONOR_UNMOUNTED=0
XCV_STAGE_CLEANED=0

xcv_whole_disk() { diskutil info "$1" 2>/dev/null | sed -n 's/^ *Part of Whole: *//p' | head -1; }

# xcv_stage_resolve_donor <mount-point>
#
# Sets XCV_DEV, XCV_FS, XCV_DONOR_UUID, XCV_DONOR_DISK. Refuses anything that must never be yanked.
xcv_stage_resolve_donor() {
    local mp="$1"

    # Only an external volume. `e6b-check.sh` excludes the boot volume from what it *offers*; the
    # scripts that actually `diskutil unmount` had no equivalent guard, and a reviewer showed that
    # `/System/Volumes/Data` cleared every check — mount point, device node, APFS. The script would
    # have unmounted the internal data volume and asked the operator to pull the internal disk.
    case "$mp" in
        "$XCV_VOLUMES_DIR"/*) ;;
        *)
            echo "!! $mp is not under $XCV_VOLUMES_DIR. Only an external volume can be a donor." >&3
            return 1
            ;;
    esac
    mount | grep -q " on $(xcv_re_escape "$mp") " || { echo "!! $mp is not a mount point" >&3; return 1; }

    # `mount_apfs` takes a device special node (`/dev/diskNsM`), not a mount point. Both variants
    # passed the mount point for months, so the mount could never succeed — and `xcv_run` cannot
    # report that, because it ends in `echo` and always returns 0.
    XCV_DEV="$(diskutil info "$mp" 2>/dev/null | sed -n 's/^ *Device Node: *//p' | head -1)"
    XCV_FS="$(diskutil info "$mp" 2>/dev/null | sed -n 's/^ *File System Personality: *//p' | head -1)"
    XCV_DONOR_UUID="$(xcv_volume_uuid "$mp")"
    XCV_DONOR_DISK="$(xcv_whole_disk "$mp")"
    XCV_DONOR_MP="$mp"
    XCV_DONOR_LABEL="${mp##*/}"

    [ -n "$XCV_DEV" ] || { echo "!! could not resolve a device node for $mp" >&3; return 1; }
    # Required, not optional: `diskutil info ""` exits 1, so an empty UUID makes a later
    # `! diskutil info "$uuid"` test vacuously true and silently degrades identity to the device
    # node — the half that is unreliable across a reconnect.
    [ -n "$XCV_DONOR_UUID" ] \
        || { echo "!! could not read a volume UUID for $mp; identity would rest on a reusable device node." >&3; return 1; }
    case "$XCV_FS" in
        *APFS*) ;;
        *) echo "!! $mp is $XCV_FS, not APFS; mount_apfs cannot mount it. Use an APFS donor." >&3; return 1 ;;
    esac
    # A synthesised APFS container can expose a volume under /Volumes that lives on the same
    # physical disk as `/`.
    local boot
    boot="$(xcv_whole_disk /)"
    [ -n "$boot" ] && [ "$XCV_DONOR_DISK" = "$boot" ] \
        && { echo "!! $mp is on $XCV_DONOR_DISK, the same physical disk as /. Refusing." >&3; return 1; }

    # Last moment the donor is guaranteed mounted. Arm the redactor here rather than leaving it to
    # each caller: a caller that forgets publishes the donor's UUID, and there is no later point
    # at which the omission is visible.
    xcv_stage_arm_redaction
    return 0
}

# xcv_stage_arm_redaction
#
# Hand `xcv_redact` the donor's identity from values held here, so a transcript filtered AFTER the
# donor is gone is still redacted. Called at the end of donor resolution, which is the last moment
# the donor is guaranteed mounted; `xcv_redact`'s own detection loop cannot see it after that.
# Without this, every E6b report named the donor's label and UUID in the clear, in a file bound for
# a tracked directory — the success paths as much as the failure paths, because staging unmounts
# the donor from /Volumes before it mounts it over the target.
xcv_stage_arm_redaction() {
    XCV_REDACT_ALSO_LABEL="$XCV_DONOR_LABEL"
    XCV_REDACT_ALSO_UUID="$XCV_DONOR_UUID"
    export XCV_REDACT_ALSO_LABEL XCV_REDACT_ALSO_UUID
}

# xcv_stage_guard_target <target>
xcv_stage_guard_target() {
    local target="$1"
    if mount | grep -q " on $(xcv_re_escape "$target") "; then
        echo "!! Something is already mounted at $target. Staging over it would hide it, and cleanup" >&3
        echo "   would force-unmount someone else's filesystem — possibly this product's own vault." >&3
        return 1
    fi
    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        echo "!! $target is not empty. Run scripts/experiments/e6b-check.sh, which explains this and" >&3
        echo "   what clearing the cache costs." >&3
        return 1
    fi
    # A *session*, not CoreSimulator's launchd XPC services: those are on-demand, present on any
    # machine that has ever booted a simulator, and probe 5 deliberately restarts one. Matching them
    # by the substring "Simulator" is why an earlier version could never have run anywhere.
    if pgrep -qx "xcodebuild|Xcode|Simulator"; then
        echo "!! An Xcode, Simulator or xcodebuild session is running. This machine's simulators are" >&3
        echo "   used by test rigs, so check whose it is before stopping anything." >&3
        return 1
    fi
    return 0
}

# xcv_stage_mount <target>
#
# Unmounts the donor, creates the target if needed, mounts, and VERIFIES that our filesystem is the
# one mounted there. Writes its narration to stdout (the caller's report).
xcv_stage_mount() {
    local target="$1"
    xcv_run "unmount donor from its mount point" diskutil unmount "$XCV_DEV"
    XCV_STAGE_DONOR_UNMOUNTED=1
    if [ ! -d "$target" ]; then
        # **Recorded, because it changes what a probe means.** "Directory present, not a mount
        # point" is the one outcome that makes issue #24's bug reachable — and if this run created
        # the directory, that reading is ambiguous between a macOS-recreated stub and our own mkdir
        # showing through. Variant A planted it with no note at all, which made its headline finding
        # a foregone conclusion.
        mkdir -p "$target"
        XCV_STAGE_TARGET_CREATED=1
        echo "NOTE: $target did not exist and was created by this run. A later probe reporting a"
        echo "      directory that is not a mount point is therefore AMBIGUOUS — it may be this mkdir."
    fi
    xcv_run "mount $XCV_DEV at $target" mount_apfs -o nobrowse "$XCV_DEV" "$target"

    # Anchored to OUR device. Asking "is something mounted there" would pass on a leftover mount
    # from an aborted run while `mount_apfs` had in fact failed.
    if ! mount | grep -q "^$(xcv_re_escape "$XCV_DEV") on $(xcv_re_escape "$target") "; then
        echo "!!!! MOUNT DID NOT TAKE: $XCV_DEV is not mounted at $target. Nothing below was run."
        echo "!! MOUNT DID NOT TAKE — $XCV_DEV is not mounted at $target. The experiment recorded nothing;" >&3
        echo "!! the run log is kept so the reason is not lost with it — see the path printed on exit." >&3
        return 1
    fi
    return 0
}

# xcv_stage_cleanup <target>
#
# Idempotent. Unmounts the staged filesystem, removes a directory this run created, and gives the
# donor back — reporting loudly on the terminal if it cannot do any of it.
xcv_stage_cleanup() {
    local target="$1"
    [ "$XCV_STAGE_CLEANED" = 1 ] && return 0
    XCV_STAGE_CLEANED=1

    if mount | grep -q " on $(xcv_re_escape "$target") "; then
        # Force first: a plain `umount` against a yanked device can block with no timeout, so a
        # `-f` *fallback* may never be reached.
        umount -f "$target" 2>/dev/null || umount "$target" 2>/dev/null || true
    fi
    if mount | grep -q " on $(xcv_re_escape "$target") "; then
        echo "!! COULD NOT UNMOUNT $target. A filesystem is still mounted over a system cache path." >&3
        echo "!! Unmount it before using Xcode or the simulators: sudo umount -f $target" >&3
    fi
    if [ "$XCV_STAGE_TARGET_CREATED" = 1 ] && [ -d "$target" ] && [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
        rmdir "$target" 2>/dev/null || echo "!! could not remove the $target directory this run created" >&3
    fi
    # By UUID first: a device node is reused after a reconnect, which is exactly the moment this
    # runs in variant B.
    if [ "$XCV_STAGE_DONOR_UNMOUNTED" = 1 ]; then
        if diskutil info "$XCV_DONOR_UUID" >/dev/null 2>&1 || diskutil info "$XCV_DEV" >/dev/null 2>&1; then
            # By UUID for the "is it already back?" test too. Asking by node here, two lines above a
            # remount that deliberately prefers the UUID, meant a renumbered donor read as "not back"
            # and the node fallback below could then mount whatever now holds that node.
            diskutil info "$XCV_DONOR_UUID" 2>/dev/null | grep -q "Mounted: *Yes" \
                || diskutil mount "$XCV_DONOR_UUID" >/dev/null 2>&1 \
                || echo "!! YOUR DONOR VOLUME IS STILL UNMOUNTED. Remount it: diskutil mount $XCV_DONOR_UUID" >&3
        fi
    fi
}

# xcv_stage_probe <target> <label>
#
# The probe both variants write. It was duplicated, and by the time a reviewer looked it had already
# drifted — variant A printed `containing filesystem` third and variant B fourth, so the two evidence
# files could not be read side by side, which is the one thing you want when both must be read
# together before either is the answer. That is the divergence this file exists to end, and probe()
# was the block it had not absorbed.
# **Two false claims stood in variant A's copy of this**, and they are recorded because the second
# was the fix for the first. It claimed to ask "`mountStatus` as the helper asks it": it does not —
# the helper uses `ATTR_DIR_MOUNTSTATUS` through `MountStatus`, while this parses `mount(8)` and
# `df`. The replacement claimed `stat -f %SY` prints the containing filesystem's mount point: `%Y` is
# a *symlink target*, and on a directory it prints nothing and exits 0 — so the `|| df` fallback
# could never fire and the field was empty in every run that script would ever have produced. It is
# the only field naming which filesystem the target sits on, which is the whole difference between
# "a stub on the internal disk" and "the donor is still there".
xcv_stage_probe() {
    local target="$1"
    echo "--- $2 ---"
    if [ -e "$target" ]; then
        stat -f '  exists: type=%HT mode=%Sp owner=%Su:%Sg links=%l device=%d' "$target"
        echo "  containing filesystem: $(df "$target" 2>/dev/null | awk 'NR==2{print $1" on "$NF}')"
        echo "  is a mount point per mount(8): $(mount | grep -c " on $(xcv_re_escape "$target") ")"
        echo "  entries: $(ls -A "$target" 2>/dev/null | wc -l | tr -d ' ')"
    else
        echo "  absent"
    fi
}

# xcv_stage_write_evidence <report> <out>
#
# The one way either variant turns a run log into a file in `docs/research/evidence/`. Redacts,
# verifies, and only then puts anything at the tracked path. Diagnostics go to fd 3; returns
# non-zero if nothing was written, and in that case `$out` is exactly as it was before the call.
#
# **Why a helper and not two copies.** This is the fourth shape that existed twice in these
# scripts and was fixed once — see the header. It is also where every historical redaction defect
# landed, so it has to be one place: `[ -s ]` cannot see a redactor that ran successfully and
# produced unredacted output, which is what every one of those defects looked like. The
# account-name check below is load-bearing; `test-common.sh` sources this file and pins it.
#
# **Verify in a temp file, then move.** Every earlier version rotated first and wrote straight to
# `$out`, so the shell created the file the moment the redirection opened — before `xcv_redact`
# had written a byte — and the previous good evidence was already renamed `-superseded-`. A
# failing run left a partial and possibly UN-REDACTED file at the canonical path, with the good
# evidence only reachable under a different name; the three `rm -f`s that patched that were
# themselves the thing that differed between the two variants. Redacting into a `mktemp` and
# moving it into place after the checks retires the whole class: no partial or unredacted byte
# ever exists at the tracked path, and a failed check rotates nothing, so the previous evidence
# stays under its own name. One window survives and is named rather than glossed: if rotation
# succeeds and the `mv` then fails, the previous evidence is reachable only as `-superseded-`.
# Nothing partial is published even then, which is the property that mattered.
xcv_stage_write_evidence() {
    local report="$1" out="$2" tmp leaks rc=1

    # Defence in depth, and said accurately: this used to be the thing that made a re-entrant
    # `cleanup` safe, back when rotation happened first. It no longer is — nothing is rotated or
    # created until every check has passed, so an empty report is refused by the `-s "$tmp"` check
    # below whether this line is here or not, and deleting it kills no test. It stays because it
    # names the condition, and because a caller reading a refusal wants "there is no run log", not
    # "the redactor produced nothing".
    [ -s "$report" ] || { echo "!! there is no run log to write." >&3; return 1; }

    # Not `${SUDO_USER:-}`: `grep -cF ""` matches every line, so an unset account name would
    # delete the evidence and report "the account name is in the output" — fail-closed, but naming
    # the wrong cause. Both variants refuse an empty SUDO_USER at startup; this is library code and
    # says so itself rather than relying on that.
    [ -n "${SUDO_USER:-}" ] || { echo "!! SUDO_USER is empty; redaction cannot be verified. NO evidence was written." >&3; return 1; }

    tmp="$(mktemp -t xcv-evidence)" || { echo "!! could not create a temp file; NO evidence was written." >&3; return 1; }

    while :; do
        # `2>&3`: on a failure path the caller has not yet restored the terminal, so fd 2 is still
        # the report this function is reading — sed's own stderr would append into its input, and
        # the reason for a failure would land in a file the caller then deletes.
        xcv_redact < "$report" > "$tmp" 2>&3 || { echo "!! redaction failed; NO evidence was written." >&3; break; }
        [ -s "$tmp" ] || { echo "!! the redactor produced nothing; NO evidence was written." >&3; break; }

        # `$SUDO_USER`, not `$USER`: this runs under sudo, so `$USER` is root and the check would
        # pass on a file full of the operator's name. `grep -c` on an unreadable file leaves this
        # empty and `[ "" -gt 0 ]` fails, so the default makes that fatal rather than reassuring.
        # It counts LINES, not occurrences.
        leaks=$(grep -cF "$SUDO_USER" "$tmp")
        if [ "${leaks:-1}" -gt 0 ]; then
            echo "!! REDACTION FAILED: the account name is in the output ($leaks line(s)); NO evidence was written." >&3
            break
        fi

        # Only now is there anything worth keeping, so only now is the previous evidence renamed.
        # `2>&3` for the same reason as above: `xcv_rotate_out` reports refusals on fd 2.
        # Symmetric with the account-name gate above, and for the leak this whole change exists to
        # close. `xcv_redact` has a rule for the donor (`XCV_REDACT_ALSO_UUID`) and the wiring is
        # pinned by two source checks — but wiring checks police the call, not the outcome. A UUID
        # is a fixed string that never legitimately appears in evidence, so it can be gated the
        # same way the account name is.
        if [ -n "${XCV_DONOR_UUID:-}" ] && grep -qF "$XCV_DONOR_UUID" "$tmp"; then
            echo "!! REDACTION FAILED: the donor volume UUID is in the output; NO evidence was written." >&3
            break
        fi

        xcv_rotate_out "$out" 2>&3 || break
        # `mv`, never `cp`, and measured rather than assumed: forced onto a full volume on
        # 2026-09-21, `cp` failed and left 8 MB of a truncated file at the destination — the
        # previous content destroyed by the open — while `mv` failed and left the destination
        # unlinked. On macOS `mv` uses fastcopy and unlinks the destination on a write error, so
        # the tracked path keeps nothing rather than something partial. Same-filesystem, `mv` is
        # an atomic rename(2) and `cp` is not. `test-common.sh` pins the call shape.
        mv "$tmp" "$out" || { echo "!! could not move the redacted evidence into place; NO evidence was written." >&3; break; }

        # Root wrote it; the operator has to be able to delete or amend it without sudo. Same as
        # `e1b-mount-probe.sh`. Best-effort: a file that exists is worth more than one refused over
        # its owner.
        chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$out" 2>/dev/null
        echo "wrote $out" >&3
        echo "redaction: ok" >&3
        rc=0
        break
    done

    rm -f "$tmp"
    return "$rc"
}

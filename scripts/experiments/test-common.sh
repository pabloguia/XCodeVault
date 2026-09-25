#!/bin/bash
# Tests for the helpers in common.sh, and for xcv_redact above all.
#
# Every defect xcv_redact has ever shipped was invisible by inspection and obvious under a test:
# a home containing a space silently truncated, a short account name eating the words around it,
# SUDO_USER obeyed outside a sudo session. Those three are regression cases here. So is the
# publication extension (ADR-0005), because a redactor is only as good as the case nobody thought
# of, and the cost of a miss is now permanent rather than local.
#
# Run: bash scripts/experiments/test-common.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./common.sh

fails=0
run=0
check() {  # check <name> <expected> <actual>
    run=$((run + 1))
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}
redact() { printf '%s\n' "$1" | xcv_redact; }

# ---- fixture -----------------------------------------------------------------------------------
# A fixture volumes directory stands in for /Volumes so the result does not depend on what happens
# to be plugged into the machine running the tests.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/volumes/VAULT" "$FIX/volumes/Backup" "$FIX/volumes/Weird.Name+1" \
         "$FIX/volumes/Trailing." "$FIX/volumes/My"
ln -s / "$FIX/volumes/BootName"
export XCV_VOLUMES_DIR="$FIX/volumes"

# A synthetic UUID, deliberately. Hard-coding a real one would put back into the tree the value
# this helper exists to take out — and the redaction would then rewrite the fixture itself,
# leaving the assertion passing for the wrong reason.
xcv_volume_uuid() {
    case "${1##*/}" in
        VAULT) echo "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D" ;;
        Backup) echo "BBBBBBBB-1111-2222-3333-444444444444" ;;
        *) echo "" ;;
    esac
}
T_USER=dev
T_HOME=/Users/dev
xcv_identity() { printf '%s\n%s\n' "$T_USER" "$T_HOME"; }

# ---- the identity, including the three defects that shipped once ---------------------------------
check "home directory is redacted" \
    "~/Library/Developer" "$(redact "/Users/dev/Library/Developer")"

T_HOME="/Users/two words"
check "a home containing a space is not truncated at the space" \
    "~/Library" "$(redact "/Users/two words/Library")"
T_HOME=/Users/dev

check "a short account name does not eat the words containing it" \
    "devicectl ran as <user>" "$(redact "devicectl ran as dev")"

T_USER=root
T_HOME=/var/root
check "the word root is a subject, not an identity: only the home is redacted" \
    "root-owned file at ~/x" "$(redact "root-owned file at /var/root/x")"
T_USER=dev
T_HOME=/Users/dev

# ---- volumes: the publication extension ----------------------------------------------------------
check "a volume label is redacted in path form" \
    "/Volumes/<vault>/XCodeVault" "$(redact "/Volumes/VAULT/XCodeVault")"

check "a volume label is redacted standing alone" \
    "Volume <vault> on disk3s1 force-unmounted" "$(redact "Volume VAULT on disk3s1 force-unmounted")"

check "a volume label does not eat a longer word containing it" \
    "the VAULTED archive" "$(redact "the VAULTED archive")"

check "a volume UUID is redacted" \
    "Volume UUID: <vault-uuid>" "$(redact "Volume UUID: A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")"

check "the boot volume is redacted, and marked as the boot volume" \
    "/Volumes/<bootvolume>/Users" "$(redact "/Volumes/BootName/Users")"

# The boot volume's BARE label. This half of the rule was missing until 2026-09-18: only the
# `/Volumes/` form was redacted, so a boot volume named after its owner — which is the default on
# a Mac set up with a personal name — was published verbatim in every evidence file. The Swift
# redactor had it right (`(?<!/)` in Redaction.swift); the shell one did not, while
# Redaction.swift's header claimed the two were kept in step.
check "the boot volume's bare label is redacted, not only its /Volumes/ form" \
    "volumeName: <bootvolume>" "$(redact "volumeName: BootName")"
check "the boot volume's bare label is redacted in prose" \
    "the <bootvolume> volume is full" "$(redact "the BootName volume is full")"
check "the boot volume's bare label is redacted when it is the whole line" \
    "<bootvolume>" "$(redact "BootName")"

# And the reason the bare-label rule was left out in the first place, which must stay true: the
# label is also an ordinary path component. A rule without the not-a-slash guard rewrites every
# app bundle path in the evidence — the binary paths that ARE the finding in E14a, E14b and E13b.
check "a path component equal to the boot volume label survives" \
    "/Applications/Xcode.app/Contents/BootName/Xcode" "$(redact "/Applications/Xcode.app/Contents/BootName/Xcode")"
check "a deeper path component equal to the boot volume label survives" \
    "/a/BootName/b/BootName/c" "$(redact "/a/BootName/b/BootName/c")"

check "regex metacharacters in a label are escaped, not interpreted" \
    "/Volumes/<vault>/x" "$(redact "/Volumes/Weird.Name+1/x")"

check "an escaped dot matches a dot and nothing else" \
    "/Volumes/WeirdXName+1/x" "$(redact "/Volumes/WeirdXName+1/x")"

# ---- what must survive redaction ------------------------------------------------------------------
# E1 and E8 name the runtime volumes CoreSimulator mounts. Those live outside /Volumes, and the
# findings depend on being able to read them.
check "a CoreSimulator runtime volume is untouched" \
    "/Library/Developer/CoreSimulator/Volumes/iOS_23F77" \
    "$(redact "/Library/Developer/CoreSimulator/Volumes/iOS_23F77")"

# The E8 round-trip is the observation that this identifier changes across an export/import.
# Redacting it would delete the finding.
check "a CoreSimulator runtime UUID is untouched" \
    "iOS 26.5 (23F77) - 90F2566D-F038-4CF6-A8FF-0A9CC9C1F0BE" \
    "$(redact "iOS 26.5 (23F77) - 90F2566D-F038-4CF6-A8FF-0A9CC9C1F0BE")"

# Apple's APFS partition-type GUID identifies a filesystem format, not anybody's hardware.
check "the APFS partition-type GUID is untouched" \
    "41504653-0000-11AA-AA11-00306543ECAC" "$(redact "41504653-0000-11AA-AA11-00306543ECAC")"

check "a specific OS build is not personal and stays" \
    "macOS 26.7 (25G229)" "$(redact "macOS 26.7 (25G229)")"

# ---- the escape hatches ----------------------------------------------------------------------------
# A label that is also an ordinary word over-redacts by default. That is the deliberate trade:
# failing closed costs a false positive, failing open costs a permanent leak.
check "a label that is an ordinary word is redacted by default" \
    "<vault> drive" "$(redact "Backup drive")"

check "XCV_REDACT_KEEP opts a label out" \
    "Backup drive" "$(XCV_REDACT_KEEP="Backup" redact "Backup drive")"

check "XCV_PRIVATE_DIRS redacts folder names" \
    "in <private-dir> and <private-dir>" \
    "$(XCV_PRIVATE_DIRS="parallels backup-ios" redact "in parallels and backup-ios")"

check "XCV_PRIVATE_DIRS respects word boundaries" \
    "parallelsism" "$(XCV_PRIVATE_DIRS="parallels" redact "parallelsism")"

# ---- a donor that is GONE by the time the transcript is filtered -----------------------------------
# The limit of detection made concrete. `E6BDONOR` is deliberately absent from the fixture volumes
# directory, which is exactly the state an E6b run is in when it writes its evidence: staging
# unmounted the donor from /Volumes before mounting it over the target, so the detection loop
# cannot see it. Both variants filtered there and published the donor's label and UUID in the
# clear — the success paths as much as the failure paths.
check "an unmounted donor is NOT detected, which is why the held values exist" \
    "/Volumes/E6BDONOR 8B2F1A44-0000-4000-8000-000000000001" \
    "$(redact "/Volumes/E6BDONOR 8B2F1A44-0000-4000-8000-000000000001")"

check "XCV_REDACT_ALSO_LABEL redacts an unmounted donor in path form" \
    "/Volumes/<vault>" "$(XCV_REDACT_ALSO_LABEL="E6BDONOR" redact "/Volumes/E6BDONOR")"

check "XCV_REDACT_ALSO_LABEL redacts an unmounted donor standing alone" \
    "donor <vault> is gone" "$(XCV_REDACT_ALSO_LABEL="E6BDONOR" redact "donor E6BDONOR is gone")"

check "XCV_REDACT_ALSO_LABEL does not eat a longer word containing it" \
    "E6BDONORS" "$(XCV_REDACT_ALSO_LABEL="E6BDONOR" redact "E6BDONORS")"

check "XCV_REDACT_ALSO_UUID redacts an unmounted donor's UUID" \
    "UUID <vault-uuid>" \
    "$(XCV_REDACT_ALSO_UUID="8B2F1A44-0000-4000-8000-000000000001" redact "UUID 8B2F1A44-0000-4000-8000-000000000001")"

check "regex metacharacters in a held label are escaped, not interpreted" \
    "E6BxDONOR" "$(XCV_REDACT_ALSO_LABEL="E6B.DONOR" redact "E6BxDONOR")"

# Same asymmetry as the detected case, and for the same reason: KEEP exists because a label can be
# an ordinary English word, and a UUID never is.
check "XCV_REDACT_KEEP opts a held label out" \
    "E6BDONOR" "$(XCV_REDACT_KEEP="E6BDONOR" XCV_REDACT_ALSO_LABEL="E6BDONOR" redact "E6BDONOR")"

check "XCV_REDACT_KEEP does not opt the held UUID out" \
    "<vault-uuid>" \
    "$(XCV_REDACT_KEEP="E6BDONOR" XCV_REDACT_ALSO_LABEL="E6BDONOR" XCV_REDACT_ALSO_UUID="8B2F1A44-0000-4000-8000-000000000001" \
        redact "8B2F1A44-0000-4000-8000-000000000001")"

# ---- xcv_re_escape ------------------------------------------------------------------------------------
check "xcv_re_escape escapes a dot" '\.' "$(xcv_re_escape '.')"
check "xcv_re_escape leaves a plain word alone" 'plain' "$(xcv_re_escape 'plain')"


# ---- regressions from the pre-publication review -------------------------------------------------
# Every case below is a defect this suite did not catch when it was first written. The redactor had
# 21 green checks and was corrupting every app-bundle path on the author's machine.

# A boot volume's name is an ordinary path component. On a machine whose boot volume is called
# `MacOS` — as the author's is — a bare-label rule rewrites `Contents/MacOS/` in every bundle path,
# including the binary paths that are the whole finding in E14a, E14b and E13b. Word boundaries do
# not help: `/` is not a word character.
check "the boot volume's name is not redacted as a path component" \
    "/Applications/X.app/Contents/BootName/X" "$(redact "/Applications/X.app/Contents/BootName/X")"

check "the boot volume is still redacted under /Volumes" \
    "/Volumes/<bootvolume>/Users" "$(redact "/Volumes/BootName/Users")"

# XCV_REDACT_KEEP exists because a label can be an ordinary English word. A volume UUID never is,
# so keeping the label must not keep the hardware identifier behind it.
check "XCV_REDACT_KEEP keeps the label but not the volume UUID" \
    "Backup at <vault-uuid>" \
    "$(XCV_REDACT_KEEP="Backup" redact "Backup at BBBBBBBB-1111-2222-3333-444444444444")"

# [[:>:]] needs a word character to its left, so a label ending in punctuation had no working
# trailing boundary and the bare-label rule silently matched nothing.
check "a label ending in a non-word character is redacted bare" \
    "<vault> is mounted" "$(redact "Trailing. is mounted")"

check "a label ending in a non-word character is redacted in path form" \
    "/Volumes/<vault>/x" "$(redact "/Volumes/Trailing./x")"

# The home is a path prefix, not a word: unanchored it turned /Users/dev + "ops" into "~ops".
check "a longer home-like path is not rewritten" \
    "/Users/devops/x" "$(redact "/Users/devops/x")"

check "the home is redacted at end of line" \
    "cd ~" "$(redact "cd /Users/dev")"

# KEEP compares whole tokens rather than substrings: keeping "Backups" must not keep "Backup".
check "XCV_REDACT_KEEP does not keep a label that is merely a prefix of an entry" \
    "<vault> drive" "$(XCV_REDACT_KEEP="Backups" redact "Backup drive")"

# And the limit that follows from a whitespace-separated list, asserted rather than assumed: a
# two-word entry is two entries, so a label containing a space cannot be expressed in KEEP at all.
# Documented in common.sh; pinned here so nobody "fixes" the splitting and is surprised.
check "a two-word XCV_REDACT_KEEP entry is two separate labels" \
    "My drive" "$(XCV_REDACT_KEEP="My Vault" redact "My drive")"

# The private-dirs loop was unquoted, so it globbed against the working directory.
check "XCV_PRIVATE_DIRS is not glob-expanded" \
    "in <private-dir> here" "$(XCV_PRIVATE_DIRS="*" redact "in * here")"

# A metacharacter label was only ever tested in path form.
check "a metacharacter label is redacted bare too" \
    "<vault> mounted" "$(redact "Weird.Name+1 mounted")"

# ---- the epilogue's stderr, which four reviews watched go missing ------------------------------
#
# The E6b scripts send their evidence to a temp file with `exec >>"$REPORT" 2>&1` and restore the
# terminal afterwards. Restoring only stdout leaves every `>&2` in the epilogue writing into a file
# the EXIT trap then deletes — so a run that found the operator's account name in evidence bound for
# a public repository printed "do not commit it" into an unlinked inode, exited 1, and left the file
# on disk while the terminal showed `wrote <path>` and nothing else.
#
# That shape — a failure message written somewhere nobody reads — has now appeared four times in
# these scripts, each time in a different disguise: inside a pipeline whose `exit` did not exit, in
# a trap installed before the terminal fd existed, and twice on a stream that was never restored.
# The two behavioural checks below prove the hazard is real rather than theoretical; they are
# positive controls on a synthetic subshell and would have caught nothing in the real scripts.
# The source loop further down is what would have.

hazard_out="$(mktemp)"
(
    f="$(mktemp)"
    exec 3>&1
    exec >>"$f" 2>&1
    exec >&3  # stdout only — the defect
    echo "visible on stdout"
    echo "LOST WARNING" >&2
    rm -f "$f"
) >"$hazard_out" 2>&1
check "restoring only stdout loses the epilogue's warnings" \
    "visible on stdout" "$(cat "$hazard_out")"
rm -f "$hazard_out"

fixed_out="$(mktemp)"
(
    f="$(mktemp)"
    exec 3>&1
    exec >>"$f" 2>&1
    exec >&3 2>&3  # both — the fix
    echo "visible on stdout"
    echo "LOST WARNING" >&2
    rm -f "$f"
) >"$fixed_out" 2>&1
check "restoring both streams keeps them" \
    "visible on stdout
LOST WARNING" "$(cat "$fixed_out")"
rm -f "$fixed_out"

# Every script that redirects both streams into a report must restore both. A bare `exec >&3` is the
# defect, and it is invisible by inspection — which is why this is a check and not a convention.
#
# **Derived, not listed.** The first version named two files, so a third script written next month
# with the same defect would have passed — the gap a reviewer named, and precisely the shape that let
# variant A keep four defects while variant B was being fixed. The non-empty assertion below is the
# positive control: a pattern that stops matching would otherwise turn this whole loop into a no-op
# that reports success.
# `1?>>` because `exec 1>>"$F" 2>&1` is the same redirect spelled out, and the first version's regex
# required the `1` to be elided — a script written that way was never discovered, and the non-empty
# control below stayed green off the back of the two files that were.
#
# `*.sh`, not `e*.sh`: this directory holds library files too, and `mount-staging.sh` — added by this
# very change — is the proof. Scoping the sweep to the experiment prefix would have exempted exactly
# the kind of file most likely to grow the defect next.
redirecting=$(grep -lE '^exec 1?>>"\$[A-Za-z_]+" 2>&1$' ./*.sh 2>/dev/null | grep -vE '/(common|test-common)\.sh$')
check "the stream-restore loop found scripts to check" "yes" "$([ -n "$redirecting" ] && echo yes || echo no)"
for s in $redirecting; do
    # Anchored at column 0, because the comments in those scripts *describe* these patterns and an
    # unanchored count read the prose as code — the same defect the seam-discipline tests had with
    # braces written in sentences, reproduced here within an hour of writing about it.
    # The same pattern discovery uses. Hardcoding `$REPORT` here while discovery accepted any
    # variable name made a *correct* script using a different name fail — a check that cries wolf on
    # good code, which is the learned-to-ignore hazard the comments two screens up name twice.
    redirects=$(grep -cE '^exec 1?>>"\$[A-Za-z_]+" 2>&1$' "$s")
    restores_both=$(grep -cE '^exec >&3 2>&3$' "$s")
    restores_stdout_only=$(grep -cE '^exec >&3$' "$s")
    check "$s redirects both streams once" "1" "$redirects"
    check "$s restores both streams" "1" "$restores_both"
    check "$s has no stdout-only restore" "0" "$restores_stdout_only"
    # Counts alone let a restore sit *before* its redirect and still pass. Order matters: the
    # restore is what ends the redirected section.
    redirect_line=$(grep -nE '^exec 1?>>"\$[A-Za-z_]+" 2>&1$' "$s" | head -1 | cut -d: -f1)
    restore_line=$(grep -nE '^exec >&3 2>&3$' "$s" | head -1 | cut -d: -f1)
    check "$s restores after it redirects" "yes" \
        "$([ -n "$redirect_line" ] && [ -n "$restore_line" ] && [ "$restore_line" -gt "$redirect_line" ] && echo yes || echo no)"
done

# `mv`, not `cp`. Measured on 2026-09-21 against a deliberately full volume: `cp` failed and left
# 8 MB of a truncated file at the destination, destroying what was there; `mv` failed and left the
# destination unlinked. The difference only shows under ENOSPC or a cross-device fault, which is
# not worth a rig — so the call shape is pinned instead, the way the two wiring checks below are.
check "the redacted evidence is moved into place, not copied" "1" \
    "$(grep -cE '^ *mv "\$tmp" "\$out"' mount-staging.sh)"

# ---- the two calls that stand between the donor's identity and a tracked directory --------------
#
# Source checks, not behaviour checks, and deliberately so: both of these are calls that cannot be
# reached without root and a real donor volume, which is the same constraint that left the
# unmounted-donor leak undetected in the first place. The redaction tests above prove the RULE
# works on a literal; these prove the rule is still wired up.
#
# `xcv_stage_arm_redaction` is what hands `xcv_redact` the donor's label and UUID from values held
# before the donor was unmounted. Drop the call and every E6b report names the donor in the clear,
# in a file bound for `docs/research/evidence/`, with every other check still green.
arm_def=$(grep -cE '^xcv_stage_arm_redaction\(\)' mount-staging.sh)
arm_call=$(awk '/^xcv_stage_resolve_donor\(\) \{/,/^\}/' mount-staging.sh | grep -cE '^ *xcv_stage_arm_redaction$')
check "mount-staging.sh defines xcv_stage_arm_redaction" "1" "$arm_def"
check "xcv_stage_resolve_donor arms the redactor before it returns" "1" "$arm_call"

# And every evidence file goes through the one writer that rotates, redacts, checks for the account
# name, and deletes on doubt. A variant that redacts straight into the evidence directory has
# skipped the leak gate; that duplication is how the `rm` on the redact-failure branch came to
# exist in one variant and not the other.
for s in ./e6b-mount-stub-reappearance.sh ./e6b-physical-disconnect.sh; do
    check "$s writes evidence through xcv_stage_write_evidence" "1" \
        "$(grep -cE '^xcv_stage_write_evidence "\$REPORT" "\$out"' "$s")"
    check "$s does not redact straight into the evidence directory" "0" \
        "$(grep -cE '^ *xcv_redact .*> *"\$(out|diag)"' "$s")"
done

# ---- every script at least parses ----------------------------------------------------------------
# `mount-staging.sh` was outside every gate: no gate sourced it, ran it, or syntax-checked it, so a
# deleted leak check in the single evidence writer left the suite green. This is the floor; the
# behavioural checks below are the rest.
for s in ./*.sh; do
    check "$s parses" "0" "$(bash -n "$s" 2>/dev/null; echo $?)"
done

# ---- xcv_stage_write_evidence: the one path to a tracked directory ---------------------------------
#
# Behaviour, not source shape. Every historical redaction defect looked like a redactor that ran
# successfully and produced unredacted output, which is exactly what `[ -s ]` cannot see and only
# the account-name gate catches — so the gate has to be exercised, not grepped for.
#
# `common.sh` is already sourced with the fixture identity above; sourcing the staging library on
# top of it gives the real writer over a fake redactor-input, with `$out` in a temp directory.
. ./mount-staging.sh

# ---- the target guard's symlink refusal ------------------------------------------------------
# A symlink anywhere in the target path means the mount lands on the RESOLVED path while every
# `mount | grep " on $target "` in `mount-staging.sh` — the did-it-take check, both cleanup
# checks, the probe — greps for the literal one. The filesystem would be mounted somewhere nobody
# is watching and cleanup would report success. Behaviour, not source shape: the leaf case and
# the ancestor case are different code and the first version only caught the leaf.
#
# Under a PHYSICALLY resolved base, deliberately. `$FIX` comes from `mktemp -d`, which hands back
# `/var/...`, and `/var` is a symlink to `/private/var` — so the control case refuses for the
# right reason while proving nothing about the wrong one. Caught by this very check failing on
# its first run, which is the argument for having it.
GT="$(cd "$FIX" && pwd -P)/guard"
mkdir -p "$GT/real/inner"
ln -s "$GT/real" "$GT/link"
ln -s "$GT/real/inner" "$GT/real/sym"
# `type -t` first: a missing function returns non-zero, which would read as "refused" and make
# every refusal check below pass for the wrong reason. This block sat above the `. ./mount-staging.sh`
# on its first draft and did exactly that.
check "the target guard is actually loaded" "function" "$(type -t xcv_stage_guard_target)"
guard() { xcv_stage_guard_target "$1" >/dev/null 2>&1 3>/dev/null && echo allowed || echo refused; }
# The one environment-dependent check in this file: the guard also runs `pgrep -qx
# "xcodebuild|Xcode|Simulator"` and `pgrep -qx launchd_sim`, so this fails with Xcode open or any
# simulator device booted. It fails loudly rather than
# vacuously, which is the safe direction, but it is the reason a red run here may not be a code
# change. This machine runs test rigs on its simulators, so it will happen.
check "an ordinary directory passes the target guard" "allowed" "$(guard "$GT/real/inner")"
check "a symlinked ANCESTOR is refused" "refused" "$(guard "$GT/link/inner")"
check "a symlinked LEAF is refused" "refused" "$(guard "$GT/real/sym")"

# The combination that defeated the first two drafts: a symlinked ancestor AND a parent that does
# not exist yet. `[ -L ]` is false (it lstats the leaf, resolving ancestors), and stopping the
# resolution at `dirname` finds nothing to compare — so the guard fell through and
# `xcv_stage_mount` would then `mkdir -p` the missing components under the RESOLVED ancestor.
check "a symlinked ancestor with an ABSENT parent is refused" "refused" \
    "$(guard "$GT/link/notyet/leaf")"

# The predicate itself, and that both callers reach it. It lived in two places for one round —
# the library's copy pinned, E6c's inline copy not — which is the shape `mount-staging.sh`'s own
# header exists to record.
sym() { xcv_stage_refuse_symlinked_path "$1" >/dev/null 2>&1 3>/dev/null && echo allowed || echo refused; }
check "the shared symlink predicate is loaded" "function" "$(type -t xcv_stage_refuse_symlinked_path)"
check "the predicate allows a real path" "allowed" "$(sym "$GT/real/inner")"
check "the predicate refuses a symlinked ancestor" "refused" "$(sym "$GT/link/inner")"
check "the target guard delegates to it" "1" \
    "$(grep -cE '^ *xcv_stage_refuse_symlinked_path "\$target" \|\| return 1$' mount-staging.sh)"
check "e6c delegates to it for its control dir" "1" \
    "$(grep -cE '^xcv_stage_refuse_symlinked_path "\$PROBE" \|\| exit 1$' e6c-mount-mechanism.sh)"

EV=$(mktemp -d)
SUDO_USER="$T_USER"
w_out="$EV/evidence.txt"
w_report=$(mktemp)

# A clean report: no account name, no home, nothing to redact.
printf 'a clean line\nanother clean line\n' > "$w_report"
w_msgs=$(xcv_stage_write_evidence "$w_report" "$w_out" 3>&1 >/dev/null 2>/dev/null)
check "a clean report is written" "0" "$([ -f "$w_out" ] && echo 0 || echo 1)"
check "a clean report is written verbatim" "a clean line
another clean line" "$(cat "$w_out" 2>/dev/null)"
w_said=no; case "$w_msgs" in *"redaction: ok"*) w_said=yes ;; esac
check "and the writer says so on fd 3" "yes" "$w_said"

# A report the redactor handles: the home is rewritten, so the account name never reaches the gate.
printf 'built in %s/x\n' "$T_HOME" > "$w_report"
xcv_stage_write_evidence "$w_report" "$w_out" 3>/dev/null >/dev/null 2>/dev/null
check "the home is redacted on the way out" "built in ~/x" "$(cat "$w_out" 2>/dev/null)"

# The gate itself. `xcv_redact` word-boundaries the account name, so to reach the gate the leak has
# to be a form it does not rewrite — here, part of a longer token, which is exactly the shape the
# "short account name does not eat the words containing it" rule deliberately leaves alone.
prev=$(cat "$w_out")
before=$(ls -1 "$EV" | wc -l | tr -d ' ')
printf 'user %sops signed in\n' "$T_USER" > "$w_report"
w_rc=0; xcv_stage_write_evidence "$w_report" "$w_out" 3>/dev/null >/dev/null 2>/dev/null || w_rc=$?
check "a leaked account name is refused" "1" "$w_rc"
check "and the leaking file is NOT at the canonical path" "$prev" "$(cat "$w_out" 2>/dev/null)"
# The point of redact-into-a-temp-then-move: a refused write rotates nothing, so the previous
# evidence is still at its own name rather than surviving only as `-superseded-`.
check "and nothing was rotated out from under the previous evidence" "$before" \
    "$(ls -1 "$EV" | wc -l | tr -d ' ')"

# Refusals that must happen before anything is touched.
: > "$w_report"
w_rc=0; xcv_stage_write_evidence "$w_report" "$w_out" 3>/dev/null >/dev/null 2>/dev/null || w_rc=$?
check "an empty run log is refused" "1" "$w_rc"
printf 'x\n' > "$w_report"
check "a missing run log is refused" "1" \
    "$(xcv_stage_write_evidence "$EV/no-such-report" "$EV/never.txt" 3>/dev/null >/dev/null 2>/dev/null; echo $?)"
check "a refused write leaves no file behind" "0" "$([ -e "$EV/never.txt" ] && echo 1 || echo 0)"

# The rc is the same on both sides of this guard's deletion — without it, `grep -cF ""` matches
# every line and the write is refused anyway. So an rc assertion here would pass whether the guard
# exists or not; deleting it was measured as surviving a 100-check run. The REASON on fd 3 is the
# only observable difference, and message accuracy is the whole point of the guard: "the account
# name is in the output (1 line(s))" names the wrong cause.
w_msgs=$(SUDO_USER="" xcv_stage_write_evidence "$w_report" "$EV/nouser.txt" 3>&1 >/dev/null 2>/dev/null)
w_rc=0; SUDO_USER="" xcv_stage_write_evidence "$w_report" "$EV/nouser.txt" 3>/dev/null >/dev/null 2>/dev/null || w_rc=$?
w_why=no; case "$w_msgs" in *"SUDO_USER is empty"*) w_why=yes ;; esac
check "an empty SUDO_USER is refused" "1" "$w_rc"
check "and refused BY NAME, not reported as an account-name leak" "yes" "$w_why"
check "and it wrote nothing" "0" "$([ -e "$EV/nouser.txt" ] && echo 1 || echo 0)"

# The donor gate, symmetric with the account-name gate. Reached by defeating the redactor rather
# than the gate: with the redactor unarmed the UUID passes through, and the gate is what stops it.
unset XCV_REDACT_ALSO_LABEL XCV_REDACT_ALSO_UUID
XCV_DONOR_UUID=8B2F1A44-0000-4000-8000-000000000001
printf 'donor UUID %s\n' "$XCV_DONOR_UUID" > "$w_report"
w_rc=0; xcv_stage_write_evidence "$w_report" "$EV/leakuuid.txt" 3>/dev/null >/dev/null 2>/dev/null || w_rc=$?
check "an unredacted donor UUID is refused even when the redactor missed it" "1" "$w_rc"
check "and it wrote nothing" "0" "$([ -e "$EV/leakuuid.txt" ] && echo 1 || echo 0)"
unset XCV_DONOR_UUID

# The donor identity, end to end through the real writer with the donor UNMOUNTED — the state an
# E6b run is actually in when it writes. `E6BDONOR` is absent from the fixture volumes directory.
XCV_DONOR_LABEL=E6BDONOR
XCV_DONOR_UUID=8B2F1A44-0000-4000-8000-000000000001
xcv_stage_arm_redaction
printf 'donor /Volumes/E6BDONOR UUID 8B2F1A44-0000-4000-8000-000000000001\n' > "$w_report"
xcv_stage_write_evidence "$w_report" "$EV/donor.txt" 3>/dev/null >/dev/null 2>/dev/null
check "an unmounted donor is redacted by the real writer" \
    "donor /Volumes/<vault> UUID <vault-uuid>" "$(cat "$EV/donor.txt" 2>/dev/null)"
unset XCV_REDACT_ALSO_LABEL XCV_REDACT_ALSO_UUID

rm -rf "$EV"; rm -f "$w_report"

printf '\n%d checks, %d failures\n' "$run" "$fails"
[ "$fails" -eq 0 ]

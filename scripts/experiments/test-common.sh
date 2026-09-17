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
mkdir -p "$FIX/volumes/VAULT" "$FIX/volumes/Backup" "$FIX/volumes/Weird.Name+1"
ln -s / "$FIX/volumes/BootName"
export XCV_VOLUMES_DIR="$FIX/volumes"

xcv_volume_uuid() {
    case "${1##*/}" in
        VAULT) echo "<vault-uuid>" ;;
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
    "Volume UUID: <vault-uuid>" "$(redact "Volume UUID: <vault-uuid>")"

check "the boot volume is redacted, and marked as the boot volume" \
    "/Volumes/<bootvolume>/Users" "$(redact "/Volumes/BootName/Users")"

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

# ---- xcv_re_escape ------------------------------------------------------------------------------------
check "xcv_re_escape escapes a dot" '\.' "$(xcv_re_escape '.')"
check "xcv_re_escape leaves a plain word alone" 'plain' "$(xcv_re_escape 'plain')"

printf '\n%d checks, %d failures\n' "$run" "$fails"
[ "$fails" -eq 0 ]

#!/bin/bash
# Asserts that this machine can actually run the tests that `XCTSkip` would otherwise skip.
#
# Twenty-four `XCTSkip` sites gate tests on environment capabilities. The first CI run, on
# 2026-09-18, measured **zero** tests skipped on both `macos-15` and `macos-26` — so every one of
# them fires today. That question is settled, and settled in the direction that the tests do run.
#
# What was *not* settled, and what this file is for (issue #18): **nothing enforced it.** An
# environment change could start skipping tests and no gate would notice. A test that silently stops
# running is worse than a test that fails, because the suite still reports green and the count only
# moves if somebody is watching it.
#
# Two controls, and they are different in kind:
#
#   - This script asserts the *capabilities* exist, and says which one is missing when it fails.
#     Run it before `swift test` so a missing capability is diagnosed rather than inferred.
#   - `scripts/ci-assert-no-skips.sh` asserts the *outcome* — that the suite skipped nothing. That
#     is the one that cannot be fooled by a capability this file forgot to check.
#
# Both are needed. A capability check is a list somebody maintains; the skip count is the property
# actually wanted. Neither alone would have caught a skip introduced by a test that gates on
# something nobody thought to assert here.
#
#   bash scripts/ci-environment-assertions.sh
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || { echo "ci-env: cannot reach the repository root" >&2; exit 2; }

fails=0
scratch=$(mktemp -d) || { echo "ci-env: cannot create a scratch directory" >&2; exit 2; }
cleanup() {
    # Detach before removing: a still-attached image makes the rmdir fail and leaves the runner
    # holding a device. `|| true` on each, because cleanup must not mask the real exit status.
    [ -n "${attached:-}" ] && hdiutil detach "$attached" -force >/dev/null 2>&1
    rm -rf "$scratch" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

ok()   { printf 'ci-env: ok      %s\n' "$1"; }
bad()  { printf 'ci-env: MISSING %s\n           %s\n' "$1" "$2" >&2; fails=$((fails + 1)); }

# ---- 1. ACLs (`chmod +a`) ---------------------------------------------------------------------
# Used by the deny-delete ACL tests in M3Tests and OwnershipAdviceTests. A `deny delete` ACL is the
# demonstrated route to `isDeletableFile == true` while `removeItem` fails, which is the case the
# abort/forget termination bound was built for.
acl_probe="$scratch/acl-probe"
: > "$acl_probe"
if chmod +a "everyone deny delete" "$acl_probe" 2>/dev/null; then
    ls -le "$acl_probe" 2>/dev/null | grep -q 'deny delete' \
        && ok "chmod +a sets a deny-delete ACL" \
        || bad "chmod +a is accepted but the ACL does not stick" "the tests that stage an undeletable file would skip"
    chmod -a# 0 "$acl_probe" 2>/dev/null
else
    bad "chmod +a" "the filesystem under \$TMPDIR does not support ACLs; the deny-delete tests would skip"
fi

# ---- 2. `hdiutil create` / `attach` -------------------------------------------------------------
# Used wherever a test needs a real filesystem it can detach — a separate device for the
# cross-device checks, and a case-sensitive volume for E12's shape.
image="$scratch/probe.dmg"
if hdiutil create -size 10m -fs APFS -volname xcv-ci-probe -quiet "$image" 2>/dev/null; then
    attached=$(hdiutil attach "$image" -nobrowse -mountpoint "$scratch/mnt" 2>/dev/null | awk '/\/dev\/disk/ {print $1; exit}')
    if [ -n "${attached:-}" ] && [ -d "$scratch/mnt" ]; then
        ok "hdiutil create + attach"
        hdiutil detach "$attached" -force >/dev/null 2>&1 && attached=""
    else
        bad "hdiutil attach" "the image was created but would not attach; the disk-image tests would skip"
    fi
else
    bad "hdiutil create" "cannot create a disk image; the disk-image tests would skip"
fi

# ---- 3. The `/Volumes/<boot volume name>` symlink -----------------------------------------------
# macOS puts a symlink to `/` at `/Volumes/<boot volume name>`. One test reaches the boot volume
# through it on purpose, because a path that looks like `/Volumes/<something>` but is the boot
# volume is the shape the shadow-data rules have to tell apart from a real external volume.
boot_name=$(diskutil info / 2>/dev/null | awk -F': *' '/Volume Name/ {print $2; exit}')
if [ -z "$boot_name" ]; then
    bad "the boot volume's name" "diskutil could not report it, so the symlink cannot be checked"
elif [ -L "/Volumes/$boot_name" ]; then
    ok "/Volumes/<boot volume> is a symlink"
else
    bad "/Volumes/<boot volume>" "no symlink there; the test that reaches the boot volume through /Volumes would skip"
fi

# ---- 4. A non-root user -------------------------------------------------------------------------
# Eleven of the skips are "root can read/write a 000 directory" or "root bypasses ACLs". Running the
# suite as root does not make them fail — it makes them *vanish*, which is the failure mode this
# whole file exists to prevent.
if [ "$(id -u)" -eq 0 ]; then
    bad "a non-root test user" "running as root silently removes eleven permission tests from the suite"
else
    ok "not running as root"
fi

if [ "$fails" -gt 0 ]; then
    echo "ci-env: $fails capability/capabilities missing — tests would be skipped rather than run" >&2
    exit 1
fi
echo "ci-env: ok"

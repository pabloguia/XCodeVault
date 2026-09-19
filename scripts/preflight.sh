#!/bin/bash
# Runs the CI gates that can be run here, in CI's order, on this machine.
#
# Nine of CI's eleven steps. The two it leaves out are named rather than silently missing:
# "Toolchain" only prints versions, and the read-only gating experiments (E1/E8) **write evidence
# files into `docs/research/evidence/`** — running them before every push would dirty the working
# tree as a side effect of checking it, which is a worse habit than the coverage is worth. Run
# `scripts/experiments/e1-mountability.sh` deliberately, when you mean to record evidence.
#
# **Why this exists.** CI was red for four consecutive pushes on `swift format lint --strict`,
# while the author had run `swift test`, `helper-invariants.sh` and `check-doc-mirror.sh` locally
# and concluded the tree was green. Three of the four gates is not "the gates passed", and the
# only way to find that out was a push and a six-minute wait — so the cheapest check in the set
# was the one nobody ran.
#
# It is a convenience, **not a control**: CI remains the authority, this cannot verify the other
# runner's macOS/Xcode combination, and a gate added to `.github/workflows/ci.yml` and not added
# here is silently missing. `--list` prints what it runs so the two can be compared by eye; the
# assertion below fails loudly when the workflow grows a step this script does not know about.
#
#   scripts/preflight.sh          # every gate runs; failures are reported together at the end
#   scripts/preflight.sh --fast   # skip the suite (~45 s) — for a docs- or script-only change
#   scripts/preflight.sh --list   # name the gates without running them
set -u -o pipefail
cd "$(dirname "$0")/.."

GATES=(
    "build:swift build -Xswiftc -warnings-as-errors"
    "environment:bash scripts/ci-environment-assertions.sh"
    "tests:swift test"
    "no-skips:bash scripts/ci-assert-no-skips.sh"
    "doc-mirror:bash scripts/check-doc-mirror.sh"
    "helper-invariants:bash scripts/helper-invariants.sh"
    "redaction:bash scripts/experiments/test-common.sh"
    "format:swift-format lint --recursive --strict --configuration .swift-format Sources Tests"
    "cli-smoke:.build/debug/xcodevaultctl status && .build/debug/xcodevaultctl xcode list && .build/debug/xcodevaultctl compatibility && .build/debug/xcodevaultctl report --json"
)

if [ "${1:-}" = "--list" ]; then
    for g in "${GATES[@]}"; do printf '  %-20s %s\n' "${g%%:*}" "${g#*:}"; done
    exit 0
fi
fast=0
[ "${1:-}" = "--fast" ] && fast=1

# The workflow is the source of truth for what CI runs; drifting from it silently is the one
# failure this script cannot afford, because its whole value is "green here means green there".
workflow_steps=$(grep -cE '^      - name: ' .github/workflows/ci.yml)
expected_steps=11
if [ "$workflow_steps" -ne "$expected_steps" ]; then
    echo "preflight: ci.yml has $workflow_steps steps, this script was written against $expected_steps." >&2
    echo "preflight: compare 'scripts/preflight.sh --list' against the workflow and update both." >&2
    exit 2
fi

log=$(mktemp -t xcv-preflight)
trap 'rm -f "$log"' EXIT
failed=()
ran=0
for g in "${GATES[@]}"; do
    name="${g%%:*}"
    cmd="${g#*:}"
    if [ "$fast" = 1 ] && { [ "$name" = "tests" ] || [ "$name" = "no-skips" ]; }; then
        printf '  %-20s skipped (--fast)\n' "$name"
        continue
    fi
    printf '  %-20s ' "$name"
    ran=$((ran + 1))
    case "$name" in
        tests)
            # Tee'd because the no-skips gate reads the suite's own output rather than re-running it.
            if swift test >"$log" 2>&1; then echo "ok"; else echo "FAILED"; failed+=("$name"); fi
            ;;
        no-skips)
            if [ ! -s "$log" ]; then
                echo "SKIPPED (no test log — the suite did not run)"
                failed+=("$name")
            elif bash scripts/ci-assert-no-skips.sh "$log" >/dev/null 2>&1; then
                echo "ok"
            else
                echo "FAILED"
                failed+=("$name")
            fi
            ;;
        format)
            fmt=$(xcrun --find swift-format 2>/dev/null)
            if [ -z "$fmt" ]; then
                echo "FAILED (swift-format is not in this toolchain; the gate cannot run)"
                failed+=("$name")
            elif "$fmt" lint --recursive --strict --configuration .swift-format Sources Tests >/dev/null 2>&1; then
                echo "ok"
            else
                echo "FAILED"
                failed+=("$name")
            fi
            ;;
        *)
            if eval "$cmd" >/dev/null 2>&1; then echo "ok"; else echo "FAILED"; failed+=("$name"); fi
            ;;
    esac
done

if [ ${#failed[@]} -eq 0 ]; then
    # The count is what **ran**, not how many exist. "ok (9 gates)" after `--fast` skipped two was
    # a false statement printed by the script whose entire purpose is that green means green.
    if [ "$ran" -eq "${#GATES[@]}" ]; then
        echo "preflight: ok ($ran gates)"
    else
        echo "preflight: ok ($ran of ${#GATES[@]} gates — $(( ${#GATES[@]} - ran )) skipped by --fast; this is NOT a full check)"
    fi
    exit 0
fi
echo "preflight: ${#failed[@]} gate(s) failed: ${failed[*]}" >&2
echo "preflight: every gate ran — this list is complete, not the first failure." >&2
echo "preflight: re-run the failing one directly to see its output — this script hides it deliberately," >&2
echo "preflight: because a wall of passing output is how the one failing line gets missed." >&2
exit 1

#!/bin/bash
# Assert that a SonarQube Cloud scan measured this commit's code, on the main branch.
#
# **Why this exists.** `sonarqube-scan-action` succeeds when it has *uploaded* a report. The scanner
# prints `ANALYSIS SUCCESSFUL` at that moment — before the server has processed anything, and
# regardless of how few files it looked at. Four consecutive CI runs reported success while
# measuring two files, because the project's main branch in SonarCloud was `master` while the
# repository's is `main`: every CI analysis landed on a secondary branch, where SonarCloud analyses
# only what changed against the main branch. Nothing anywhere went red, and the dashboard kept
# showing a stale local run, because the dashboard shows the main branch.
#
# Four assertions, each of which must be able to fail:
#   1. the server finished processing, and the task succeeded
#   2. the analysis is on the project's MAIN branch, not a secondary one
#   3. it is for this commit
#   4. it covers at least MIN_NCLOC lines
#
# Assertion 4 is the one that catches the failure above, and its floor is deliberately a real number
# rather than 1: a threshold nothing can fall below is not a threshold.
set -uo pipefail

: "${SONAR_TOKEN:?SONAR_TOKEN is required}"
: "${PROJECT_KEY:?PROJECT_KEY is required}"
MIN_NCLOC="${MIN_NCLOC:-4000}"
HOST="${SONAR_HOST_URL:-https://sonarcloud.io}"
TASK_FILE="${TASK_FILE:-.scannerwork/report-task.txt}"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null)}"

api() { curl -sS -H "Authorization: Bearer $SONAR_TOKEN" "$HOST/$1"; }
die() { echo "!! $*" >&2; exit 1; }

[ -f "$TASK_FILE" ] || die "$TASK_FILE is missing — the scanner did not run, or ran in another directory."
TASK_ID="$(sed -n 's/^ceTaskId=//p' "$TASK_FILE" | head -1)"
[ -n "$TASK_ID" ] || die "no ceTaskId in $TASK_FILE; cannot tell whether the report was processed."

# 1. Wait for the server, rather than trusting the scanner's "uploaded" as "analysed".
status=""
for _ in $(seq 1 60); do
    status="$(api "api/ce/task?id=$TASK_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"]["status"])' 2>/dev/null)"
    case "$status" in
        SUCCESS | FAILED | CANCELED) break ;;
    esac
    sleep 5
done
[ "$status" = "SUCCESS" ] || die "the analysis report was not processed successfully (status: ${status:-unknown}). Nothing was measured."

# 2 and 3. Which branch, and which commit.
# One value per call. Reading three space-separated fields with `read` shifts them when the first is
# empty — and an empty branch is exactly the main-branch case, so the bug would have fired precisely
# where the check matters and put the branch *type* into the branch *name*.
analysed_branch="$(api "api/ce/task?id=$TASK_ID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"].get("branch",""))' 2>/dev/null)"

main_branch="$(api "api/project_branches/list?project=$PROJECT_KEY" | python3 -c '
import json, sys
for b in json.load(sys.stdin).get("branches", []):
    if b.get("isMain"):
        print(b["name"]); break
' 2>/dev/null)"
[ -n "$main_branch" ] || die "could not read the project's main branch from $HOST."

if [ -n "$analysed_branch" ] && [ "$analysed_branch" != "$main_branch" ]; then
    die "the analysis landed on branch '$analysed_branch' while the project's main branch is '$main_branch'.
   SonarCloud analyses only CHANGED files on a non-main branch, so this measured a fraction of the code
   and the dashboard still shows whatever last analysed '$main_branch'.
   Fix it once, in SonarCloud: Administration > Branches and Pull Requests — rename '$main_branch' to
   '$analysed_branch' (deleting the existing '$analysed_branch' entry first)."
fi

# 3. This commit, not a stale analysis. The whole reason this was invisible for four runs is that the
# dashboard kept showing a three-hour-old local run: a measurement can be perfectly healthy and still
# be about code nobody pushed. Only asserted on a push, where GITHUB_SHA *is* the analysed commit —
# a pull-request analysis is of a merge commit that exists nowhere in the branch.
if [ "${GITHUB_EVENT_NAME:-push}" = "push" ] && [ -n "$SHA" ]; then
    analysed_rev="$(api "api/project_analyses/search?project=$PROJECT_KEY&branch=$main_branch&ps=1" \
        | python3 -c 'import json,sys; a=json.load(sys.stdin).get("analyses",[]); print(a[0].get("revision","") if a else "")' 2>/dev/null)"
    [ -n "$analysed_rev" ] || die "could not read the analysed revision for '$main_branch'; treating an unreadable answer as a failure."
    [ "$analysed_rev" = "$SHA" ] || die "the newest analysis on '$main_branch' is for ${analysed_rev:0:8}, not this commit ${SHA:0:8}.
   The scan reported success but its result is not what the dashboard is showing."
fi

# 4. The measurement itself. This is what the broken configuration could not satisfy.
ncloc="$(api "api/measures/component?component=$PROJECT_KEY&branch=$main_branch&metricKeys=ncloc" \
    | python3 -c 'import json,sys; print(next((m["value"] for m in json.load(sys.stdin)["component"]["measures"] if m["metric"]=="ncloc"), ""))' 2>/dev/null)"
case "$ncloc" in
    '' | *[!0-9]*) die "could not read ncloc for '$main_branch' (got: '${ncloc}'). Treating an unreadable measurement as a failure." ;;
esac
[ "$ncloc" -ge "$MIN_NCLOC" ] || die "the analysis measured $ncloc lines, below the floor of $MIN_NCLOC.
   That is what a branch-scoped or partial analysis looks like: it succeeds, and it measures almost nothing."

echo "sonar-verify: ok — $ncloc lines on main branch '$main_branch' (floor $MIN_NCLOC), task $TASK_ID, commit ${SHA:0:8}"

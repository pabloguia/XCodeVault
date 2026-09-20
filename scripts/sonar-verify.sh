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
MIN_COVERAGE="${MIN_COVERAGE:-60}"
HOST="${SONAR_HOST_URL:-https://sonarcloud.io}"
TASK_FILE="${TASK_FILE:-.scannerwork/report-task.txt}"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null)}"

api() { curl -sS -H "Authorization: Bearer $SONAR_TOKEN" "$HOST/$1"; }
die() { echo "!! $*" >&2; exit 1; }

# The floors are validated before anything uses them. `MIN_COVERAGE` is interpolated into a `float()`
# call below, where a non-numeric value raises ValueError and exits 1 — the SAME status as "below the
# floor". A reviewer demonstrated `MIN_COVERAGE=60%` producing "coverage is 84.2%, below the floor of
# 60%%", which is false and sends the reader to write tests for a typo in a workflow file.
case "$MIN_NCLOC" in '' | *[!0-9]*) die "MIN_NCLOC must be a whole number (got: '$MIN_NCLOC')." ;; esac
case "$MIN_COVERAGE" in '' | *[!0-9.]*) die "MIN_COVERAGE must be a number (got: '$MIN_COVERAGE')." ;; esac

# What this run actually verified, accumulated as it goes. The success line is built from THIS rather
# than from the list of assertions in the file, because several do not apply to a pull-request
# analysis: the previous version printed the ncloc and coverage floors on a PR run that had applied
# neither, and rendered a skipped coverage check as the literal `n/a (pull request)%`.
checked=""
note_check() { checked="${checked:+$checked; }$1"; }

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
note_check "task $TASK_ID processed"

# 2 and 3. Which branch, and which commit.
#
# The task is fetched ONCE and its fields read from that one response. One value per `python3` call,
# never three space-separated fields through `read`: `read a b c` shifts them when the first is empty,
# and an empty branch is exactly the main-branch case — so the bug would have fired precisely where
# the check matters and put the branch *type* into the branch *name*.
task_json="$(api "api/ce/task?id=$TASK_ID")"
# Unreadable is a FAILURE, like every other assertion here says of itself. `api` is plain `curl -sS`
# with no `--fail`, so an HTTP 401, 429 or 5xx arrives as a body with exit 0; `field` would then
# return the empty string for every key, and the branch check below — the one that exists because
# four runs landed on a secondary branch — is skipped precisely when `analysed_branch` is empty.
# The script would print "ok". This is the only assertion that had that hole, and the refactor that
# introduced `field` widened it to two keys.
printf '%s' "$task_json" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["task"].get("id") else 1)' 2>/dev/null \
    || die "could not read the analysis task from $HOST (HTTP error, rate limit, or malformed body).
   Treating an unreadable answer as a failure: every field below would read as empty, which does not
   fail the branch check — it disables it."
field() { printf '%s' "$task_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['task'].get('$1',''))" 2>/dev/null; }
analysed_branch="$(field branch)"
# A pull-request analysis is not a branch analysis: SonarCloud reports it under `pullRequest`.
#
# **This exemption is belt-and-braces, and the comment here used to claim more.** It said that
# without it every PR would fail with a message about renaming the main branch. Measured on PR #35,
# the first this repository ever had: a PR task carries `branch: ""`, so the `[ -n "$analysed_branch" ]`
# guard below would have skipped on its own. What the exemption buys is that the skip is stated
# rather than incidental — if SonarCloud ever also sets `branch` on a PR task, the rule stays correct
# instead of failing every pull request for a reason about the main branch.
analysed_pr="$(field pullRequest)"

main_branch="$(api "api/project_branches/list?project=$PROJECT_KEY" | python3 -c '
import json, sys
for b in json.load(sys.stdin).get("branches", []):
    if b.get("isMain"):
        print(b["name"]); break
' 2>/dev/null)"
[ -n "$main_branch" ] || die "could not read the project's main branch from $HOST."

if [ -z "$analysed_pr" ] && [ -n "$analysed_branch" ] && [ "$analysed_branch" != "$main_branch" ]; then
    die "the analysis landed on branch '$analysed_branch' while the project's main branch is '$main_branch'.
   SonarCloud analyses only CHANGED files on a non-main branch, so this measured a fraction of the code
   and the dashboard still shows whatever last analysed '$main_branch'.
   Fix it once, in SonarCloud: Administration > Branches and Pull Requests — rename '$main_branch' to
   '$analysed_branch' (deleting the existing '$analysed_branch' entry first)."
fi
# Spelled out rather than `${analysed_pr:+...}${analysed_pr:-...}`: `:-` expands to the VALUE when the
# variable is set, so that pair printed "pull request #77" for PR 7.
if [ -n "$analysed_pr" ]; then
    note_check "pull request #$analysed_pr"
else
    note_check "branch '${analysed_branch:-$main_branch}'"
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
    note_check "commit ${SHA:0:8}"
fi

# 4. The measurement itself. This is what the broken configuration could not satisfy.
#
# Push-only. The query is scoped `branch=$main_branch`, so on a pull request it measured the MAIN
# branch and passed for reasons having nothing to do with the change under review — a check reporting
# on code the reviewer is not looking at. Scoping it to the PR instead would be worse: a PR's ncloc is
# its changed-line count, and a floor of 4000 on that would fail every ordinary contribution.
if [ "${GITHUB_EVENT_NAME:-push}" = "push" ]; then
    ncloc="$(api "api/measures/component?component=$PROJECT_KEY&branch=$main_branch&metricKeys=ncloc" \
        | python3 -c 'import json,sys; print(next((m["value"] for m in json.load(sys.stdin)["component"]["measures"] if m["metric"]=="ncloc"), ""))' 2>/dev/null)"
    case "$ncloc" in
        '' | *[!0-9]*) die "could not read ncloc for '$main_branch' (got: '${ncloc}'). Treating an unreadable measurement as a failure." ;;
    esac
    [ "$ncloc" -ge "$MIN_NCLOC" ] || die "the analysis measured $ncloc lines, below the floor of $MIN_NCLOC.
   That is what a branch-scoped or partial analysis looks like: it succeeds, and it measures almost nothing."
    note_check "$ncloc lines (floor $MIN_NCLOC)"
fi

# 5. Coverage actually landed on the server (issue #34).
#
# `scripts/coverage-to-sonar.sh` already refuses to write an empty or implausibly small report, so
# a report that does not exist fails the job before the scan. This is the OTHER half, and it is the
# half only the server can answer: a report can be perfectly well-formed, pass every floor at
# production time, and still be discarded wholesale on import when its paths do not match the files
# Sonar indexed. The converter would print "37 files, 84.2%" and the dashboard would read 0%.
#
# That 0% is indistinguishable from an untested project, which is precisely the confusion issue #34
# exists to remove — so it is asserted rather than eyeballed.
#
# Push-only, and against the main branch, for the same reason as assertion 3: on a pull request this
# metric means coverage *of new code*, which is legitimately absent for a docs-only change. Judging
# a docs PR by it would be the "red for a reason unrelated to the change" failure, rebuilt here.
if [ "${GITHUB_EVENT_NAME:-push}" = "push" ]; then
    coverage="$(api "api/measures/component?component=$PROJECT_KEY&branch=$main_branch&metricKeys=coverage" \
        | python3 -c 'import json,sys; print(next((m["value"] for m in json.load(sys.stdin)["component"]["measures"] if m["metric"]=="coverage"), ""))' 2>/dev/null)"
    case "$coverage" in
        '' | *[!0-9.]*) die "no coverage measure for '$main_branch' (got: '${coverage}').
   The scan imported no coverage at all. Either coverage.xml never reached the scanner, or every path
   in it was dropped as unrecognised. Check the scanner log for 'Imported coverage data'." ;;
    esac
    # Compared as a float: `[ ]` is integer-only, and "84.2" would make it error out and, with
    # `set -uo pipefail` but no `-e`, carry on to print success.
    #
    # The verdict is PRINTED rather than signalled by exit status, so that a ValueError cannot
    # masquerade as "below the floor" — `sys.exit(1)` says both things at once.
    verdict="$(python3 -c "print(1 if float('$coverage') >= float('$MIN_COVERAGE') else 0)" 2>/dev/null)"
    case "$verdict" in
        1) ;;
        0) die "coverage on '$main_branch' is ${coverage}%, below the floor of ${MIN_COVERAGE}%.
   The floor is not a quality target — the quality gate is. It separates 'this project is under-tested'
   from 'the import silently produced nothing', which render identically on the dashboard." ;;
        *) die "could not compare coverage '$coverage' with the floor '$MIN_COVERAGE'." ;;
    esac
    note_check "coverage ${coverage}% (floor ${MIN_COVERAGE}%)"
else
    coverage="n/a (pull request)"
fi

# 6. The quality gate itself (issue #34).
#
# Assertions 1-5 establish that a real measurement of this commit reached the server. This is the one
# that acts on WHAT it measured, and it is the half issue #34 says was missing: "CI does not enforce
# the gate — `sonar.qualitygate.wait` is not set and the workflow's own `scripts/sonar-verify.sh`
# checks that the analysis *happened*, not that it passed — so nothing is blocked today."
#
# Done here rather than with `sonar.qualitygate.wait=true` for two reasons. Ordering: that flag fails
# the scan step, so a gate failure would pre-empt assertions 1-5 and a red check could mean either
# "the gate failed" or "the analysis never happened" — the distinction this whole script exists to
# draw. And diagnosis: the scanner prints that the gate failed, not WHICH condition, so the failing
# conditions are listed below.
#
# This runs on a pull request too, and it is the only assertion that does. `new_coverage` is graded on
# new code, which is what a PR is; assertions 3, 4 and 5 are all push-scoped because they speak about
# the main branch.
# Two routes to the same answer. `analysisId` identifies exactly the analysis just verified, which is
# what this should judge; the scoped query asks about the PR or branch instead, which is very
# slightly weaker.
#
# **The fallback has never been taken, and that is now measured rather than assumed.** It was written
# because it had not been observed whether a pull-request CE task carries an `analysisId`. PR #35
# settled it: it does (`analysisId` present, `branch` empty, `pullRequest` set), so every real run so
# far — push and pull request alike — has gone down the first branch. The fallback was checked by
# querying it directly for PR #35 and it returned the same verdict, so it is correct; it is simply
# not exercised by any code path this repository has run. Kept as the safety net it was written to
# be, labelled honestly rather than described as though it were load-bearing.
#
# If BOTH come back unreadable this fails. A gate check that passes when it could not run is the
# failure mode of the four green runs that measured two files.
# Values are percent-encoded before they go into a query string. A branch named `x&y` would
# otherwise close the `branch=` parameter and open another, and the gate would grade something other
# than what this script reports it graded — the exact substitution the whole file exists to catch,
# reintroduced in its newest assertion.
urlenc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

analysis_id="$(field analysisId)"
gate_scope=""
if [ -n "$analysis_id" ]; then
    gate_scope="analysisId=$(urlenc "$analysis_id")"
elif [ -n "$analysed_pr" ]; then
    gate_scope="projectKey=$(urlenc "$PROJECT_KEY")&pullRequest=$(urlenc "$analysed_pr")"
else
    gate_scope="projectKey=$(urlenc "$PROJECT_KEY")&branch=$(urlenc "${analysed_branch:-$main_branch}")"
fi
# Fetched ONCE. Asking twice — once for the status, once for the conditions — allows the two to
# disagree, and the failure message would then list conditions from a different read than the verdict
# it is explaining.
gate_json="$(api "api/qualitygates/project_status?$gate_scope")"
gate_status="$(printf '%s' "$gate_json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("projectStatus",{}).get("status",""))' 2>/dev/null)"

case "$gate_status" in
    OK) ;;
    ERROR | WARN)
        failing="$(printf '%s' "$gate_json" | python3 -c '
import json, sys
for c in json.load(sys.stdin)["projectStatus"].get("conditions", []):
    if c.get("status") in ("ERROR", "WARN"):
        print("     %s  is %s, threshold %s %s"
              % (c.get("metricKey"), c.get("actualValue"), c.get("comparator"), c.get("errorThreshold")))
' 2>/dev/null)"
        die "the SonarQube quality gate is $gate_status for this analysis:
$failing
   These are measured over NEW code — the lines this change touched — not the whole project.
   Full report: $HOST/dashboard?id=$PROJECT_KEY"
        ;;
    NONE)
        # Not a pass. NONE means no condition was evaluated, which on a project that has a gate means
        # the gate was detached or emptied — a check silently stopping is the failure mode this
        # repository keeps finding, and it must not read as success.
        die "the quality gate reports NONE: no condition was evaluated for this analysis.
   A gate with nothing to say is not a gate that passed. Check the project's Quality Gate in SonarCloud."
        ;;
    *)
        die "could not read the quality gate status (got: '${gate_status}'). Treating an unreadable gate as a failure."
        ;;
esac
note_check "quality gate OK"

# The success line reports what THIS run verified, not the list of assertions in this file. On a pull
# request the commit, ncloc and coverage checks do not apply and are named as skipped, because the
# previous version printed both floors on a PR run that had applied neither — and rendered the skipped
# coverage check as the literal string `n/a (pull request)%`.
if [ -n "$analysed_pr" ]; then
    echo "sonar-verify: ok — $checked"
    echo "sonar-verify: not applicable to a pull-request analysis, and NOT checked: analysed commit,"
    echo "              ncloc floor, project coverage floor. Those speak about the main branch."
else
    echo "sonar-verify: ok — $checked"
fi

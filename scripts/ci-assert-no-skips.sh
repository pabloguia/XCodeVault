#!/bin/bash
# Fails when the test suite skipped anything.
#
# The committed baseline is **zero**, and it is a measurement, not an aspiration: the first CI run
# on 2026-09-18 executed all 275 tests on both `macos-15` and `macos-26` with nothing skipped. This
# is the control that keeps that true (issue #18).
#
# Why the *outcome* and not only the capabilities: `scripts/ci-environment-assertions.sh` checks a
# list of capabilities somebody maintains, and a skip introduced by a test gating on something not
# on that list would pass it. This reads what the suite actually did.
#
# Usage — pipe a test run through it, or hand it a saved log:
#
#     swift test 2>&1 | tee test.log; bash scripts/ci-assert-no-skips.sh test.log
#
# **It refuses to pass on a log it could not parse.** The number this asserts is zero, and "zero
# skips" and "I found no test summary at all" render identically if you only count. That mistake has
# been made three times in this repository — a `git grep` that blew the argument limit, a parser
# that stopped on a short header, a `grep -c … || echo 0` returning the string "0\n0" — each caught
# by a positive control. So: the summary line has to be there, and the executed count has to be
# non-zero, before the skip count means anything.
set -uo pipefail

log=${1:-}
if [ -n "$log" ]; then
    [ -r "$log" ] || { echo "no-skips: cannot read $log" >&2; exit 2; }
    text=$(cat "$log")
else
    text=$(cat)
fi

# xctest prints, per suite and once for the whole run:
#   Executed 341 tests, with 2 tests skipped and 0 failures (0 unexpected) in 60.1 seconds
summaries=$(printf '%s\n' "$text" | grep -E 'Executed [0-9]+ tests?,' || true)
if [ -z "$summaries" ]; then
    echo "no-skips: found no 'Executed N tests' line — the suite did not report, so this check says nothing." >&2
    echo "          Refusing to report ok: a check that cannot tell 'clean' from 'I did not run' is not a check." >&2
    exit 2
fi

# The whole-run line is the last one, and it is the one with the largest executed count.
executed=$(printf '%s\n' "$summaries" | sed -E 's/.*Executed ([0-9]+) tests?,.*/\1/' | sort -n | tail -1)
if [ -z "$executed" ] || [ "$executed" -eq 0 ]; then
    echo "no-skips: the suite reported 0 tests executed; that is a broken run, not a clean one." >&2
    exit 2
fi

# `with N test(s) skipped` is absent entirely when nothing skipped, so a missing match is 0 — but
# only now that the summary above is known to exist.
skipped=$(printf '%s\n' "$summaries" | sed -nE 's/.*with ([0-9]+) tests? skipped.*/\1/p' | sort -n | tail -1)
skipped=${skipped:-0}

if [ "$skipped" -gt 0 ]; then
    echo "no-skips: $skipped test(s) skipped; the committed baseline is 0." >&2
    echo "          A skipped test is a test that silently stopped running while the suite stayed green." >&2
    echo "          Run scripts/ci-environment-assertions.sh to see which capability is missing." >&2
    printf '%s\n' "$text" | grep -iE 'skipped' | head -20 >&2
    exit 1
fi

echo "no-skips: ok — $executed tests executed, 0 skipped"

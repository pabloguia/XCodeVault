#!/bin/bash
# Fails when a run leaves new `xcv-*` entries in $TMPDIR — the prefix this repository's tests and scripts
# give their scratch files, so that what they create can be told apart from every other tool's.
#
# Why: on 2026-10-25 the per-user temp directory held 27 `xcv-*` leftovers — nine journals from each
# `swift test` (R8OwnershipAppTests never removed its scratch files) and E20's dry-run and probe files.
# Each was small; the habit is what this guards, and a leak is cheapest to fix the day it appears.
#
#   tmp-leak-check.sh snapshot <file>   record the current `xcv-*` entries into <file>
#   tmp-leak-check.sh check <file>      exit 1, naming them, if any entry is new since <file>
#   tmp-leak-check.sh --self-test
#
# Kept on purpose and not counted: `xcv-snapshots` (visual-review output the snapshot tests write only when
# asked). Anything else a run means to keep belongs outside $TMPDIR. A concurrent run of the suite in another
# checkout can trip this; re-run before chasing it.
set -u -o pipefail

tmpdir() { local t="${TMPDIR:-/tmp}"; echo "${t%/}"; }
list() { find "$(tmpdir)" -maxdepth 1 -name 'xcv-*' ! -name 'xcv-snapshots' 2>/dev/null | sed 's#.*/##' | LC_ALL=C sort; }

case "${1:-}" in
    snapshot)
        [ -n "${2:-}" ] || { echo "usage: $0 snapshot <file>" >&2; exit 2; }
        list > "$2"
        ;;
    check)
        [ -r "${2:-}" ] || { echo "tmp-leaks: no snapshot at '${2:-}'" >&2; exit 2; }
        new=$(list | LC_ALL=C comm -13 "$2" -)
        if [ -n "$new" ]; then
            echo "tmp-leaks: this run left $(echo "$new" | wc -l | tr -d ' ') new xcv-* entr(y/ies) in $(tmpdir):" >&2
            echo "$new" | sed 's/^/  /' >&2
            exit 1
        fi
        ;;
    --self-test)
        work=$(mktemp -d) || exit 2
        trap 'rm -rf "$work"' EXIT
        mkdir "$work/T"
        export TMPDIR="$work/T"
        fail=0
        touch "$TMPDIR/xcv-old" "$TMPDIR/other"
        "$0" snapshot "$work/base" || fail=1
        "$0" check "$work/base" 2>/dev/null || { echo "FAIL: an unchanged directory was reported"; fail=1; }
        touch "$TMPDIR/not-ours"; mkdir "$TMPDIR/xcv-snapshots"
        "$0" check "$work/base" 2>/dev/null || { echo "FAIL: a non-xcv entry or xcv-snapshots was reported"; fail=1; }
        rm "$TMPDIR/xcv-old"
        "$0" check "$work/base" 2>/dev/null || { echo "FAIL: a removed entry was reported"; fail=1; }
        touch "$TMPDIR/xcv-new"
        out=$("$0" check "$work/base" 2>&1); rc=$?
        if [ "$rc" != 1 ] || ! echo "$out" | /usr/bin/grep -q 'xcv-new'; then echo "FAIL: a new xcv-* entry was not reported (exit $rc)"; fail=1; fi
        "$0" check "$work/missing" 2>/dev/null; [ $? = 2 ] || { echo "FAIL: a missing snapshot did not exit 2"; fail=1; }
        [ "$fail" = 0 ] && echo "tmp-leak-check self-test: ok"
        exit "$fail"
        ;;
    *)
        echo "usage: $0 snapshot <file> | check <file> | --self-test" >&2; exit 2
        ;;
esac

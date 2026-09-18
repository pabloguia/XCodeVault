#!/bin/bash
# PostToolUse hook (Edit|Write): lint edited Swift files with the toolchain's swift-format.
#
# THIS IS A CONVENIENCE, NOT A CONTROL — the same demotion `helper-guard.sh` received, and for
# better reasons. It guarantees nothing:
#
#   - Every exit path is 0. It prints; it never blocks. A file with lint errors is written anyway.
#   - It only sees Edit and Write. `cat >`, `sed -i`, `tee`, `git apply` and `git checkout` all
#     write Swift files without going near this hook.
#   - Truncation is silent past the cap below, so a file with fifty violations reports the first
#     few and says nothing about the rest — fixed by counting, but the cap still hides detail.
#
# The control is `.github/workflows/ci.yml`, which runs swift-format over the tree. If this hook
# and CI ever disagree, CI is right.
#
# The `--configuration` path is resolved from whichever tool is running: this file is mirrored
# byte-identically into `.codex/hooks/`, and the earlier version read `$CLAUDE_PROJECT_DIR`
# unconditionally — unset under Codex, so it linted against `/.swift-format`, swift-format errored,
# `2>&1` captured the error into `$out`, and it was printed as though it were lint output.
input=$(cat)
path=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)
case "$path" in *.swift) ;; *) exit 0;; esac
[ -f "$path" ] || exit 0
root="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
if [ -z "$root" ] || [ ! -f "$root/.swift-format" ]; then
    printf 'swift-format lint: skipped (no .swift-format config found); CI still lints this file\n'
    exit 0
fi
# A missing formatter is announced. Silence here is how a lint stops running without anyone noticing.
if ! fmt=$(xcrun --find swift-format 2>/dev/null); then
    printf 'swift-format lint: skipped (swift-format not in this toolchain); CI still lints this file\n'
    exit 0
fi
all=$("$fmt" lint --strict --configuration "$root/.swift-format" "$path" 2>&1)
if [ -n "$all" ]; then
    total=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
    printf 'swift-format lint (%s):\n%s\n' "$path" "$(printf '%s\n' "$all" | head -20)"
    [ "$total" -gt 20 ] && printf '... and %d more line(s) not shown\n' "$((total - 20))"
fi
exit 0

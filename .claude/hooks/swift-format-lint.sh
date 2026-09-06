#!/bin/bash
# PostToolUse hook (Edit|Write): lint edited Swift files with the toolchain's swift-format.
input=$(cat)
path=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)
case "$path" in *.swift) ;; *) exit 0;; esac
[ -f "$path" ] || exit 0
fmt=$(xcrun --find swift-format 2>/dev/null) || exit 0
out=$("$fmt" lint --strict --configuration "$CLAUDE_PROJECT_DIR/.swift-format" "$path" 2>&1 | head -20)
[ -n "$out" ] && printf 'swift-format lint (%s):\n%s\n' "$path" "$out"
exit 0

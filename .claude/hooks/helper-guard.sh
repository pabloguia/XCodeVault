#!/bin/bash
# PreToolUse hook (Edit|Write): block forbidden constructs in the privileged helper and in
# any file that would create the known-broken symlinks. Deterministic enforcement of
# docs/architecture/SECURITY_MODEL.md and NON_GOALS_AND_SAFETY.md.
input=$(cat)
path=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)
content=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("tool_input",{}); print(t.get("content") or t.get("new_string") or "")' 2>/dev/null)
[ -z "$path" ] && exit 0

deny() { echo "helper-guard: BLOCKED — $1 (see docs/architecture/SECURITY_MODEL.md)" >&2; exit 2; }

case "$path" in
  *Sources/XCodeVaultHelper/*|*Sources/XCodeVaultHelperProtocol/*)
    printf '%s' "$content" | grep -nE '/bin/(ba)?sh|\bsystem\(|\bpopen\(|"-c"|NSTask|launchPath *= *"/bin/|/usr/bin/env' >/dev/null && deny "shell or generic command execution in the privileged helper ($path)"
    printf '%s' "$content" | grep -nE 'AuthorizationCopyRights\(nil|AuthorizationCopyRights\(NULL|processIdentifier|SecCodeCopyGuestWithAttributes' >/dev/null && deny "forbidden peer-validation pattern (PID / NULL AuthorizationRef) in helper ($path)"
    printf '%s' "$content" | grep -nE 'shouldAcceptNewConnection[^\n]*\{[[:space:]]*return true' >/dev/null && deny "unconditional shouldAcceptNewConnection in helper ($path)"
    printf '%s' "$content" | grep -nE 'removeItem\(at: *[a-zA-Z_]*(path|url)[A-Za-z]*\)|rm -rf' >/dev/null && deny "generic deletion of a client-supplied path in helper ($path)"
    ;;
esac
case "$path" in
  *.swift|*.sh)
    printf '%s' "$content" | grep -nE 'csrutil (disable|enable)|nvram boot-args' >/dev/null && deny "SIP manipulation is never allowed"
    ;;
esac
exit 0

#!/bin/bash
# PreToolUse hook (Edit|Write): block forbidden constructs in the privileged helper, XPC client code,
# launchd plists and signing scripts. Deterministic enforcement of docs/architecture/SECURITY_MODEL.md
# and NON_GOALS_AND_SAFETY.md. FAILS CLOSED: any parsing problem blocks the edit.
input=$(cat)
if ! command -v python3 >/dev/null 2>&1; then echo "helper-guard: python3 missing — refusing to allow unchecked edits" >&2; exit 2; fi
# First line: file path (never contains a newline); remaining lines: the content to check.
parsed=$(printf '%s' "$input" | python3 -c '
import json,sys
d=json.load(sys.stdin); t=d.get("tool_input",{})
p=t.get("file_path","")
if "\n" in p: sys.exit(3)
print(p)
print(t.get("content") or t.get("new_string") or "", end="")' 2>/dev/null) || { echo "helper-guard: could not parse tool input — blocking" >&2; exit 2; }
path=$(printf '%s\n' "$parsed" | head -n 1)
content=$(printf '%s\n' "$parsed" | tail -n +2)
[ -z "$path" ] && exit 0

deny() { echo "helper-guard: BLOCKED — $1 (see docs/architecture/SECURITY_MODEL.md)" >&2; exit 2; }
has() { printf '%s' "$content" | grep -nE "$1" >/dev/null; }

case "$path" in
  *Sources/XCodeVaultHelper/*|*Sources/XCodeVaultHelperProtocol/*)
    has '/bin/(ba|z)?sh|\bsystem\(|\bpopen\(|posix_spawn|\bexec(v|ve|vp|l|lp|le)\(|NSTask|\bProcess\(|executableURL|launchPath|/usr/bin/env|xcrun|"-c"' \
      && deny "process/shell execution in the privileged helper ($path)"
    # `.run()` on anything except the main RunLoop (Process.run() is the exec API).
    printf '%s' "$content" | grep -nE '\.run\(\)' | grep -vE 'RunLoop' >/dev/null && deny "Process.run() in the privileged helper ($path)"
    has 'AuthorizationCopyRights|processIdentifier|SecCodeCopyGuestWithAttributes|audit_token_to_pid|xpc_connection_get_pid|SecCodeCheckValidity' \
      && deny "forbidden peer-validation pattern (PID / hand-rolled validation / AuthorizationCopyRights) in helper ($path)"
    if has 'shouldAcceptNewConnection' && ! has 'setCodeSigningRequirement'; then deny "connection acceptance without setCodeSigningRequirement ($path)"; fi
    has 'dlopen|Bundle\(path:|Bundle\(url:|\.load\(\)|NSBundle' && deny "dynamic code loading in the privileged helper ($path)"
    has 'removeItem\(at: *[a-zA-Z_]*(path|url|URL)[A-Za-z]*\)|rm -rf|chflags|chmod\(|\bchown\(' && deny "generic deletion/permission change of a client-influenced path in helper ($path)"
    has 'ownerUID|ownerGID|uid: *UInt32|gid: *UInt32' && deny "client-supplied uid/gid in the helper API — take identity from the connection ($path)"
    ;;
  *LaunchDaemons/*.plist)
    has 'SMAuthorizedClients|SMPrivilegedExecutables' && deny "SMJobBless-era keys in an SMAppService daemon plist ($path)"
    ;;
  *scripts/bundle-app.sh|*scripts/release.sh)
    has 'disable-library-validation' && deny "library validation must stay on ($path)"
    printf '%s' "$content" | grep -nE 'codesign.*--deep' | grep -E -- '--sign' >/dev/null && deny "never sign with --deep; sign inside-out ($path)"
    ;;
esac
case "$path" in
  *.swift|*.sh|*.plist)
    has 'csrutil (disable|enable)|nvram boot-args|amfi_get_out_of_my_way' && deny "SIP/AMFI manipulation is never allowed"
    ;;
esac
exit 0

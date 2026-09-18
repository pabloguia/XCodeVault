#!/bin/bash
# PreToolUse hook (Edit|Write): catch forbidden constructs in the privileged helper, XPC client code,
# launchd plists and signing scripts early, while an edit is being proposed.
#
# **This is a convenience, not a control, and it must not be cited as one.** It used to describe
# itself as "deterministic enforcement" that "fails closed"; a pre-publication review demonstrated
# otherwise, and a guard trusted more than it deserves is worse than no guard once outside
# contributors arrive. What it cannot do:
#
#   - It is wired to Edit|Write. `cat >`, `sed -i`, `tee`, `git apply` and `git checkout` are not
#     hooked at all, and neither is any other route that writes a file.
#   - It inspects the *proposed text*, not the resulting file. An edit whose new text is `// removed`
#     contains none of the strings any rule looks for, so deleting the code-signing requirement
#     passes cleanly.
#   - An edit payload with no `content`/`new_string` field yields an empty string, and every rule
#     then matches nothing and returns success.
#   - It is a raw text match, so it cannot tell a use from a mention: it has blocked a comment
#     explaining why a forbidden API is *not* used, and blocked the writing of the file-level
#     checker, which necessarily contains the patterns it searches for.
#
# The control is `scripts/helper-invariants.sh`, which checks the files as they are and runs in CI.
# Keep the two in step, and when they disagree, the file check is the one that decides.
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
  *Sources/XCodeVaultHelper/*|*Sources/XCodeVaultHelperCore/*|*Sources/XCodeVaultHelperProtocol/*)
    has '/bin/(ba|z)?sh|\bsystem\(|\bpopen\(|posix_spawn|\bexec(v|ve|vp|l|lp|le)\(|NSTask|\bProcess\(|executableURL|launchPath|/usr/bin/env|xcrun|"-c"' \
      && deny "process/shell execution in the privileged helper ($path)"
    # `.run()` on anything except the main RunLoop (Process.run() is the exec API).
    printf '%s' "$content" | grep -nE '\.run\(\)' | grep -vE 'RunLoop' >/dev/null && deny "Process.run() in the privileged helper ($path)"
    has 'AuthorizationCopyRights|processIdentifier|SecCodeCopyGuestWithAttributes|audit_token_to_pid|xpc_connection_get_pid|SecCodeCheckValidity' \
      && deny "forbidden peer-validation pattern (PID / hand-rolled validation / AuthorizationCopyRights) in helper ($path)"
    if has 'shouldAcceptNewConnection' && ! has 'setCodeSigningRequirement'; then deny "connection acceptance without setCodeSigningRequirement ($path)"; fi
    has 'dlopen|Bundle\(path:|Bundle\(url:|\.load\(\)|NSBundle' && deny "dynamic code loading in the privileged helper ($path)"
    # `atPath:` was missing, which is the form main.swift actually uses — the rule named the one
    # call in the tree it could not see. `fchown` stays unmatched on purpose: a descriptor already
    # opened O_NOFOLLOW is the safe form.
    has 'removeItem\(at(Path)?: *[a-zA-Z_]*(path|url|URL)[A-Za-z]*\)|rm -rf|chflags|[^f]\bchmod\(|(^|[^f[:alnum:]_])chown\(' && deny "generic deletion/permission change of a client-influenced path in helper ($path)"
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

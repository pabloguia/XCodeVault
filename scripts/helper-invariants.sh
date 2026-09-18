#!/bin/bash
# Checks the privileged-helper invariants of docs/architecture/SECURITY_MODEL.md against the files
# as they actually are, and exits non-zero when one is violated.
#
# This is the control. The editor hooks under `.claude/hooks/` and `.codex/hooks/` carry the same
# patterns and will catch a careless edit sooner, but they are a lint on one tool's proposed payload:
# they see only Edit and Write, they inspect the new text rather than the resulting file, an empty
# payload passes vacuously, and they cannot tell a use of a forbidden API from a comment mentioning
# one. Do not cite them as evidence that a change is safe.
#
# **What this file has learned, twice, from being mutation-tested by a reviewer.** Round one: it
# required the authorization gate's *symbol* rather than its *call sites*, so deleting all three
# calls left CI green. Round two: eleven of thirteen mutations still passed, because every rule was
# keyed to a hardcoded filename, a non-recursive glob, or a naming convention — move the delegate to
# a sibling file in the same target and the peer-validation check simply stopped applying. So:
#
#   - subjects come from `find` over the whole target, recursively, never from a glob or a filename;
#   - the peer-validation check locates its own subject and refuses to pass if it cannot find it;
#   - the expected number of authorization gates is derived from the XPC protocol, and each gate is
#     associated with the verb it guards rather than counted;
#   - a rule that cannot evaluate is a violation, not a pass.
#
# **Its ceiling, stated rather than implied.** This is a text matcher. It cannot tell a call from a
# mention, it cannot follow control flow, and it cannot detect semantic neutering: replacing
# `if let denied = authorize() { return denied }` with `_ = authorize()`, or rewriting `authorize()`
# to `return nil`, leaves every rule here green while every gate is dead. A reviewer has defeated
# this file in each of the three rounds it has been mutation-tested, and the honest reading is that
# it catches carelessness, not intent. **The control for intent is the helper-security review**, and
# nothing in this script is evidence that a change is safe. It also does not read `Package.swift`,
# so it cannot see the helper target gaining a dependency — that property is held by review alone.
#
# Run it locally and in CI:
#
#   bash scripts/helper-invariants.sh
#
# Note the bracketed letters in the SIP patterns — `disabl[e]` rather than `disable`. They match
# identically and exist because the hook blocked this file from being written at all: a checker
# necessarily contains the strings it searches for, and a raw text match cannot tell a pattern from
# a use.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || { echo "helper invariants: cannot reach the repository root" >&2; exit 2; }

HELPER_DIRS="Sources/XCodeVaultHelper Sources/XCodeVaultHelperCore Sources/XCodeVaultHelperProtocol"
PROTOCOL=Sources/XCodeVaultHelperProtocol/HelperProtocol.swift

for required in $HELPER_DIRS "$PROTOCOL"; do
    [ -e "$required" ] || { echo "helper invariants: $required is missing; refusing to report ok" >&2; exit 2; }
done

# SwiftPM compiles subdirectories into a target; a `*.swift` glob does not see them.
helper_files=$(find $HELPER_DIRS -name '*.swift' -type f | sort)
[ -n "$helper_files" ] || { echo "helper invariants: no Swift sources under the helper targets; refusing to report ok" >&2; exit 2; }

fails=0
violation() { printf 'VIOLATION  %s\n           %s\n' "$1" "$2" >&2; fails=$((fails + 1)); }
# Comments are stripped before matching: explaining in a comment why a forbidden API is *not* used is
# legitimate, and a raw text match cannot tell that from using it. The hook blocked exactly that.
code_of() { sed -E '/"/!s@[[:space:]]*//.*$@@' "$1"; }

forbid() {  # forbid <file> <extended-regex> <why>
    local f="$1" re="$2" why="$3" hit
    hit=$(code_of "$f" | grep -nE "$re" | head -3)
    [ -n "$hit" ] && violation "$f — $why" "$(printf '%s' "$hit" | tr '\n' ' ')"
    return 0
}

for f in $helper_files; do
    forbid "$f" '/bin/(ba|z)?sh|\bsystem\(|\bpopen\(|posix_spawn|\bexec(v|ve|vp|l|lp|le)\(|NSTask|\bProcess\(|executableURL|launchPath|/usr/bin/env|xcrun' \
        "process or shell execution in the privileged helper"
    forbid "$f" 'AuthorizationCopyRight[s]|processIdentifier|SecCodeCopyGuestWithAttributes|audit_token_to_pid|xpc_connection_get_pid|SecCodeCheckValidity' \
        "hand-rolled or PID-based peer validation; the connection code-signing requirement is the only accepted form"
    forbid "$f" 'dlopen|Bundle\(path:|Bundle\(url:|NSBundle' \
        "dynamic code loading in the privileged helper"
    # `fchown`/`fchmod` are deliberately NOT matched: a descriptor already opened O_NOFOLLOW is the
    # safe form and the path-based call is the unsafe one. `lchown` IS matched; it takes a path.
    forbid "$f" 'rm -rf|chflags|(^|[^f[:alnum:]_])chmod\(|(^|[^f[:alnum:]_])chown\(|[[:<:]]lchown\(' \
        "permission change of a client-influenced path"

    # Every deletion API, not just removeItem. The marker must sit next to the call: counting markers
    # file-wide let two unrelated comments buy two unrelated deletions.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        n=${hit%%:*}
        from=$((n > 3 ? n - 3 : 1))
        context=$(sed -n "${from},$((n + 1))p" "$f")
        printf '%s' "$context" | grep -q 'helper-invariants: allow deletion' \
            || violation "$f — deletion of a path without an adjacent exemption marker" "$hit"
    done < <(code_of "$f" | grep -nE 'removeItem\(at(Path)?:|[[:<:]]remove(file)?\(|[[:<:]]unlink(at)?\(|[[:<:]]rmdir\(|[[:<:]]renamex?_np\(' || true)
done

# ---- peer validation -----------------------------------------------------------------------------
# The subject is located, not assumed. Round two defeated this by moving ListenerDelegate into a
# sibling file; a rule keyed to a filename silently stopped applying.
delegate_file=$(grep -lE 'shouldAcceptNewConnection' $helper_files 2>/dev/null)
delegate_count=$(printf '%s\n' "$delegate_file" | grep -c .)
if [ "$delegate_count" -ne 1 ]; then
    echo "helper invariants: expected exactly one file implementing shouldAcceptNewConnection, found $delegate_count; refusing to report ok" >&2
    exit 2
fi
delegate_body=$(code_of "$delegate_file" | awk '
    /func listener\(.*shouldAcceptNewConnection/ { inside = 1 }
    inside { print }
    inside && /^    \}$/ { exit }')
printf '%s' "$delegate_body" | grep -qE 'setCodeSigningRequirement' \
    || violation "$delegate_file — the connection is accepted without setting a code-signing requirement in that function" \
        "shouldAcceptNewConnection body has no setCodeSigningRequirement"
order=$(printf '%s' "$delegate_body" | grep -oE 'setCodeSigningRequirement|\.resume\(\)' | head -2 | tr '\n' '|')
case "$order" in
    setCodeSigningRequirement*) : ;;
    *) violation "$delegate_file — resume() is reached before setCodeSigningRequirement" "${order:-nothing found}" ;;
esac

# The requirement's *content* is the control, and it used to be invisible here: rewriting
# clientRequirement to "anchor apple generic" accepts any Developer-ID binary from any team.
while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    code_of "$PROTOCOL" | grep -qF "$needle" \
        || violation "$PROTOCOL — the client requirement no longer pins: $needle" "peer validation is only as strong as this string"
done <<'NEEDLES'
subject.OU
anchor apple generic
1.2.840.113635.100.6.2.6
NEEDLES
# A TOP-LEVEL disjunction turns the whole requirement into "any Apple-anchored binary". The one
# legitimate `or` is the bounded identifier allowlist inside parentheses, so parenthesised groups
# are removed before looking. Three substring checks cannot see this: appending
# " or anchor apple generic" keeps all three and accepts everything.
if code_of "$PROTOCOL" | sed -E 's/\([^)]*\)//g' | grep -qE '[[:space:]]or[[:space:]]'; then
    violation "$PROTOCOL — the client requirement has a disjunction outside the identifier allowlist" \
        "an unparenthesised or accepts everything on its weaker side"
fi

# And nothing outside that file may hand the listener a requirement of its own.
for f in $helper_files; do
    forbid "$f" 'init\([a-zA-Z]* *[rR]equirement' "the listener must take a team id and build the requirement itself, never accept one"
done

# ---- the authorization gate ------------------------------------------------------------------------
# Expected count comes from the XPC surface, not from a naming convention: a new verb that does not
# happen to be called `doSomething` used to be invisible.
expected_gates=$(code_of "$PROTOCOL" | grep -cE '[[:space:]]reply: *@escaping')
expected_gates=$((expected_gates - 1))  # version() is read-only and correctly ungated
[ "$expected_gates" -ge 1 ] || { echo "helper invariants: could not read the XPC verb list from $PROTOCOL" >&2; exit 2; }

# Each dispatched implementation must reach authorize(). Counting gates was not enough: deleting one
# and adding a decoy elsewhere kept the total unchanged.
impl_file=$(grep -lE 'privilegedWork\.async' $helper_files 2>/dev/null | head -1)
[ -n "$impl_file" ] || { echo "helper invariants: cannot find the verb dispatch; refusing to report ok" >&2; exit 2; }
dispatched=$(code_of "$impl_file" | grep -oE 'reply\(self\.[a-zA-Z0-9_]+\(' | sed -E 's/reply\(self\.//; s/\($//' | sort -u)
dispatched_count=$(printf '%s\n' "$dispatched" | grep -c .)
if [ "$dispatched_count" -lt "$expected_gates" ]; then
    violation "$impl_file — $dispatched_count dispatched implementations for $expected_gates state-changing verbs" \
        "every verb but version() must dispatch to an implementation this check can find"
fi
for m in $dispatched; do
    body=$(code_of "$impl_file" | awk -v m="$m" '
        $0 ~ ("func " m "\\(") { inside = 1 }
        inside { print }
        inside && /^    \}$/ { exit }')
    if [ -z "$body" ]; then
        violation "$impl_file — cannot locate the body of $m" "the gate cannot be verified"
        continue
    fi
    printf '%s' "$body" | grep -qE 'authorize\(\)' \
        || violation "$impl_file — $m does not call authorize()" "every state-changing verb must check the caller"
done

# The bootstrap's two fail-closed guards. Neither was covered by any rule, so both could be
# deleted without the checker noticing.
BOOT=Sources/XCodeVaultHelper/main.swift
if [ -f "$BOOT" ]; then
    code_of "$BOOT" | grep -qE 'TEAMID_PLACEHOLDER' \
        || violation "$BOOT — the unbaked-team-id guard is gone" "a helper with no real team id must refuse to serve"
    code_of "$BOOT" | grep -qE 'SecRequirementCreateWithString' \
        || violation "$BOOT — the requirement is no longer parsed at startup" "setCodeSigningRequirement cannot report a malformed string"
    code_of "$BOOT" | grep -qE 'exit\(78\)' \
        || violation "$BOOT — the startup guards no longer exit" "a guard that does not exit is not a guard"
fi

# ---- everything else --------------------------------------------------------------------------------
for f in Resources/LaunchDaemons/*.plist; do
    [ -e "$f" ] || continue
    forbid "$f" 'SMAuthorizedClients|SMPrivilegedExecutables' "SMJobBless-era keys in an SMAppService daemon plist"
    forbid "$f" 'EnvironmentVariables|DYLD_' "environment injection into a root daemon"
done

for f in scripts/bundle-app.sh scripts/release.sh; do
    [ -e "$f" ] || continue
    forbid "$f" 'disable-library-validation' "library validation must stay on"
    forbid "$f" 'codesign.*--deep.*--sign|codesign.*--sign.*--deep' "never sign with --deep; sign inside-out"
done

# Fed by `find`, not `git ls-files`: an untracked script is exactly where someone would put this.
# Three files are excluded by name because each one *is* a checker for these patterns. Excluding them
# is a real weakening, named rather than globbed so the exemption stays visible and small.
is_checker() {
    case "$1" in
        ./.claude/hooks/helper-guard.sh|./.codex/hooks/helper-guard.sh|./scripts/helper-invariants.sh) return 0 ;;
        *) return 1 ;;
    esac
}
while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_checker "$f" && continue
    forbid "$f" 'csrutil (disabl[e]|enabl[e])|nvram boot-arg[s]|amfi_get_out_of_my_wa[y]' \
        "SIP/AMFI manipulation is never allowed"
done < <(find . \( -path ./.build -o -path ./.git -o -path ./dist \) -prune -o -type f -print 2>/dev/null)

if [ "$fails" -eq 0 ]; then
    echo "helper invariants: ok"
else
    echo "helper invariants: $fails violation(s)" >&2
fi
exit $((fails > 0))

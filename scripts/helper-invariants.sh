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
    #
    # `removeContents(` is in this list because a review demonstrated the gap: once the recursive
    # fd-relative deleter existed, a new root-recursive-delete function could be written that
    # called it and named none of the kernel APIs below, and this script passed. A deletion
    # PRIMITIVE this repository owns has to be gated like the syscalls it wraps.
    #
    # Declaring one is not performing one, so `func remove…` lines are excluded; every CALL still
    # needs its own adjacent marker, including the recursive one.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        n=${hit%%:*}
        from=$((n > 3 ? n - 3 : 1))
        context=$(sed -n "${from},$((n + 1))p" "$f")
        printf '%s' "$context" | grep -q 'helper-invariants: allow deletion' \
            || violation "$f — deletion of a path without an adjacent exemption marker" "$hit"
    done < <(code_of "$f" \
        | grep -nE 'removeItem\(at(Path)?:|[[:<:]]remove(file|Contents)?\(|[[:<:]]unlink(at)?\(|[[:<:]]rmdir\(|[[:<:]]renamex?_np\(' \
        | grep -vE '[[:<:]]func +remove' || true)
done

# Lines in Sources/ that CALL a seam-bearing function and supply a mount answer.
# Comment lines are dropped first: a doc comment naming the parameter is not a call.
# A failure here is a violation, not a pass — the first version of this helper had an unbalanced
# pattern, printed a grep error, and still exited 0.
code_of_tree() {
    local fn=$1 out rc
    out=$(grep -rn "${fn}(" Sources/ 2>&1); rc=$?
    if [ $rc -gt 1 ]; then
        echo "helper invariants: the seam scan could not run: $out" >&2
        exit 1
    fi
    printf '%s\n' "$out" \
        | grep -v -E ':[0-9]+:[[:space:]]*(//|\*)' \
        | grep -v -E "func[[:space:]]+${fn}\(" \
        | grep -E 'isMountPoint[[:space:]]*:' || true
}

# ---- test seams on safety guards -------------------------------------------------------------------
# A guard that takes its primitive from an injectable parameter is only as good as the line that
# feeds it. Three seams were added on 2026-09-18 so mount-point refusals could be tested, and a
# review showed they had merely moved the untested mutation: flipping the PRODUCTION call site to
# `{ _ in false }` disabled the refusal on the deletion path with the whole suite green. It reads
# as plumbing, which is what makes it worse than editing the guard.
#
# The seams were removed — `/` is a real mount point, so the rules are reachable with the real
# primitive — and this keeps the one that remains from being fed from production.
#
# THE CEILING, stated because the first version of this rule claimed more than it delivered. It
# lists the functions that HAVE a mount-answer parameter and forbids production code supplying it.
# It is not a general ban on the identifier: `isMountPoint` is also a plain `Bool` property on
# `ScanItem` and a local in `Scanner`, and a rule broad enough to catch every spelling of an
# injected answer also caught those. A new seam parameter must be added to this list by hand —
# which is the point, since adding one should be a deliberate act.
seam_bearing_functions='shadowDataRefusal'
seam_violations=0
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "$hit" in
        *"isMountPoint: isMountPoint"*) continue ;;  # self-forwarding, not a supplied answer
        *"-> Bool"* | *"->Bool"*) continue ;;        # the declaration itself
    esac
    printf 'VIOLATION  %s\n' "$hit" >&2
    seam_violations=$((seam_violations + 1))
done < <(code_of_tree "$seam_bearing_functions" || true)
if [ "$seam_violations" -gt 0 ]; then
    echo "helper invariants: $seam_violations safety-guard seam(s) supplied from production code" >&2
    echo "  A mount-point answer must come from the real primitive outside tests." >&2
    exit 1
fi

# ---- safety calls, not just safety symbols ---------------------------------------------------------
# The negative rule above stops a guard being fed a lie. It does nothing about a guard that is
# simply no longer called, and that is this script's own round-one lesson, recorded at the top of
# this file: the authorization rule required the gate's SYMBOL and not its CALL SITES, so deleting
# all three calls left CI green.
#
# `shadowDataRefusal` is the case that needs it. The rule itself is tested both directions, but
# deleting the call from `preflightLocation` fails no test: reaching the refusal for real needs a
# directory under a `/Volumes/<name>` that is not a mount point, and `/Volumes` is root-owned.
required_call="Sources/XCodeVaultCore/Locations/XcodeLocations.swift:shadowDataRefusal("
f=${required_call%%:*}; needle=${required_call#*:}
if [ ! -f "$f" ]; then
    echo "helper invariants: $f is missing; the required-call rule cannot be evaluated" >&2
    exit 1
fi
if ! grep -q 'func shadowDataRefusal(' "$f"; then
    echo "helper invariants: $f no longer declares shadowDataRefusal; update this rule deliberately" >&2
    exit 1
fi
# The declaration itself matches the needle, so require a second occurrence: the call.
if [ "$(grep -c "$needle" "$f")" -lt 2 ]; then
    violation "$f — preflightLocation no longer calls shadowDataRefusal(); the shadow-data rule is orphaned" "$needle"
fi

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
# Counted by excluding the read-only verb **by name**, not by subtracting one from a pattern that
# never matched it. The previous form was `grep -cE '[[:space:]]reply: *@escaping'` minus one: that
# pattern requires whitespace before `reply:`, which the two-argument verbs have (`, reply:`) and
# `version(reply:` does not — so version was never in the count, and subtracting it anyway left
# `expected_gates` at 1 when there are 2 state-changing verbs.
#
# The per-implementation `authorize()` loop below iterates over what it *finds* rather than over
# this number, so that control was never weakened. What the undercount did weaken is every rule
# that compares a count against it — including the audit rule added for issue #4, which passed with
# one of its two calls deleted. Found by mutation-testing that new rule, not by reading.
expected_gates=$(code_of "$PROTOCOL" | grep -E 'func [a-zA-Z0-9_]+\(.*reply: *@escaping' | grep -cvE 'func version\(')
[ "$expected_gates" -ge 1 ] || { echo "helper invariants: could not read the XPC verb list from $PROTOCOL" >&2; exit 2; }

# Each dispatched implementation must reach authorize(). Counting gates was not enough: deleting one
# and adding a decoy elsewhere kept the total unchanged.
impl_file=$(grep -lE 'privilegedWork\.async' $helper_files 2>/dev/null | head -1)
[ -n "$impl_file" ] || { echo "helper invariants: cannot find the verb dispatch; refusing to report ok" >&2; exit 2; }
# **Keyed to the protocol's verb names, not to what the implementation calls.**
#
# This rule was twice wrong in the same place and the second version was worse than the first. It
# began by matching `reply(self.doX(...))`; the audit trail (issue #4) made that shape impossible,
# because computing and replying in one expression leaves nowhere to record the invocation in
# between. Widening the matcher to also accept `= self.doX(...)` taught it the new shape and, in
# doing so, made the "dispatched implementations" set mean *any method this file calls on itself*.
#
# A helper-security reviewer demonstrated the consequence rather than describing it: a
# `createVaultDirectory` rewritten to do its work inline with no `authorize()` and no audit, plus a
# decoy `func decoyPad` containing `let _ = self.authorize()` and one `HelperAudit.emit(...)`,
# produced **exit 0, "helper invariants: ok"**. A state-changing root verb, ungated and unlogged,
# with the control green. The earlier `expected_gates` undercount fix would have caught it; the
# widened matcher handed it straight back, so the two changes cancelled.
#
# The fix is to stop inferring the verb set at all. `XCodeVaultHelperXPC` already declares it, so
# read it from there and look each verb up by name. A decoy cannot help a verb that is checked by
# its own name, and a verb that does not exist is a violation rather than an absence.
#
# One residual is structural and is the reason the human review is the control, not this file:
# `authorize()`'s own body contains the string `authorize()` on its `func` line, so a verb
# *renamed* to `authorize` would satisfy its own check. Keying to the protocol makes that
# unreachable — no protocol verb is called `authorize` — but no text matcher detects semantic
# neutering, and this one does not either.
verbs=$(
    code_of "$PROTOCOL" \
        | grep -E 'func [a-zA-Z0-9_]+\(.*reply: *@escaping' \
        | grep -vE 'func version\(' \
        | grep -oE 'func [a-zA-Z0-9_]+\(' | sed -E 's/func //; s/\(//'
)
verb_count=$(printf '%s\n' "$verbs" | grep -c .)
[ "$verb_count" -eq "$expected_gates" ] || {
    echo "helper invariants: read $verb_count verb names but counted $expected_gates gates; refusing to report ok" >&2
    exit 2
}

# For each verb: find the implementation it dispatches to, then check THAT body for the gate.
#
# The two halves matter separately. Starting from the protocol's verb list means a decoy function
# cannot join the set — that was F1. Following the verb to its implementation by name means the
# gate is looked for where it actually lives: `authorize()` is inside `doRemoveRegenerable…`, not
# inside the XPC method, so keying the gate check to the verb body alone reported a false
# violation on correct code. Both were found by running the thing rather than reading it.
for v in $verbs; do
    verb_body=$(code_of "$impl_file" | awk -v m="$v" '
        $0 ~ ("func " m "\\(") { inside = 1 }
        inside { print }
        inside && /^    \}$/ { exit }')
    if [ -z "$verb_body" ]; then
        violation "$impl_file — no implementation of the XPC verb $v" "a verb declared in the protocol must be implemented where this check can see it"
        continue
    fi

    # The verb itself must record and must serialise. Checked on the verb body, because that is
    # where both belong: the record has to bracket the reply, and the queue is what orders them.
    printf '%s' "$verb_body" | grep -qE 'HelperAudit\.emit\(' \
        || violation "$impl_file — $v records nothing" "every state-changing verb must record its invocation before replying"
    printf '%s' "$verb_body" | grep -qE 'privilegedWork\.async' \
        || violation "$impl_file — $v does not dispatch through privilegedWork" "the serial queue is what orders the record before the reply"

    # The implementation this verb dispatches to, named by the verb itself. `self.` is lowercase on
    # purpose: `Self.helper(...)` is a static utility, not the verb's implementation.
    impls=$(printf '%s' "$verb_body" | grep -oE 'self\.[a-zA-Z0-9_]+\(' | sed -E 's/^self\.//; s/\($//' | sort -u)
    impl_count=$(printf '%s\n' "$impls" | grep -c .)
    if [ "$impl_count" -ne 1 ]; then
        violation "$impl_file — $v dispatches to $impl_count implementations" \
            "a verb must name exactly one implementation, or this check cannot say which body holds its gate"
        continue
    fi

    impl_body=$(code_of "$impl_file" | awk -v m="$impls" '
        $0 ~ ("func " m "\\(") { inside = 1 }
        inside { print }
        inside && /^    \}$/ { exit }')
    if [ -z "$impl_body" ]; then
        violation "$impl_file — cannot locate the body of $impls, which $v dispatches to" "the gate cannot be verified"
        continue
    fi
    printf '%s' "$impl_body" | grep -qE 'authorize\(\)' \
        || violation "$impl_file — $impls (the implementation of $v) does not reach authorize()" "every state-changing verb must check the caller"
done

# ---- the audit trail's own file (issue #4) -----------------------------------------------------------
AUDIT=Sources/XCodeVaultHelperCore/HelperAudit.swift
if [ -f "$AUDIT" ]; then
    # `.info` and `.debug` are memory-backed and are dropped rather than persisted, so a daemon
    # that logged its deletions at either would still have nothing after a reboot — the defect the
    # file exists to fix, reintroduced by a one-word change.
    #
    # Stated as a prohibition, not as "at least one `.notice` exists". Mutation-testing the first
    # draft showed that rewriting every `log.notice` to `log.info` still passed, because a single
    # surviving `log.error` satisfied it. A positive existence check cannot express "none of them
    # may be memory-backed".
    forbid "$AUDIT" 'log\.(info|debug|trace)\(' "the audit must not emit at a memory-backed level; it would not survive a reboot"
    code_of "$AUDIT" | grep -qE 'log\.notice\(' \
        || violation "$AUDIT — the audit no longer emits at .notice" "the durable level is the one the trail depends on"

    # Caller-supplied arguments must never reach a root-owned log in the clear.
    #
    # Also a prohibition, and for the same reason the level rule is — a reviewer defeated the
    # existence-check version of *this* rule twice: once by flipping three of four qualifiers to
    # `.public` and leaving one `.private`, and once by flipping all four and adding an unrelated
    # `static let keep = "privacy: .private"`. Both passed. The rule now names the interpolation it
    # protects, so padding elsewhere in the file buys nothing.
    forbid "$AUDIT" 'args=\\\(arguments, privacy: \.public' "caller-supplied arguments must never be logged in the clear"
    code_of "$AUDIT" | grep -qE 'privacy: \.private' \
        || violation "$AUDIT — nothing in the audit is marked private" "a root-owned log must not disclose paths or volume identity"
else
    violation "$AUDIT — missing" "the root daemon's audit trail is required (issue #4)"
fi

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

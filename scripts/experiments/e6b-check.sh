#!/bin/bash
# E6b prerequisites — read-only, no sudo, safe to run any time.
#
# Issue #29 has been "blocked on hardware" since 2026-09-07, which is true but useless: it does not
# say *which* prerequisite is missing, so the only way to find out has been to sit down with a drive
# and discover it. This answers that in one command, before anyone clears a 7 GB cache or yanks a
# disk for nothing.
#
# It changes nothing and touches no mount. Every check below is a read.
source "$(dirname "$0")/common.sh"

TARGET="/Library/Developer/CoreSimulator/Caches/dyld"

# The report is built in a file and redacted on the way out, not printed directly.
#
# It names mounted volumes and running processes, and terminal output is what people paste into
# issues — including this project's. `xcv_redact` is the same filter every evidence file goes
# through, and `ExperimentScriptSafetyTests` requires every script here to use it. A pipe would put
# `ready` in a subshell and lose it, which is why the report is accumulated first.
REPORT="$(mktemp -t xcv-e6b-check)"
trap 'rm -f "$REPORT"' EXIT
ready=1
note() { printf '  %-6s %s\n' "$1" "$2" >>"$REPORT"; [ "$1" = "NO" ] && ready=0; return 0; }
say() { printf '%b\n' "$*" >>"$REPORT"; }

xcv_header "E6b prerequisites" >>"$REPORT"
say ""

# 1. The target must be empty or absent. A populated cache under a mount would confuse "macOS
#    recreated a stub" with "the old contents were always there" — a mount hides what is beneath it
#    and gives it back on unmount, which looks exactly like the thing being measured.
if [ ! -e "$TARGET" ]; then
    note "OK" "$TARGET is absent"
elif [ ! -r "$TARGET" ]; then
    # Not "empty": unreadable. `ls -A` on a root-owned path returns nothing for permission-denied
    # exactly as it does for an empty directory, and this script is deliberately no-sudo — so the
    # cheerful reading would be a false green on the one prerequisite that exists to stop two
    # different states being confused in the evidence.
    note "NO" "$TARGET is not readable by you, so its contents are unknown. Check with: sudo ls -A $TARGET"
elif [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    note "OK" "$TARGET is empty"
else
    size=$(du -sh "$TARGET" 2>/dev/null | cut -f1)
    note "NO" "$TARGET holds ${size:-content}. It is regenerable — this is the cache the canonical-mount"
    printf '         %s\n' "strategy targets — but clearing it costs a slow first boot per runtime, and" >>"$REPORT"
    printf '         %s\n' "\`xcodevaultctl clean\` CANNOT do it (privilege: .root; see issue #30)." >>"$REPORT"
fi

# 2. Nothing may be using the simulators. This machine's are used by test rigs; the runbook says to
#    check rather than assume, and this is that check.
# What matters is a *session* — someone's Xcode, a booted Simulator UI, a running xcodebuild — not
# CoreSimulator's launchd XPC services. `com.apple.CoreSimulator.CoreSimulatorService` and
# `SimulatorTrampoline` are on-demand services present on any machine that has ever booted a
# simulator; the first version of this matched them by the substring "Simulator", so it reported NO
# on a perfectly idle machine and no script could ever have run here. Probe 5 of the disconnect
# experiment deliberately restarts CoreSimulatorService, so treating it as a blocker was doubly wrong.
running=$(pgrep -lx "xcodebuild|Xcode|Simulator" 2>/dev/null | head -5)
if [ -z "$running" ]; then
    note "OK" "no Xcode, Simulator or xcodebuild session"
    ondemand=$(pgrep -l "CoreSimulatorService" 2>/dev/null | head -2)
    # `>>"$REPORT"`, like every other line here. Without it this printed straight to stdout — above
    # the header, outside the redactor — which is how one line escapes a rework whose whole point
    # was that nothing does.
    [ -n "$ondemand" ] \
        && printf '         %s\n' "(CoreSimulator's launchd XPC services are running; that is normal and not a blocker)" >>"$REPORT"
else
    note "NO" "an Xcode/Simulator/xcodebuild session is running; stop it or wait — this machine's"
    printf '         %s\n' "simulators are used by test rigs, so check whose it is before killing anything:" >>"$REPORT"
    printf '%s\n' "$running" | sed 's/^/         /' >>"$REPORT"
fi

# 3. A donor volume you can afford to yank.
# Exclude anything that is the boot volume. `/Volumes/MacOS` on this machine is a symlink to `/`,
# and a name filter let it through — so the script printed the boot volume under "pick one whose
# contents you would not miss". A name filter cannot know what a volume is; the target does.
donors=""
for v in /Volumes/*; do
    [ -e "$v" ] || continue
    [ "$(readlink "$v" 2>/dev/null)" = "/" ] && continue
    # By device, not by name. The comment above says a name filter cannot know what a volume is,
    # and this line contradicted it two lines later — `Macintosh HD` is not the only name a boot
    # volume can have, and a donor could legitimately be called that.
    [ "$(diskutil info "$v" 2>/dev/null | sed -n 's/^ *Part of Whole: *//p' | head -1)" \
        = "$(diskutil info / 2>/dev/null | sed -n 's/^ *Part of Whole: *//p' | head -1)" ] && continue
    donors="$donors$(basename "$v")\n"
done
donors=$(printf '%b' "$donors" | grep -v '^$' | head -5)
if [ -n "$donors" ]; then
    # Deliberately not "OK". This script cannot tell a scratch disk from someone's personal USB
    # drive, and the experiment physically disconnects the chosen one while a filesystem is mounted
    # over a system cache path. Naming that choice as satisfied would be the script deciding
    # something only the person holding the cable can.
    note "??" "volumes are mounted, but YOU must pick the donor — this yanks it mid-mount:"
    printf '%s\n' "$donors" | sed 's/^/         /' >>"$REPORT"
    printf '         %s\n' "Pick one whose contents you would not miss. Do not pick a working drive." >>"$REPORT"
    # `xcv_redact` rewrites EVERY non-boot volume label to `<vault>` — it has no registered-vault
    # concept. An earlier version of these lines said "<vault> is your REGISTERED VAULT — never pick
    # it", which made the one safety instruction in this script tell the operator that every option
    # was the one to avoid. They would have had to ignore it to proceed, which is poor training for a
    # warning that names a drive not to yank.
    printf '         %s\n' "Every volume name redacts to <vault>, so the above is a COUNT, not a list of names." >>"$REPORT"
    printf '         %s\n' "Run \`diskutil list\` to see the real names, and never pick this project's vault." >>"$REPORT"
else
    note "NO" "no external volume mounted"
fi

# 4. sudo. Not a blocker to arrange, but it decides whether this can run unattended — it cannot.
# Informational, not a blocker: the experiment blocks on a person pulling a cable anyway, so
# someone is standing there and can type a password. The first version set ready=0 here while the
# comment above it said "not a blocker to arrange" — the two disagreed and the code won.
if sudo -n true 2>/dev/null; then
    note "OK" "sudo needs no password"
else
    note "--" "sudo will prompt for a password. Not a blocker — you will be at the keyboard anyway."
fi

# 5. The built CLI, which the evidence header records the version from.
[ -x "$XCV_ROOT/.build/debug/xcodevaultctl" ] && note "OK" "xcodevaultctl is built" || note "NO" "run \`swift build\` first"

say ""
if [ "$ready" = 1 ]; then
    # Variant A first, matching the runbook. This line used to send a ready operator straight to the
    # physical variant while the runbook said the opposite — the two files in one change disagreeing
    # about run order.
    say "ready. Variant A first (software unmount), then variant B (physical yank):"
    say "  sudo scripts/experiments/e6b-mount-stub-reappearance.sh /Volumes/<donor>"
    say "  sudo scripts/experiments/e6b-physical-disconnect.sh   /Volumes/<donor>"
else
    say "not ready: the NO lines above are what issue #29 is actually blocked on, one at a time."
fi

xcv_redact < "$REPORT"

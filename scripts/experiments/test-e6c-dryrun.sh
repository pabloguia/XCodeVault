#!/bin/bash
# Exercises E6c's cleanup, teardown and abort paths — the ones that need root and a real donor,
# and that therefore had no test while four review rounds found six defects in them.
#
# How. A directory of recording stubs goes ahead of PATH; `diskutil`, `hdiutil`, `mount`,
# `umount` and `mount_apfs` log their arguments and return a status the scenario chose. The real
# script runs unmodified against them, so what is tested is the script, not a paraphrase of it.
#
# What this can and cannot see. It reaches every branch that depends on a command's STATUS or
# OUTPUT — the abort paths, the NOT MEASURED branches, the containment assert, cleanup's detach
# and its conditional delete. It cannot tell you what the real `diskutil` would have returned.
# That is the division of labour: this file pins the harness's reactions, and the experiment
# itself measures the system.
#
# **It already happened.** Before the evidence-directory guard and the `-DRYRUN` filename
# existed, dry runs written while building this harness landed in `docs/research/evidence/`
# under the canonical name, rotating the real E6c evidence to `-superseded-` and taking its
# place. Five fabricated matrices, one of them sitting where a reader would take it for the
# operator's run. Nothing was lost only because `xcv_rotate_out` exists — the control added
# after a 2026-09-15 overwrite is what saved this one. Both the guard and the filename marker
# are asserted below, because they were added and left unasserted, which is how they would have
# been removed just as quietly.
#
# **What this does NOT cover**, stated here so a green run is not read as more than it is:
#
#   - `shadow_check`'s payload. No scenario answers `diskutil info <donor-uuid>` with a mount
#     point, so every run takes the "the donor did not come back" branch and the DONOR ROOT
#     CHANGED path — safety rule 6's actual content — has never executed here.
#   - The `hdiutil attach -plist` stub emits JSON; the real one emits an XML plist. That is why
#     `plutil -convert json` exists in the script, and removing that stage would not be caught.
#   - The mount-table model is coarse: an unmount truncates the whole table, so a cleanup that
#     unmounts the wrong path, or only one of two, is invisible.
#   - `cleanup`'s own `$PROBE`/`$TARGET` unmount loop is UNREACHED. `cleanup-with-work` leaves a
#     mount standing, but at `/Volumes/elsewhere`, and the loop knows only those two paths by
#     construction. The state it exists for is a cell that mounts where asked and whose teardown
#     then refuses. I attempted that scenario and withdrew it: with `rc.diskutil.unmount` and
#     `rc.umount` both failing, the mount table verifiably still held the probe line at teardown
#     time (traced from inside the stub) and `cell` nevertheless reported the unmount as taken.
#     I could not account for that by reading, and a scenario whose name claims more than it
#     demonstrates is worse than a stated gap. Whoever picks this up: start by instrumenting
#     `cell`'s post-teardown `mount | grep` rather than the stub.
#   - The root refusal is pinned by expression and ordering, not by behaviour, and the reason is
#     the guard's own correctness — see the check itself.
#   - Account-name redaction, everywhere but `cell-d-at-dyld`. `id` is stubbed, so the redactor's
#     identity is empty and its account-name rule is a no-op unless a scenario answers `id -un`;
#     only that scenario does. A leak gate passing elsewhere says nothing about the rule.
#   - The re-entrancy guard inside `cleanup` is redundant given the signal ignore beside it;
#     deleting it alone changes nothing here, and the script says so where it is defined.
#
# Run: bash scripts/experiments/test-e6c-dryrun.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

fails=0
run=0
check() {  # check <name> <expected> <actual>
    run=$((run + 1))
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
        # The run's own last lines, because a boolean `no` says nothing about WHERE it stopped.
        # Three iterations of this harness were spent hand-rebuilding a scenario to find out.
        if [ -s "$WORK/last-out" ]; then
            printf '       --- last lines of %s ---\n' "${SCENARIO:-?}"
            tail -4 "$WORK/last-out" | sed 's/^/       | /'
        fi
        fails=$((fails + 1))
    fi
}
contains() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

SCENARIO=""
# An account name that cannot occur in the script's own output. The first draft used `dryrun`,
# which is a substring of the banner and of `dryrun-probe`, so the account-name leak gate refused
# to publish every scenario — correctly. The harness tripping the guard it exists to exercise is
# the guard working; picking a colliding name was the mistake.
FAKE_USER=zqxjkvuser
# PHYSICALLY resolved, for the reason `test-common.sh` documents: `mktemp -d` returns
# `/var/folders/...` and `/var` is a symlink to `/private/var`, so the symlink guard on the
# control directory refuses — correctly — and no scenario reaches a cell. The guard catching
# its own test harness is a point in the guard's favour.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# stub <name> — a recording shim. Each call appends its argv to $WORK/calls, then looks for its
# output and its exit status in the most specific file that exists:
#
#   out.<name>.<sub>.<lastarg>   rc.<name>.<sub>.<lastarg>     most specific
#   out.<name>.<sub>             rc.<name>.<sub>
#   out.<name>                   rc.<name>                     least specific
#
# Keyed on the last argument as well as the subcommand because a single answer per command is not
# a faithful stand-in: the first draft returned one `diskutil info` for every argument, so the
# donor and `/` reported the same whole disk and the boot-disk guard refused the run. The harness
# catching that is the harness working — an unrealistic stub is exactly the thing that makes a
# passing test meaningless.
# **No backticks inside the heredoc below.** Its delimiter is unquoted, so `$WORK` and `$name`
# expand at creation time — which is what makes the stub self-contained — and backticks are
# command substitution in exactly the same way. A comment written here with `mount` in backticks
# ran the real `mount` and embedded its output into the stub, which then tried to execute a mount
# table as shell. Text turning out to be executable, one more time.
#
# BEHAVIOUR, not just answers: `$WORK/script.<name>` is sourced first, with the stub's argv, and
# may rewrite the other stubs' answers. Static output cannot model state, and the script under
# test verifies state — it re-checks the mount table after an unmount, so a mount table that
# never changes makes every unmount "not take".
mkstub() {
    local name="$1"
    cat > "$WORK/bin/$name" <<STUB
#!/bin/bash
echo "$name \$*" >> "$WORK/calls"
[ -f "$WORK/script.$name" ] && . "$WORK/script.$name"
sub="\${1:-}"
case "\$sub" in -*) sub="" ;; esac
last="\${!#}"
key="\$(printf '%s' "\$last" | tr -c 'A-Za-z0-9' '_')"
for f in "$WORK/out.$name.\$sub.\$key" "$WORK/out.$name.\$sub" "$WORK/out.$name"; do
    [ -f "\$f" ] && { cat "\$f"; break; }
done
for f in "$WORK/rc.$name.\$sub.\$key" "$WORK/rc.$name.\$sub" "$WORK/rc.$name"; do
    [ -f "\$f" ] && exit "\$(cat "\$f")"
done
exit 0
STUB
    chmod +x "$WORK/bin/$name"
}

# scenario <name> — a clean slate: fresh stub dir, fresh evidence dir, fresh call log.
scenario() {
    rm -rf "$WORK/bin" "$WORK/ev"; mkdir -p "$WORK/bin" "$WORK/ev"
    # `script.*` too. Leaving them behind let one scenario's behaviour survive into the next:
    # a `script.umount` defined three scenarios earlier was still truncating the mount table,
    # so a cell whose teardown was supposed to FAIL reported success and the scenario tested
    # nothing. Cross-scenario contamination is how a suite comes to lie.
    rm -f "$WORK"/calls "$WORK"/rc.* "$WORK"/out.* "$WORK"/script.* "$WORK"/int1 "$WORK"/int2 "$WORK"/interrupted
    : > "$WORK/calls"
    for c in diskutil hdiutil mount umount mount_apfs stat log pgrep id; do mkstub "$c"; done
    # The in-hierarchy probe's PARENT. The script uses `mkdir` without `-p`, so whether this
    # exists is the whole difference between H1/H2 running and the H0 refusal branch — which is
    # how `hprobe-refused` below reaches that branch with no test-only switch in the script.
    mkdir -p "$WORK/ev/dryrun-hprobe-parent"
    SCENARIO="$1"; : > "$WORK/last-out"
}

# e6c — run the real script against the current scenario. Captures everything.
# `E6C_TARGET` picks the allowlisted target NAME. Every scenario ran `cryptex` until 2026-09-25, so
# the arm a real `dyld` run takes in `matrix` had never executed — and it was wrong.
e6c() {
    XCV_DRYRUN=1 XCV_STUB_BIN="$WORK/bin" XCV_DRYRUN_EVIDENCE_DIR="$WORK/ev" SUDO_USER="$FAKE_USER" \
        bash ./e6c-mount-mechanism.sh "/Volumes/DRYDONOR" "${E6C_TARGET:-cryptex}" 2>&1
}
# A FILE, not a variable: every call site is `out="$(run_e6c)"`, so an assignment inside would
# happen in the subshell and never reach `check`. That is the same shape as the defects this
# harness exists to catch, found in the harness itself within the hour.
run_e6c() {
    # The script's status, not `tee`'s. `e6c | tee` reports the pipeline's last command, so an
    # interrupted run came back 0 and the exit-130 check could never fail.
    e6c > "$WORK/last-out" 2>&1
    local rc=$?
    cat "$WORK/last-out"
    return "$rc"
}
calls() { cat "$WORK/calls" 2>/dev/null; }
# The published evidence. Most of the script's narration goes into the report via
# `exec >>"$REPORT" 2>&1`; only fd 3 reaches the terminal. A check that greps the terminal for a
# line the script writes to its report will fail for the wrong reason — which is how the first
# B0 scenario looked broken when it was working.
evidence() { cat "$WORK"/ev/*.txt 2>/dev/null; }

# ---- the mode's own guards, which are what keep a dry run from ever being a real one -----------
out="$(XCV_DRYRUN=1 XCV_STUB_BIN=/nonexistent XCV_DRYRUN_EVIDENCE_DIR=/tmp bash ./e6c-mount-mechanism.sh /Volumes/D cryptex 2>&1)"
check "a dry run without a stub directory is refused" "yes" "$(contains "needs XCV_STUB_BIN" "$out")"

scenario guards
out="$(XCV_DRYRUN=1 XCV_STUB_BIN="$WORK/bin" XCV_DRYRUN_EVIDENCE_DIR="$(cd ../.. && pwd)/docs/research/evidence" \
    bash ./e6c-mount-mechanism.sh /Volumes/D cryptex 2>&1)"
check "a dry run refuses to write to the real evidence directory" "yes" \
    "$(contains "refuses to write to the real evidence" "$out")"

# The inversion: the mode that skips the privilege check must be the mode that cannot have it.
#
# **This one cannot be behavioural, and the reason is the guard's own correctness.** `id -u` runs
# BEFORE `PATH` is prefixed with the stubs, deliberately: if it ran after, then
# `sudo XCV_DRYRUN=1 XCV_STUB_BIN=/evil …` would meet a stubbed `id` that lies, skip the root
# refusal, and proceed as root with an attacker's directory ahead of PATH. So a stub cannot reach
# it, and testing it for real needs root, which is the thing it forbids.
#
# What replaces a behavioural check is a source check pinned to the EXPRESSION and to the
# ORDERING, not to the message. The first version grepped for the refusal's text, so inverting
# the condition while leaving the message intact kept the suite green — an assertion that a
# string exists in a file.
# **Behaviourally, after all** — through a channel a PATH stub cannot use. `export -f id` puts
# `BASH_FUNC_id%%` in the environment and the child bash imports it; a function beats PATH
# lookup, so it reaches `id -u` even though that call deliberately runs BEFORE the stubs are
# prefixed. It does not reopen the hole that ordering closes: `sudo` under `env_reset` strips
# `BASH_FUNC_*` — the post-Shellshock hardening — and bash refuses to import functions across a
# privilege change, so `sudo XCV_DRYRUN=1 XCV_STUB_BIN=/evil` still cannot supply a lying `id`.
#
# The source pins below stay as the second and third lines of defence, and they are not
# sufficient alone: removing just the `exit 2` from the guard's body keeps the expression, the
# ordering and the message, and proceeds anyway. The status and the absence of the startup
# banner are what catch that.
rootout="$(bash -c 'id() { echo 0; }; export -f id
    XCV_DRYRUN=1 XCV_STUB_BIN="$1" XCV_DRYRUN_EVIDENCE_DIR="$2" \
        bash ./e6c-mount-mechanism.sh /Volumes/D cryptex 2>&1; echo "rc=$?"' _ "$WORK/bin" "$WORK/ev")"
check "a dry run that believes it is root refuses" "yes" "$(contains "must NOT run as root" "$rootout")"
check "and STOPS, rather than printing and proceeding" "yes" "$(contains "rc=2" "$rootout")"
check "and never reaches the stubs" "no" "$(contains "NOTHING IS MOUNTED" "$rootout")"

check "the root refusal is a real refusal, not just a message" "1" \
    "$(grep -cF '[ "$(id -u)" != 0 ] || {' ./e6c-mount-mechanism.sh)"
idline=$(grep -nF '[ "$(id -u)" != 0 ] || {' ./e6c-mount-mechanism.sh | head -1 | cut -d: -f1)
pathline=$(grep -nF 'PATH="$XCV_STUB_BIN:$PATH"' ./e6c-mount-mechanism.sh | head -1 | cut -d: -f1)
check "and it runs before the stubs reach PATH" "yes" \
    "$([ -n "$idline" ] && [ -n "$pathline" ] && [ "$idline" -lt "$pathline" ] && echo yes || echo no)"

# ---- the allowlist, which the dry-run target redirect must not touch --------------------------
# The script's own comment says this is asserted here. It was not — the property held only
# through `ExperimentScriptSafetyTests`, and a claim naming a control that does not exist sits
# exactly where a future reader looks before widening the redirect.
check "xcv_e6b_target still returns the real cryptex path" "/Library/Developer/CoreSimulator/Cryptex/Caches" \
    "$( . ./common.sh >/dev/null 2>&1; xcv_e6b_target cryptex )"
# The redirect exists once and is indented, i.e. inside a block — a top-level `TARGET=` would
# move the cache target in a REAL run. Counting dry-run guards would not say this: there are
# three of them.
check "the target redirect exists exactly once" "1" \
    "$(grep -cF 'TARGET="$XCV_EVIDENCE_DIR/dryrun-target"' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and is inside a block, not at top level" "0" \
    "$(grep -cE '^TARGET="\$XCV_EVIDENCE_DIR/dryrun-target"' ./e6c-mount-mechanism.sh | tr -d ' ')"

# ---- the donor cannot be resolved: nothing may be mounted, nothing published --------------------
# donor_ok — the stub answers that let a run reach the cells: the donor is an external APFS
# volume on its own physical disk, the target is an empty directory, no Xcode is running.
donor_ok() {
    printf '/dev/disk9s1 on /Volumes/DRYDONOR (apfs, local)\n' > "$WORK/out.mount"
    printf '   Device Node:               /dev/disk9s1\n   File System Personality:   APFS\n   Volume UUID:               AAAA-BBBB-CCCC\n   Part of Whole:             disk9\n   Mounted:                   Yes\n' \
        > "$WORK/out.diskutil.info._Volumes_DRYDONOR"
    # Keyed on the DEVICE, because the script now asks `diskutil info /dev/disk9s1` for the
    # device class rather than `diskutil info /Volumes/...` — which returned nothing on a real
    # run, since the donor is unmounted by then, while this stub answered a mount path forever.
    printf '   Part of Whole:             disk9\n   Protocol:                  Disk Image\n   Device Location:           External\n   Removable Media:           Fixed\n   Owners:                    Disabled\n   Virtual:                   Yes\n' \
        > "$WORK/out.diskutil.info._dev_disk9s1"
    # `/` on a DIFFERENT physical disk, or the boot-disk guard refuses — correctly — and the run
    # never reaches a cell.
    printf '   Part of Whole:             disk1\n' > "$WORK/out.diskutil.info__"
    echo 1 > "$WORK/rc.pgrep"
    # State: an unmount empties the mount table, so the script's own "did it take" check passes.
    # Without this the donor reads as still mounted and every run aborts before the first cell.
    cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in unmount|unmountDisk) : > "$WORK_DIR/out.mount" ;; esac
SCR
    cat > "$WORK/script.umount" <<'SCR'
: > "$WORK_DIR/out.mount"
SCR
    sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil" "$WORK/script.umount"
}

scenario no-donor
# A non-zero `mount` makes the donor read as "not a mount point", so resolution refuses.
# The comment is on its own line: `ExperimentScriptSafetyTests` forbids a backtick anywhere on
# an `echo` line, and while a trailing `#` comment is not command substitution, the check is
# deliberately line-based and conservative. Moving the comment is free; loosening the check to
# accommodate one line of mine is not the trade to make.
echo 1 > "$WORK/rc.mount"
out="$(run_e6c)"
check "an unresolvable donor stops before any mount" "no" "$(contains "mount_apfs" "$(calls)")"
check "and publishes nothing" "0" "$(ls -1 "$WORK"/ev/*.txt 2>/dev/null | wc -l | tr -d ' ')"

# ---- hdiutil create fails: B0 is NOT MEASURED, and no attach is attempted ----------------------
scenario b0-create-fails
donor_ok
echo 1 > "$WORK/rc.hdiutil.create"
out="$(run_e6c)"
check "a failed hdiutil create says so on the terminal" "yes" \
    "$(contains "B0's image could not be created" "$out")"
check "and records NOT MEASURED in the published matrix" "yes" \
    "$(contains "NOT MEASURED (hdiutil create failed)" "$(evidence)")"
check "and never attaches" "no" "$(contains "hdiutil attach" "$(calls)")"
# E's row must appear even here — an arm two levels above the recorder in an earlier version,
# which produced a matrix stamped `complete` with no E row at all.
check "and E is still recorded in the matrix" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: NOT MEASURED" "$(evidence)")"
check "and still publishes evidence" "1" "$(ls -1 "$WORK"/ev/*.txt 2>/dev/null | wc -l | tr -d ' ')"
# The two markers that stop a fabricated artifact from reading as real evidence. Both were
# added and neither was asserted — deleting either was silent, which is the same shape as the
# root-refusal grep.
check "the published file says it is fabricated" "yes" "$(contains "THIS IS A DRY RUN" "$(evidence)")"
# The SHIPPING matrix arm for `cryptex`. The arm used to be chosen by comparing `$TARGET` with a
# hardcoded `D_MEASURED_AT`, which the dry run had to move with the redirected target — and moving it
# hid the arm a real `dyld` run took. `matrix` now keys on the target NAME, which the redirect does
# not touch; `cell-d-at-dyld` below pins the other arm.
#
# **D is a RUN CELL as of 2026-09-24, not a carried-over value.** It used to be printed as
# "REFUSED (measured 2026-09-21, EPERM; not repeated here)", and this check asserted that string —
# so it would have gone on passing while the matrix reported a number measured in a different TCC
# context from every other cell in it. What has to be pinned now is that D is measured HERE and
# that the old value is labelled as the cross-context one it was.
check "D is a measured cell, not a carried-over value" "yes" \
    "$(contains "D. mount_apfs at the cache target:" "$(evidence)")"
check "and no run still prints the 2026-09-21 value as D's result" "no" \
    "$(contains "REFUSED (measured 2026-09-21, EPERM" "$(evidence)")"
check "and the older value is flagged as measured without Full Disk Access" "yes" \
    "$(contains "measured WITHOUT" "$(evidence)")"
check "and the A-vs-D reading rule is printed" "yes" \
    "$(contains "A MOUNTED, D REFUSED" "$(evidence)")"
check "and its filename does too" "yes" "$(contains "DRYRUN" "$(ls -1 "$WORK/ev")")"

# attached <store-disk> [volume-disk] — the stub answers that make an image attach and resolve.
#
# The volume NAME is derived from the recorded `hdiutil create` call, not hardcoded: the script
# builds it from its own `$$`, which is not the harness's. Writing `XCVB0-$$` here produced a
# name that never matched, so `B0_VOL` came back empty and every B0 scenario read as "volume did
# not resolve" instead of reaching the branch under test.
attached() {
    local store="$1" vol="${2:-disk21s1}"
    cat > "$WORK/script.hdiutil" <<'SCR'
case "${1:-}" in
    attach)
        printf '{"system-entities":[{"content-hint":"GUID_partition_scheme","dev-entry":"/dev/disk20"}]}\n' \
            > "$WORK_DIR/out.hdiutil.attach"
        ;;
    create)
        # The name the script chose, read back out of its own call, so `diskutil list` can answer
        # with a line the script's `awk` will match.
        n="$(grep -o -- '-volname [^ ]*' "$WORK_DIR/calls" | tail -1 | cut -d' ' -f2)"
        printf '   1:   APFS Volume %s   500.0 KB   %s\n' "$n" "VOL_DISK" > "$WORK_DIR/out.diskutil.list"
        ;;
esac
SCR
    sed -i '' -e "s|\$WORK_DIR|$WORK|g" -e "s|VOL_DISK|$vol|g" "$WORK/script.hdiutil"
    printf '   APFS Physical Store:       %s\n' "$store" > "$WORK/out.diskutil.info._dev_$vol"
}

# ---- the containment assert: a volume this run did not create must not be measured ------------
scenario b0-containment
donor_ok
# The image attached as disk20; the name-matched volume's physical store is disk30. The two are
# resolved independently, which is the only reason a disagreement is visible at all.
attached disk30s1 disk31s1
out="$(run_e6c)"
check "a volume on another disk fails containment" "yes" \
    "$(contains "CONTAINMENT FAILED" "$(evidence)")"
check "and is recorded as NOT MEASURED, not as a refusal" "yes" \
    "$(contains "NOT MEASURED (containment check failed)" "$(evidence)")"
check "and the operator is told on the terminal" "yes" \
    "$(contains "did not resolve to this run's own image" "$out")"
# The banner is not the behaviour: deleting the `B0_VOL=""` that a containment failure sets
# leaves both strings printing and then mounts the foreign volume anyway, which is the defect.
#
# Both words on one line, because the donor's own cells call `diskutil mount -mountPoint`
# legitimately and a bare match on that can never fail; and the foreign volume IS read —
# `diskutil info /dev/disk31s1` is how its physical store is resolved, which is the check
# working. What must never appear is a MOUNT of it.
#
# No `|| echo 0`: `grep -c` prints `0` AND exits 1 when it finds nothing, so the fallback fired
# on the passing case and produced "0\n0". Same family as the `| tail -40 || echo` in the script
# that a reviewer caught earlier today — a pipeline's status is not what it looks like.
foreign_mounts="$(grep -c 'mount.*disk31s1' "$WORK/calls" 2>/dev/null)"
check "and the foreign volume is never mounted" "0" "${foreign_mounts:-0}"

# ---- cleanup after an abort: the donor must come back, and nothing may stay mounted ------------
scenario cleanup-on-abort
donor_ok
echo 1 > "$WORK/rc.mount_apfs"        # every mount_apfs refuses
echo 1 > "$WORK/rc.diskutil.mount"    # and so does every diskutil mount
out="$(run_e6c)"
check "an all-refused run still publishes a matrix" "yes" "$(contains "matrix" "$(evidence)")"
# The capture actually runs here, and with the bounded window. This is the behavioural half of
# the source checks below: a refused cell reaches the DA-capture branch, so `log`'s argv proves
# what was asked for rather than what the source says.
check "a refused cell asks log show for a bounded window" "yes" \
    "$(grep -qE 'log show --start 20[0-9][0-9]-' "$WORK/calls" && echo yes || echo no)"
check "and never asks for a rolling one" "no" \
    "$(grep -q 'log show.*--last' "$WORK/calls" && echo yes || echo no)"

check "and hands the donor back by UUID" "yes" \
    "$(contains "diskutil mount AAAA-BBBB-CCCC" "$(calls)")"
# An all-refused run is a COMPLETE run — every cell answered. What must not pass silently is
# cell C, whose control refused: the matrix has to say so, because that block is what gets
# pasted into HYPOTHESES.md.
check "and marks cell C void because its control refused" "yes" \
    "$(contains "CELL C IS VOID" "$(evidence)")"
# The other side of the fail-vs-empty distinction, behaviourally. Here the `log` stub exits 0
# with no output, so the rc=0-empty line is actually produced; asserting it means both sides are
# verified by a run rather than one side by a run and the other by a grep of the source.
check "an empty window that succeeded says so" "yes" \
    "$(contains "log show rc=0" "$(evidence)")"
# The unfiltered count is the only in-band detector for a clock step or store lag, both of which
# return rc=0 with a header-only window. Deleting it survived every other check.
check "and reports the unfiltered line count beside it" "yes" \
    "$(contains "raw lines in window:" "$(evidence)")"

# ---- a capture that FAILS must not read as an empty window --------------------------------------
# The whole point of the change: `(no matching diskarbitrationd lines)` is the evidence for "the
# cache path produces no DiskArbitration transaction", so a `log show` that merely broke must not
# produce that line. A source-text check cannot see this — it greps the failure message, which a
# mutant leaves in place while making the branch unreachable. That mutant survived until this
# scenario existed. **Placed after `cleanup-on-abort` finishes, not inside it**: the first version
# was spliced in before that scenario's last two checks, and `scenario()` wipes `calls` and the
# evidence dir — so the donor-hand-back and C-void assertions silently began measuring this run
# instead, and passed, because neither depends on `rc.log`.
scenario log-show-fails
donor_ok
echo 1 > "$WORK/rc.mount_apfs"
echo 1 > "$WORK/rc.diskutil.mount"
echo 64 > "$WORK/rc.log"              # log show exits 64 on a malformed --start
# Two lines, in this order, because that is what `log show` really does: it writes its stdout
# header BEFORE any diagnostic, so on a failure that produced output `head -1` returns the header
# and silently drops the reason. With a one-line stub, `head -1` and `grep -m1 '^log:'` are
# indistinguishable and the mutant reverting to `head -1` survives — which it did.
printf 'Timestamp               Ty Process[PID:TID]\nlog: Failed conversion of '"''"' using format %s\n' "'%Y-%m-%d'" > "$WORK/out.log"
out="$(run_e6c)"
check "a failed log show is reported as a failure" "yes" \
    "$(contains "log show FAILED, rc=64" "$(evidence)")"
check "and is NOT reported as an empty window" "no" \
    "$(contains "no matching diskarbitrationd lines" "$(evidence)")"
check "and the reader is told not to read absence from it" "yes" \
    "$(contains "Do not read absence from this cell" "$(evidence)")"
check "and the reason is carried" "yes" \
    "$(contains "Failed conversion" "$(evidence)")"
check "and it is the reason, not log's own stdout header" "no" \
    "$(grep -q 'log show FAILED, rc=64: Timestamp' <<<"$(evidence)" && echo yes || echo no)"

# ---- cell D, the only genuinely new mount: the cases that would forge its value -----------------
# D is `mount_apfs` at the cache target, and the reading rule loads its REFUSED with "the only
# combination that isolates the cache directory". Two states would produce a REFUSED that means
# nothing: an ABSENT target (mount_apfs fails ENOENT) and a non-empty one. Cell C has aborted on
# both for four runs; D did not until now.
# **D's vanished-target abort is a SOURCE check, and here is what it cost to find that out.** The
# abort matters: the guard's emptiness test is `[ -e ] && [ -n "$(ls -A)" ]`, so an absent directory
# passes it, `mount_apfs` then fails ENOENT, and `cell` would record `D: REFUSED` — the value the
# reading rule loads with "the only combination that isolates the cache directory". Cell C has had
# this abort for four runs; D did not.
#
# Two behavioural routes tried and measured. Removing the target up front aborts at cell C's own
# existence check and never reaches D's. Hooking `script.diskutil`'s unmount to `rmdir` the target
# — which models H14's own phenomenon rather than inventing one — never fires: measured,
# `diskutil unmount` is called on that path **zero** times in that scenario, so no cell tears down
# there and the hook has nothing to run on. Why E and C do not unmount the target under
# `mounts_succeed` is unexplained, and a scenario whose mechanism I cannot account for is worse than
# a stated gap.
# **Pin the CONDITION, not the message.** The first version grepped for the abort's own text, and
# the mutant that replaces `if [ ! -d "$TARGET" ]` with `if false` leaves that text in the file while
# making the branch unreachable — it survived. Third time that shape has defeated a source check
# here; a grep for a string cannot see whether anything reaches it.
# Two of them: cell C's, which has existed for four runs, and cell D's, added 2026-09-24. Deleting
# either takes this to 1.
check "both cache-target cells abort on a vanished target, by condition not by message" "2" \
    "$(grep -vE '^[[:space:]]*#' ./e6c-mount-mechanism.sh | grep -cF 'if [ ! -d "$TARGET" ]; then' | tr -d ' ')"
check "and the abort says it will not forge the measurement" "1" \
    "$(grep -c 'vanished before cell D' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and says why it will not create it" "1" \
    "$(grep -c 'D. mount_apfs at the cache target: NOT MEASURED' ./e6c-mount-mechanism.sh | tr -d ' ')"

scenario cell-d-measures-when-it-mounts
donor_ok
attached disk20s1
mounts_succeed
# A deterministic `mount_apfs` stub. `mounts_succeed`'s version picks its target by scanning for the
# first `/*` argument, and measured, it did not put D's line in the table — D came out
# `REFUSED (exit 0)`, i.e. the command succeeded and `cell` found nothing mounted. Keyed on the LAST
# argument, which is what `mount_apfs` actually takes as the mount point.
cat > "$WORK/script.mount_apfs" <<SCR
t="\${!#}"
d=""
for a in "\$@"; do case "\$a" in /dev/*) [ -z "\$d" ] && d="\$a" ;; esac; done
[ -n "\$d" ] && [ -n "\$t" ] && printf '%s on %s (apfs, local, nobrowse)\n' "\$d" "\$t" >> "$WORK/out.mount"
SCR
out="$(run_e6c)"
check "D is recorded as MOUNTED when the mount takes" "yes" \
    "$(contains "D. mount_apfs at the cache target: MOUNTED" "$(evidence)")"
check "and D's own stat is recorded before it runs" "yes" \
    "$(contains "stat $WORK/ev/dryrun-target before cell D" "$(evidence)")"
check "and the A/H1/D rule is printed, not the bare A-vs-D one" "yes" \
    "$(contains "A, H1 AND D MOUNTED" "$(evidence)")"

# ---- the same full run at the `dyld` target: the arm no dry run had ever taken ------------------
# H14's own path. Until 2026-09-25 `matrix` decided D's arm by comparing `$TARGET` with a
# `D_MEASURED_AT` hardcoded to the cryptex path, so a real dyld run would have printed
# "D. mount_apfs at …/dyld: NOT MEASURED" above the D line it had just measured, and dropped the
# A/H1/D rules. No scenario ran dyld, so nothing could see it. Same stubs as the scenario above.
scenario cell-d-at-dyld
donor_ok
# The donor's standing line carries a user attribution, as the real one does: the new header line
# prints it, so the redaction of `mounted by <account>` has to be exercised, not assumed.
#
# **The redactor's identity has to be supplied, and the first two drafts of this scenario got it
# wrong.** `id` is one of the stubs, and a dry run is never root, so `xcv_identity` takes the
# non-root branch and asks the STUB for `id -un` — which answers nothing. The account-name rule
# then degenerates to an empty word, a no-op, **in every dry-run scenario**, while the publish gate
# hunts for `SUDO_USER`. Measured: with `$FAKE_USER` in the line the gate refused to publish; with
# the real `id -un` the name went out unredacted and the gate passed it. Answering `id -un` with the
# same account as `SUDO_USER` is the shape of a real run, where both identities are `SUDO_USER`.
echo "$FAKE_USER" > "$WORK/out.id.._un"
DRY_ACCOUNT="$FAKE_USER"
printf '/dev/disk9s1 on /Volumes/DRYDONOR (apfs, local, nodev, nosuid, journaled, noowners, mounted by %s)\n' "$DRY_ACCOUNT" > "$WORK/out.mount"
attached disk20s1
mounts_succeed
cat > "$WORK/script.mount_apfs" <<SCR
t="\${!#}"
d=""
for a in "\$@"; do case "\$a" in /dev/*) [ -z "\$d" ] && d="\$a" ;; esac; done
[ -n "\$d" ] && [ -n "\$t" ] && printf '%s on %s (apfs, local, nobrowse)\n' "\$d" "\$t" >> "$WORK/out.mount"
SCR
out="$(E6C_TARGET=dyld run_e6c)"
check "a dyld run publishes under the dyld name" "yes" "$(contains "e6c-mount-mechanism-dyld-DRYRUN" "$(ls -1 "$WORK/ev")")"
check "a dyld run records D as MOUNTED when the mount takes" "yes" \
    "$(contains "D. mount_apfs at the cache target: MOUNTED" "$(evidence)")"
# The CONDITION, observed through its output: the dyld arm's note is printed and the cryptex arm's
# is not. Swapping the arms, or keying them on anything the redirect changes, flips both.
check "and says D has no earlier baseline at this target" "yes" \
    "$(contains "no earlier run's D is a baseline for this one" "$(evidence)")"
check "and does not print the cryptex-only history as though it applied" "no" \
    "$(contains "measured WITHOUT" "$(evidence)")"
check "and never calls its own measured D NOT MEASURED" "0" \
    "$(evidence | grep -c 'D\. mount_apfs at .*: NOT MEASURED' | tr -d ' ')"
check "and prints the A/H1/D rules" "yes" "$(contains "A, H1 AND D MOUNTED" "$(evidence)")"
# The two header records added the same day: who placed the donor, measured before any cell, and
# the TCC indicator — which a dry run must NOT probe, since a builtin redirect cannot be stubbed.
check "the donor's standing mount is recorded before any cell" "yes" \
    "$(contains "donor standing mount (before any cell): /dev/disk9s1 on " "$(evidence)")"
check "and a dry run records that TCC was not probed" "yes" \
    "$(contains "TCC indicator: NOT PROBED (dry run)" "$(evidence)")"
check "the standing line's account name is redacted, and the run still publishes" "yes|no" \
    "$(contains "mounted by <user>" "$(evidence)")|$(contains "mounted by $DRY_ACCOUNT" "$(evidence)")"

# ---- a booted simulator refuses the run, however it was booted --------------------------------
# `simctl boot` from a headless rig starts neither Simulator.app nor xcodebuild, so the older check
# passed it. At `dyld` a runtime boot rebuilds the cleared cache under the mount. Keyed on the
# argument, so it is THIS pgrep that answers "running" and not the older one.
scenario booted-simulator-refuses
donor_ok
echo 0 > "$WORK/rc.pgrep..launchd_sim"
out="$(E6C_TARGET=dyld run_e6c)"
check "a booted simulator device refuses the run" "yes" "$(contains "A simulator device is booted" "$out")"
check "and nothing is mounted by either mechanism" "no|no" \
    "$(contains "mount_apfs" "$(calls)")|$(contains "diskutil mount" "$(calls)")"
check "and the refusal came from asking for launchd_sim" "yes" "$(contains "pgrep -qx launchd_sim" "$(calls)")"

# ---- a guard refusal must not force-unmount a stranger's filesystem -----------------------------
# The EXIT trap is armed BEFORE the pre-flight guards, and those guards refuse the run precisely
# when something is already mounted at one of the three paths. Cleanup then force-unmounted that
# filesystem on the way out — possibly this product's own vault, which `mount-staging.sh` names as
# the wrong outcome. Cleanup asks the anchored question instead — is one of THIS RUN's two devices
# mounted here — so a stranger's filesystem is reported and left alone at all three paths and on
# every abort path, including the target guard that runs AGAIN after the cells have really mounted
# things. An earlier `XCV_GUARDS_PASSED` flag could not cover that last case and was deleted.
scenario guard-refusal-leaves-foreign-mount-alone
donor_ok
# Something is already mounted at the control directory. The guard must refuse, and cleanup must
# keep its hands off it.
# The directory has to EXIST for this to be a real scenario: the script's mount check lives inside
# its `[ -e "$PROBE" ]` branch, so a mount table naming a path that does not exist never reaches
# the guard at all. My first version omitted the mkdir and the rc check passed anyway, for the
# wrong reason — the run was dying earlier.
mkdir -p "$WORK/ev/dryrun-probe"
# Appended, not written: `donor_ok` has already put the donor in this table and overwriting it
# makes the run die at "not a mount point" before it ever reaches the guard.
printf '/dev/disk77s1 on %s (apfs, local)\n' "$WORK/ev/dryrun-probe" >> "$WORK/out.mount"
out="$(run_e6c)"; rc=$?
check "the run refuses when the control dir is already mounted" "1" "$rc"
check "and does NOT unmount it" "no" \
    "$(grep -qE '(diskutil unmount|umount) .*dryrun-probe' "$WORK/calls" && echo yes || echo no)"
# **Path-anchored, and that matters twice over.** `contains "already mounted"` matched TWO
# different guards — `xcv_stage_guard_target`'s capital-S "Something is already mounted", which
# exits BEFORE the trap is armed and where cleanup never runs at all, and the probe guard's
# lower-case one. And the left-it-alone line is emitted per path, so an unanchored match passed on
# any of the three. Without the path in both, the scenario could pass having exercised neither the
# guard it is named for nor cleanup.
check "and it is the probe guard that refused, not the target guard" "yes" \
    "$(contains "something is already mounted at $WORK/ev/dryrun-probe" "$out")"
check "and cleanup names that path as one it left alone" "yes" \
    "$(contains "$WORK/ev/dryrun-probe is mounted by /dev/disk77s1, which is neither" "$out")"

# Same shape at the in-hierarchy probe, whose guard is a separate block.
scenario guard-refusal-at-hprobe
donor_ok
mkdir -p "$WORK/ev/dryrun-hprobe-parent/hprobe"
printf '/dev/disk88s1 on %s (apfs, local)\n' "$WORK/ev/dryrun-hprobe-parent/hprobe" >> "$WORK/out.mount"
out="$(run_e6c)"; rc=$?
check "a foreign mount at the in-hierarchy probe refuses the run" "1" "$rc"
check "and cleanup leaves it alone by name" "yes" \
    "$(contains "dryrun-hprobe-parent/hprobe is mounted by /dev/disk88s1, which is neither" "$out")"
check "and never unmounts it" "no" \
    "$(grep -qE '(diskutil unmount|umount) .*dryrun-hprobe-parent/hprobe' "$WORK/calls" && echo yes || echo no)"

# **The positive control for the anchor.** Everything above asserts cleanup does NOT unmount; all
# of it would pass if the loop unmounted nothing ever. Here the volume standing at the probe is
# OUR donor, so cleanup must tear it down — which is also the case an over-tight anchor breaks,
# leaving our own mount over a live path while the donor is remounted elsewhere.
scenario guard-refusal-with-our-own-volume
donor_ok
mkdir -p "$WORK/ev/dryrun-probe"
printf '/dev/disk9s1 on %s (apfs, local)\n' "$WORK/ev/dryrun-probe" >> "$WORK/out.mount"
out="$(run_e6c)"
check "a leftover mount of OUR OWN donor is torn down" "yes" \
    "$(grep -qE '(diskutil unmount|umount) .*dryrun-probe' "$WORK/calls" && echo yes || echo no)"
check "and is not reported as a stranger's" "no" \
    "$(contains "dryrun-probe is mounted by" "$out")"

# **B0's volume is the SECOND device that can be ours, and it has NO behavioural coverage.** An
# over-tight anchor — dropping `$B0_VOL` from the owner set — leaks a mount of ours over a live path
# while the donor is handed back elsewhere, the double-mount direction of rule 6. Only the text check
# below kills that mutant, and a text check cannot see reachability: it passes if `$B0_VOL` never
# resolves to a device node, and it fails on a reformat.
#
# Three routes tried and measured, so the next person does not re-walk them:
#
#   1. Inject `/dev/disk21s1` into the mount table from the `hdiutil create` stub. Does nothing —
#      that stub writes `out.diskutil.list`, and the table is only ever written by
#      `script.diskutil`'s `mount` arm. The scenario passed anyway, for reason 2.
#   2. Assert an unmount call in `$WORK/calls`. Cannot discriminate: the CELLS unmount the probe
#      too, so the grep passes whether cleanup ran or not.
#   3. Let the real flow mount B0's volume, then fail the probe's teardown (keyed `rc.diskutil.
#      unmount.<probe>` plus `rc.umount`) with a `script.diskutil` whose `unmount` arm spares the
#      probe, so B0's mount is still standing in cleanup and `COULD NOT UNMOUNT <path> (<device>)`
#      — a string only cleanup prints — names the device. This is the right shape and it did not
#      land: B0's cell runs and `disk21s1` reaches the call log, but the mount table ends EMPTY and
#      the run completes, so the teardown never failed. Unfinished, not disproven; the remaining
#      suspect is the `grep -v` in that unmount arm emptying the table when its target is absent.
#
# The `$TARGET` arm has no coverage either, and route 3 on cell E would give both at once.
check "both of this run's own devices are in cleanup's owner set (TEXT check — see above)" "1" \
    "$(grep -c 'for d in "\$XCV_DEV" "\$B0_VOL"; do' ./e6c-mount-mechanism.sh | tr -d ' ')"

# mounts_succeed — a mount ADDS to the mount table and an unmount removes from it. Without this
# every cell reads REFUSED, because the script verifies a mount by grepping the table for
# `<dev> on <dest>` and a static table never contains it. This is the smallest amount of state
# that makes a cell's success path reachable at all.
mounts_succeed() {
    cat > "$WORK/script.mount_apfs" <<'SCR'
d=""; t=""
for a in "$@"; do case "$a" in /dev/*) d="$a" ;; /*) t="$a" ;; esac; done
[ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local, nobrowse)\n' "$d" "$t" >> "$WORK_DIR/out.mount"
SCR
    cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    mount)
        d=""; t=""
        for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; done
        prev=""
        for a in "$@"; do [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
        # No `-mountPoint` is B3: DA picks the location, so the table gets /Volumes/<name>.
        # Without this, B3 never mounts in any scenario and its ANYWHERE handling — the branch
        # that stops "DA chose the place" from reading as MOUNTED ELSEWHERE — is never
        # exercised. It was a surviving mutant until this line existed.
        [ -n "$d" ] && [ -z "$t" ] && t="/Volumes/DRYDONOR"
        [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount"
        ;;
    unmount|unmountDisk) : > "$WORK_DIR/out.mount" ;;
esac
SCR
    sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.mount_apfs" "$WORK/script.diskutil"
}

# ---- the DiskArbitration bypass taint -----------------------------------------------------------
scenario da-bypass
donor_ok
attached disk20s1
mounts_succeed
# DA declines every unmount, so every teardown falls back outside it. The `umount` stub clears
# the table, so the fallback genuinely works and the run continues — which is the case that
# matters: a tainted run that LOOKS clean.
cat > "$WORK/script.umount" <<'SCR'
: > "$WORK_DIR/out.mount"
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.umount"
echo 1 > "$WORK/rc.diskutil.unmount"   # DA declines every unmount; teardown falls back outside it
out="$(run_e6c)"
check "a teardown outside DiskArbitration is recorded" "yes" \
    "$(contains "teardown: umount-f" "$(evidence)")"

# The taint marks REFUSED cells only, which is right: a cell that MOUNTED after a bypassed
# teardown is not misleading, and a cell that refused might be refusing because of the bypass.
# So the case to construct is a refusal DOWNSTREAM of one — here, C refuses at the cache path
# while the control cells mounted at the probe.
scenario da-bypass-then-refusal
donor_ok
attached disk20s1
mounts_succeed
cat > "$WORK/script.umount" <<'SCR'
: > "$WORK_DIR/out.mount"
SCR
# Mount everywhere EXCEPT the cache target, so C is the one refusal and it sits after two
# bypassed teardowns. Keyed on `dryrun-target`, because in a dry run the cache target is a
# scratch path — see the script's own comment for why it has to be.
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    mount)
        d=""; t=""; prev=""
        for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
        case "$t" in *dryrun-target*) ;; *) [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount" ;; esac
        ;;
    unmount|unmountDisk) : > "$WORK_DIR/out.mount" ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.umount" "$WORK/script.diskutil"
echo 1 > "$WORK/rc.diskutil.unmount"
out="$(run_e6c)"
check "a refusal after a bypassed teardown is marked VOID" "yes" \
    "$(contains "VOID: an earlier teardown bypassed DiskArbitration" "$(evidence)")"
check "and the cell that refused is cell C" "yes" \
    "$(contains "C. diskutil at the cache target" "$(evidence)")"

# ---- a leftover image from an earlier run must be unmatchable -----------------------------------
# The hazard the per-run volume name closes: a previous run that failed to detach leaves an
# `XCVB0` behind whose backing file is gone. A bare name match would select it, its mount would
# fail, and `cell` would record B0 REFUSED — which the reading rule turns into "E1b's call no
# longer works on this OS build". A harness artifact promoted to a finding about macOS, through
# the control added to prevent exactly that. Mutation-checked: removing `-$$` from the volume
# name makes this scenario fail.
scenario b0-stale-leftover
donor_ok
mounts_succeed
cat > "$WORK/script.hdiutil" <<'SCR'
case "${1:-}" in
    attach)
        printf '{"system-entities":[{"content-hint":"GUID_partition_scheme","dev-entry":"/dev/disk20"}]}\n' \
            > "$WORK_DIR/out.hdiutil.attach"
        ;;
    create)
        n="$(grep -o -- '-volname [^ ]*' "$WORK_DIR/calls" | tail -1 | cut -d' ' -f2)"
        # A STALE bare XCVB0 first, on a disk this run never attached, then ours.
        { printf '   1:   APFS Volume XCVB0   500.0 KB   disk99s1\n'
          printf '   2:   APFS Volume %s   500.0 KB   disk21s1\n' "$n"; } > "$WORK_DIR/out.diskutil.list"
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.hdiutil"
printf '   APFS Physical Store:       disk20s1\n' > "$WORK/out.diskutil.info._dev_disk21s1"
printf '   APFS Physical Store:       disk98s1\n' > "$WORK/out.diskutil.info._dev_disk99s1"
out="$(run_e6c)"
check "the stale leftover is not selected" "no" "$(contains "volume: /dev/disk99s1" "$(evidence)")"
check "this run's own volume is" "yes" "$(contains "volume: /dev/disk21s1" "$(evidence)")"
check "and B0 is measured rather than falsely refused" "no" \
    "$(contains "B0. E1b replicated, diskutil at the control dir (sparse image): REFUSED" "$(evidence)")"

# ---- cell E runs only behind its control ------------------------------------------------------
# E is the decisive cell after the 2026-09-21 run, and it means nothing without B0: it asks
# whether DA reaches the cache path using the one volume DA has agreed to mount.
scenario cell-e-with-control
donor_ok
attached disk20s1
mounts_succeed
out="$(run_e6c)"
# The matrix ROW, not the `====` section header: the header prints as soon as `cell` is called,
# so it passes even if the row is never emitted, and the row is what travels into HYPOTHESES.md.
check "E runs and lands in the matrix when its controls hold" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: MOUNTED" "$(evidence)")"
# Two listings per cell: one the instant the mount lands, one immediately before teardown. The
# second is the only record of what the window produced, and for cell E it is the only one that
# survives at all — its volume is detached and its backing file deleted.
check "each cell records the volume root after its window" "yes" \
    "$(contains "root after the window" "$(evidence)")"
# B3 — the plain mount, which the run was already performing in cleanup without recording it.
# H1/H2 — the in-hierarchy control. Without them the A-vs-D contrast cannot distinguish "this
# directory" from "this hierarchy", which is one of the two reasons the 2026-09-22 closure was
# retracted.
check "H1 mounts inside the CoreSimulator hierarchy" "yes" \
    "$(contains "H1. mount_apfs at a run-created dir INSIDE CoreSimulator: MOUNTED" "$(evidence)")"
check "and it is a DIFFERENT directory from the probe" "yes" \
    "$(grep -q 'mount_apfs -o nobrowse /dev/disk9s1 .*dryrun-hprobe-parent/hprobe' "$WORK/calls" && echo yes || echo no)"
# The real path, by source: in a dry run `$HPROBE` is redirected to scratch like `$PROBE`, so
# the property that makes it a control — being INSIDE the CoreSimulator hierarchy — cannot be
# exercised. Same limit as the allowlist check above, and the same remedy.
check "the in-hierarchy probe really is in the hierarchy" "1" \
    "$(grep -cF 'HPROBE=/Library/Developer/CoreSimulator/xcv-e6c-hprobe' ./e6c-mount-mechanism.sh)"
check "and cleanup removes it only if this run created it" "1" \
    "$(grep -cF '[ "$HPROBE_CREATED" = 1 ] && rmdir "$HPROBE"' ./e6c-mount-mechanism.sh)"
check "the target's entry count is recorded, not just its stat" "yes" \
    "$(grep -qE 'cache target: .* \(entries: [0-9]+\)' "$WORK"/ev/*.txt && echo yes || echo no)"
check "B3 asks DA for its own choice of location" "yes" \
    "$(contains "B3. diskutil with NO -mountPoint" "$(evidence)")"
check "and does so without a mount point" "yes" \
    "$(grep -qE 'diskutil mount /dev/disk9s1$' "$WORK/calls" && echo yes || echo no)"
# MOUNTED, not "MOUNTED ELSEWHERE": DA choosing the location is B3's entire point, and the cell
# has to read that as success rather than as the stray-mount failure it otherwise looks like.
# Two assertions, because `MOUNTED ELSEWHERE, not at ANYWHERE` CONTAINS `: MOUNTED` — the
# substring check passed on the mutant that broke exactly this behaviour. Positive and negative
# together are what pin it.
check "and a DA-chosen location reads as MOUNTED" "yes" \
    "$(contains "B3. diskutil with NO -mountPoint (the donor, DA's own choice of location): MOUNTED" "$(evidence)")"
check "and NOT as a stray mount" "no" \
    "$(contains "B3. diskutil with NO -mountPoint (the donor, DA's own choice of location): MOUNTED ELSEWHERE" "$(evidence)")"
# E0b — the depth control. Deleting the device-class loop and the E0b cell were both surviving
# mutants before these.
check "E0b runs after E, at E's own mount depth" "yes" \
    "$(contains "E0b. diskutil at the control dir a THIRD time (depth control for E): MOUNTED" "$(evidence)")"
check "the donor's device class is recorded, not blank" "yes" \
    "$(grep -qE '^-- /dev/disk9s1: .*Protocol=' "$WORK"/ev/*.txt && echo yes || echo no)"
check "and E0, its history control, ran first" "yes" \
    "$(contains "E0. diskutil at the control dir AGAIN, same image (history control): MOUNTED" "$(evidence)")"
check "and uses B0's image, not the donor" "yes" \
    "$(grep -q 'diskutil mount -mountPoint .*dryrun-target /dev/disk21s1' "$WORK/calls" && echo yes || echo no)"

scenario cell-e-without-control
donor_ok
# No `attached`: B0 cannot resolve a volume, so it is NOT MEASURED and E has no control.
out="$(run_e6c)"
check "E does not run when B0 did not mount" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: NOT MEASURED (no control)" "$(evidence)")"
# There is deliberately no "and the donor was not substituted for B0's image" check here: cell C
# legitimately runs `diskutil mount -mountPoint <target> <donor>`, so E-with-the-donor and C are
# indistinguishable by call shape, and a check that cannot tell them apart would pass either way.
# The NOT MEASURED line above is the property; this is the limit of what the call log can say.
check "and the rest of the matrix still runs" "yes" \
    "$(contains "C. diskutil at the cache target" "$(evidence)")"

# B0 resolves but DA REFUSES it — which is exactly what the 2026-09-21 run saw with the donor
# (status 0x4D). This is the case that makes E's control guard load-bearing: the volume exists,
# so the enclosing branch is entered, and only `CELL_RESULT_B0 = mounted` stops E from asking
# the decisive question with a volume DA has just declined.
scenario cell-e-control-refused
donor_ok
attached disk20s1
mounts_succeed
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    unmount|unmountDisk) case "${2:-}" in /dev/*) : > "$WORK_DIR/out.mount" ;; esac ;;
    mount)
        d=""; t=""; prev=""
        for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
        # B0's volume is declined; the donor's cells behave normally.
        case "$d" in
            /dev/disk21s1) ;;
            *) [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount" ;;
        esac
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil"
out="$(run_e6c)"
check "B0 refused is recorded as a refusal, not as unmeasured" "yes" \
    "$(contains "B0. E1b replicated, diskutil at the control dir (sparse image): REFUSED" "$(evidence)")"
check "and E is NOT MEASURED for want of a control" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: NOT MEASURED (no control)" "$(evidence)")"
check "and E0 did not run either" "no" \
    "$(contains "E0. diskutil at the control dir AGAIN" "$(evidence)")"
e_attempts="$(grep -c 'diskutil mount -mountPoint .*dryrun-target /dev/disk21s1' "$WORK/calls" 2>/dev/null)"
check "and E never asks its question with a declined volume" "0" "${e_attempts:-0}"

# ---- E0 refuses: the history case, which is what E0 exists to detect --------------------------
# B0's image mounts the FIRST time and is declined the SECOND. That is the shape the 2026-09-21
# run's B1 refusal is suspected to have, and if it is real then E's question cannot be asked
# with this volume — so E must not run. Without this scenario, "E no longer requires E0" was a
# surviving mutation: in every other scenario B0 mounting implies E0 mounting.
scenario e0-refuses-second-mount
donor_ok
attached disk20s1
mounts_succeed
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    # Every unmount clears the table, by device OR by path: a cell tears down by PATH, and an
    # unmount that does not take makes the cell abort before the next one runs.
    unmount|unmountDisk) : > "$WORK_DIR/out.mount" ;;
    mount)
        d=""; t=""; prev=""
        for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
        # B0's volume: accepted once, declined thereafter.
        if [ "$d" = /dev/disk21s1 ]; then
            if [ -f "$WORK_DIR/b0-mounted-once" ]; then exit 0; fi
            : > "$WORK_DIR/b0-mounted-once"
        fi
        [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount"
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil"
out="$(run_e6c)"
check "B0 mounted but E0 refused is recorded as such" "yes" \
    "$(contains "E0. diskutil at the control dir AGAIN, same image (history control): REFUSED" "$(evidence)")"
# The reason changed, and deliberately: "no control" and "E0 refused: mount history" are
# different findings, and printing the first beside a row reading `B0 …: MOUNTED` was a
# self-contradictory matrix.
check "and E does not run on a volume DA has started declining" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: NOT MEASURED (E0 refused: mount history)" "$(evidence)")"
e0_target="$(grep -c 'diskutil mount -mountPoint .*dryrun-target /dev/disk21s1' "$WORK/calls" 2>/dev/null)"
check "and never reaches the cache target with it" "0" "${e0_target:-0}"
check "and the matrix says the refusal follows mount history" "yes" \
    "$(contains "E0 REFUSED: DiskArbitration declined a volume it had just accepted" "$(evidence)")"

# ---- the target guard, re-run immediately before E, is the one with no test -------------------
# Deleting that guard left all 59 checks green: the safety-critical re-check before mounting over
# a real CoreSimulator path was the untested one. Injected by making B0's own mount drop a file
# into the target, so the emptiness check refuses on the next look.
scenario cell-e-target-guard-refused
donor_ok
attached disk20s1
mounts_succeed
cat >> "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    mount) [ -d "$WORK_DIR/ev/dryrun-target" ] && : > "$WORK_DIR/ev/dryrun-target/intruder" ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil"
out="$(run_e6c)"
check "a target that stopped being empty refuses E" "yes" \
    "$(contains "E. diskutil at the cache target, with B0's own image: NOT MEASURED (target guard refused)" "$(evidence)")"
guard_mounts="$(grep -c 'diskutil mount -mountPoint .*dryrun-target /dev/disk21s1' "$WORK/calls" 2>/dev/null)"
check "and nothing was mounted over it" "0" "${guard_mounts:-0}"

# ---- a failed attach must not bind to a name-matched volume ------------------------------------
# The other door on the same safety property as the containment assert: `hdiutil attach` fails,
# but the name scan still finds a volume. Only the attach-rc branch's `B0_VOL=""` stops it.
scenario b0-attach-fails
donor_ok
echo 1 > "$WORK/rc.hdiutil.attach"
cat > "$WORK/script.hdiutil" <<'SCR'
case "${1:-}" in
    create)
        n="$(grep -o -- '-volname [^ ]*' "$WORK_DIR/calls" | tail -1 | cut -d' ' -f2)"
        printf '   1:   APFS Volume %s   500.0 KB   disk21s1\n' "$n" > "$WORK_DIR/out.diskutil.list"
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.hdiutil"
printf '   APFS Physical Store:       disk20s1\n' > "$WORK/out.diskutil.info._dev_disk21s1"
out="$(run_e6c)"
check "a failed attach is NOT MEASURED, not bound by name" "yes" \
    "$(contains "NOT MEASURED (hdiutil attach failed)" "$(evidence)")"
attach_mounts="$(grep -c 'mount.*disk21s1' "$WORK/calls" 2>/dev/null)"
check "and that volume is never mounted" "0" "${attach_mounts:-0}"

# ---- a run that ABORTS mid-matrix still publishes what it had ---------------------------------
# Found by mutation, not by design: deleting `matrix "INCOMPLETE …"` from `cleanup` killed no
# check, because every scenario above either completes or stops before a cell. An all-refused
# run is COMPLETE — every cell answered — so it exercises `matrix "complete"`, not the abort
# path. This is the abort path: the donor's unmount does not take, so the run stops after the
# header with `XCV_RUN_FAILED=1`.
scenario abort-midway
donor_ok
cat > "$WORK/script.diskutil" <<'SCR'
: SCR
SCR
: > "$WORK/script.diskutil"
out="$(run_e6c)"
check "an aborted run publishes a FAILED file" "yes" \
    "$(contains "FAILED" "$(ls -1 "$WORK/ev" 2>/dev/null)")"
check "and its matrix is stamped INCOMPLETE, not complete" "yes" \
    "$(contains "matrix (INCOMPLETE" "$(evidence)")"
check "and it says the unmount did not take" "yes" \
    "$(contains "UNMOUNT DID NOT TAKE" "$out")"

# ---- the interrupt path, which had no coverage at all ------------------------------------------
# Three of the six historical defects live here: a second Ctrl-C re-entering cleanup, publishing
# twice, and `rm -f`-ing the report out from under the outer invocation. Nothing sent a signal
# until now, so all three would ship green.
#
# The signal is delivered by a stub: `diskutil unmount` kills its own process group's leader —
# the script — which puts the interrupt at a realistic moment, after staging and inside a
# teardown, rather than at an arbitrary sleep.
scenario interrupt-midway
donor_ok
mounts_succeed
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    unmount|unmountDisk)
        : > "$WORK_DIR/out.mount"
        # Interrupt the script that invoked us, once.
        if [ ! -f "$WORK_DIR/interrupted" ]; then : > "$WORK_DIR/interrupted"; kill -INT "$PPID" 2>/dev/null; fi
        ;;
    mount)
        d=""; t=""; prev=""
        for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
        [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount"
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil"
rc=0; out="$(run_e6c)" || rc=$?
check "an interrupted run exits 130" "130" "$rc"
# COUNTED, not matched. `shadow_check` remounts the donor too, so a single occurrence proves
# nothing about cleanup's: deleting cleanup's remount entirely still leaves one in the log.
# Cleanup's comes first, then shadow_check's.
remounts="$(grep -c 'diskutil mount AAAA-BBBB-CCCC' "$WORK/calls" 2>/dev/null)"
check "and both cleanup and shadow_check hand the donor back" "2" "${remounts:-0}"
check "and publishes exactly one file, not two" "1" \
    "$(ls -1 "$WORK"/ev/*.txt 2>/dev/null | wc -l | tr -d ' ')"
check "and does not claim its log could not be kept" "no" \
    "$(contains "could NOT be redacted" "$out")"

# ---- a SECOND interrupt, arriving while cleanup is already running -----------------------------
# The re-entrancy guard and the `trap ''` at the top of cleanup exist only for this, and one
# signal cannot reach either: deleting both left the suite green. Delivered deterministically
# rather than by racing — the stub fires the second INT from inside a command that only cleanup
# calls, the donor remount, so it lands in the middle of cleanup by construction.
scenario interrupt-then-term
donor_ok
mounts_succeed
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    unmount|unmountDisk)
        : > "$WORK_DIR/out.mount"
        if [ ! -f "$WORK_DIR/int1" ]; then : > "$WORK_DIR/int1"; kill -INT "$PPID" 2>/dev/null; fi
        ;;
    mount)
        # The donor remount by UUID is cleanup's; the second signal goes here.
        case "${2:-}" in
            AAAA-BBBB-CCCC)
                # TERM, not a second INT: bash holds a signal whose own handler is running, so
                # a second INT queues rather than re-entering. A DIFFERENT signal is not held,
                # and that is the case the re-entrancy guard and the `trap ''` exist for.
                if [ ! -f "$WORK_DIR/int2" ]; then : > "$WORK_DIR/int2"; kill -TERM "$PPID" 2>/dev/null; fi
                ;;
            *)
                d=""; t=""; prev=""
                for a in "$@"; do case "$a" in /dev/*) d="$a" ;; esac; [ "$prev" = "-mountPoint" ] && t="$a"; prev="$a"; done
                [ -n "$d" ] && [ -n "$t" ] && printf '%s on %s (apfs, local)\n' "$d" "$t" >> "$WORK_DIR/out.mount"
                ;;
        esac
        ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.diskutil"
rc=0; out="$(run_e6c)" || rc=$?
check "an INT then a TERM still exits 130" "130" "$rc"
# ZERO, not one: `there is no run log to write` is what the evidence writer prints when it is
# called a SECOND time, the report already gone. Its absence is the guard working. An earlier
# draft asserted 1, which is the symptom, not the cure.
# The COUNTED detector is the real one. A string-absence check is hostage to the wording in
# `mount-staging.sh` — reword the message and it is green forever — so the string is grepped out
# of that file rather than duplicated here, the way the `id -u` expression is pinned.
reentry_msg="$(grep -oF '!! there is no run log to write.' ../experiments/mount-staging.sh | head -1)"
check "the re-entry symptom string still exists to look for" "yes" \
    "$([ -n "$reentry_msg" ] && echo yes || echo no)"
reentries="$(grep -cF "$reentry_msg" "$WORK/last-out" 2>/dev/null)"
check "and cleanup does not run twice" "0" "${reentries:-0}"
check "and publishes exactly one file" "1" \
    "$(ls -1 "$WORK"/ev/*.txt 2>/dev/null | wc -l | tr -d ' ')"
check "and never says its log could not be kept" "no" \
    "$(contains "could NOT be redacted" "$out")"
# Counted, because deleting BOTH defences lets cleanup run start to finish a second time and
# every string-based symptom still looks normal. The teardown work is what doubles.
term_remounts="$(grep -c 'diskutil mount AAAA-BBBB-CCCC' "$WORK/calls" 2>/dev/null)"
check "and does not repeat cleanup's teardown work" "yes" \
    "$([ "${term_remounts:-0}" -le 2 ] && echo yes || echo no)"

# ---- cleanup with work to do: something still mounted, and B0 still attached --------------------
# The unmount loop and the B0 detach were unREACHED, not merely unasserted: no scenario left
# anything mounted or `$B0_DEV` set at the moment cleanup ran. This is the abort those blocks
# were written for — B0's cell returns 1 because the mount lands somewhere other than asked.
scenario cleanup-with-work
donor_ok
attached disk20s1
cat > "$WORK/script.hdiutil" <<'SCR'
case "${1:-}" in
    attach)
        printf '{"system-entities":[{"content-hint":"GUID_partition_scheme","dev-entry":"/dev/disk20"}]}\n' \
            > "$WORK_DIR/out.hdiutil.attach"
        ;;
    create)
        n="$(grep -o -- '-volname [^ ]*' "$WORK_DIR/calls" | tail -1 | cut -d' ' -f2)"
        printf '   1:   APFS Volume %s   500.0 KB   disk21s1\n' "$n" > "$WORK_DIR/out.diskutil.list"
        ;;
esac
SCR
# The mount lands at /Volumes/elsewhere instead of the probe — DiskArbitration's documented
# fallback — and every unmount refuses, so cleanup inherits both a live mount and a live image.
# The DONOR's unmount must succeed — the script verifies it and aborts otherwise, before any
# cell. Only the cell teardowns refuse. The two are told apart by their argument: the donor is
# unmounted by device, a cell by path.
cat > "$WORK/script.diskutil" <<'SCR'
case "${1:-}" in
    unmount|unmountDisk)
        case "${2:-}" in /dev/*) : > "$WORK_DIR/out.mount" ;; esac
        ;;
    mount) printf '/dev/disk21s1 on /Volumes/elsewhere (apfs, local)\n' >> "$WORK_DIR/out.mount" ;;
esac
SCR
sed -i '' "s|\$WORK_DIR|$WORK|g" "$WORK/script.hdiutil" "$WORK/script.diskutil"
printf '   APFS Physical Store:       disk20s1\n' > "$WORK/out.diskutil.info._dev_disk21s1"
# Every unmount refuses EXCEPT the donor's, which the script verifies and aborts on. The stub's
# own specificity does this: `rc.<cmd>.<sub>.<last-arg>` beats `rc.<cmd>.<sub>`.
echo 1 > "$WORK/rc.diskutil.unmount"
echo 0 > "$WORK/rc.diskutil.unmount._dev_disk9s1"
echo 1 > "$WORK/rc.umount"
# And the detach refuses too, so cleanup must keep the image file rather than delete it under a
# live device — the branch that replaced an unconditional `rm -rf`.
echo 1 > "$WORK/rc.hdiutil.detach"
out="$(run_e6c)"
# `MOUNTED ELSEWHERE` is the report's wording; the terminal gets "mounted somewhere other than".
check "a mount that lands elsewhere is not recorded as a refusal" "yes" \
    "$(contains "MOUNTED ELSEWHERE" "$(evidence)")"
check "and the operator is told on the terminal" "yes" \
    "$(contains "mounted somewhere other than" "$out")"
check "cleanup tries to detach B0's image" "yes" "$(contains "hdiutil detach" "$(calls)")"
check "and when that fails, keeps the file instead of deleting it under a live device" "yes" \
    "$(contains "STILL ATTACHED" "$out")"

# The H0 branch: the in-hierarchy probe cannot be created. **The errno here is `ENOENT`** — the
# parent is missing — and NOT the real case's refusal, whatever that turns out to be. This pins
# the plumbing (the branch runs, the run continues, the text reaches the evidence); it reproduces
# nothing about the hierarchy. Before 2026-09-22 the script aborted
# the whole run here, so this branch — and the H1/H2 `else` — were unreachable and untested while
# the operator's real sudo run was walking straight into them.
scenario hprobe-refused
donor_ok
attached disk20s1
mounts_succeed
rmdir "$WORK/ev/dryrun-hprobe-parent"
out="$(run_e6c)"; rc=$?
check "a probe that cannot be created does not abort the run" "0" "$rc"
check "and the other cells still run" "yes" "$(contains "mount_apfs -o nobrowse /dev/disk9s1" "$(calls)")"
check "the refusal is recorded as a cell, not swallowed" "yes" "$(contains "H0." "$(evidence)")"
check "H0 is labelled as being about mkdir and not about mounting" "yes" \
    "$(contains "mkdir (not mount)" "$(evidence)")"
check "the errno text is carried into the evidence" "yes" \
    "$(contains "No such file or directory" "$(evidence)")"
check "H1/H2 are skipped rather than reported" "yes" "$(contains "H1/H2. in-hierarchy control: NOT MEASURED" "$(evidence)")"
check "and nothing was mounted at the probe that does not exist" "no" \
    "$(contains "dryrun-hprobe-parent/hprobe" "$(calls)")"
check "the legend explains H0 only when H0 happened" "yes" "$(contains "H0 REFUSED" "$(evidence)")"
check "and warns that H0 does not explain D" "yes" "$(contains "does not explain D" "$(evidence)")"
check "the operator is told on the terminal, not only in the report" "yes" \
    "$(contains "recorded as H0" "$out")"
# The legend must not appear on runs where the probe WAS created: one machine's mkdir result
# stated as though every report had measured it is the defect this gate exists to stop.
scenario hprobe-created
donor_ok
attached disk20s1
mounts_succeed
out="$(run_e6c)"
check "the H0 legend is absent when the probe was created" "no" "$(contains "H0 REFUSED" "$(evidence)")"
check "and H1 ran instead" "yes" "$(contains "H1. mount_apfs" "$(evidence)")"

# The probe passes its guard at startup and is mounted at five cells later. This dirties it in
# between — cell A's `mount_apfs` drops a file into it — so the revalidation immediately before
# H1 is the only thing standing between the run and a mount that hides someone's data. Deleting
# that revalidation survived mutation until this scenario existed.
scenario hprobe-dirtied
donor_ok
attached disk20s1
mounts_succeed
cat >> "$WORK/script.mount_apfs" <<SCR
case "\${!#}" in *dryrun-probe) : > "$WORK/ev/dryrun-hprobe-parent/hprobe/intruder" ;; esac
SCR
out="$(run_e6c)"
check "a probe dirtied after its guard is not mounted over" "no" \
    "$(grep -q 'mount_apfs -o nobrowse /dev/disk9s1 .*dryrun-hprobe-parent/hprobe' "$WORK/calls" && echo yes || echo no)"
check "and the operator is told why" "yes" "$(contains "no longer empty" "$out")"

# The rolling-window defect. `log show --last 60s` after the cell makes a refused cell replay its
# predecessors: C's block came out byte-identical to B2's in three runs, and two readings were
# built on the inherited lines and retracted. Pinned at the source AND behaviourally — an earlier
# version of this comment claimed the stub could not catch it, which was wrong: `log` is stubbed
# and every stub records its argv, so `cleanup-on-abort` (where every mount refuses) drives the
# refused branch and the capture with it.
check "the DA window is bounded by the cell's own start" "1" \
    "$(grep -c 'log show --start "\$cell_log_start"' ./e6c-mount-mechanism.sh | tr -d ' ')"
# Comment lines excluded on purpose: the comment explaining the defect names `log show --last`,
# and the first version of this check matched its own documentation.
# `--last` ANYWHERE on a `log show` line, not the adjacency `log show --last`: appending
# `--last 60s` after `--start` restores the defect and the adjacency grep cannot see it.
check "and no log show carries --last at all" "0" \
    "$(grep -vE '^[[:space:]]*#' ./e6c-mount-mechanism.sh | grep 'log show' | grep -c -- '--last' | tr -d ' ')"
# The format too: `date '+%Y-%m-%d'` is also accepted by `log show` and restores a 24-hour window.
# **The SIP-policy block, and why these are TEXT checks.** The defect was `grep | sed || echo`: the
# `||` binds to the pipeline, whose status is `sed`'s, and `sed` exits 0 on empty input, so the
# fallback never fired and a machine with no match got a silent blank — indistinguishable from "this
# check did not run". It is unreachable behaviourally from here: this machine's `rootless.conf` DOES
# match, so both the correct and the defective form print the same thing, and the dry run reads the
# real file. So: pin the shape. Capture into a variable first, and keep the three outcomes distinct.
check "the rootless capture is not bound to a pipeline's exit status" "1" \
    "$(grep -c 'xcv_rootless_hits="$(grep -i developer' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and an unreadable file is not reported as an absence" "1" \
    "$(grep -c 'NOT CHECKED, which is not the same as no entry' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and a real absence is RECORDED rather than left blank" "1" \
    "$(grep -c 'absence RECORDED, file was readable' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and no sed-then-fallback pipeline survives in that block" "0" \
    "$(grep -vE '^[[:space:]]*#' ./e6c-mount-mechanism.sh | grep -c "rootless.conf 2>/dev/null | sed" | tr -d ' ')"

check "the timestamp carries time and offset, not just the date" "1" \
    "$(grep -c "date '+%Y-%m-%d %H:%M:%S%z'" ./e6c-mount-mechanism.sh | tr -d ' ')"
# The failure this whole change is about: a capture that fails must not read as an empty window,
# because an empty window IS the evidence for "the cache path produces no DA transaction".
check "a failed log show is distinguished from an empty window" "1" \
    "$(grep -c 'log show FAILED, rc=' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "and the empty case says the capture succeeded" "1" \
    "$(grep -c 'no matching diskarbitrationd lines; log show rc=0' ./e6c-mount-mechanism.sh | tr -d ' ')"
check "the start is captured before the command runs, not after" "yes" \
    "$(awk '/cell_log_start=/{c=NR} /xcv_run "\$label"/{r=NR} END{print (c>0 && r>0 && c<r) ? "yes" : "no"}' ./e6c-mount-mechanism.sh)"

printf '\n%d checks, %d failures\n' "$run" "$fails"
[ "$fails" -eq 0 ]

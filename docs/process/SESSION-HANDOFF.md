# XCodeVault — continuing the work

Starting point for a new session. Project at `~/projects/XCodeVault`, public at
`github.com/pabloguia/XCodeVault` since 2026-09-18.

> **State verified 2026-09-27 17:44.** Point-in-time — re-verify before acting, including what is
> written here. When you finish an item, update this page along with `STATUS.md`.
>
> **A number measured inside a transient window is not state** (2026-09-16, twice in one day).
> Measure twice, separated in time, before writing one here — and name who measured it: the
> operator's terminal has Full Disk Access and the agent's process does not (H15), so the same
> command can answer differently from the two.

## Read before acting, in this order

1. `CLAUDE.md` — the non-negotiable safety rules (especially 3, 5, 6, 7).
2. `STATUS.md` — the live sections at the top ("In flight", "Blocked / pending — manual", "Next
   three actions"). Item 1 of "Next three actions" holds the E6c/H14/H15 series in order.
3. `docs/architecture/HYPOTHESES.md` — **H15**, then **H14 from its title to the end of the file**:
   every E6c run's pre-registered reading sits immediately before its RESULT.
4. `docs/architecture/COMPATIBILITY_MATRIX.md` — the last four E6c entries.

## Where the project has got to (2026-09-27)

What the product does today: accounting (`scan`/`doctor`), cleanup of regenerable data, and the
Runtime Library flow (export → `runtime offload` → `runtime import`). Milestones M1–M3 committed; M4
has a first GUI slice; M5 (signing, notarization) is not started. **The privileged helper has never
run live** — issue #30, blocked on a signed build.

**In flight (2026-09-27): user-first permissions**, four deliverables in
`docs/superpowers/plans/2026-09-27-user-first-permissions.md`; `STATUS.md` "In flight" says how many
are done.

The week's series, in one paragraph each — details and evidence in H14/H15:

- **H15 — the "root is refused inside CoreSimulator" signature was the caller's TCC posture.** With
  Full Disk Access, `mkdir`, `rm` and `mount_apfs` all work there. Every harness run now records a
  measured `TCC indicator` line; nothing may be contrasted across TCC contexts.
- **E6c — what refuses mounting at the CoreSimulator cache paths: nothing, with the grant.** Runs 6–8:
  `mount_apfs` and DiskArbitration both mount at `Cryptex/Caches` and at `Caches/dyld`, for disk
  images (runs 6–7) and for a physical USB SSD volume (run 8, all twelve cells). DiskArbitration's
  refusal of the disk-image donor at caller-chosen mount points followed **who attached the image**
  (item 4: user session refused, root accepted). None of it reopens ADR-0004.
- **H14 / issue #29 — the "stub" is the mount point itself.** After a clean unmount the pre-existing
  directory is there, `root:admin 0755`, empty (run 7). What remains: the physical yank (pending a
  pendrive), and what writes into `Caches/dyld` afterwards — twenty hours of the rig's headless use
  requested nothing at info level; H11's one recorded rebuild followed an OS update.

## Machine state (measured 2026-09-27 17:44, by the agent, read-only)

- macOS **26.7 (25G229)**, Xcode **26.5**. Intel, `x86_64`.
- **Internal free: 9.3 GiB** — down from 44 GiB on 2026-09-25 after `Caches/dyld` was cleared.
  Not investigated; `~/projects` 27G, CoreSimulator `Devices` 10G (8.2G on 2026-09-16),
  `DerivedData` 5.1G, runtime images 15G. The operator's to look into.
- Runtimes: iOS 26.5 (23F77) and watchOS 26.5 (23T570), both Ready.
- `/Library/Developer/CoreSimulator/Caches/dyld`: **empty** (0 entries, mtime 2026-09-25 19:19) —
  cleared by the operator for E6c; not rebuilt since.
- Attached: `/tmp/e6b-donor.sparseimage` (label `E6BDONOR`, 1 GB, disposable, from E6c run 7 —
  detach whenever), and the operator's USB SSD with their data volume. **Never use that SSD for a
  physical yank** (it disconnects their data with the donor).
- `~/projects/XCodeVault-pre-rewrite-2026-09-17.bundle` exists outside the tree: the only copy of the
  history before the 2026-09-17 redaction rewrite. It is unredacted — never move it inside the tree,
  never push it; restore with `git fetch <bundle> master:pre-rewrite` (the bundle's branch is `master`).
- The operator runs test rigs on the shared simulators: check `pgrep -lx 'xcodebuild|launchd_sim'`
  before anything that boots or mounts. `test-common.sh`'s "an ordinary directory passes the target
  guard" fails whenever a device is booted — that is the guard working, not a regression.

## What to do, in priority order

1. **E6b variant B — the physical yank, with a disposable USB pendrive.** Guards are in place
   (`--donor-uuid`; the donor must be the only volume on its drive). Before running: erase the
   pendrive as APFS with one volume, pre-register the reading, review. See STATUS "Blocked /
   pending".
2. **What rebuilds `Caches/dyld`.** Candidate trigger, untested: the first boot on a new host build
   (H14's last subsection). Interactive Xcode/Simulator.app use is unmeasured. The info-level
   listener pattern works (0 dropped); the debug-level one drops everything.
3. Issue #30 and M4/M5 — need a signed build.

**Harness facts that cost time to learn:** every E6c/E6b run needs `--donor-uuid`; run test suites
in the foreground or through the `perl` SIGINT reset (an `&` job ignores SIGINT); `scripts/preflight.sh`
before every push, run while the rig is idle.

## History — priorities as of 2026-09-16

The sections below are kept as they were written; they are a record, not instructions.

### What to do, in priority order (2026-09-16)

### 1. ~~The ~5.4 GB of regenerable data inside the devices~~ — DONE 2026-09-13, with the result inverted

Catalogued and reported; **not cleanable, and for a better reason than expected.** The three
categories (`simulatorDeadContainers`, `simulatorMobileAssets`, `simulatorLogStore`) are
report-only: `scan` measures per device, `doctor` prints the breakdown and the reason, `clean`
offers nothing.

`Dead` **is swept sometimes, and nobody knows why** — two earlier versions of this paragraph
claimed to know and both were knocked down by re-measuring. One mass sweep was observed (15 entries
/ 1.5 GB → 3 / 306 MB, against a shut-down device that did not change a byte), but the same device,
booted for three more hours, went back to 2.0 GB without sweeping anything. None of the three
categories offers remediation. The solid number is the **growth**: ~2 GB/hour in an
`xcodebuild test` loop. See F22.

~~Open: reproduce `log erase --all` via `simctl spawn`~~ — **closed 2026-09-15, negative.** All
three documented forms are refused by `logd` inside the device (`Operation not permitted`), while
`log stats` on the same device works. The three per-device categories remain report-only, and now
none of them for lack of trying. See E18.

### 2. E14b and E14c — CLOSED on 2026-09-15. Nothing here to run

**H12 falsified for external storage:** `create` fails on the vault and works on an alternative
internal set, with identical commands. Phase 3 unreachable, E15 with no effect on any v1 decision.

**E14c narrowed H6, run twice:** a case-sensitive APFS image whose file lives on the vault hosts
the very device the vault refuses. Case sensitivity, `Device Location=External`, mount options, the
*class* of path (both under `/Volumes`; the paths themselves differ) and the physical SSD all held
equal. `Removable Media` varied, but see the caveat below
(the volume called `Removable` is the one that works). That leaves `Protocol`: real device against
virtual. Evidence: `evidence/e14c-image-on-vault-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

**Second independent confirmation, 2026-09-16, by a different mechanism and on a different OS.** E2
re-run on macOS 26.7 gives the same result by a different route — loading a `.xctest` bundle
instead of `simctl create` — and two of its nine cases carry the argument:

- **Case E fails:** an *internal* path that is a symlink to the vault fails exactly like the vault.
  The restriction follows the **device**, not the text of the path. Rewriting the path does not
  escape it.
- **Case F passes:** a disk image whose **backing file is on the USB SSD** works. The bytes cross
  the same physical device, over the same I/O path, and the test runs. That **clears the hardware
  and the bus** and leaves the volume's DiskArbitration classification.

So H6 today has two mechanisms agreeing across two macOS versions. It stays **probable** — one
machine, one physical device — but it is no longer a single observation.

**What is still missing to get past *probable* needs hardware:** a **non-USB** external (a
Thunderbolt/NVMe enclosure). Every external tested so far is USB, so "removable" and "USB" are
still the same variable. That is E14d, and the project does not have the enclosure.

#### History (the path to here)

`create` fails on the vault and works on an **internal** alternative set (exit 0, a 17 MB `data`
container), with identical commands. The alternative-set mechanism works; the volume is the
variable. **H12 falsified for external storage**, phase 3 unreachable, E15 no longer triggers a v1
decision. Evidence: `evidence/e14b-control-internal-create-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

H6 gained a **second independent reproduction, with a named mechanism**: `tccd` queried 3× for
`kTCCServiceSystemPolicyRemovableVolumes` about the CoreSimulatorService, a kernel
`deny(1) file-write-create`, then EPERM — with no `xctest` anywhere. It stays **probable**: one
machine, one physical device.

*(Everything below is a record of the path to the result above. **There is nothing here to run** —
the `e14b-control-internal-create.sh` control has already run and is closed.)*

E14b's phase 2 failed on the vault: `create` exits 22. **The run's evidence file contains only
that** — the harness captured the log only on a phase 3/4 failure. The mechanism was read by hand
from `CoreSimulator.log` and is in
`evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`, with declared
provenance: the CoreSimulatorService fails to copy the initial content into `<set>/<UDID>/data`
with `NSPOSIXErrorDomain Code=1` (EPERM, not EACCES) and destroys the half-created device. That
rules out the directory's permission bits — the script wrote there in the previous step, as the
same user — and nothing beyond that. The unified-log capture is **not** empty, and unlike E2 it
**names the mechanism**: three `tccd` queries for
`service=kTCCServiceSystemPolicyRemovableVolumes` attributed to the CoreSimulatorService, and a
kernel `deny(1) file-write-create` over the set's path, milliseconds before the failure
(`evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`). What that
authorizes concluding about H6 has **not** been decided — it is one observation, one volume, one
machine, the control not yet run. **Phase 3, the boot gate, was never reached.**

#### History of the first attempt (void)

`scripts/experiments/e14b-device-set-external.sh` ran and aborted in phase 1, on a wrong gate of
its own: it required `device_set.plist` after a bare `list`, and that file is only born on the
first `create`. A control on the internal disk gave an equally empty directory, exit 0, identical
output — the gate separated an empty set from a full one, not external from internal. **Phases 2
and 3 never ran.** Phase 1 today is a declared smoke test, which gates nothing: measured,
`simctl --set … list` exits 1 only when the path does not exist and 0 for any existing directory,
and the script creates the directory on the previous line. Do not quote exit 0 from there as
acceptance of external storage.

Two safety reviews of that fix found serious, long-standing defects in the script, since corrected:
`mkdir -p` **adopted** an existing directory for the `rm -rf`; the path refusal was textual, and
`/Volumes/<vault>/../../Users/<you>/Library/Developer/CoreSimulator` passed; `cleanup` deleted the
set trusting a return code instead of asking how many devices were left; and there was no `trap`.
**Do not run an old copy of this script.**

~15 min, no sudo, writes only on the vault, never addresses the default device set. Requires
`--i-understand`. Its guards have **no CI coverage** — `ci.yml` runs only `e1` and `e8`; they were
exercised by hand on 2026-09-15 and are recorded in `COMPATIBILITY_MATRIX.md`.

If the test device does not reach `Booted` from USB, H12 dies — and H6 suggests it does die,
because in a test with a simulator destination the `.xctest` bundle is installed **inside the
device's data container**, which is E2's configuration one layer in.

Context: F1 said there is no evidence of Xcode honoring a custom device set. **That has been partly
knocked down** — `DVTSimulatorSetLocation` exists in Xcode 26.5's `IDEiOSSupportCore`. But Xcode
does not pass the path on to Simulator.app, which reads its own `DeviceSetPath`: a silent split
brain, rule 6, disqualifying on its own.

### 3. ~~E13 — the reboot probe for the orphaned dyld cache~~ — DONE 2026-09-16, negative

**The orphan survived the restart.** A capture before the reboot and another 5h46m later: the cache
tree came back byte-for-byte identical — same sizes, same mtimes, same `newest file write` inside
the orphan. The `diff` gives exactly two hunks, both in the header (timestamp/boottime and
`internal free: 17Gi → 16Gi`, which is six hours of normal use, not the tree — it stayed at 9.4G).

There were **two** restarts, not one: the orphan was born on Sep 7 and the *before* capture's
`kern.boottime` already read Sep 15. The premise the experiment was written on ("created after the
last boot, never went through a restart") was true on Sep 9 and had expired by itself before the
probe ran — nobody edited anything, only time passed.

Product consequence, already applied: **`doctor` no longer tells you to restart** for that finding,
because it was measured not to help. And H11 moved from *open* to **falsified as a general rule** —
the startup GC is path-specific: it collects the Inbox and does not collect `inc/`, with both
lacking a BSD flag and absent from `rootless.conf`.

Evidence: `evidence/e13-dyld-reboot-20260916T100005.txt` (before) and `…T155821.txt` (after).

### 3b. E13b ran in inspection mode and lost its target — and then came the real finding

**The macOS update took the whole tree.** Between the E13 capture (15:58, on 25G83) and the E13b
run (19:53, already on 25G229) the machine updated and rebooted at 19:14. At 19:53 `Caches/dyld/`
held only `25G229/inc`, empty: the 9.4 GB from the previous build, orphan included, no longer
existed. Those caches are indexed by the host build, so an OS update supersedes the entire
directory.

**But only the orphan's share is durable space, and that is what matters.** Eight minutes later the
two installed runtimes had already rebuilt on the new build, at the same sizes (4.4G iOS, 2.7G
watchOS); `inc/` stayed at 0B. Net gain ≈ **2.3 GB**, free 16 → 19 GiB. The `0B` / `29 GiB`
visible in the window between the update and the rebuild was transient and **cannot be quoted as
recovery**. A first version of this section quoted it, and was wrong for an hour.

As a bonus, it is the cleanest confirmation the category has ever had: the cache of an **installed**
runtime comes back on its own (it buys a slow boot, not disk); the cache of an **absent** runtime
does not. Both halves measured in the same before/after, by accident.

Not established: **who** deleted it — the installer or the CoreSimulatorService on first use after
the update. The mtime of `dyld/` is 19:53, the time the run itself woke `simctl`, which is
consistent with both readings. A unified-log query over that window returned nothing.

**Three of E13b's guards failed open on that run, and it stopped by accident** — all corrected, see
the commit. The content allowlist approved an empty reading and printed "every entry is a known
cache artifact" over a reading of nothing; the `lsof` veto fired on `lsof`'s own error banner,
captured by a `2>&1`; and `home_of` returned two paths for root
(`/var/root /private/var/root`), leaving witness 2 with an invalid `HOME` — and it *made no
difference*, which is worse, because the split-view check ran broken and reported agreement. On top
of that the build mismatch was computed, printed and ignored.

**Where E13b is still worth something:** on a machine where an orphan persists. Here there is no
target left.

The script is at `scripts/experiments/e13b-dyld-orphan-root-delete.sh`, written on 2026-09-16:

```
# inspection, deletes nothing:
sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand
# and then, if the report makes sense:
sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand --delete
```

It measures **errno** instead of using `rm -f` (which suppresses exactly the answer being sought:
EPERM=1 is a policy refusal, EACCES=13 is an ordinary permission), deletes from the **smallest file
to the largest** — the first usually has zero bytes, so a refusal arrives without destroying
anything — and stops at the first refusal. Before touching anything it requires **five witnesses**
to agree that the runtime is gone, including the `.simruntime` bundles inside each Xcode, which
`simctl` cannot see. The shape of the path does not establish that it is an orphan: the **live**
iOS cache passes every path guard and is only stopped there.

A refusal is the more interesting result: it would be the second path where root is blocked with no
SIP flag and no `rootless.conf` entry — OS behavior to report to Apple, not a cleanup detail.

## Constraints (always in force)

- **Never ask for or accept the user's password. Never run `sudo`.** If something requires root,
  that is a finding: write the script, hand over the command, the user runs it. Never touch
  `/System`.
- Every change that copies/moves/deletes/mounts data goes to `migration-safety-reviewer` before the
  commit. Changes to the privileged helper go to `helper-security-reviewer`.
- Commit only with `swift build && swift test` green — check the real exit code, not a grep.
  No push.
- Mutation-test what you write, and count crashes as well as assertion failures.
- The repository owner is Brazilian and prefers conversation in Portuguese; **everything written
  into the repository — code, comments, commits, documentation — is in English.** If you are not
  working with him directly, the second half is the part that binds.

## Four lessons that recurred and are documented in STATUS

1. **An inherited claim is not a fact.** Five rounds of review in this session; in three of them the
   problem was an earlier fix that had moved rather than gone away. And several
   `[COMMUNITY-REPRO]` entries in our docs did not survive examination.
2. **A seam does not test what it replaces.** A guard shipped that *could not fire*
   (`statfs` never returns `/` for a path under `/Volumes`, which is a firmlink) and the tests
   agreed with it, because they hand-built a value the system does not produce. Every injected
   default needs a test that passes no seam at all.
3. **A rehearsal in a different context is not a rehearsal.** A `--dry-run` as the user passed and
   the real run as root refused, because commands were reading the wrong home. And confirming a
   verb's contract by invoking it is not diagnosis — `simctl runtime unmount` is not read-only. On
   Sep 16 this recurred twice in a single script: `sudo -u` without `-H` made both witnesses read
   the same store, and a bash function was tested in interactive zsh, where it failed for a reason
   that does not exist in bash.
4. **A measurement inside a transient window is not state** *(new, Sep 16, recurred the same day)*.
   E13's header claimed "created after the last boot, never went through a restart" — two dates,
   true when written, expired by themselves with nobody editing anything. Hours later I measured
   the dyld cache at `0B` in the window between the macOS update and the rebuild, and wrote
   "9.4 GB recovered / 29 GiB free" into four files. Eight minutes later it was 7.1 GB and 19 GiB,
   and the real gain was 2.3 GB. **Before writing a number that claims permanence, measure twice
   separated in time, or write the window down alongside the number.**

## Where to start (2026-09-16 — historical; the current order is at the top)

### Re-baseline on macOS 26.7 — done 2026-09-16, five entries

Every `COMPATIBILITY_MATRIX` entry said **26.6.2 (25G83)**, and the machine went to 26.7 (25G229)
mid-session with nothing noticing. A file whose job is to record *which combinations this was
verified on* had a single combination, and it had stopped being the one in use.

Re-ran the five that need no device, no root and no event — **E1, E8, E14a, E2, E12**. No simulator
touched, no `sudo`. **All of them survive the bump:**

| | result on 26.7 |
|---|---|
| E1 | identical findings — no BSD flags, absent from `rootless.conf`, no nested mounts |
| E8 | **zero** substantive differences |
| E14a | 22/25 finding sections identical |
| E2 | **9/9 identical verdicts** — see H6 above |
| E12 | 19/20 sections identical; case-sensitive APFS is still fine on both surfaces |

**Careful when repeating this:** a raw `diff` reported 64 differences in E1 and 39 in E14a, and it
*looks* like the findings changed. They did not — it was machine inventory (the runtime `.dmg`s
were back in `Images/`, the device set had shrunk). Compare the sections that carry findings, with
sizes and timestamps normalized away, and not the whole file.

**Gap recorded and not fixed:** `e2-external-xctest.sh` has no `trap` — dying halfway leaves sparse
images mounted. It is not destructive. I left it alone on purpose: it was being re-run *as is* to
re-verify a recorded result, and editing the instrument during the re-verification is how a
comparison stops being one.

**Matrix state: 5 of ~21 entries re-verified on 26.7.** The rest mutate a device, need root, or need
an event — and should be read as 26.6.2-only until someone runs them. That is less than "the matrix
is up to date", and it is what was measured.

### The rest

Items 1–3 above are **closed**, and all three closed negatively. What is left in the storage
research is blocked on hardware (E14d: a **non-USB** external, to separate removability from bus)
or on an event (F10's third probe: whether a superseded *runtime build* leaves a cache behind — no
machine here has exhibited one).

### e8c was rewritten on Sep 16, and I was wrong to call it an "open decision"

Both decisions had already been taken and written down; it was the script that was never updated.
`EXPERIMENTS.md:363` already said **"never `bootstatus -b`"**, and `STATUS.md:125`, from Sep 13,
records that you did not reuse e8c because it "unconditionally deletes the runtime + runs `simctl
delete unavailable` at the end — both wrong here" and ran the steps by hand. It sat there as a trap.

`simctl delete unavailable` was the serious problem, not `bootstatus`: it sweeps **every**
unavailable device from the default set, and runtime offload is exactly what leaves your iPhones
unavailable — they come back on their own at reimport, unless something deletes them first.
`doctor` is tested to refuse to recommend that command in that exact state, and the product has
removed that pattern three times already. The experiment was still doing it.

Now it is platform-general (the device type comes from simctl's `supportedDeviceTypes`, not from a
hardcoded `"Apple TV"`), polls for `Booted`, deletes only the device it created, by UDID, and
**refuses** if the installer's runtime is already installed — because then "restore the previous
state" would be taking something of yours away. Exercised against the vault's two real installers:
**exit 3, nothing touched**, because iOS 26.5 and watchOS 26.5 are both installed. To actually run
it you need an installer for a runtime you do **not** have.

The safety review found my rewrite worse than the original in three places, all in paths I had not
executed — including a lowercase `$rid` that kept the probe from running, and `runtime delete`
receiving the wrong identifier (it wants the **image's UUID**, which the original script got
right). Corrected. And this session's lint caught an unescaped backtick that I wrote myself while
fixing them.

With that, the next real work is product, not research — see the milestones in `STATUS.md`.

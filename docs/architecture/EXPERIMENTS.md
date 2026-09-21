# Gating Experiments

These run **before** production implementation. Each answers a question that can
change the product's architecture; several can kill a strategy outright. Record every
result in `COMPATIBILITY_MATRIX.md` and update the corresponding hypothesis status in
`HYPOTHESES.md`. Capture raw command output as evidence artifacts in the repo
(`docs/research/evidence/<experiment>-<macos>-<xcode>-<arch>.txt`).

**Rules for all experiments:** run on a machine whose developer data is expendable or
fully backed up; never delete a source until the experiment has concluded; capture
`sw_vers -productVersion`, `sw_vers -buildVersion`, `uname -m`, `xcodebuild -version`,
and `xcode-select -p` at the top of every evidence file.

---

## E1 — Is the target path even mountable? (gates H1, H8) — RUN FIRST

Cheap, read-only, minutes.

```
ls -lO@ /Library/Developer /Library/Developer/CoreSimulator
xattr -l /Library/Developer/CoreSimulator
grep -i developer /System/Library/Sandbox/rootless.conf
mount | grep -i developer
ls -la /Library/Developer/CoreSimulator/Volumes 2>/dev/null
```

Looking for: a `restricted`/`sunlnk` flag or `com.apple.rootless` xattr on the target;
nested mounts already present. Then attempt an actual mount of a scratch external APFS
volume over a **throwaway** path first, and only then over the real one on a test
machine.

**If the path is rootless-protected → H1 is dead.** Record it, write the ADR, and
reallocate to H4 + cleanup + disconnect safety.

## E2 — Does the external-volume sandbox restriction follow the device or the path? (gates H6) — HIGHEST VALUE

Reproduce the January 2026 report (`xctest` cannot load a test bundle from
`/Volumes/...`, F4), then repeat with the *same external volume* mounted at a
canonical, non-`/Volumes` path.

1. Point Xcode ▸ Settings ▸ Locations ▸ Derived Data at `/Volumes/<ext>/DD`. Build and
   run a framework-target unit test on the "My Mac" destination. Expect failure.
2. Unmount, remount the same volume at e.g. `/Users/<me>/DDMount` (or another canonical
   non-`/Volumes` path), repoint DerivedData there, repeat.
3. Also test with a **disk image** (non-removable) vs. a real USB/TB device, to separate
   "removable device" from "external volume" from "path under /Volumes".

**Outcome decides the product's shape:** device-based → canonical mount buys nothing
here and the honest answer is a documented limitation; path-based → canonical mount has
a demonstrable, unique advantage over every existing tool.

## E3 — When does CoreSimulator actually start? (mount-race window)

```
log stream --predicate 'process == "simdiskimaged" OR process == "com.apple.CoreSimulator.CoreSimulatorService"' --info
```
Observe across: boot, login, first Finder activity, first `xcodebuild -version`, first
Xcode launch. Confirms or refutes "on-demand, at first Xcode use" (F5) — which
determines how much time a mount daemon actually has to win the race.

## E4 — Does a byte-identical runtime survive relocation? (gates H1, H9)

Copy an installed runtime bundle (`Cryptex/Images/bundle/SimRuntimeBundle-<UUID>`) to
an external APFS volume preserving everything (`ditto`, or `rsync -aXAE --fileflags`),
then make it visible at the canonical location by mount (not symlink) and try:
`xcrun simctl runtime list`, create a device, boot it, install and launch a test app,
shut down, delete. Watch for `SimDiskImageErrorDomain Code 5` / `-67061`.

Also test the officially supported alternative first, as a control:
`xcodebuild -downloadPlatform iOS -exportPath /Volumes/<ext>/RuntimeLibrary` then
`xcodebuild -importPlatform <dmg>` (E8).

## E5 — Ownership, xattrs, ACLs across the boundary

Mount the external volume with and without `owners`; verify that mixed root/user
ownership, ACLs, and xattrs (`com.apple.provenance`, quarantine, code-signing related)
survive a `ditto`/`rsync -aXAE` round trip. Confirm whether `mount_apfs -u/-g` or
`diskutil enableOwnership` is needed. Prior art dropping these (`rsync -a` only) is a
known correctness defect, not a cosmetic one (F9).

## E6 — Surprise removal (gates H3)

With the volume mounted at the canonical path and a simulator booted: physically yank
the drive. Then record:
- Does the canonical path revert to an empty local directory?
- Do subsequent Xcode/simctl operations write **locally** into it?
- What state is `simdiskimaged` left in (nested mounts gone, database stale)?
- Can the volume be remounted at that path afterwards without manual cleanup — and if
  the mount point is now non-empty, does the mount fail or silently hide the data?
- Repeat with a *clean* eject to compare.

## E7 — Does the shadow-data defense work or make things worse? (gates H3)

Set the unmounted mount point to root-owned, mode `0500`, `chflags uchg`. Run the same
Xcode/simulator operations. Determine whether writes fail loudly (good) or Xcode/
`simdiskimaged` crashes or corrupts state (worse than the disease). Also validate
`getattrlist` `ATTR_DIR_MOUNTSTATUS` as the mount check and a volume-root sentinel file
as the "is this really our volume" check.

## E8 — Official mechanisms: what actually works on each Xcode (gates H4)

Feature-detect rather than assume. For each installed Xcode:
```
xcodebuild -downloadPlatform iOS -exportPath <dir>
xcodebuild -downloadPlatform iOS -buildVersion <v> -architectureVariant arm64 -exportPath <dir>
xcodebuild -importPlatform <dmg>
xcodebuild -runFirstLaunch -checkForNewerComponents
xcodebuild -showComponent metalToolchain      # Xcode 26
defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation
defaults read com.apple.dt.Xcode IDEBuildLocationStyle
```
Record which flags exist, which error out (`-buildVersion` is reported rejected on some
builds), the actual size difference `-architectureVariant arm64` buys, and whether the
2016-era DerivedData defaults keys are still honoured on Xcode 16/26.

## E9 — Reproduce the symlink-breaks-Simulator report (gates H5)

Symlink `~/Library/Developer/CoreSimulator` to another directory **on the same internal
disk**, then exercise the Simulator's Files app (share a file, save, create a folder)
plus a normal build/run/test cycle. Confirm or refute Lapcat's August 2025 report (F3)
on current Xcode. Also verify the FB12363725 child-symlink allowlist from H2, and
confirm `~/Library/Developer/DeveloperDiskImages` must remain a real directory.

## E10 — Drive qualification benchmark (product differentiator)

Measure **4K random IOPS at QD1–4** and metadata-operation latency — not sequential
MB/s — for internal vs Thunderbolt vs USB 3.x, then correlate with an actual
`xcodebuild` clean-build wall clock and simulator boot time. No such published
benchmark exists (F9); producing one is cheap, useful to users, and is the honest basis
for the app's "expected performance impact" per storage category.

## E11 — Runtime install staging space

Verify the reported ~40 GB free-space requirement to install a 9–12 GB runtime, and
where staging happens (`Cryptex/Images/Inbox/`). If staging is always on the internal
volume, relocation alone does not solve the user's most acute failure — the product
must say so and, if possible, help (free space first, or stage elsewhere if supported).

---

## Reporting

Every experiment produces: a matrix entry, a hypothesis status change (or an explicit
"still unverified, here's why"), an evidence file, and — where it changes a design
decision — an ADR.

## E12 — does developer data survive on case-sensitive APFS? (qualification warning)

macOS ships case-**in**sensitive APFS; a user's external drive may be case-sensitive, and
`VolumeQualification` warned about it from first principles without ever testing it. The warning
gates a real decision, so it needs evidence rather than caution.

Script: `scripts/experiments/e12-case-sensitivity.sh` — runs entirely on a disposable `hdiutil`
sparse image, no sudo, never touches the user's drive. Two surfaces, chosen to match the product's
own layout (source stays internal, XCodeVault relocates the rest):
- **A.** `swift build --scratch-path <case-sensitive volume>` — this also clones dependency
  *source* into `checkouts/`, which is the riskier half: a package with case-inconsistent internal
  references breaks when its source is case-sensitive, not when its output is.
- **B.** `xcodebuild -derivedDataPath <case-sensitive volume>` with source on the internal volume.

Include a control that proves the two volumes actually differ (`probe.txt` + `PROBE.txt` coexist on
one and collapse to a single file on the other) — otherwise a passing build proves nothing about
case sensitivity.

## E13 — is the orphaned dyld cache reaped at startup? (gates F10, and the advice `doctor` gives)

F10 found 2.3 GiB under `Caches/dyld/<hostBuild>/inc/<runtimeIdentifier>` belonging to a runtime
that is no longer installed. The open question is not whether it is garbage — nothing can rebuild a
cache for an absent runtime — but **whether the system already collects it**, because that decides
what `doctor` should tell the user to do.

The reason this is the first probe and not the second: the closest analogue in this repo is the
stranded runtime Inbox `.dmg` (FINDINGS, 2026-09-06 note), where root deletion was refused three
times with `Operation not permitted` and a **reboot** reclaimed the file — the reaper is a startup
GC. When this was written the orphan had never been through a restart, which is what made the probe
decisive.

**Run 2026-09-16 — RESULT: it survived, and the second branch below is the one taken.** Captured
before a reboot and again 5h46m after it; the `== cache tree ==` section of the two files is
byte-identical — same sizes, same mtimes, same birth times, and the same `newest file write` epoch
inside the orphan. `diff` produces exactly two hunks, both in the header: the timestamp/boottime and
`internal free: 17Gi → 16Gi` (ordinary use over six hours; the tree itself stayed at 9.4G). tvOS is
still absent from `simctl runtime list` in both, so it is still a genuine orphan.

Two restarts, not one. The controlled pair above is the second: the orphan was born Sep 7 18:37 and
`kern.boottime` in the *before* capture already read Sep 15 09:01, so it had outlived a restart
before this experiment began. The premise quoted above had gone stale between being written
(2026-09-09) and being tested — worth noting as a class of error, since nothing about it looked
stale.

**What this settles and what it does not.** `Caches/dyld/<build>/inc/` is not covered by the startup
reaper that collects the Inbox, so the reaper is path-specific rather than a general mechanism (H11).
The "resumable build" branch is also ruled out for this boot: the newest write did not move, so
nothing resumed the build at startup — though installing tvOS 26.5 again might, and that is untested.
Root deletability is untouched by this result; E13b is now unblocked, not answered.

**No privilege, no deletion, nothing mounted.** Script:
`scripts/experiments/e13-dyld-cache-reboot.sh` — run it, restart, run it again, diff the two
captures. It records per-entry size, mtime, **birth time**, and the newest file write anywhere
inside each entry. The last of those matters: a directory's own mtime freezes once its entries are
created while the build keeps writing into them, so it cannot distinguish "abandoned" from "in
progress" on its own. Measured here, that gap is not small — the tvOS orphan was born 18:37:58 with
a final write at 18:54:48, and the iOS cache rebuild spanned 06:47:15 → 07:06:28.

Three outcomes, each of which settles a different question:

- **Gone after the restart** → the reaper exists and covers `inc/`. F10 shrinks to "transient until
  restart", and `doctor`'s remediation should be *only* "restart", with no `sudo` at all. The rule
  keeps its value (it explains 2.3 GiB the user can see) but stops implying manual work.
- **Still there** → the Inbox reaper does not cover this path. Only then does the root-deletion probe
  (E13b) become worth running, and only then may `doctor` mention a command. **← this is what happened,
  2026-09-16.**
- **Still there but shrunk / partially rebuilt** → CoreSimulator is treating it as a resumable build.
  That would falsify the "interrupted, abandoned" reading in F10 and argue for widening the `inc/`
  age guard well beyond its current one hour.

**E13b — unblocked 2026-09-16, written, not yet run.** Script:
`scripts/experiments/e13b-dyld-orphan-root-delete.sh`. It needs root, so it is handed over as a
command rather than run here.

    # inspect only, deletes nothing:
    sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand
    # then, if the report looks right:
    sudo scripts/experiments/e13b-dyld-orphan-root-delete.sh <orphan-dir> --i-understand --delete

Four design choices are the experiment rather than decoration:

- **errno, not `rm`.** The remediation `doctor` prints uses `rm -f`, and `-f` suppresses exactly what
  is being measured. Each unlink goes through `os.unlink` and reports the raw errno, because
  EPERM (1) vs EACCES (13) is the discriminator — a policy refusal against ordinary permissions.
- **Smallest file first.** The first thing unlinked is normally the zero-byte
  `update_dyld_sim_shared_cache-stdout.txt`. If policy refuses, the answer arrives having destroyed
  nothing; only if that succeeds does anything of size get touched. The run stops at the first
  refusal — nothing further needs destroying to learn the same fact twice.
- **Five witnesses before anything is touched**, any one of which vetoes: `simctl runtime list` as
  the invoking user *and* as root (a disagreement is itself a veto), an available device on that
  runtime, `images.plist`, and — the one `simctl` cannot provide — the `.simruntime` bundles inside
  every Xcode on the machine. A runtime bundled in an older Xcode is invisible to `simctl`, so its
  cache looks orphaned while being live. Path shape does not establish liveness: the *installed*
  iOS cache passes every argument check and is stopped only here.
- **Inspect-only is the default**, and the rehearsal runs as root. A `--dry-run` as the user would be
  the wrong-context rehearsal this repo has already shipped once (handoff, lesson 3).

It also refuses a symlink argument, refuses any directory holding a file it does not recognise
(surprises are reported, not deleted), vetoes on an open file handle, re-checks the target's
dev:inode immediately before the first unlink because minutes of `du` and `lsof` pass since
validation, copies `update_dyld_sim_shared_cache-stderr.txt` aside with `cp -p` before deleting
because `doctor`'s own glob destroys that diagnostic, verifies by re-stat instead of by exit code,
and never elevates itself — run as a non-root user it prints the command and stops.

**What has actually been run, and what has not.** Only the argument chain — everything above the root
check — has been exercised, as a non-root user: missing arguments, a missing `--i-understand`, an
unknown flag, a nonexistent path, a symlink argument, a path outside the cache root, the cache root
itself, a build directory, `inc` itself, and two valid orphan paths that stop at the root check.
**Everything from the root check onward has never executed**: the witness chain, the contents
allowlist, the unlink loop, the accounting. Inspect mode exists so that the first root run exercises
the witnesses without deleting anything, and its first output is data about this script as much as
about the OS.

**There is no rollback**, and a refusal partway through the loop leaves a partially deleted
directory. "The answer arrives having destroyed nothing" holds only for a refusal on the *first*
file, which is why the order is smallest-first and why phase 3 prints a manifest of what it did
unlink before stopping.

Witness 4 deserves its own caveat, because a first version of it was worse than useless. It searched
one directory level too shallow for the historical bundle path, and on finding nothing printed "no
Xcode here bundles <rid>" — an affirmative pass in the language of a result, which is the same
instrument failure this file records elsewhere. Measured afterwards: this machine has **zero**
`.simruntime` bundles anywhere under the selected Xcode, because Xcode 26.x ships runtimes as disk
images. So on this machine witness 4 is inconclusive by construction and now says so rather than
voting; four witnesses vote, not five. It vetoes only when it could not search at all.

**A refusal is the more interesting result**, and the script says so rather than treating it as a
failed run: it would mean a second path where root is blocked without a SIP flag or a `rootless.conf`
entry, which is worth reporting to Apple and worth a rule of its own. Record `chflags`/`lsof` either
way — neither explained the Inbox.

**Do not run E13b first.** The whole point of the ordering is that a free, unprivileged probe can
make the privileged one unnecessary — and that reasoning from "no SIP flags + absent from
rootless.conf" to "root can delete it" has already been wrong once in this repo, on a path with
exactly those properties.

## E4b — the half of E4 that needs root: CoreSimulator using an externally-backed runtime

E4a (2026-09-09) settled the seal question without privilege: a byte-identical copy of an installed
runtime image, living on an external USB APFS volume, attaches `sealed` as a normal user, with a
negative control proving the check is enforced. Evidence:
`docs/research/evidence/e4a-seal-survives-external-relocation-*.txt`.

What it could not touch is the half that decides whether relocation is a product feature: making the
copy visible at `/Library/Developer/CoreSimulator/...` **by mount, not symlink**, and seeing whether
CoreSimulator accepts and uses it there. That path is root-owned, and this project does not take
privilege it does not need — so the commands belong to the operator, not to the tool.

Two reasons to keep expectations low before spending the effort:

- **H6.** The sandbox/TCC restriction that breaks `xctest` bundle loading classifies by **device
  removability, not by path** (E2): it reproduced on a real USB SSD both under `/Volumes/…` and
  through an internal-path symlink, and did not reproduce on disk images. A canonical mount does not
  disguise a removable device, so the restriction is expected to follow the runtime.
- **ADR-0004** already demoted canonical mount to R&D on exactly that reasoning. E4b is a
  falsification attempt, not a step toward shipping it.

**Amended 2026-09-09, before running: the mount route is replaced by an images.plist repoint.**
Mounting over `/Library/Developer/CoreSimulator/Volumes/<name>` fights `simdiskimaged` for the same
mount point, and `Signature State` is served from `images.plist` rather than from whatever is
mounted — so the mount route answers the wrong question. The script repoints the database
CoreSimulator actually consults.

**The trap that shaped the script, worth reading before designing any successor.** Both runtime
volumes are already attached at the kernel level, and killing `simdiskimaged` does not detach them;
`signatureState` and `state` are *stored in* `images.plist`, which the edit preserves. So a naive
version reports `Ready / Verified` while the daemon never opens the external file — reading back a
cached value the script itself wrote, over a stale mount. A false positive here would argue for
reopening a safety-motivated ADR, which is the worst outcome available. The script therefore
unmounts the runtime first, asserts the mount point is clear, and records `hdiutil info` before and
after: **the `image-path` line is the verdict, not the Ready/Verified text.**

Script: `scripts/experiments/e4b-runtime-from-external-volume.sh`, with `--dry-run` that needs no
privilege. It refuses unless the vault verifies by UUID + sentinel, no device is booted, Xcode is
closed, and the external image is **sha256-identical** to the registered one — that last check
matters because E4a hashed the *iOS* image, while E4b relocates watchOS (confirmed identical
2026-09-09: `d80c9180…`). Recovery is a pointer restore, not a re-import: the internal image is never
touched, and re-import is not in fact available here — the vault's watchOS artifact is an
`.exportedBundle` directory that `runtime import` rejects, and free space is below the 1.5×+2 GB
`preflightImport` requires.

Sequence, once a root shell is available and a simulator can be spared:

1. Record the baseline: `xcrun simctl runtime list -v`, `mount | grep CoreSimulator`.
2. Unmount the internal runtime volume, mount the external copy at the same canonical path.
3. `xcrun simctl runtime list` — does it still report `Signature State: Verified`, or does
   `SimDiskImageErrorDomain Code 5` / `-67061` finally appear?
4. Create a throwaway device on that runtime, boot it, install and launch a trivial app, shut down,
   delete. Watch for the H6 signature (`Failed to create a bundle instance`) rather than a seal error.
5. Restore: unmount, remount the internal image, verify the baseline devices return.

Report either outcome. A success would reopen ADR-0004; a failure at step 4 with the H6 signature
would close H1 for good and is the more likely result.

## E14 — is the CoreSimulator *device set* a relocation target? (gates H12)

Two halves, because they fail for unrelated reasons and entangling them wastes the cheap one.

**E14a — read-only reconnaissance. Done 2026-09-09.**
`scripts/experiments/e14a-device-set-static.sh`. Answers "what does the toolchain document",
"which binary reads a custom set path and from what input", and "what is actually inside the
device set". Evidence `evidence/e14a-device-set-static-*.txt`; findings F17–F21.

**E14b — does a device set work on an external physical volume? THE KILL GATE.**
`scripts/experiments/e14b-device-set-external.sh <set-path-on-/Volumes> --i-understand`.
Mutating, unprivileged, writes only under the path passed; refuses any path inside
`~/Library/Developer` or `/Library/Developer` or outside `/Volumes`; every `simctl` call carries
`--set`, so the default device set is never addressed. Phases, cheapest first. Phase 1 is **not** a kill gate; 2 onward are:

1. `simctl --set <external> list devices` — **smoke test only.** Measured 2026-09-15: this exits
   1 only when the path does not exist and 0 for any existing directory, and the script creates
   the directory immediately before asking — so exit 0 reports that `mkdir` worked, not that the
   service accepted external storage. Two gates were tried here and both were vacuous; see the
   note in the script. The first phase that discriminates anything about the volume is 2.
2. `simctl --set <external> create` — does a device get made there?
3. `boot`, then **poll `list devices` for `Booted`** — never `bootstatus -b`, which E11 recorded
   hanging on `Data Migration` long after the device had booted. **This is the H6 gate.** For
   simulator-destination testing the `.xctest` bundle is installed *into* the device's data
   container, so a device set on a USB volume is the E2 configuration one layer in.
4. install and launch a trivial `.app` from the external set — the E2 failure shape directly.
5. accounting: confirm nothing appeared in the default set; then delete the probe device and the
   probe set (guarded by a marker file the script itself wrote).

On failure at 3 or 4 the script captures `log show` for CoreSimulator/TCC/Sandbox **before**
cleaning up — E2 found nothing there, so an empty capture is itself the expected result and should
be recorded rather than retried.

## E14c — is it the physical removable device, or the removable *classification*? (narrows H6)

`scripts/experiments/e14c-image-on-vault.sh <directory-on-the-vault> --i-understand`. Mutating,
unprivileged. **Run twice on 2026-09-15 with identical results; see the matrix entry.** Both arms
created their device, so the discriminator is among the varied properties — and `Removable Media`
is excluded by direction, leaving `Protocol`.

E14b showed `simctl create` failing on the vault and succeeding in an internal alternate set,
with `tccd` queried for `kTCCServiceSystemPolicyRemovableVolumes` and the kernel denying
`file-write-create`. But those two volumes differed in four ways at once, so the result narrowed
to "volume class" and only the log pointed at removability. This narrows it further using E2's
own trick — an APFS disk image — and it measures the properties rather than assuming them.

**Measured while writing the script, and it killed the first two drafts.** An attached
case-sensitive sparse image reports `Device Location: External`, `Removable Media: Removable`,
`Protocol: Disk Image`, and mounts `nodev,nosuid` — while the vault reports `Device Location:
External`, `Removable Media: **Fixed**`, `Protocol: USB`. So the image is not "the non-removable
arm" the first draft assumed, and the two volumes do not agree on `Removable Media` the way the
second draft assumed. Draft one would have declared every run inconclusive. Phase 3 now computes
the held-equal and varied sets from both volumes at run time and phrases its verdict from them.

Two arms, cheapest and most disqualifying first:

1. **Arm B — image on the INTERNAL disk.** The control for the control. If `create` fails inside
   a disk image here, images do not host device sets at all and arm A is uninterpretable; the
   run stops and says so. Without this arm a null result in arm A has two readings and no way to
   choose between them.
2. **Arm A — image whose FILE lives on the vault.** The question. The bytes are on the USB
   device, the path is under `/Volumes`, the filesystem is case-sensitive APFS, the mount carries
   `nodev,nosuid` — and the volume is virtual rather than a real USB device.

Reading the result: if arm A creates, the discriminator is among the varied properties and not
among the held-equal ones, which on current measurements means a real removable device rather
than the `External` classification both volumes carry — consistent with E2, whose failure also
vanished inside images stored on that same USB SSD. If arm A fails, the discriminator is
something both arms share, **and that diverges from E2** — device creation failing where bundle
loading passed would mean the two restrictions are not one mechanism, which is a larger finding
than the one this experiment set out for. Record it separately rather than folding it into H6.

Not varied by either arm, and still what H6 needs to finish: **bus**. A Thunderbolt enclosure
would separate "physically removable" from "USB". Nothing here has done that.

## E18 — does `log erase` inside a device reclaim the simulated log store? (decides `simulatorLogStore`)

`scripts/experiments/e18-simctl-log-erase.sh --i-understand`. Mutating, unprivileged, ~5 min.
**Run 2026-09-15. Answer: no, in every documented form.**

`simulatorLogStore` was the one per-device regenerable with a documented narrow verb — `man log`
defines `log erase`, runnable inside a device through `simctl spawn` — and the catalog said so
while refusing to offer it, because an unreproduced verb is not a product feature. This reproduces
it.

**The dangerous command is the same command.** `log erase --all` on the HOST erases the user's own
Mac system logs; the `simctl spawn <udid>` in front of it is the entire safety property. The script
has exactly one function that invokes `log`, it refuses an empty UDID, and a test in the Swift suite
(`ExperimentScriptSafetyTests`) fails the build if `log erase` ever appears on a line without
`simctl … spawn`. That test exists because the first draft of this script contained
`echo "!! ``log erase --all`` failed …"` — backticks inside double quotes are command substitution,
so the line would have run the host-wide erase from inside an error message.

Method: create a throwaway device in a `mktemp` device set on the internal disk (external fails at
`create`, E14b), boot it, let it log for 120 s, measure `data/var/db/diagnostics` +
`data/var/db/uuidtext`, run the erase inside the device, measure again, and check the device still
works. Every simctl invocation carries `--set`, so the default device set is never addressed.

Result: `--all`, `--ttl` and no-argument all return `Error from logd: Operation not permitted`
(exit 1). `log stats` on the same device exits 0 and reports the archive, so the binary runs and can
read the store — the daemon declines the erase specifically. No denial appeared in the last 30 lines
of a host-side sandbox/logd capture, but that is a truncated tail of a noisy window and the guest's
own log was never queried, so it resembles E2's and E14b's silence rather than being shown to be it.

An earlier arm passed `--ttl 1`; `--ttl` takes no argument, so that was exit 64, a usage error, and
proved nothing. It is recorded as a broken arm rather than a refusal — a script that miscalls the
verb is not evidence about the verb.

Incidental, and **speculation rather than a finding**: on this probe `db/uuidtext` dwarfed
`db/diagnostics` — 152 MB vs 12 MB at the first measurement, 153 vs 15 three minutes later, and
84 MB in an earlier run at the same point, so uuidtext was still filling and the number is a moving
one. F18 measured the opposite ratio across three long-lived devices (1.2 GB diagnostics, 0.3 GB
uuidtext). Comparing one throwaway iPhone SE on iOS 26.5 against three devices of unstated age and
runtime, with no time series on either, does not establish that the symbolication table "dominates
early and is overtaken later". It is a difference worth a real measurement some day.

Evidence: `../research/evidence/e18-simctl-log-erase-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

## E15 — does `xcodebuild`/Xcode honour `DVTSimulatorSetLocation`? (gates H12's transparency half)

> **Never run. No evidence file exists for E15** — it is the only script in `scripts/experiments/`
> with a zero count, found by the 2026-09-19 harness audit (issue #23). It is also classified
> **destructive** by the `run-experiment` skill, because steps B–D `defaults write` and
> `defaults delete` a real key in the user's own `com.apple.dt.Xcode`; the script restores the prior
> value on exit, but an interrupted run leaves Xcode pointing at another device set — and the
> harness's own measured limitation is that cleanup traps do not run on interruption (see
> "Harness" below). Nothing in the product depends on E15 and `HYPOTHESES.md` does not cite it, so
> this is an unexercised tool rather than an unsupported claim. Run it and record the result, or
> delete it; do not leave a destructive script that nobody has ever run.

`scripts/experiments/e15-ide-honours-device-set.sh --i-understand`. Uses an alternate set on the
**internal** disk on purpose, so a failure here means "not transparent" and not "external storage".
Writes one user default and restores the prior value on exit including `^C`.

- A. control: build a one-device set with `simctl --set`.
- B/C. `xcodebuild -showdestinations` with the key unset, then set, in `com.apple.dt.Xcode`.
  **Identical output means xcodebuild does not see the key** — likely, since `xcodebuild` is not
  bundled and has no `--set` flag.
- D. repeat in the `xcodebuild` domain, which is what a non-bundled tool's standard domain may be.
- E. **manual**: quit Xcode, set the key, relaunch, and read the run-destination menu, the Devices
  and Simulators window and the Previews canvas. The direct answer is one log line —
  `log stream --predicate 'eventMessage CONTAINS "SimDeviceSet"'` prints either
  `Creating/fetching temporary SimDeviceSet at: <path>` or `Creating/fetching default SimDeviceSet`.
  Then check whether Simulator.app follows or shows the default set; if it splits, that is the
  rule 6 hazard and it fails the experiment even though both halves "work".

---

## Harness — cleanup traps do not run on interruption, and the reason is structural

**Measured 2026-09-17**, bash 3.2 on macOS 26.7 (25G229). Every script here has the same shape: the
body is a brace group piped through redaction and a filter —

```
{ … } 2>&1 | xcv_redact | tee "$out" | grep -E '…'
```

A brace group in a pipeline runs in a subshell. With a minimal reproduction —
`{ trap cleanup EXIT INT TERM HUP; echo BODY; sleep 60; } 2>&1 | cat` — the result is:

| trap position | normal exit | any interruption |
|---|---|---|
| **parent** (before the `{`) | **runs** | **does not run** |
| **body** (first line after the `{`) | **does not run** | **does not run** |

Interruption was tried four ways against both placements: `SIGTERM` to the parent alone, `SIGTERM`
to the whole pipeline (every stage carries the script's command line, so `pkill -f` matches them
all), and `SIGINT` to the process group, which is what Ctrl-C sends. None of them cleaned up.

**What follows from the table.** A trap in the parent is worth having — it covers the normal exit
path, which is how these scripts almost always end. A trap inside the body is worth nothing in any
case. Ten scripts here use this shape; all but one put the trap in the parent, which is the better
of the two.

**Do not "fix" a cleanup by moving its trap inside the body.** It reads as the obvious correction —
the subshell is where the resources live — and `e8c-import-roundtrip.sh` was changed that way on
review advice on 2026-09-16, which silently gave up the one path that did work in a script that
boots a device in the user's default device set. Reverted 2026-09-17 once the table above existed.

**The fix, applied to `e2-external-xctest.sh` on 2026-09-17 and validated.** Take the body out of
the pipeline: make it a function and call it with `> "$out.raw"` instead of `| …`. A function call
with a redirect does not fork, so it runs in the shell whose trap receives signals; redaction and the
console filter run afterwards over the file. Measured with `scripts/harness-trap-bench.sh`, which
builds both shapes and runs each under five conditions:

| shape | normal exit | Ctrl-C (group SIGINT) | SIGTERM |
|---|---|---|---|
| `{ … } \| redact \| tee \| grep` | cleans | **leaks** | **leaks** |
| `main > file` | cleans | **cleans** | cleans, **deferred** |

"Deferred" is measured rather than assumed: with SIGTERM the handler runs when the current
foreground command finishes, so an interrupt during an `xcodebuild` waits for that build to end. The
bench logged `ACQ t=0`, TERM at t≈1, `CLEANED t=6` against a six-second body. Ctrl-C is prompt
because the signal reaches the foreground child too. The same bench showed cleanup firing **twice**
on a signal — once from the handler, once from `EXIT` — so an idempotence guard is required rather
than tidy.

Validated on the real experiment, not only the bench: the full nine-case E2 re-run after the change
produced **9 of 9 identical verdicts** and a transcript of the same length, with the image detached,
both scratch directories removed and exit 0. An interrupted run was checked separately: image
detached, scratch removed, and a **partial transcript preserved** (763 bytes against 1212 for a
complete run), which is the wanted behaviour — a partial evidence file says what happened where a
missing one says nothing. It also restored live progress, which the buffered filter in the old shape
had cost.

**A false start worth recording, because it cost a day.** Five earlier attempts fixed symptoms rather
than the cause — a parent trap that broke the body's, a retry loop for a volume that was not busy, a
cleanup log written to dodge a SIGPIPE that was not happening — and were reverted. Two of those
failures were the *test*, not the script: one run measured a stale image left mounted by the previous
run, and three ran with stdout on `/dev/null`, so "no cleanup message" was read as "nothing to clean"
rather than "the cleanup never got there". A sixth failure was a verification window of 15 seconds
against a deferral that needed longer. Hence the bench: it asserts its precondition and captures
output, and both are the assertions the failures needed.

**`e12-case-sensitivity.sh` converted next (2026-09-17), and one subtlety that does not transfer.**
E12 calls its own `cleanup` **twice by design** — once to clear leftovers before setup, once as
teardown — so the idempotence guard could not go on `cleanup` itself the way it did in E2; it would
have turned the teardown call into a no-op. The guard lives on a separate `on_exit` wrapper while
`cleanup` stays repeatable. Copying E2's shape wholesale would have broken it silently.

Validated for the normal path: the run after conversion matches the run before on **19 of 20
sections**, the one difference being the SwiftPM build's step count, which moves when this repository
gains a file. Clean teardown, exit 0, and live per-case progress restored.

**Its interrupt path was NOT independently demonstrated, and that is worth stating rather than
implying.** Three attempts all ended with a complete transcript and a normal teardown: the signal
either arrived after the last long command or the run finished before it mattered. One attempt looked
like a success — the mount disappeared while the process was still alive — until it became clear that
this is *also* exactly what a normal teardown does, so the observation cannot discriminate between
the two. A clean discriminator exists and was not reached in the time given: interrupt during case A
and check whether the transcript is missing its `## teardown` marker. E12 therefore inherits the
structural guarantee established on the bench and demonstrated on E2 (a genuine partial transcript,
763 bytes against 1212), rather than carrying its own proof.

**Still not propagated.** Eight scripts have the old shape. They are left alone deliberately: most
mutate devices behind `--i-understand`, and changing a script one cannot run is how the first attempt
went wrong. Convert one at a time, each validated the way these two were — and pick a discriminator
that a normal completion cannot also satisfy.

**Consequences to accept until it is fixed.** An interrupted run can leave: sparse disk images
attached under `/Volumes`, work directories on the internal disk and on the vault, and — for
`e8c` — a probe device booted in the default device set. All are inert and removable by hand; none
is data loss. After interrupting any experiment, check:

```
mount | grep -i XCV ; xcrun simctl list devices | grep xcv-probe ; ls ~/.xcodevault-e2-scratch
```

## E6b — does a mount stub reappear at a CoreSimulator cache path? (gates H14, issue #29)

Two variants over one target from the closed set (`dyld` or `cryptex`): a scripted software
unmount (`scripts/experiments/e6b-mount-stub-reappearance.sh`) and a physical cable pull
(`e6b-physical-disconnect.sh`). Both are needed — a clean `umount` is not obviously the same event
as a surprise removal. Procedure in `docs/process/RUNBOOK-E6b-disconnect.md`. Needs root, a
disposable donor volume and, for the second variant, hands at the machine.

**Status: blocked upstream, 2026-09-21.** Neither variant has produced a finding, because staging
the mount fails: `mount_apfs` returns `Operation not permitted` to root at the cache path. See
H14 in `HYPOTHESES.md` for the measurement and the reading rule, and E6c below for the experiment
that separates the two explanations.

## E6c — is it the path or the mechanism? (unblocks E6b)

`scripts/experiments/e6c-mount-mechanism.sh` fills a mechanism × path matrix: `mount_apfs` and
`diskutil mount nobrowse -mountPoint`, each against a throwaway directory under
`/Library/Developer` and against the real cache path. The fourth cell is the E6b measurement and
is not repeated.

The reading rule is fixed in H14 **before** the run, deliberately: the two outcomes retire or
merely postpone a hypothesis, and a rule written after seeing the numbers is not a rule. The
script aborts rather than recording a cell whose REFUSED could have a cause other than the mount
being refused — a donor that failed to unmount, an absent target — because a false "the path is
protected" would close H14 on the strength of an open file.

Needs root and a disposable donor. Nothing is written to either target; the run also compares the
donor's root before and after, because anything a daemon writes to a cache path while the donor is
mounted over it lands on the donor and survives the unmount.

**Two traps to avoid when re-attempting this.** First, assert the precondition: a test that starts
with a stale image already mounted measures the previous run, and reports a leak that is not this
run's. Second, capture the output: three of the attempts above ran with stdout on `/dev/null`, so
the cleanup's own messages — the thing that says whether it ran at all — were invisible, and the
absence of a "detaching" line was read as "nothing to detach" rather than "the cleanup never got
there".

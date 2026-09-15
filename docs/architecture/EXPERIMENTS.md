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
GC. The orphan measured for F10 was created at 18:54 on the same day the machine last booted at
17:39, so it has survived simulator boots but never a restart. Until this runs, "nothing reclaims
it" is a statement about one uptime session.

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
  (E13b) become worth running, and only then may `doctor` mention a command.
- **Still there but shrunk / partially rebuilt** → CoreSimulator is treating it as a resumable build.
  That would falsify the "interrupted, abandoned" reading in F10 and argue for widening the `inc/`
  age guard well beyond its current one hour.

**E13b (only if it survives):** attempt the narrow removal `doctor` currently suggests — `rm -f` of
`dyld_sim_shared_cache_*` and `update_dyld_sim_shared_cache-std*.txt`, then `rmdir`. Record whether
root is refused, and if so whether `chflags`/`lsof` explain it (they did not for the Inbox). A
refusal is the more interesting result: it would mean a second path where root is blocked without a
SIP flag or a `rootless.conf` entry, which is worth reporting to Apple and worth a rule of its own.

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

## E15 — does `xcodebuild`/Xcode honour `DVTSimulatorSetLocation`? (gates H12's transparency half)

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

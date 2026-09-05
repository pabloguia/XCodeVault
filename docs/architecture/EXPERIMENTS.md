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

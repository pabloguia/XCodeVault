# Technical Hypotheses

Every non-trivial architectural claim in this project starts as a hypothesis here,
not as an assumption baked into code. Status values: **unverified** (default for
anything new) → **probable** (some evidence, not reproduced across matrix) →
**verified** (reproduced with functional tests, recorded in COMPATIBILITY_MATRIX.md)
→ **falsified** (disproven — keep the entry, record why, don't delete history).

Do not write product code that depends on a hypothesis above `probable` without also
updating its status here, with evidence.

## H1 — Canonical APFS mount for CoreSimulator (the primary open question)

**Claim:** Modern CoreSimulator storage can be safely and transparently placed on an
external APFS volume by mounting that volume directly at a canonical
`/Library/Developer/CoreSimulator...` path (not a symlink), while preserving:
simulator boot/run, Xcode builds, multi-Xcode-install compatibility, reboot behavior,
and physical-device debugging.

**Status:** unverified. Prove or falsify — do not assume yes.

**Why it matters:** if true, it avoids per-file relocation/symlink fragility for the
largest storage category. If false (or only true for a narrower boundary), the
product should fall back to `userDirectoryRelocation`/`symlinkRelocation` at a safer
granularity, or `nativeConfiguration` where Apple exposes one.

**Sub-questions to resolve before declaring a verdict:**
- Is the ideal mount boundary the whole `/Library/Developer/CoreSimulator` tree, or a
  narrower one (`.../Images` only, etc.)? Decide from test evidence, not intuition.
- Behavior across `mount_apfs`, `diskutil`, Disk Arbitration, `/etc/fstab`,
  UUID-based mounting, launchd-triggered mounting, automount timing, unmount
  ordering, ownership/ACL/xattr propagation, FileVault interaction.
- Differences: Intel vs. Apple Silicon; macOS release; Xcode generation (12/14/15/16/26+).
- Reboot and login-race behavior; crash-mid-mount behavior.

## H2 — Whole-`~/Library/Developer` symlink is unsafe on Xcode 15+

**Claim:** Symlinking the entire `~/Library/Developer` tree breaks Xcode 15+ physical
device DDI (DeveloperDiskImage) discovery, even though the equivalent worked on
Xcode 14 and earlier.

**Status:** probable (reported symptom motivating this project; needs our own
reproduction before being treated as verified). Treat as true for design purposes
(never do whole-tree symlinking) regardless of final verification status — the
downside of being wrong is much larger than the cost of avoiding it.

## H3 — External-drive-absence split-brain risk

**Claim:** If a canonical-mount or symlink-relocated path is left as an empty local
directory when the external volume is absent at boot, macOS/Xcode/CoreSimulator will
write new local content into it, creating a hidden shadow copy that collides with the
external volume on reconnect.

**Status:** probable — this is a known class of failure for this kind of setup in
general; verify the specific behavior for each strategy before shipping it, and design
mount-readiness / shadow-detection regardless (see `MIGRATION_ENGINE.md`).

## H4 — Official Apple mechanisms cover more than assumed

**Claim:** `xcodebuild -downloadPlatform` / `-downloadAllPlatforms` / `-importPlatform`,
DerivedData relocation, and other supported configuration points can satisfy more of
the storage-reduction goal than ad hoc filesystem relocation, for some categories.

**Status:** unverified — audit current Xcode CLI/config surface per supported
Xcode version before assuming a category needs a filesystem-level strategy at all.

## Evidence discipline

For each hypothesis, log in `COMPATIBILITY_MATRIX.md`: macOS version/build, Xcode
version/build, architecture, what was tested, reproduction steps, and result. Source
priority when researching: (1) official Apple docs, (2) Xcode release notes, (3) man
pages, (4) our own experimentally verified behavior, (5) Apple Developer Forums, (6)
high-quality open-source implementations, (7) community reports. Never promote a
forum workaround straight to "verified" — reproduce it yourself first.

# Technical Hypotheses

Every non-trivial architectural claim starts as a hypothesis here, not as an
assumption baked into code. Status: **unverified** → **probable** (evidence, not
reproduced by us) → **verified** (reproduced with functional tests, recorded in
`COMPATIBILITY_MATRIX.md`) → **falsified** (keep the entry, record why).

Do not write product code that depends on a hypothesis below **probable**, and do not
ship a user-facing strategy built on one below **verified**.

Desk evidence for all of these is in `../research/FINDINGS-2026-09-05.md` (F-numbers
below refer to it). The reproduction protocol is in `EXPERIMENTS.md` (E-numbers).

---

## H1 — Canonical APFS mount for CoreSimulator

**Claim:** modern CoreSimulator storage can be safely and transparently placed on an
external APFS volume mounted at a canonical `/Library/Developer/CoreSimulator...`
path, preserving simulator operation, Xcode builds, multi-Xcode compatibility, reboot
behavior and physical-device debugging.

**Status: unverified.** Evidence is mixed-to-negative and the framing needed fixing:

- The bytes are **not** mostly where the original brief assumed. `Profiles/Runtimes`
  is largely a mount graft; the real storage is `Cryptex/Images/bundle/` and
  `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/` (F1). A mount
  at `/Library/Developer/CoreSimulator` therefore captures **less** than assumed.
- `simdiskimaged` creates **nested mounts** under `Volumes/` inside the very directory
  we would be mounting over (F1). Surprise removal tears down a mount *tree*.
- Every published user attempt to relocate the system-domain CoreSimulator (2021,
  2022, Oct 2024) **failed** — all via symlink/alias, never via a mount (F3).
- No one has published a canonical-mount attempt at all. This remains genuinely open.

**Verdict gate:** E1 → E2 → E4 → E6 in `EXPERIMENTS.md`, in that order. E1 or E2
failing kills this hypothesis outright.

## H2 — Whole-`~/Library/Developer` symlink breaks Xcode 15+ DDI discovery

**Status: probable, and treated as true regardless.** FB12363725, reproduced on Xcode
15.0/15.1/15.3 (F3). The published workaround also gives us a hard constraint worth
encoding as an invariant: `~/Library/Developer` stays a **real directory**;
`~/Library/Developer/DeveloperDiskImages` **must never be a symlink**. Asymmetric
downside — never do whole-tree redirection regardless of final verification status.

## H3 — Disconnect creates silent shadow data

**Claim:** when the external volume is absent, the canonical path resolves to an empty
local directory, daemons write into it, and on reconnect the mount either fails or
hides that data, which then consumes internal disk invisibly.

**Status: probable** (VFS semantics + the nested-mount complication; not sourced for
APFS surprise removal — F6). Design for it regardless. Candidate defense —
`chflags uchg` + mode `0500` + root ownership on the unmounted mount point so stray
writes fail loudly — is **our own synthesis and unverified**; it may simply crash
Xcode in a worse way. Gate: E6, E7.

## H4 — Official Apple mechanisms cover more than assumed

**Status: probable → partially verified by documentation** (F2). Confirmed by Apple
docs: `-downloadPlatform`/`-downloadAllPlatforms` with `-exportPath`, then
`-importPlatform <dmg>` — i.e. the Runtime Library concept is **officially supported**;
`-architectureVariant arm64` cuts image size; `-downloadComponent`/`-importComponent`
(Xcode 26) for the Metal toolchain; `~/Library/Developer/Packages/` is a real,
documented, undermanaged cache. Still unverified: whether `IDECustomDerivedDataLocation`
/ `IDEBuildLocationStyle` key names are current for Xcode 16/26 (2016-era source).
Gate: E8.

## H5 — Symlink indirection breaks the Simulator even on the same disk *(new)*

**Claim:** symlinking `~/Library/Developer/CoreSimulator` breaks Simulator subsystems
(Files app: cannot share, save, or create folders) independently of any external drive.

**Status: probable** — Jeff Johnson, 2025-08-17, target on the same internal disk (F3).

**Why this matters more than H1:** it removes "per-category symlink" as the safe
fallback for CoreSimulator, which is precisely what the prior art does. If confirmed,
CoreSimulator has **no** symlink-based strategy at any risk level, and the choice
narrows to canonical mount (H1), official mechanisms (H4), or cleanup only. Gate: E9.

## H6 — External-volume sandbox/TCC restrictions apply regardless of mount path *(new, highest value)*

**Claim:** the sandbox/TCC restrictions that break `xctest` bundle loading from
`/Volumes/...` — which hit even Apple's *supported* DerivedData relocation (F4) —
classify by **device removability**, not by path.

**Status: unverified.** If true, mounting at a canonical path does **not** escape the
problem and a large part of the canonical-mount thesis collapses; the product would
have to warn that test execution against externally-located build products is
degraded, whatever the mechanism. If false (path-based), canonical mount gains a
concrete, demonstrable advantage over symlinks and becomes the strategically
interesting path. **This single experiment (E2) changes the product's shape more than
any other.** Run it first, alongside E1.

## H7 — FSKit passthrough is the eventual right mechanism *(new)*

**Claim:** an FSKit passthrough file system (`FSPathURLResource`, `mount -t <fs>`) can
redirect a canonical path to external storage as a first-party, kextless,
notarizable, SIP-compatible mechanism — the bind mount macOS never had (F5).

**Status: unverified and deliberately deferred.** macOS 26.0+ only; requires the
`com.apple.developer.fskit.fsmodule` entitlement (appears approval-gated); requires
the user to enable the extension manually; the sample omits xattr operations and
kernel-offloaded I/O, both of which a CoreSimulator-backing filesystem needs;
performance for simulator-scale I/O is unmeasured. Track as an R&D tier with an ADR,
not as a v1 mechanism.

## H8 — `/Library/Developer/CoreSimulator` is mountable at all *(new, gating)*

**Claim:** `/Library/Developer/CoreSimulator` is not SIP-protected
(`com.apple.rootless`) and root can mount a volume over it.

**Status: unverified — and it gates H1 entirely.** If the path carries
`com.apple.rootless`, the whole canonical-mount approach dies immediately and the
project should reallocate effort to H4 + cleanup + disconnect safety. This is a
one-command check (E1). **Do it before anything else.**

## H9 — Byte-identical relocation preserves runtime seal validation *(new)*

**Claim:** a sealed simulator-runtime image copied byte-identically to another APFS
volume still passes cryptex seal/trust-cache verification and mounts.

**Status: unverified.** Failure surfaces as `SimDiskImageErrorDomain Code 5` /
`-67061 invalid signature` (F1). Nobody has published such a test. Gate: E4.

---

## Evidence discipline

Log every experiment in `COMPATIBILITY_MATRIX.md` with macOS version/build, Xcode
version/build, architecture, procedure, and result. Research source priority:
(1) official Apple docs, (2) Xcode release notes, (3) man pages, (4) our own
reproduced behavior, (5) Apple Developer Forums (DTS answers rank above user posts),
(6) high-quality open-source implementations, (7) community reports. Never promote a
forum workaround straight to "verified" — reproduce it first.

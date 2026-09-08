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

**Status update 2026-09-06 (E1 read-only half + E2, macOS 26.6.2 / Xcode 26.5 / Intel):
still unverified, and reframed as low-value on Xcode 26.** The path is mountable (H8), but
`Cryptex/Images/bundle` is empty and **every installed-runtime byte lives in
`/System/Library/AssetsV2/…`**, which no mount under `/Library/Developer` can capture. The only
regular storage a canonical mount would move is `Caches/dyld` (7.4 GB, regenerable — i.e.
deletable). E2 additionally shows the external-device test restriction follows the physical
volume, not the path, so a canonical mount would not buy DerivedData anything either. The
mount attempt itself (root required) is **pending — manual**; see ADR-0004 for the
consequence: canonical mount drops from "gated headline" to "R&D curiosity" for v1.

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

**Status: probable, partially reproduced (E6 software variant, 2026-09-06; E7, 2026-09-07).**
A force unmount of a real USB APFS vault mid-copy made macOS remove the `/Volumes/<name>` mount
point outright, so no local directory was left to collect shadow writes in that scenario; the
volume came back at the same path. Shadow data therefore requires something to recreate the
directory (a tool writing an absolute `/Volumes/…` path, Xcode's own Locations, a `Name 1`
remount) — which is exactly what `doctor` now checks for. Physical yank not yet tested. Design
for it regardless. Candidate defense — `chflags uchg` + mode `0500` + root ownership on the
unmounted mount point so stray writes fail loudly — **partially verified (E7, 2026-09-07): does
not crash Xcode.** `xcodevaultctl scan`/`doctor` silently skip a `0500` root-owned directory
under `/Library/Developer` during their `fts` walk (no crash, no warning surfaced — a visibility
gap, not a safety one). A real `xcodebuild build` pointed at a derived-data path inside such a
directory (via `-derivedDataPath`, isolated from any live build) failed loudly and cleanly:
"Couldn't create workspace arena folder … you don't have permission", `** BUILD FAILED **`, exit
65 — no crash, no hang, no corrupted state, confirmed against a live `log stream` capture (no
SIGSEGV/SIGABRT/fatal-error lines). Not yet tested: the Xcode.app GUI (only `xcodebuild` CLI was
exercised, to avoid touching the global `IDECustomDerivedDataLocation` default while a real build
was running concurrently) and the `VaultVerifier` sentinel-file check (no vault was pointed at
the probe path). Gate: E6, E7.

## H4 — Official Apple mechanisms cover more than assumed

**Status: verified end-to-end for the Runtime Library workflow (E8, 2026-09-06 export +
2026-09-07 import).** Every flag below is present in `xcodebuild -help` on Xcode 26.5, plus
`-deleteComponent`, `-prepareDeviceSupport`, and `simctl runtime add/delete/unmount/verify`.
`IDECustomDerivedDataLocation` **is honoured by xcodebuild on 26.5 (E8b, verified)** and the
compilation cache lives inside DerivedData by default. The `-exportPath` export **ran for
tvOS (E11 evidence): it downloads, installs the runtime internally, then exports an
`.exportedBundle` — peak ≈1.4× the image internally.** The `-importPlatform` half, previously
pending (blocked once by an environmental space shortfall on 2026-09-06), **now passed
(2026-09-07):** `xcodevaultctl runtime import` invokes `xcodebuild -importPlatform <dmg>`
with the direct path to the `.exportedBundle`'s inner Cryptex dmg — that argument form worked
on the first try, no fallback to the bundle directory or `simctl runtime add` was needed —
consuming a peak of 4.807 GB internally for a 4.906 GB image (≈0.98×, vs. ≈1.18× on the prior
attempt), then a full functional probe (create → boot → reach `Booted` → shutdown → delete
device → `runtime delete` → `simctl delete unavailable`) all exited 0 and left the machine
back at its prior runtime/device state. So the Runtime Library is supported "export → offload
→ import" round trip, verified working, not just "export then offload". Confirmed by Apple
docs: `-downloadPlatform`/`-downloadAllPlatforms` with `-exportPath`, then
`-importPlatform <dmg>` — i.e. the Runtime Library concept is **officially supported**;
`-architectureVariant arm64` cuts image size; `-downloadComponent`/`-importComponent`
(Xcode 26) for the Metal toolchain; `~/Library/Developer/Packages/` is a real,
documented, undermanaged cache. Still unverified: whether `IDECustomDerivedDataLocation`
/ `IDEBuildLocationStyle` key names are current for Xcode 16/26 (2016-era source).
Evidence: `docs/research/evidence/e8c-import-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

**Re-run against a much larger image, iOS 26.5 (10.35 GB), on 2026-09-08: confirms the ratio
holds.** Export was near-free (1 MB peak — the runtime was already installed, so `-exportPath`
just copied the sealed image out, no re-download/re-install); offload freed the runtime and
left the two real, in-use devices on it (`iPhone 17 Pro Max`, `iPhone SE (3rd gen)`) in
`Unavailable` state (not deleted); import peak was **10.110 GB for a 10.35 GB image (≈1.0×,
matching the tvOS ≈0.98–1.18× range)**, `simctl runtime verify` passed, and — critically — the
two real devices came back to normal `Shutdown` state **automatically** once the same-version
runtime was reimported, with zero data loss and no manual recreation. The throwaway probe
device booted successfully (confirmed via `simctl list devices` state), but **`simctl
bootstatus -b` itself hung** reporting a non-terminal `Data Migration` status for several
minutes after the device had actually reached `Booted` — a monitoring-tool gotcha, not a
runtime/import defect (worked around by polling device state directly instead of trusting
`bootstatus`'s exit). Evidence:
`docs/research/evidence/e11-iOS-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
`docs/research/evidence/e11-import-iOSSimulatorRuntime_Cryptex-macos26.6.2-25G83-xcode26.5-x86_64.txt`.
Gate: E8 — closed.

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

**Status: probable — device-based (E2, 2026-09-06, macOS 26.6.2 / Xcode 26.5 / Intel).**
The F4 failure reproduced verbatim (`xctest … Failed to create a bundle instance`) with
DerivedData on a real USB APFS SSD, both under `/Volumes/…` and through an internal-path
symlink; it did **not** reproduce on APFS disk images (case-insensitive or case-sensitive,
at `/Volumes` or at a `$HOME` mount point, even under an identical hidden path), and
`swift test`'s own `xctest` loads the same bundle from the USB volume fine. The discriminator
is the physical external device (TCC "Removable Volumes" is the prime suspect; log capture in
`evidence/e2-*.txt`). Canonical mount therefore buys nothing here; the product warns before
placing DerivedData on external storage, exactly as `NON_GOALS_AND_SAFETY.md` requires.
Remaining unknowns: Apple Silicon, Thunderbolt NVMe, and whether the Xcode IDE's own test
runner behaves like `xcodebuild`. Original framing kept below for the record.

If true, mounting at a canonical path does **not** escape the
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

**Status: verified (E1 read-only half 2026-09-06 + mount half 2026-09-07, macOS 26.6.2 / Xcode 26.5 / Intel).**
Root mounted a scratch APFS volume over `/Library/Developer/xcv-probe`, wrote to it, unmounted,
and the directory was an empty local directory again. Note the default `noowners` mount. No `restricted`/`sunlnk`
flag, no `com.apple.rootless` xattr on `/Library/Developer` or `…/CoreSimulator`;
`rootless.conf` protects only `/System/Developer`. The actual mount attempt over a throwaway
path needs root and is **pending — manual** (`scripts/experiments/e1-mountability.sh` records
the read-only half; the mount step is documented in `COMPATIBILITY_MATRIX.md`). Note that H8
being true no longer rescues H1 — see H1's 2026-09-06 update.

## H9 — Byte-identical relocation preserves runtime seal validation *(new)*

**Claim:** a sealed simulator-runtime image copied byte-identically to another APFS
volume still passes cryptex seal/trust-cache verification and mounts.

**Status: unverified.** Failure surfaces as `SimDiskImageErrorDomain Code 5` /
`-67061 invalid signature` (F1). Nobody has published such a test. Gate: E4.

---

## H10 — The MobileAsset runtime store is the real relocation target on Xcode 26 *(new, 2026-09-06)*

**Claim:** on Xcode 26 the only way to move installed-runtime bytes off the internal disk
would be to relocate `/System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime/`
(or make `mobileassetd`/`simdiskimaged` accept an image elsewhere via `simctl runtime add`).

**Status: unverified and, for v1, out of bounds.** The path is under `/System` (CLAUDE.md
rule 2 forbids modifying it, even though it is physically on the Data volume), is owned by
`mobileassetd`, and orphaned `NeverCollected` assets there are a documented failure mode
(F1). `simctl runtime add` clones the image into the store when possible and copies
otherwise, so an image kept on an external volume costs a full copy on install. The
supported answer remains: keep *installers* external (Runtime Library) and keep at most the
runtimes you use installed. Revisit only with an Apple-supported mechanism.

## Evidence discipline

Log every experiment in `COMPATIBILITY_MATRIX.md` with macOS version/build, Xcode
version/build, architecture, procedure, and result. Research source priority:
(1) official Apple docs, (2) Xcode release notes, (3) man pages, (4) our own
reproduced behavior, (5) Apple Developer Forums (DTS answers rank above user posts),
(6) high-quality open-source implementations, (7) community reports. Never promote a
forum workaround straight to "verified" — reproduce it first.

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
**Replicated 2026-09-09 through XCodeVault's own verbs (F13).** Both runtimes were offloaded, then
iOS alone re-imported: the two iPhones returned to `Shutdown` with their data (3.7 GB, 4.3 GB)
automatically, while the Apple Watch Ultra 3 — needing the still-offloaded watchOS runtime —
correctly stayed `unavailable` with its 1.2 GB intact. So device availability tracks the *specific*
runtime, not merely "an import happened". Import peak 9 GiB for a 9.9 GB image (~0.9×).
Unpredicted, and load-bearing for anything that records what was offloaded: the runtime came back
with a **different image UUID** (`34AF883C…` → `99ABCCEF…`), so `simctl runtime list`'s identifier is
a per-installation id and only `runtimeIdentifier` survives a round trip. Still one configuration —
same-version re-import on macOS 26.6.2 / Xcode 26.5 / Intel.

Gate: E8 — closed.

## H5 — Symlink indirection breaks the Simulator even on the same disk *(new)*

**Claim:** symlinking `~/Library/Developer/CoreSimulator` breaks Simulator subsystems
(Files app: cannot share, save, or create folders) independently of any external drive.

**Status: NOT REPRODUCED on this configuration (E9, 2026-09-08, macOS 26.6.2 25G83 /
Xcode 26.5 17F42 / Intel x86_64).** The claim as stated — that the Files app cannot share,
save, or create folders — did **not** hold here. With `~/Library/Developer/CoreSimulator`
renamed to `~/CoreSimulator-real` and replaced by a symlink to it (same internal disk), all
three reported operations succeeded on a throwaway `iPhone 17 Pro` device, each confirmed on
disk through the symlink: creating a folder (`File Provider Storage/untitled folder`), sharing
a photo via Share > Save to Files (`IMG_0002.JPG`, 2,567,402 bytes), and a Safari download
landing in Files (`Downloads/e9-safari-download.zip`). The share sheet opened and behaved
normally. A full `xcodebuild build` → `simctl install` → `launch` cycle also succeeded
(`** BUILD SUCCEEDED **`, exit 0) and the app wrote `e9-write-test.txt` into its own container
through the symlink without crashing. The device registry survived a forced
`CoreSimulatorService` restart with all devices intact. A debug-level guest `log stream`
(845,711 lines) showed subsystems resolving through the symlink and succeeding, with no sandbox
denials and no FileProvider errors. Evidence:
`../research/evidence/e9-symlink-coresimulator-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

**This does not make symlinking CoreSimulator a supported strategy, and `CLAUDE.md` rule 7
stands unchanged.** One passing configuration is not a safety proof: the original report (F3)
may have been accurate for its own OS/Xcode build, the failure may be intermittent or depend on
iCloud Drive / a signed-in Apple Account (absent here), and this run exercised a *freshly
created* device rather than long-lived ones with accumulated state. What E9 does settle is
narrower and still useful: the mechanism is **not** an unconditional, immediately-visible break
on current macOS/Xcode, so a user who already has this layout (e.g. via `mac-ssd-rescue`) will
not necessarily see obvious Files-app symptoms — which makes silent, hard-to-attribute breakage
the more realistic risk, and argues for `doctor` detecting and reporting the layout rather than
relying on the user noticing failures. The product still ships no symlink strategy for
CoreSimulator (ADR-0004: accounting + official mechanisms + cleanup + disconnect safety).

**Caveat on what was NOT tested:** the FB12363725 half of E9. The report's precondition is
symlinking `~/Library/Developer` *itself*, which was deliberately not performed (it would move
`DeveloperDiskImages`, forbidden by rule 7). As read-only negative evidence for the narrow case,
both paired physical devices (iPhone 17 Pro Max, Apple Watch Ultra 2) stayed
`available (paired)` in `devicectl` throughout, with no "Preparing…" state and no DDI errors,
while only `CoreSimulator` was symlinked. Also untested: the Xcode.app GUI (only `xcodebuild`
was exercised), Apple Silicon, and any configuration with iCloud Drive signed in.

**Why this mattered more than H1:** it was expected to remove "per-category symlink" as the safe
fallback for CoreSimulator, which is precisely what the prior art does. The strategic conclusion
is unchanged by this result — the choice remains canonical mount (H1), official mechanisms (H4),
or cleanup only — because the reason for refusing the symlink is now "unverified and
contradicted by a credible field report we could not reproduce", not "proven broken". Gate: E9
(executed 2026-09-08; runbook `../process/RUNBOOK-E9-symlink-coresimulator.md`).

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

**Narrowed by E14c, 2026-09-15, run twice with identical results.** A case-sensitive APFS disk
image whose FILE is stored on the vault hosts a device the vault itself refuses. The script
computes the comparison rather than asserting it, and both runs came out the same: **held equal**
were case sensitivity, `Device Location=External`, and the mount options (`nodev,nosuid,journaled`
on both), plus — by construction — the physical device holding the bytes and the `/Volumes` path.
**Varied** were `Removable Media` and `Protocol`.

That TCC's "removable" is not DiskArbitration's `Removable Media` is already known from E14b's
log, independently of this experiment: `tccd` queried
`service=kTCCServiceSystemPolicyRemovableVolumes` about a volume `diskutil` labels **`Fixed`**
(`../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`). E14c's own direction observation — the volume labelled `Removable`
works, the one labelled `Fixed` fails — is consistent with that but does not prove it: it would
only follow if the policy had been evaluated for the image volume and allowed, and **E14c captured
no TCC logs in either run**. A restriction that short-circuits on "virtual device" before reaching
any removability field fits the same data. What survives as the discriminator is `Protocol`: a
real device versus a virtual one, which is also exactly E2's shape.

So H6's "not by path" half is **established on this combination** — the same `/Volumes` path
*class* (the two paths themselves differ: `…/XCodeVault/E14bSet` versus the image's mount point),
same filesystem,
same mount options, same physical medium, and the image works. Its "by removability" half is
sharper but not isolated: **removability and bus are still the same variable here**, because every
external volume tested has been USB. E14d — a Thunderbolt or NVMe enclosure — is what separates
them, and the project has no such hardware. Evidence: `../research/evidence/e14c-image-on-vault-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

**Second independent reproduction, 2026-09-15, with the mechanism named for the first time
(E14b phase 2 + its control).** Status stays **probable**, not verified: this is still one
physical device on one machine, which is the same limit E2 had. What is new is that the failure
reproduced in a subsystem E2 never touched — CoreSimulator device creation, no `xctest`, no
bundle loading — and that the log names the policy. E2's matrix entry reads "mechanism unnamed"
after querying the same subsystems; here `tccd` is queried three times for
`service=kTCCServiceSystemPolicyRemovableVolumes` about CoreSimulatorService, the kernel logs
`deny(1) file-write-create` on the set path, and the copy then fails with EPERM. The internal
control succeeded with identical commands, so the volume is the variable. To reach *verified*,
H6 needs what it always needed — a second physical device, Apple Silicon, Thunderbolt — plus
E14c — which has since run and did **not** isolate removability, only narrowed it; see the
paragraph above. It was expected to separate removability from the
other three differences. Original conditional framing kept below.

**Original framing, written before the control ran:** CoreSimulatorService
failed to populate a simulator device's data container on the USB vault with EPERM and an empty
unified-log capture that, unlike E2's, is **not** silent: `tccd` queries
`kTCCServiceSystemPolicyRemovableVolumes` for CoreSimulatorService and the kernel logs
`deny(1) file-write-create` on the set path, milliseconds before the copy fails. Different
subsystem from E2, no `xctest` involved, and the first named mechanism in this repo — E2's own
matrix entry records "mechanism unnamed" after querying the same places. If `e14b-control-internal-create.sh` shows the identical create succeeding on an
internal alternate set, that narrows the cause to volume class — **not yet to removability**,
because the two volumes also differ in case sensitivity, mount options and bus, none of which
E2 controlled for a *copy* as opposed to a bundle load. It would be consistent with H6 and would
justify an experiment that varies one factor at a time; it would not by itself be a second
reproduction. If the control fails too, this observation is not about H6 at all. Do not cite it either way until
the control has run.

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

**Status: the seal half is verified; the "CoreSimulator uses it in place" half is not
(E4a, 2026-09-09, macOS 26.6.2 25G83 / Xcode 26.5 / Intel).** The vault copy of the installed
iOS 26.5 image is byte-identical (sha256 `e27aaecf…`, previously only inferred from size+mtime),
and attaching it **from the external USB APFS volume** mounts `sealed`, as a normal user, with
`iOS 26.5.simruntime` readable inside. The `.exportedBundle` inner image behaves the same.
Negative control: flipping one byte makes both `hdiutil verify` and `hdiutil attach` fail
(`checksum failed with error 1000`), so `sealed` is enforced rather than carried along. The named
failure — `SimDiskImageErrorDomain Code 5` / `-67061` — did not occur.

**What is still open, and it is the part that decides the product question.** `simctl runtime add`
*stages* an image into the internal secure storage area (the "clone" it mentions is same-volume
only), and no simctl verb points CoreSimulator at an external path — so nothing here shows a runtime
being *used* with its bytes left outside. Nor is a user-level `hdiutil` APFS seal shown to be the
same gate as the cryptex trust-cache check that emits -67061. Making the copy visible at the
canonical location needs root and is recorded as **E4b** (amended to an images.plist repoint — the mount route cannot distinguish a real read from a stale mount); per H6 that is where the
interesting failure is expected anyway, since the xctest restriction classifies by device
removability rather than path. Evidence:
`evidence/e4a-seal-survives-external-relocation-macos26.6.2-25G83-xcode26.5-x86_64.txt`.
**E4b, 2026-09-09: answered, negatively, and the reason is upstream of everything else.** Root
cannot write `/Library/Developer/CoreSimulator/Images/images.plist` — `Operation not permitted` on
an existing `root:wheel 644` file, with no BSD flags, no ACL and no `rootless.conf` entry — while
simdiskimaged rewrites the same file freely (F16). So a runtime cannot be pointed at an external
image at any privilege a product may use. **H9 is settled and split: the seal survives relocation,
and the relocation cannot be effected.** The run aborted before writing anything and left the
machine healthy: both runtimes Ready, both volumes mounted, no unavailable devices.

Gate: E4 — closed (E4a positive, E4b negative).

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

## H11 — regenerable system caches are reclaimed by the system, not by us

**Status: falsified as a general rule (2026-09-16). The startup GC is path-specific.** Two paths
under `/Library/Developer/CoreSimulator` accumulate multi-GB residue that no user action reclaims:
the runtime Inbox (F1) and the dyld shared-cache tree (F10). They now answer *differently*, and that
split is the finding:

| path | root deletion | restart |
|---|---|---|
| runtime Inbox `.dmg` (F1) | refused, `Operation not permitted` ×3 | **reclaims it** (2026-09-07, +5 GB) |
| `Caches/dyld/<build>/inc/` (F10) | untested — E13b, and it lost its target | **does nothing** (E13, 2026-09-16, byte-identical across two restarts) — but a macOS **update** removed the whole host-build tree hours later; the installed runtimes' caches rebuilt within the hour, the orphan did not, so ~2.3 GB durable |

Both paths carry no BSD flags and are absent from `rootless.conf`. The two properties that looked
like they explained the Inbox's behaviour therefore explain neither, and "reclaimed by the system"
is not a property of `/Library/Developer/CoreSimulator` as a whole.

This matters beyond one directory, and the branch taken is the second of the two written here before
the probe ran: **each such path needs its own probe, and the absence of SIP markers is not evidence
either way.** The product cannot answer "root-owned regenerable data" with "tell the user to
restart" — that answer is now known to be wrong for the larger of the two paths, and `doctor` has
been corrected accordingly. Whether the privileged helper is on the critical path here is reopened,
and turns on E13b.

**Do not treat "no BSD flags + absent from `rootless.conf` ⇒ root can delete it" as sound.** It has
been falsified once here, on exactly such a path, and reasoning from it produced a `doctor`
remediation that contradicted an instruction already written in FINDINGS.

Gate: E13 — **run 2026-09-16, negative for `inc/`**: a restart does not reclaim it.

**A third mechanism then turned up by accident, and it is the one that matters for this path.** Hours
after E13, a macOS update (26.6.2/25G83 to 26.7/25G229) left the entire previous host-build cache
tree gone — 9.4 GB, the orphan included. These caches are keyed by host build, so an OS update
supersedes the whole directory. Whether the installer or CoreSimulatorService does the removal is
not established. One observation.

**Most of it then rebuilt, which is the part that bears on the product.** Within the hour the two
installed runtimes had caches on the new build at the same sizes as before (4.4G and 2.7G); the
orphan stayed at zero. So the update does not "reclaim 9.4 GB" — it reclaims the absent-runtime
share, here 2.3 GB, and the rest is a slow first boot. Do not quote the figure measured inside the
rebuild window; an early version of this note did.

So H11's reclamation story now has three answers for two paths, and none of them generalises:
restart for the Inbox, OS update for the dyld tree, and root deletion untested on both.

E13b (root deletion) is written and **lost its target on this machine** before it could run — the
directory it was pointed at no longer exists. Its refusal would still be the more interesting
outcome wherever an orphan does persist: a second path where root is blocked with no SIP flag and no
`rootless.conf` entry is worth reporting to Apple.
Evidence: F1 (2026-09-06 note), F10, `evidence/e13-dyld-reboot-20260916T{100005,155821}.txt`,
`evidence/e13b-dyld-orphan-root-delete-macos26.7-25G229-x86_64.txt`.

---

## H12 — an alternate CoreSimulator device set is a usable relocation target *(new, 2026-09-09)*

**Claim:** `~/Library/Developer/CoreSimulator/Devices` (9.1 GB here) can be relocated to external
storage via CoreSimulator's alternate device set (`simctl --set`), because it is user-owned, is not
behind the entitlement boundary that killed runtime relocation (F16), and has an explicit,
first-party indirection point rather than a symlink.

**Status: unverified, and split into two independent questions.** F1's dismissal of `--set` was
inherited from a 2022 forum thread and is now **partly falsified**: Xcode 26.5's IDE *does* have a
custom-device-set code path, selected by the `NSUserDefaults` key `DVTSimulatorSetLocation`, read in
`-[DVTiPhoneSimulatorLocator startLocating]` and feeding the same locator that populates the
run-destination picker (F17, static). So "the IDE cannot be pointed at another set" is not true as
stated. What remains open is different and sharper:

1. **Does it work on an external physical volume at all?** H6 is the threat and it is prior to
   everything else. E2 showed the restriction that breaks `xctest` bundle loading follows the
   *physical external device*, and for simulator-destination testing the `.xctest` bundle is
   installed **into the device's data container**, i.e. inside the device set. A set on a USB volume
   is therefore a direct instance of the E2 configuration, one layer in. Gate: **E14b**, phases 0–3
   (create a device in a set on the vault, boot it, launch a bundle from it). If a device cannot
   boot or an installed app cannot launch from there, H12 is dead and nothing else matters.
2. **Is it transparent?** Three clients configure the set independently: `simctl --set` (works),
   Xcode via `DVTSimulatorSetLocation` (code path proven, behaviour untested), and Simulator.app via
   its own `DeviceSetPath` (Xcode does **not** pass the set through — F17). `xcodebuild` has no
   `--set` flag at all and may not even resolve the key to `com.apple.dt.Xcode`. Gate: **E15**,
   which deliberately uses an alternate set on the *internal* disk so the transparency question is
   not entangled with (1).

**The prize is smaller than the directory size suggests, and this changes the ranking.** F18 measures
~6.5 GB of the 9.1 GB as regenerable cache, log and on-demand asset, against ~0.5 GB of real app
containers. Relocation moves ~9 GB; only ~2.6 GB of it is durable data that cleanup could not also
recover. So even a fully successful H12 is worth less than F18's cleanup, and F18 needs no new
mechanism. **Do not let a promising mechanism outrank a measured quantity.**

**Failure mode to treat as fatal, not as a bug to fix:** Xcode driving one device set while the
visible Simulator window shows another. Two independent keys, no propagation between them, and no
UI anywhere that names the active set. That is rule 6's shadow-data hazard reached through a
supported mechanism, and if E15 shows it, H12 should be falsified for a v1 *product* even if the
plumbing works for a scripted CI user.

**E14b was attempted on 2026-09-15 and produced no verdict on H12.** The script aborted at
phase 1 on a gate of its own making: it required `device_set.plist` to exist after a bare
`simctl --set <external> list devices`, and printed "H12 falsified at the cheapest gate". That
line is wrong. `device_set.plist` is materialised by the first `create`, not by a `list`, and a
control run of the identical command against an empty set on the **internal** disk produced an
equally empty directory with exit 0 and byte-identical output. The gate discriminates
empty-vs-non-empty set, not external-vs-internal, so it would have "falsified" H12 on the
internal disk too. Phase 1 has since been reduced to a labelled smoke test that gates nothing:
the obvious replacement — gating on the list's exit status — was measured and is also vacuous,
because the script creates the directory one line before asking and that command exits 0 for any
directory that exists.

**The attempt leaves no datum about this volume at all, and the first draft of this paragraph
claimed otherwise.** It said `simctl --set` had "resolved a path on the USB volume", which read
as the service accepting external storage. It did not. Measured afterwards:
`simctl --set <path> list devices` exits 1 only when the path does not exist and 0 for any
existing directory, `/tmp` included — and the script creates the directory one line before
asking. Exit 0 therefore reports that `mkdir` worked. The byte-identical output against the
internal control points the same way: output invariant to the path is output that never
consulted it. A service-level refusal of external storage, if one exists, would surface at
`create` or `boot`. **Phases 2 and 3 have still never executed, so the H6 boot gate that
decides H12 is unrun, and nothing has moved H12 in either direction.**

**Status as of 2026-09-15: FALSIFIED for external storage, with the control run and the
mechanism named.** `simctl --set <vault> create` fails; the identical command, same device type
and same runtime, succeeds in an alternate set on the internal disk and writes the 17 MB `data`
container the vault refused. Alternate device sets work as a mechanism — what does not work is
putting one on this volume. Phase 3 is moot: a device that cannot be created cannot be booted,
and H12's transparency half (E15) is moot with it for a v1 product. The scope of the
falsification is one external volume on one machine; see the removability question below, which
is now sharper rather than settled. Evidence:
`../research/evidence/e14b-device-set-external-attempt2-macos26.6.2-25G83-xcode26.5-x86_64.txt` (external failure),
`../research/evidence/e14b-control-internal-create-macos26.6.2-25G83-xcode26.5-x86_64.txt` (internal control),
`../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` (mechanism).

**2026-09-15, attempt 2 with the corrected harness: the first real gate failed.** Phase 2's
`simctl --set <vault> create` exited 22. The mechanism is **not in the run's own evidence** —
the harness captures logs only on a phase 3/4 failure, so phase 2 recorded `code=22` and nothing
else — and was read from `CoreSimulator.log` by hand afterwards, into
`../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`: CoreSimulatorService could not copy the device's sample content
into `<set>/<UDID>/data`, `NSPOSIXErrorDomain Code=1`, EPERM rather than EACCES, and tore the
half-created device down. The run's evidence does exclude one alternative on its own — the
script wrote `.xcv-e14b` into that same directory moments earlier as the same user the service
runs as, so the directory's mode bits are not the refusal. It excludes the mode bits and nothing
more: a sample-content copy also moves xattrs, ACLs, flags and ownership. The unified-log
capture is **not** empty, and unlike E2's it names the mechanism: three `tccd` queries for
`service=kTCCServiceSystemPolicyRemovableVolumes` attributed to CoreSimulatorService, then a
kernel `deny(1) file-write-create` on the set path, then the `Code=1`. Evidence
`../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

This is the shape H6 predicts, but it is **not yet H6's verdict**, and H12 is **not yet
falsified**, because two readings survive: the volume is the problem (H6), or alternate device
sets do not work this way at all — and the latter cannot be separated from "the harness is wrong
a third time" without a control.

**The control ran and settled it: reading (A).** `create` succeeded on an internal `mktemp` set,
exit 0, and produced the 17 MB `data` container whose copy failed on the vault. So the mechanism
is fine and the volume is not. That narrows the cause to *volume class* by experiment; it does not
by itself isolate removability, because the two volumes differ in case sensitivity, mount options,
bus and removability at once. What points at removability is the log rather than the design:
`tccd` was queried for `kTCCServiceSystemPolicyRemovableVolumes` about CoreSimulatorService, three
times, immediately before the kernel denied the write. That is a removability-specific policy
being consulted, which case sensitivity and mount flags do not explain. **E14c has since run and
did not isolate it** — it excluded case sensitivity, mount options and the `External`
classification, and left removability confounded with bus. It was meant to work — repeat this create against a case-sensitive APFS disk image *stored on the vault*.
E2 already established that disk images do not reproduce its failure even when the image file
itself sits on the USB SSD, so an image that permits device creation would separate removability
from case sensitivity, from path, and from the physical device holding the bytes. `scripts/experiments/e14b-control-internal-create.sh` runs the
identical create on an internal `mktemp` set and decides it. Written, not yet run. Phase 3, the
boot gate, was never reached and is now moot unless the control reads (B).

Gates: E14b control, then phase 3 if it survives, then E15. Evidence so far:
`../research/evidence/e14a-device-set-static-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
`../research/evidence/e14b-device-set-external-attempt1-void-macos26.6.2-25G83-xcode26.5-x86_64.txt`
(attempt 1, void — invalid run with an appended correction; do not cite its verdict line),
`../research/evidence/e14b-device-set-external-attempt2-macos26.6.2-25G83-xcode26.5-x86_64.txt` (attempt 2, the phase-2 failure),
`../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` (its mechanism, captured by hand — read the PROVENANCE header),
`../research/evidence/e14b-control-internal-macos26.6.2-25G83-xcode26.5-x86_64.txt`, F17, F18.

## H13 — a runtime can be *used* from an external volume without touching `images.plist` *(new, 2026-09-09)*

**Claim:** `simctl create <name> <deviceType> <path-to-.simruntime>` accepts a runtime bundle inside
an image attached from the vault, giving a device backed by external runtime bytes without writing
the database F16 showed is unwritable at any usable privilege.

**Status: unverified, and deliberately narrow.** The claim's whole basis is that Apple's own
`simctl help create` lists `"/Volumes/path/to/Runtimes/watchOS 3.2.simruntime"` as a valid
`<runtime id>` (F19), and that E4a already proved the vault image attaches and exposes
`iOS 26.5.simruntime` as a normal user. It is the only candidate found that attacks the F16 barrier
from a direction F16 does not cover — every other route needs the pointer changed.

**Expect it to fail, and say why in advance so the failure is informative.** The path form is
pre-Xcode-14 packaging; this machine has no `Profiles/Runtimes` directory at all (F10); and
`simctl runtime add` — the modern equivalent — *stages into the internal secure area by design*
(H10), which is exactly the behaviour that would make this useless even if it is accepted. The
distinguishing observation is therefore not "did the device get created" but **"did internal free
space drop by the size of the runtime"**. A creation that succeeds and copies is a falsification,
not a success.

Cheap, unprivileged, non-destructive: attach the vault image read-only, `simctl --set <scratch>
create` against the inner bundle path, measure internal free space, delete the scratch set, detach.
Runs entirely outside the default device set. Gate: **E16** (to be written; fold into E14b's harness
once E14b phase 1 has shown a scratch set works).

## H7 status update 2026-09-09 — the mechanism is documented; the delivery is the blocker

H7 was deferred as "unverified and deliberately deferred", with the sample's gaps cited as a reason.
Two things changed the picture (F20):

- Apple documents **"Building a passthrough file system"**, which "exposes an existing path as its
  own file system", with sample code and `FSPathURLResource`. `mount(8)` here documents `-F` for
  FSKit modules and `fskitd`/`fskit_agent`/`fskit_helper` are installed. The mechanism is the bind
  mount macOS never had, and it is first-party. **[APPLE-DOC]**
- **FSKit is the only remaining path that E4b/F16 does not foreclose.** F16 blocks rewriting the
  pointer in `images.plist`; a passthrough file system rewrites no pointer, it changes what a path
  resolves to. Every other relocation candidate for `/Library/Developer/CoreSimulator` needs the
  pointer changed and is therefore already dead.

Against it: third-party FSKit extensions are reported non-functional on macOS 26.1/26.2 (`fskitd`
refusing unprivileged clients, "entitlement no", reproducing on Apple's own sample; closed "not
planned" Dec 2025), and DTS has diagnosed a `fskitd` deadlock in the passthrough sample
(r.172914665). 26.6 is untested by anyone we can find. The `com.apple.developer.fskit.fsmodule`
entitlement remains required with an undocumented approval path — a business gate an open-source
project may simply not be able to pass, which is a reason to keep it out of the critical path
regardless of whether it works.

**Status: still unverified, still R&D, but promoted from "no clear mechanism" to "blocked on
platform reliability and an entitlement".** Do not schedule it against v1. Re-check on each macOS
26.x update; the check is cheap (build Apple's sample, `mount -F`).

## H14 — a mount stub reappears at a CoreSimulator cache path after its volume goes away *(2026-09-19, still unverified; E6c settled the mechanism question at `Cryptex/Caches` on 2026-09-22 and did NOT close this. A `mkdir` under `sudo` inside `/Library/Developer/CoreSimulator/` also failed that day — errno not captured, and a refusal to create a directory is not a refusal to mount one. See the end)*

**The claim.** When a filesystem mounted at `/Library/Developer/CoreSimulator/Caches/dyld`
disappears, macOS leaves or recreates a plain directory there — `root:admin 0755`, empty, and not a
mount point.

**Why it is here rather than assumed.** Issue #24 added a guard to the privileged cleanup verb on
the strength of a three-step sequence, and this is its middle step. The verb refuses while the path
is a mount point; after a disconnect it sees a plain directory, the mount query truthfully agrees,
and the old code deleted the contents as an ordinary cache. Step two has never been observed by
this project. An independent audit went looking through `docs/research/evidence/` and found nothing.

**What is measured, and is not this.** The ordinary-state ownership and mode of that path —
`755 root:admin` — is recorded in `COMPATIBILITY_MATRIX.md` on one configuration. That is the state
*before* any mount, and it is what makes the helper's guarded walk pass. It says nothing about what
happens after a volume is removed.

**Adjacent, and not a substitute.** E9 recorded CoreSimulator rebuilding a `Devices/` skeleton after
a **service restart** — different path, different trigger. `e6-software-unmount.sh` records whether
a plain `/Volumes/<name>` directory appears after a vault unmount — that is the mount-point
directory under `/Volumes`, not a cache path inside `/Library/Developer`. Neither answers this.

**What turns on the answer, stated precisely so it is not over-read.** Nothing about whether the
#24 guard is correct. If no stub reappears, the path is absent, the verb returns "nothing to do"
before it ever reads its record, and the composition #24 describes was unreachable by this route.
**This hypothesis sizes the bug, not the fix.** What it does change is whether a shipped safety
mechanism is defending against something real, and — if a stub does appear — whether its owner and
mode are what the guarded walk assumes.

**How it is proven or falsified.** `docs/process/RUNBOOK-E6b-disconnect.md`, in two variants:
a scripted software unmount (`scripts/experiments/e6b-mount-stub-reappearance.sh`) and a manual
physical yank. Both are needed — a clean `umount` is not obviously the same event as a surprise
removal, and assuming they are is the same shortcut this hypothesis exists to avoid. Blocked on
`sudo` and on hands at the machine. Tracked as issue #29.

**2026-09-21: blocked upstream. The mount cannot be staged.** The first real run refused before any
probe ran: `mount_apfs -o nobrowse /dev/diskNsM /Library/Developer/CoreSimulator/Cryptex/Caches`
returned `Operation not permitted` **to root**, exit 77. Evidence:
`evidence/e6b-mount-stub-cryptex-FAILED-macos26.7-25G229-xcode26.5-x86_64.txt`.

Measured on the target, all negative: no BSD flag (`ls -lO` shows `-`), no ACL, no
`com.apple.rootless` xattr — only a Time Machine exclusion — and no `rootless.conf` entry for
`/Library/Developer`. SIP enabled, normally. The donor is a disposable APFS sparse image with
`Owners: Disabled`. The refusal has no visible cause, which is the **same shape as E4b above**,
where root could not write `images.plist` on a `root:wheel 644` file with no flags, no ACL and no
`rootless.conf` entry, while `simdiskimaged` rewrote it freely (F16).

Two explanations fit and they lead to opposite conclusions, so the reading rule is fixed **here,
before the run**, rather than in whatever the run happens to emit:

- **(a) the PATH is protected, whatever the mechanism.** Then H14 is not merely unverified but
  *unreachable by mounting* at any privilege a product may use, and the canonical-mount strategy is
  dead at CoreSimulator paths for the same reason `images.plist` is. That is a finding, not a
  disappointment: it would mean the #24 guard defends against a state this route cannot produce.
- **(b) the MECHANISM is refused.** `mount_apfs` called directly by a non-entitled process is
  blocked and DiskArbitration is the supported route. This is live because **E1b mounted a disk
  image over a throwaway directory under `/Library/Developer` and it worked** — using
  `diskutil mount -mountPoint`, not `mount_apfs`. E6b has never used the mechanism this project
  actually proved. Then E6b can run once staging switches, and H14 is merely still open.

`scripts/experiments/e6c-mount-mechanism.sh` separates them by filling the mechanism × path
matrix. Cell D (`mount_apfs` at the cache path) is the measurement above and is not repeated.

| | throwaway dir under `/Library/Developer` | `…/CoreSimulator/Cryptex/Caches` |
|---|---|---|
| `mount_apfs` | A — pending | D — **REFUSED**, EPERM, 2026-09-21 |
| `diskutil mount nobrowse -mountPoint` | B — pending (E1b says yes) | C — pending |

**Read it as:**

- **B refuses** → the control cell failed, so the harness or the mechanism is broken and the
  matrix is **void**. Nothing may be concluded from C in that state.
- **C mounts** → (b). E6b re-runs on DiskArbitration and H14 stays open.
- **C refuses while B mounts** → (a). H14 is unreachable by this route and closes as
  sized-but-unproducible. Note the limit of that claim: two root cells license "unreachable at
  root by either mechanism", **not** "by any privilege" — Apple's own daemons mount at these
  paths, which is the F16/E4b observation the argument leans on in the first place.
- **A mounts while D refused** → the refusal is specific to the CoreSimulator path rather than to
  `mount_apfs`, which is (a) by a narrower argument.

A cell that reports REFUSED for a reason other than the mount being refused would invalidate the
matrix, and a false (a) would retire a hypothesis on the strength of an open file. The script
aborts rather than record the two causes it can detect — a donor that failed to unmount, and an
absent target — and carries the command's exit status into every REFUSED line for the rest, which
it cannot distinguish: a malformed invocation and `Operation not permitted` both leave nothing
mounted. Read the exit status before reading the cell.

### E6c, first run, 2026-09-21: one cell settled, the rest voided by the harness

Evidence: `evidence/e6c-mount-mechanism-cryptex-macos26.7-25G229-xcode26.5-x86_64.txt`.

| | throwaway dir under `/Library/Developer` | `…/CoreSimulator/Cryptex/Caches` |
|---|---|---|
| `mount_apfs -o nobrowse` | A — **MOUNTED**, exit 0 | D — **REFUSED**, EPERM, exit 77 |
| `diskutil mount nobrowse -mountPoint` | B — REFUSED, exit 1 | C — REFUSED, exit 1 |

**A and D settle one thing, and it is not small.** Same mechanism, same invocation shape
(`mount_apfs -o nobrowse /dev/disk9s1 <path>`), same privilege, same OS build, same donor device,
two paths under `/Library/Developer`: `mount_apfs` mounted at `/Library/Developer/xcv-e6c-probe`
and was refused with EPERM at the CoreSimulator cache path. **The refusal is specific to that
path, or to some property of it, and not to `mount_apfs`.** It holds regardless of the diskutil
column, because it depends on neither cell in it.

Two qualifications, both checkable and both narrowing the claim:

- **Two runs, about six hours apart**, not one session — D is E6b at `14:58:51Z`, A is E6c at
  `20:53:23Z`. An earlier draft of this paragraph said "same session, minutes apart"; that was
  wrong and is corrected rather than quietly dropped.
- **The two directories differ in more than their names.** `$PROBE` is `root:wheel`, created by
  the run; the target is `root:admin`, system-created, carrying a backup-exclude xattr. Neither
  has the `restricted` flag and `rootless.conf` has no CoreSimulator entry, so the obvious SIP
  explanation is ruled out — and the cause remains unidentified. "Specific to the path" is what
  the evidence licenses; "because CoreSimulator paths are protected" is not, yet.

**The diskutil column is VOID**, by the rule fixed above — B refused — and the cause is a defect
in the experiment rather than a fact about macOS. Three candidates, all introduced by the script:

1. **`nobrowse`.** E1b's proven call is `diskutil mount -mountPoint <dir> <dev>`, with no
   `nobrowse`. It was added during review so that cells A and B would differ only in mechanism —
   which traded one confound for a departure from the only call this project had seen work.
2. **Cell order.** `mount_apfs` ran first. A mount torn down outside DiskArbitration is a
   plausible way to leave DA unable to mount the same volume afterwards.
3. **Teardown through `umount`, not `diskutil unmount`.** E1b used `diskutil unmount`; `cell`
   used bare `umount`, which bypasses DiskArbitration. Plausible, and **unevidenced** — an
   earlier draft called it the leading suspect on the strength of the failure message reading
   `Volume  on disk9s1 failed to mount` with what looked like an emptied volume name. It is not
   emptied: `diskutil`'s template for this path is literally `Volume on %@ failed to mount`, with
   no name field at all (`strings /usr/sbin/diskutil`), and the evidence has one space, not two.
   Cell C produced the identical message with no bare `umount` before it, so the message
   discriminates nothing. Reading a fixed format string as a symptom is the error here.
4. **The donor class.** E1b used a freshly created hdiutil sparse image; E6c uses the operator's
   physical external drive. DA may decline `-mountPoint` for removable physical media.
5. **The OS build.** E1b ran on 26.6.2 (25G83); E6c on 26.7 (25G229).

Candidates 4 and 5 are not defects at all — either would be a *finding* — and the first re-run
design could not distinguish them from a broken harness, because "B1 refused" was pre-labelled
VOID. So the re-run adds **B0**: E1b replicated on its own throwaway sparse image, first, touching
neither the donor nor the cache path. B0 refused ⇒ something changed since 26.6.2, which is a
result. B0 mounted while B1 refused ⇒ it is the donor class, not the call.

The other three are addressed directly: the diskutil cells go first; teardown goes through
`diskutil unmount` and **records which mechanism won**, marking every later diskutil cell VOID if
it ever fell back outside DA; and `nobrowse` becomes its own cell (B2) beside E1b's verbatim call
(B1). Cell C keeps `nobrowse` unless B2 proves it is the obstacle — a browsable donor over a real
cache path is a manufactured shadow-data event, which is rule 6 and not worth trading for tidiness.

A note on "we reused the proven extraction", because that inference is what made the first B0
look safe. E1b resolves its image's device with a plist filter on `e.get("content")`, falling back
to a `diskutil list` name match. Checked against live `hdiutil info -plist` on 2026-09-21: every
`system-entities` entry carries exactly `content-hint` and `dev-entry`, and `content` is `None`
for all of them. **E1b's plist path has never produced anything**; E1b passed through its
fallback, every time. B0's first draft copied the plist expression and inherited a silent no-op,
which would have left its image attached while cleanup deleted the backing file. Both are
corrected to `content-hint`, and B0's volume now carries a per-run name so a leftover image from
a failed detach cannot be matched by the next run and reported as a refusal.

Since `diskutil`'s other template is `Volume on %@ failed to mount: "%@"` and the run got the bare
form, DA returned no detail string at all — so each diskutil cell now also captures
`log show --predicate 'process == "diskarbitrationd"'`, which is the only place a reason exists.

Recorded rather than quietly re-run because the void is the interesting part: the reading rule
fixed before the run is what stopped a REFUSED cell C — obtained through a broken control — from
being read as "the path is protected" and closing H14.

### E6c, second run, 2026-09-21: the question splits in two, and neither half is the one asked

Evidence: `evidence/e6c-mount-mechanism-cryptex-macos26.7-25G229-xcode26.5-x86_64.txt`.

| cell | mechanism | volume | destination | result |
|---|---|---|---|---|
| A | `mount_apfs` | donor | probe | **MOUNTED** |
| D | `mount_apfs` | donor | cache path | REFUSED, EPERM (prior run) |
| B0 | `diskutil mount -mountPoint` | fresh image | probe | **MOUNTED** |
| B1 | `diskutil mount -mountPoint` | donor | probe | REFUSED, exit 1 |
| B2 | `diskutil … nobrowse` | donor | probe | REFUSED, exit 1 |
| C | `diskutil mount -mountPoint` | donor | cache path | **VOID** — its control, B1, refused |

**Two refusals, and they are not the same refusal.**

- **`mount_apfs` is refused by the PATH.** A and D are the same mechanism, the same volume, the
  same privilege: it mounts at `/Library/Developer/xcv-e6c-probe` and returns EPERM at
  `…/CoreSimulator/Cryptex/Caches`.
- **DiskArbitration is refused for this volume WHEN A CUSTOM MOUNT POINT IS REQUESTED.** B0 and
  B1 are the same mechanism and the same destination: a freshly created sparse image mounts, the
  donor does not.

  An earlier draft of this line read "refused by the VOLUME", and **the same evidence file
  falsifies that** — a fourth DA data point nobody counted. After B1, B2 and C had all refused,
  `shadow_check` ran a PLAIN `diskutil mount "$XCV_DONOR_UUID"`, with no `-mountPoint`, and it
  succeeded: line 154's "donor root listing unchanged" branch is reachable only when the donor
  came back, and no "came back at X, not Y" note printed, so it came back where it started. DA
  takes that volume. What it declines is that volume at a mount point of our choosing.

  This also narrows the mount-history candidate below: the donor had a prior mount in this same
  session and DA accepted it anyway, so only the conjunction "custom mount point AND prior
  mount" survives. The run was performing the decisive measurement in its cleanup and not
  recording it as one; cell B3 now records it. The reason is in the
  log this run was taught to capture — `diskarbitrationd`: `unable to mount /dev/disk9s1
  (status code 0x0000004D)`.

  On that status code, carefully, because an earlier draft of this paragraph decoded it and the
  decoding was invention: 0x4D is 77, which is also the number `mount_apfs` exited with at the
  cache path. 77 is `EX_NOPERM` in `sysexits.h` and `ENOLCK` in `errno.h`, and DiskArbitration's
  status codes are documented as neither. **It is an unexplained numeric coincidence across two
  namespaces, recorded for the next run and carrying no weight in the argument below** — if
  anything it cuts against it, since a shared code is weak evidence that two refusals are the
  same, in a section arguing they differ.

So C is void by the rule, and correctly: the only volume DiskArbitration has agreed to mount is
B0's, and B0 never went near the cache path. **Nothing yet says whether DiskArbitration can
reach it.** What distinguishes the donor from B0's image is **not yet established**, and an
earlier draft of this paragraph ruled out one candidate on a premise that is in neither the
evidence nor the script: it asserted both were APFS sparse images, while the script's own header
frames the donor as the operator's physical external drive and names media class a live
candidate. The evidence records `owners on donor: Disabled` and nothing about B0's. Two
candidates remain:

- **mount history, in conjunction with a custom mount point** — the donor was mounted under
  `/Volumes` and unmounted by this run; B0's image was attached `-nomount` and had never been
  mounted anywhere. Bare history is already ruled out by the cleanup remount above;
- **media class** — whether DA declines `-mountPoint` for the kind of device the donor is.

The next run records `Protocol`, `Device Location`, `Removable Media`, `Owners` and `Virtual`
for both volumes, so the next reading of B1 rests on something. And cell E0 below settles the
first candidate directly.

**Cells E0 and E are the decisive ones and are now in the script.** E is B0's own image — the
volume DA has just accepted — at the real cache target. But B0 cannot be its only control:
**running B0 is what destroys E's freshness.** By the time E runs, that image has itself been
mounted and unmounted in this session, which is precisely the property the mount-history
candidate attributes B1's refusal to, so an `E REFUSED` would be confounded between "the path
refuses DA" and "DA refuses a volume with a prior mount". E0 — the same image, at the same
probe, a second time — separates them:

- **E0 REFUSED** → a second `-mountPoint` mount of the same volume is refused. E is **not run**
  (not void — void means it ran and its control failed). This makes mount history a live
  explanation for B1; it does not establish one, because B1 is a different volume of a different
  media class.
- **E0 AND E0b MOUNTED, E REFUSED** → history is ruled out *at E's own mount depth*, and both
  mechanisms refuse the cache path using a volume each has accepted elsewhere. The strongest
  form of (a) available here; H14 closes as unreachable by this route.

  **E0 alone is not enough, and that is the second time this experiment's control was one step
  short.** E0 is the image's second mount; E is its third attempt. Any refusal rule monotone in
  mount depth — the obvious shape for cached or leaked DA state, which is exactly what the
  history candidate posits — yields `E0 MOUNTED, E REFUSED` with the path playing no part at
  all. **E0b** repeats the probe mount *after* E, so it attempts at precisely E's depth.

### E6c, third run, 2026-09-22: a real result at one path, and a closure I wrote and retracted

Evidence: `evidence/e6c-mount-mechanism-cryptex-macos26.7-25G229-xcode26.5-x86_64.txt`, with the
two earlier runs kept beside it as `-superseded-20260921T203611` and `-superseded-20260921T211656`.

| cell | mechanism | volume | destination | result |
|---|---|---|---|---|
| A | `mount_apfs` | donor | probe | MOUNTED |
| D | `mount_apfs` | donor | cache path | REFUSED (EPERM, exit 77 — 2026-09-21) |
| B0 | `diskutil -mountPoint` | fresh image | probe | MOUNTED |
| E0 | `diskutil -mountPoint` | same image, 2nd mount | probe | MOUNTED |
| E | `diskutil -mountPoint` | same image | cache path | REFUSED (exit 1) |
| E0b | `diskutil -mountPoint` | same image, after E | probe | MOUNTED |
| B1 | `diskutil -mountPoint` | donor | probe | REFUSED |
| B2 | `diskutil … nobrowse` | donor | probe | REFUSED |
| B3 | `diskutil`, **no** `-mountPoint` | donor | DA's own choice | MOUNTED |
| C | `diskutil -mountPoint` | donor | cache path | REFUSED (void: control B1) |

**What is established.**

- **`mount_apfs` is refused at `/Library/Developer/CoreSimulator/Cryptex/Caches` and not at a
  throwaway directory one level up.** A and D are the same mechanism and the same volume. This
  is the firm result of the whole series.
- **Neither mount history nor mount depth explains the diskutil column.** E0 mounted the image
  immediately before E and E0b immediately after, both at the probe. That pair does what it was
  built to do.
- **DiskArbitration accepts the donor** — B3 mounted it with no `-mountPoint`. What it declines
  is that volume at a mount point of our choosing, and the device-class line shows donor and
  image are the same class (`Protocol=Disk Image, Device Location=External, Removable Media=
  Removable, Owners=Disabled`), so media class does not explain B1 either. B1 stays unexplained
  and no longer blocks anything.

**What I wrote and then had to take back.** I closed H14 on this run. Two reasons that was
wrong, both found in review:

1. **The decisive cell's refusal is invisible to the instrument added to explain it.** Cells B1
   and B2 each captured their own `diskarbitrationd` failure with `status code 0x0000004D`.
   Cells **E and C captured none** — their log blocks contain only the earlier cells' events
   replayed by the 60-second window. Not truncation (`tail` keeps the newest lines), not the
   filter (E's own device appears in that same block for B0 and E0). The straightforward
   reading is that E's request never reached `diskarbitrationd` — rejected client-side by
   diskutil or the framework. So "both mechanisms refuse that path" is **not supported**:
   `mount_apfs` is refused by the kernel with EPERM; `diskutil` exits 1 with no evidence a mount
   was attempted at all. That is precisely the invalidation condition fixed above — "a cell that
   reports REFUSED for a reason other than the mount being refused would invalidate the matrix".
2. **Every cell used `Cryptex/Caches`; H14 is about `Caches/dyld`.** `common.sh` says the
   substitution is not free, in as many words, and the reason bites here: `Cryptex/` is where
   `simdiskimaged` attaches signed runtime cryptexes, so a protection specific to that subsystem
   is the most plausible unexamined cause — and it would not generalise to an ordinary
   root-owned regenerable cache. **`dyld` has never been attempted, by either mechanism.**

A third gap, smaller but in the same direction: **the target's emptiness was never recorded in
this run.** The script enforces and records it for the probe and not for the target; the only
measurement is from a different run a day earlier. A non-empty mount point is a textbook
DiskArbitration refusal and would produce exactly diskutil's bare failure template.

**Two overstatements corrected in place.** "Using a volume each has just accepted elsewhere" is
true of diskutil and false of `mount_apfs`: D is 2026-09-21T14:58:51Z and A is
2026-09-22T09:05:44Z — about eighteen hours and a different session apart, and A came after D.
And E0b is the image's *fourth* attempt, one deeper than E rather than at E's exact depth; the
inference against a monotone-in-depth rule survives a fortiori, but the sentence claimed
precision it did not have.

### E6c, fourth run, 2026-09-22: the errno arrives, and the third run's weakest claim gets stronger

Evidence: `docs/research/evidence/e6c-mount-mechanism-cryptex-macos26.7-25G229-xcode26.5-x86_64.txt`
(three `-superseded-` predecessors sit beside it). The matrix reproduces exactly — B0, E0, E0b, B3
and A MOUNTED; E, B1, B2 and C REFUSED; C VOID again because B1 refused; same cell order, same
donor state.

**H0, with an artifact this time.** `mkdir -p /Library/Developer/CoreSimulator/xcv-e6c-hprobe`
under `sudo` was refused, **reported as `Operation not permitted`** (the run records `strerror`,
not the numeral; `EPERM` is the safe inference on Darwin and is an inference). That is the
measurement the aborting run destroyed and the one its write-up asserted without having: root —
the header records `Runner: root (uid 0)` — at the top level of the hierarchy, macOS 26.7, one
machine. The `Caches/` and `Cryptex/` rows in the table above are still non-root, and this is
still a result about creating a directory, not about mounting one.

**The target was empty at run start.** `cache target: /Library/Developer/CoreSimulator/Cryptex/Caches
(entries: 0)`, recorded by the run rather than inferred from a different day, so a non-empty mount
point — the textbook DiskArbitration refusal, and the obvious explanation for diskutil's bare
failure template — is excluded. Partially at cell time: the re-checks before E and before C report
`links=2`, which excludes child *directories* and not regular files.

**Cell E's cache-path refusal leaves no record of its own, and that reproduces.** I first read this run as falsifying the third run's version of the claim, because C's log
block carries two `unable to mount … (status code 0x0000004D)` lines. It does not. **C's
`diskarbitrationd` block is byte-identical to B2's**, and both `0x4D` lines are timestamped before
C ran — `10:24:42.109` is B1's own failure and `10:24:44.276` is B2's, both at the *control
directory*. Nothing after `44.276` appears in C's window at all. The harness explains it:
`log show --last 60s` runs *after* the cell with no start sentinel, so every refused cell replays
its predecessors. The third run shows the same shape, its C block byte-identical to its B2 block.

So the honest statement is the third run's, upgraded rather than retracted:

- **Control-directory cells produce a DA solicitation and a `0x0000004D` failure** (B1, B2).
- **Cell E's cache-path attempt adds no record to its own window.** Note the property carefully:
  it is *attribution*, not naming. E's window holds 35 records naming `disk11s1` — including the
  dissent discussed below — and the finding is that **nothing appears after E0's teardown at
  `10:24:37.478`**, so every line present is attributable to B0, E0 or attach time. E is what the
  claim rests on, because E has a working control in the same run. C is *consistent* with it and is
  **void**: reading C is the mistake recorded below. Reproduced for E in runs 3 and 4 (both
  2026-09-22); C's own-window emptiness reproduces in runs 2, 3 and 4 (2026-09-21 and 2026-09-22 —
  run 1 predates the per-cell capture entirely and has no `diskarbitrationd` block at all, its
  cells being A, B and C with no B1/B2 split). The refusal is not shown to be a mount refusal; it may be a client-side rejection
  before the request reaches `diskarbitrationd`.

**Cell E contributed nothing to its own window either.** It holds two complete
`mounted disk … success` / `unmounted disk … success` cycles for E's device, and there are exactly
two prior successful cells on that device — B0 and E0. The cycles are theirs. E left no trace, and
the absence is the finding.

**The one line in E's window that looks like an answer.** `dispatched response, kind = disk mount
approval, disk = /dev/disk11s1, dissented, status = 0xF8DA000A` — `kDAReturnNotReady`, per
`DADissenter.h` in the installed SDK. It is not E's refusal, and the reason matters, because my
first reason was wrong. Not "it precedes E's solicitation by 600 ms": the solicitation 600 ms
later is *B0's*, and E has no solicitation for anything to precede. The reason is the timestamps: the dissent at `35.294`
precedes even B0's own cycle, let alone E's, and it sits 5 ms after
`diskimages-helper … kind = disk claim` / `claimed disk … success`, where an attach-time
auto-mount approval belongs. It reproduces at that same position in the third run, 4 ms after its
own claim. Two runs, attach-time, before any cell.

**What C's VOID does and does not permit.** A log record is an observation and a verdict is an
inference, so in principle a void cell's log can still be read. That distinction did not apply
here and reaching for it is how the mistake above happened: the records imported into C were B1's
and B2's — the control-directory failures whose refusal is precisely what voided C. The run's own
pre-registered rule says it plainly: *"this DONOR is what diskutil will not take. Not a statement
about the cache path. Do not read C."*

**Three things in this run's evidence worth more than the headline.**

1. **The kernel takes the donor at the control directory where DiskArbitration will not.**
   `mount_apfs -o nobrowse /dev/disk9s1 /Library/Developer/xcv-e6c-probe` MOUNTED (cell A) at the
   same directory, on the same donor, in the same session where `diskutil mount -mountPoint` was
   refused twice (B1, B2). A clean mechanism split. It also narrows one tempting
   reading: `mount_apfs` invoked *directly* accepts the donor at that directory, so `0x0000004D`
   is not an unconditional property of that donor-plus-directory. It does not foreclose the code
   originating inside DA's own mount — a different invocation in a different context, and the
   resulting flags differ (`local, journaled, nobrowse` for A against `local, nodev, nosuid,
   journaled, noowners` for the DA mounts).
2. **`noowners` is excluded as the donor-versus-image differentiator.** The donor reports
   `owners on donor: Disabled` and mounts `noowners` — but B0's accepted image mounts `noowners`
   too. The control is in the file and was never stated.
3. **DiskArbitration does not refuse the donor "everywhere".** B3 — `diskutil mount` with no
   `-mountPoint` — MOUNTED the donor at DA's own choice of location. DA declines that volume at
   *any mount point we choose*, which is a narrower and stranger claim.

**The pre-registered rule that fired and was not honoured, for the second time.** `E REFUSED, E0
AND E0b BOTH MOUNTED` is written in the legend as closing H14. It fired again. It is again not
honoured, for the reason recorded at the third run: every cell used `Cryptex/Caches` and H14 is
about `Caches/dyld`. Noted here so the next reader does not re-trip it.

**The harness defect this exposes, and the fix, which landed with this write-up.** A rolling
`log show --last 60s` taken after the cell cannot attribute anything to the cell. Two readings have
now died on it. `cell()` now captures a wall-clock timestamp *before* the command and passes
`log show --start`; a `logger` sentinel would be more precise still, but `log show --start` takes
only a wall-clock string, so "monotonic" was never available through this interface. Three limits
survive and are printed in every report — one-second granularity (widens the window, the safe
direction), a backward clock step (drops the cell's own events), and the store's own lag. And the
bound is on event timestamps rather than causality, so an asynchronously emitted record from the
previous cell's teardown still lands here; only pairing records to their solicitation `id` fixes
that, and a sentinel would not.

**Read the fourth run's blocks with that in mind: they predate the fix.** Their own headers say
`## diskarbitrationd, last 60s`. Every log claim in this section rests on the unattributable form,
which is why C's identity with B2's had to be established by diffing the blocks rather than by
trusting either. **No per-cell log claim in any E6c evidence file written before this change is
safe without that diff.**

**Gate: E6c is closed for `Cryptex/Caches`. H14 is NOT closed, and issue #29 stays open.**
What remains, in order:

1. `Caches/dyld`, both mechanisms — H14's own path and the #24 guard's path. **Attempted
   2026-09-22 and refused by the harness's own guard**: the path holds 7.1 GB (one entry,
   `25G229`, the current build's cache), and mounting over a non-empty directory would hide it.
   That refusal is correct and it is also a finding about testability — H14's own path cannot be
   probed by mounting while the cache is populated, which is its normal state. Reaching it needs
   the cache cleared first, at the cost of a rebuild on this machine's shared simulators, and
   that is the operator's call rather than an experiment's. Note what it does *not* mean: the
   product's own relocation flow would empty the path before mounting, so the scenario is not
   unreachable in principle — only untestable without paying that cost. `Cryptex/Caches` was
   chosen originally for exactly this reason: it was empty. **Re-priced 2026-09-22:** clearing it
   also supplies the in-hierarchy control of item 2, because `Caches/dyld` is the only empty-able
   directory inside the hierarchy that the mount allowlist permits. Two answers for one clearing —
   **with the two limits item 2 states**: the contrast still needs a valid `cryptex` run, and a
   daemon-owned cache is a weaker control than the neutral directory the cell wanted.
2. A matched control *inside* the hierarchy — **narrowed on 2026-09-22, not answered.** Cells
   H1/H2 were to mount at a run-created empty directory under
   `/Library/Developer/CoreSimulator/`, separating "this directory refuses" from "this hierarchy
   refuses". **The run-created form of that control cannot be built on this machine**: the
   operator's `sudo` run of E6c stopped at its own guard, unable to
   `mkdir -p /Library/Developer/CoreSimulator/xcv-e6c-hprobe` (the `-p` matters: it is why a
   missing parent cannot be the explanation).

   **What that observation is, exactly.** It is one `sudo` run, on one machine, macOS 26.7 — and
   **its errno was not captured.** The pre-change script wrote `mkdir`'s stderr into `$REPORT`
   and then `exit 1` without setting `XCV_RUN_FAILED`, so cleanup deleted the report; the only
   surviving output is `!! could not create …` on the terminal. That establishes *failure* and
   not *`EPERM`*. E6c now records the error text as cell **H0** and continues the run, so the
   next machine to meet this produces the artifact this one destroyed.

   Separately, four `mkdir` probes **run as `pirado`, not root**:

   | path | errno (non-root) |
   |---|---|
   | `/Library/Developer/` | `EACCES` — Permission denied |
   | `/Library/Developer/CoreSimulator/` | `EPERM` — Operation not permitted |
   | `/Library/Developer/CoreSimulator/Caches/` | `EPERM` |
   | `/Library/Developer/CoreSimulator/Cryptex/` | `EPERM` |

   `/Library/Developer/` refuses a non-root user the way any `root:wheel drwxr-xr-x` directory
   does, and yields to `sudo` — which is why the out-of-hierarchy probe has mounted in every run.
   Everything below `/Library/Developer/CoreSimulator/` refuses with `EPERM`. (The table records
   errno and nothing else — no mode or owner column, so it cannot say the permissions match.) That contrast is real and it is a non-root
   measurement; it does not carry to root by itself, and the root run that would have joined the
   two is the one whose errno was lost.

   **And it is a result about `mkdir`, not about mounting.** Cell D was refused at
   `…/Cryptex/Caches`, a directory that already existed — no `mkdir` was involved, so H0 does not
   explain D even if the two share an errno class. The question this item was opened for is
   therefore still open, and cheap **if a pre-existing empty directory other than `$TARGET` can be
   found** inside `/Library/Developer/CoreSimulator/` — run H1/H2 against that. Using
   `Cryptex/Caches`, the only one this series has established as empty, collapses H1 into D. That cell is not written. Directory creation and
   mounting being refused by the same mechanism is a hypothesis the observation suggests and does
   not test.

   **2026-09-22, later: the blocker is not the directory, it is the allowlist — and that collapses
   this item into item 1.** I went looking for a pre-existing empty directory in the hierarchy.
   Seven exist. Five are `drwxr-xr-x root:admin`, the same mode and owner as the target; the last
   two only appeared that way, and why is the point of the correction below:

   | path | what it is |
   |---|---|
   | `Cryptex/Caches` | the target itself (item already measured) |
   | `Cryptex/Images/bundle`, `Cryptex/Images/Inbox`, `Cryptex/Images/mnt` | CoreSimulator cryptex image staging |
   | `Images/Inbox`, `Images/mnt` | CoreSimulator image staging |
   | `Volumes/iOS_23F77`, `Volumes/watchOS_23T570` | **not candidates at all — live runtime mount points; see below** |

   So the cell is constructible and I am still not writing it, for a reason that is worth more than
   the cell. **And the last two rows are a measurement error worth keeping visible.** I enumerated
   them as empty and `root:admin`, like the others. Re-checked hours later they hold one entry each
   and read `root:wheel`, because by then they were mounted:

   ```
   /dev/disk5s1 on /Library/Developer/CoreSimulator/Volumes/iOS_23F77      (apfs, sealed, read-only, nobrowse)
   /dev/disk7s1 on /Library/Developer/CoreSimulator/Volumes/watchOS_23T570 (apfs, sealed, read-only, nobrowse)
   ```

   Both readings were correct when taken; runtime cryptexes mount on demand. `simctl runtime list -j`
   settles the identity authoritatively rather than by a build-number coincidence — its `mountPath`
   for `SimRuntime.iOS-26-5` (23F77) and `SimRuntime.watchOS-26-5` (23T570), both *Ready*, is
   exactly those two paths. **So inside this hierarchy "empty" is the signature of an *unmounted*
   runtime mount point, and emptiness can never be the candidate test.** The refusal is harder than
   rule 6's shadow data, too: a donor there would stack a filesystem over a Ready runtime the test
   rigs need, and a cleanup force-unmount would then tear down Apple's own mount. And the other five fail a narrower test:
   **`xcv_e6b_target`'s closed set mirrors `HelperCleanupTarget`** — `coreSimulatorDyldCache` and
   `cryptexCaches`, two regenerable caches — precisely so an experiment cannot stage a mount over
   anything the product would not itself clean. None of the five is such a path. Adding one would
   dissolve the invariant the allowlist exists for, to answer a question that has a compliant route.

   **The only compliant route is `Caches/dyld`, which is item 1** — inside the hierarchy, inside
   the allowlist, and H14's own path. It is worth more than one answer, and less than I first wrote:

   - **The contrast needs a second valid cell, which does not yet exist.** The other in-hierarchy
     result is `Cryptex/Caches`, whose diskutil verdict is **VOID** in runs 2 through 4 and whose
     `mount_apfs` cell D is not measured at the other target. A dyld run gives one in-hierarchy
     result, not a pair. The missing half is a valid `cryptex` run on the fixed harness — cheap,
     since cryptex needs no clearing, but not nothing.
   - **`Caches/dyld` is a weaker control than the cell it stands in for.** H1/H2 wanted a
     run-created *neutral* directory, so that location was the only variable. Both cache paths are
     CoreSimulator daemon-owned, and `common.sh` warns in as many words that behaviour here "can
     depend on which daemon owns the path". A refusal at both is equally consistent with "the
     hierarchy refuses" and with "daemon-owned CoreSimulator cache paths refuse". The substitution
     narrows what the cell can conclude; it does not preserve the question.

   So clearing the cache still buys more than it looked like — H14's own path plus one half of the
   hierarchy contrast — at the same cost, which remains the operator's call.

   **A narrowing that cost nothing and was available the whole time.** "The hierarchy refuses"
   has to mean some OS-level policy attaches to it. Four runs recorded `stat -f`, which has no
   flags field. `ls -lO` does: **no ancestor carries `restricted`** — `/Library/Developer`,
   `CoreSimulator`, `Cryptex` and `Caches` all show `-`, with only an xattr on `Caches` — and
   `rootless.conf` names `/System/Developer`, not `/Library/Developer`. **SIP path policy is
   therefore excluded as the mechanism for the mount refusals and for H0's `mkdir` refusal alike.**
   E1 and E13b already recorded these two checks; E6c did not, and now does, in its header so an
   aborted run still carries them.

3. ~~Record `$TARGET`'s entry count, and guard it as the probe is guarded.~~ **Done**: the count is
   in the header (`entries: 0` on 2026-09-22) and the flags/rootless checks above sit beside it.
   What remains at this number is the narrower question those checks opened — **which mechanism does
   return the refusals, now that SIP path policy is excluded.**
4. Why diskutil produces no DiskArbitration record at the cache path — **reproduced**: for E in
   runs 3 and 4 (both 2026-09-22), and for C, whose verdict is void, in runs 2 through 4. So it is
   not an artefact of one run. A direct
   `DADiskMountWithArguments` would say whether the API refuses or diskutil does.
5. The physical-yank variant, which H14 insists on and which none of this touches.

The guard added by issue #24 should stay. Note the reason precisely, because the tempting one is
wrong: it is not that the state cannot exist — `simdiskimaged` mounts under that hierarchy in
normal operation — but that *we* cannot manufacture it with the mechanisms a product may use.

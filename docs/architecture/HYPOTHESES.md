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
| `Caches/dyld/<build>/inc/` (F10) | untested — E13b, and it lost its target | **does nothing** (E13, 2026-09-16, byte-identical across two restarts) — but a macOS **update** removed the whole host-build tree hours later, 9.4 GB, same day |

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

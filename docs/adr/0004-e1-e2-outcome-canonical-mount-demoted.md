# ADR 0004: After E1/E2, canonical APFS mount is demoted to R&D; v1 is accounting, official mechanisms, cleanup, and disconnect safety

- Status: accepted
- Date: 2026-09-06
- Related hypotheses: H1, H6, H8, H10

## Context

ADR-0002 kept canonical mount as a *gated* Tier 2 headline pending E1 and E2. Both ran on
2026-09-06 (macOS 26.6.2 / Xcode 26.5 / Intel; evidence in `docs/research/evidence/`):

1. **E1:** `/Library/Developer/CoreSimulator` is not SIP-protected — but on Xcode 26.5 there
   is nothing under it worth mounting over. `Cryptex/Images/bundle` is empty; **all 15.8 GB of
   installed runtime images live in `/System/Library/AssetsV2/…MobileAsset_*SimulatorRuntime`**
   as `Patchable Cryptex Disk Image`s that `simdiskimaged` attaches into `Volumes/`. The only
   regular storage under the path is `Caches/dyld` (7.4 GB), which is regenerable and therefore
   a cleanup target, not a relocation target.
2. **E2:** the "xctest cannot load a test bundle from an external volume" failure reproduced
   verbatim on a physical USB SSD and **follows the device, not the path**: an internal symlink
   into the same volume fails identically, while disk images pass at `/Volumes` and at `$HOME`
   paths alike. A canonical mount of an external device would therefore inherit the restriction.

Together these remove both arguments that made canonical mount interesting: it would capture
neither the runtime bytes nor any test-execution advantage for DerivedData.

## Decision

- **Canonical APFS mount moves to the R&D track** alongside FSKit (ADR-0002 Tier 3). It stays
  defined in the catalog as `canonicalMount` for completeness, is never surfaced as an action
  in v1, and is not built until an Apple-supported way to place runtime images elsewhere
  exists (H10) or a concrete, measured user benefit appears for the small remaining scope.
- **v1 scope is fixed to:** (M1) honest accounting including the MobileAsset store and every
  path the competition misses; (M2) Apple's supported mechanisms end-to-end — Locations,
  the external Runtime Library via `-exportPath`/`-importPlatform`, `simctl runtime delete`
  (with `--keep-asset` awareness), `-prepareDeviceSupport`, regenerable-data cleanup; (M3)
  disconnect safety, the migration journal and `doctor`; (M4) GUI; (M5) release.
- **Disclose-don't-bury stays mandatory:** every path that places DerivedData or build
  products on a physical external volume shows the E2 warning before acting.
- **E4/E6/E7 (byte-identical runtime relocation, surprise removal, shadow-data defense) are
  no longer gating for v1.** They remain valuable for M3's cold-storage and Runtime Library
  volumes and will be run as part of that milestone's fault-injection work, on scratch disk
  images first.

## Consequences

- No privileged mount verbs in the helper for v1. The helper's allowlist shrinks to: cleanup of
  approved root-owned regenerable paths (`CoreSimulator/Caches/dyld`, stranded Inbox
  downloads), running `simctl runtime delete`/`xcodebuild -importPlatform` as root where
  needed, and ownership repair on the app's own external directory. Smaller attack surface.
- The product's honest pitch changes from "mount your runtimes externally" to "know exactly
  what Xcode consumes, keep installers and cold data external, delete only what regenerates,
  and never lose data when the drive is unplugged." That is still a category no tool occupies.
- If a future Xcode moves runtime storage back under `/Library/Developer` (as Xcode 14–15 did
  with `Cryptex/Images/bundle`), re-run E1's size accounting — the scanner reports per-path
  bytes precisely so this is a one-command check — and revisit.

## Evidence

`docs/research/evidence/e1-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
`docs/research/evidence/e2-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
`docs/research/FINDINGS-2026-09-05.md` §"Corrections … 2026-09-06",
`docs/architecture/COMPATIBILITY_MATRIX.md` entries E1/E2/E8.

## Addendum 2026-09-09 — E4b closes the question upstream of the reasoning above

This ADR demoted canonical mount because H6 showed the sandbox restriction that breaks `xctest`
classifies by device removability rather than path, so mounting an external volume at a canonical
location buys nothing. That reasoning stands, but it is no longer the binding constraint.

E4b found an earlier one. `/Library/Developer/CoreSimulator/Images/images.plist` — the database that
records where each runtime image lives — **cannot be written by root**: `Operation not permitted` on
an existing `root:wheel 644` file, no BSD flags, no ACL, absent from `rootless.conf`, while
simdiskimaged rewrites it freely (F16). A runtime therefore cannot be pointed at an external image
at any privilege level a product may use, and the question never reaches H6.

Nothing in the decision changes; its footing does. "Canonical mount buys nothing" becomes "the
relocation cannot be effected at all", which is a stronger and more durable reason. R&D on this
track should now start by asking whether that entitlement boundary has any legitimate opening —
`simctl runtime add` is the only one found so far, and it stages into the internal area by design.

Two things worth keeping from the same work: a byte-identical runtime image on an external APFS
volume **does** keep a verifying seal (E4a), so the barrier is authorization rather than integrity;
and the Runtime Library workflow (H4/E8) is not the pragmatic compromise it looked like when this
ADR was written — it is the only door the system leaves open.

## Addendum 2026-09-15 — the alternate device set is closed too, and H6 finally has a name

E14b and its control settle the last candidate that could have moved CoreSimulator device storage
to external media. `simctl --set <vault> create` fails: CoreSimulatorService allocates the device,
cannot write its `<UDID>/data` container, and tears it down. The identical command — same device
type, same runtime — succeeds in an alternate set on the internal disk and writes that container at
17 MB. So the indirection works and the volume is the variable. **H12 is falsified for external
storage**, its boot gate is unreachable, and E15's transparency question stops gating anything a v1
product decides.

This confirms the ADR rather than reversing it. The decision already put supported Apple mechanisms
and disconnect safety first and left everything else in the R&D tier; one more R&D candidate has now
been tested and closed, which is what that tier is for. No product behaviour changes.

What is new, and worth more than the closure, is that the mechanism finally has a name. E2 reached
the same class of failure and its matrix entry still reads "mechanism unnamed" after querying the
same subsystems. Here the unified log shows `tccd` queried three times for
`service=kTCCServiceSystemPolicyRemovableVolumes` about CoreSimulatorService, then the kernel
logging `deny(1) file-write-create` on the set path, then the EPERM — in eighty milliseconds, on a
code path with no `xctest` anywhere in it. That is a second independent reproduction of H6's shape
in a different subsystem, and the first time a removable-volumes policy has been observed being
consulted.

H6 stays **probable**, not verified: still one physical device, one machine. The control narrows
the cause to volume class by experiment; the TCC line is what points specifically at removability,
and it arrived from the log rather than from the design. E14c was expected to isolate it; it ran
the same day and did not — see the 2026-09-15 (later) addendum below. The prediction is kept as
written rather than edited. It read: E14c would isolate it — repeat the create
inside a case-sensitive APFS disk image stored on the vault, since E2 already showed disk images do
not reproduce its failure even with the image file on the USB SSD. If device creation works there,
removability is separated from case sensitivity, from path, and from the physical device holding
the bytes.

The user-facing consequence is unchanged but now better supported: the product warns before placing
developer storage on external media, and it cannot offer to move the device set there at all.


## Addendum 2026-09-15 (later) — E14c ran, and narrowed rather than isolated

The prediction in the addendum above was wrong in its strength, and correcting it in place would
have hidden what the prediction was. E14c ran twice. A case-sensitive APFS disk image whose file
sits on the vault hosts a device the vault itself refuses, with case sensitivity, `Device
Location=External`, mount options, the `/Volumes` path class and the physical SSD all held at the
vault's values.

What it bought: case sensitivity, mount options, the `External` classification and the medium
holding the bytes are all excluded as the discriminator. What survives is `Protocol` — a real
device against a virtual one.

What it did **not** buy, and the reason H6 stays *probable*: **every external volume this project
has tested is USB**, so removability and bus have never been separated, and replacing a real device
with a virtual one changes both at once. That needs a Thunderbolt or NVMe enclosure (E14d), which
the project does not own.

One wording consequence for the product: H6's mechanism clause should say "a real external device"
rather than "removability". The measurement has excluded the DiskArbitration field that the word
names — E14b's log shows TCC querying `kTCCServiceSystemPolicyRemovableVolumes` about a volume
`diskutil` labels `Removable Media: Fixed` — so "removability" now means something narrower than it
sounds, and writing it plainly costs nothing.

No product behaviour changes. The warning before placing developer storage on external media, and
the absence of any offer to move the device set there, both stand on E14b alone.

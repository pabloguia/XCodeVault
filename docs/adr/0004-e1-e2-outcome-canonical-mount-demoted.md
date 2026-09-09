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

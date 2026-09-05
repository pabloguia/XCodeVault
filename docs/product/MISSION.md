# Mission

## Problem

Xcode and Apple developer tooling consume tens to hundreds of GB of internal SSD
through Simulator runtimes, CoreSimulator data, DerivedData, indexes, build products,
Archives, device support/symbols, DeveloperDiskImage/CoreDevice data, SPM caches,
logs, previews, doc caches, downloadable platform components, and more.

## Goal

Transparently externalize every storage category that can be *safely* externalized;
use official Xcode/macOS configuration mechanisms first; provide managed cold storage
and cleanup where relocation isn't appropriate; clearly label Apple-managed or
non-relocatable data that must stay local. The user should be able to keep using
Xcode, Simulator, xcodebuild, simctl, devicectl, and third-party tools normally.

## Explicit non-goal

We do **not** assume every byte can or should move. A category with no verified-safe
strategy stays local and is reported honestly, not force-fit into a risky strategy to
maximize reclaimed space. See `NON_GOALS_AND_SAFETY.md`.

## Target users

Individual iOS/macOS developers and teams whose internal SSD is squeezed by Xcode,
including those running multiple Xcode versions side by side, working across
Intel/Apple Silicon, and/or supporting older Macs.

## Compatibility tiers

**Minimum supported macOS is 14.0** — see `docs/adr/0001-minimum-macos-target.md` for
the full reasoning. In short: App Store submission has required Xcode 26 (hence macOS
15.6+) since April 2026; macOS 13 is the API floor for `SMAppService.daemon` and
`NSXPCConnection.setCodeSigningRequirement`; supporting anything older means a second
privileged-helper implementation we could not CI-test, since GitHub-hosted runners for
macOS ≤14 are gone or going. The original "legacy tier ~10.13+" ambition is retired.

- **Supported**: macOS 14+, developed and tested primarily against macOS 15 and 26.
- **Excluded but acknowledged**: pre-14 users get, at most, a **read-only diagnostic
  mode** that reports reclaimable space without any privileged relocation.

Isolate compatibility-sensitive code (privileged-helper registration, mount mechanics)
behind protocols so a future tier — e.g. FSKit passthrough on macOS 26+ — can slot in.

## Operational profiles (see UX_AND_CLI.md for detail)

- **Safe** — official configuration, supported cleanup, cold storage only.
- **Transparent** — adds validated filesystem relocation/mounting strategies.
- **Expert** — detailed CoreSimulator/CoreDevice/runtime diagnostics; still refuses
  unsafe protected-system modifications.

## Strategy ordering (evidence-driven — see docs/adr/0002)

1. **Supported mechanisms, done completely** — Xcode Locations (DerivedData, Archives,
   Compilation Cache), `xcodebuild -downloadPlatform … -exportPath` + `-importPlatform`
   for an external Runtime Library, `-architectureVariant arm64`, `simctl runtime
   delete`, honest cleanup of regenerable data. No tool packages this today.
2. **Own the disconnected-drive problem** — mount verification, shadow-data detection,
   refusal under ambiguity, verified restore. This is the missing half of every
   existing attempt and the real differentiator.
3. **Canonical APFS mount** — experimental, opt-in, gated on the experiments in
   `docs/architecture/EXPERIMENTS.md`.
4. **FSKit passthrough (macOS 26+)** — R&D track, not v1.

## Prior art

Every mature tool in this space (DevCleaner, ClearDisk, CodePurge, CleanMyMac,
DaisyDisk) **deletes**; none relocates. The only relocation tool,
`Viniciuscarvalho/mac-ssd-rescue`, is a 3-commit script whose approach is contradicted
by published failure reports. See `docs/process/PRIOR_ART.md` and
`docs/research/FINDINGS-2026-09-05.md` §F9.

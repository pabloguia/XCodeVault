# Storage Catalog Model

Do not implement a single generic "move a directory" abstraction. Model each
storage category as an entry in a version-aware catalog with an explicit strategy.

## Strategies

- `nativeConfiguration` — use Xcode/toolchain's own configuration point (e.g.
  DerivedData location) instead of filesystem tricks.
- `safeCleanup` — regenerable, safe to delete outright via official commands.
- `coldStorage` — move to external storage as an archive, not on the live path.
- `userDirectoryRelocation` — relocate a `~/Library/Developer/...` directory.
- `symlinkRelocation` — relocate + symlink (per-category only, never whole-tree).
- `canonicalMount` — external volume mounted at the canonical system path (highest
  risk; requires hypothesis validation — see `architecture/HYPOTHESES.md`).
- `downloadRepository` — keep installers/runtimes externally, install on demand.
- `restoreOnDemand` — pull back from cold storage when needed.
- `appleManaged` — Apple owns the lifecycle; we surface info only, no relocation.
- `neverMove` — known unsafe or unnecessary to move; document why.

## Required metadata per catalog entry

identifier, human-readable name, discovered path(s), owning Apple subsystem,
detected size, reclaimable size, regenerability, deletion safety, relocation safety,
recommended strategy, required privilege level, supported macOS versions, supported
Xcode versions, Intel/Apple Silicon considerations, external-drive requirements,
dependencies on other categories, rollback capability, verification procedure, risk
level.

Populate this from runtime discovery (see `UX_AND_CLI.md` → `scan`/`doctor`), not
hardcoded assumptions — discover installed Xcodes, active `xcode-select`, SDKs,
runtimes, device support state, CoreSimulator/CoreDevice/simctl/xcodebuild
capabilities, filesystem formats, attached disks, APFS containers/volumes/UUIDs, free
space, current mounts, symlinks, and any unexpected path topology.

## Known categories to seed the catalog with (verify strategy per category before shipping)

Simulator runtimes & disk images, CoreSimulator data, DerivedData, indexes, build
products, Archives, XCTest devices, physical-device support & symbols,
DeveloperDiskImage/CoreDevice data, SPM caches & repo cache, Xcode/Simulator logs,
SwiftUI preview data, documentation caches, downloadable platform components
(installers), temporary developer assets, other Xcode-managed content discovered
at runtime.

## Runtime Library concept

Model a downloaded runtime **installer** and an **installed** runtime as distinct
catalog entries with distinct strategies (`downloadRepository` vs. the runtime's own
`appleManaged`/`canonicalMount` entry), so a user can keep installers on external
storage (`ExternalDrive/XcodeVault/RuntimeLibrary/...`) without re-downloading
multi-GB runtimes, install/offload on demand, and see which Xcode versions support
each operation (`xcodebuild -downloadPlatform` / `-downloadAllPlatforms` /
`-importPlatform`, feature-detected — never assumed present).

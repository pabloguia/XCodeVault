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
storage (`ExternalDrive/XCodeVault/RuntimeLibrary/...`) without re-downloading
multi-GB runtimes, install/offload on demand, and see which Xcode versions support
each operation (`xcodebuild -downloadPlatform` / `-downloadAllPlatforms` /
`-importPlatform`, feature-detected — never assumed present).

---

## Corrections from the 2026-09-05 research pass (read this before populating the catalog)

The category list above was written from the original brief. Research
(`../research/FINDINGS-2026-09-05.md`) corrects it in ways that matter:

- **`/Library/Developer/CoreSimulator/Profiles/Runtimes` is mostly a mount graft, not
  storage.** Measuring or moving it operates on a facade. The real bytes:
  - `/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-<UUID>`
  - `/Library/Developer/CoreSimulator/Cryptex/Images/Inbox/<UUID>.dmg` (download staging;
    stranded multi-GB files live here after failed installs)
  - **`/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/<sha1>.asset`** —
    outside `/Library/Developer` entirely, on the Data volume behind a `/System` path.
    A scanner that misses this **systematically under-reports** what Xcode consumes.
  - `/Library/Developer/CoreSimulator/Volumes/<Platform>_<Build>` — mount points managed
    by `simdiskimaged`, not storage.
  - Directory is `Cryptex` **singular**; there is no `Cryptexes`, no `Images/Bundles`.
- **Add `~/Library/Developer/Packages/`** — Apple-documented cache populated by
  `xcodebuild -runFirstLaunch -checkForNewerComponents`; essentially no cleanup tool
  knows about it.
- **Sealed runtimes are a distinct class**: hash-verified cryptex images, mounted, not
  copied. Strategy is `appleManaged` + `downloadRepository` (keep *installers* external
  via `-exportPath`/`-importPlatform`, which is supported) — **not** file relocation,
  until H9/E4 says otherwise.
- **`-architectureVariant arm64`** materially shrinks runtime downloads on Apple
  Silicon. Surface this as a first-class recommended action; it is free savings that
  requires no relocation at all.
- **CoreSimulator has no symlink strategy** — do not offer `symlinkRelocation` for this
  category at any risk level. **This is unconditional** (CLAUDE.md rule 7); it is not
  waiting on an experiment. E9 ran on 2026-09-08 and could **not** reproduce the Aug 2025
  report that symlinking `~/Library/Developer/CoreSimulator` breaks the Simulator's Files
  app (H5), so do not restate that as fact — but E9 did show the layout leaves shadow
  device sets behind, because CoreSimulator caches the resolved target path. The rule
  stands on "unverified, and known to produce shadow data".
- **`~/Library/Developer/DeveloperDiskImages` is `neverMove`** — it must remain a real
  directory (FB12363725). `~/Library/Developer` itself is `neverMove` as a whole.
- **Staging space is a category concern**: installing a 9–12 GB runtime reportedly needs
  ~40 GB free on the internal volume. Relocation does not fix the user's most acute
  moment of pain unless the product accounts for staging (E11).
- **Every entry needs an "evidence" field** pointing at the matrix entry or research
  finding that justifies its strategy. A strategy with no evidence pointer is
  `unverified` by definition and must render as experimental.

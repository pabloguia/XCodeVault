# Prior Art

## Viniciuscarvalho/mac-ssd-rescue

Primary prior art. Migrates user-level directories (DerivedData, iOS DeviceSupport,
CoreSimulator, XCTestDevices, SPMCache, `~/Library/Caches/org.swift.swiftpm`,
Archives) via rsync → file-count verification → delete source → symlink.

**What to reuse:** the basic category list as a starting point; the general
rsync-then-symlink approach for categories where per-directory symlinking is proven
safe (i.e., not the ones implicated in H2).

**What to rethink:**
- File-count verification is too weak — see `architecture/MIGRATION_ENGINE.md` for
  the stronger verification this project requires.
- No transactionality/journal — a crash mid-migration or mid-symlink-swap has no
  defined recovery path in the original tool; this project requires one.
- Whole-`~/Library/Developer` style symlinking risk (H2) wasn't a concern under
  older Xcode; it is on Xcode 15+ — don't inherit that assumption.
- No handling of system-wide `/Library/Developer/CoreSimulator*` paths, DeveloperDiskImages,
  CoreDevice, or MobileAsset — this project needs to research those independently
  (H1, H3).
- No canonical-mount concept — evaluate as a potentially better strategy for
  large system-wide categories, per H1.

Run `doctor` checks (see `product/UX_AND_CLI.md`) that specifically look for
leftover artifacts (stale symlinks, deleted-source-with-broken-link) from prior
mac-ssd-rescue usage, since users migrating to XCodeVault may already have run it.

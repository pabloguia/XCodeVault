# Proposal: catalogue the disk-image runtime store (`CoreSimulator/Images`) — 2026-10-27

**Status: proposal, for the operator's approval.** Nothing in the catalog changes until it is approved; this is the
"catalog change needing the evidence and review of a catalog decision" that STATUS's *Blocked / pending* names.

## The gap, measured (macOS 26.7.1 · Xcode 26.5 · Intel, 2026-10-27, read-only)

- `simctl runtime list -j`: both installed runtimes are `kind: Disk Image`, `Ready`, at
  `/Library/Developer/CoreSimulator/Images/<UUID>.dmg` — iOS 26.5 (10,597,197,700 B) and watchOS 26.5 (5,242,171,072 B).
- `du -sx /Library/Developer/CoreSimulator/Images` = 15 G; the files' allocated blocks equal `sizeBytes` (no sparse
  difference). `Images/Inbox` and `Images/mnt` are empty; the images mount under `CoreSimulator/Volumes/…` (another
  category, `runtimeMounts`, a mount graft), so `du -x` on `Images` does not cross into them.
- The store is `root:admin`, `rwxr-xr-x`, files `rw-r--r--`: readable by the user, so a user-level scan measures it.
- The catalog has no category for `Images/`. The savings model's runtime actions — **park** (`runtime offload`) and
  **delete** (`runtime delete`) — are attached to `simulatorRuntimeAssets` (the MobileAsset store under
  `/System/Library/AssetsV2/…`), which holds **4 KB** here. So the actions exist and work on these runtimes, but the bytes
  they free (15.8 GB, the largest single item on this Mac) show up only as a side note ("measured by simctl") and in no
  bucket, total or Plan figure.

F1's correction (2026-09-08) already established that an `-importPlatform` runtime — what XCodeVault's own Runtime
Library import produces — lives here, not in AssetsV2. The catalog was not updated for it.

## What is proposed

A new category, `runtimeDiskImages`:

| field | value | why |
|---|---|---|
| path | `/Library/Developer/CoreSimulator/Images` | the store |
| subsystem | `coreSimulator` | `simdiskimaged` manages it |
| regenerability | `redownloadable` | also restorable from a Runtime Library export (E8) |
| deletion risk | `medium` | as `simulatorRuntimeAssets`: only via `simctl runtime delete` |
| relocation risk | `critical` | E4: relocation refused; H20/ADR-0019: mounting it elsewhere not pursued |
| recommended | `appleManaged`, allowed `[appleManaged]`, `cleanupCommand: xcrun simctl runtime delete <identifier>` | same shape as `simulatorRuntimeAssets`; never touch the files |
| privilege | `root` (writes); scan as user | the files are root-owned |
| evidence | F1 correction; E8 (import lands here); this measurement | `probable` until reviewed |

and the savings model treats it as it treats `simulatorRuntimeAssets`: the same bucket (`runtimes`), the same park and
delete commands and markers (`exportFirst`, `runtimeSizes`), so the 15.8 GB enter the totals and the Plan.

### The one structural problem: `Images/Inbox`

`runtimeInbox` already lists `/Library/Developer/CoreSimulator/Images/Inbox` (and `Cryptex/Images/Inbox`). A category over
`Images/` contains it, so a stranded download there would be counted twice. Options:

1. **Drop `Images/Inbox` from `runtimeInbox`** (it keeps `Cryptex/Images/Inbox`); `doctor` still checks both Inboxes
   by its own path list, so the stranded-download finding is unchanged. A stranded `.dmg` there would then count under
   `runtimeDiskImages`, whose action (`simctl runtime delete`) cannot remove it — the savings would overstate by that
   file until a restart reaps it. Inbox is empty on a healthy machine (measured).
2. **Make `Images/Inbox` a breakdown** (`isBreakdownOf: runtimeDiskImages`) in a new category of its own, and drop it from
   `runtimeInbox`: totals stay a partition, the stranded bytes are listed separately, the overstatement remains.
3. **Measure only the `.dmg` files** (the catalog has no file-level template today): new scanner code, more risk.

**Recommendation: 2.** It keeps the totals honest by the catalog's own rule (`CatalogRules.validate`) and needs no new
scanner code.

### What else changes if approved

- The CLI's separate "runtime images measured by simctl" note goes (they are counted now); `scan`'s runtime list stays.
- The Overview and Simulators stop showing those bytes "outside the totals".
- `simulatorRuntimeAssets` keeps its actions for MobileAsset-delivered runtimes (Apple Silicon / newer Xcode layouts).
  Whether both categories should carry the park/delete rows, or the rows should follow where `simctl` says each runtime
  lives, is the design question to settle with the implementation; double-listing one runtime under both must not happen.
- `docs/product/STORAGE_CATALOG.md`, the pinned category table, tests, and a migration-safety review (it changes what the
  delete/park actions are shown against).

## Not proposed

Moving the store (E4 refused it; ADR-0019 declined the mount). This is accounting only.

# Transactional Migration Engine

## State machine

```
DISCOVER → PREFLIGHT → PLAN → QUIESCE → COPY → VERIFY DATA → ACTIVATE
  → VERIFY FUNCTIONALITY → COMMIT → (optional) CLEANUP
```

Persist a durable journal of the current state and all inputs needed to resume or
roll back, so the engine survives: app crash, helper crash, macOS reboot, external
SSD removal mid-operation, insufficient space, permission changes, partial copy,
source mutation during copy, and unexpected CoreSimulator restart.

**Never remove the source until the migration reaches a provably safe, verified
state.** Archives and other non-regenerable artifacts require stricter verification
than caches before source removal is even offered as an option.

## Verification (must exceed file-count comparison)

Depending on category, preserve and/or verify as relevant: file size, byte totals,
directory topology, symlinks, ownership, permissions, ACLs, extended attributes,
content hashes where appropriate, APFS-specific metadata where relevant.

## Functional verification (filesystem verification alone is not sufficient)

- Simulator-related: `simctl` responds; runtime registry responds; runtime is
  visible; a simulator device can be created; it boots to Booted state; a test app
  installs and launches; the simulator shuts down and can be deleted.
- Toolchain: `xcodebuild` builds a minimal fixture project; SwiftPM resolution works
  where relevant; XCTest runs where relevant.
- Physical device / CoreDevice (when test hardware available): device discovery,
  pairing state, Developer Mode compatibility, debugging support, DDI/CoreDevice
  behavior. Where hardware isn't available, mark pending and provide the manual test
  protocol (see `process/EXECUTION_PHASES.md`).

Never claim a strategy is compatible with a macOS/Xcode generation until its
functional tests pass for that generation — record the result in
`COMPATIBILITY_MATRIX.md`.

## Split-brain / external-drive-absence safety

Treat a missing external volume as a first-class failure mode, not an edge case.

Required mechanisms:
- Identify volumes by persistent UUID, not by mount path or drive name.
- Verify mount state and mount *readiness* before any operation depends on it running.
- Detect stale/shadow local data that may have accumulated while the external volume
  was absent, before allowing the external volume to be mounted back over it.
- On detecting a split-brain condition: refuse destructive operations and surface a
  reconciliation plan to the user — never auto-resolve by silently deleting either
  copy.
- Handle boot/login races (external volume not yet mounted when a service starts)
  and crash recovery cleanly; document the exact behavior for each canonical-mount
  category once H1 (see `HYPOTHESES.md`) is resolved.

## Rollback

Every migration must have a defined, tested rollback path back to the pre-migration
state, until the point where cleanup has been explicitly confirmed by the user.

---

## Corrections from the 2026-09-05 research pass

- **Copy fidelity:** `rsync -a` alone (what the prior art uses) **drops xattrs, ACLs and
  resource forks** — a correctness defect for code-signed bundles, `.xcarchive`s, and
  anything carrying `com.apple.provenance`/quarantine. Use `ditto`, or at minimum
  `rsync -aXAE` (plus `--fileflags` where available), and verify the metadata survived
  rather than assuming (E5).
- **Never verify by file count.** The prior art compares `find -type f | wc -l` with
  `<`; a copy that truncated every file passes. Byte totals + content hashes for
  non-regenerable data, topology + metadata checks for the rest.
- **Nested mounts:** `simdiskimaged` maintains mounts *inside*
  `/Library/Developer/CoreSimulator/Volumes/`. Any operation on that tree is operating
  on a mount tree, not a directory tree — unmount ordering matters, surprise removal
  tears down the whole tree, and the daemon can be left with a database pointing at
  vanished images. Quiesce accordingly and detect zombie runtime state.
- **Identify volumes by UUID, never by `/Volumes/<name>`.** Names change, and an unclean
  eject can bring the volume back as `<name> 1`, silently pointing every absolute
  symlink at nothing.
- **Mount-state check:** use `getattrlist(2)` with `ATTR_DIR_MOUNTSTATUS`
  (`DIR_MNTSTATUS_MNTPOINT`) — Apple DTS explicitly prefers it over Disk Arbitration for
  synchronous "is it mounted?" decisions. Keep a **sentinel file at the volume root** to
  distinguish "our volume is mounted" from "a local directory that happens to have
  content."
- **Mount pattern:** fstab (`UUID=… <path> apfs rw,noauto,nobrowse,nosuid,noatime,owners`)
  as a *suppressor* so the volume never auto-mounts at `/Volumes`, plus a root
  LaunchDaemon that performs `diskutil mount -mountPoint <path> <UUID>`; `StartOnMount`
  + Disk Arbitration for reconnect. This is the Nix `/nix` pattern — with the caveat
  that Nix's volume is internal and therefore always present at boot, which is exactly
  the problem we do not get to skip.
- **Ownership:** external volumes default to `noowners` (everything uid/gid 99).
  CoreSimulator has mixed root/user ownership — mount with `owners`, verify with E5.
- **Shadow-data defense (unverified, ours):** keep the unmounted mount point root-owned,
  mode `0500`, `chflags uchg`, so stray daemon writes fail loudly rather than silently
  succeeding. Validate with E7 before shipping — it may crash Xcode in a worse way than
  the problem it prevents. A LaunchDaemon `WatchPaths` tripwire on the mount point is
  the low-risk complement.
- **Breakage in this domain is silent and delayed** — the published failures surface
  weeks later, after an Xcode point release, by which time the user has forgotten the
  migration. Design the doctor subsystem to be the thing that catches it, and record
  every migration in a journal the doctor can read.

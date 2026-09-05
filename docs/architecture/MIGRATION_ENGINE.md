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

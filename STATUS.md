# XCodeVault — Status

_Last updated: 2026-09-06 (session 1). This file is the hand-off for the next session or a
post-compaction continuation. Update it as milestones move._

## Current milestone

**M3 — disconnect safety: implemented, reviewed, review fixes committed (re-review in flight).**
M1, M2, M3 committed. M4 GUI first slice builds and launches (read-only + clean flow). M5:
release/bundle scripts and cask draft exist; nothing signed yet.

## Done

- **Spec read; index reset** (stale staged deletions removed, working tree == HEAD).
- **Stack chosen — ADR-0003:** Swift 6 / SwiftPM monorepo; `XCodeVaultCore` is the single
  domain layer; `xcodevaultctl` CLI on swift-argument-parser; helper/GUI targets to be added
  in M3/M4; `.app` assembled by script; CI on `macos-15` + `macos-26`.
- **M0 agentic environment:** `.claude/agents/` (helper-security-reviewer,
  migration-safety-reviewer, storage-researcher), `.claude/skills/` (run-experiment,
  add-catalog-category, safety-review), hooks (`helper-guard.sh` blocks shell/PID-validation/
  generic-deletion patterns in helper sources and any SIP manipulation; `swift-format-lint.sh`).
- **Gating experiments:**
  - E1 (read-only half): path not SIP-protected; **all runtime bytes are in
    `/System/Library/AssetsV2`**, `Cryptex/Images/bundle` empty on Xcode 26.5. Mount attempt
    needs root → pending — manual (procedure in the matrix).
  - E2: F4 failure reproduced on a physical USB SSD; **follows the device, not the path**
    (disk images pass at `/Volumes` and `$HOME`; symlink into the USB volume fails). H6 probable.
  - E8: full Xcode 26.5 flag surface feature-detected (incl. `-prepareDeviceSupport`,
    `-deleteComponent`, `simctl runtime add/verify`). H4 probable.
  - **ADR-0004:** canonical mount demoted to R&D; v1 = accounting + official mechanisms +
    cleanup + disconnect safety.
- **M1 code:** `xcodevaultctl scan|status|report|doctor|xcode list|runtime list|volumes|
  compatibility`, all with `--json`. Discovery: Xcodes + capabilities, runtimes, devices,
  volumes + qualification, host. Catalog of 22 categories with evidence pointers and
  experimental labeling enforced by `CatalogRules`. `DiskUsage` (fts, `ATTR_DIR_MOUNTSTATUS`
  mount boundaries). Doctor: forbidden symlinks, broken/external symlinks, mac-ssd-rescue
  leftovers, low space, runtime registry/mount/signature problems, stranded Inbox, orphan
  MobileAssets, unavailable devices, DerivedData-on-external warning, xcode-select, OS floor.
  31 unit tests green; `scan` on the dev Mac ≈ 22 s.

- **M2 (committed):** journaled `clean` (granular, safeCleanup-only, Apple-tool categories
  never filesystem-deleted), `runtime delete/export/import/library/offload` (feature-detected,
  E11 staging preflight), `locations show/set-*/reset-*` for DerivedData, Archives (verified),
  compilation cache (Xcode 26, experimental). E8b + Locations-keys evidence in the matrix.
- **M3 (committed):** `VaultRegistry`/`VaultVerifier` (UUID + sentinel;
  states verified/absent/movedMountPoint/foreign/ambiguous/sentinelMissing), `TreeVerifier`
  (topology, mode, symlink targets, xattrs, SHA-256), `MigrationEngine` (plan → copy via ditto
  → verify → explicit re-verified source removal; abort; refuses while an interrupted migration
  exists), doctor rules for shadow `/Volumes/<name>` dirs, absent/foreign vaults, interrupted
  journal ops, Locations pointing at absent volumes. `vault init/status/forget`, `externalize`,
  `restore`, `migration status/abort`, `bench` (E10, heuristic verdicts). 55 unit tests incl.
  fault injection (source mutation mid-copy, destination vanishing, corrupted copy, crash
  between COPY and VERIFY).
- **Helper skeleton (committed; security review in flight, not reachable from clients):** `XCodeVaultHelperProtocol`
  (three allowlisted verbs, fixed paths, NSSecureCoding result), `xcodevault-helper` daemon
  (code-signing requirement set before resume; refuses to serve without a baked team id),
  launchd plist for `SMAppService.daemon`. Not yet wired into the CLI/GUI (needs a signed bundle).
- **M4 first slice:** SwiftUI app (Overview / Storage / Doctor / Clean / Volumes / Runtimes /
  Journal) on the same Core; `scripts/bundle-app.sh` assembles `dist/XCodeVault.app`
  (unsigned) — launches.

## In flight

- Migration-safety re-review of the fixes (first review: 10 findings, all addressed with
  regression tests). Helper-security review of the daemon skeleton.
- E2 is complete (9 cases): only the physical USB volume fails; the mechanism is still unnamed
  (no TCC/sandbox denials in the unified log). Recorded in FINDINGS + matrix.

## Blocked / pending — manual (ask the user)

- E1 mount half, E7 shadow-data defense, E6 surprise removal, E9 CoreSimulator symlink
  reproduction: need root and/or physical hardware manipulation on the user's Mac.
- E8 behavioural half: `-downloadPlatform … -exportPath` round trip needs ≥ 20 GB free
  (the dev Mac has < 4 GB — E11 staging problem in real life); `IDECustomDerivedDataLocation`
  write-test needs a moment when Xcode is closed.
- GitHub remote/CI: repo has no remote; do not create one without the user.

## Next three actions

1. Land review findings; commit M3 + helper skeleton + GUI slice; run `swift test` on CI once a
   remote exists (user decision: repo creation is public — ask first).
2. **M4:** wire `clean`/`vault`/`externalize` flows into the GUI with the same confirmations as
   the CLI; helper client (`SMAppService.daemon` registration UI, status handling) behind the
   signed bundle — cannot be tested unsigned.
3. **M5:** Developer ID signing + notarization + stapling in `scripts/release.sh`, Homebrew Cask
   formula draft, in-app uninstall (`unregister()`), diagnostic bundle (`report --json`).

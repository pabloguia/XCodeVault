# XCodeVault — Status

_Last updated: 2026-09-06 (session 1). This file is the hand-off for the next session or a
post-compaction continuation. Update it as milestones move._

## Current milestone

**M3 — disconnect safety: implemented, independently reviewed twice, all findings fixed and committed.**
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
- **Helper skeleton (committed, security-reviewed, not reachable from clients yet):** `XCodeVaultHelperProtocol`
  (three allowlisted verbs, fixed paths, NSSecureCoding result), `xcodevault-helper` daemon
  (code-signing requirement set before resume; refuses to serve without a baked team id),
  launchd plist for `SMAppService.daemon`. Not yet wired into the CLI/GUI (needs a signed bundle).
- **M4 first slice:** SwiftUI app (Overview / Storage / Doctor / Clean / Volumes / Runtimes /
  Journal) on the same Core; `scripts/bundle-app.sh` assembles `dist/XCodeVault.app`
  (unsigned) — launches.

## Session 2 (2026-09-06, user authorised experiments on the Kingston USB volume)

- **E6 (software variant): pass** after 4 runs; found and fixed the "failed op leaves an
  unremovable partial copy" gap (`migration status`/`doctor` list leftovers, `abort` removes them,
  retry error names the command). Force unmount removes `/Volumes/<name>` outright (no shadow dir).
- **E8 export: pass with a surprise** — `-downloadPlatform -exportPath` downloads, **installs the
  runtime internally** (tvOS 26.5, 4.9 GB), then writes an `.exportedBundle` (dir with
  `Restore/*_Cryptex.dmg`). Peak internal use 7 GB for a 5 GB image. Library scanner understands
  `.exportedBundle`; export warns; offload is the workflow.
- **E8 import: environmental fail** — `-importPlatform` copies the image internally first
  (5.8 GB in 20 s) and CoreSimulator refused at 10.3 GB free ("disk is almost full"). Preflight now
  requires 2× image + 3 GB. Functional boot probe not reached.
- **Real-world `clean --apply`:** freed 8.86 GB of DerivedData, journaled.
- **Stranded 5.02 GB Inbox dmg** left behind by Apple's export (after `runtime delete`) — `doctor`
  flags it; removal needs root: `sudo rm /Library/Developer/CoreSimulator/Cryptex/Images/Inbox/85D24F59-8A6C-40FD-B663-440AF721202A.dmg`.
- `vault init --directory` added (volume roots are root-owned; helper not shipped).
- Everything created on the USB volume and in the home directory was removed; the temporary vault
  registration was forgotten. Machine state vs. session start: DerivedData cleaned (−8.9 GB),
  the stranded Inbox dmg (+5 GB, needs root), tvOS devices/runtime removed again.

## In flight

- Nothing running. 67 tests green.

## Blocked / pending — manual (ask the user)

- **E1 mount half: done by the user with sudo (2026-09-07) — H8 verified**, default mount is
  `noowners`. E7, E9 (scratch account) and the physical yank for E6 still need hands on the Mac.
- **Stranded 5 GB Inbox dmg: blocked** — `sudo rm` refused (no flags, no holder, no logged
  denial). Next: reboot and re-check with `doctor`; if it persists, file Feedback Assistant.
  The helper's `removeStrandedRuntimeDownload` verb would hit the same policy — re-evaluate it.
- Import half of E8 (`scripts/experiments/e8c-import-roundtrip.sh`) needs ≥ 2× image + 3 GB
  free internally; blocked by the Inbox file (5 GB) on this Mac.
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

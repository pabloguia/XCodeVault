# XCodeVault — Status

_Last updated: 2026-09-06 (session 1). This file is the hand-off for the next session or a
post-compaction continuation. Update it as milestones move._

## Current milestone

**M1 — honest accounting: done (first cut, committed).** M2 (supported mechanisms) is next.

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

## In flight

- E2 follow-up: `log show` capture of TCC/sandbox denials during the failing USB case
  (`XCV_E2_CASES="B F"` rerun) to name the mechanism; case F (disk image backed by the USB
  device) had a harness bug in the first run, fixed.

## Blocked / pending — manual (ask the user)

- E1 mount half, E7 shadow-data defense, E6 surprise removal, E9 CoreSimulator symlink
  reproduction: need root and/or physical hardware manipulation on the user's Mac.
- E8 behavioural half: `-downloadPlatform … -exportPath` round trip needs ≥ 20 GB free
  (the dev Mac has < 4 GB — E11 staging problem in real life); `IDECustomDerivedDataLocation`
  write-test needs a moment when Xcode is closed.
- GitHub remote/CI: repo has no remote; do not create one without the user.

## Next three actions

1. **M2:** `xcodevaultctl clean --plan/--apply` for user-domain regenerable categories with a
   dry-run default and journaled deletion; `runtime list/download/offload` wrapping
   `-downloadPlatform -exportPath` / `-importPlatform` / `simctl runtime delete` with
   feature-detection and the E11 staging-space check; `locations` to read/write Xcode's
   DerivedData/Archives settings with the E2 warning.
2. Test the `IDECustomDerivedDataLocation` write path against `xcodebuild -showBuildSettings`
   (E8 remainder) and record in the matrix.
3. **M3 groundwork:** volume identity (UUID + sentinel), journal format, and the fault-injection
   test harness on scratch disk images.

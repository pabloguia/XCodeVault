# XCodeVault — Status

_Last updated: 2026-09-08 (session 4). This file is the hand-off for the next session or a
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

## Session 3 (2026-09-07, `docs/process/RUNBOOK-E8-import-roundtrip.md` executed as written)

- **E8 import half: pass, with a functional boot probe.** Re-exported tvOS to the USB volume,
  offloaded, then `xcodevaultctl runtime import` → `xcodebuild -importPlatform <dmg>` (direct
  path to the exported bundle's inner Cryptex dmg — worked first try, no fallback needed) →
  `simctl runtime verify` → create/boot/reach `Booted`/shutdown/delete an "Apple TV" device →
  `runtime delete` → `simctl delete unavailable`. All exit 0. Peak internal staging: 4.807 GB
  for a 4.906 GB image (≈0.98×, vs. ≈1.18× on the 2026-09-06 attempt). Machine returned to only
  iOS 26.5 + watchOS 26.5, 0 unavailable devices, no runtime/device `doctor` findings — **no
  reboot needed this run** (unlike 2026-09-06, no stranded file landed in the Inbox this time;
  cause not investigated — worth a follow-up if it recurs). H4 in `HYPOTHESES.md` moved to
  verified; `COMPATIBILITY_MATRIX.md` E8 import entry and pending table updated.
- **Preflight tightened:** `RuntimeOperations.preflightImport`'s old 2×+3 GB hard requirement was
  materially too conservative next to the two measured peaks (≈4.8–5.8 GB for the same 4.9 GB
  image); now 1.5×+2 GB required / 2×+2 GB warn. Only validated against one mid-size (tvOS,
  ~4.9 GB) image — revisit if a much larger image (e.g. iOS, ~10 GB) shows a different peak
  ratio.
- Ran alongside an unrelated concurrent `xcodebuild` (user's own MySmoke iOS project, different
  platform/DerivedData) with no observed contention; internal free stayed ≥ 19 GB throughout.
- Everything created on the USB volume was removed; no vault registered.
- **E7 shadow-data defense: pass, does not crash Xcode.** User set up
  `/Library/Developer/xcv-probe` (`root:wheel`, `0500`, `chflags uchg`, per
  `docs/process/MANUAL_TEST_PROTOCOL.md`); agent verified the setup, then confirmed
  `xcodevaultctl scan`/`doctor` silently skip the locked directory (no crash), and — in a
  disposable scratch project isolated via `-derivedDataPath` (to avoid touching the global
  `IDECustomDerivedDataLocation` while the MySmoke build/tests above were still running) — a
  real `xcodebuild build` failed loudly and cleanly (`** BUILD FAILED **`, exit 65, no crash,
  confirmed against a `log stream` capture). H3 in `HYPOTHESES.md` updated;
  `COMPATIBILITY_MATRIX.md` gets a new E7 entry. Not tested: Xcode.app GUI, `VaultVerifier`
  sentinel check. **`/Library/Developer/xcv-probe` still exists and needs the user to run,
  with sudo, to clean up:**
  `sudo chflags nouchg /Library/Developer/xcv-probe && sudo rm -rf /Library/Developer/xcv-probe`.

## Session 4 (2026-09-08, E8 import round trip repeated against the real, in-use iOS runtime)

- **E8 import re-validated against a much larger, real, in-use image (iOS 26.5, 10.35 GB):
  pass.** Confirms the tightened preflight formula (1.5×+2GB) generalizes: import peak was
  10.110 GB (≈1.0×), matching the tvOS ≈0.98–1.18× range. No code change needed.
- **Real devices survive the round trip.** `iPhone 17 Pro Max` and `iPhone SE (3rd gen)` — the
  user's actual MySmokeiOS dev devices, one of them booted at the time — were marked
  `Unavailable` (not deleted) the moment the iOS runtime was offloaded, and came back to normal
  `Shutdown` state **automatically** once the same-version runtime was reimported. Zero data
  loss, nothing recreated. `e8c-import-roundtrip.sh` was NOT reused as-is (it's tvOS-specific
  and unconditionally deletes the runtime + runs `simctl delete unavailable` at the end — both
  wrong here); ran the steps manually with a distinctly-named throwaway device
  (`xcv-probe-ios`) instead.
- **Gotcha found:** `simctl bootstatus -b` hung reporting a non-terminal `Data Migration`
  status for several minutes after the probe device had actually finished booting (confirmed
  via `simctl list devices` directly). Not a product defect — `bootstatus` isn't used anywhere
  in `Sources/`, only in the tvOS experiment script.
- Freed 5.31 GB of DerivedData first (pre-authorized category) to get comfortable headroom
  before the export; this deleted the user's own MySmokeiOS DerivedData too (expected/
  regenerable — their next build there will be a full build).
- `HYPOTHESES.md` H4, `COMPATIBILITY_MATRIX.md` (new entry), `FINDINGS-2026-09-05.md` updated.
  Everything created on the USB volume removed; no vault registered.

## In flight

- Nothing running. 67 tests green.

## Blocked / pending — manual (ask the user)

- **E1 mount half: done by the user with sudo (2026-09-07) — H8 verified**, default mount is
  `noowners`. The physical yank for E6 still needs hands on the Mac.
- **E9 (symlink `~/Library/Developer/CoreSimulator`, gates H5) — scheduled for a fresh session.**
  Full self-contained runbook: `docs/process/RUNBOOK-E9-symlink-coresimulator.md`. User
  authorized running it on their own account (not a scratch account) on 2026-09-08 — "o
  CoreSimulator se refaz se for necessário". No `sudo` needed; mandatory restore step either way.
- **E7 shadow-data defense: done (2026-09-07), pass.** See Session 3 above. `/Library/Developer/
  xcv-probe` removed by the user with sudo, confirmed gone.
- **Stranded 5 GB Inbox dmg: resolved by reboot** (2026-09-07). `sudo rm` is refused by policy,
  but simdiskimaged reaps the Inbox at startup. Doctor now says "restart the Mac". The helper's
  `removeStrandedRuntimeDownload` verb is pointless against this policy — drop it in M3 review.
- **Import half of E8 — done (2026-09-07, tvOS; 2026-09-08, iOS 10.35 GB), pass both times.**
  See Session 3 and Session 4 above and `docs/process/RUNBOOK-E8-import-roundtrip.md` for the
  tvOS procedure. Preflight formula confirmed against two very different image sizes.
- GitHub remote/CI: repo has no remote; do not create one without the user.

## Next three actions

1. Land review findings; commit M3 + helper skeleton + GUI slice; run `swift test` on CI once a
   remote exists (user decision: repo creation is public — ask first).
2. **M4:** wire `clean`/`vault`/`externalize` flows into the GUI with the same confirmations as
   the CLI; helper client (`SMAppService.daemon` registration UI, status handling) behind the
   signed bundle — cannot be tested unsigned.
3. **M5:** Developer ID signing + notarization + stapling in `scripts/release.sh`, Homebrew Cask
   formula draft, in-app uninstall (`unregister()`), diagnostic bundle (`report --json`).

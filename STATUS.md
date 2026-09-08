# XCodeVault — Status

_Last updated: 2026-09-08 (session 6). This file is the hand-off for the next session or a
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

## Session 5 (2026-09-08, `docs/process/RUNBOOK-E9-symlink-coresimulator.md` executed as written)

- **E9: the symlink-breaks-the-Simulator report (F3) did not reproduce.** With
  `~/Library/Developer/CoreSimulator` (9.1 GB) renamed to `~/CoreSimulator-real` and replaced by
  a symlink on the same internal disk, all three Files-app operations from the report succeeded
  on a throwaway `xcv-e9-probe` device and were verified on disk *through the symlink*: create
  folder, share a photo via Save to Files (2,567,402 bytes), Safari download into
  `On My iPhone/Downloads`. `xcodebuild build` → `simctl install` → `launch` → container write
  all exit 0 (`** BUILD SUCCEEDED **`, `e9-write-test.txt` written, no crash). Device registry
  intact before *and* after a forced `CoreSimulatorService` restart. Guest `log stream`
  (845,711 lines, debug): subsystems resolve through the symlink and succeed; no sandbox denials,
  no FileProvider errors.
- **H5 recorded as "not reproduced on this configuration", NOT as "symlink is safe."**
  `CLAUDE.md` rule 7 and ADR-0004 are unchanged and the product still ships no symlink strategy
  for CoreSimulator. The useful shift is in the risk shape: the failure is not an unconditional,
  visible break on current macOS/Xcode, so a user already in this layout (typically from
  `mac-ssd-rescue`) may see no symptom — which is an argument for `doctor` reporting the layout
  rather than assuming the user notices breakage.
- **Method caveat that nearly produced a false positive:** the first synthetic tap on each new
  Simulator UI state is consumed as a window-focus click. The first "New Folder" tap produced no
  folder and the menu just closed — visually identical to the reported bug. Repeating the
  identical tap created the folder. Recorded in the evidence file and the matrix.
- Physical devices (read-only, opportunistic): iPhone 17 Pro Max and Apple Watch Ultra 2 stayed
  `available (paired)` in `devicectl` with only `CoreSimulator` symlinked. The wider
  `~/Library/Developer` symlink FB12363725 needs was deliberately not performed.
- **Restore ran and passed.** `CoreSimulator` is a real directory again (9.1 GB, original mtime),
  `~/CoreSimulator-real` gone, the three real devices back with their original UUIDs, runtimes
  unchanged, 0 unavailable, `doctor` showing only the two pre-existing findings. One deviation
  from the runbook, taken for safety: the `Apple Watch Ultra 3` was found `Booted` (stale since
  2026-09-07 21:02, no Xcode/Simulator running), so it was `simctl shutdown`-ed before the swap
  rather than left running through a `CoreSimulatorService` kill, and booted again afterwards to
  match the baseline.
- **Post-restore residue — a real shadow directory, worth a `doctor` rule.** The restore
  correctly removed `~/CoreSimulator-real`, but a final independent check found it *recreated*
  minutes later, holding an empty `Devices/` (0 KB, nothing open under it). Cause: the restore's
  `pkill CoreSimulatorService` was followed by the service restarting and recreating the skeleton
  at the **resolved** path it had cached while the symlink was live — consistent with step 6,
  where `simctl get_app_container` returned a path under `~/CoreSimulator-real` rather than under
  `~/Library/Developer/CoreSimulator`. Verified the real directory still held all three device
  UUIDs plus `device_set.plist` before touching anything, then removed the leftover with `rmdir`
  (not `rm -rf`) so it would refuse if anything were inside. This is a concrete, external-volume-
  free instance of the rule-6 shadow/duplicate failure mode. **The `doctor` rule this suggested
  is now implemented** — see below.
- **New `doctor` rule `shadow-coresimulator` (implemented this session).**
  `Doctor.checkShadowCoreSimulatorRoots` flags CoreSimulator device sets living outside
  `~/Library/Developer/CoreSimulator`. `.error` when the set holds devices or a
  `device_set.plist` (real duplicated state, remediation explicitly refuses to suggest deletion),
  `.warning` when it is an empty skeleton (remediation offers `rmdir`, which cannot take data
  with it). Scans home 1 level deep and external volumes / disk images 2 levels deep — the
  second level matters because the real-world layout is
  `/Volumes/<disk>/mac-ssd-rescue/CoreSimulator`, which a top-level-only scan missed in the
  first draft. Detection only; it never touches the filesystem.
  Four shapes, because "could not read it" and "empty" must never collapse into one:
  `.unreadable` (→ `.error`, refuses to suggest removal), `.holdsDevices` (→ `.error`, "do not
  delete it yet"), `.otherContent` (→ `.warning`, names what is actually left), `.pureResidue`
  (→ `.warning`, the only branch that mentions `rmdir`, and only when the root is nothing but a
  genuinely empty `Devices`). Both `.unreadable` and `.holdsDevices` escalate to `.critical` when
  a forbidden symlink co-exists, i.e. when two sets can be taking writes at once. A root that
  cannot be enumerated emits its own `shadow-coresimulator-unscannable` finding rather than
  passing silently. No copy-pasteable shell command is emitted anywhere: paths would need
  escaping for volume names with quotes, and `report` redacts `$HOME` to a literal `~` that does
  not expand inside quotes.
  **Verified against this machine, not just fixtures:** it flags
  `/Volumes/<vault>/mac-ssd-rescue/CoreSimulator` (3 devices + `device_set.plist`, 7.4 GB) as
  `.error` — i.e. there is a duplicate copy of all three real simulator devices on the external
  drive — and the deliberately recreated E9 residue as `.warning`. 18 new tests (85 total,
  0 failures).
  **Three independent review rounds, each REQUEST CHANGES, each finding a real defect of the same
  class — a false "this is empty" claim on the one branch that invites deletion:**
  (1) the residue branch checked only UUID-named entries, so a `Devices/` holding a `.DS_Store`
  — the likely state of any set on a drive somebody has browsed in Finder — was announced as
  "nothing but an empty Devices directory" and offered for `rmdir`; (2) the same branch used
  `fileExists`, which follows symlinks, so a symlinked `Devices` reached it too and the suggested
  `rmdir` would return `ENOTDIR`; (3) an unreadable directory below a volume root silently
  swallowed a whole device set. All three are now gated on unfiltered listings and `lstat`, with
  regression tests, and the three surviving mutants the reviewer reported were re-run locally and
  confirmed killed.
  **A fourth defect was caught by running against the real machine rather than fixtures:** the fix
  for (3) fired on every external volume's root-owned macOS metadata stores (`.Spotlight-V100`,
  `.DocumentRevisions-V100`, `.TemporaryItems`) — three unactionable warnings per volume on every
  run. The first fix (skip hidden directories entirely) was itself wrong and was replaced on
  review: hidden directories are scanned, only the *unreadable-hidden finding* is suppressed —
  the noise came from reporting, not from scanning, and a deny-list of known macOS stores was
  rejected because that set is not closed, so every OS release would be a latent noise regression.
  **A fifth, found in the fourth round and the nastiest of the set:** dot entries were filtered out
  of the "what is left" list but still counted by the gate, so a root holding only hidden extras
  rendered "not empty either — ." — naming nothing, while Finder hides dotfiles and shows an empty
  directory. A real CoreSimulator root carries `.metadata_never_index`, so **the exact E9 residue
  this rule exists for hit that path**: the user sees an empty directory, a message naming nothing,
  and reaches for `rm -rf`. Fixed, with a test for that precise shape.
  **Approved on the fifth round**, after the reviewer brute-forced 56 directory shapes (root ×
  `Devices` entry combinations, incl. dotfiles at both levels) asserting that no branch renders an
  empty leftovers list, no "nothing but an empty" claim contradicts the on-disk listing, and every
  remediation naming `rmdir` survives a real `rmdir(2)`. 8 of 8 adversarial mutants killed; the two
  newest tests are each the *sole* killer of two mutants, including "someone adds a harmless-dotfile
  allowlist", which is the plausible future regression that would put the E9 skeleton back on the
  removal branch.
  **Follow-ups, tracked not fixed** (the first two are in the rule's false-negative list):
  1. `ATTR_DIR_MOUNTSTATUS` is still unchecked, so a volume that unmounted and left a readable
     empty mount-point stub enumerates clean and yields no finding. The finding text now says this
     honestly, but "doctor reports clean on an unmounted volume" is the exact silence rule 6
     exists to prevent — this is the one gap where the documentation is a stopgap, not a fix.
     `MountStatus.isMountPoint` already exists and is used elsewhere in `Doctor`; it needs an
     injection seam like the one `Doctor` has for `home`/`runner` to be testable.
  2. A set in a volume's Trash (`/Volumes/X/.Trashes/<uid>/CoreSimulator`, depth 3) is invisible —
     and that is precisely where one lands when a user follows this rule's own `.holdsDevices`
     advice via Finder. Deserves an issue, not just a comment.
- **Two existing rule texts corrected, deliberately without weakening the rules.**
  `checkForbiddenSymlinks` asserted that symlinking `~/Library/Developer/CoreSimulator` "breaks
  the Simulator's Files app"; `checkPriorToolLeftovers` called it "a documented-broken
  configuration". E9 could not reproduce that, so both now say the layout is *unsupported* and
  *leaves shadow device sets*, with the Files-app report flagged as unverified rather than
  proven. Severity stays `.critical` and rule 7 is untouched — only the stated reason changed.
- Follow-up (small, fixed in this commit): the E9 script's `DeveloperDiskImages` check printed
  "real directory (as required)" when the path does not exist at all (`[ -L ]` is false for a
  missing path). Not a rule-7 violation — nothing was symlinked — but the check now tests
  existence first. `~/Library/Developer/DeveloperDiskImages` does not exist on Xcode 26.5 here.
- Not ours, left alone: `/tmp/xcv-e9-runbook-test.log` (13:17, a `swift test` log predating this
  session — presumably from writing the runbook earlier today).

## Session 6 (2026-09-08, external-drive setup + E12)

- **The user is done with `mac-ssd-rescue`.** They deleted its ~26.4 GB (11 GB iOS DeviceSupport,
  8.0 GB DerivedData, 7.4 GB CoreSimulator, plus SPM Repos / XCTestDevices) after a read-only
  comparison found nothing worth keeping: internal copies newer and larger on all three devices, no
  app present only externally, and — after normalising the per-install container UUIDs, without
  which thousands of files look "missing" — everything genuinely unique was simulator OS state
  (Apple News widget cache, PosterKit, MobileAsset analytics, `.tracev3` logs), unsent SDK telemetry
  (Crashlytics, google-sdks-events), or a build artifact regenerable from source. Caveat stated to
  the user: paths were compared, not contents.
- **E12 (new): case-sensitive APFS is not the hazard the shipped warning implied.** See the matrix
  entry and `scripts/experiments/e12-case-sensitivity.sh`. Both product-shaped workloads pass on a
  disposable case-sensitive image; the warning is narrowed from "may break" to the residual risk
  actually left (source referring to a file by the wrong case). This mattered because the user's
  real destination drive is Case-sensitive APFS.
- **Ownership has a second face that F5 never recorded.** Enabling ownership is required (mixed
  root/user data) *and* is exactly what makes the volume root `root:wheel` and unwritable by the
  user — so `vault init` fails with a bare "permission denied", and `rm -rf` on a directory in the
  volume root empties it but cannot remove it. New `OwnershipAdvice` (`Sources/.../Vault/`) turns
  both into the precise one-time privileged command, shell-quoted for volume names with spaces or
  apostrophes, resolving the real user/group at runtime rather than hardcoding. `install -d` over `mkdir`+`chown`
  for idempotency — NOT atomicity: install(1) does mkdir then chown, so the root-owned window
  exists either way; the advantage is one command that also repairs an existing directory. XCodeVault prints these and never
  runs them (`SECURITY_MODEL.md`: the helper allowlist has no arbitrary `mkdir`/`chown`).
  `vault init` now also rejects a pre-existing but unwritable vault directory — the bare
  `sudo mkdir` case, which otherwise fails on the first real write instead of here.
- **A `contains: .` bug in `checkPriorToolLeftovers`, found in real use rather than by review.**
  Once the prior tool's data was deleted but its directory survived, the rule rendered an empty
  contents list as nothing and still advised "compare with the local copies before deleting" —
  advice about nothing, on a rule that talks about deletion. Same defect class as the four the E9
  doctor-rule reviews chased, in pre-existing code. Empty and unreadable are now distinct, with
  tests.
- **Drive state:** `/Volumes/<vault>`, Case-sensitive APFS, `Owners: Enabled`, 1.0 TB / ~363 GiB free,
  qualifies `suitableWithWarnings` (USB IOPS + case-sensitivity). Vault directory
  `/Volumes/<vault>/XcodeVault` pending the user's one privileged command.
- **Four safety-review rounds on this session's code; the blocking finding was mine, three times
  over.** `try? contentsOfDirectory(...) ?? []` — list a directory, and on failure treat it as
  empty. It fails *open*: a directory nobody can read reads as "this is empty". It appeared in the
  shadow-root rule, then in the mac-ssd-rescue rule, then in `OwnershipAdvice`, where the empty
  branch is exactly the one that emitted `sudo chown`. Rather than patch it a third time I grepped
  every `contentsOfDirectory` in `Sources/`: all 13 others already `guard let … else { continue }`
  and fail closed. That was the last one. **If this pattern reappears, treat it as a repeat, not a
  new bug.**
- Follow-ups from the final review, tracked not fixed:
  1. **`VaultVolume.register` re-check (highest).** `createDirectory` at :106 and the sentinel write
     at :116 are separated only by the mount check at :91. If the volume unmounts in that window,
     macOS removes the mount-point directory and `withIntermediateDirectories: true` recreates it
     *locally* — and the new writability check approves it, because it really is ours. Today the
     only thing preventing a local write at a canonical path is `/Volumes` being root-owned, which
     is the OS, not our code, and does not hold for disk images or user-writable mount directories.
     Re-assert `isMountPoint` **and** the volume UUID immediately before the sentinel write.
  2. **One resolution helper.** There are now three copies of "resolve a symlink destination and
     compare" (`Doctor.swift` twice, `PathSafety.canonicalize`). `stillTargeted` still misses
     symlink→symlink, case-differing destinations, and doubled slashes — all fail-open. One helper
     comparing lexical + `realpath()` forms, case-insensitively, closes all three. Harm ceiling is
     low (the advice is `rmdir`, which cannot destroy data).
  3. **Journal the directory creation.** `register` journals only on success, so a crash between
     creating the directory and writing the sentinel leaves an unjournalled empty directory.
  4. **SF-2 not done, deliberately.** A test that `register` refuses an existing-but-unwritable
     vault directory needs a real mount point plus a directory we cannot write — impossible without
     sudo or a disk image in a unit test. `writabilityProblem` is covered in isolation instead; the
     integration is one line. Recorded rather than faked.
  5. `common.sh` could print the script name and git rev in every evidence header — E12 does this
     now; no other experiment file records which script version produced it.
- Next: once the vault directory exists, exercise a real relocation into it (DerivedData is the
  natural first, `nativeConfiguration` via Xcode Locations) and verify the disconnect path.

## In flight

- Nothing running. 105 tests green.

## Blocked / pending — manual (ask the user)

- **E1 mount half: done by the user with sudo (2026-09-07) — H8 verified**, default mount is
  `noowners`. The physical yank for E6 still needs hands on the Mac.
- **E9 (symlink `~/Library/Developer/CoreSimulator`, gates H5): done (2026-09-08) — the reported
  failure did NOT reproduce.** See Session 5 below. Rule 7 / ADR-0004 unchanged. Still pending
  and explicitly out of scope for that runbook: the `~/Library/Developer`-wide symlink that
  FB12363725 actually requires (forbidden by rule 7 — it would move `DeveloperDiskImages`), the
  Xcode.app GUI (only `xcodebuild` was exercised), Apple Silicon, and any iCloud-Drive-signed-in
  configuration.
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

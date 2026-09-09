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
- **Vault directory renamed `XcodeVault` → `XCodeVault`** (capital C, the project's own spelling) at
  the user's request, and **registered**: `/Volumes/<vault>/XCodeVault`, `<user>:staff` 755, sentinel
  written unprivileged, `vault status` VERIFIED. On a case-sensitive volume — which the user's drive
  is — the spelling is a genuinely different path, not cosmetic. The name now lives in
  `XCodeVaultHelperProtocol` (the only module both the client and the helper link);
  `XCodeVaultCore` deliberately keeps NO dependencies, so it repeats the literal and
  `HelperContractTests` links both modules and fails if they drift.
- **Helper security review found a real hole the rename opened.** Moving the name out of
  `main.swift` moved with it the guarantee that the created directory stays inside the approved
  mount point. A leading `".."` would make `dir` resolve to `/Volumes`: `lstat` sees a directory so
  `mkdir` is skipped, `O_NOFOLLOW` does not constrain `..`, and the `fchown` hands `/Volumes` to the
  caller. Unreachable (compile-time constant, no XPC parameter feeds it) and already blocked by a CI
  assertion — but in *another target*, not by the helper. The guard is back in `main.swift`, and
  validated on **bytes**: `String.contains("/")` compares graphemes, so a `/` carrying a combining
  mark passes it while the kernel still splits on 0x2F; an embedded NUL likewise passes every
  String-level check and then truncates the C string to the volume root.
- **Correction worth remembering:** `openat`/`mkdirat` is *not* a substitute for that guard. macOS
  has neither `O_RESOLVE_BENEATH` nor `openat2(RESOLVE_BENEATH)`, so an anchored fd still traverses
  `..` in the name argument. What `openat` would buy is closing the path-based TOCTOU on `mp`
  between `isMountPoint` and `mkdir` — a race the filesystem already closes, since `/Volumes` is
  root-owned and SIP-restricted. Low-priority hardening, tracked, not urgent.
- **`--directory` gap, now documented in the CLI:** it is a client-side choice, and the privileged
  helper can only ever create the default. A user registering with a custom directory has to create
  it themselves regardless; the helper refusing a client-supplied path is correct and must not
  change.
- **On "the app should ask for the sudo password" — it should not, and it will not need to.** The
  correct mechanism already exists here: `createVaultDirectory(volumeUUID:)` is implemented in the
  helper, takes a UUID rather than a path, resolves the mount point itself, and chowns an
  `O_NOFOLLOW` descriptor to the uid/gid from the XPC audit token. macOS shows its own
  authentication once, at `SMAppService.daemon` installation; the app never sees a password.
  `OwnershipAdvice` printing a command is the stopgap until the bundle is signed, and says so.
- **F1 corrected: an imported runtime lives outside the MobileAsset store.** F1 said 100 % of
  installed-runtime bytes are in `/System/Library/AssetsV2/...` and that
  `/Library/Developer/CoreSimulator/Images/` holds only `images.plist` and empty dirs. True for a
  runtime Apple downloaded; false in general. After E8's export → offload → `-importPlatform`, iOS
  26.5 reports `path = /Library/Developer/CoreSimulator/Images/<UUID>.dmg` — 9.9 GiB there — while
  watchOS 26.5, never exported, is still in the MobileAsset store at 4.9 GiB. The two locations
  coexist and which one applies depends on how the runtime was installed. Also: the iOS and
  appleTVOS MobileAsset store directories still exist at **4 KB each**, so a store directory's
  presence says nothing about whether bytes are in it.
- **Runtime audit (2026-09-08): no orphans.** Both installed runtimes are in use — iOS 26.5 by
  iPhone 17 Pro Max + iPhone SE, watchOS 26.5 by Apple Watch Ultra 3. 14.8 GB total, none
  reclaimable. Zero `unavailable` devices, Inbox empty (session 2's stranded 5 GB dmg is confirmed
  reaped). The five "skipped runtime image" lines in `clean` were the tool listing each MobileAsset
  store path including the two empty ones — not evidence of waste, contrary to how I first read it.
- **Follow-up (design question, not a bug):** the storage catalog has `Images/Inbox` and
  `Cryptex/Images/bundle` but no category for `/Library/Developer/CoreSimulator/Images/*.dmg`, so
  the category accounting and the runtime accounting reach the same bytes by different routes.
  Adding a category would double-count against the runtime listing in `scan` totals; decide
  deliberately rather than reflexively.
- **The machine's actual reclaim is cleanup, not relocation.** Internal free is ~8.6 GiB
  (`doctor` now CRITICAL, threshold 10 GB). Nothing large is relocatable: the big categories are
  `appleManaged`, `safeCleanup` or must-stay-local. `clean` plans 13.75 GB, of which **3.6 GB is
  user-level** (watchOS DeviceSupport 3.13 GB, SwiftPM caches 484 MB, logs) and **10.12 GB is the
  root-owned CoreSimulator dyld caches**, which need the privileged helper's
  `removeRegenerableSystemDirectoryContents` — listed for accounting, not executable today.
- **FU-1 closed (was the highest-priority follow-up, and the one item `VaultVolume` outright
  failed):** `register` now re-asserts, immediately before the sentinel write, that `mp` is still a
  mount point AND that its volume UUID still matches. Both are needed — the first catches "nothing
  is mounted here any more", the second catches "a different volume auto-mounted into the freed
  path", which answers the first with a cheerful yes. Without this, an unmount between
  `createDirectory(withIntermediateDirectories:)` and the sentinel write lands the vault on the
  *internal* disk at a canonical-looking path, and the writability check approves it because it
  really is ours. New `MountStatus.volumeUUID(at:)` (`getattrlist ATTR_VOL_UUID`, mirroring the
  helper) makes the check cheap enough to run inside the transaction — `VolumeDiscovery` shells out
  to `diskutil` and is far too heavy for that.
  **Caveat I wrote and the test disproved:** the first doc comment claimed the primitive returns nil
  for a non-mount-point. It does not — `ATTR_VOL_*` answers about the *containing* volume, so an
  ordinary directory returns its filesystem's UUID. Comment corrected and the real behaviour pinned;
  callers must pair it with `isMountPoint`, which `register` does (ordering matters).
- **FU-2 closed:** three copies of "read a symlink, resolve it, compare" in `Doctor` are now one
  `PathSafety.symlinkRedirectsBetween`. It closes the fail-open gaps the review listed — chained
  symlinks, doubled slashes, relative destinations, and containment in *both* directions — via
  `realpath(3)` with a lexical fallback for dangling targets. Comparison is case-insensitive on
  purpose: it over-matches, and over-matching only withholds a deletion suggestion, whereas
  under-matching offers to delete a live redirect target. Mutation-verified: reverting to the old
  lexical-only comparison fails the chained-symlink and doubled-slash tests.
- **Review round 2 on FU-1 found three errors in my reasoning, all worth carrying forward:**
  1. "The ordering makes it safe" is **wrong** — `isMountPoint` and `volumeUUID` are separate
     syscalls with a gap, the same class of gap this code closes. What makes it safe is that the
     UUID check is a *positive identity assertion that fails closed*: unmounted-and-gone (nil),
     unmounted-with-the-directory-persisting (boot volume UUID) and different-volume-mounted (its
     UUID) all fail the comparison. **Never rewrite it as `if let now = …, now != uuid { throw }`** —
     that form lets nil pass and silently reinstates the bug.
  2. "Nothing was written" was **false**: `createDirectory` ran before the guards, so a refusal left
     a directory behind, on the internal disk, at the canonical path, in exactly the failure mode
     being guarded. The guards now run before any write, which makes the sentence true, removes the
     orphan and closes FU-3. A `writabilityProblem` refusal is now journalled `.failed`.
  3. My real-machine "verification" **did not touch the new code** — re-register returns early at
     the already-registered branch, before the guards. Zero coverage, unit or manual.
- `register` gained an injection seam (`isMountPoint`, `volumeUUID` closures, mirroring
  `VaultVerifier`). Two reasons: a stub that answers truthfully once and then lies distinguishes
  "caught at the top" from "caught by the guard", and without it the happy path became permanently
  un-unit-testable — the fixtures use synthetic UUIDs against real mount points, which the identity
  guard rejects by construction. **No test had ever exercised a successful `register()`**; all three
  call sites were throws-assertions and every fixture bypassed it via `save(...)`. There is one now.
- `testDiskutilAndGetattrlistAgreeOnVolumeUUIDs` pins the assumption the whole guard rests on: if
  `diskutil`'s VolumeUUID ever disagreed with `ATTR_VOL_UUID`, **every** registration would fail.
  Verified against whatever is actually mounted, so it keeps checking on any machine.
- Mutation-verified: restoring the old order (mkdir before the guards) fails two tests.
- Next: exercise a real relocation into the vault and verify the disconnect path. Note DerivedData
  is currently **0 B**, so it is not a usable subject until something is built; and a migration
  needs no internal free space at all (source internal → destination external, internal usage only
  falls when the verified source is removed). The ~40 GB internal requirement belongs to *runtime
  installs* (E11), which is a different operation — do not conflate them.

## In flight

- Nothing running. 114 tests green.

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

## 2026-09-09 (overnight) — the durable-space path, and three bugs found only by running it for real

Goal of the session: free disk space. Internal free was 14 GiB at the start (up from ~8.6 after
`mac-ssd-rescue` was deleted), and `doctor` reported it as the only WARNING.

**The 10 GB is unblocked and waiting on one command.** `xcodevaultctl runtime export iOS --to
/Volumes/<vault>/XCodeVault/RuntimeLibrary` ran to completion: a 10.6 GB installer now sits on the
vault and internal free never moved off 14 GiB. Nothing was deleted — `runtime offload` is the
destructive half and is deliberately left for a waking human, because it puts the two real iPhone
devices into `Unavailable` until the runtime is re-imported (E11 showed they return automatically,
with no data loss, once it is).

- **F11 (new): exporting an *already-installed* runtime is nearly free internally.** E11's "~7 GB
  peak, watch for ENOSPC" is the **download** case. `preflightExport` told every caller that story,
  which on a nearly-full disk argues the user out of the one operation that frees the most space. It
  now branches on `isAlreadyInstalled` and falls back to the expensive story when the runtime list is
  empty. Measured twice: 1 MB peak in E11, and again tonight — 4.4 GB written to the destination in
  the first 20 s with internal free flat, monitored with an abort guard set to kill the export if
  internal free fell below 7 GiB.

- **Bug, and the reason the 10 GB was still blocked: `RuntimeInstaller.parse` did not understand
  Apple's own export filenames.** Xcode writes `iphonesimulator_26.5_23F77.dmg`; the parser only knew
  the display form `iOS 26.5 Simulator Runtime.dmg`. So `platform` came back nil,
  `installer(for:in:)` matched nothing, and `runtime offload` refused with "NO installer in library —
  export first" while the installer sat in the library. The gate is doing its job — it will not
  delete a runtime it cannot prove is recoverable — which is exactly why an unparsed name silently
  blocks *every* offload. **The fixtures used hand-written display names and passed throughout**;
  this only appeared when the real export was run and its output read. Reverting the fix fails 5
  tests now. The SDK vocabulary was already spelled out in `installer(for:in:)` — the two lists must
  be kept in step.

- **F10 (new): a removed runtime leaves its dyld shared cache behind.** 2.3 GiB under
  `Caches/dyld/25G83/inc/…tvOS-26-5.23L470` for a runtime that is not installed, containing a
  mode-0600 `mkstemp` part file. New rule `checkOrphanedDyldCaches` separates this from the rest of
  the tree, because "rebuilt on next boot" is true of a cache whose runtime is installed — deleting
  it buys a slow boot, not disk — and false of this one. `clean`'s dyld warning now says the same,
  since that line is usually the largest number in the plan and reads as recoverable space.

**Review found three errors in my reasoning on F10; all three are worth carrying forward.**

1. **I inverted this repo's own evidence.** I argued "no BSD file flags + absent from
   `rootless.conf` ⇒ root can delete it" and cited the runtime Inbox as the *contrast* case. The
   2026-09-06 note in FINDINGS records the Inbox file having **both** of those properties while root
   got `Operation not permitted` three times — it is the **counterexample**, and that section ends
   with "`doctor` must not promise a root-only fix". The first version of the rule broke an
   instruction already written down. **Neither check predicts root-deletability on this filesystem.**
2. **The cheap probe is a restart, not sudo.** `kern.boottime` Sep 7 17:39:10 vs orphan mtime
   Sep 7 18:54 — it was created *after* the last boot, so "nothing reclaims it" was a claim about one
   uptime session. What reclaimed the Inbox file was a **startup GC**. If `inc/` is reaped the same
   way the finding shrinks to "transient until restart". The remediation now leads with the reboot
   and offers only `rm -f` of known filenames plus `rmdir` (which refuses on surprises) if it
   survives one. Probe order in F10: reboot → sudo → superseded-build.
3. **A fifth `?? []`-family fail-open, through a door I had not guarded.** I guarded
   `runtimes.isEmpty`, but `runtimeIdentifier` is optional and the decoder enforces no required keys,
   so a non-empty array whose identifiers did not decode produced `installedPrefixes == []` → every
   live cache on the machine reported for deletion. Also: `report.warnings` already carries
   `simctl runtime list failed:`, so my comment claiming the failure was undetectable was false.
   **Guard the derived collection, not the input collection.**

Other fixes from the same review, each of which had produced a deletion command against live data:
`lstat`/`S_IFDIR` was only at level 1, so a plain file (`update_dyld_sim_shared_cache-stderr.txt`,
which really is in that tree) and a symlink were both reported; any unrecognised sibling became "a
stale macOS build" (a directory named `tmp` got a delete command); an unreadable tree printed
"0 bytes" next to one. The stale-build branch now requires a build-shaped name **and** a sibling
equal to this machine's build, is `.info`, and carries no command — it has never fired on real data.
`inc/` entries younger than an hour are assumed live, as a second guard independent of "not
installed". Matching is now `rid + "." + build`, which makes a superseded build's cache visible.

**Test-hygiene note worth keeping:** an unguarded `f[0]` after `XCTAssertEqual(f.count, 1)` traps on
failure and takes down the whole test process, so every other test in the run reports nothing. It
also silently broke a mutation-testing harness that keyed off "Executed N tests". Use `XCTUnwrap`.

**Tracked, not fixed:** (a) an `inc/` entry that also has a newer finished sibling is probably a
leftover rather than work in flight; (b) whether reporting a whole stale-build tree is the right
granularity; (c) the reboot probe itself, which gates F10 and needs a human.

### Review round 2 on F10/F11 — three more blockers, and a pattern worth naming

Every one of these was a *fix from round 1* that moved the bug rather than removing it. That is the
pattern: hardening one level of a walk while leaving the level below it, and answering a
three-valued question with a Bool.

1. **The unrecognised-name hole moved down a level and got worse.** Round 1 hardened level 1 so a
   `tmp` sibling was no longer called a stale build. Levels 2 and 3 got the *type* check but not the
   *name* check — and there the finding carries a `sudo rm`. A directory named `tmp` was reported as
   "a finished cache for a runtime `simctl runtime list` no longer reports", which the rule cannot
   know about a name it does not recognise. Now: a cache directory must contain `.SimRuntime.`
   Applying a guard at one level of a nested walk is not applying it.
2. **The age guard read the wrong mtime.** It used the *directory's* mtime, which freezes once the
   entries are created while the build keeps writing hundreds of MB into them — measured here: the
   iOS rebuild spanned 06:47→07:06 and the tvOS orphan's directory mtime froze 17 minutes after
   birth. So a build running *right now*, for a runtime `simctl` has not reported yet — exactly the
   case the guard exists for — was reported with a delete command. Now: `max(dir, newest child)`, and
   an unreadable mtime is `continue`, not "old enough".
3. **`isAlreadyInstalled` was a Bool answering a three-valued question, and the third value was the
   dangerous one.** `-downloadPlatform iOS` with no `-buildVersion` fetches the **latest**. Answering
   "already installed" because *some* iOS is present told a user with 3 GB free that a 10 GB download
   was free — and suppressed the ENOSPC warning with it, because that warning lived in the `else`.
   **My own new test pinned this behaviour as correct.** Now `ExportCost` has three cases and the
   unknown one warns about both outcomes and keeps the ENOSPC line.

Also fixed: exact `<rid>.<build>` matching now runs only when the tree contains at least one
exactly-named installed runtime, so a machine whose naming differs falls back to prefix matching
instead of orphaning every live cache for that platform; `simctl runtime list` covers disk-image
runtimes only, so an available device now also witnesses its runtime (a runtime bundled in an older
Xcode would otherwise get `sudo rm` offered for a live cache); the remediation was cut from 1310
characters and no longer claims the Inbox's EPERM predicts anything here; `CleanPlanner` no longer
calls the orphan "durable" when durability across a restart is exactly what is untested.

`Doctor` gained an injectable `dyldCacheRoot`, like `home`. Two tests were passing for boilerplate
reasons and are fixed: `testTheRuleIsReachableThroughDiagnose` asserted the *absence* of a finding on
a report that could not produce one, so it passed with the `diagnose` call deleted; and the
unreadable-size test asserted only "no '0 bytes'", which passes vacuously on an empty result.

**Two harness lessons, both of which hid a live mutant for a whole round.** (a) `swift test --filter
"A|B"` prints one summary line per suite, so `grep … | head -1` reports whichever ran first — a
surviving mutant looked killed. Count `error: -[` lines instead. (b) An assertion inside `if let`
is an optional assertion: wrapping the build-string check in `if let build = ios.build` let the
"drop build-string matching" mutant survive. Use `XCTUnwrap`.

Round 2 tally: 26 tests in `OrphanedDyldCacheTests`, 11 in `RuntimeOperationsTests`, 152 total, 0
failures; 9 mutations attempted on the round-2 changes, 9 killed.

### Review round 3 — the same pattern a third time, and what finally broke it

Round 3 found three more blockers, and all three were again *round-2 fixes applied at one level of
the walk but not another*. Naming the pattern in round 2 did not stop me repeating it in round 3;
what stopped it was building the guards so they cannot be applied partially.

1. **The age guard was `inc/`-only.** A finished cache written *this second*, for a runtime `simctl`
   has not reported yet, got a deletion command — the exact defect round 2 removed from level 3 and
   left standing at level 2. Nothing establishes that a rebuild is staged through `inc/` rather than
   written straight into its final directory, and F10 does not measure that either.
2. **`exactNamingConfirmed` was one Bool for the whole tree.** On a mixed tree, iOS naming its
   directory `<rid>.<build>` licensed exact matching for a visionOS runtime named some other way, and
   reported that live cache for deletion. The guard did not remove the round-2 bug; it moved it from
   single-platform trees to mixed ones. Now confirmation is **per runtime and per level** — `<build>/`
   and `<build>/inc/` are two naming conventions and confirming one says nothing about the other.
3. **`inc/<rid>` with no build suffix.** My own code comment and `EXPERIMENTS.md` describe
   CoreSimulator writing that form during an install; `FINDINGS` described `inc/<rid>.<build>`. Three
   documents disagreed and the code failed on the form two of them documented, reporting a live
   in-progress build as "a runtime simctl no longer reports". All three now agree, and the rule
   claims both forms.

Also fixed: the device cross-check had **erased the rule's headline capability** — a device entry can
only prefix-match, and since every machine has devices for its installed runtimes, superseded-build
detection was inert in production; devices are now consulted only for identifiers `simctl` does not
report at all, which is the bundled-runtime case they exist for. The displayed "Last written" date
came from the directory's own mtime — the same frozen value the age guard was fixed to stop trusting,
printed next to a delete command. `exportCost` ignored `architectureVariant`, a third axis answered
by ignoring it. The remediation went from 1205 to 515 characters by binding the path to a shell
variable instead of repeating it four times.

**A over-claim that survived by moving from the code into its citation.** Round 2 removed
"already installed ⇒ free" from `isAlreadyInstalled`; the `.copyOut` branch then cited E11 and F11 as
having measured it. Both runs used **no `-buildVersion`** — they measured the *unknown* branch
resolving to a copy-out. `.copyOut` (reached only with `-buildVersion`) has never been executed
against a real export. Code, FINDINGS §F11 and the compatibility matrix now say inferred, not
measured. **Check that evidence citations cover the branch that cites them.**

Three mutants had survived round 2 undetected and are now killed: `.SimRuntime.` without the trailing
dot, the level-2 hidden-entry filter, and `r.version == want` — the last was dead for every input the
test supplied, because the dashed-identifier branch already answered those cases. A test can pass for
a reason other than the one its name gives.

Round 3 tally: 34 tests in `OrphanedDyldCacheTests`, 13 in `RuntimeOperationsTests`, 162 total, 0
failures; 9 mutations attempted, 9 killed with a corrected harness (count `error: -[` lines — the
round-2 harness reported whichever suite ran first).

**Tracked, not fixed — stated explicitly rather than left implicit (reviewer items 4/5).**
`runtime export --to <dir>` validates the destination with `fileExists(isDirectory:)` only. No mount
check, no volume UUID, no sentinel, though `MountStatus.isMountPoint` and `VaultVolume` exist and
`vault init` already does all three. A stale `/Volumes/<vault>/XCodeVault/RuntimeLibrary` left by an
unclean eject — or a volume that came back as `<vault> 1` — takes a 10.6 GB export onto the **boot
volume at a canonical path**, which is the split-brain case in `MIGRATION_ENGINE.md` and a rule-6
violation. Pre-existing, but this change made it load-bearing: `.copyOut` now tells the user to
"budget the space at the DESTINATION". It belongs in its own change, wired through the same
`VaultVerifier` path `vault status` uses.

### Review round 4 (export destination guard) — I shipped a check that could not fire, and my tests agreed with it

The guard added to `preflightExport` asked `MountStatus.filesystem(containing: destination)?.mountPoint == "/"`.
**That condition is unsatisfiable for the case it was written for.** `/Volumes` is a firmlink onto
the Data volume, so `statfs` reports `/System/Volumes/Data` for it and for every ordinary directory
inside it — never `/`. Verified with my own probe rather than taken on the reviewer's word:

```
/Volumes             -> /System/Volumes/Data
/Volumes/<vault>       -> /Volumes/<vault>
/                    -> /
```

So on every macOS ≥ 10.15 the only path under `/Volumes` that could satisfy it is a symlink to the
boot volume, which is a false positive with the wrong diagnosis. The split-brain case stayed open.

**Both of my tests passed because they hand-built `FilesystemInfo(mountPoint: "/")` — a value
`statfs` cannot produce for any path under `/Volumes`.** I mutation-tested four mutations and killed
all four, and every one of them lived *inside* the injected seam. The defect was in the default
argument, which no test exercised. **A seam does not test the thing it replaces.** Any injected
default now needs one test that passes no seam at all.

The correct implementation was already in the repo: `Doctor+Vault.checkLocationsPointAtPresentVolumes`
takes the first component under `/Volumes/` and asks `MountStatus.isMountPoint(top)` —
`ATTR_DIR_MOUNTSTATUS`, which is what `MIGRATION_ENGINE.md` and the safety checklist ask for. The
rewrite uses that, and the doc comment says in as many words not to reimplement it with `statfs`.

Fixed alongside: fails **closed** now (`isMountPoint` is false when the attribute cannot be read, so
"I cannot tell" refuses) — the earlier "unknown ⇒ allow" reasoning was unsound, because `statfs` can
fail with `EACCES`/`EIO` on a path that exists and is writable, so the existence and writability
guards do not subsume it. Both the literal and symlink-resolved spellings are checked, since a
symlink *into* a vault never mentions `/Volumes` and `/Volumes/<bootname>` stops mentioning it after
resolution. `/Volumes` matching is case-insensitive, which is load-bearing only for a path that does
not exist — measured: `resolvingSymlinksInPath` normalises `/volumes/<vault>/…` while <vault> is mounted
but leaves a non-existent `/volumes/Ghost/…` lowercase.

**The same guard now also gates `runtime offload --library`**, which is the verb that actually
deletes 5–25 GB. With the volume absent and a stale installer in a leftover `/Volumes` directory on
the internal disk, `library(at:)` listed it, `hdiutil imageinfo` read it, and the runtime would have
been deleted against a copy that is not where the user believes — checklist item 1.

**Still not done, and now stated rather than implied:** this checks the mount *shape*, not volume
*identity*. A different drive mounted at `/Volumes/<vault>` passes. `VaultVerifier.resolveUsable`
exists and `MigrationEngine` already uses it; wiring it in when the destination lies inside a
registered vault is the next increment.

**A third harness lesson.** My mutation harness counted `error: -[` lines, so a mutant that makes the
test process *crash* (index out of range) registered as a survivor. Count crashes too. That is three
distinct harness bugs tonight — `head -1` across suites, assertions inside `if let`, and now crashes
— each of which reported a live mutant as dead.

Round 4 tally: 19 tests in `RuntimeOperationsTests`, 168 total, 0 failures; 8 mutations, 8 killed
after the tests were made load-bearing (3 initially survived).

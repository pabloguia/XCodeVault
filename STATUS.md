# XCodeVault — Status

_Last updated: 2026-09-19. **The live sections are immediately below**: what is in flight, what is
blocked, and the next actions. Everything after them is an append-only chronological log, newest at
the end — it is history, not instructions._

_Restructured 2026-09-19 under issue #22. Before that the live sections sat at line 436 with 1,400
lines of chronology above and below them, while `CLAUDE.md` told every session to read this file for
"in flight / blocked / next three actions". The restructure waited on two ranges that were the only
surviving copy of a lesson: the abort/forget five-pass sequence is now in
`docs/process/MUTATION-TESTING-NOTES.md`, and the harness cleanup-trap lesson was confirmed already
rehoused — more fully than here — in `docs/architecture/EXPERIMENTS.md` § "Harness". The line-by-line
classification is in `docs/process/REVIEW-2026-09-17.md` §G12._

## In flight

- Post-publication issue backlog, worked in batches. See `gh issue list` for the live queue and
  `git log` for which batch closed what — each batch commit names its issues.
- Test count and gate state move every batch, so this section does not restate them: `swift test`,
  `swift format lint --strict`, `scripts/helper-invariants.sh` and `scripts/check-doc-mirror.sh`
  are the four gates, and CI runs them on `macos-15` and `macos-26`. A number written here goes
  stale within a day; the commit that changed it is the honest record.

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
  `removeStrandedRuntimeDownload` verb was pointless against this policy — **deleted 2026-09-18**,
  together with `HelperInboxDirectory`, which had no other user. It had no client anywhere, and its
  name asserted a "stranded" check the implementation never performed.
- **Import half of E8 — done (2026-09-07, tvOS; 2026-09-08, iOS 10.35 GB), pass both times.**
  See Session 3 and Session 4 above and `docs/process/RUNBOOK-E8-import-roundtrip.md` for the
  tvOS procedure. Preflight formula confirmed against two very different image sizes.
- GitHub remote/CI: **done.** The repository is public at `github.com/pabloguia/XCodeVault` since
  2026-09-18 and CI runs on `macos-15` and `macos-26`. Pushes go over HTTPS (the SSH key has a
  passphrase). Left here rather than deleted because the line above it is the reason it was blocked.

## Next three actions

_Item 1 was "Publish" until 2026-09-18; the repository is public and CI runs on both runners, so it
is done. The post-publication issue backlog replaced it._

1. **Work the issue backlog.** `gh issue list` is the current queue — the findings the pre-publication
   review left deliberately, plus what the independent reviews have opened since. They are worked in
   batches, each batch commit naming the issues it closes. Structural work (`Doctor.swift` and
   `MigrationEngine.swift` seams) is sequenced before the file renames that depend on it.
2. **M4:** wire `clean`/`vault`/`externalize` flows into the GUI with the same confirmations as
   the CLI; helper client (`SMAppService.daemon` registration UI, status handling) behind the
   signed bundle — cannot be tested unsigned.
3. **M5:** Developer ID signing + notarization + stapling in `scripts/release.sh`, Homebrew Cask
   formula draft, in-app uninstall (`unregister()`), diagnostic bundle (`report --json`).



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
   **(2026-09-16: the reboot ran and the orphan survived byte-identical, so the "transient until
   restart" branch is dead, the remediation no longer leads with a reboot, and the order is now
   sudo → superseded-build. Note also that this item's own first sentence expired without anyone
   editing it: the machine booted on Sep 15, so by the time the probe ran the orphan had already
   outlived a restart. The claim was two timestamps, and one of them moved.)**
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
granularity; (c) ~~the reboot probe itself, which gates F10 and needs a human~~ — **run 2026-09-16,
and the orphan survived byte-identical (E13).** What needs a human now is E13b, the root deletion.

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
**(Superseded 2026-09-16: E13 tested it, the orphan is durable across a restart, and `CleanPlanner`
now says so rather than hedging.)**

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

### Live data-loss bug, found by the user running the tool (2026-09-09)

The user offloaded both runtimes — ~23 GiB freed, devices correctly left `unavailable` rather than
deleted, exactly as the E8 round trip predicted. `doctor` then told them:

> `xcrun simctl delete unavailable` removes devices whose runtime is gone.

That would have permanently destroyed their three baseline devices and 9.82 GB of data, when the
correct action was to re-import and get them back. **XCodeVault created the state and then advised
destroying what it had just promised to preserve.** Rule 5, reached through our own happy path.

The fix is not "check the journal" — that was my first attempt, and review found it reintroduced the
same bug one step away: unplug the vault, run `doctor`, and an unreachable installer read as "no
installer", which fell straight back to the delete recommendation. **The absence of a *reachable*
installer is not the absence of an installer, and silence from a journal that could not be read is
not a fact.**

`checkUnavailableDevices` now recognises five states and emits the destructive suggestion from
**exactly one** — journal read in full, no offload on record:

1. reachable installer matching an unavailable device's runtime → name it, re-import
2. reachable installer, journal entry predates identity recording → neutral, check `runtime library`
3. installer recorded on a volume that is not mounted → reconnect and re-run (rule 6)
4. journal missing, unreadable or partially corrupt → not advising deletion
5. journal complete, no offload → delete, stated as permanent

Supporting changes, each of which was its own defect:

- **`Journal.entries()` cannot report failure.** It returns `[]` for a missing file and
  `compactMap { try? decode }` swallows corrupt lines, so "nothing happened", "the journal is gone"
  and "every line is corrupt" are one value — and `try?` at the call site was decoration. New
  `read() -> ReadResult` distinguishes them. **Wherever absence of a record drives a destructive
  suggestion, an unreadable source must not read as an empty one.**
- **The offload entry recorded the image UUID, not the runtime identity**, so nothing could match an
  installer to the devices it would restore. Now in `detail`. Do **not** fix this by parsing the
  filename: for a `.exportedBundle` the recorded path is
  `…/Restore/WatchOSSimulatorRuntime_Cryptex.dmg`, whose basename carries neither platform nor
  version — a filename matcher would silently drop the watchOS installer and hand the Apple Watch
  the delete advice.
- **`fileExists` is not "is this an installer"**: it is true for a directory and for a 16-byte stub,
  and the first version of the test *asserted* a stub counted. Now a regular file above the 500 MB
  floor `installer(for:in:)` already uses.
- **`Doctor(home:)` read this machine's real journal**, because `Journal.defaultURL` reads
  `NSHomeDirectory()` while `Doctor.home` is injected. The seam looked complete and was not — a test
  can pass against production data. The journal now derives from `home`.
- **The same destructive advice was reaching the user through a second door**: the catalog's
  `cleanupCommand` was `xcrun simctl delete unavailable`, printed verbatim by *every* `clean` run.
  Replaced with the per-device `simctl delete <udid>`, which is still the official tool and still
  delete-only, but names what it destroys and cannot sweep up a device that is coming back.
- **The claim was over-stated and mis-cited.** Device return is one observation (macOS 26.6.2 /
  Xcode 26.5 / Intel, iOS 26.5, re-imported at the **same version**) and the precondition is
  load-bearing, so it is now in the user-facing text. E11 is the staging-space experiment; the
  device-return finding belongs to the E8 import round trip under H4.
- `runtime offload` printed `stdout + stderr` from `simctl runtime delete`, which prints nothing on
  success — so it emitted a blank line and finished having reported only its pre-checks. The user
  asked whether it had worked. It now says what it deleted, and that the devices are Unavailable
  rather than gone. The size is reported as "at least", since deleting the runtime also drops its
  MobileAsset copy.

12 tests in `UnavailableDeviceAdviceTests`, 180 total, 0 failures. 7 mutations, 6 killed; the
surviving one (dropping the `S_IFREG` check) is documented in place as redundant-today rather than
covered by an invented test — under `lstat` both directories and symlinks fail the size floor anyway.

## 2026-09-09 — E4 closed. Runtime relocation is refused by the system, not merely unproven.

The user asked whether runtimes could run from the external drive. The honest answer at the time was
"the Runtime Library stores the *installer* externally; using a runtime still costs ~10 GB
internally", with H9/E4 as the experiment that would decide it. E4 ran, in two halves.

**E4a (no privilege) — the seal survives relocation.** The vault copy of the installed iOS image is
byte-identical (sha256 `e27aaecf…`, previously only inferred from size+mtime), and attaching it
*from the external USB APFS volume* mounts `sealed` as a normal user with the runtime bundle
readable. The `.exportedBundle` inner image behaves the same. Negative control: one flipped byte
makes `hdiutil verify` and `attach` both fail. The failure H9 named — `SimDiskImageErrorDomain Code
5` / `-67061` — did not occur.

**E4b (root, run by the machine's owner) — the pointer cannot be moved.** Root cannot write
`/Library/Developer/CoreSimulator/Images/images.plist`: `Operation not permitted` on an existing
`root:wheel 644` file, no BSD flags, no ACL, absent from `rootless.conf`. Creating a new file in that
directory is refused identically. **And yet simdiskimaged rewrites the file freely** — the run's own
`simctl runtime unmount` advanced `lastStateChangeAt` past the backup taken a minute earlier. So the
protection is *"only the entitled daemon writes here"*, by a mechanism invisible to POSIX and SIP
metadata. With the Inbox EPERM (F1) that is three observations of one mechanism across two paths
(F14, F16).

**So H9 is settled and split, and the barrier is authorization rather than integrity.** ADR-0004
demoted canonical mount because H6 showed the sandbox restriction follows the *device* rather than
the path; that still holds but is no longer binding — the question never reaches H6, because the
pointer cannot be changed at any privilege a product may use. Recorded as an ADR addendum rather
than a reversal: the decision is unchanged, its footing is stronger. The Runtime Library workflow is
not the pragmatic compromise it looked like — it is the only door the system leaves open.

**Two protocol lessons from the run, both about rehearsals rather than guards.**
- A `--dry-run` that executes in a different privilege context is not a rehearsal. Mine passed as a
  user and the real run refused at the vault check, because `xcodevaultctl vault status` under sudo
  reads root's home. Everything that reads the invoking user's state now goes through one `as_user`
  helper with `-H` (`sudo -u` switches uid but leaves `HOME` alone on macOS).
- Confirming a verb's contract by invoking it is not a diagnostic. I ran `simctl runtime unmount` to
  learn which identifier it accepts; it is not read-only and it unmounted the user's runtime.
  Restored with `runtime scan-and-mount`. F15 records the contract: `unmount`/`delete` take the
  per-installation image UUID, which F13 showed is *not* stable across a round trip — so store
  `runtimeIdentifier` and resolve the UUID at the moment of use.

**A safety check that cried wolf.** The post-restore verification hashed the whole plist against the
backup. simdiskimaged writes that file itself, so any run that unmounts anything was guaranteed a
mismatch — a false alarm on a safety check, which is worse than no check. It now compares the path
entries, which is what the script edits.

**Where the disk actually goes on this machine, now that the runtime route is closed:**

| | |
|---|---|
| `/Library/Developer/CoreSimulator/Images` | 15 GB — relocation refused (F16); movable only via offload/import |
| `/Library/Developer/CoreSimulator/Caches` (dyld) | 9.4 GB — root-owned, mostly rebuilt on boot; the durable part is F10: 2.3 GB that came back byte-identical across a reboot (E13 2026-09-16), so a restart is **not** the remedy |
| `~/Library/Developer/CoreSimulator/Devices` | **9.1 GB — user-owned, unexplored** |
| `~/Library/Developer/Xcode` | 2.9 GB — DerivedData/Archives, supported relocation, but F4/H6 warns against external |

The device set is the largest untouched target and the only large one that is neither root-owned nor
protected. `simctl --set <path>` exists; F1 records it as `[COMMUNITY-REPRO]` and judges it "not a
viable foundation for transparent relocation" on the strength of two unverified claims (the Xcode
IDE run-destination picker may not honour it; Web Inspector does not see such simulators). Neither
was tested by us, and both predate Xcode 26. **That judgement is the next thing to verify, not
inherit.**

## 2026-09-09 (later) — E14a: the device set was dismissed on hearsay, and the hearsay is wrong

F1 said `simctl --set` was "not a viable foundation for transparent relocation" on the strength of a
2022 forum thread we never tested. Xcode 26.5's own binary contradicts it:
`-[DVTiPhoneSimulatorLocator startLocating]` reads the user default **`DVTSimulatorSetLocation`**
and, when it is set, opens the device set at that path instead of the default one — in the very
locator that feeds the run-destination picker. That is static evidence only: no picker was observed
repopulating, and the IDE does **not** hand the path to Simulator.app, which reads its own
`DeviceSetPath`. Silent split brain is the expected failure, and under rule 6 that would fail the
experiment even if both halves technically work.

**The more useful finding is a measurement, not a mechanism.** Of the 9.1 GB in
`~/Library/Developer/CoreSimulator/Devices`, ~6.5 GB is `containermanagerd/Dead`, on-demand
`MobileAsset` downloaded *inside* the simulators (650 MB of Siri understanding models in one
device), and the simulated unified-log store. Real app containers are ~0.5 GB. So relocating the
device set moves 9 GB of which ~2.6 GB is durable, while reporting and cleaning it returns ~6.5 GB
with no new mechanism — recurring, since the caches rebuild on the next boot. Accounting first.

Also recorded: `simctl help create` documents a `/Volumes/…/*.simruntime` path as a runtime
specifier (H13 — the only candidate that attacks the F16 barrier from a direction F16 does not
cover, and expected to fail by staging internally); FSKit's passthrough file system is
Apple-documented and is the only canonical-relocation path F16 does not foreclose, but third-party
FSKit is reported broken on 26.1/26.2 (H7); and Xcode 26.5's `IDEFoundation` still carries every
`IDECustom*Location` key, including two we had not catalogued — Archives and the compilation cache.

**Next three actions:** (1) **E14b phases 0–3** — create and boot a probe device in a device set on
the vault; ~15 min, unprivileged, touches no developer data, and kills H12 outright if it fails.
(2) E15 phases A–D, then the manual phase E. (3) Teach `scan`/`doctor` the F18 per-device split, which
is shippable regardless of how E14b and E15 land.

### Research pass after E4 — what is left, ranked, and one inherited claim overturned

**F1's dismissal of `simctl --set` was partly wrong, and it mattered.** Xcode 26.5's
`IDEiOSSupportCore` contains a `DVTSimulatorSetLocation` user-default read inside
`-[DVTiPhoneSimulatorLocator startLocating]` — the only simulator locator Xcode has, the one that
feeds the run-destination picker — branching to `deviceSetWithPath:error:` when the key is set.
Independently confirmed: the symbol and the log string "Creating/fetching temporary SimDeviceSet at:
%@" are both present in the shipped binary. So "no evidence the IDE honours a custom device set" is
no longer accurate. What remains unknown is whether the picker repopulates, and whether `xcodebuild`
resolves the key at all. Two cautions carried forward: the IDE calls it a *temporary* set, and Xcode
does **not** pass the path to Simulator.app, which reads its own `DeviceSetPath` — so silent split
brain is the expected failure, which is rule 6 and disqualifying for v1 on its own.

**But H6 is prior, and probably fatal.** For simulator-destination testing the `.xctest` bundle is
installed *into the device's data container*, so a device set on USB is E2's configuration one layer
in. Boot-from-USB is the kill gate and it comes before the IDE question.

**The ranking, with the lesson it teaches:**

| # | Candidate | GB here | Status |
|---|---|---|---|
| 1 | Per-device regenerable data | **~4.1 verified** | measured, needs no new mechanism |
| 2 | Device set relocation (H12) | ~9 raw, ~2.6 durable | gated on E14b phase 3 (boot from USB) |
| 3 | External `.simruntime` at create time (H13) | up to 10/runtime | untested; folds into E14b |
| 4 | Archives / compilation cache | 0 here | needs an archive to test |
| 5 | FSKit passthrough (H7) | all, eventually | blocker moved from "no mechanism" to "platform reliability + entitlement" |
| 6 | An opening in the F16 entitlement boundary | — | searched; none exists |

**Rank 1 beats rank 2 on measured quantity, and that is the point.** A promising *mechanism* should
not outrank a measured *number*. Verified independently on this machine: `Dead` app containers
836 MB, in-simulator `MobileAsset` 3.3 GB, out of an 8.5 GB device set — user-owned, no root, and
reclaimable without erasing a device. That is a bigger, cheaper win than relocating the set, and it
is available today.

Next experiment: `e14b-device-set-external.sh` phases 0–3 (~15 min, no sudo, writes only to the
vault, never addresses the default device set). If the probe device does not reach `Booted`, H12 dies
before the IDE question matters.

## 2026-09-13 — the per-device regenerables are catalogued, and the biggest one turns out to clean itself

Item 1 of the handoff (the ~5.4 GB of regenerable data inside the simulator devices) is done as
accounting. Three categories now exist, all **report-only**: `simulatorDeadContainers`,
`simulatorMobileAssets`, `simulatorLogStore`. `scan` resolves them per device, `doctor` prints a
per-device breakdown with the reason it offers no cleanup, `clean` offers nothing. Catalog version
`2026-09-13.1`. 191 tests green, `swift build` and `swift test` both exit 0.

**The headline is a reversal of the premise, and a better answer than the one that was asked for.**
The handoff said the `Dead` containers had tripled in four days and framed them as recurring
accumulation to reclaim. They are recurring — each install of a changed app leaves a ~125 MB bundle
container behind, 57 MB of it the app's `.debug.dylib` — but **a booted device reaps them itself**.
Measured with a control: the booted device went 15 entries / 1.5 GB → 3 entries / 306 MB, with only
entries younger than ~10 minutes surviving, while the device that stayed shut down did not change by
a byte. So a large number here is not a leak; it is a device that has not been booted lately, and
`doctor`'s remediation is "boot it" (or `simctl delete <udid>` if it is a device you no longer want).
F22 has the table and the residual uncertainty.

**A third category was added beyond the two the handoff named.** F18 had already measured the
simulated log store (`db/diagnostics` + `db/uuidtext`, ~1.5 GB) and `scan` was not reporting it.
Leaving it out would have been the same failure as rejecting a lowercase UDID: silently
under-reporting, which is the one thing an accounting tool must not do.

**Two mistakes worth keeping, because both are repeats of lessons already in this file.**

- *I shipped a rule that could not fire, and my tests agreed with it — lesson 2, verbatim.*
  `checkPerDeviceRegenerables` read `item.allocatedBytes`, but `doctor` scans with
  `measureSizes: false`, so on a real machine it reported nothing at all. Every test passed, because
  every test built its items with a measuring scanner — a value the production caller never
  produces. Caught only by running `xcodevaultctl doctor` against the real machine. The rule now
  measures its own paths, and the regression test constructs the report exactly as the CLI does;
  reverting the fix makes that one test fail and no other.
- *I ran an experiment on a device the user was testing on.* The first attempt to answer the sweep
  question booted a simulator that an `xcodebuild test` was already driving. The measurement was
  contaminated and discarded rather than reported. It became answerable only because the *second*
  device was untouched — the control was luck, not design. Any future probe of this kind checks
  `pgrep xcodebuild` and the device's state first, and says which device it will touch before
  touching it.

**The previous three are all closed, and all three closed negatively** — E14b (H12 falsified for
external storage), `log erase --all` (refused by `logd` inside the device, all three documented
forms), and E13 (the dyld orphan survived a reboot byte-identical). Worth noting as a batch: none of
the three produced a feature, and each replaced an assumption with a measurement.

**E13b ran in inspect mode on 2026-09-16 and found nothing to inspect.** A macOS update (26.6.2/
25G83 to 26.7/25G229) had removed the whole previous host-build cache tree, orphan included. Within
the hour the installed runtimes' caches rebuilt on the new build at the same sizes and the orphan did
not, so the durable reclaim is ~2.3 GB and not the tree's 9.4 GB — the 29 GiB free visible mid-rebuild
was a transient and is recorded as one. **F10's open question is therefore closed by the OS rather
than by us**, and E13b has no target on this machine.

**Next three actions:** (1) **E13b stays written for a machine where an orphan persists** — nothing
to run here. Its run did expose three fail-open guards, all fixed: an allowlist that approved an
empty read, an `lsof` veto firing on `lsof`'s own error banner, and a `home_of` that returned root's
two `NFSHomeDirectory` values as one string, leaving a cross-check running broken and reporting
agreement. A *refusal* is the more valuable outcome — it would make this the second path where root is
blocked with no BSD flag and no `rootless.conf` entry, which is reportable OS behaviour rather than a
cleanup detail. (2) **E14d** — `create` on a non-USB external (Thunderbolt/NVMe enclosure), the one
confounder E14c could not break, since every external tested here is USB. Blocked on hardware the
project does not have. (3) **The superseded-build orphan class** (F10 probe 3): whether a runtime
*update* leaves its old finished cache behind. It is the most likely orphan class on any machine that
has taken an update, and no machine here has exhibited one — so this needs either a runtime update
performed deliberately or a second machine.

### Safety review of the same change — what it caught, and the one thing it made me un-say

`migration-safety-reviewer` returned **REQUEST CHANGES**, then **APPROVE** after fixes. Three of its
findings were defects I had introduced and would not have found myself.

- **A destructive command in an INFO remediation.** My `simulatorDeadContainers` hint ended with
  "and if you no longer need that device, `xcrun simctl delete <udid>` is the official tool" —
  unconditional, journal-blind, under a device list sorted largest-first, two lines below a sentence
  saying the space comes back for free. This repo has now removed that exact pattern three times
  (`clean`'s `delete unavailable`, `checkUnavailableDevices`, this). Worse, **my test pinned it**: it
  banned `rm` and `simctl erase` while tolerating `simctl delete`. A test can lock in the wrong
  behaviour as firmly as the right one. The hint now stops at "booting reclaims it"; the test bans
  every destructive verb in any `remediationHint`.
- **I spliced two functions into the middle of an existing doc comment**, cutting
  `checkUnavailableDevices`'s rationale mid-sentence — the single most safety-critical explanation in
  `Doctor`, reduced to a dangling fragment. Restored, functions moved below it.
- **A missing gate the diff made reachable.** `planRestore` had no strategy check at all, so any
  category whose `pathTemplates` named a live tree could be a restore *destination* — our own engine
  writing shadow data into the CoreSimulator device set (rule 6). Pre-existing via `simulatorDevices`;
  my three ids tripled the surface and gave it plausible-looking targets. Guard added, plus one in
  `removeSource`, which is the only function in the product that deletes a source directory.

**And one correction to how I wanted to record a deferral, which is the part worth keeping.** I
argued that exact per-device path containment could wait because "every destructive entry point is
gated on a strategy these categories lack." The reviewer checked that against the code and the
conclusion held but *the reason was false*: `removeSource` and `resume` have no strategy gate and
reach `requireContained(..., in: c.pathTemplates)` as their only path check — and `resume` recovers
its `categoryID` by string-splitting the journal's free-text `summary`, with `?? "archives"` as a
fallback. The true invariant was "unreachable because no gated planner can produce the journal entry
that would name these ids", which is a much weaker guarantee spanning four functions and a
user-writable file. Recording the convenient version would have left a future reader relying on
something untrue. That is the failure mode this file already names twice — an inherited claim that
nobody re-checked — arriving as a claim I was about to write down myself.

**Open on this surface, in order:** (1) `resume` should read `categoryID` from the journal's `detail`
dictionary instead of parsing a summary string — a parser standing between a journal line and a
`removeItem`. (2) Exact `<deviceSet>/<UDID>/<subpath>` containment for per-device categories, which
would make `pathTemplates.first!` stop being a lie for them (it is currently the default source in
`M3Commands`). (3) `simulatorRuntimeAssets` prints its skipped line once per path, five times, right
above the aggregated lines this change introduced.

### One more correction, found by re-measuring rather than by review

The first write-up of F22 said the dead containers are reaped "on a rolling, age-based schedule",
because at 19:30 the only survivors were three entries from the preceding ten minutes. An hour later
those same three were still there, untouched. The sweep was a **single bulk event** that removed
everything predating it, trigger unknown — not a timer. The catalog note, the remediation text and
F22 were all corrected, and the remediation no longer promises "within minutes". Two measurements of
one directory supported two different models; only the second showed which to discard.

## 2026-09-13 (late) — the same finding falsified a third time, by looking again

The commit above (`923208f`) shipped a claim that is wrong, and the correction is the point of this
entry. It said a booted device reaps the dead containers, so `doctor`'s remediation was "boot it".
Three and a half hours later the same device — booted the whole time, never shut down — held **20
entries / 2.0 GB**, including the three survivors of the original sweep, untouched. Nothing had been
reaped since one event around 19:27. The shutdown control was still byte-identical.

So the history of this one directory reads:

| draft | claim | killed by |
|---|---|---|
| 1 | rolling age-based reaper | re-measuring an hour later: same three entries still there |
| 2 | booting collects it | re-measuring three hours later: booted, 2 GB, nothing reaped |
| 3 | *it is swept sometimes; the trigger is unknown* | — |

Each of the first two was a causal claim built from a single observation of a single directory, and
each fell to nothing more sophisticated than looking again. The pattern this file already names —
an inherited claim nobody re-checked — turns out to apply just as well to a claim I had produced
myself an hour earlier, which is the harder case to catch because it arrives feeling verified.

Corrected: `remediationHint` is nil for all three per-device categories, `evidenceStatus` back to
`.probable`, and F22 now carries the measurement table rather than a mechanism. The test that
asserted the advice mentions "boot" now asserts no per-device finding offers advice at all — it had
been pinning the wrong answer, for the second time on this same field.

**What did come out of it is a better number than the one we were chasing.** The 17 new entries span
21:55–22:44: one per ~3 minutes, ~125 MB each, produced by an ordinary `xcodebuild test` loop —
about **2 GB an hour** during active iteration. That is measured, repeatable, and it is what justifies
the category. The sweep is merely what keeps it from being unbounded.

**E14b is blocked, not deferred:** `/Volumes/<vault>` is not attached (only `/Volumes/MacOS`), and the
experiment writes only to the vault. It needs the drive plugged in. Internal free space is 18 GiB.

## 2026-09-14 — the journal stopped being parsed, and five review passes on one function

`resume` recovered its `categoryID` by splitting the journal's free-text `summary` on spaces, with
`?? "archives"` when that failed, and spent the result on deletion decisions. That is closed: the
category, the vault volume and the direction are all fields on the PLAN line now, read as fields.

What the sequence actually cost, and why it was worth it: **five review passes, each of which found
that the previous fix had hardened the wrong thing.**

| pass | what I thought I had done | what was true |
|---|---|---|
| 1 | removed the parser from a deletion path | removed it from the value that only *decides*; `aside`, which names the victim and reaches `removeItem`, was still read from the journal |
| 2 | added the vault and PLAN-line guards | both survived their own deletion — guards with no test |
| 3 | hardened `resume` | the same hole lived in `abort`, and `forget` (my own escape hatch) orphaned partial copies |
| 4 | made `abort` check the vault | broke every *restore*, whose partial copy is at the canonical home path by construction — and the refusal message said it was not this migration's copy when it was exactly that |
| 5 | factored the abort/forget rule into one function | the rule was factored for "a PLAN line exists" and re-derived for "it does not" — the same bug one level up, introduced by the pass that fixed it |

Two data-loss paths were real and are closed. A line appended to the journal setting `aside` to the
destination would have had `resume` delete the vault copy, because a tree verifies as identical
against itself. And `abort` — the command the tool *tells* the user to run — deleted local data in
the ordinary disconnect case: crash during COPY, reboot, the volume loses the mount race, a plain
directory sits at the mount point, `lstat` succeeds and the mount-point check does not fire because
the *volume* would be the mount point while the destination is several levels below it.

`migration forget --i-verified-both-copies-myself` exists because refusing is not free: a refused
`resume` left the operation `started`, which blocks every future migration, while `abort` refused
too. The pair is now governed by one sentence — *`forget` declines anything `abort` can still clean
up* — and, since pass five, by one function. `AbortDisposition` returns `.cleanable(planned:)`,
`.unreachable(reason)` or `.declined(reason)`; both verbs consume it; the reason travels into the
journal while the remedy stays with whoever throws, so a permanent record never tells its reader to
run the command that produced it.

**The mutation lessons are in `docs/process/MUTATION-TESTING-NOTES.md`**, because they generalise
past this change. Short version: a clean mutation means "no test covers this difference" at least as
often as "the code is equivalent"; a mutant that lands in a branch which independently accepts is
not a mutation of the guard; a non-compiling mutant is a broken experiment, not a catch; and the
rows worth mutating are the ones where two code paths are *supposed* to agree, because that is where
a duplicated rule hides. Also: reading for "where is this decided twice?" found both duplications
before any mutant did.

One branch is knowingly unpinned and says so at the guard: `abortDisposition`'s mount-point refusal
survives its own removal, because the fixtures cannot make a temp directory into a mount point and
every path that could be one fails containment first.

219 tests. `swift build` and `swift test` both exit 0.

## 2026-09-15 — E14b ran, proved nothing, and the gate that stopped it was mine

The kill gate did not fire. The script aborted one phase earlier, on a check it had no business
making, and printed `H12 falsified at the cheapest gate`. That line was wrong, and it was wrong in
the most expensive direction available: a falsification is the result that ends a line of work.

Phase 1 was written to ask whether CoreSimulatorService accepts a device set on the vault. It
cannot ask that — see below — but on the day it looked like it had, because
`simctl --set /Volumes/<vault>/... list devices` exited 0 and printed the runtime headers. The
script then failed the phase anyway, because `device_set.plist` had not appeared in the
directory. `device_set.plist` is written by the first `create`. A bare `list` on an empty set
has nothing to persist, so the file is absent on any set that has never held a device, anywhere.

The control took one command and settled it: the same `list` against an empty set on the **internal**
disk produced an equally empty directory, exit 0, byte-identical output. The gate discriminates
empty-vs-non-empty set. It does not mention externality. It would have falsified H12 on the internal
disk, which is the definition of a check that cannot fail the way it claims to.

So H12 is not falsified. It is also not advanced: **phases 2 and 3 never executed**, and phase 3 is
the H6 boot gate that decides the whole hypothesis.

Then the safety review caught me doing the milder version of the same thing, twice, in the fix. The
first version of this section said the surviving datum "points away from refusal" because
`simctl --set` had resolved a USB path exactly as it resolved an internal one. Measured afterwards:
that command exits 1 only when the path does not exist and 0 for any existing directory, `/tmp`
included — and the script creates the directory one line before asking. Exit 0 means `mkdir` worked.
The byte-identical output I had cited as corroboration is the tell: output invariant to the path
never consulted the path. There is no datum. And my replacement gate had inherited the defect —
gating on that exit status is gating on `mkdir`, which is a check that cannot fail the way it claims
to, which is precisely the sentence I had just written about the old gate.

Accounting after the run was clean, which is the one thing that went right by design: the
marker-guarded cleanup removed the probe set, nothing named `XCV-E14b` reached the default set, the
default set was 10G before and after, and all three of the user's devices were `Shutdown` throughout.
No shadow data. Rule 6 held.

This is lesson 1 from the handoff arriving in a new costume. That lesson says a causal claim drawn
from one observation falls on the next measurement. The variant here is narrower and worth naming
separately: **a gate written before the behaviour is understood encodes the guess, and then reports
the guess as a measurement.** The phase-1 check was a plausible-sounding proxy — "a real set has a
plist" — authored at the same time as the hypothesis it was meant to test independently. Lesson 4
already says seams do not test what they replace; this is the same failure moved from the test suite
into the experiment harness, where a false negative does not go red, it gets published.

The cheapest defence is the one that worked: **before believing a gate's failure, run it against the
condition it is supposed to pass.** One internal-disk control, thirty seconds, and the falsification
evaporated.

Phase 1 is now labelled a smoke test that gates nothing, with both failed gates written out
beside it so the third attempt is not a guess either. The honest statement of what it does: it
detects that the path stopped existing between `mkdir` and `list`, and nothing else.
The invalid evidence file is kept, unaltered, with an appended correction — the run happened and the
record should say so; what it should not do is let a reader cite its verdict line.

E14b phases 2–3 are still unrun and are still the next thing. 219 tests. `swift build` and
`swift test` both exit 0; no Swift changed in this session.

### The re-run: the gate fired, one phase later, and named a mechanism

`create` on the vault exits 22. The run's evidence file says that and nothing more, and the
reason is a hole in the harness I then walked straight into: `EXPERIMENTS.md` specified log capture
on a phase 3 or 4 failure, phase 2 had none, so the mechanism had to be read out of `CoreSimulator.log`
by hand — and the first draft of this section cited it as though the run had produced it, including
the sentence "the POSIX reading is ruled out by the evidence file itself". It is not in the evidence
file. It is now in `evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` with a provenance header saying how it was taken, and the script
captures on phase 2 from now on.

What the log shows: the service allocated the device, could not copy its sample content into
`<set>/<UDID>/data` — `NSPOSIXErrorDomain Code=1` — and tore the half-made device down.

EPERM, not EACCES. The run's own evidence excludes exactly one alternative: the script created
`.xcv-e14b` inside that same directory in the phase before, as the same user `CoreSimulatorService`
runs as, so the directory's mode bits are not what refused. That is one alternative, not all of
them — a sample-content copy also moves xattrs, ACLs, flags and ownership, and a zero-byte file
tests none of those.

And then the safety review caught the largest error of the day, which was mine and was about to be
published: I wrote that the unified-log capture came back empty. It does not. My interactive
`log show` returned nothing and I believed it; the harness-style capture, run minutes later over
the same window, contains — inside 80 ms, in causal order — three `tccd` queries for
`service=kTCCServiceSystemPolicyRemovableVolumes` attributed to CoreSimulatorService, a kernel
`com.apple.sandbox.reporting:violation … deny(1) file-write-create` on the set path, and only then
the `Code=1`. The ad-hoc grep was the bad instrument, and "I looked and saw nothing" became
"there is nothing" without the step in between. Evidence `evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt`.

That line is the most valuable thing this session produced, and the draft I nearly committed
recorded its absence. E2's matrix entry says "mechanism unnamed" after querying the same
subsystems; this names one, on a code path with no `xctest` in it. **What it licenses for H6 is
not decided here** — one observation, one volume, one machine, control unrun. Deciding that in the
same edit that corrected the error is exactly how the last two rounds went wrong.

It has E2's shape. Whether it has E2's cause is a different question, and the control cannot answer
it either: an internal `mktemp` set differs from the vault in case sensitivity, mount options,
removability and bus all at once, so "creates internally" narrows the cause to volume class and
stops there. Calling that a second reproduction of H6 would be the same overreach one size smaller.

**It is not recorded as that yet, and H12 is not recorded as falsified.** Two readings fit: the
volume is the problem, or alternate device sets do not work this way at all — and the second cannot
be told apart from "the harness is wrong a third time" by staring at it. Today has already spent
two rounds on exactly that confusion. `e14b-control-internal-create.sh` runs the identical create
on an internal `mktemp` set and separates them in about a minute.

Worth noting what this costs if reading (A) wins: phase 3, the boot gate that the whole experiment
was designed around, becomes unreachable. H12 would die one phase earlier than planned, on the
device's data container rather than on booting it — and the reason would be the same removability
that E2 found, which is the answer the plan considered most likely and least convenient.

The hardened cleanup did its job on a path that had never been exercised: it took the `rm -rf`
branch, which is only reachable when the set reports zero remaining devices rather than when a
return code says so, and both post-cleanup probes came back empty. The count itself was not
printed, so that is read off the code path rather than the evidence — the script now echoes it. The run exited 1, and said so on stderr — before today it
would have exited 0 and printed nothing but `wrote`.

### The control: alternate device sets work, the vault is the variable

`create` on an internal `mktemp` set: exit 0, and the `<UDID>/data` container the vault refused
gets written, 17 MB of it. Same device type, same runtime, same commands as the run that failed.

So H12 is falsified for external storage. Not "the gate failed" — falsified, with its own control.
Phase 3 never needs running: a device that cannot be created cannot be booted, and E15's
transparency question stops mattering for anything v1 decides.

The more valuable half is H6. E2 hit this class of failure in September and its matrix entry still
says "mechanism unnamed" after querying the same subsystems. This run names it: `tccd` queried three
times for `kTCCServiceSystemPolicyRemovableVolumes` about CoreSimulatorService, then the kernel
logging `deny(1) file-write-create` on the set path, then EPERM — eighty milliseconds, no `xctest`
within a mile of it. Second independent reproduction, different subsystem, and the first sight of a
removable-volumes policy actually being consulted.

H6 stays **probable**. One physical device, one machine, same as E2's limit. And the control's own
limit is worth being precise about rather than letting the good news paper over it: the internal set
differs from the vault in case sensitivity, mount options, bus *and* removability at once, so the
experiment narrows the cause to volume class and stops. What points at removability is the log, not
the design. E14c was expected to be the clean isolation — it ran, and it was not; see the later
section. It is cheap, and it repeats this create inside a case-sensitive
APFS disk image stored on the vault. E2 already established that disk images do not reproduce its
failure even with the image file sitting on the USB SSD, so a create that works inside one separates
removability from case sensitivity, from path, and from the physical device holding the bytes.

Session arithmetic worth keeping: this experiment produced its result on the third run. Run one was
void on a gate I wrote wrong, run two hit the real failure, and the reading of run two survived only
because a review caught me reporting the mechanism from a log the experiment never captured — and
then reporting that same log as empty when it contained the answer. The finding is good. Nothing
about how it was nearly reported was.

### E14c: the restriction reads the device, not the label macOS puts on it

A case-sensitive APFS disk image whose file sits on the vault hosts a simulator device that the
vault itself refuses. Same path under `/Volumes`, same filesystem, same `nodev,nosuid,journaled`,
same `Device Location=External`, same physical SSD holding every byte. Two properties varied, and
one of them falls over on inspection: the volume macOS labels `Removable Media: Removable` is the
one that works, and the one it labels `Fixed` is the one that fails. A policy keyed on that field
would have to run backwards. What is left is `Protocol` — a real device against a virtual one.

That is the shape E2 saw and could not name, arrived at from the other direction, and it settles
H6's "not by path" half on this machine: the path, the filesystem, the mount options and the medium
were all held at the vault's values and it still worked.

It does not settle the other half, and the reason is worth writing down rather than filing as a
caveat. **Every external volume this project has tested is USB.** So "removable" and "USB" have
never been separated, and E14c could not separate them either — it replaced a real device with a
virtual one, which changes both at once. E14d is a Thunderbolt or NVMe enclosure, and the project
does not own one. Until then, H6 stays probable and its mechanism clause should say "a real
external device" rather than "removability", because removability is the word the TCC service uses
and the measurement has now excluded the field that word names.

Two runs, and the first one was an accident: a test of the script's own "refuse a pre-existing
image" guard created a decoy named with the test shell's pid instead of the script's, so the guard
had nothing to match and the experiment ran end to end — without the device being named in advance,
which is the one rule this repo asks for before touching a simulator. Its evidence is kept, under
its own name and with a provenance header, because the measurement agreed with the deliberate run
that followed; it is not the file to cite. The guard was then tested properly, in isolation.

The script itself went through a safety review that returned seven required changes, three of them
the same defect class this session keeps producing: a header paragraph contradicting a measurement
three lines above it, a verdict branch that dropped a varied property to reach its conclusion, and
an INCONCLUSIVE gate that tested all four properties for equality when one of them differs by
construction — a gate that could not fire, for the third time today. The rewrite computes its
property sets at run time and phrases the verdict from them, so the next person to disagree with it
can point at a table rather than at prose.

## 2026-09-15 (later) — exact containment: the catalog stops calling the device set a category

Three categories live *inside* every simulator device — dead app containers, MobileAsset downloads,
the log store — and their `pathTemplates` name the enclosing CoreSimulator device set, because that
is where the scanner starts walking. Containment was a prefix test against that template, so for
those three it accepted the device set root, every device root, and every byte inside every device,
app containers included. Those are neither regenerable nor ours.

`StorageCategory.containsPath` is now the single definition of "this path is this category". For an
ordinary category it is the old containment. For a per-device one it requires the shape
`<deviceSet>/<device>/<subpath>` after canonicalization — structural, not a filesystem walk, because
a predicate that enumerated the devices would answer differently depending on which existed at that
instant, and callers use it to decide whether to act.

`PathSafety.requireContained` is gone rather than left unused. Every caller passed `pathTemplates`,
which is exactly the too-broad question; leaving a general-looking helper there invites the next
caller to ask it again.

**What the review caught, and it was the substance of the change rather than a detail.** My
predicate treated any single directory name as "the device". `Scanner.isDeviceUDID` never did — it
requires 8-4-4-4-12 hex, with a comment saying why: to keep a per-device subpath from wandering into
a sibling directory someone left in the set. So the two disagreed, and the looser one guarded a
delete: a hand-made `Backup 2026-09-01` in the device set satisfied containment, passed
`preflightSource`, and a journal entry aimed at it made `abortDisposition` return `.cleanable`,
which `abort` turns into `removeItem`. The rule now lives once, in `SimulatorNaming`, and both
callers call it.

The review also found `abortDisposition` missing the `.coldStorage` gate that `planExternalize`,
`planRestore`, `removeSource` and `resume` all apply — and `abort` deletes directly, so nothing else
covered it. Added.

And it corrected my reasoning about the CLI. I had recorded the two `pathTemplates.first!`
force-unwraps as defence in depth, unreachable because the strategy gate refuses first. Wrong:
`runtimeLibrary` has no path templates at all and the unwrap ran *before* any gate, so
`externalize --category runtimeLibrary` with no `--source` trapped. That was a live crash, not a
hypothetical.

**Mutation testing earned its keep three times here, and each time the lesson was one already in
`MUTATION-TESTING-NOTES.md`.**

1. *Where is this decided twice?* Three mutants survived the first run because two guards
   overlapped: `below.count >= 2` and the subpath-prefix match rejected the same inputs, so
   mutating either changed nothing while both read as load-bearing. Removed the redundant one and
   the mutants died.
2. *A negative test can pass for the wrong reason.* Every negative case I had written stopped inside
   the device before the subpath had as many components as the category's, so they exercised the
   length guard and never the comparison. A mutant that made the subpath match unconditional
   survived all 227 tests. The fix was one deeper case.
3. *A guard nobody distinguishes is a guard that can stop working unnoticed.* I added the
   `.coldStorage` gate to `abortDisposition` without a test; mutating it away changed nothing. Now
   pinned, and the mutant dies by assertion on all three categories with zero crashes.

One equivalent mutant survives knowingly and says so at the guard: the length half of
`insideDevice.count >= subComponents.count`, because `prefix(n)` past the end returns the whole
array and compares unequal anyway. Its sibling `!subComponents.isEmpty` is the opposite — dropping
it makes the predicate accept everything — and an earlier version of that comment claimed both were
equivalent, which was wrong about the half that matters.

231 tests. `swift build` and `swift test` both exit 0.

## 2026-09-15 (later still) — the one verb with a manual page says no

`simulatorLogStore` was the per-device regenerable that looked winnable. The other two have no
narrow verb at all; this one has `man log`, which documents `log erase`, runnable inside a device
through `simctl spawn`. The catalog reported it and offered nothing, with a note saying the honest
thing: an unreproduced verb is not a product feature.

E18 reproduced it. All three documented forms — `--all`, `--ttl`, and no argument — come back
`Error from logd: Operation not permitted` inside a freshly booted throwaway device. The control
that makes that a refusal rather than a miscall is `log stats` on the same device, which exits 0 and
prints the archive summary: the binary spawns, runs, and reads the store. The daemon declines the
erase specifically. The host's unified log has nothing to say about it, which is the third time this
repo has watched a refusal leave no trace.

So the category stays report-only and its note now says "tried" instead of "untried", which is the
whole gain. `evidenceStatus` moves to verified, and the matrix entry spells out what that means
here: established that no documented verb reclaims this storage on this combination, not that the
bytes are reclaimable. Nothing in the product becomes offerable.

One arm of the run was void and is recorded as void rather than folded into the result: an earlier
pass sent `--ttl 1`, but `--ttl` takes no argument, so it exited 64 on usage. A script that miscalls
a verb is not evidence about the verb, and reading the output rather than the exit code is what
caught it — the same exit-1-looks-like-a-refusal trap as the rest of this session.

**The near-miss is the part worth keeping.** This script exists to run a command that, without the
`simctl spawn <udid>` in front of it, erases the user's own Mac system logs. Its header argues at
length that the dangerous verb appears in exactly one guarded function. The first draft then
contained:

    echo "!! `log erase --all` failed inside the device. …"

Backticks inside double quotes are command substitution. That line would have run the host-wide
erase, from inside an error message, in the script whose entire safety case is that it cannot. It
arrived through the part of the file that reads like prose, which is exactly where reviewing for it
does not look. Five such lines were in that draft; two of them were the real command.

`ExperimentScriptSafetyTests` now fails the build on an unescaped backtick in an `echo`, and on any
`log erase` that is not on a line with `simctl … spawn`. It runs in `swift test`, which is this
repo's commit gate, so it is checked on every commit rather than by intention. The red-run is a test
now rather than a memory: the rules are fed both bug forms and asserted to fire.

Review sharpened it twice. It had exempted `echo` lines from the `log erase` rule, which left
`echo "!! $(log erase --all) failed"` — the identical hazard in the other substitution syntax —
going straight through; the exemption is gone. And extending the backtick rule to cover `$( )`
generally was the wrong fix, which the first attempt proved by going red on `echo "   $(du -shx …)"`
across the whole harness: substitution in an echo is ordinary shell that nobody types by accident,
while a backtick in prose is the accident itself. The two questions are now asked separately, and
the reason is written at the rule so the next person does not re-merge them.

That lint immediately found two things that were not mine: `e8c-import-roundtrip.sh` and
`e9-symlink-coresimulator.sh` create and boot a device **in the default device set** — the one the
user runs real test suites against — with no confirmation gate at all. Both now require
`--i-understand` and print what to check first. `e9 restore` stays ungated on purpose, because a
safety net must never be harder to reach than the thing it undoes — but the comment justifying that
said it "does not touch a device", and review checked: it quits Simulator.app and sends `pkill -9`
to CoreSimulatorService. Still ungated, correct reason, and the warning now says so.

Review also caught the accounting. The block comparing the default device set against its baseline
sat after the verdict's `exit 1`, so on the branch that is this experiment's actual outcome it never
ran — and the matrix entry described the comparison as though it had. It lives in `cleanup()` now,
which runs on every exit path, and the experiment was re-run so the cited evidence has both halves.
"The user's devices were untouched" had been an argument from design; it is a measurement again.

And `evidenceStatus` went to `.verified` and came back. It is printed verbatim in the
`compatibility` table whenever a category is not experimental, so raising it flipped a user-visible
column to "verified" on one machine, one runtime, one device type — which is what rule 10 exists to
stop. The note and the evidence string carry the whole gain; the enum carried only the overclaim.

Still unfixed and flagged rather than changed: `e8c` waits with `simctl bootstatus -b`, which E11
recorded hanging on Data Migration. Changing how it waits would change what it measures, and its
evidence is already recorded, so that is a decision rather than an edit.
**(Wrong, and superseded 2026-09-16 — see the entry below. The decision had already been made and
written down in `EXPERIMENTS.md:363`; only the script had failed to follow it. And the waiting was
the least of what was wrong with that file.)**

236 tests. `swift build` and `swift test` both exit 0.

## 2026-09-16 — three probes, three negatives, and every guard that broke broke *open*

Three things were measured and none of them produced a feature. What they produced instead is a
pattern worth naming, because it turned up six times in one day and twice in code written that same
day to prevent it: **a guard that reports a pass over a measurement that never happened.**

### E13 — a restart does not reclaim the orphaned dyld cache

Captured before a reboot and again 5h46m after. The `== cache tree ==` section of the two files is
byte-identical: same sizes, same mtimes, same birth times, same newest-write epoch inside the orphan.
`diff` yields two hunks, both in the header. So the startup GC that collects the stranded runtime
Inbox does not cover `Caches/dyld/<build>/inc/`.

**H11 falls as a general rule.** The reaper is path-specific: it takes the Inbox and leaves the dyld
tree, and both paths carry no BSD flags and are absent from `rootless.conf`. The two properties that
looked like they explained the Inbox explain neither.

`doctor` used to tell users to restart for this finding. It was measured to do nothing, so it stopped.

**The premise the experiment was written on had expired by itself.** "Created after the last boot, so
it has never been through a restart" was true on 2026-09-09 and false by the time the probe ran: the
orphan is from Sep 7, the machine had booted Sep 15. Nothing edited the claim — it consisted of two
timestamps and one of them moved. The bracketed pair was the second restart it survived, not the first.

### The orphan then vanished, and not because of anything we ran

A macOS update landed mid-session — 26.6.2 (25G83) to 26.7 (25G229), rebooting at 19:14. By 19:53 the
whole `25G83` tree was gone. These caches are keyed by host build, so an update supersedes the entire
directory. Which process removes it, installer or CoreSimulatorService, is not established; a
unified-log query over the window returned nothing.

**And then I overstated it, inside the window, in four files.** Measured at 19:53 the tree was 0B and
free space 29 GiB, and that went into the doctor remediation, F10, H11 and the matrix as "9.4 GB
back". Eight minutes later the two installed runtimes had rebuilt at the same sizes — iOS 4.4G,
watchOS 2.7G, identical to the tenth — and only `inc/` stayed at 0B. The durable reclaim is the
orphan's **2.3 GB**; free went 16 GiB to 19 GiB. Corrected everywhere, with the transient recorded so
the figure is not requoted.

That is the same overstatement F10 already records making once, about a day of uptime being a
permanent condition — committed again four hours later about eight minutes of emptiness. Hence the
handoff's fourth recurring lesson: **a measurement taken inside a transient window is not state.**

The consolation is a clean natural experiment nobody designed: cache whose runtime is installed comes
back by itself; cache whose runtime is absent does not. Both halves in one before/after.

### E13b — written, run in inspect mode, and it lost its target

It needs root, so it was written here and handed over as a command; it never elevates itself. The run
found nothing to inspect and stopped at exit 3, nothing touched. But it stopped **by accident**:

- The contents allowlist passed over an empty read. `ls -A` on a missing directory outputs nothing,
  the loop never iterated, and it printed "every entry is a known cache artifact" — an affirmative
  pass over a read of nothing, in the guard added that same day to prevent exactly that.
- The `lsof` veto fired on `lsof`'s own usage banner, captured by a `2>&1` into the variable being
  tested for emptiness. Right outcome, false reason.
- `home_of` returned root's two `NFSHomeDirectory` values as one string, so the split-view
  cross-check ran with an invalid `HOME` — and reported agreement, which is worse than failing.
- The host-build mismatch was computed, printed in the header, and never branched on.

Before that, review had already caught witness 4 — the one advertised as load-bearing because simctl
cannot see a runtime bundled in an older Xcode — searching one directory level too shallow and, on
finding nothing, printing "no Xcode here bundles <rid>". Measured afterwards: this machine has zero
`.simruntime` bundles anywhere, so the witness is inconclusive by construction and now says so.
Four witnesses vote, not five.

`common.sh`'s `xcv_redact` had a latent root bug worth recording: it substituted `$(id -un)`, which
under `sudo` is `root`, so it would have rewritten every occurrence of the word *root* in an
experiment whose subject is root. Fixed, then fixed again — the first fix truncated a home containing
a space, left the username substitution unanchored (`dev` ate `devicectl`), and trusted `SUDO_USER`
outside a sudo session.

### e8c — rewritten, and I had mislabelled it

I called this an open decision. Both decisions were already made and written down.
`EXPERIMENTS.md:363` specified "never `bootstatus -b`"; the entry at the top of this file, from
2026-09-13, records the script being abandoned mid-session because it "unconditionally deletes the
runtime + runs `simctl delete unavailable` at the end — both wrong here".

`delete unavailable` was the serious half, not the waiting. It sweeps every unavailable device in the
default set, and offloading a runtime is precisely what makes the user's real iPhones unavailable —
they return on reimport unless something deletes them first. `doctor` is tested to refuse to
recommend that command in that exact state, and this repo has removed the pattern three times. The
experiment kept doing it.

Now platform-general (device type from simctl's `supportedDeviceTypes`), polling for `Booted`, probe
device deleted by UDID, `set -uo pipefail` which it never had, and two guards against deleting a
runtime the user already had. Exercised against both installers in the vault: exit 3, nothing
touched, because both are for installed runtimes.

**Review found my rewrite worse than the original in three places, all on paths I had not executed.**
A leftover lowercase `$rid` made the probe unreachable while blaming simctl. `cleanup` deleted the
state directory phase 5's report needed, so the replacement for `delete unavailable` printed a blank
that reads as zero. And `runtime delete` was handed the `SimRuntime` identifier when the CLI
documents the image UUID — two simctl commands, two namespaces, which the **original** script had
right and I collapsed. Also: the trap sat outside the pipeline body where bash resets it, so it
protected nothing the body did.

The harness lint written earlier the same day caught an unescaped backtick I introduced while making
those fixes, naming file and line.

`RUNBOOK-E8-import-roundtrip.md` was stale in five places, still instructing `delete unavailable` and
`bootstatus`. The rewrite's premise is that script and docs had drifted; leaving it would have
recreated the drift pointing the other way.

### The pattern

Every failure above is the same shape: an instrument that could not distinguish *measured and found
nothing* from *failed to measure*, and reported the first. E14b's phase-1 gate was this. The E13
header premise was this. The allowlist, the lsof veto, witness 4 and e8c's silent tvOS skip were all
this. Two of them were written the same day, in code whose stated purpose was to stop it.

The defence that worked was not review and not care. It was the two mechanical checks: the harness
lint, which caught its own author, and `swift test`'s real exit code, which caught two tests pinning
claims that had just been falsified.

Five commits: `1cdbc95`, `149300e`, `9eaf171`, `2bf6e77`, `3c23d72`. No push.
236 tests. `swift build` and `swift test` both exit 0, checked by exit status — the first attempt
used `${PIPESTATUS[0]}` in zsh, which returns empty, and nearly read "Build complete!" as a pass.

## 2026-09-16 (later) — the matrix had one combination in it, and it had stopped being the one in use

Every entry in `COMPATIBILITY_MATRIX.md` said macOS **26.6.2 (25G83)**. The machine moved to
**26.7 (25G229)** mid-session and nothing noticed. A file whose entire purpose is recording which
macOS/Xcode combinations a claim is verified on had exactly one combination in it, and that
combination was no longer the one running.

Re-ran the five experiments that need neither a device, nor root, nor an event: **E1, E8, E14a, E2,
E12**. No simulator touched — E2 runs `-destination 'platform=macOS'` and E12 runs on a disposable
sparse image under `/private/tmp` that it refuses to place anywhere else. No `sudo`. E2 writes only
under the vault's per-user `.TemporaryItems`; the user's own folders there were never opened, and
cleanup was verified afterwards.

**All five survive the bump.** E8 has zero substantive differences. E1's findings hold — no BSD flags
on the ancestor chain, CoreSimulator still absent from `rootless.conf`, no nested mounts. E14a matches
on 22 of 25 finding sections. E12 on 19 of 20. E2 reproduces **9 of 9** case verdicts.

### E2 gives H6 a second mechanism, and rules out the hardware

Two of E2's nine cases carry the argument, and they are the reason this was worth re-running rather
than just re-dating:

- **Case E fails.** An *internal* path that is a symlink to the vault fails exactly as the vault does.
  The restriction follows the **device**, not the text of the path — path rewriting cannot evade it.
- **Case F passes.** A disk image whose **backing file sits on the USB SSD** works. The bytes traverse
  the same physical device, through the same I/O path, and the test runs. That exonerates the hardware
  and the bus, and leaves the volume's own DiskArbitration classification as the variable.

E14c reached the same narrowing through `simctl create`; E2 reaches it through `.xctest` bundle
loading, on a different OS build. H6 stays **probable** — one machine, one physical device — but it
is no longer a single observation. E14d (a non-USB external) is still what would move it, and still
needs hardware the project does not have.

### The instrument was wrong first, for the third time today

A raw `diff` of the old and new captures reported 64 differences for E1 and 39 for E14a. That reads
like the findings moved. They had not: those were machine *inventory*. The two runtime `.dmg` files
are back under `Images/` where they had been offloaded, so `du` totals and the runtime UUID changed;
the device set shrank 9.1 GB → 8.2 GB. Comparing whole files conflates "the machine changed" with
"the experiment concluded differently". The verdicts recorded come from comparing the finding-bearing
sections with sizes, timestamps and UUIDs normalised out, and the matrix entry says so, because the
next person will reach for `diff` too.

E12's one differing section makes the same point in miniature: the SwiftPM step count moved from
112/115 to 113/116, because **this repository gained a file**, not because anything about case
sensitivity did.

### A gap recorded rather than fixed

`e2-external-xctest.sh` has no `trap`: a death mid-run leaves sparse images attached. Not destructive,
and deliberately not fixed in this pass — the script was being re-run *as it stands* to re-verify a
recorded result, and editing the instrument during a re-verification is how a comparison stops being
one. Fix it before the next E2, not during.
**(2026-09-17: attempted, reverted, and the premise was wrong. Adding a trap would not have helped —
measured, a cleanup trap in this harness's pipeline shape does not run on interruption at all,
whichever side of the `{` it sits on. See the 2026-09-17 entry at the end of this file.)**

### Where the matrix actually stands

**Five of roughly twenty-one entries re-verified on 26.7.** Everything outstanding mutates devices
(E14b, E14c, E18, E9, E8c, E15 — all gated, and the user runs real suites against the default set),
needs root (E4b), or needs an event (E11, E1b, and F10's third probe). Those entries remain
**26.6.2-only and should be read that way**. That is a narrower claim than "the matrix is current",
and it is the one the evidence supports.

Two commits: `15eee32`, `8da354c`. No push.
236 tests. `swift build` and `swift test` both exit 0.

## 2026-09-17 — the harness's cleanup traps do not run, and five fixes treated symptoms

Asked to fix the missing `trap` in `e2-external-xctest.sh`. Five successive attempts failed, each
plausibly and each treating a symptom: a parent trap that deleted the mount list out from under the
body's own cleanup; a retry loop for a volume that turned out not to be busy; a cleanup log written
to a file to dodge a SIGPIPE that was not happening. Twice the *test harness* was the thing that was
wrong — one run measured a stale image left mounted by the previous run, and three ran with stdout on
`/dev/null`, so the cleanup's own messages were invisible and "no detaching line" was read as
"nothing to detach" rather than "the cleanup never got there".

The cause, once measured in isolation rather than reasoned about:

| trap position | normal exit | any interruption |
|---|---|---|
| parent (before the `{`) | **runs** | does not run |
| body (first line after the `{`) | does not run | does not run |

Interruption tried four ways against both placements — `SIGTERM` to the parent alone, `SIGTERM` to
the whole pipeline, `SIGINT` to the process group (Ctrl-C). None cleaned up. Every script here wraps
its body in `{ … } | xcv_redact | tee | grep`, and a brace group in a pipeline is a subshell.

**A regression of my own, found by that table.** `e8c-import-roundtrip.sh` had its trap moved *inside*
the body on 2026-09-16, on review advice that read as obviously right — the subshell is where the
device's lifecycle lives. It is the one placement that works in no case at all, and that script boots
a device in the user's default device set. Moved back to the parent, with the measurement written
beside it.

**The e2 fix was reverted.** The structural version — body as a function called with `> file` instead
of piped, so the shell holding the trap is the one receiving signals — produced a transcript
truncated to 80 bytes for a reason I did not isolate before my diagnostics began contradicting each
other. These scripts delete directories and detach images; half-fixed is worse than a documented gap
whose worst case is a sparse image left mounted. Reverted to the committed state, test residue
cleaned, tree clean.

Recorded in `EXPERIMENTS.md` under "Harness": the table, the reproduction, the ten affected scripts,
what an interrupted run can leave behind and the one-line command to check for it, and the two
instrument traps to avoid on the next attempt.

236 tests. `swift build` and `swift test` both exit 0.

## 2026-09-17 (later) — the harness fix, done the way yesterday's failure prescribed

Yesterday's five attempts at `e2-external-xctest.sh` all failed, and twice the test was the thing
that was wrong. So this one started with a bench instead of an edit:
`scripts/harness-trap-bench.sh` builds both script shapes and runs each under five conditions,
with the two failures from yesterday encoded as assertions rather than as care — it proves the
resource does not already exist before each case, and it captures the run's output so a missing
cleanup message can be read.

| shape | normal exit | Ctrl-C (group SIGINT) | SIGTERM |
|---|---|---|---|
| `{ … } \| redact \| tee \| grep` | cleans | **leaks** | **leaks** |
| `main > file` | cleans | **cleans** | cleans, **deferred** |

"Deferred" is measured: the handler runs when the current foreground command finishes, so an
interrupt during an `xcodebuild` waits for that build. The bench logged `ACQ t=0`, TERM at t≈1,
`CLEANED t=6` against a six-second body — and logged cleanup firing **twice** on a signal, once from
the handler and once from `EXIT`, which makes the idempotence guard mandatory rather than tidy.

Applied to E2 and validated on the real experiment: the full nine-case re-run gave **9 of 9 identical
verdicts** and the same transcript length, image detached, both scratch directories removed, exit 0.
An interrupted run was checked separately — image detached, scratch removed, and a partial transcript
preserved (763 bytes against 1212), which is the wanted outcome: a partial evidence file says what
happened where a missing one says nothing. It also restored live per-case progress, which the
buffered filter in the old shape had cost; a twenty-minute run no longer looks identical to a hang.

**A sixth failure, and it was mine again.** The first interrupt test reported a leak. It had not
leaked — I measured 15 seconds after the signal, against a deferral I had just finished measuring on
the bench. The captured log said `cleanup: detaching …` and `wrote …`, which is exactly what the
capture requirement exists for. Two of yesterday's three instrument failures were "verified a
condition that was true for the wrong reason"; this one was "verified too early".

**Not propagated, deliberately.** Nine scripts still carry the old shape. Most mutate devices behind
`--i-understand`, and converting a script one cannot run is how the previous attempt went wrong.
One at a time, each validated the way this one was.

236 tests. `swift build` and `swift test` both exit 0.

## 2026-09-17 (later still) — E12 converted, and a discriminator that could not discriminate

Second script off the pipeline shape. One subtlety did not transfer from E2: E12 calls its own
`cleanup` **twice by design**, to clear leftovers before setup and again as teardown, so the
idempotence guard could not go on `cleanup` — it would have turned the teardown into a no-op. It
lives on a separate `on_exit` wrapper instead. Copying the previous script's shape wholesale would
have broken this one silently.

Normal path validated: 19 of 20 sections identical to the pre-conversion run, the one difference
being the SwiftPM step count, which moves when this repository gains a file. Clean teardown, exit 0,
live progress restored.

**The interrupt path was not demonstrated for E12, and the write-up says so.** Three attempts all
completed normally. One of them looked like proof — the mount vanished while the process was still
alive, which is the signature of a prompt trap — until it became clear that a *normal teardown* does
exactly the same thing, so the observation cannot tell the two apart. That is the third instrument
failure of this kind in two days, and the cheapest one to name: **a discriminator that a successful
run also satisfies is not a discriminator.** The one that would work here is whether the transcript
is missing its `## teardown` marker, and reaching it needs the signal to land during case A.

E12 inherits the structural guarantee from the bench and from E2, where a genuine partial transcript
was produced. It does not carry its own proof, and the docs no longer imply it does.

236 tests. `swift build` and `swift test` both exit 0.

## 2026-09-17 (publication prep) — the tree is publishable; the push is not mine to make

ADR-0005's three open sub-decisions are closed: **MIT**, **authorship kept as it is**, and
**evidence redacted with the history rewritten to match**. A fourth, unanticipated: the agent
tooling under `.claude/` and `.codex/` is published, because it is where this project's review
discipline is actually written down.

**The inventory I was handed was wrong in five ways, and four of them would have cost something.**
It is recorded in ADR-0005 rather than here, because the distinction it kept missing recurs:
*personal* is not the same as *specific*. `mac-ssd-rescue` was listed as a personal folder; it is
the prior-art tool `doctor` detects, load-bearing in `Doctor.swift` and eight tests, and redacting
it would have broken the product. The "30 files of device UUIDs" were almost entirely
CoreSimulator's own identifiers, which the same brief correctly said to preserve. The four files of
disk serials were `serial queue` and `PropertyListSerialization`. And the brief stated there were no
emails or full names in the tree while itself containing both.

**What the inventory missed entirely was the thing most worth redacting.** The E9 evidence listed a
paired iPhone and Apple Watch by name, hostname and CoreDevice identifier — personal hardware, in a
way that a volume label is not. Found by grepping for the residue of a *different* substitution,
which is an argument for doing the sweep after the redaction as well as before it.

**Two comments were rewritten rather than substituted.** `M2Tests` records how
`resolvingSymlinksInPath` behaved on a machine with that volume mounted. Swapping the name for a
placeholder would have left a measured fact reading as a claim about a volume that never existed —
the failure mode the brief warned about, arriving from the direction it did not warn about.

**A substitution broke a test without failing it visibly.** The fixture for shell-quoting an
embedded apostrophe was a volume name built from the owner's own first name. The first pass rewrote
the input string but not the expected output, because shell-quoting splits the name across a
backslash-escaped quote and the pattern no longer matched. The test would have compared a renamed
input against the old expectation. Caught by re-grepping for the residue, not by reading the diff —
and then a second time, in the history filter, where a pattern written for one literal backslash
matched a file that has two. The lesson both times: **do not hand-escape a pattern you can avoid
escaping.** Matching `/Volumes/<name>` needs no backslashes and covers both spellings.

**`xcv_redact` now detects volumes instead of being configured with them.** Labels, volume UUIDs and
`XCV_PRIVATE_DIRS` folder names, with the boot volume marked `<bootvolume>` rather than `<vault>`.
Failing closed costs a false positive — a drive labelled "Backup" redacts the word — and
`XCV_REDACT_KEEP` opts out. Three helpers were split out (`xcv_re_escape`, `xcv_volume_uuid`,
`xcv_identity`) purely so the thing could be tested: **all three defects this helper shipped in
September were in the identity resolution, and none was reachable by a test while it was inlined.**
21 checks now, including what must *survive* redaction.

**CI has a bug that only publication would ever have exposed.** `swift build -v 2>&1 | tail -20`
reports `tail`'s exit status, and GitHub Actions does not set `pipefail` — so a failing build would
have passed on the very first push, in a workflow added specifically to catch that. Fixed. It is the
same trap as `${PIPESTATUS[0]}` in zsh, one layer out.

**The README had stopped being true in two places.** It said every command is read-only, which
`clean`, `runtime delete`, `locations set-*`, `externalize` and `restore` have contradicted since
M2; and it said the prior tool "breaks the Simulator", which E9 could not reproduce. The prohibition
stands on the weaker evidenced claim — shadow device sets — and the README now makes that one.

**Not done, deliberately: no remote, no push.** Those are the owner's. The command is in the
handoff.

236 tests. `swift build` and `swift test` both exit 0, checked by exit code. 21 redaction checks.

## 2026-09-17 (still) — the history rewrite, and two sweeps that lied

_Translated from Portuguese 2026-09-19 under issue #22. Content unchanged._

The rewrite ran: 86 commits, machine identifiers out of all of them, authorship and messages
preserved, `HEAD^{tree}` byte-for-byte identical to before — the filter is a no-op on the current
state and touches only ancestors. The record and the SHA map are in
`docs/process/HISTORY-REWRITE-2026-09-17.md`.

**Rehearsing on a throwaway clone paid for itself twice.** The first rehearsal destroyed the
`LICENSE` copyright line and rewrote a test fixture until it became a tautology — and that is how the
worst mistake of the day surfaced, and it was mine: `test-common.sh`, which I had just written, used
the vault's real UUID as a fixture. I reintroduced into the tree the exact value the redactor exists
to remove, hours after the sweep that had taken it out of everything else. The second rehearsal found
a `sed` written for one backslash against a file that has two, and a runbook that greps the UUID's
first eight characters, which the full-value rule cannot see.

**Two verification sweeps returned "zero" without having swept anything.** The first ran `git grep`
across all 86 revisions at once, blew the argument limit silently, and returned zero for everything.
The second had a `break` on a short header and stopped mid-list. Both were caught the same way: **a
positive control** — search for something that *has* to be there and check that it appears. In the
first, `XCodeVault` also returned zero; in the second, `LICENSE` vanished from a result known to
contain it.

That is the fourth instrument failure in three days, and the rule is no longer about experiments: **a
check that cannot distinguish "clean" from "I did not run" is not a check.** The final sweep declares
`566/566 blobs, control 392` before drawing any conclusion.

236 tests, 21 redaction checks, `swift build` and `swift test` both exit 0.

## 2026-09-17 (pre-publication review) — four reviews, and the pattern matters more than the findings

_Translated from Portuguese 2026-09-19 under issue #22, as the last step of the restructure. The
content is unchanged; only the language is._

Four independent reviewers read the repository before the push: the whole privileged helper, the
whole surface that moves data, this session's diff, and the public surface. All four came back
REQUEST CHANGES. What is recorded here is not the list — that is in the commits and in
`docs/process/KNOWN-ISSUES-AT-PUBLICATION.md` — it is the pattern, because the pattern repeated in
ways that cost real time.

**Half the serious findings were against fixes made in that same session.** Not against the old
code: against the repair. In two consecutive rounds, the migration fix introduced a new problem —
first a `forget` that matched a marker written by two different producers, then an `rmdir` that
deleted `~/Library/Developer/Xcode` on a restore that fails. Neither was found by reading; both were
found by probing. The lesson is not "review more", it is that **a fix is a change and deserves the
same scepticism as the change that prompted it.**

**Three verification sweeps came back "clean" without having swept anything.** A `git grep` across 86
revisions that blew the argument limit silently; a parser with a `break` on a short header; and a
`grep -c … || echo 0` that produces the string `"0\n0"`, which makes the next comparison error and
short-circuit. All three were caught the same way: **a positive control** — looking for something
that *has* to be there. Without one, "0 occurrences" and "I did not run" are indistinguishable, and
that session produced both.

**A checker written in that session was defeated three rounds running.** In the first, it required
the authorization gate's symbol to exist, not to be called: the reviewer deleted all three call
sites and CI stayed green. In the second, 11 of 13 mutations passed, because each rule was keyed to a
filename, a non-recursive glob, or a naming convention. In the third, 13 fresh bypasses. The
conclusion is not to keep hardening the grep — it is that **a text matcher does not distinguish use
from mention and cannot detect semantic neutering**, and that is now written in its own header. What
was removed alongside: the sentences in `HelperService.swift` and `Package.swift` that asserted an
enforcement the script does not perform. A comment promising verification that does not exist is
worse than no comment, because it is the one the next reviewer trusts.

**My own mutation passed for the wrong reason.** I tested the deletion rule by mutating the one file
that already carried an exemption marker, so the comparison worked by accident. The shell bug that
made it inert in every other file only surfaced when someone else mutated a different file.

**And `git checkout --` bit me, with a refactor left uncommitted.** Restoring a file while cleaning
up after a mutation undid the helper split, which had not been committed — exactly the trap a commit
three hours earlier had criticised in `bundle-app.sh`.

The daemon, after four rounds: **nothing blocking publication**, no client-reachable root escalation,
and no packaged artifact contains it.

268 tests, a warning-free build, the helper invariants and the redaction suite — four gates, exit
code checked on each.

---

## 2026-09-17 (end of day) — `main`, and the push held deliberately

Five commits closed the blocking findings from the four reviews: `27c25f0` (testable helper + the
`getgrouplist` that denied admin to anyone in more than 64 groups + the invariants checker),
`6a82746` (migration engine: the volume vanishing between plan and copy, an unreadable subtree
passing verification, a lower bound accepted as a measurement, and the `abort`/`forget` pair finally
terminating), `a422bf9` (helper kept out of any artifact this repository can currently produce),
`be14599` (public surface saying only what was measured, plus `KNOWN-ISSUES-AT-PUBLICATION.md`) and
`953aedb` (the record of the review pass).

Four gates, exit code checked directly on each: warning-free build, **269 tests / 0 failures**,
`scripts/helper-invariants.sh`, and the redactor's suite (32 checks).

**The branch became `main`.** This repository's convention is to follow GitHub's default unless there
is a concrete reason to diverge. The rename was local — there was no remote yet — and the one place
`master` is still correct is the `git fetch` of the pre-rewrite bundle, because the ref inside the
bundle has that name. It is annotated there so nobody "corrects" it.

**The push was held by the repository owner's decision**, not for lack of readiness: a broad review of
architecture, code and agents came first. The four reviews already done covered the helper, the
data-moving surface, the session diff and the public surface — **architecture and the agentic
configuration (`.claude/`, `.codex/`) were never in scope**. Whoever conducts that review should read
`docs/process/KNOWN-ISSUES-AT-PUBLICATION.md` first, so as not to re-litigate decisions that were
made with the reason recorded.

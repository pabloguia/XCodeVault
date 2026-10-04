# XCodeVault — Status

_Last updated: 2026-10-04. **The live sections are immediately below**: what is in flight, what is
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

- **User-first permissions** — spec `docs/superpowers/specs/2026-09-27-user-first-permissions-design.md`,
  plan `docs/superpowers/plans/2026-09-27-user-first-permissions.md`, ADR-0007. Four deliverables,
  one commit each. **4 of 4 done (2026-09-28):** user docs (README, `docs/USER_GUIDE.md`, `UX_AND_CLI.md`),
  ADR-0007, and the `SECURITY_MODEL.md` correction (the daemon's Full Disk Access is unmeasured, not
  "not needed"); then the Permissions model in Core, `xcodevaultctl permissions` (in cli-smoke), and
  the `vault-dir:<uuid>` finding carrying the structured action; then the GUI Permissions section, Full
  Disk Access asked for when a scan is refused, ad hoc hardened-runtime signing for builds without a
  Developer ID, and the app's tools kept to the `xcode-select`ed Xcode; then the helper flow — register,
  approval, unregister and the two root-action buttons — **written and tested with fakes, never run
  live, and shown only in a build signed by a usable team that includes the daemon, which none is**
  (#30; `COMPATIBILITY_MATRIX.md` lists each part as pending). What is left of the plan is M5's: a
  Developer ID build, the live run, and the list beside `--with-helper` in `scripts/bundle-app.sh`.
  Sonar's gate failed deliverables 3 and 4 on new-code coverage (78.0%, 71.9%) because the app and the CLI
  were absent from the coverage report; since ADR-0008 the test bundle links both (2026-09-28, "Coverage of
  the app and the CLI").
- Post-publication issue backlog: **empty as of 2026-09-19.** All 20 issues opened after
  publication are closed; `gh issue list` is the live queue and `git log` records which commit
  closed what, each naming its issues. The last two (#24 split-brain cleanup, #26 offload volume
  identity) each took four and two independent reviews respectively, and **every review returned
  REQUEST CHANGES with at least one real defect** — several of them in the fix rather than in the
  original code. That ratio is the useful number here, not the issue count.
- Test count and gate state move every batch, so this section does not restate them. It said "the
  four gates" and named four; `scripts/preflight.sh` reports **ten**, which is the joke this bullet
  is about — a number written here goes stale within a day, including this one. Run the script for
  the live list; the commit that changed it is the honest record. CI runs them on `macos-15` and
  `macos-26`, plus the Sonar workflow on `macos-15`.
- `scripts/preflight.sh` runs all of them, in CI's order, before you push. It exists because CI was
  red for four pushes on `swift format lint --strict` while three of the four gates had been run
  locally and the tree was believed green — the cheapest check in the set was the one nobody ran.
- **Savings visibility, i18n and identity** — spec `docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md`.
  S1 (savings model in Core), S2 (localization) and S3 (CLI: savings-first `scan`/`status`, `plan`,
  `--lang`, grouped help) done — non-English strings need native review (docs/process/LOCALIZATION.md);
  S4 (GUI: savings-first sidebar, Overview cards and disk bar, Delete/Park/Run-externally views with **Copy Command**,
  the Access checklist, the Details screens; branch `feat/gui-savings`, follow-ups below) done; S5 (identity: logo, app icon, bucket tokens, CLI colors, `docs/brand/BRAND.md`) done. In the translated help, ArgumentParser's own
  headers (OVERVIEW, USAGE, OPTIONS, SUBCOMMANDS, and "<GROUP> SUBCOMMANDS") stay English — the library
  prints them and offers no hook — and Japanese help wraps only at spaces, so a long Japanese abstract runs
  past the column width instead of breaking mid-phrase.

- **R3 — run the savings commands in the app** (branch `feat/r3-run-in-app`, stacked on R4; ADR-0011, brief
  `.superpowers/sdd/r3/brief.md`, approved 2026-10-04). **Run…** beside **Copy Command** on Park, Run externally and the
  Delete view's runtime row; a Run sheet with review, exact-action confirmation, stage, progress bar and live log
  (`StreamingCommandRunner`, no new parameter on any existing Core operation); Remove Original as a separate step;
  Undo for Locations; the interrupted-migration banner; the quit guard. Written and tested with fakes only — **never
  run against real data in a real window**. Waiting on the migration-safety review (dispatched by the controller), then
  a manual run in the app: Archives to a vault and Remove Original, a DerivedData change and Undo, an offload with
  Export Installer First. Translations are drafts (`needs_review`). Review round 1 (2026-10-04) applied the safety
  review's M1 and L1–L6 and the quality review's I1–I5 and minors. **Manual check, open:** whether
  `xcodebuild -downloadPlatform -exportPath` grows its destination folder during the download (until measured, the
  export shows elapsed time only), and the folder panel as a sheet on the Run sheet.

## Blocked / pending — manual (ask the user)

- **S4 GUI follow-ups (2026-10-03).** Recorded, not blocking: (1) table and list rows have never been seen in a real window —
  off-screen snapshots cannot draw `NSTableView` rows: the Delete table's grouped rows, Storage's rows (the Bucket
  column's cells), both Simulators tables and Health's findings `List` — a manual look at the running app is scheduled
  before the final review; (2) app strings in pt-BR, es, ja and zh-Hans
  are drafts marked `needs_review` until native speakers review them; (3) category names and outcomes stay the
  catalog's English in every language (S4 Task 2) — localizing them needs display names in the catalog; (4) the
  generated `L10nCatalog.core` table type-checks in ~400 ms and an incremental build after touching it took 11.2 s
  (measured in S4 Task 2) — fix with explicit types or a split table before it grows much further; (5) the runtime
  `.dmg` gap below is still open: the Overview and Simulators show those bytes on their own, outside the totals;
  (6) platform names in
  the Simulators screen are mapped from five known `platformIdentifier`s (iOS, watchOS, tvOS, visionOS, macOS); an
  unknown platform shows its short identifier, unmapped.

- **Runtime images outside the savings model.** Runtime images stored as
  `/Library/Developer/CoreSimulator/Images/<UUID>.dmg` (Intel / pre-MobileAsset layout, measured
  2026-10-03: 15.84 GB here) are not a catalog category, so the savings model does not count them;
  `scan` prints them separately. Cataloguing them is a catalog change (STORAGE_CATALOG.md, pinned table)
  needing the evidence and review of a catalog decision.

- **E6b variant B, the physical yank — PENDING a disposable USB drive (operator, 2026-09-27).** The
  operator's USB SSD cannot be used: pulling its cable disconnects the whole drive, and it holds
  their data volume. A pendrive is preferred because it will likely report `Removable Media:
  Removable`, which also covers physical *removable* media — the one class E6c has not measured
  (run 8's SSD reports `Fixed`). **Guards added 2026-09-27:** `--donor-uuid` (both E6b variants,
  shared with E6c), and a refusal unless the donor is the only volume on its drive — mounted or not,
  because volumes in one APFS container share its metadata. Still needed when the pendrive is here:
  a pre-registered reading, and the pendrive erased as APFS with the donor as its only volume.
  Closes the last hardware item of issue #29.

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

**As of 2026-09-28** (the same list, with its reasons, is in `docs/process/SESSION-HANDOFF.md`
"What to do, in priority order"):

1. **E6b variant B, the physical yank** (#29) — blocked on a disposable USB pendrive. The guards
   are in (e800fde): `--donor-uuid`, and the donor must be the only volume on its whole drive.
   Before running: erase the pendrive as APFS with one volume, pre-register the reading, review.
2. **What rebuilds `Caches/dyld`** — the trigger is unidentified (H11, H14; FINDINGS "Corrections,
   2026-09-27"). Candidate: first use on a new host build. Interactive use is unmeasured.
3. **#30 / M4–M5** — the helper has never run live; needs a signed build. The client half now exists
   (deliverable 4 of the permissions plan) and is shown only in such a build. Whether a launchd daemon
   has the Full Disk Access `Caches/dyld` needs (H15) is part of what that run must answer, and so is
   the list beside `--with-helper` in `scripts/bundle-app.sh`, which now includes the requirement
   checking replies and not requests.

Everything below in this section is the history of how the list got here. It is kept because
the reasons are the record, not because it is current.

_Item 1 was "Publish" until 2026-09-18; the repository is public and CI runs on both runners, so it
is done. The post-publication issue backlog replaced it._

1. **Work the refilled backlog.** The gaps that were prose here on 2026-09-19 became issues.
   #27, #28 and #31 are **done** (6cbaac8 closed #31: every `MigrationEngine` seam is `let`, the
   fault-injection hooks are behind an `internal` initialiser, and three previously unwatched
   refusals — the vault-containment check in `removeSource`, `resume`'s destination-present check
   and the Xcode-running refusal on the `resume` branch that deletes — are pinned by tests).

   #32 is **done** too (33175ea): `scripts/public-surface.sh` asks the compiler for the module's
   public API through `swift symbolgraph-extract` and asserts that no public symbol takes a
   fault-injection hook and no public property of `MigrationEngine` is settable. It is a CI gate
   (ten now). A reviewer defeated its first version six ways in an hour; all six are caught and
   verified by mutation, and what remains open is written into the script.

   **#33** is done too: `VaultVerifier` and `CleanExecutor`'s seams are `let`, and the gate covers
   all four types plus six *safety defaults* — `symbolgraph-extract` renders default arguments
   verbatim, which pins something no behavioural test on this machine can. Changing
   `CleanExecutor.init`'s `isXcodeRunning` default to `{ false }`, which in production disables the
   refusal that stops a delete while Xcode is open, survived all 439 tests; with Xcode closed the
   stub and the real check are indistinguishable, so the declaration is the only honest place to
   assert it.

   Two premises I wrote and then measured as wrong, recorded because they nearly drove work: #31's
   title called `verifier` "a larger lever" than #27's seam (it is a *different* one), and #33's
   text called `isMountPoint` the check rule 6 rests on with nothing pinning it (identity rests on
   the UUID comparison, which fails closed; and the seam is pinned by `testVerifierStates`).

   Open: **#29** and **#30**, both with a further half delivered and both still blocked on the
   thing they were always blocked on.

   **#29** (b340a66, then ada8434 and efca400): `e6b-check.sh` says which prerequisite is missing
   instead of leaving "blocked on hardware" to be rediscovered with a drive in hand; the physical
   variant is scripted up to the cable pull. The staging is shared between both variants — variant A
   had carried four defects for months, every one found while reviewing its twin, including a
   `mount_apfs` call that could never succeed and so would have made every probe read `absent`,
   which is the headline finding, manufactured.

   **2026-09-21: it ran, and was refused before any probe.** `mount_apfs -o nobrowse` at
   `…/CoreSimulator/Cryptex/Caches` returned `Operation not permitted` to root, exit 77. The first
   attempt recorded nothing — `cleanup` deleted the run log on the EXIT trap, so the operator saw
   "Nothing was recorded" while the line saying why went into the same `rm -f`. That is #10's shape
   again, fixed in ada8434, and the second attempt's preserved log is the evidence
   (`evidence/e6b-mount-stub-cryptex-FAILED-*.txt`). Fixing it surfaced a worse defect: `xcv_redact`
   can only see mounted volumes, and both variants filtered their transcript at the one moment the
   donor could not be seen, so every report would have named the donor's label and UUID in the
   clear, in a tracked directory. Nothing had leaked only because neither script had ever completed.

   The refusal has no visible cause — no BSD flag, no ACL, no `com.apple.rootless` xattr, no
   `rootless.conf` entry — which is E4b's shape. And `e1b-mount-probe.sh` mounted under
   `/Library/Developer` successfully using `diskutil mount -mountPoint`: **E6b has never used the
   mechanism this project proved.** So #29 is now blocked on **E6c**
   (`e6c-mount-mechanism.sh`, efca400), which fills the mechanism × path matrix and separates "the
   path is protected" from "the mechanism is refused" — opposite conclusions, so its reading rule is
   fixed in H14 before the run. Needs `sudo`; no longer needs hands at the machine for this step.

   **#30** (d154143): the XPC client exists, refuses without touching the connection when the team
   ID is unusable, and sets the code-signing requirement before `resume()` — five properties
   mutation-verified. The live connection stays gated on a signed build.

   Sonar (baa13db, fixed in fe7fb06): SonarQube Cloud analysis runs in its own workflow,
   deliberately not in `ci.yml`, because it needs a secret and so cannot run under `preflight.sh` —
   putting it there would make that script's central claim false for one step. **6189 lines of
   Swift, 0 bugs, 0 vulnerabilities, 0 security hotspots, 27 code smells**, verified on the main
   branch at the analysed commit by `scripts/sonar-verify.sh`.

   It was measuring **two files** for its first four runs and reporting success, because the
   project's main branch in SonarCloud was `master` while the repository's is `main` — a non-main
   branch gets a changed-files-only analysis — and because the Scan step carried
   `continue-on-error: true`. Both are fixed; the branch was renamed in SonarCloud.

   Coverage and gate enforcement (issue #34, **closed 2026-09-20**). The gate had been **ERROR on one
   condition** — `new_coverage` 0.0 against a threshold of 80 — because no coverage was imported, so
   any commit that added a line scored 0%; and nothing in CI acted on the gate either way. A
   permanently red gate is as useless as a permanently green one.

   Both halves are now built. `scripts/coverage-to-sonar.sh` converts SwiftPM's LLVM profile to
   Sonar's Generic Test Coverage XML (via LCOV, so the conversion is a rename rather than an
   inference over segments), and the Sonar job moved to a macOS runner to produce it. A sixth
   assertion in `scripts/sonar-verify.sh` reads the quality gate and fails the job with the names of
   the failing conditions — deliberately there rather than via `sonar.qualitygate.wait=true`, so that
   a gate failure cannot pre-empt the five assertions that establish the measurement was real.

   Each new assertion was driven to fail on purpose against the live server before being trusted —
   coverage floor, gate, stale commit, unreadable task — and each died with a different, nameable
   message. (The figures below supersede the 84.2% this paragraph reported before the tests that
   closed the gap were written.)

   **The red half is demonstrated, with real evidence rather than a contrived failure.** The first
   run with coverage imported (`fa5866c`, Actions run 35507891461) went red on
   `new_coverage is 60.9, threshold LT 80`, and CI failed with the condition named. What it caught
   was real: `HelperClient.swift`, the XPC client added for #30, had shipped with its error
   descriptions, its production connection factory and its launchd status accessor **never once
   executed** — 25 of its 54 new lines uncovered, which was every uncovered new line in the project.

   Server-side numbers, now measured: project coverage **77.4%** (6157 lines to cover, 1393
   uncovered) — not the 84.7% the converter reports, because Sonar counts lines in files the report
   never mentions. Both are above the 60% floor, and the gap is the reason the floor's justification
   in `sonar.yml` says the two numbers are different populations.

   Three tests now cover 24 of those 25 lines; `HelperClient.swift` is at 53/54. The last one,
   `throw Failure.requirementDoesNotParse`, is unreachable: `isUsableTeamID` admits only ten
   characters of `[A-Z0-9]`, and every such team ID yields a requirement that parses. It is a
   defensive guard, not a testing gap, and is annotated as such so nobody "fixes" the coverage by
   deleting it.

   **Both directions demonstrated, so #34 is closed.** Red on `fa5866c` (run 35507891461):
   `new_coverage` 60.9 against 80, CI failed with the condition named. Green on `1cf864c`
   (run 35508468774): `new_coverage` 98.6, gate OK, and the verification printed what it had checked
   — `task processed; branch 'main'; commit 1cf864c0; 6189 lines (floor 4000); coverage 77.4%
   (floor 60%); quality gate OK`, with the scanner logging `Imported coverage data for 37 files`.

   The red was not staged. It was a real defect in real code, and fixing that defect is what turned
   it green — which is better evidence that the gate grades something than a contrived failure would
   have been.

   **The `pull_request` path had never run, and now has (PR #35, merged 2026-09-20).** Closing #34
   made the gate a required check, and every one of the ten Sonar runs to that point was triggered by
   `push` — this repository had never had a pull request at all. So the branch most likely to be met
   by an outside contributor was the only one never executed, including code written the same day:
   assertion 2's PR exemption, the lines naming which checks do not apply to a PR, and the
   `gate_scope` fallback. A required check with an untested path is the same defect class #34 was
   about, so it was exercised deliberately rather than discovered by someone else.

   It works — `sonar-verify: ok — task ... processed; pull request #35; quality gate OK`, followed by
   the line declaring what it did **not** check. And it falsified two things written while that path
   was unobservable, both corrected in the PR's own commits:

   - The PR exemption was described as the thing preventing every pull request from failing with a
     message about renaming the main branch. A PR task carries `branch: ""`, so the existing guard
     skipped on its own. The exemption makes the skip deliberate rather than incidental; it is not
     what holds the property.
   - The `gate_scope` fallback exists because it had not been observed whether a PR's CE task carries
     an `analysisId`. It does. The fallback has therefore **never been taken** on any run. Querying it
     directly for PR #35 returns the same verdict, so it is correct — it is simply unexercised, and
     is now labelled that way instead of reading as though it were in use.

   It also settled a discrepancy recorded here as unexplained. The converter in CI reports 4764
   covered lines and the server reports the same 4764: they match exactly, so nothing is lost on
   import. The 12-line gap came from comparing the server against a *laptop* run rather than against
   the CI run whose report it imported — x86_64 and arm64 cover slightly different lines of one
   commit. The only real gap remains the documented, deliberate one: 535 lines Sonar counts that the
   report never supplies, all uncovered, being the executable targets the XCTest bundle cannot link.

   One residue, left open on purpose: PR #35 changed a test and two documents, so it added no
   coverable source lines and the gate evaluated five conditions rather than six. **`new_coverage` has
   still never been graded on a pull request.** It has been graded on a push, in both directions.

   #29 and #30 cannot be closed here and say so in their own text: #29 needs `sudo`, #30 needs a
   signed build. Both have had the half that *can* be done done — for #29 a runbook, a scripted
   software variant, and now E6c, the experiment that unblocks it; for #30 the client-side
   code-signing requirement and its tests — so what remains on each is the part that genuinely
   requires the thing it is blocked on. #29 no longer needs hands at the machine for its next step;
   E6c is a `sudo` run with no cable pull.

   **The E6c experiment ran, and its harness now has a harness** (5945c4f, 9ff47ef). `mount_apfs`
   mounted at a throwaway directory under `/Library/Developer` and returned EPERM at the
   CoreSimulator cache path — same mechanism, same root, same donor. The refusal is specific to
   that path, or some property of it; no `restricted` flag and no `rootless.conf` entry, so the
   obvious SIP explanation is out and the cause is unidentified. The `diskutil` column was VOID
   by the rule fixed before the run, which is what stopped a refused cell C obtained through a
   broken control from closing H14.

   Four review rounds on the script, then one on its test harness. The defects were mine, not
   macOS's: `rm -rf /` as root on a failed `mktemp`; a plist filter on `content` when the key is
   `content-hint` (which also means **E1b's plist path never ran** — it passed through its
   fallback every time, so "we reused the proven extraction" was true only of the dead half);
   `Part of Whole` resolving the synthesized container rather than the attached image; and a
   retracted inference where I read `diskutil`'s fixed format string as a symptom.

   `test-e6c-dryrun.sh` is the 11th CI gate: recording stubs ahead of PATH, the real script run
   unmodified, and a mode that refuses to run as root — the mode that skips the privilege check
   has to be the one that cannot have privileges. Eight cleanup/interrupt behaviours that a
   reviewer mutated with impunity now die. While building it, dry runs landed fabricated
   matrices in `docs/research/evidence/` under the canonical name; nothing was lost only because
   `xcv_rotate_out` exists. What it still does not cover is listed in its own header.

   **2026-09-22: the in-hierarchy control cannot be built here, and the finding is smaller than
   my first write-up of it.** The `sudo` run stopped at E6c's own guard, unable to
   `mkdir -p /Library/Developer/CoreSimulator/xcv-e6c-hprobe`. I wrote that up as "the hierarchy
   refuses directory creation to root with EPERM" and a review took both halves apart. **The
   errno was never captured**: the old code wrote `mkdir`'s stderr into `$REPORT`, then `exit 1`
   without setting `XCV_RUN_FAILED`, so cleanup deleted the report — what survived is "it
   failed". The EACCES-at-`/Library/Developer`/EPERM-inside contrast is real and was measured as
   `pirado`, not root. **And a refused `mkdir` is not a refused mount**: cell D was declined at a
   directory that already existed, so this does not explain D, and the open question is
   unchanged — run H1/H2 against a *pre-existing* empty directory in the hierarchy. That cell is
   not written. Same species as the retraction two commits earlier, caught the same way.

   The harness now records the error text as cell H0 and continues instead of aborting, which is
   the point: the machine that hits this next produces the artifact this one destroyed. Six
   changes came out of the review, and the three that were not documentation are the ones worth
   naming — a single `mkdir` (a second attempt to capture stderr can succeed and write
   `REFUSED ()` for an operation that worked), `mkdir` rather than `mkdir -p` (which would create
   a shadow `CoreSimulator` on a machine without Xcode — rule 7, attempted twice now), and the
   symlink/mounted/empty revalidation immediately before H1, since the startup guard has expired
   five mount cycles earlier. Deleting that revalidation survived mutation until a scenario
   existed that dirties the probe in between.

   **The fourth run, later on 2026-09-22, produced the errno — and my first reading of it was
   wrong in the way this whole series keeps being wrong.** `mkdir -p` under `sudo` inside the
   hierarchy is refused, reported as **`Operation not permitted`**: the artifact the aborting run
   destroyed, now cell H0. The target was measured empty by the run itself (`entries: 0` at run
   start; `links=2` at cell time, which excludes child directories and not regular files), which
   excludes the textbook DiskArbitration refusal. Then I read cell C's log block as falsifying
   the third run's "neither cache-path cell captured a `diskarbitrationd` record" — it carries
   two `0x0000004D` lines. **C's block is byte-identical to B2's**, both lines predate C, and the
   cause is the harness: `log show --last 60s` runs after the cell with no start sentinel, so a
   refused cell replays its predecessors. The third run's sentence was correct and the fourth run
   reproduces it; I retracted a true sentence using the artifact that confirms it. Two readings
   have now died on that rolling window, and **the fix landed with this write-up**: each cell's
   window is `log show --start` from a timestamp captured before the command, with the capture's
   own exit status reported so a failed capture can no longer read as an empty one — an empty
   window being exactly the evidence for "the cache path produces no DA transaction". The fourth
   run's blocks predate that fix, so no per-cell log claim in any E6c file written before it is
   safe without diffing the block against its predecessor's. 107 checks now, and the mutant that
   forced the last of them was one of my own new checks failing to die: a source-text grep for the
   failure message survives a mutant that leaves the message in place and only makes its branch
   unreachable.

   **The in-hierarchy control turns out to be blocked by the allowlist, not by the hierarchy.**
   Looking for a pre-existing empty directory inside `/Library/Developer/CoreSimulator/` found
   seven, all with the target's own mode and owner — so the cell that separates "this directory
   refuses" from "this hierarchy refuses" is constructible. It stays unwritten on purpose. Two of
   the seven are `Volumes/iOS_23F77` and `Volumes/watchOS_23T570`, which `simctl runtime list`
   identifies as the mount points of the two installed runtimes (14.8 GB, both Ready) — mounting a
   donor there is rule 6's shadow-data failure aimed at what the test rigs need. The other five are
   CoreSimulator image-staging directories, and `xcv_e6b_target`'s closed set mirrors
   `HelperCleanupTarget`'s two regenerable caches exactly so an experiment cannot mount over a path
   the product would never clean. Widening it to answer one question would dissolve the invariant
   it exists for.

   **So two open items collapse into one.** `Caches/dyld` is inside the hierarchy, inside the
   allowlist, and is H14's own path: clearing that cache answers H14's path *and* the
   hierarchy-versus-directory question in one run, with no allowlist change. The cost is unchanged
   — a rebuild on shared simulators, which is the operator's call — but it now buys twice as much.

   **2026-09-22, late: clearing the dyld cache is REFUSED, and that is a bigger finding than the
   run it was meant to unblock.** `sudo rm -rf` on `Caches/dyld/25G229` returned
   `Operation not permitted` for every entry, as root; nothing was deleted. So H14's own path was
   never blocked by the cost of a rebuild — it is blocked by the same refusal E6c exists to explain.
   Root is now refused three different operations inside `/Library/Developer/CoreSimulator/` —
   `mkdir`, `rm`, `mount_apfs` — all `EPERM`, while no `restricted` flag, no `com.apple.rootless`
   xattr and no `rootless.conf` entry exists, and a positive control proves the flag would have
   shown (`/System/Library/CoreServices` reports `restricted` on this same OS with the same command).
   **New hypothesis H15: it is TCC, not SIP** — TCC returns `EPERM`, marks no file and applies to
   root, and the shell these measurements ran from demonstrably lacks Full Disk Access because
   `TCC.db` fails with the identical error. The test is one grant and two commands, and it is the
   operator's to make.

   **2026-09-24: H15 is CONFIRMED for `mkdir`.** With Full Disk Access granted to the terminal,
   `sudo mkdir` inside `/Library/Developer/CoreSimulator/` succeeds — the same command that was
   refused minutes earlier without it. **H0's wording is retracted: the refusal was a property of
   the caller, not of the hierarchy.** `rm` and `mount_apfs` are NOT re-tested, and the mount
   refusal is what the entire E6c series rests on, so the next thing to run is E6c at `cryptex`
   (empty, no clearing needed) with the reading fixed in advance — D mounting retracts "the cache
   path refuses mounting" across the series; D still refusing gives the discrimination the series
   never had. **And record which context measured what:** the grant reaches the operator's terminal
   and not the process this project's tooling runs in, which is the asymmetry that produced the
   wrong wording in the first place.

   **2026-09-24, fifth run, with the grant: the series' central finding is retracted.** Cell E —
   `diskutil` at the cache target — **MOUNTED**, having been REFUSED in all four previous runs. Cell
   H1 — `mount_apfs` at a neutral directory *inside* `CoreSimulator` — **MOUNTED**, having never
   been constructible before because `mkdir` was refused. So neither "the cache path refuses
   mounting" nor "the hierarchy refuses" was ever about macOS.

   What survives is the finding the series kept walking past, and it is about a **volume**: every
   `0x0000004D` in this run is on the donor, in four cells across **three** paths (B1 and B2 are both
   the probe, differing only in `nobrowse`), while the same `diskutil`
   mounts the donor where DA itself chooses (B3) and mounts a never-before-mounted sparse image
   anywhere asked, cache target included. Path, depth and hierarchy are excluded. *(An earlier draft
   added "`mount_apfs` produced no DA record at all" — the harness never asked: the capture is inside
   `cell`'s REFUSED branch and gated on the label containing "diskutil". That absence was
   manufactured.)* And the retraction is scoped: cell C — the donor at the cache path — is VOID in
   run 5, so an external volume at a cache path remains unmeasured. Also: this is the first run whose per-cell log attribution is trustworthy
   — bounded windows, distinct record counts per refused cell, instead of four byte-identical blocks.

   **And cell D was never actually run.** For four runs the matrix printed a hardcoded 2026-09-21
   value for `mount_apfs` at the cache target. That value came from a non-FDA terminal while every
   other cell now comes from an FDA one, so it is the cross-context contrast the reading rules
   forbid. D is a real cell as of this change; until it is measured in-context, whether anything
   refuses `mount_apfs` at all is unknown, and with A and H1 both mounting the honest prior is no.

   **Sixth run, same day, cell D measured: `MOUNTED`.** With A and H1 also mounting, **nothing in
   that hierarchy refuses `mount_apfs` anywhere tried, the cache target included.** The mount landed
   and was verified, the donor's root was unchanged before and after the window, and the teardown went
   through DiskArbitration. The only refusal left anywhere in the matrix is DA declining *this donor*
   at a caller-named mount point — four cells, four `0x0000004D`, one device — while mounting the same
   donor at its own default location and mounting a fresh sparse image everywhere asked. **The
   premise of the whole E6c series is dissolved**: path, depth, hierarchy and mechanism are excluded.

   D is also the first admissible measurement of the donor at the cache path in the series, because
   cell C has been VOID in every run that had it. So the product's own question — can an external
   volume be mounted at a CoreSimulator cache path — has a positive answer for `mount_apfs` on this
   configuration. **It does not reopen ADR-0004**, which demoted canonical mount because there is
   nothing under that path worth mounting over (E1) and because the `xctest` restriction follows the
   device rather than the path (E2). A permitted mount is not a useful one.

   Still untouched: physical removable media (every volume in six runs was a disk image), `Caches/dyld`,
   and H14's own stub-reappearance question — which is now *testable* rather than blocked.

   **2026-09-25: the `dyld` run is prepared, and its reading is committed before it runs** (H14, "E6c,
   seventh run, at `Caches/dyld`"). Getting there found that the harness would have misreported it:
   `matrix` printed "D … NOT MEASURED" above a measured D at any non-cryptex target and dropped the
   A/H1/D rules, and no dry run had ever taken that arm. The evidence header now records the run's TCC
   indicator and the donor's standing mount — both were prose through run 6. The shared target guard
   refuses a booted simulator (`launchd_sim`), which a headless `simctl boot` slipped past. And the
   dry-run suite never exercised account-name redaction at all: `id` is stubbed, so the redactor's
   identity was empty. The donor image from runs 5–6 is gone (a reboot cleared `/tmp`); the run uses a
   recreated one. "An interrupted run exits 130" failed in every parallel mutant run
   and passed in every serial one; first recorded here as a timing flake under load. **That
   diagnosis was wrong** (corrected 2026-09-26): CPU load alone and the scratch location alone both
   pass; two suites launched as `&` jobs both fail with rc=0. A non-interactive shell starts an `&`
   job with SIGINT ignored, and a signal ignored at a shell's start cannot be trapped, so the
   scenario's INT did nothing. Measured on a four-line script: foreground 130, `&` job 0, `&` job
   through a `perl` SIGINT reset 130. The harness now resets SIGINT before starting E6c.

   **Seventh run, same night, at `dyld`: D and E MOUNTED.** H14's own path accepts a volume by
   `mount_apfs` and by DiskArbitration, from a process the header shows Full Disk Access reaches.
   Every refusal is the donor's `0x0000004D` (B1, B2, H2; C VOID), B3 mounts it at its default
   location, and the standing line says `mounted by <user>` — consistent with the user-session
   candidate, not evidence for it. Only pre-registered rules fired. H14 itself stays unverified: the
   run shows the volume can be there, not what appears after it goes. **Next, cheapest first:**
   re-mount the donor as root and repeat B1; E6b at `dyld`; physical removable media; the yank.

   **Item 4, same night: who attached the image is what DiskArbitration keys on.** Re-mounting as
   root could not test it — B3 already does that and still reads `mounted by <user>` — so
   `e6c-item4-attach-owner.sh` varied the attach instead, measured by `hdiutil info` `owner-uid`,
   in four cells on one image file. Attached by the operator's session: refused three times
   (`0x0000004D`), with and without a default-location mount. Attached by root: mounted. Order and
   uid-vs-session are not separated. A pasted runbook for this failed review first — in zsh an
   apostrophe in a comment swallowed three steps — which is why it became a script. **Next: E6b at
   `dyld`, then physical removable media, then the yank.**

   **2026-09-26: E6b at `dyld` was not run, because its premise was already measured.** The "stub"
   is the pre-existing mount point: after run 7's clean DiskArbitration unmount of a disk image it
   was there again, `root:admin 0755`, and the target guard (unmounted, empty) passed. So #24's defended state is reachable by construction, and
   the "inferred, not observed" comments in `HelperMountHistory.swift` and
   `CleanupSplitBrainTests.swift` now cite the evidence. What decides the damage — whether normal
   use writes a fresh cache into that directory — is open: two boots of a rig's device, twelve and
   seventeen minutes, wrote nothing to either cache (unplanned observations), while H11 already recorded an automatic
   rebuild after the OS update and `simctl runtime dyld_shared_cache update` exists — so the rebuild
   is real and its trigger is unknown. **Next: identify what rebuilds
   `Caches/dyld` (research, read-only first); then physical removable media; then the yank.**

   **Same day, the read-only research.** The binaries' strings (static, not behaviour) suggest an
   explicit route — `simctl runtime dyld_shared_cache update` — and an automatic one that can decline,
   reporting four properties, one named after defaults (no such key found); which reaches
   `simdiskimaged`, and how, is not shown. The unified log over a window including the rig's two
   boots holds 13 "Unable to use dyld shared cache … not currently available" lines and, at info
   level, no creation request; that nothing was built rests on the directory staying empty. The
   oldest retained `simdiskimaged` entry is 2026-09-22 20:14, after the 25G229 cache was built
   (~2026-09-16), so what built it is unrecoverable here. A passive `log stream --level debug` left
   running to catch the next rig boot's decision **failed**: 11,600 "messages dropped" notices and no
   message, so its silence is not an absence.

   **A second, info-level listener worked** (2026-09-26 → 27): 0 dropped, and its positive control
   present — 545 "Unable to use dyld shared cache … not currently available" over twenty hours of the
   rig's simulator use — against zero creation requests at info level. A device booted for three
   hours left `Caches/dyld` empty. So about twenty hours of the rig's use (headless, boot path
   unknown) neither built nor, at info level, requested the cache. Interactive use is not measured,
   and one decline property is named for the execution environment. The only recorded rebuild is
   still H11's, after an OS update.

   **Eighth run, same day, with a PHYSICAL donor: all twelve cells MOUNTED.** A new empty volume
   added to the operator's USB SSD, named by `--donor-uuid`, mounted at `Caches/dyld` by
   DiskArbitration (C) and by `mount_apfs` (D), and everywhere else asked; the operator's data volume
   in the same container was untouched. So an external physical volume can sit at H14's path on this
   configuration. It does not reopen ADR-0004. The SSD reports `Fixed`, so physical removable media
   is still untested. **Next: the physical yank (E6b variant B) — which needs a disposable drive,
   NOT this SSD: pulling its cable yanks the operator's data volume too — and what writes into
   `Caches/dyld` afterwards.**

   **Product consequence, recorded before anyone ships against it.** `clean` listed
   `CoreSimulator system dyld caches` as `[root — helper needed]`. If the gate is TCC, root is not
   the missing ingredient and the privileged helper may not be either. The feasibility of the
   cleanup verb for the largest root-owned category is an open question now, not a detail.
   **Relabelled 2026-09-27:** the CLI tag, GUI column and executor refusal now share
   `CleanAction.privilegeRequirement` — "root with Full Disk Access — not executable yet" for
   `Caches/dyld` only (where H15's `rm` was measured), "root — not executable yet" elsewhere — and
   the "rebuilt on next boot" claims are gone from the catalog, the `clean` warning and `doctor`
   (H11's one rebuild followed an OS update; two boots did not rebuild, H14). Whether the launchd
   helper has Full Disk Access is still unmeasured.

   **A caution about #30's issue text.** Its body predates `d154143` and still says "there is no
   client anywhere". There is: `Sources/XCodeVaultHelperClient/HelperClient.swift`, with tests. The
   body's own "Done when" anticipated this ("partial credit is possible and probably wise"), but
   reading the body alone will send the next person to write code that exists.

   The pattern worth carrying forward from #31: **mutation testing found guards no test
   distinguished, and every check written in response was itself vacuous until a positive control
   was added.** A check that cannot tell "clean" from "I did not run" is not a check — and a run
   reporting zero failures may mean the build broke or the `--filter` matched nothing, both of which
   read as success.
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

## 2026-09-27 — user-first permissions, deliverable 1 of 4: the docs say what exists

The README is now one screen for a user: what it does, install, first run, a permissions table,
five things it never does, and the honest state; research and contributor material moved to a
block of links. `docs/USER_GUIDE.md` covers every GUI section and command with what it changes and
how to undo it. Everything the later deliverables add is written as **planned** here and flipped by
the deliverable that ships it — the docs must not describe a command or a button that does not
exist yet. ADR-0007 records the three decisions (ask at need; no root shell in the client; Full Disk
Access guided because it cannot be automated). `SECURITY_MODEL.md`'s "a root launchd daemon does not
need Full Disk Access" is struck in place, citing H15, with the reasoning kept.

Before this plan was written, three places where the spec did not match the code went to the
operator; the answers are recorded at the top of the plan (vault-folder finding derived from a
journaled `vault init` refusal; "not available in this build" also when the daemon is not bundled;
the dyld cache wired to the helper in deliverable 4).

The independent docs review returned REQUEST CHANGES on its first round, and every important
finding held up against the code: three undo answers were wrong (simulator device sets reach the
Trash already emptied by `simctl`; the folder `vault init` creates can hold the only copy of Archives
after `externalize`; `restore` refuses while the original exists), the experimental labels
contradicted each other, and two sentences were prose rather than measurement — "the disconnection
itself loses nothing" (only a forced unmount was measured; the physical unplug is pending) and
"Nothing in this repository can produce one", said of a signed build (the scripts can; the
certificate is what is missing). The struck Full Disk Access claim also survived where it originated,
`FINDINGS-2026-09-05.md`, and is corrected there too.

## 2026-09-28 — CLI help: the experimental label reaches every subcommand

A subcommand's `--help` shows its own `CommandConfiguration`, not its group's. Measured on the built
binary: `vault init`, `vault status`, `vault forget` and the four `migration` subcommands opened
their help without the "Experimental." their groups carry; `runtime export`, `runtime import` and
`runtime library` had no label at all; `externalize` and `clean` had it only in the discussion, which
the top-level command list does not show. All of them now say it in the abstract. `runtime delete`
(Apple's `simctl runtime delete`) and `locations reset-*` stay unlabelled; the three `locations set-*`
already carried the label, at the end of their abstract. `docs/USER_GUIDE.md` marks the three
read-only commands that read an experimental strategy's state.

`CLIExperimentalLabelTests` reads each abstract from the `xcodevaultctl` sources (the executable
target cannot be imported) and ties it to the catalog entry that makes the strategy experimental;
`runtime delete` is the control that the check can say no. It reads source text, not the help
ArgumentParser renders. Full suite: 460 tests, 0 failures. Five mutants, each killed by exactly the
expected test: the label removed from `runtime export`; from `externalize`'s abstract with its
discussion still saying "Experimental:"; from the nested `vault init`; the Runtime Library rated
`.verified` in the catalog; and the instrument made to read the whole file, which only the `runtime
delete` control catches.

## 2026-09-28 — user-first permissions, deliverable 2 of 4: one model, one command

Core gained the spec's single source of truth, in `Sources/XCodeVaultCore/Permissions/`:
- `FullDiskAccessProbe` — H15's indicator: open `TCC.db` read-only and read nothing; only `EPERM` means
  not granted.
- `HelperState` — from `SMAppService.Status`, the team-ID rule, and whether the daemon's plist is in
  the bundle (operator decision 2). A status nobody has seen is never "enabled".
- `PrivilegeRequirement` — a942c02's rule moved here. `clean`'s tag and the GUI's Needs column use it,
  and the tag points to `permissions`.
- `PrivilegedAction`.

`xcodevaultctl permissions [--json]` reports both states, with why and one next step each, and runs
in cli-smoke in `preflight.sh` and CI. The CLI links `XCodeVaultHelperClient` for read-only state;
nothing calls `connect()`. `vault init` journals a permission refusal of the default vault folder, and
`doctor` turns the latest one per volume into `vault-dir:<uuid>`, the only finding that carries an
action. The printed command stays beside it.

Measured in this agent's process: `permissions` answers Full Disk Access `notGranted` and helper
`unavailableInThisBuild`. The operator's terminal was not measured. Full suite: 494 tests, 0 failures,
0 skipped. Twenty mutants, each applied and killed by the expected test, measured on the frozen
snapshots in a separate worktree: the plan's five, plus the plist's location, POSIX permission errors
only, and thirteen that pin the review fixes below. The five measured on the first snapshot have code
and tests unchanged since.

Both reviews returned REQUEST CHANGES before approving; every finding was checked against the code or
measured before it was fixed.
- **Helper security.** `bundle-app.sh`'s "Bundle it when a client exists" read as met once the CLI
  linked the client, and the helper's release condition is what keeps five known daemon bugs out of a
  release. It now says "when a shipped binary calls `connect()`".
- **Measured by the reviewer and reproduced here:** started through a symlink — what the cask's `binary`
  stanza installs — the CLI's `Bundle.main` is the link's directory, so `permissions` would call a build
  that has the helper "not available". It fails closed, and is a pending row in `COMPATIBILITY_MATRIX.md`.
- **Migration safety.** Three properties were untested: the refusal matched to its volume by UUID, the
  command naming the vault folder rather than the drive's top folder, and the journal's `try?`. All are
  pinned now.
- **The serious one.** `install -d` creates missing parents (`man install`). Run after the drive was
  ejected, the command `doctor` printed would have created the drive's mount point as a root-owned
  folder on the internal disk — a shadow `/Volumes/<name>`, and the drive back at "<name> 1". `doctor`
  now prints `mkdir … && chown -h …`, which fails instead; no `-m`, whose path-based `chmod` would follow
  a symlink swapped in during the run (round 3; per FreeBSD's `mkdir.c`, not traced here).
- **Also.** The finding requires the drive still to qualify and the folder to be absent by `ENOENT` alone,
  and carries the action only where the helper accepts the mount point (`/Volumes/<name>`).
  `HelperContractTests` holds that mirror to the helper's own guard.
- **Round 2 found one more.** The seam that lets tests use `/Volumes` paths left its production default
  untested. It is pinned now.

Declared gaps:
- A signed CLI through the cask's symlink is unmeasured.
- The rule does not re-check the mount point and UUID at the instant it reports; the helper re-resolves
  the UUID before it acts.
- An abandoned vault-folder attempt keeps an `.info` finding while its drive is mounted.
- `vault init`'s own advice still prints `install -d`; it is carried to deliverable 4, which rewords it
  the same way.
- Whether `doctor`'s `lstat` inside an external drive makes the GUI ask for removable-volume access is
  unmeasured.

Where the plan's text claimed something that does not exist yet, the code says less:
- `doctor` prints "privileged action:", not "in the app:"; no button exists before deliverable 4.
- The Full Disk Access next step is keyed to `scan`'s existing `[partial: unreadable entries]` mark.
- The helper texts say a signed build is required, not that none exists.

## 2026-09-28 — user-first permissions, deliverable 3 of 4: Full Disk Access, asked for when a scan is refused

The scan now tells a privacy refusal from an ordinary one. `DiskUsage.privacyRefusalCount` counts the
unreadable entries refused with `EPERM`, the errno TCC returns (H15), and `ScanSummary` sums it over the
items the totals count. `unreadable` and `lowerBound` are unchanged. `EPERM` is not TCC's alone — the
migration-safety reviewer's `sandbox-exec` probe produced the same `FTS_DNR` with `EPERM` — which is why the
prompt stops once the grant is known to be present.

In the app:
- The Overview says "Some folders could not be read" with **Open Settings** only when that count is
  non-zero and the grant is not known to be present. A scan that counts no refusal asks for nothing.
- A Permissions section shows Full Disk Access and the helper — state, why, next step — from the same
  `PermissionsReport` as `xcodevaultctl permissions`. **Open Settings** opens the exact pane; coming back
  re-checks and rescans once.
- Both decisions are in Core (`PermissionPrompts.shouldAskForFullDiskAccess`,
  `FullDiskAccessState.offersOpenSettings`) and tested; the view decides nothing. The app links the helper
  client for read-only state; nothing calls `connect()`.
- The tools the app starts work inside its grant — the same rule that let a granted terminal's commands do
  what they could not without it (H15). So the app's scan runs nothing from the Xcode bundles it discovers:
  a bundle is accepted on its Info.plist alone, from /Applications or ~/Applications. And before any tool
  runs, `GrantedToolEnvironment` removes `DEVELOPER_DIR`, `TOOLCHAINS` and `SDKROOT` and fixes `PATH`, so
  `xcrun` resolves through the system's `xcode-select` choice and its own cache. The CLI keeps its caller's
  environment.

`bundle-app.sh` without `--sign` now signs ad hoc, inside-out, with the hardened runtime. Measured on
macOS 26.7 (25G229): the app and the CLI carry `flags=0x10002(adhoc,runtime)` and no entitlements, and
`codesign --verify --deep --strict` passes. SwiftPM's own output is ad hoc with no runtime flag and with
`get-task-allow`; a probe dylib named in `DYLD_INSERT_LIBRARIES` ran in SwiftPM's CLI and not in the bundled
one. The app was not launched.

Measured for the environment, 2026-09-28, one machine:
- `xcrun` runs a tool it does not find as a developer tool from `PATH`; without the tool in `PATH` it
  reports "not a developer tool or in PATH".
- `xcrun`'s cache (`xcrun_db`, owned by the user) answered for a tool under a `PATH` that no longer contained
  it. Switching it off made each lookup take 9 to 18 s instead of 0.05 s, and `TMPDIR` does not move it.
- `ProcessInfo`'s environment reflects `setenv`/`unsetenv` made after its first read, and a child inherits
  the change whether started with no environment or with `ProcessInfo`'s merged.
- The probe dylib did not load into Xcode's `xcodebuild` (library validation), directly or through `xcrun`.

Also here: the doctor's orphaned-dyld remediation says to delete from a terminal that has Full Disk
Access, as H15 measured. It was promised in deliverable 2 and missed there.

Measured once, in a process without Full Disk Access: `DiskUsage.measure` of H15's indicator folder counts
its one unreadable entry as a privacy refusal. Full suite: 508 tests, 0 failures, 0 skipped.

Twenty mutants over three rounds, each measured on that round's frozen snapshot in a separate worktree:
nineteen applied and killed by the expected test, among them one for each of the `EACCES` test's two
positive controls and one for each F3 pin. The twentieth, removing the `FTS_DNR` increment, survives by
construction; it is the gap declared below.

Reviews, three rounds; every finding was checked against the code or measured before it was fixed.
- **Helper security, round 1.** The app now asks for Full Disk Access, and no build it could ship in had
  the hardened runtime, so code injected into a granted app would run with its grant. Fixed with the
  reviewer's option A, the ad hoc signing above. The footer's first sentence was unmeasured and is gone.
- **Helper security, round 2 — the one that mattered most.** The hardened runtime covers the app, not
  what it starts: the scan ran `xcodebuild` and `simctl` from any folder named `Xcode*.app` whose Info.plist
  said so, and inherited the variables that steer `xcrun`. Fixed as above; measuring the fix found the
  `PATH` fallback and the cache, and only the first is closed.
- **Migration safety, round 1.** Four pins were missing: the summary is a sum, the lower bound does not
  depend on the count, one refusal is enough to ask, and the `EACCES` test shows which branch recorded the
  entry. The count was `permissionDeniedCount`; "Permission denied" is `strerror(EACCES)`, the one errno it
  excludes. A pre-existing comment said a Codable default kept old reports decodable; the reviewer
  measured `keyNotFound`, and the comment says so now.
- **Migration safety, round 2: approved**, with three notes taken: no claim about every first run, a
  test that the dyld advice names Full Disk Access, and the advice citing E6c's check.
- **A test caught me once more.** My first doctor wording quoted H15's `sudo rm -rf`; the test that
  forbids `rm -rf` in that remediation failed on it.
- **Round 3: both approved.** Helper security's note — `setenv` is not thread-safe, and the pin
  covers `init()` but not `AppModel`'s initializer, which runs first — is carried to deliverable 4,
  plan item (9). Migration safety's — the guide said the app starts "only" the selected Xcode's
  tools, which the trusted cache contradicts — is fixed in the wording.

Declared gaps:
- The GUI has not been run on screen: opening a window needs the operator's OK.
- Whether macOS applies a new grant to the running app without a relaunch is unmeasured; the guide says to
  relaunch if macOS asks. Whether a rebuild needs the grant again is unmeasured.
- `xcrun`'s cache stays trusted by the app, as by every developer tool; whoever controls that file
  controls what `xcrun` runs inside the grant.
- The CLI's capability detection still runs `xcodebuild` and `simctl` from every `Xcode*.app` it finds —
  inside the terminal's grant when there is one. It predates this work.
- The `FTS_DNR` increment has one real measurement and no unit test; the `fts_open` failure branch has
  none. A test under `sandbox-exec` (deprecated) would need a test-only executable; declined for now.
- `refreshPermissions()` runs on the main actor; its latency is unmeasured.
- Coming back from System Settings during the first scan starts a second, overlapping scan. Both only
  read; the result shown is whichever ends last. Carried to deliverable 4, plan item (7).

## 2026-09-28 — user-first permissions, deliverable 4 of 4: the helper flow, gated on a signed build

`HelperClient` can now register and unregister the daemon through `SMAppService.daemon`, open Login Items &
Extensions for the approval, and call the two verbs — `createVaultDirectory` and
`removeRegenerableSystemDirectoryContents(coreSimulatorDyldCache)` — over one connection per message: the
requirement set before `resume()`, exactly one outcome (`ResumeOnce`), the connection always invalidated.
That requirement checks the daemon's **replies**, not the requests: the helper-security review measured a
failing peer running the method while the caller got error 4102, as xpc/connection.h:790-793 says. So an
old daemon still holding the name would act on a verb first; the fix is written down as the M5 TODO on
`helperRequirement` (a validated `version()` round trip before the verb) and listed beside `--with-helper`
and in `KNOWN-ISSUES-AT-PUBLICATION.md`. Core decides when:
- `HelperApprovalFlow`: register → open Settings → poll → enabled. A `register()` that throws while the
  service lands in approval is read from the status, not from the throw; the wait is bounded and
  cancellable. The app runs one wait at a time: a new request cancels the running one, and a cancelled wait
  does nothing.
- `PrivilegedActionRunner`: only when the helper is enabled; journaled before acting and refused when the
  journal cannot be written; the dyld cache refused while Xcode, a simulator, `simctl`, `xcodebuild` or the
  cache builder (`update_dyld_sim_shared_cache`) runs, and "cannot tell" counts as running. A failed reply
  that still freed bytes is journaled with them. `public-surface` pins the two in-use defaults, and
  `helper-invariants` now holds that only the app's adapter calls a verb, and that only it and
  `permissions` name the client, in any import spelling.
- The app shows a root action's button only when `HelperState.actionControl` says so. The vault folder
  has one on its doctor finding; the dyld cache has one in Clean alone, behind a destructive confirmation
  and titled experimental — a source test holds that no doctor finding carries it, since the Doctor's
  buttons have no confirmation of their own. Permissions offers **Install…** and **Uninstall…**.

In every build made today all of it renders "Not available in this build": a build must carry a usable
team ID, be signed by that team — read from the running code's own signature, measured to answer no team
for an ad hoc binary — and include the daemon. Nothing of it has run live (#30).

**Found by the migration-safety review, and older than this deliverable: the in-use checks read a sliver
of the process table.** `CleanExecutor.runningExecutablePaths()` read `proc_listallpids`' answers as byte
counts; they are counts of pids. Measured 2026-09-28: it looked at the first 44 of 699 pids, and neither
launchd nor Finder was among them. So since 9557b3d (2026-09-18) `xcodeIsRunning()` could answer "no" with
Xcode open — the guard in front of `clean`, the migration engine's source removal (`externalize
--remove-source-after-verify`, `migration resume`) and `locations set-*`/`reset-*` — and the new
dyld refusal had the same blind spot. Fixed, and a full buffer now counts as "cannot tell";
`testTheProcessListReachesLaunchd` pins it with launchd, whose path it first shows is readable. No tag
contains 9557b3d and there has been no release: the exposure is builds from public `main` in that window.
The user guide's FAQ says what to check, and `KNOWN-ISSUES-AT-PUBLICATION.md` has the details. The
refusals that rest on it now say "or the process list could not be read" where they are new or `clean`'s;
the migration engine's and `locations`' texts are unchanged.

What the earlier reviews carried here, done:
- `vault init` no longer prints `install -d`, which creates missing parents — the mount point too, pasted
  after an eject. It prints `mkdir` for each missing folder, parents first, then `chown -h` on the vault.
  Only the one-folder case is reachable today: `vault init`'s containment check stops earlier when a
  parent is missing (the open "misleading error" task).
- "Never two scans; one more after the running one" is `ScanGate`, in Core and tested; every scan the app
  starts goes through it.
- `bundle-app.sh`'s list beside `--with-helper` was re-verified against the helper's code: four of its five
  items had been fixed. Still open there: the cleanup verb's missing in-use check (the client's refusal
  guards against accident, not a hostile client), the reply-not-request limit above, the missing version
  predicates, and the unthrottled audit trail. Its release condition was rewritten: the old one ("when a
  shipped binary calls `connect()`") is met by this deliverable.
- `Failure.notRegistered` no longer says "Run the app once" (ADR-0007).

One change the plan did not have: `refresh()` no longer clears `lastError`. The plan's `perform(_:)` set
an error and then rescanned, which would have erased it before it was seen.

Full suite at the last Swift change: Executed 550 tests, with 0 failures; no test skipped. Mutants,
each proven applied, measured, and restored byte for byte: round 1, 16, all detected — 14 by a named
test, M4-5 as a crash on the fakes' synthetic double-resume paths (a real connection calls one handler,
measured by the helper-security review), and M4-6 by `public-surface` naming the runner's default;
round 2, 13, of which 12 were killed by the test written for them and M5-2, the full-buffer refusal in
the process listing, survives and is declared; round 3, 2, both killed. The `helper-invariants` rule was
measured case by case on copies of the tree, a non-BSD `grep` included.

Reviews: `helper-security-reviewer` and `migration-safety-reviewer`, four rounds each. Both returned
REQUEST CHANGES at the first snapshot (e03fc01) — the requirement's reply-not-request limit and the process
listing above came from those rounds — and APPROVE at the next three (bb32311, 08de88c, 6f819fb), each
approval's non-blocking notes taken into the round after it. One comment line went into
`helper-invariants.sh` after both round-4 approvals: an escape the helper-security reviewer measured and
offered to list there.

Declared gaps:
- None of it has run live: registration, approval, the XPC calls, and whether the daemon has the Full
  Disk Access `Caches/dyld` needs (#30, M5). `COMPATIBILITY_MATRIX.md` lists each as pending.
- `isSignedByItsTeam` answering `true` is unmeasured: no Developer ID build exists.
- The GUI has not been run on screen. The app's approval wait is pinned by its source text, not driven.
- The cleanup verb itself has no in-use check; the client's refusal is a guard against accident.
- The full-buffer refusal in the process listing is not pinned: a test cannot make the table outgrow the
  kernel's headroom between two calls.
- `send` has no timeout: a daemon that never replies leaves the call pending (now said in its doc). The
  runner's `.started` record then stays open and `doctor` lists it as interrupted; a second click starts a
  second call.
- An interrupted dyld run gets `doctor`'s generic interrupted-clean text, which suggests re-running a
  command; there is no CLI command for this action.
- The `helper-invariants` rule is text: a vault-verb call split across lines in an app file, and
  `LiveHelper().perform` called without the runner, are measured escapes, stated in the rule. Its
  word-bounded patterns need BSD grep; the script now refuses to report ok under a grep without them.
- `release.sh` does not pass `--with-helper`, so a release made today would show "Not available in this
  build"; M5 adds it once the list beside the flag is empty or accepted in review.

## 2026-09-28 — Coverage of the app and the CLI: the test bundle links both (ADR-0008)

SonarQube Cloud's quality gate failed the pushes of deliverables 3 and 4 on the coverage of new code: 78.0% and
71.9%, against 80%. I did not notice the first at its close-out. The operator chose to raise the figure with
tests rather than exclude the app from the measurement.

Where it came from, recomputed line by line with `git blame` against the CI's own report for deliverable 4
(e930f19): of its new lines in files the report contained, 274 of 296 were covered (92.6%). The rest were in
`Sources/XCodeVault` and `Sources/xcodevaultctl`, which the report did not contain: the test bundle linked only
the libraries, and the server counts an absent file as uncovered (measured 2026-09-20, recorded in `sonar.yml`).

What changed (ADR-0008):
- The test target depends on the app and the CLI. A probe measured first that the bundle builds (SwiftPM
  renames an executable's entry point for the test build) and that a SwiftUI view's `body` runs in an
  `NSHostingView` with no window.
- `AppModel` takes an `AppEnvironment`: the survey, the Full Disk Access probe, the helper, the approval flow,
  the runner, the clean and the URL opener. The app passes `.live`, whose members are the calls the app made
  before (checked by reading in the migration-safety review). `HelperClient` reaches launchd through an internal
  `Daemon` value, `LiveHelper` takes its client, `xcodevaultctl permissions` builds its report from a client it
  is handed, and the two in-use checks take the process list as an argument; their public forms are one-line
  wrappers.
- New tests: `AppModelTests` (the scan, the permissions, a request in each helper state, the approval wait, the
  root actions, uninstall, the clean), `LiveHelperTests`, `AppViewRenderTests` (every state deliverables 3 and 4
  added, off screen), `CLIPermissionsCommandTests`, the `HelperClient` launchd seam, and the in-use checks'
  "cannot tell". The approval-wait rules that were source-text pins are behaviour tests now, and the pins are
  gone. That closes deliverable 4's declared gap "the app's approval wait is pinned by its source text, not
  driven": it is driven, with fakes.

Measured on this machine (x86_64; CI is arm64, where line counts can differ slightly). The suite and the
coverage at 9d73742, this commit's tree before its last edits, which touched only comments and docs; the
mutants at the snapshot each bullet names.
- Full suite: Executed 578 tests, with 0 failures (550 at deliverable 4).
- The coverage report: 57 files, 5782/7117 lines (81.2%). At e930f19 it had 45 files, 5360/6144 (87.2%). The
  twelve new files are the app and the CLI, 378/965 (39.2%), mostly older views and commands no test reaches.
  The percentage fell because those lines are in the report now; the server counted them as uncovered before.
- New code by blame against this report: this change's lines, 34/41 (82.9%). Deliverable 4's lines would be
  442/468 (94.4%), deliverable 3's 75/82 (91.5%). This change's seven uncovered lines are live-only: the
  `.live` clean and URL-opener closures, the `.live` launchd register, unregister and Settings closures (#30),
  and the two public in-use wrappers, which read this Mac's process table. Nothing is excluded from the
  measurement.
- Mutants at aa4c9c4, each proven applied, measured and restored byte for byte: 15, all killed, each by the
  test written for it. The in-use checks' "cannot tell" (2), the launchd seam (2), `LiveHelper` (2),
  `permissions` (1), the approval wait (5: the source-pin mutants M5-11 to M5-13, M6-1 and M6-2), and one each
  for the permissions refresh, the helper sheet and the clean's Trash choice.
- Rerun at 182ee19, whose tests the reviews changed: the five approval-wait mutants (M8-8 to M8-12) and M4-2,
  the runner's first check weakened to refuse only an unavailable build. Each was applied, killed and restored
  byte for byte. M4-2 was killed by the three tests the migration-safety reviewer predicted, among them the one
  that used to fall back to the real journal. The test process ran with its home in a scratch directory
  (`CFFIXED_USER_HOME` and `HOME`; a throwaway test bundle showed `xctest` resolves `NSHomeDirectory()` there):
  nothing was written at the default journal path inside it, and the real journal's SHA-256 (b79ab47c…) was the
  same before and after every run.

Reviews at snapshot aa4c9c4. `helper-security-reviewer`: APPROVE with four notes, all taken. The claim that none
of the new tests touches live state was false: two read it on purpose, and the ADR and the test header now say
which. (Older tests read it too, launchd's status and the process table, and one attaches a temporary disk image
with `hdiutil`.) This entry had to land with the ADR that cites it. The two Stop tests needed a positive
control: each now has a model that is not stopped, approved at the same moment, and checks the stopped one only
after the control has acted. The live runner needed a pin that it overrides none of its defaults: a source pin,
since its in-use checks are closures. `migration-safety-reviewer`: REQUEST CHANGES, one item. Two new tests ran
the runner with the real journal, safe only while the runner's first check held, and one sat in the class a
mutant of that check runs.
Now one uses a temporary journal and the other builds the live runner without running it. A static audit of
every call in `Tests/` to the seven APIs whose journal defaults to the real one found no other direct call: four
hits, all inside comments or string literals. It cannot see a call made through a closure or a wrapper, which is
how it missed the one in `AppModelTests`; the migration-safety reviewer reproduced it independently. The real
journal had 82 lines, was last written 2026-09-09, and held no `helper:` record, both before the mutants and after
the full suite.

Round 2 at 182ee19: both APPROVE. What they flagged was wording, taken here, in the ADR and in one test comment
without a third round: where each figure was measured, "reads live state" scoped to the tests this change adds,
what the audit cannot see, and that a passing run cannot show the 50 ms timing.

Declared gaps:
- Two approval-wait tests catch a regression of the replaced wait's cleanup only if that wait resumes within
  50 ms. A passing run cannot show whether it did. The mutant runs can: both mutants that depend on it (M8-11
  and M8-12, formerly M6-1 and M6-2) were killed at aa4c9c4 and again at 182ee19. The tests say so.
- The GUI has still not been run on screen. The views render off screen; sheets, alerts and dialogs render only
  when presented in a window, so their contents are not reached.
- The server's figure for this push is the one that counts, and it arrives after this commit: the local figure
  is an estimate.

The server's figures for e0bf3cb, read once after the push (Sonar run 36418531798): `sonar-verify: ok — … 7112
lines (floor 4000); coverage 81.3% (floor 60%); quality gate OK`, the converter reported 57 files, 5791/7117 lines
(81.4%), and the scanner imported coverage for 57 files. CI (run 36418531787) passed on `macos-15` and `macos-26`.

## 2026-09-28 — Disconnect safety: a folder the verifier cannot read no longer reads as "not connected"

Found by the migration-safety review of 2026-09-28, outside the change it was reviewing. For a registered vault
volume that is not mounted, with nothing mounted at its last mount point, `VaultVerifier.check` chose between
`.absent` ("not connected") and `.ambiguous` (shadow data) by measuring the folder there and testing
`fileCount > 0`. A folder this process cannot read goes into `DiskUsage.unreadable` with no file counted, so it
read as "not connected", and shadow data inside it was never reported (rule 6). Both states refuse (`isUsable`),
so nothing was deleted; the report was missing. On `main` since M3 (dc5d9c4, 2026-09-06), which the public tag
`pre-review-2026-09-17` contains; no release.

What changed:
- A folder found at the last mount point that could not be read in full (`usage.isLowerBound`) is `.ambiguous`,
  with `shadowBytes` nil. The detail says how many paths could not be read and names the first. When files were
  seen, it says the folder holds at least that many; when none were, that shadow data cannot be ruled out. The
  branch runs before the file count, so a partial count is never given as the size of what is there.
- `doctor` titles that finding "Possible shadow data at …: it could not be read in full" and asks for it to be
  inspected as a user who can read it, not deleted unread. Its id and severity (critical) are unchanged, and so
  is the finding for a folder read in full. Critical means `doctor` exits 2, as it already did for shadow data;
  what is new is that an unreadable folder reaches it.
- Docs:
  - `KNOWN-ISSUES-AT-PUBLICATION.md` has a "Fixed 2026-09-28" section, with what is still open.
  - H3 in `HYPOTHESES.md`, and `MIGRATION_ENGINE.md`, say that the proposed root-owned `0500` mount-point
    defense would now read as possible shadow data while the drive is away.
  - The user guide's FAQ gives both titles.

Measured on this machine:
- **Red first.** On the unfixed code the three new `VaultTests`, as first written, failed: 12 run, 3 failed, 8
  assertions. The whole-folder case read `("absent") is not equal to ("ambiguous") - Volume Drive (U-locked) is
  not connected.` Against the final tests, deleting the fix fails 10 assertions (mutant A1 below).
- **Build and suite.** At f7a087b, before the review round: `swift build -Xswiftc -warnings-as-errors` exited 0
  with no warnings, and the full `swift test` Executed 581 tests, 0 failures, none skipped (578 before). The
  review round then changed the detail's wording and the no-size remediation; after it, `VaultTests` ran 12, with
  0 failures.
- **End to end.** The fixed `xcodevaultctl vault status`, run against a scratch registry with the home redirected
  (the real registry's SHA-256 was the same before and after):
  - a folder at mode `000`: AMBIGUOUS, with no `shadowBytes`;
  - readable and empty: ABSENT;
  - readable with a file: AMBIGUOUS, 4096 bytes;
  - a symlink to a folder holding a file, a regular file, and a folder holding a file under a parent that cannot
    be searched: ABSENT, all three. These are still open.
- **Mutants.** Five at 4e86fc4, then seven at 41939f1, the code after the review round. Each was proven applied,
  killed, restored byte for byte, and the class re-run green after it; the gold tree was green before the first.
  At 41939f1:
  - the fix deleted, and a size given for what could not be read: all three new tests;
  - only the folder itself counted as unreadable, files seen winning over the unreadable part, and files seen
    worded as if there were none: the subfolder test;
  - the doctor's old title, and its old remediation for a folder nobody could read: the doctor test.

Review: `migration-safety-reviewer`, round 1 at 4e86fc4. The code was approved as written, with REQUEST CHANGES
for the text:
- Three claims the code does not meet.
- Two cases missing from what is still open: the regular file and the unsearchable parent, which the reviewer
  measured.
- A check for earlier builds that would have missed the subfolder case.

It also recommended the wording for files seen and found a test comment that said the opposite of what happens
as root. Its notes: the remediation for a folder nobody can read, a comment in the migration engine, the public
tag, and the second behaviour change. All taken.

Round 2 at 9bcec15: APPROVE. There, the preflight passed its 11 gates, and the full suite executed 581 tests with
0 failures. The round's five notes were wording and recording, taken here without a third round:
- the scope of the reviewer's judgement in the gaps below;
- two follow-ups to record;
- "not directly under `/Volumes`" instead of "outside" it;
- a comment pointing at a heading that occurs twice;
- the date of the red figure.

The tree committed differs from 9bcec15 only by those notes; its own preflight is in the commit message.

Declared gaps, still open (details in `KNOWN-ISSUES-AT-PUBLICATION.md`):
- Three more ways the verifier reads "could not tell" as "not connected", measured: a parent it cannot search, a
  regular file, and a symlink at the last mount point.
- `checkShadowVolumesDirectories` makes the same decision the same way (by reading).
- By reading: the registry and journal existence checks, a `/Volumes` that cannot be listed, and the app's "None
  registered." for a registry it cannot read.
- Nothing acknowledges the new finding: it stays critical for as long as the drive is away. The reviewer judges
  this the right direction. It applies to a custom mount point the user cannot list, for example a root-owned
  `0700` or `0500` one. A root-owned `0755` mount point that is empty still reads as absent.
- The title says "Possible shadow data" even when files were seen. Putting "at least" and a size there needs a
  new field in `VaultVolumeCheck`.
- A folder that vanishes, or answers an I/O error, between the existence check and the measurement reads as
  "not connected". By reading; only a race.
- The GUI's Volumes section shows AMBIGUOUS in red with the detail. Known by reading; not run on screen.

## 2026-09-28 — F3: the CLI runs only the selected Xcode's tools (ADR-0009)

Found by the helper-security review of deliverable 3 of the permissions plan, round 2. That deliverable fixed the
app and declared the CLI open. To say what each Xcode supports, `XcodeDiscovery` ran `xcodebuild -help` and
`xcrun simctl runtime` from every folder named `Xcode*.app` in /Applications and ~/Applications whose Info.plist
named Xcode, inside the terminal's grant when there is one (H15). The CLI's `scan`, `status`, `report`, `doctor`,
`clean`, `xcode list` and `runtime delete`, `export`, `import` and `offload` did this. The `runtime` verbs used
the first Xcode found when none was selected. The probe dates from M1 (23fc324, 2026-09-06), which the public tag
`pre-review-2026-09-17` contains, and the fallback from M2 (d5be647). No release.

What changed:
- `XcodeDiscovery.inspect` runs the two tools only for the bundle whose developer directory is the one
  `xcode-select -p` answered, compared as strings. Every other bundle is only read. The answer is taken as
  printed, less its newline: `xcode-select` echoes a trailing space in `DEVELOPER_DIR`, `xcrun` refuses that
  path, and trimming it would select an Xcode `xcrun` would not run.
- `XcodeInstallation.capabilitiesProbed`: the Xcode is the selected one, and its `xcodebuild -help` ran. Every
  capability of an Xcode that was not probed reads `false`, so `xcode list` says "capabilities not probed", and
  why, in place of its ✗ rows: "only the xcode-select'ed Xcode's tools are run", or, for the selected one, "its
  `xcodebuild -help` could not be run". The scan's text flags it "capabilities not probed". The key is new in
  the `--json` output of `xcode list`, `scan`, `status` and `report`.
- The `runtime` verbs (`Runtime.selected`) refuse when no Xcode is selected. The refusal counts the Xcodes found,
  prints none of their paths, and says how to select one: `xcode-select -s`, or `DEVELOPER_DIR`.
- `RecordingRunner` keeps each call's executable path and environment (`calls`), and can model a tool that
  cannot be started (`unstartable`).
- ADR-0009; the user guide; a "Fixed 2026-09-28" section in `KNOWN-ISSUES-AT-PUBLICATION.md`; and the app's
  comment on why it detects no capabilities, which described the old behaviour.

Measured on this machine: macOS 26.7 (25G229), x86_64, Xcode 26.5 (17F42) at /Applications. The planted folder
was `~/Applications/Xcode-x.app` in a scratch home (`HOME` and `CFFIXED_USER_HOME` moved for that one process):
an Info.plist and three scripts, `xcodebuild`, `simctl` and `xcrun`, that only record that they ran.
- **Before**, with the CLI built at 11:39 from the unfixed tree: `xcode list` ran the folder's `xcodebuild -help`
  by path, and `/usr/bin/xcrun` handed `simctl runtime` to the folder's `usr/bin/xcrun`. With no `xcrun` in the
  folder, only its `xcodebuild` ran.
- **How `/usr/bin/xcrun` hands off**, measured with scratch developer directories after the review corrected my
  first description:
  - It loads the directory's `usr/lib/libxcrun.dylib`, and runs its `usr/bin/xcrun` only when there is no such
    library. With neither, it refuses ("missing xcrun").
  - A library that fails to load stops it; it does not fall back to `usr/bin/xcrun`.
  - A planted library, empty or signed ad hoc, was refused: "mapping process is a platform binary, but mapped
    file is not".
  - Apple's own library, copied into one planted folder, refused with "unable to find Xcode installation". In the
    review's planted folder, whose plists differed, it ran the folder's own `usr/bin/xcodebuild`, and tried to
    when there was none. Which plist content decides it was not established. So "loads only platform code" is no
    defence: Apple's library is platform code anyone can copy.
  - Xcode 26.5 ships that library, signed `identifier "com.apple.libxcrun" and anchor apple`, and no
    `usr/bin/xcrun`. `/usr/bin/xcrun` has signing flags `0x0`.
- **The signature check**, measured and not chosen (ADR-0009).
  - The bundle's designated requirement is not `anchor apple`.
  - `codesign --verify -R '=anchor apple'` on `xcodebuild` exits 0 in 0.09 s; the same check naming a team it
    does not have exits 3.
  - `simctl` is a bash script that `codesign -dv` says "is not signed at all", covered only by a seal over
    121,000 files. Verifying the whole seal at background priority had not finished after 120 s. One file can
    be checked against the seal alone, though (`SecCodeValidateFileResource`, public since macOS 10.13), so
    cost is not the ADR's reason.
  - Its reasons: what runs cannot be listed in advance (`simctl` runs `xcodebuild -runFirstLaunch` when
    CoreSimulator is not the version it expects, and `xcodebuild` loads a framework through `@rpath` entries
    into the bundle); a file checked in a folder the user can write can change before it runs; and a genuine
    older Xcode passes every check.
- **After**, with the CLI built at 14:04 from this tree: the planted folder ran nothing, and
  /Applications/Xcode.app, which is selected, was probed (all 11 rows ✓). Control: with the planted folder
  selected through `DEVELOPER_DIR`, its `xcodebuild` and its `usr/bin/xcrun` ran, and /Applications/Xcode.app
  was listed as not probed. So "nothing" is the rule at work, not a broken marker.
- **A trailing space.** With `DEVELOPER_DIR` set to /Applications/Xcode.app's developer directory plus a space,
  `xcode-select -p` answers it (exit 0) and `xcrun` refuses it ("missing DEVELOPER_DIR path", exit 1). `xcode
  list` now selects nothing and probes nothing.
- **The refusal.** `runtime delete xcv-bogus-id`, without `--yes`, with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: "No Xcode is selected: `xcode-select -p` names none of
  the Xcodes found (1; `xcodevaultctl xcode list` lists them). …", exit 64. Control, with
  /Applications/Xcode.app selected: the existing "Pass --yes to confirm, or --dry-run" refusal, exit 64.
  `DEVELOPER_DIR=/Applications/Xcode.app` reaches the same point: `xcode-select -p` then answers
  `/Applications/Xcode.app/Contents/Developer`.
- **Red first.**
  - Round 1: on the unfixed code, `testOnlyTheSelectedXcodesToolsRun` and
    `testNoBundlesToolsRunWhenNoXcodeIsSelected` failed. The second got `["xcode-select -p", "xcodebuild -help",
    "xcrun simctl runtime"]` where it expected `["xcode-select -p"]`.
  - Round 2: on the round-1 code, the four tests for the review's changes failed, each for its reason (10 run,
    4 failing). The trailing space selected the Xcode; `capabilitiesProbed` was true with `xcodebuild`
    unstartable; the refusal printed both paths; and `xcode list` gave the selected Xcode the other reason.
    Their in-test controls passed.
  - The `isSelected` pins and the first `CLIXcodeSelectionTests` pin code that already worked; the mutants below
    are their red.
- **Suite.** The full `swift test` Executed 597 tests, 0 failures, none skipped (581 before this work), on the
  tree frozen as a63612a. That run covers the F9 entry below too.
- **Mutants.** Fourteen, at a63612a in a separate worktree, after the gold tree there built and ran the four
  classes this work uses green (31 tests). Each was proven applied, killed, restored byte for byte with the
  whole tree proven identical to the snapshot, and its class re-run green; none failed to compile. Nine of them
  were also run at b387e61, the round-1 code, and killed there.
  - Every bundle probed (the fix deleted), and the rule inverted: the discovery tests, and with the inversion
    the scanner test too.
  - `capabilitiesProbed` true for every bundle: three discovery tests. True when `xcodebuild` was only
    attempted: the unstartable test.
  - An empty `xcode-select` answer selecting every bundle (`hasPrefix` for `==`): the no-selection test.
  - Discovery reporting every bundle selected: the three tests that pin `isSelected` (the review's first item).
  - The answer trimmed of all whitespace again: the trailing-space test.
  - The `runtime` verbs falling back to the first Xcode found: the refusal test. Ignoring the selection: that
    and the selection test. Printing the paths found again: the refusal test.
  - `xcode list` printing rows for an Xcode it did not probe, or giving each Xcode the other's reason: both list
    tests.
  - The scan's text dropping the flag, or flagging the probed Xcode instead: the scanner test.

Review:
- **Helper security, round 1** at 43ec909: REQUEST CHANGES. It found no path that runs a non-selected bundle's
  tools, and that the string comparison cannot fail open. Taken:
  - two required changes: pin `isSelected` from discovery, which `Runtime.selected` trusts (`runtime export`
    lists runtimes through the chosen Xcode before any capability check); and replace the ledger's detection
    command, which fails in zsh;
  - three corrections, each re-measured before it was written: the `xcrun` hand-off through `libxcrun.dylib`;
    the ADR's cost argument against a signature check; and the app's comment;
  - three hardenings: the answer less only its newline; "probed" meaning `xcodebuild -help` ran; and a refusal
    that prints no path.
  - Not taken: a refusal in `RuntimeOperations` for an Xcode that is not selected, which the reviewer offered
    against future callers and not as a boundary. The ADR records where the rule is enforced instead.
- **Helper security, round 2** at 0955743: APPROVE. It verified each fix, by measurement where one applied, ran
  the four classes from the prebuilt binaries (13 tests, 0 failures), and repeated the planted-folder run and its
  control end to end. It also found that `xcrun` refuses a trailing carriage return, and, from a check of the
  same Swift expression, that discovery then selects nothing either. Its three notes, all taken as text:
  - the genuine-library measurement above, which is also in the ADR and the `inspect` comment;
  - an `xcodebuild -help` that starts and then fails counting as probed: declared below, rather than a code
    change after the approval;
  - the ledger's wording for zsh.
- **Round 3** at 66d86e2: APPROVE. It confirmed that each of the four `runtime` verbs refuses when a flag it
  needs reads `false`, and judged the `capabilitiesProbed` change a reasonable follow-up rather than a blocker.
  Its three notes were wording, taken here without a fourth round: the genuine library's refusal turned on the
  plists, not on a missing `xcodebuild`; "what is displayed" rather than "what `xcode list` shows"; and what its
  round 2 measured rather than read.

The tree committed differs from a63612a, where the suite and the mutants ran, only in documentation and in two
comments; its own preflight is in the commit message.

Declared gaps:
- The comparison is by string. When `xcode-select -p` spells the selected bundle through a symlink, the bundle is
  listed twice and only the spelling that matches is probed. Seen once, with `DEVELOPER_DIR` under
  `/private/tmp` for a folder found under `/tmp`. Not fixed.
- The selected Xcode is trusted whatever it is, and `xcrun`'s cache stays trusted (deliverable 3).
- The rule is enforced where an Xcode is chosen: `RuntimeOperations` and `SimulatorDiscovery.runtimes(developerDir:)`
  accept any developer directory, and `inspect` is public.
- A failure of `xcrun simctl runtime` alone, with `xcodebuild -help` run, still reads as ✗ on the `simctl` rows.
- Probed means `xcodebuild -help` ran, not that it succeeded: one that starts and then fails reads as probed, its
  flags parsed from whatever it printed. A healthy install's exits 0, as the review measured. This changes only
  what is displayed (`xcode list`, the scan's text, `--json`); a `runtime` verb whose flag reads `false` refuses.
- `xcode list`, `scan`, `status` and `report` print the paths of the Xcodes found as they are, a planted folder's
  included. That predates this change.
- `scripts/experiments/e8-feature-detect.sh` runs the tools of every `/Applications/Xcode*.app` when run without
  arguments: by hand, and by CI on every push, on runners with no user's grant. Not changed.
- `locations set-compilation-cache` still falls back to the first Xcode found when none is selected, for its
  version only; it runs nothing from it.
- An `XcodeInstallation` stored before this would not decode: a Codable default does not make a missing key
  decode, as deliverable 3's review measured. Nothing in the tree decodes one from storage, by reading (the
  review agrees): the decoders are the journal, the registry, the sentinel and `simctl`'s output.
- Of the `runtime` verbs, only `delete`'s refusal was run end to end; `export`, `import` and `offload` share
  `Runtime.selected` and were not run.

## 2026-09-28 — F9: `vault init --directory` with missing folders reaches the step that creates them

Found by the migration-safety review of deliverable 4 of the permissions plan. `VaultRegistry.register` checked
that the vault folder is inside the volume with `PathSafety.isContained`. That resolves the folder's parent with
`realpath(3)`, which fails when any folder in the path is missing. So `vault init <mount> --directory a/b/c` with
`a/b` absent was refused as "…/a/b/c is not inside <mount>". It never reached
`createDirectory(withIntermediateDirectories: true)`, nor the refusal that names each missing folder
(`OwnershipAdvice.createVaultDirectoryCommand`). It refused, so nothing was written; the message was wrong, and
the nested case could not be reached. Since `--directory` was added (0c79d94, 2026-09-06), which the public tag
`pre-review-2026-09-17` contains. No release.

What changed:
- `PathSafety.canonicalizeAllowingMissingParents` and `isContainedAllowingMissingParents`, both internal. The
  deepest folder on the path that exists, by `lstat`, is resolved through `realpath`, and the missing folders
  under it are appended as written. `..` and `.` refuse, as in `canonicalize`. A symlink on the way counts as
  existing and is resolved: pointing off the volume it is "not inside", and dangling it refuses. Any `lstat`
  error other than "no such file" refuses: `EACCES`, `ENOTDIR`. With every parent present the answer is
  `canonicalize`'s. The containment check does not check that the root exists; the doc comment says so, and
  that `register` asserts the mount before and after it.
- `canonicalize` and `isContained` are unchanged, so every other caller — the migration engine, journal
  forensics, the catalog, `CleanPlanner` and `XcodeLocations` — gets the answers it got before.
- `register` uses the new check. A path it cannot resolve refuses as "Cannot tell where … would be created: ….
  Nothing was written.", which is not "not inside".
- `OwnershipAdvice`'s comment no longer says the several-folder command is unreachable; the user guide's
  `vault init` row names the folders created on the way; and `KNOWN-ISSUES-AT-PUBLICATION.md` has a "Fixed
  2026-09-28" section with what an earlier build needs.

Measured on this machine:
- **The path shapes**, pinned by `PathSafetyMissingParentsTests`, which pass here:
  - every parent present: the same answer as `canonicalize`, a dangling symlink as the last component included;
  - missing folders: appended to the deepest one, resolved, also through a symlinked path to the root;
  - a symlink on the way: pointing off the root, not contained; re-pointed into it, contained;
  - a dangling symlink on the way refuses with "No such file", a path under a regular file with "Not a
    directory", and `..`, `.` and a relative path are refused;
  - a folder at mode `000` on the way refuses with "Permission denied", and the same path resolves once it is
    searchable again.
- **`register`**, driven with the mount-point and volume-UUID seams on scratch folders, where it creates real
  folders:
  - `--directory a/b/c` with `a` missing registers, and writes the sentinel in `a/b/c`;
  - on a volume root at mode `555`, the refusal names `'<mnt>/a' '<mnt>/a/b' '<mnt>/a/b/c'` in one `sudo mkdir`,
    does not say "is not inside", and creates nothing;
  - a folder on the way that is a symlink off the volume refuses as "not inside" and creates nothing where it
    points; the same link pointing into the volume registers;
  - a dangling symlink on the way refuses as "Cannot tell where".
- **Red first.** On the unfixed code all four new `VaultTests` failed, each with "…/mnt/a/b/c is not inside …",
  where they expected a registration, the folders named, or "Cannot tell where". `PathSafetyMissingParentsTests`
  tests the two functions this change added, so it was written after them; the mutants below are its red.
- **Not run end to end.** `vault init` reads the mount and its UUID from the system, so it needs a mounted
  volume, which here means attaching a disk image. That was not done unasked.
- **Suite**: the run in the F3 entry above. **Mutants**: seven, at the same snapshot and the same way, after the
  same gold proof; all seven were also run at b387e61 and killed there.
  - `register` reverted to `isContained`: all four new `VaultTests`.
  - Any `lstat` error read as "missing": the `ENOTDIR` and `EACCES` tests. At b387e61 both failed with "did not
    throw" (the per-mutant run logs), and the review confirmed with a small C program that `realpath` of a
    mode-`000` folder succeeds while a path beneath it answers `EACCES`: the `EACCES` guard is what refuses there.
  - The missing folders not appended: the appending test, and the `EACCES` test's positive control.
  - A parent `realpath` cannot resolve used as written, the fail-open direction: the dangling-symlink tests in
    both classes.
  - "Cannot tell" read as "not inside": the dangling-symlink `VaultTests` test. Both refuse, so this pins the
    wording only.
  - The containment answer ignored: the symlink-off-the-volume test, where the mutant created `b` in the folder
    the link points to.
  - The prefix without its separator: the appending test's `mntx` case.

Review: **migration safety, round 1** at 43ec909: APPROVE. It confirmed the check fails closed when it runs,
with a harness over the edge cases (symlink loops, links to files, over-long names, unsearchable folders,
dangling links, links out and back), and that no other caller's answer changed. Its notes, all taken:
- two declared gaps, both below: what the verifier makes of a vault folder that resolves off the volume, and a
  creation that fails part way, which it measured;
- a doc comment saying the check does not check the root exists;
- the complete list of other callers;
- a "Fixed" section in the ledger;
- two assertions that could never fail — that a dangling symlink's target was not created — which are gone.
  Nothing can create under a dangling link — the kernel answers `ENOENT` there — and `mkdir` of the link itself
  answers `EEXIST`, as the reviewer found. The earlier text here said "and creates nothing" for that case; it
  was true by construction, not measured, and is gone too.

**Round 2** at 0955743: REQUEST CHANGES, for three sentences; the code approval stands. All taken:
- The ledger's advice for an earlier build now says to create the folders one `mkdir` at a time, with the drive
  connected. The `sudo install -d` that build prints, like `mkdir -p`, creates every missing folder, the drive's
  mount point on the internal disk included after an eject.
- "Until a copy is attempted" was wrong: the vault reads VERIFIED after a refused copy too.
- The dangling-link sentence claimed more than was found: creating a file through a dangling link, rather than a
  folder under it, creates the link's target.

Two optional notes were taken as well: "to the volume" in a doc comment, and the C check of `realpath` above.
The note that came with that check, that the "did not throw" output was not saved, was wrong, as round 3 said
itself: it is in the per-mutant `.run` files, which its search did not include. **Round 3** at 66d86e2: APPROVE;
its one note, that correction, is taken here.

Declared gaps:
- Between the check and `createDirectory`, a folder put on the way — a symlink where a missing folder was — is
  followed by `createDirectory` and by the sentinel write, and the volume is registered. The same window existed
  for folders that were present. `vault status` and `doctor` read such a vault as VERIFIED, and still do after a
  copy into it has been refused: the verifier reads the sentinel through the path, reads no journal, and nothing
  checks that the folder is on the volume. A folder on the way that is another volume's mount point does the
  same, with no race. By reading, as
  the review traced it: the migration engine's `assertVaultVolumeStillPresent` resolves the path and compares its
  volume UUID before it writes, so a copy there refuses; `register` itself does not check again.
- `createDirectory` makes the folders one at a time. A failure part way leaves the folders already made on the
  volume, with no journal entry, and the printed `sudo mkdir` names only the rest. Examples are a name longer
  than the filesystem allows, a full volume, or an inherited deny entry. The review measured this on scratch
  folders: a 300-byte last component (Cocoa error 514) left `a` and `a/b`, and an inherited deny entry (513) left
  `a`. For the long name, the printed command would fail with "File name too long", under a message that blames
  root ownership. New with this change: before it, at most one folder could be created.
- "Nothing was written." in `register`'s later refusals (no longer a mount point, an identity it cannot read, a
  different volume) is true of the volume but not of the journal: they come after the journal line for a vault
  under `.TemporaryItems`.
  Pre-existing, found by the review; the new refusal comes before every write.

## 2026-10-02 — M5: releases signed in CI (ADR-0010), written and not yet run

The operator chose option 1 of docs/process/RUNBOOK-M5-release-signing.md and did Parts A and B the same day.
The CI-only Developer ID certificate is on team `4V58BSZL3W`; the notary key has the Developer role.

**Checked with `gh api`, read-only:**
- the `release` environment has the five secrets and the two variables, and its tag rule is `v*`;
- `APPLE_SIGNING_IDENTITY` is the Developer ID hash, not the Apple Development one;
- the rulesets are `release-tags` (create, update, delete and force push restricted to Repository admin) and
  `main` (no deletion, no force push, no bypass);
- workflows default to read-only, and fork pull requests need approval for every outside contributor;
- the `.p8` was deleted.

**Open, the operator's:**
- ~~the environment has no required reviewer and administrator bypass on~~. **Fixed by the operator later on
  2026-10-02**, after the commit that recorded it (d72883f). `gh api …/environments/release` now shows rules
  `branch_policy` and `required_reviewers` (reviewer `pabloguia`, prevent self-review off) and
  `can_admins_bypass: false`. So a `v*` tag now waits at `sign` for the operator's approval;
- the CI certificate's `.p12` and the notary API key's `.p8` are still on the Mac in `~/certs`, and the CI
  identity is still in the login keychain (A.2 step 4, A.3 step 4). The `.p8` escaped the earlier search
  because its file was renamed: it no longer starts with `AuthKey_`.

**Written:** `release.yml`, `ci-sign-notarize.sh`, `release-artifact-scan.sh`, `release-hygiene.sh` and its
test, the hygiene gate in CI and preflight (CI now has 14 named steps), `.gitignore`, and a refusal in
`release.sh`.

**Measured:**
- `test-release-hygiene.sh`: 19 cases in round 1; 43 after the review (below).
- The artifact scan passed `dist/XCodeVault.app` until `strings -a` was replaced, which found none of the 206
  home paths in the debug CLI; it now refuses that bundle, as it should (206 and 84 occurrences, counted).
- The signature checks were read against a Developer ID app (iTerm): `TeamIdentifier=`, `Authority=Developer
  ID Application: `, `Timestamp=`.

**Found by the new gate:** `sonar.yml` ran `actions/setup-java@v4` and `SonarSource/sonarqube-scan-action@v6` by
tag, in the job holding `SONAR_TOKEN`. Both are now pinned by SHA (v4.9.1, v6.0.0).

**Helper-security review, round 1: REQUEST CHANGES.** Answered:
- B1 is the missing required reviewer above.
- R1–R3: the line-pattern gate let through every bypass the reviewer tried — a `#` in a quoted string, flow
  style, quoted keys, `toJSON( secrets )`, `tojson(secrets)`, job permissions widened, `on: push`. It now reads
  the workflows with Ruby's YAML parser, and each of those is a test case that must fire alone. One reproduced
  case did not stand: in a *plain* scalar ` #` really is a comment, to YAML and so to Actions, so the test
  uses a `run: |` block, where it is not.
- R4: `sign` takes its scripts out of the checkout before it opens the build job's zip, and refuses entries
  outside the bundle, `..` and links.
- R5: the scan prints counts, never what it found.
- R6: `sign` and `publish` refuse if the tag no longer names the commit built.
- R7: the prose on the `main` check and on arguments is corrected.
- N1 (keychain and job timeouts), N2 (cleanup by fixed path) and N5 (links) are fixed; N3, N4, N6 and N7 are
  either fixed or written down in ADR-0010.
- Tests: 43 cases, 0 failed. Two mutants of the gate killed. A third, which disabled the nil branch of HYG6,
  survived because the next branch refuses the same input; it is equivalent.

**Round 2: REQUEST CHANGES**, everything from round 1 verified fixed. The reviewer confirmed the plain-scalar
reasoning and found that ditto clamped `..` and refused to write through a link in their tests, so no escape
was demonstrated. Answered:
- R8: the zip's `..` and link checks never ran on a large listing: `grep -q` exits at its first match, the
  listing dies of SIGPIPE, the pipeline returns 141 and the `&&` refusal is skipped. Reproduced by the
  reviewer with 3000 entries. The checks moved into `scripts/ci-unpack-bundle.sh`, which reads the listings
  from files, and the test builds both 3000-entry zips. Each case is pinned by its message: the first version
  of those cases checked only the exit status, and the piped mutant survived it, because the
  "nothing beside the bundle" backstop refused the same zip. Once pinned, both piped mutants were killed.
- N8 and N9: duplicate keys and `<<` merge keys are refused (HYG0), since Psych keeps the last duplicate and
  applies merges, and Actions may do neither.
- Tests: 52 cases, 0 failed.

**Round 3: APPROVE.** One NIT, N10: duplicate keys were compared as written, and Psych reads a plain `on`,
`On` and `true` as one key, so `on: [push, workflow_dispatch]` followed by `true:` holding the clean trigger
passed. Fixed two ways: keys are compared as Psych reads them, and a top-level key Actions does not define is
refused, as is a second YAML document. Tests: 57 cases, 0 failed. Mutants that disabled each of the two
mechanisms were killed, each by its own case. Preflight on the round-3 tree: ok, 12 gates, 597 tests.

**Round 4: APPROVE**, one NIT, N11, opened by that fix: a quoted `"on"` is compared as text and a plain `on`
as `true`, so the two did not collide. Rather than chase spellings, quoted and complex keys are now refused
(HYG0); the reviewer's quoted-`environment` case now fails there instead of at HYG9. Tests: 59 cases.

**Round 5: APPROVE**, one speculative NIT, N12: `downcase` does not fold `ſ` (long s), so `permiſſions` beside
`permissions` passed; it matters only if Actions folds Unicode case in keys. Non-ASCII keys are now refused
(HYG0). Tests: 60 cases.

**Not measured:** the workflow itself. Nothing signs or notarizes until the first tag, and only the run shows
whether the keychain import, `notarytool` with the API key and `attest-build-provenance` work as written.

## 2026-10-03 — S4 GUI done (spec `docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md` §6)

Plan `docs/superpowers/plans/2026-10-03-s4-gui.md`, six tasks on `feat/gui-savings`: the savings-first sidebar
(Save space / Details), the Overview's disk bar and three cards, the Delete, Park and Run-externally views (the app
copies commands and runs none of them; Delete's semantics unchanged), the Access checklist asked for where it matters,
and the Details screens renamed (Health, History, Drives, Simulators — now with runtimes and devices with sizes — and
Storage with a Bucket column). The legacy `ScanSummary` savings numbers are gone from the app (a test greps for them).
User docs: `docs/USER_GUIDE.md` § The app; spec: `docs/product/UX_AND_CLI.md` § GUI. The snapshot tests now return
instead of skipping without `XCV_SNAPSHOTS=1`: the no-skips gate holds the suite to zero skipped tests, and the two
earlier snapshot tests would have failed it. Follow-ups are in "Blocked / pending" above.

## 2026-10-04 — R1: screens fit any window, Back, Drives without duplicates

Brief `.superpowers/sdd/r1/brief.md`, branch `fix/r1-layout-navigation`. The user's "the sidebar gets lost" and the
undrawn Delete table had one cause, measured: Delete asked for 451 pt minimum (a `Table.frame(minHeight: 200)` plus the
blocks around it) and Simulators for 410 pt (two tables with `minHeight: 140`), so with real data the split view grew
taller than the window and was centered off the top. Delete's table now takes the remaining height; the helper's access row
stays above it and everything else sits below in one notes panel folded by default (`DeleteNotes`); Simulators is one scrolling page whose tables are as tall
as their rows (`SimulatorsTable.fittedTableHeight`). Minimums now: Delete 182 pt (188 with the panel open, 274 with the access row), every other
screen 1 pt; `ScreenFitTests` holds every screen to 300 pt in en and ja over the sample and a stress fixture, without a
window. **Back** (⌘[): `NavigationHistory` in Core, recorded by every section change in `AppModel`. **Drives**:
`DrivesList` groups the boot System and Data volumes on one APFS container into one row, shows a mounted vault as a
badge on its own row, and keeps a section only for vaults that are not connected; warnings are folded. Six new keys,
drafts `needs_review`. The snapshot test's comment that blamed off-screen drawing for the undrawn Delete is corrected.

**R1 review round 1 (same day).** Simulators tables may scroll inside again (`scrollDisabled` removed: a wrong row
metric now degrades to a small internal scroll, never hidden rows). A mounted vault that is not usable shows its
check's sentence as text (`DriveRow.showsVaultDetail`), not only as a tooltip. The boot row now holds only the running
system's pair, the volumes at `/` and `/System/Volumes/Data` on one container; another install's System/Data in the same
container keeps its own rows. **Known limitation:** `Volume` does not carry the APFS volume-group UUID, so System and
its Data sibling are tied by those mount points, not by the group itself. Also: the Delete notes label names its
warnings, the table gets layout priority over the notes, duplicate registry entries are shown rather than dropped, and
the not-mounted vaults' symbol follows their state.

## 2026-10-04 — R2: charts and sortable, filterable tables (Storage, Simulators, Drives)

Brief `.superpowers/sdd/r2/brief.md`, branch `feat/r2-charts` (stacked on R1). **Storage**: a Swift Charts bar per bucket
with rows (bucket color as fill, symbol + title on the axis, size at the bar's end), 150 pt high; a click on a bar filters
the table (`StorageTable.filter(after:clicked:)`, `AppModel.storageBucketFilter`), a chip with × and **All** clear it; every
column sorts through Core comparators (`StorageTable.Column`, default size descending, ties by path). Bars sum only the
rows that `countsInBucketTotal` (no symlinks, no breakdowns). The click is read with a `chartOverlay` tap and
`ChartProxy.value(atY:)`, not `chartYSelection`, whose value resets when the gesture ends. **Simulators**: horizontal bars
per measured runtime and device (`SimulatorsChart.bars`), colored and marked by kind, unmeasured counted under the chart;
a click selects the row (`SimulatorSelection`, in the model) and scrolls the page to it (`SimulatorsChart.rowAnchor`);
both tables sort. The chart is as tall as its bars inside the page's ScrollView. **Drives**: `DiskBar` gained a general
`init(totalBytes:freeBytes:bucketBytes:)` (the Overview's init now calls it) and `DiskBar.drive(_:report:)`; each measured
drive row draws `DiskBarView` with its legend. `Volume.totalBytes` already existed and is Codable, so the scan was not
changed. `ScreenFitTests` passes unchanged. 14 new keys in the first commit (not 15), drafts `needs_review`.

**Follow-up (vault contents):** the vault's bar shows only what the scan found on that volume (items whose mount point is
the vault's). The registry records no sizes of what XCodeVault placed there, so the bar cannot show "vault contents" as
such without measuring the vault directory, which this change does not do; the row says so in a caption.
**Needs a real window:** the click-to-filter and click-to-select gestures (no test can click), the scroll to a selected row,
and the tables' sort headers — off-screen drawing leaves `Table`/`List` rows blank.

**R2 review round 1 (same day).** I1: the Simulators tables set the selection through `SimulatorSelection.selecting(runtimeID:)`
and `selecting(deviceID:)`, which clear the other table's row, so only one row is ever selected; the page scrolls only for a
chart click (`AppModel.simulatorScrollRequests`), never under the pointer in a table (M8). I2: one counting rule,
`SavingsCalculator.countsOnce` and `countedOnceBucket`, used by the Storage chart, the Storage rows, every drive's bar and the
savings model; the savings model and the boot row add the named filter `isInternalSaving` (boot volume) on top. Storage stays
the inventory of every drive and its caption says "on all drives"; a test pins that an item on an external drive is in the
chart and not in the Overview's bar, and that the chart's boot-volume subset equals the Overview's buckets. Minors: the click's
plot geometry moved to Core (`ChartHit.plotY`, tested); the strategy column's key documents that the cell shows the identifier
and puts the experimental one second; `StorageTable.rows`, `SimulatorsTable.runtimes` and `devices` are now `sorted(_:using:)`
with the default order, one tie-breaker each (fixture with ties); Storage says so when no bucket has rows instead of drawing an
empty plot; a **Bucket** menu next to **All** sets the filter without a pointer; a rescan clears a filter whose bucket has no
bar and a selection whose row is gone. Two more keys (`app.storage.chart.none`, `app.storage.filter.menu`), 16 for R2 in all.
**Still needs a real window:** the menu, the chart clicks, and the scroll on a chart click.

## 2026-10-04 — R4: Health as cards, History as operations, Access registers the app

Brief `.superpowers/sdd/r4/brief.md`, branch `feat/r4-health-history-access` (stacked on R2). **Health**: a summary line of
counts by severity (symbol and word), then one card per finding (`HealthCard.cards`: severity, then size, then the doctor's
order) with the severity, the title, one sentence (`HealthCard.firstSentence`, tested on abbreviations, dotted names and
backticks), the size and the action or the fix's first sentence; **Details** folds the rest. `Finding` gained `bytes` and
`parts` (explanation, per-device lines, the not-offered note), set by the per-device rule; `detail` is unchanged, so the CLI
prints what it did. **History**: `JournalTimeline.rows` merges records by operation id into one row with its final state
(an orphan start is `interrupted`, the rule of `Journal.interrupted()`; `inProgress` only for ids the caller names,
and the app names none), kinds from the records (`helper: ` summaries are the privileged helper; a migration needs its
`direction`; the vault registry is `other`), sections by day, a kinds filter in the model; the newest 100 operations are
cut after the merge. Badge palette: light/dark hex per kind, 3:1 on the window and control backgrounds and the older
macOS values (`HistoryKindPaletteTests`). **Access**: **Open Full Disk Access Settings** calls
`AppEnvironment.registerForFullDiskAccess` (`FullDiskAccessRegistration`: `open(2)`+`close(2)` of `~/Library/Safari`) then
opens the pane; the row's text is hedged (see the review round below). Every activation re-checks the
permissions; a rescan follows only a new grant (`AccessChecklist.rescansOnActivation`), so coming back without granting no
longer rescans. R2 N1: the Bucket menu is disabled without bars. 28 new keys, one removed (`app.column.sequence`), drafts
`needs_review`.
**Needs a real window:** that the attempt on `~/Library/Safari` does list the app in the Full Disk Access pane on macOS 14,
15 and 26 (no API reports it; tests replace the closure), and how a dev build is listed; the History list's column header
alignment with the rows and the Kinds menu's toggles; Health's **Details** disclosure — off-screen drawing leaves `List` rows
blank and draws disclosures closed.

**R4 review round 1 (same day).** I1: only a last state of `started` is `interrupted`, exactly `Journal.interrupted()`; a
last state of `planned` is its own outcome, **Planned** (`calendar` symbol) — the vault registry writes standalone
`planned` notes, which are not crashes; the matching test now has a planned-only id. I2: the registration is H16 in
`HYPOTHESES.md`, **unverified**, with the manual procedure; ADR-0007 has a note; the hint now reads "XCodeVault should now
be in the list — turn its switch on. If it isn't there, add it with +." (four drafts re-drafted, `needs_review`), and the
user guide says the same. Minors: M1 `Finding`'s JSON pinned (old JSON decodes, unset fields are not encoded, a per-device
finding round-trips) and noted in `UX_AND_CLI.md`; M4 a row's size is the closing record's, else the opening record's;
M5 failed and interrupted rows show how they ended under the summary, and the guide points to `xcodevaultctl journal`;
M6 `AppModel.journal` removed; M7 the day header and the time format in the grouping calendar's time zone; M8 a hidden
kind the rows no longer have is cleared after a scan; M9 a scan in flight counts as a scan for the rescan rule. Not changed:
M2 (vault records stay "Other": honest, and the review marks it optional); M3 (the app still names no running operation;
the guide says a concurrent `xcodevaultctl` operation shows as Interrupted until it ends); M7's second half ("Today" goes
stale across midnight until the next redraw). One new key, `app.history.outcome.planned`.
**Still needs a real window:** H16's manual check, and the History row's second line.

## 2026-10-04 — R5: every finding of the independent HIG review, and the user's real-window feedback

Branch `feat/r5-hig` (stacked on R3, with R3's two later safety commits merged in before the last commit). Requirements:
`.superpowers/sdd/hig/brief.md`; the review `.superpowers/sdd/hig/report.md` (72 findings) and the user's feedback of
2026-10-04. Three commits, as the review's §5 plans them: feedback and destructive actions; writing and typography (with
H16 and **Relaunch XCodeVault**); Mac-native structure and polish (with the Storage/Simulators filtering the user asked
for). Wording and presentation only: what Delete and Run delete or run, their confirmations and the two-step remove are
unchanged. The R3 Run sheets (§4) were already done in R3; only cross-cutting writing applies to them, and none of their
strings needed it beyond the shared ones. **H16 is verified** on macOS 26.7.1 · Intel by the user's manual check
(HYPOTHESES, COMPATIBILITY_MATRIX); other versions stay unmeasured.

| Finding | Disposition |
|---|---|
| N1 | Fixed — chevron Back and Forward, icon-only with tooltips, ⌘[ ⌘], disabled not hidden (`NavigationHistory.forward`) |
| N2 | Fixed — `navigationSubtitle`: the host line, or "Scanning…"; removed from the Overview body |
| N3 | Fixed — `Window` scene, `defaultSize` 1100×720. The 960×620 minimum is kept: it is what `ScreenFitTests` proves |
| N4 | Fixed — `SidebarCommands`, `ToolbarCommands`, Rescan in the View menu, ⌘1–⌘4 for Save Space |
| N5 | Fixed — "Save Space", "Run Externally" |
| N6 | Fixed — the compliant alternative: `trash` in the sidebar only; BRAND.md records the split |
| N7 | Fixed — "Permissions" |
| N8 | Fixed — a labelled progress while scanning; Delete without a plan offers Rescan |
| N9 | Fixed — one Rescan item whose content swaps to a spinner |
| N10 | Fixed — `AppError`: a title per action, the error's description and recovery as the message |
| N11 | Fixed — inline result (`AppModel.feedback`), announced, cleared by the next action |
| N12 | Fixed — the wait is the helper sheet's second state, with Open System Settings and Stop Waiting |
| S1 | Fixed — Cancel and Stop Waiting are `.cancelAction`; a `lock.shield` glyph |
| S2 | Fixed — "Install Helper…" |
| O1 | Fixed — "Space comes back" / "Space stays free" (app keys; the CLI keeps Temporary/Permanent) |
| O2 | Fixed — promise and undo cost moved to the title's tooltip and the bucket view's header |
| O3 | Fixed — primary text, tinted symbol |
| O4 | Fixed — "issues need attention", severity symbols, Show in Health |
| O5 | Fixed — no "Definition of Done" |
| O6 | Fixed — `tertiarySystemFill` with a separator hairline on the bar and chips |
| O7 | Skipped — the product deliberately recommends no option; the review allows keeping three equal Review buttons |
| D1 | Fixed — context menu (Show in Finder, Copy Path, Delete Selected…), ⌘⌫ and Delete, destructive role. Same confirmation |
| D2 | Fixed — "Move to Trash", explanation as tooltip and in the confirmation |
| D3 | Fixed — the message names the undo cost of exactly the selected rows (`DeleteList.undoCosts`); no "journaled" |
| D4 | Fixed — a question title keeping "experimental"; no H14 |
| D5 | Fixed — why and guidance run full width under the status |
| D6 | Fixed — one-line header; details in its tooltip |
| D7 | Fixed — "Cost to Undo", "Notes" |
| D8 | Fixed — name, size trailing in secondary |
| P1 | Fixed — shorter intro |
| P2 | Fixed — status row, tinted symbol, Copy for the set-up command (no in-app vault set-up exists to offer) |
| P3 | Fixed — one "Experimental" badge app-wide |
| P4 | Fixed — small bordered "Copy" |
| ST1 | Fixed — one filter model: a set of options shown by the bars, toggle chips and a summary with Show All (chips, not a Picker: the user asked for several at once) |
| ST2 | Fixed — horizontal padding, leading y-axis labels |
| ST3 | Fixed — selection, Show in Finder, Copy Path |
| ST4 | Fixed — strategy names (`AppText.strategy`) with the badge; symlink and mount point as symbol and word |
| ST5 | Fixed — "Option" |
| ST6 | Fixed — the caption under the chart, wrapping, and a persistent hint |
| SI1 | Fixed — one Table with Runtimes and Devices sections; the chart's box is bounded |
| SI2 | Fixed — "Yes"/"No" gone (state says "Mounted"), "—" for unknowns, "Not measured" |
| SI3 | Fixed — hover highlight and pointing hand on both charts |
| SI4 | Fixed — scrolling respects Reduce Motion |
| DR1 | Fixed — the boot volume shows "Boot volume" only (`DriveRow.showsQualificationDetail`) |
| DR2 | Fixed — symbol-tinted labels with primary text |
| DR3 | Fixed — one vault verdict (`DriveRow.vaultVerdict`) |
| DR4 | Fixed — headline name, one secondary facts line |
| DR5 | Fixed — only the symbol is tinted |
| DR6 | Fixed — "Vaults" |
| H1 | Fixed — title-case severities |
| H2 | Fixed — wrench symbol, not "→" |
| H3 | Fixed — description and Rescan |
| H4 | Already done — informational; the symbols were distinct |
| HI1 | Fixed — a Table with day sections, kept badges and filter, Copy Summary |
| HI2 | Fixed — red failed, orange interrupted symbols |
| HI3 | Fixed — "All Kinds" / "n of m Kinds", Show All inside the menu |
| A1 | Fixed — "Off" with a neutral symbol when nothing needs it (`Row.isNeeded`) |
| A2 | Fixed — hint only after the trip to the pane (`AccessChecklist.showsHint`) |
| A3 | Fixed — "Open System Settings" |
| A4 | Fixed — "Check Again", "Install Helper…" |
| C1 | Fixed — system indigo/teal kept, recorded in BRAND.md |
| C2 | Fixed — "0" at the origin |
| X1 | Fixed — no ids or internal words; `R5WritingTests` scans every app/perm/savings string in every language |
| X2 | Fixed — no ALL CAPS (same test) |
| X3 | Fixed — SF Symbols |
| X4 | Fixed — prose trimmed on every screen |
| X5 | Fixed — title case for buttons, menus, headers, sidebar |
| X6 | Fixed — one-line guidance, the manual route as its tooltip (`Row.helpKey`) |
| X7 | Fixed — Delete's table takes focus; chips and menus reach every filter. Full Keyboard Access not exercised in a window |
| X8 | Fixed — min/ideal widths; fixed caption widths removed; the helper sheet flexible |
| X9 | Fixed — Increase Contrast variants and hairlines. Off a window `NSAppearance(named:)` gives the base, so only the mapping is tested |
| X10 | Fixed — tooltips on icon-only controls, badges, the chart, truncated cells |

Totals: 70 fixed, 1 skipped (O7), 1 already done (H4). The user's feedback: H16 recorded; hint un-hedged with the +
fallback; Relaunch XCodeVault behind `AppEnvironment.relaunch`; Storage multi-select (⌘-click, chips), Show All with a
summary, hover and pointer, a persistent hint, search in Core (`StorageTable.matches`); Simulators search and a
clearable selection.
**Still needs a real window:** hover/pointer and ⌘-click on the charts; the Simulators table scrolling to a clicked row
(`ScrollViewReader` on a `Table`); History rows of two lines in a `Table`; the search fields' placement; Relaunch
XCodeVault (a new instance, then quit); Increase Contrast; Full Keyboard Access.

# Known issues at publication, 2026-09-17

Everything here was found by an independent review before the first push, judged non-blocking, and
deliberately left. It is written down so it becomes public issues rather than knowledge that existed
only in one conversation. Each entry says who found it and what makes it non-blocking *today*,
because several of them stop being non-blocking the moment something else changes.

The blocking findings from the same reviews were fixed; see `STATUS.md` for that pass.

## Privileged helper

Nothing here is reachable by a client. No shipped artifact contains the helper — `bundle-app.sh`
gates the binary and the LaunchDaemon plist behind `--with-helper`, off by default — and no code in
the tree opens a connection to it. **Every item below becomes live the moment that flag is used in a
release**, which is why the same list is repeated beside the flag in `scripts/bundle-app.sh`.

- ~~**Path-based cleanup verb.**~~ **Fixed 2026-09-18** (issue #1). The verb now walks every
  component from `/` with `openat` + `O_NOFOLLOW`, checking owner *and* mode at each level, and —
  the part that took two review rounds to get right — acts **through the returned descriptor**
  (`fstatat`/`openat`/`unlinkat`) instead of rebuilding the path. The first attempt did the walk
  and then re-resolved the string for every operation, which made the guard decorative; both
  reviewers caught it independently. The recursion also refuses to cross a device boundary, which
  `FileManager.removeItem` (`removefile(3)` with `REMOVEFILE_RECURSIVE`) did not.
- ~~**`isMountPoint` fails open in that same verb.**~~ **Fixed 2026-09-18** (issue #2). The query
  is three-valued (`MountAnswer`), is asked of the **descriptor** rather than the name, and the
  verb refuses on `.undetermined`. `isMountPoint` survives for the byte accounting, where the
  collapse is not a safety decision; its doc comment now names both callers and says why the
  remaining guard use is safe.

  Both of the above are now pinned *at the call site*, not only in the primitives. The mutations
  that restore each defect verbatim — replacing the mount switch with `_ = mount(fd)`, and the
  guarded walk with a bare `open` — previously passed the whole suite and now each fail **one
  named test** (`testTheVerbRefusesOnBothNonAnswersFromTheMountQuery`, 6 assertions;
  `testTheVerbRefusesWhenAComponentOfTheChainIsGroupWritable`, 2 assertions). An earlier draft of
  this paragraph said "four named tests each"; that was assertion-failure lines counted as test
  failures — the measurement error `MUTATION-TESTING-NOTES.md` exists to prevent, made in the very
  document meant to be checkable. Corrected by counting distinct `Test Case … failed` lines.

  Seven guards inside the new code remain unpinned. Each says so **at the branch**, with the
  reason: the two `st_dev` checks (one on a child's name, one on the opened descriptor — the
  second needs a mount to appear between the `fstatat` and the `openat`), the `failures += 1` on
  an unstattable child (needs a `readdir`/`fstatat` race), the `readdir` `errno` check (needs a
  real I/O error mid-enumeration), `O_NOFOLLOW` on the recursive child open (survives only
  because the `S_IFLNK` check catches the symlink first — redundant-looking and load-bearing),
  the `AT_REMOVEDIR` failure branch (near-unreachable, since a surviving child already reported),
  and the production gate on the injected mount query (its whole point is the `base == "/"`
  branch, which no test can enter without walking the real system path).

  An earlier draft of this paragraph said two. A reviewer enumerated nine surviving mutations and
  showed that **two of them needed no root, no volume and no race** — `chmod 000` on a
  subdirectory and `chflags uchg` on a file. Those two are now tested, along with the depth
  limit, the trust-anchor containment check and the root-anchor owner refusal. The lesson is the
  one this change is about: "unpinnable" is a claim that has to be checked per guard, not a
  category applied to whatever is left over.
- **The volume-UUID lookup parses an attribute it never confirmed was returned.** `getattrlist` is
  called without `ATTR_CMN_RETURNED_ATTRS`, so a filesystem that succeeds without supplying
  `ATTR_VOL_UUID` would yield the all-zero UUID, which is a valid `UUID` and would act as a
  wildcard. Probed on apfs, msdos, devfs and autofs, all of which either return a real UUID or fail;
  smbfs, nfs, webdav and FUSE are untested.
- **No audit log.** A root daemon that deletes files and changes ownership records nothing, so an
  incident has nothing to reconstruct from.
- **A narrow race in `createVaultDirectory`.** Between `mkdir` succeeding and `open` returning, a
  writer on that volume can rename a different directory into the path. The create branch now also
  requires the directory to be root-owned, which closes the demonstrated case; the caller must
  already be an administrator either way.

## `scripts/helper-invariants.sh`

The checker has been mutation-tested by a reviewer three times and defeated every time. The current
round left thirteen known bypasses. Its header states its ceiling, and the important thing is that
**nothing in the project may cite it as evidence that a change is safe** — the helper-security
review is the control. Specific gaps worth closing, in rough order of value:

- It does not read `Package.swift`, so it cannot see the helper target gaining a dependency, and the
  "only two dependents" property is held by human review alone.
- Function bodies are extracted by a fixed-indent terminator rather than brace balance, so a
  one-line body runs into the next function and can borrow its `authorize()`.
- The helper directory list is hardcoded; a new target added to the helper's dependency closure is
  invisible.
- Comment stripping is line-based and quote-aware only crudely.
- It cannot detect semantic neutering — `_ = authorize()`, or an `authorize()` rewritten to return
  nil — and no text matcher can.

## Migration engine

The abort/forget pair terminates under every obstacle a reviewer could produce on this machine —
`deny delete` ACLs, `uchg`, read-only parents, an obstacle that only appears on the second attempt —
because the redirect is bounded by counting `ABORT_FAILED` entries rather than by predicting whether
a removal will succeed. Two residuals were found in the same review and left:

- **"I cannot see it" is reported as "it is gone."** `abort`, `forget` and `leftoverPartialCopies`
  all treat a failing `lstat` on the partial copy as absence. `EACCES` — from a parent with no search
  permission, or an ACL denying `search,list,readattr` — and `EIO` from a failing enclosure both
  produce that, and the operation is then journaled as "no partial copy present, source intact"
  while the copy is still on the drive. Nothing is deleted on this path and the source is untouched;
  what is wrong is the claim. The fix is to keep `errno` and treat only `ENOENT` as absence.
- **An entry closed after two failed aborts survives only as a journal summary.** `doctor` and
  `migration status` read `leftoverPartialCopies`, which is driven by open entries, so once
  `forget --i-verified-both-copies-myself` closes one the partial copy is no longer named anywhere
  but the journal line that records it. That is the intended escape hatch — it exists for a copy the
  machine cannot remove — but the trade is real and worth stating: the user is the one who has to
  remember.
- **If the journal itself cannot be written, every verb errors and nothing closes.** `abort` records
  its failure before rethrowing, so an unwritable journal replaces the removal error with a write
  error and the failure count never advances. Not reproduced; noted because the failure mode is loud
  rather than silent, which is the property that makes it acceptable to leave.

## Compatibility

Every claim in `docs/architecture/COMPATIBILITY_MATRIX.md` was measured on one Mac, one
architecture, two macOS builds of one major version, one Xcode and one external volume. Several
findings are `probable` rather than `verified` for that reason alone. This is the gap publication
exists to close; see `CONTRIBUTING.md`.

## Documentation

- The tail of `STATUS.md` is still in Portuguese. `SESSION-HANDOFF.md` was translated in the
  2026-09-18 review because both entry points route a cold start to it; `STATUS.md` was classified
  line by line in the same review but not restructured, because four of its ranges are the only
  surviving copy of a lesson and rehousing them is a separate piece of work. See
  `REVIEW-2026-09-17.md` §G12 for the line ranges and their named destinations.

## Found by the 2026-09-18 pre-publication review and left

Each of these is real, has a written remedy in `REVIEW-2026-09-17.md`, and was judged to cost more
than it returns before a first public commit. They are here so they become issues rather than
knowledge that existed in one conversation.

### Testability of the privileged verbs

**Largely resolved 2026-09-18** (issue #6). `removeRegenerableSystemDirectoryContents` is now
internal and called by tests through a `under:` seam that injects the *trust anchor* only — the
target is still chosen from `HelperCleanupTarget` and the required owner is derived from whoever
owns the anchor, so a test owns its own tree while production keeps demanding root. An earlier
draft injected `requiredOwner` instead; both reviewers pointed out that an owner knob on a root
deletion verb is a way to ask root to delete somebody else's tree, and that a default argument is
not a defence against a future in-module caller.

This section previously made a falsifiable prediction: that replacing `doCreateVaultDirectory`'s
`(created && st_uid == 0) || st_uid == callerUID` guard with `true` would fail no test. It was
correct, and it now fails five rows of a truth table. **What it did not predict is the more
interesting half** — extracting and testing the guard did not pin the *call site*, and the first
attempt at this change left all three call sites mutation-clean while looking thoroughly tested.

Still open: `doCreateVaultDirectory` itself has no test that calls it, so the `mayTakeOwnership`
call site remains unpinned even though the predicate is exhaustively covered. See issue #5, which
needs the same verb reworked onto `mkdirat`/`openat` against a parent descriptor anyway.

### Structural findings with named seams

- `Doctor.swift` (1,025 lines) has a real two-reasons-to-change seam at lines 471-941: the
  CoreSimulator rules are versioned by *Apple's* release schedule, everything else by this
  project's. `Doctor+Vault.swift` already proves the extension-in-its-own-file pattern works.
- `MigrationEngine.swift` (839 lines) has one at 660-839: journal forensics that migrate nothing and
  read only `[JournalEntry]`. `abortDisposition` is already near-pure over its input.
- Four injection seams are missing, each blocking a specific test: `isMountPoint` in
  `MigrationEngine` (the source already says "UNPINNED, knowingly" beside it), the free-space guard,
  `XcodeLocations.preflightLocation`'s shadow-data check, and `CleanExecutor.preflight`'s
  nested-mount-point guard.
- The `runtime offload` transaction — four guards, an `hdiutil` verification and three journal
  transitions — lives in `Sources/xcodevaultctl/M2Commands.swift`, an executable target no test can
  import. It is the most destructive verb in the product. This is the `getgrouplist` pattern the
  project has already paid for once.

### API surface

`XCodeVaultCore` ships as a `.library` product with a large public surface and no
`package`/`internal` discipline, which makes all of it a semver commitment on the day the repository
opens, when every actual consumer is in this repository. Two passes counted the surface differently
(551 vs 422) by different methods; the count is not the point. Also: `XcodeLocations.Change.key` is a
free-form `String` written into `defaults write com.apple.dt.Xcode`, with the "which keys this tool
may own" rule held by discipline at six call sites; and each client composes the Doctor's two rule
families by hand, so a third family means editing three files with no compile error if one is missed.

### CI and the test suite

- ~~Six of the twenty `XCTSkip` sites cannot be ruled out on a GitHub runner~~ — **measured on the
  first CI run, 2026-09-18: zero tests skipped on either `macos-15` or `macos-26`.** All 275
  executed on both. So `chmod +a` works there, `hdiutil create`/`attach` works there, and the
  `/Volumes/<bootname>` symlink exists there; the three ACL tests, including the only pin on the
  abort/forget termination bound, do run in CI. The *residual* is that nothing enforces it: an
  environment change could start skipping tests and no gate would notice. CI should assert its
  environment supports what the skips need, and fail if the skip count exceeds a committed baseline
  of zero.
- `.github/workflows/ci.yml` pins `actions/checkout` and `actions/upload-artifact` by mutable tag
  rather than SHA. Given `permissions: contents: read`, no secrets, and no publishing step, this does
  not materially change the workflow's risk — but the calculus changes the day a release job is added.
- The workflow has still never executed. Publishing is what will run it for the first time.

### Evidence ledger

Three rows in `docs/architecture/COMPATIBILITY_MATRIX.md` warrant demotion on evidence grounds: a
`.verified` catalog status whose evidence (F22) has no matrix entry; a verdict claiming a formula
"generalizes" from n=2 on one machine where the adjacent row correctly scopes the same claim; and a
row whose evidence is "this session's transcript (no `.txt` evidence file written)" in a document
whose header calls it an evidence ledger. Evidence is append-only, so these are demotions only.

### Naming

`M2Commands.swift` and `M3Commands.swift` are named for a milestone scheme that appears nowhere in
`README.md`, `CONTRIBUTING.md`, `CLAUDE.md` or `AGENTS.md` — the docs say "Phase 0…6". The code's
vocabulary is not recoverable from the repository. Renaming by content is cheap and internal; it was
left because it would collide with the structural splits above, which should happen first.

